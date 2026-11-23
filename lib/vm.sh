#!/usr/bin/env bash
# vm.sh - VM lifecycle: create, run, install, resize, import/export, menus

# --- Paths ---
vm_disk() {
  local d; d="$(vm_dir_of "$1")"
  printf '%s/disk.qcow2' "$d"
}

# --- Disk info ---
disk_size_line() {
  local disk="$1"
  [[ -f "$disk" ]] || { echo "disk: missing"; return; }
  if command -v python3 >/dev/null 2>&1; then
    qemu-img info --output=json "$disk" 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
v=d.get("virtual-size",0); a=d.get("actual-size",0)
def h(n):
    for u in ["B","KB","MB","GB","TB"]:
        if n < 1024 or u == "TB":
            return f"{n:.1f}{u}" if u != "B" else f"{int(n)}B"
        n /= 1024
print(f"virtual={h(v)}  used={h(a)}")
' 2>/dev/null || du -h "$disk" | awk '{print "used="$1}'
  else
    du -h "$disk" | awk '{print "used="$1}'
  fi
}

# --- Name handling ---
# Validate a VM name before creating anything.
validate_vm_name() {
  local name="$1"
  if [[ -z "$name" ]]; then
    warn "VM name cannot be empty."
    return 1
  fi
  if (( ${#name} > 64 )); then
    warn "VM name is too long (max 64 characters)."
    return 1
  fi
  case "$name" in
    .|..) warn "Invalid VM name: $name"; return 1 ;;
    -*)   warn "VM name cannot start with '-': $name"; return 1 ;;
    */*|*\\*) warn "VM name cannot contain '/' or '\\': $name"; return 1 ;;
  esac
  if [[ "$name" == *[[:cntrl:]]* ]]; then
    warn "VM name contains control characters."
    return 1
  fi
  return 0
}

# Validate a folder chosen as a VM destination.
validate_vm_dest() {
  local dest="$1" parent name d
  if [[ -z "$dest" ]]; then
    warn "Folder cannot be empty."
    return 1
  fi
  case "$dest" in
    *$'\t'*|*$'\n'*) warn "Folder cannot contain tabs or newlines."; return 1 ;;
  esac
  if [[ "$dest" == "/" ]]; then
    warn "Refusing to use '/' as a VM folder."
    return 1
  fi
  if [[ "$dest" == "$HOME" ]]; then
    warn "Refusing to use your home folder as a VM folder."
    return 1
  fi
  if [[ -e "$dest" ]]; then
    if [[ ! -d "$dest" ]]; then
      warn "Not a folder: $dest"
      return 1
    fi
    if [[ ! -r "$dest" || ! -x "$dest" ]]; then
      warn "Folder is not readable: $dest"
      return 1
    fi
    if [[ -n "$(ls -A -- "$dest" 2>/dev/null)" ]]; then
      warn "Folder is not empty: $dest"
      return 1
    fi
  fi
  while IFS= read -r name; do
    d="$(vm_dir_of "$name")"
    case "$dest" in
      "$d") warn "Folder is already used by VM '$name': $dest"; return 1 ;;
      "$d"/*) warn "Folder is inside VM '$name': $dest"; return 1 ;;
    esac
  done < <(list_vms)
  parent="$(dirname "$dest")"
  if [[ ! -d "$parent" ]]; then
    if ! mkdir -p -- "$parent" 2>/dev/null; then
      warn "Cannot create parent folder: $parent"
      return 1
    fi
  fi
  require_dir_writable "$parent" "Parent folder" || return 1
  return 0
}

# Ask for a VM folder; sets VM_DEST (not echoed, so warnings stay visible).
VM_DEST=""
choose_vm_dest() {
  local default="$1" input dest
  read -e -r -p "VM folder [$(pretty_path "$default")]: " input
  dest="$(resolve_user_path "${input:-$default}")" || { warn "Invalid path."; return 1; }
  validate_vm_dest "$dest" || return 1
  VM_DEST="$dest"
  return 0
}

# Is this VM's disk currently opened by a QEMU process?
vm_is_running() {
  local name="$1" disk out
  disk="$(vm_disk "$name")"
  out="$(ps -eww -o args= 2>/dev/null || ps -eo args= 2>/dev/null || ps aux 2>/dev/null || true)"
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out" | grep -F -- "qemu-system" | grep -Fq -- "$disk"
}

# --- Menus ---
pick_main_menu() {
  local -a items=()
  local vm
  while IFS= read -r vm; do [[ -n "$vm" ]] && items+=("$vm"); done < <(list_vms | sort)
  items+=("＋ New VM" "⇩ Import VM" "⚙ Permissions check" "⚙ Settings")
  menu_pick "Select> " "Select a VM, or create/import" "60%" "${items[@]}"
}

pick_vm_action() {
  local name="$1" disk size dir
  disk="$(vm_disk "$name")"
  size="$(disk_size_line "$disk")"
  dir="$(vm_dir_of "$name")"
  local -a actions=("Run" "Install / Reinstall (from ISO)" "Resize disk" "Port forwards" "Bootstrap" "VM Settings" "Export VM" "Delete VM" "Back")
  menu_pick "$name> " "VM: $name | $size | $(pretty_path "$dir")" "45%" "${actions[@]}"
}

# --- Name/ISO pickers ---
# Pick a new VM name. With fzf, Tab inserts the highlighted suggestion into
# the query and keeps the picker open, so the text can still be edited or
# extended (e.g. "Windows 11" + " Test") before pressing Enter.
pick_name() {
  local name=""
  if has_fzf; then
    local out="" query="" sel="" rc=0
    local header="Tab = complete  •  Enter = confirm  •  Esc = cancel  |  ${#VMCTL_OS_LIST[@]} suggestions"
    local -a base=(--print-query --prompt="VM name> " --height=75% --reverse --border --tiebreak=index --header="$header")

    out="$(printf '%s\n' "${VMCTL_OS_LIST[@]}" | \
      fzf "${base[@]}" --bind 'tab:replace-query,ctrl-space:replace-query' 2>/dev/null)" || rc=$?
    # Very old fzf builds do not know "replace-query": retry without the bind.
    if (( rc == 2 )); then
      rc=0
      out="$(printf '%s\n' "${VMCTL_OS_LIST[@]}" | fzf "${base[@]}" 2>/dev/null)" || rc=$?
    fi

    query="$(printf '%s\n' "$out" | sed -n '1p')"
    sel="$(printf '%s\n' "$out" | sed -n '2p')"

    if (( rc == 130 )); then
      name=""                                  # Esc / Ctrl-C = cancel
    elif [[ -z "$sel" ]]; then
      name="$query"                            # custom name with no match
    elif [[ -z "$query" ]]; then
      name="$sel"                              # only a highlighted item
    elif [[ "${sel,,}" == "${query,,}"* ]]; then
      name="$sel"                              # typed prefix -> full suggestion
    else
      name="$query"                            # edited/extended text wins
    fi
  else
    local filter choice i
    read -e -r -p "Search OS (Enter = list first 40): " filter
    local -a matches=()
    while IFS= read -r line; do matches+=("$line"); done < <(
      printf '%s\n' "${VMCTL_OS_LIST[@]}" | grep -iF -- "$filter" | head -n 40
    )
    if (( ${#matches[@]} == 0 )); then
      name="$filter"
    else
      echo "Matches:" >&2
      i=1
      for line in "${matches[@]}"; do echo "  $i) $line" >&2; i=$((i+1)); done
      read -e -r -p "Number, or type a custom name: " choice
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#matches[@]} )); then
        name="${matches[$((choice-1))]}"
      else
        name="$choice"
      fi
    fi
  fi
  name="$(sanitize_name "$name")"
  printf '%s' "$name"
}

pick_iso() {
  local iso=""
  if has_fzf; then
    read -e -r -p "ISO path (empty = browse): " iso
    if [[ -z "$iso" ]]; then
      iso="$(find "$DIR" "$HOME" -maxdepth 4 -type f -iname '*.iso' 2>/dev/null | fzf --prompt="ISO> " --height=60% --reverse --border)" || true
    fi
  else
    read -e -r -p "ISO path: " iso
  fi
  printf '%s' "$iso"
}

normalize_iso() {
  local iso="$1"
  iso="$(resolve_user_path "$iso" 2>/dev/null || true)"
  if [[ ! -f "$iso" ]]; then
    local iso_unescaped
    iso_unescaped="$(printf '%s' "$iso" | sed 's/\\\([[:space:]'\''"()&;]\)/\1/g')"
    [[ -f "$iso_unescaped" ]] && iso="$iso_unescaped"
  fi
  [[ -f "$iso" ]] || die "File not found: $iso"
  [[ -r "$iso" ]] || die "ISO is not readable: $iso"
  case "${iso,,}" in
    *.iso) ;;
    *.rar|*.zip|*.7z|*.tar.gz|*.tar.xz) die "Selected file is an archive, not an ISO: $iso"$'\n'"Extract it first, then provide the .iso file." ;;
    *) die "Selected file is not an .iso: $iso" ;;
  esac
  printf '%s' "$iso"
}

# --- SPICE readiness ---
wait_spice_port() {
  local port="$1" pid="$2" i=0 max=60
  info "Waiting for SPICE on 127.0.0.1:$port ..."
  while [[ "$i" -lt "$max" ]]; do
    local elapsed=$(( i / 2 ))
    if command -v python3 >/dev/null 2>&1; then
      if python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.2); r=s.connect_ex(('127.0.0.1',int(sys.argv[1]))); s.close(); sys.exit(0 if r==0 else 1)" "$port" >/dev/null 2>&1; then
        progress_bar "$i" "$max" "SPICE " "${elapsed}s"; printf '\n'
        ok "SPICE ready on port $port (${elapsed}s)"; return 0
      fi
    elif command -v nc >/dev/null 2>&1; then
      if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
        progress_bar "$i" "$max" "SPICE " "${elapsed}s"; printf '\n'
        ok "SPICE ready on port $port (${elapsed}s)"; return 0
      fi
    else
      sleep 2; ok "SPICE wait skipped (no port checker)"; return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then printf '\n'; return 1; fi
    progress_bar "$i" "$max" "SPICE " "${elapsed}s"
    sleep 0.5
    i=$((i + 1))
  done
  printf '\n'
  return 1
}

# --- Per-VM config ---
vm_conf()        { printf '%s/vm.conf' "$(vm_dir_of "$1")"; }
vm_conf_legacy() { printf '%s/display.conf' "$(vm_dir_of "$1")"; }

vm_conf_get() {
  local name="$1" key="$2" def="${3:-}" val
  val="$(conf_get "$(vm_conf "$name")" "$key" "")"
  [[ -z "$val" ]] && val="$(conf_get "$(vm_conf_legacy "$name")" "$key" "")"
  printf '%s' "${val:-$def}"
}

vm_conf_set() { conf_set "$(vm_conf "$1")" "$2" "$3" 600; }

get_vm_monitors() { local v; v="$(vm_conf_get "$1" monitors "")"; [[ "$v" =~ ^[1-4]$ ]] && printf '%s' "$v" || true; }
get_vm_memory()   { local v; v="$(vm_conf_get "$1" memory "")";   [[ "$v" =~ ^[0-9]+[MG]$ ]] && printf '%s' "$v" || true; }
get_vm_cpus()     { local v; v="$(vm_conf_get "$1" cpus "")";     [[ "$v" =~ ^[0-9]+$ ]] && (( v>=1 && v<=32 )) && printf '%s' "$v" || true; }

set_vm_monitors() { [[ "$2" =~ ^[1-4]$ ]] || return 0; [[ "$(get_vm_monitors "$1")" == "$2" ]] && return 0; vm_conf_set "$1" monitors "$2"; }
set_vm_memory()   { local v; v="$(printf '%s' "$2" | tr 'mg' 'MG')"; [[ "$v" =~ ^[0-9]+[MG]$ ]] || return 1; vm_conf_set "$1" memory "$v"; }
set_vm_cpus()     { [[ "$2" =~ ^[0-9]+$ ]] && (( $2>=1 && $2<=32 )) || return 1; vm_conf_set "$1" cpus "$2"; }

vm_setting() {
  local name="$1" key="$2" global_def="$3" val
  case "$key" in
    monitors) val="$(get_vm_monitors "$name")" ;;
    memory)   val="$(get_vm_memory "$name")" ;;
    cpus)     val="$(get_vm_cpus "$name")" ;;
    *) val="" ;;
  esac
  printf '%s' "${val:-$global_def}"
}

ask_monitor_count() {
  local name="${1:-}" ans="" def="${DEFAULT_MONITORS:-1}" saved=""

  # Env override for automation/scripting.
  if [[ -n "${VMCTL_MONITORS:-}" ]]; then
    ans="$VMCTL_MONITORS"
    [[ "$ans" =~ ^[1-4]$ ]] || { warn "VMCTL_MONITORS must be 1-4, using ${DEFAULT_MONITORS:-1}."; ans="${DEFAULT_MONITORS:-1}"; }
    [[ -n "$name" ]] && set_vm_monitors "$name" "$ans"
    printf '%s' "$ans"
    return
  fi

  [[ -n "$name" ]] && saved="$(get_vm_monitors "$name")"
  [[ -n "$saved" ]] && def="$saved"

  if [[ ! -t 0 ]]; then
    [[ -n "$name" ]] && set_vm_monitors "$name" "$def"
    printf '%s' "$def"
    return
  fi

  echo >&2
  read -e -r -p "Number of monitors [$def]: " ans || true
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[0-9]+$ ]] || { warn "Invalid number, using $def monitor(s)."; ans="$def"; }
  if (( ans < 1 )); then warn "Minimum is 1, using 1."; ans=1; fi
  if (( ans > 4 )); then warn "Maximum is 4, using 4."; ans=4; fi

  [[ -n "$name" ]] && set_vm_monitors "$name" "$ans"
  printf '%s' "$ans"
}

run_qemu() {
  local name="$1" disk="$2" boot_iso="${3:-}"
  local nic monitors; nic="$(nic_arg "$name")"
  monitors="$(ask_monitor_count "$name")"

  local cpus mem
  cpus="$(vm_setting "$name" cpus "${DEFAULT_CPUS:-2}")"
  mem="$(vm_setting "$name" memory "${DEFAULT_MEMORY:-4G}")"
  [[ "$cpus" =~ ^[0-9]+$ ]] || cpus=2
  [[ "$mem" =~ ^[0-9]+[MG]$ ]] || mem=4G

  local -a args=(
    -name "$name"
    -machine pc,usb=on
    -accel "$ACCEL"
    -cpu "${CPU}${CPU_EXTRA}"
    -smp "$cpus,sockets=1,cores=$cpus,threads=1"
    -m "$mem"
    -rtc base=localtime,clock=host
    -drive "file=$disk,format=qcow2,if=ide,cache=writeback"
  )

  if [[ -n "$boot_iso" ]]; then
    args+=( -drive "file=$boot_iso,media=cdrom,readonly=on" -boot once=d )
  fi
  args+=(
    -nic "$nic"
    -device usb-tablet
  )
  if (( monitors > 1 )); then
    # More compatible multi-monitor: one QXL device per head.
    # Windows/QXL drivers often detect separate devices more reliably than
    # multiple outputs on a single qxl-vga.
    local vgamem=64 qxl_ram=128 i
    args+=( -vga none
            -device "qxl-vga,id=video0,max_outputs=1,vgamem_mb=$vgamem,ram_size_mb=$qxl_ram,vram_size_mb=$qxl_ram" )
    for (( i=1; i<monitors; i++ )); do
      args+=( -device "qxl,id=video$i,max_outputs=1,vgamem_mb=$vgamem,ram_size_mb=$qxl_ram,vram_size_mb=$qxl_ram" )
    done
  else
    args+=( -vga qxl )
  fi
  args+=(
    -spice "addr=127.0.0.1,port=${SPICE_PORT},disable-ticketing=on,image-compression=off,disable-copy-paste=off,disable-agent-file-xfer=off,agent-mouse=on,seamless-migration=on"
    -device virtio-serial-pci
    -chardev spicevmc,id=vdagent,name=vdagent
    -device virtserialport,chardev=vdagent,name=com.redhat.spice.0
    -chardev spiceport,id=webdav,name=org.spice-space.webdav.0
    -device virtserialport,chardev=webdav,name=org.spice-space.webdav.0
    -device ich9-intel-hda -device hda-duplex
  )

  info "[1/3] Configuration"
  echo "      VM:       $name"
  echo "      FOLDER:   $(pretty_path "$(vm_dir_of "$name")")"
  echo "      ACCEL:    $ACCEL"
  echo "      CPU:      ${CPU}${CPU_EXTRA}"
  echo "      RAM:      $mem"
  echo "      CPUS:     $cpus"
  echo "      DISK:     $disk ($(disk_size_line "$disk"))"
  echo "      MONITORS: $monitors"
  [[ -n "$boot_iso" ]] && echo "      ISO:      $boot_iso"
  echo "      SPICE:    127.0.0.1:$SPICE_PORT"
  if (( monitors > 1 )); then
    info "Extra monitors are exposed to the guest. If the second window does not open automatically, enable Extend inside the guest:"
    echo "      Windows (fast): run in PowerShell/cmd inside guest:  DisplaySwitch.exe /extend"
    echo "      Windows (GUI):  Settings > System > Display > Extend these displays"
    echo "      Linux:          install spice-vdagent/qxl, then enable outputs in Display Settings/xrandr"
  fi

  run_bootstraps "$name"

  if command -v remote-viewer >/dev/null 2>&1; then
    args+=( -display none )
    info "[2/3] Starting QEMU..."
    qemu-system-x86_64 "${args[@]}" &
    local qemu_pid=$!
    cleanup() { kill "$qemu_pid" 2>/dev/null || true; cleanup_bootstraps; }
    trap cleanup EXIT INT TERM
    ok "QEMU started (pid $qemu_pid)"
    info "[3/3] Connecting viewer..."
    wait_spice_port "$SPICE_PORT" "$qemu_pid" || { cleanup_bootstraps; die "QEMU exited before SPICE became ready."; }
    remote-viewer "spice://127.0.0.1:${SPICE_PORT}" || true
    info "Viewer closed, shutting down..."
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
    cleanup_bootstraps
    trap - EXIT INT TERM
    ok "VM stopped"
  else
    info "[2/3] Starting QEMU (no remote-viewer, using default display)..."
    args+=( -display default )
    info "[3/3] SPICE available at spice://127.0.0.1:${SPICE_PORT}"
    trap cleanup_bootstraps EXIT INT TERM
    qemu-system-x86_64 "${args[@]}" || true
    cleanup_bootstraps
    trap - EXIT INT TERM
  fi
}

# --- Per-VM settings ---
action_vm_settings() {
  local name="$1"
  while true; do
    local mem cpu mon
    mem="$(vm_setting "$name" memory "${DEFAULT_MEMORY:-4G}")"
    cpu="$(vm_setting "$name" cpus "${DEFAULT_CPUS:-2}")"
    mon="$(vm_setting "$name" monitors "${DEFAULT_MONITORS:-1}")"
    local -a acts=(
      "Memory:   $mem"
      "CPUs:     $cpu"
      "Monitors: $mon"
      "Reset to global defaults"
      "Back"
    )
    local choice
    choice="$(menu_pick "VM Settings> " "VM: $name (per-VM overrides; empty = global default)" "45%" "${acts[@]}")"
    case "$choice" in
      Memory:*)
        local v; v="$(ask_default "Memory for '$name' (e.g. 2G, 8G, 4096M) [$mem]: " "$mem")"
        v="$(printf '%s' "$v" | tr 'mg' 'MG')"
        if [[ "$v" =~ ^[0-9]+[MG]$ ]]; then set_vm_memory "$name" "$v" && ok "Saved."
        else warn "Invalid value. Use like 2G or 4096M."; fi
        ;;
      CPUs:*)
        local v; v="$(ask_default "CPU cores for '$name' (1-32) [$cpu]: " "$cpu")"
        if [[ "$v" =~ ^[0-9]+$ ]] && (( v>=1 && v<=32 )); then set_vm_cpus "$name" "$v" && ok "Saved."
        else warn "Invalid value. Use 1-32."; fi
        ;;
      Monitors:*)
        local v; v="$(ask_default "Monitors for '$name' (1-4) [$mon]: " "$mon")"
        if [[ "$v" =~ ^[1-4]$ ]]; then set_vm_monitors "$name" "$v"; ok "Saved."
        else warn "Invalid value. Use 1-4."; fi
        ;;
      "Reset to global defaults")
        if confirm "Reset VM '$name' memory/CPUs/monitors to global defaults?"; then
          local f tmp
          for f in "$(vm_conf "$name")" "$(vm_conf_legacy "$name")"; do
            [[ -f "$f" ]] || continue
            tmp="$(mktemp "${f}.XXXXXX")" || continue
            awk -F= '!/^[[:space:]]*(memory|cpus|monitors)[[:space:]]*=/{print}' "$f" > "$tmp" && mv -f -- "$tmp" "$f" || rm -f -- "$tmp"
            chmod 600 "$f" 2>/dev/null || true
          done
          ok "Per-VM overrides cleared (global defaults will be used)."
        fi
        ;;
      Back|"") return ;;
    esac
  done
}

# --- VM actions ---
action_run() {
  local name="$1" disk
  require_vm_writable "$name" || return
  disk="$(vm_disk "$name")"
  [[ -f "$disk" ]] || die "Disk not found for '$name'. Use Install / Reinstall first."
  [[ -r "$disk" ]] || die "Disk is not readable: $disk"
  run_qemu "$name" "$disk" ""
}

action_install() {
  local name="$1" vm_dir disk
  require_vm_dir_writable "$name" || return
  vm_dir="$(find_vm_dir "$name")"
  disk="$vm_dir/disk.qcow2"
  if ! ensure_dir_private "$vm_dir"; then
    warn "Cannot access VM folder: $vm_dir"
    echo "  Fix: $(perm_chown_cmd "$vm_dir")"
    return
  fi

  echo
  echo "${C_RED}┌──────────────────────────────────────────────────────────┐${C_RST}"
  echo "${C_RED}│  DESTRUCTIVE ACTION: INSTALL / REINSTALL                 │${C_RST}"
  echo "${C_RED}└──────────────────────────────────────────────────────────┘${C_RST}"
  echo "${C_YEL}  VM:${C_RST}     $name"
  echo "${C_YEL}  Folder:${C_RST} $(pretty_path "$vm_dir")"
  echo "${C_YEL}  Disk:${C_RST}   $disk"
  echo "${C_YEL}  Action:${C_RST} Delete disk and create a fresh 40G qcow2"
  echo "${C_YEL}  Scope:${C_RST}  Only this VM's disk is affected"
  echo
  confirm_exact "Type ${C_RED}INSTALL${C_RST} to confirm: " "INSTALL" || { warn "Cancelled."; return; }

  local iso
  iso="$(pick_iso)"
  [[ -n "$iso" ]] || { warn "No ISO selected."; return; }
  iso="$(normalize_iso "$iso")"

  echo
  echo "${C_CYN}Install plan:${C_RST}"
  echo "  VM:     $name"
  echo "  ISO:    $iso"
  echo "  Folder: $(pretty_path "$vm_dir")"
  echo "  Disk:   $disk (40G, qcow2, fresh)"
  echo
  confirm "Proceed with wipe + install?" || { warn "Cancelled."; return; }

  info "[1/4] Removing old disk..."
  rm -f -- "$disk"
  ok "Old disk removed"

  info "[2/4] Creating fresh 40G qcow2 disk..."
  if ! qemu-img create -f qcow2 "$disk" 40G >/dev/null; then
    die "Could not create disk: $disk"
  fi
  chmod 600 -- "$disk" 2>/dev/null || true
  ok "Disk created: $disk"

  info "[3/4] Verifying disk..."
  local size_line; size_line="$(disk_size_line "$disk")"
  ok "Disk ready ($size_line)"

  info "[4/4] Launching VM..."
  run_qemu "$name" "$disk" "$iso"
}

action_resize() {
  local name="$1" disk
  require_vm_writable "$name" || return
  disk="$(vm_disk "$name")"
  [[ -f "$disk" ]] || die "Disk not found for '$name'."

  local current_bytes current_h
  if command -v python3 >/dev/null 2>&1; then
    current_bytes="$(qemu-img info --output=json "$disk" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("virtual-size",0))')"
  else
    current_bytes="$(qemu-img info "$disk" | awk -F'[()]' '/virtual size/ {print $2}' | awk '{print $1}')"
  fi
  [[ "$current_bytes" =~ ^[0-9]+$ ]] || die "Could not read disk size: $disk"
  current_h="$(awk -v n="$current_bytes" 'BEGIN { printf "%.1fG", n / 1073741824 }')"

  echo
  info "VM: $name"
  info "Folder: $(pretty_path "$(vm_dir_of "$name")")"
  info "Current virtual size: $current_h"
  echo "Select new size (grow only; shrinking can corrupt data):"

  local -a sizes=("32G" "40G" "64G" "80G" "128G")
  local choice=""
  if has_fzf; then
    choice="$(printf '%s\n' "${sizes[@]}" | fzf --prompt="Size> " --height=40% --reverse --border --header="Current: $current_h")" || true
  else
    local i=1
    for s in "${sizes[@]}"; do echo "  $i) $s" >&2; i=$((i+1)); done
    local idx; read -r -p "Choice: " idx
    if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx>=1 && idx<=${#sizes[@]} )); then choice="${sizes[$((idx-1))]}"; fi
  fi
  [[ -n "$choice" ]] || { warn "Cancelled."; return; }

  local new_bytes
  new_bytes=$(( ${choice%G} * 1024 * 1024 * 1024 ))
  if (( new_bytes <= current_bytes )); then
    warn "New size ($choice) must be larger than current ($current_h). Shrinking is not supported."
    return
  fi

  echo "Resize plan: $current_h -> $choice"
  confirm "Apply resize?" || { warn "Cancelled."; return; }
  info "[1/2] Resizing disk..."
  qemu-img resize "$disk" "$choice" >/dev/null
  ok "Resize applied: $current_h -> $choice"
  info "[2/2] Verifying..."
  local new_h; new_h="$(disk_size_line "$disk")"
  ok "Current: $new_h"
  warn "Inside the guest OS, extend the partition to use the new space."
}

# Default export folder: ~/Documents/ExVMcli (XDG-aware)
documents_dir() {
  local d=""
  if command -v xdg-user-dir >/dev/null 2>&1; then
    d="$(xdg-user-dir DOCUMENTS 2>/dev/null || true)"
  fi
  if [[ -z "$d" || "$d" == "$HOME" ]]; then
    d="$HOME/Documents"
  fi
  printf '%s' "$d"
}

# Build a timestamped default export path for a VM.
# ext is "zst" (fast) or "gz" (compatible).
export_default_path() {
  local name="$1" ext="${2:-gz}" safe ts
  safe="$(printf '%s' "$name" | sed 's/[[:space:]]\+/_/g; s#[/\\:]#-#g')"
  ts="$(date +%Y%m%d-%H%M%S)"
  printf '%s/ExVMcli/%s-%s.vmctl.tar.%s' "$(documents_dir)" "$safe" "$ts" "$ext"
}

# --- Archive compression helpers ---
# Detect the compression from magic bytes (extension-independent).
archive_kind() {
  local f="$1" magic
  magic="$(od -An -tx1 -N6 -- "$f" 2>/dev/null | tr -d ' \n')"
  case "$magic" in
    1f8b*)         printf 'gz' ;;
    28b52ffd*)     printf 'zst' ;;
    fd377a585a00*) printf 'xz' ;;
    425a68*)       printf 'bz2' ;;
    *)             printf 'plain' ;;
  esac
}

# Read archive members into a file; returns non-zero for corrupt archives.
# Optional 4th arg: file to write uncompressed total KB (GNU tar --totals).
# Shows a live progress bar on stderr when reading large archives on a TTY.
archive_list_to() {
  local archive="$1" out="$2" kind="$3" totals_out="${4:-}"
  local -a cmd
  case "$kind" in
    gz)    cmd=(tar -tzf "$archive") ;;
    zst)   cmd=(tar -I zstd -tf "$archive") ;;
    xz)    cmd=(tar -tJf "$archive") ;;
    bz2)   cmd=(tar -tjf "$archive") ;;
    plain) cmd=(tar -tf "$archive") ;;
    *) return 1 ;;
  esac

  if [[ -n "$totals_out" ]]; then
    local tmp_err rc=0
    tmp_err="$(mktemp "${TMPDIR:-/tmp}/vmctl-tarerr.XXXXXX")" || return 1

    # Progress bar based on compressed bytes read (Linux /proc/<pid>/io).
    local arch_bytes show_progress=0
    arch_bytes="$(stat -c '%s' -- "$archive" 2>/dev/null || stat -f '%z' -- "$archive" 2>/dev/null || echo 0)"
    [[ "$arch_bytes" =~ ^[0-9]+$ ]] || arch_bytes=0
    if [[ -t 2 && -d /proc && "$arch_bytes" -gt 0 ]]; then
      show_progress=1
    fi

    if (( show_progress )); then
      "${cmd[@]}" --totals > "$out" 2> "$tmp_err" &
      local tar_pid=$! read_bytes=0 pct=0
      local now_ms=0 last_ms=0 last_bytes=0 rate_bps=0 eta_ms=-1
      local unit=M scale=$((1024*1024))
      (( arch_bytes >= 1073741824 )) && { unit=G; scale=1073741824; }
      while kill -0 "$tar_pid" 2>/dev/null; do
        read_bytes=0
        local _p _rb
        for _p in "$tar_pid" $(ps -o pid= --ppid "$tar_pid" 2>/dev/null); do
          _rb="$(awk '/^read_bytes:/ {print $2; exit}' "/proc/$_p/io" 2>/dev/null)"
          [[ "$_rb" =~ ^[0-9]+$ ]] && read_bytes=$(( read_bytes + _rb ))
        done
        (( read_bytes > arch_bytes )) && read_bytes="$arch_bytes"
        now_ms="$(date +%s%3N 2>/dev/null)"; [[ "$now_ms" =~ ^[0-9]+$ ]] || now_ms=$(( $(date +%s) * 1000 ))
        if (( last_ms > 0 )); then
          local dt=$(( now_ms - last_ms ))
          if (( dt >= 400 )); then
            local db=$(( read_bytes - last_bytes ))
            (( db < 0 )) && db=0
            rate_bps=$(( db * 1000 / dt ))
            last_ms="$now_ms"; last_bytes="$read_bytes"
          fi
        else
          last_ms="$now_ms"; last_bytes="$read_bytes"
        fi
        if (( rate_bps > 0 )); then eta_ms=$(( (arch_bytes - read_bytes) * 1000 / rate_bps ))
        else eta_ms=-1; fi
        pct=$(( read_bytes * 100 / arch_bytes )); (( pct > 99 )) && pct=99
        local sp=$(( rate_bps / 1048576 ))
        local n e b s dn tn etas
        n=$(( pct * 20 / 100 )); e=$(( 20 - n ))
        b="$(printf '%*s' "$n" '' | tr ' ' '#')"; s="$(printf '%*s' "$e" '' | tr ' ' '-')"
        dn=$(( read_bytes * 10 / scale )); tn=$(( arch_bytes * 10 / scale ))
        if (( eta_ms < 0 )); then etas="--:--"
        elif (( eta_ms < 3600000 )); then etas="$(printf '%02d:%02d' $(( eta_ms / 60000 )) $(( eta_ms % 60000 / 1000 )))"
        else etas="$(printf '%d:%02d:%02d' $(( eta_ms / 3600000 )) $(( eta_ms % 3600000 / 60000 )) $(( eta_ms % 60000 / 1000 )))"; fi
        printf '\r  [%s%s] %3d%%  %d.%d/%d.%d%s  %d MB/s  ETA %s ' "$b" "$s" "$pct" "$((dn/10))" "$((dn%10))" "$((tn/10))" "$((tn%10))" "$unit" "$sp" "$etas" >&2
        sleep 0.2
      done
      wait "$tar_pid" || rc=$?
      if (( rc == 0 )); then
        local dn tn
        dn=$(( arch_bytes * 10 / scale )); tn="$dn"
        printf '\r  [####################] 100%%  %d.%d/%d.%d%s  done            \n' "$((dn/10))" "$((dn%10))" "$((tn/10))" "$((tn%10))" "$unit" >&2
        awk '/Total bytes (read|written):/ {for(i=1;i<=NF;i++) if($i=="read:"||$i=="written:") {gsub(/[^0-9]/,"",$(i+1)); print int($(i+1)/1024); found=1; exit}} END{if(!found) print 0}' "$tmp_err" > "$totals_out"
        rm -f -- "$tmp_err"
        return 0
      fi
      printf '\n' >&2
      rm -f -- "$tmp_err"
      # Retry without --totals
      printf '0\n' > "$totals_out"
      "${cmd[@]}" > "$out" 2>/dev/null
      return $?
    fi

    if "${cmd[@]}" --totals > "$out" 2> "$tmp_err"; then
      awk '/Total bytes (read|written):/ {for(i=1;i<=NF;i++) if($i=="read:"||$i=="written:") {gsub(/[^0-9]/,"",$(i+1)); print int($(i+1)/1024); found=1; exit}} END{if(!found) print 0}' "$tmp_err" > "$totals_out"
      rm -f -- "$tmp_err"
      return 0
    fi
    rc=$?
    rm -f -- "$tmp_err"
    printf '0\n' > "$totals_out"
    "${cmd[@]}" > "$out" 2>/dev/null
    return $?
  fi
  "${cmd[@]}" > "$out" 2>/dev/null
}

# Total uncompressed payload size in KB (best-effort, used for progress/ETA).
archive_total_kb() {
  local archive="$1" kind="$2" bytes
  bytes="$(
    case "$kind" in
      gz)    tar -tzvf "$archive" 2>/dev/null ;;
      zst)   tar -I zstd -tvf "$archive" 2>/dev/null ;;
      xz)    tar -tJvf "$archive" 2>/dev/null ;;
      bz2)   tar -tjvf "$archive" 2>/dev/null ;;
      plain) tar -tvf "$archive" 2>/dev/null ;;
      *) return 1 ;;
    esac | awk '
      # GNU tar: -rw-r--r-- user/group SIZE date time name
      # bsdtar:  -rw-r--r--  1 user group SIZE date time name
      /^[^ ]/ {
        s = $3 + 0
        if ($3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]{4}-|^[A-Za-z]{3}/) { sum += $3; next }
        if ($5 ~ /^[0-9]+$/) { sum += $5; next }
        if ($3 ~ /^[0-9]+$/) { sum += $3; next }
      }
      END { print sum + 0 }
    '
  )" || bytes=0
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
  echo $(( bytes / 1024 ))
}

# Extract an archive into a folder (fallback for old tar without --no-same-owner).
archive_extract_to() {
  local archive="$1" dir="$2" kind="$3"
  local -a cmd
  case "$kind" in
    gz)    cmd=(tar -xzf "$archive" -C "$dir") ;;
    zst)   cmd=(tar -I zstd -xf "$archive" -C "$dir") ;;
    xz)    cmd=(tar -xJf "$archive" -C "$dir") ;;
    bz2)   cmd=(tar -xjf "$archive" -C "$dir") ;;
    plain) cmd=(tar -xf "$archive" -C "$dir") ;;
    *) return 1 ;;
  esac
  "${cmd[@]}" --no-same-owner 2>/dev/null || "${cmd[@]}" 2>/dev/null
}

# GNU tar checkpoint action: renders a progress/ETA bar to stderr.
# Env: VMCTL_TOTAL_KB, VMCTL_SCALE, VMCTL_UNIT, VMCTL_PROGRESS_FILE
_tar_checkpoint_action() {
  cat <<'SH'
f=${VMCTL_PROGRESS_FILE:-/dev/null}; tf=${VMCTL_TOTAL_KB:-1}
now=$(date +%s%N 2>/dev/null)
case "$now" in ""|*[!0-9]*) now=$(( $(date +%s) * 1000 )) ;; *) now=$(( now / 1000000 )) ;; esac
dkb=$(( TAR_CHECKPOINT * 10 ))
mp=$(( dkb * 1000 / tf )); [ "$mp" -gt 999 ] && mp=999
set -- $(cat "$f" 2>/dev/null)
pmp=${1:-}; ats=${2:-0}; akb=${3:-0}; rate=${4:-0}
case "$ats" in ""|*[!0-9]*) ats=0 ;; esac
case "$akb" in ""|*[!0-9]*) akb=0 ;; esac
case "$rate" in ""|*[!0-9]*) rate=0 ;; esac
[ "$ats" -gt 0 ] || { ats=$now; akb=0; }
if [ "$mp" != "$pmp" ]; then
  el=$(( now - ats )); [ "$el" -lt 0 ] && el=0
  if [ "$el" -ge 4000 ]; then
    rate=$(( (dkb - akb) * 1000 / el )); [ "$rate" -lt 0 ] && rate=0
    ats=$now; akb=$dkb; el=0
  fi
  printf "%s %s %s %s\n" "$mp" "$ats" "$akb" "$rate" > "$f"
  p=$(( mp / 10 ))
  if [ "$rate" -gt 0 ]; then
    rem=$(( tf - dkb )); [ "$rem" -lt 0 ] && rem=0
    eta=$(( rem * 1000 / rate ))
  else
    eta=-1
  fi
  if [ "$rate" -gt 0 ]; then sp=$(( rate / 1024 ))
  elif [ "$el" -gt 0 ]; then sp=$(( (dkb - akb) * 1000 / el / 1024 ))
  else sp=0; fi
  n=$(( p * 20 / 100 )); e=$(( 20 - n ))
  b=$(printf "%*s" "$n" "" | tr " " "#"); s=$(printf "%*s" "$e" "" | tr " " "-")
  dn=$(( dkb * 10 / ${VMCTL_SCALE:-1024} )); tn=$(( tf * 10 / ${VMCTL_SCALE:-1024} ))
  if [ "$eta" -lt 0 ]; then etas="--:--"
  elif [ "$eta" -lt 3600000 ]; then etas=$(printf "%02d:%02d" $(( eta / 60000 )) $(( eta % 60000 / 1000 )))
  else etas=$(printf "%d:%02d:%02d" $(( eta / 3600000 )) $(( eta % 3600000 / 60000 )) $(( eta % 60000 / 1000 ))); fi
  printf "\r  [%s%s] %3d%%  %d.%d/%d.%d%s  %d MB/s  ETA %s " "$b" "$s" "$p" "$(( dn / 10 ))" "$(( dn % 10 ))" "$(( tn / 10 ))" "$(( tn % 10 ))" "${VMCTL_UNIT:-G}" "$sp" "$etas" >&2
fi
SH
}

action_export() {
  local name="$1"
  require_vm_readable "$name" || return
  local vm_dir; vm_dir="$(find_vm_dir "$name")"

  if vm_is_running "$name"; then
    warn "VM '$name' is running. Stop it before exporting (the disk may be inconsistent)."
    return
  fi

  # Pick the archive format: zstd is much faster when available.
  # Override with VMCTL_EXPORT_FORMAT=auto|zst|gz.
  local fmt="${VMCTL_EXPORT_FORMAT:-auto}"
  case "$fmt" in
    auto|"")
      if command -v zstd >/dev/null 2>&1; then fmt=zst; else fmt=gz; fi ;;
    zst|zstd) fmt=zst ;;
    gz|gzip)  fmt=gz ;;
    *) warn "VMCTL_EXPORT_FORMAT must be auto, zst, or gz."; return ;;
  esac
  if [[ "$fmt" == zst ]] && ! command -v zstd >/dev/null 2>&1; then
    warn "zstd is not installed; exporting with gzip instead."
    echo "  Install: $(pkg_install_hint zstd)"
    fmt=gz
  fi

  local default_out; default_out="$(export_default_path "$name" "$fmt")"
  local out=""
  echo
  info "Export VM: $name"
  echo "  Folder:  $(pretty_path "$vm_dir")"
  echo "  Format:  ${fmt} (override: VMCTL_EXPORT_FORMAT=zst|gz)"
  echo "  Default: $(pretty_path "$default_out")"
  read -e -r -p "File or folder [Enter = default]: " out
  out="${out:-$default_out}"
  out="$(resolve_user_path "$out")" || { warn "Invalid path."; return; }

  # A folder keeps the generated name; an explicit .zst/.gz suffix picks
  # the matching format; anything else gets our extension appended.
  if [[ -d "$out" || "$out" == */ ]]; then
    out="${out%/}/$(basename "$default_out")"
  else
    case "${out,,}" in
      *.tar.zst|*.tzst)
        if ! command -v zstd >/dev/null 2>&1; then
          warn "Cannot write a .zst archive: zstd is not installed."
          echo "  Install: $(pkg_install_hint zstd)"
          return
        fi
        fmt=zst
        ;;
      *.tar.gz|*.tgz) fmt=gz ;;
      *) out="${out}.vmctl.tar.${fmt}" ;;
    esac
  fi
  out="$(normalize_path "$out")"
  echo "  Output:  $(pretty_path "$out")"

  case "$out" in
    "$vm_dir"|"$vm_dir"/*)
      warn "Export file cannot be inside the VM folder."
      return
      ;;
    "$VMS_DIR"/*|"$STATE_DIR"/*)
      warn "Export file cannot be inside the VM storage/state folders."
      return
      ;;
    "$DIR"/*)
      warn "Export destination is inside the workspace: $(pretty_path "$DIR")"
      confirm "Write the archive there anyway?" || { warn "Cancelled."; return; }
      ;;
  esac

  local outdir; outdir="$(dirname "$out")"
  if ! mkdir -p -- "$outdir" 2>/dev/null; then
    warn "Cannot create folder: $outdir"
    return
  fi
  if [[ ! -w "$outdir" ]]; then
    warn "Folder is not writable: $outdir"
    echo "  Fix: chmod u+rwx -- \"$outdir\""
    return
  fi

  # Free-space check (compressed archive is usually smaller, but be safe).
  local need_kb
  need_kb="$(du -sk "$vm_dir" 2>/dev/null | awk '{print $1}')"; need_kb="${need_kb:-0}"
  check_space "$outdir" "$need_kb" "export" || { warn "Cancelled."; return; }

  # FAT32 cannot store a single file larger than 4 GB.
  local fstype
  fstype="$(stat -f -c '%T' -- "$outdir" 2>/dev/null || true)"
  if [[ "$fstype" == vfat || "$fstype" == msdos ]] && (( need_kb > 4000000 )); then
    warn "Target is FAT32 ($outdir); one file cannot exceed 4 GB."
    echo "  Choose an ext4/NTFS/exFAT location, or export to \$HOME and copy it."
    return
  fi

  if [[ -f "$out" ]]; then
    confirm "File exists. Overwrite?" || { warn "Cancelled."; return; }
  fi

  # Write to .part first; remove partial files on failure or Ctrl-C.
  local part="$out.part" prog="$out.part.progress"
  rm -f -- "$part" "$prog"
  local cleanup_cmd; cleanup_cmd="rm -f -- $(printf '%q ' "$part" "$prog")"
  trap "$cleanup_cmd" EXIT INT TERM
  info "[1/3] Packing VM '$name'..."

  # Speed: zstd uses all cores; else pigz; else fast gzip.
  # Level override: VMCTL_EXPORT_LEVEL (zstd default 1, gzip default 1).
  local level compressor=""
  if [[ "$fmt" == zst ]]; then
    level="${VMCTL_EXPORT_LEVEL:-1}"
    [[ "$level" =~ ^([1-9]|1[0-9])$ ]] || level=1
    local zjobs="-T0"
    zstd --help 2>&1 | grep -q -- '-T' || zjobs=""
    compressor="zstd $zjobs -$level"
  else
    level="${VMCTL_EXPORT_LEVEL:-1}"
    [[ "$level" =~ ^[1-9]$ ]] || level=1
    if command -v pigz >/dev/null 2>&1; then
      local jobs
      jobs="$(nproc 2>/dev/null || echo 4)"
      [[ "$jobs" =~ ^[0-9]+$ ]] && (( jobs > 0 )) || jobs=4
      compressor="pigz -p $jobs -$level"
    elif command -v gzip >/dev/null 2>&1; then
      compressor="gzip -$level"
      if (( need_kb > 500000 )); then
        info "Tip: install zstd or pigz for much faster exports: $(pkg_install_hint zstd)"
      fi
    fi
  fi

  # Progress: GNU tar reports a checkpoint every N records (10 KB each).
  # Aim for ~100 updates and only redraw when the percentage changes.
  local total_kb cp_interval unit scale
  total_kb="$(du -sk --apparent-size "$vm_dir" 2>/dev/null | awk '{print $1}')"
  [[ -n "$total_kb" ]] || total_kb="$(du -sk "$vm_dir" 2>/dev/null | awk '{print $1}')"
  total_kb="${total_kb:-0}"; (( total_kb > 0 )) || total_kb=1
  cp_interval=$(( total_kb / 1000 )); (( cp_interval < 1 )) && cp_interval=1

  # Show GiB for large VMs and MiB for small ones (avoids "0.0/0.2G").
  if (( total_kb >= 1048576 )); then unit=G; scale=1048576; else unit=M; scale=1024; fi

  # GNU tar sets TAR_CHECKPOINT to the number of 10 KB records processed
  # (not the checkpoint ordinal), so percent = records * 1000 / total_kb.
  #
  # ETA is based on a sliding ~4s window (not the average since start), so a
  # target that slows down mid-export (USB stick, network share, page-cache
  # flushing) shows up within a few seconds instead of lagging minutes behind.
  # Until the first window completes the ETA shows "--:--" instead of guessing.
  # State file: "<deci-percent> <anchor_ms> <anchor_kb> <rate_kb_per_s>"
  local cp_action; cp_action="$(_tar_checkpoint_action)"

  local -a tar_args=(-C "$vm_dir/.." --exclude='*.log' --exclude='*.pid')
  local show_progress=0
  if [[ -t 2 ]] && tar --version 2>/dev/null | grep -q 'GNU tar'; then
    show_progress=1
    tar_args+=(--checkpoint="$cp_interval" --checkpoint-action="exec=$cp_action")
  fi
  if [[ -n "$compressor" ]]; then
    tar_args+=(-I "$compressor")
  elif [[ "$fmt" == gz ]]; then
    tar_args+=(-z)
  else
    rm -f -- "$part" "$prog"
    die "No compressor available for $fmt archive."
  fi
  tar_args+=(-cf "$part" -- "$(basename "$vm_dir")")

  local tar_rc=0
  VMCTL_TOTAL_KB="$total_kb" VMCTL_SCALE="$scale" VMCTL_UNIT="$unit" \
    VMCTL_PROGRESS_FILE="$prog" \
    tar "${tar_args[@]}" || tar_rc=$?
  if (( tar_rc != 0 )); then
    printf '\n' >&2
    rm -f -- "$part" "$prog"
    die "Export failed."
  fi
  rm -f -- "$prog"
  local t10=$(( total_kb * 10 / scale ))
  (( show_progress )) && printf '\r  [####################] 100%%  %d.%d%s total\n' \
    "$(( t10 / 10 ))" "$(( t10 % 10 ))" "$unit" >&2
  if [[ ! -s "$part" ]]; then
    rm -f -- "$part"
    die "Export produced an empty archive."
  fi
  mv -f -- "$part" "$out" || { rm -f -- "$part"; die "Could not write: $out"; }
  trap - EXIT INT TERM
  chmod 600 -- "$out" 2>/dev/null || true

  ok "[2/3] Exported: $(pretty_path "$out")"
  info "[3/3] Size: $(du -h "$out" | awk '{print $1}')"
  info "Bootstrap *.log files were excluded."
}

action_import() {
  local archive=""
  echo
  read -e -r -p "Archive path (.vmctl.tar.zst / .tar.gz): " archive
  [[ -n "$archive" ]] || { warn "No file selected."; return; }
  archive="$(resolve_user_path "$archive")" || { warn "Invalid path."; return; }
  [[ -f "$archive" ]] || { warn "File not found: $(pretty_path "$archive")"; return; }
  [[ -r "$archive" ]] || { warn "File is not readable: $(pretty_path "$archive")"; return; }

  local kind; kind="$(archive_kind "$archive")"
  if [[ "$kind" == zst ]] && ! command -v zstd >/dev/null 2>&1; then
    warn "This archive uses zstd, but zstd is not installed."
    echo "  Install: $(pkg_install_hint zstd)"
    return
  fi

  info "Reading archive index (large archives may take a moment)..."
  # Read member list and uncompressed total in one pass (avoids long silent pause).
  local list totals_file total_kb
  list="$(mktemp "${TMPDIR:-/tmp}/vmctl-import.XXXXXX")" || die "Cannot create a temp file."
  totals_file="$(mktemp "${TMPDIR:-/tmp}/vmctl-import-totals.XXXXXX")" || { rm -f -- "$list"; die "Cannot create a temp file."; }
  if ! archive_list_to "$archive" "$list" "$kind" "$totals_file"; then
    rm -f -- "$list" "$totals_file"
    warn "Not a valid or supported archive: $(pretty_path "$archive")"
    return
  fi
  total_kb="$(cat -- "$totals_file" 2>/dev/null)"; [[ "$total_kb" =~ ^[0-9]+$ ]] || total_kb=0
  rm -f -- "$totals_file"

  local rc=0
  _import_from_list "$archive" "$list" "$kind" "$total_kb" || rc=$?
  rm -f -- "$list"
  return "$rc"
}

# Internal: do the import using an already-read member list.
_import_from_list() {
  local archive="$1" list="$2" kind="${3:-gz}" total_kb_in="${4:-0}"
  local unsafe top
  unsafe="$(awk '/^\// || /(^|\/)\.\.(\/|$)/ { print; exit }' "$list")"
  if [[ -n "$unsafe" ]]; then
    warn "Refusing unsafe archive entry: $unsafe"
    return
  fi

  top="$(sed -n '1p' "$list" | sed 's#^\./##' | cut -d/ -f1)"
  [[ -n "$top" && "$top" != "." ]] || { warn "Archive has no VM folder."; return; }

  # Duplicate names are never overwritten: the user must pick a new name.
  local default_name name input existing prompt
  default_name="$(sanitize_name "$top")"
  while true; do
    if [[ -n "$default_name" ]]; then prompt="VM name [$default_name]: "; else prompt="VM name: "; fi
    read -e -r -p "$prompt" input
    name="$(sanitize_name "${input:-$default_name}")"
    validate_vm_name "$name" || continue
    existing="$(find_vm_dir "$name" 2>/dev/null || true)"
    if [[ -z "$existing" ]]; then break; fi
    warn "VM name already exists: $(pretty_path "$existing")"
    warn "Please choose a different name (import never overwrites)."
    default_name=""
  done

  # Destination folder (default: <VM root>/<name>, or any empty folder).
  local dest
  while true; do
    choose_vm_dest "$VMS_DIR/$name" || continue
    dest="$VM_DEST"
    break
  done

  local arch_kb total_kb
  arch_kb="$(du -sk "$archive" 2>/dev/null | awk '{print $1}')"; arch_kb="${arch_kb:-0}"
  if [[ "$total_kb_in" =~ ^[0-9]+$ ]] && (( total_kb_in > 0 )); then
    total_kb="$total_kb_in"
  else
    total_kb="$(archive_total_kb "$archive" "$kind")"; [[ "$total_kb" =~ ^[0-9]+$ ]] || total_kb=0
  fi
  # Space: prefer real uncompressed size when known, else compressed * 2.
  local need_kb="$(( arch_kb * 2 + 1024 ))"
  (( total_kb > 0 )) && need_kb="$(( total_kb + arch_kb + 1024 ))"
  check_space "$(dirname "$dest")" "$need_kb" "import" || { warn "Cancelled."; return; }
  if (( total_kb > 0 )); then
    local comp_mb=$(( arch_kb / 1024 )) uncomp_mb=$(( total_kb / 1024 ))
    info "Archive: $(pretty_path "$archive") (${comp_mb} MB compressed, ${uncomp_mb} MB uncompressed)"
  else
    info "Archive: $(pretty_path "$archive") ($(( arch_kb / 1024 )) MB compressed)"
  fi

  local parent; parent="$(dirname "$dest")"
  local tmpdir; tmpdir="$(mktemp -d "$parent/.vmctl-import.XXXXXX")" || die "Cannot create temp folder in $parent"
  trap "rm -rf -- '$tmpdir'" EXIT INT TERM
  local prog="$tmpdir/.vmctl-progress"
  info "[1/3] Extracting archive..."

  local -a tar_cmd
  case "$kind" in
    gz)    tar_cmd=(-xzf "$archive" -C "$tmpdir") ;;
    zst)   tar_cmd=(-I zstd -xf "$archive" -C "$tmpdir") ;;
    xz)    tar_cmd=(-xJf "$archive" -C "$tmpdir") ;;
    bz2)   tar_cmd=(-xjf "$archive" -C "$tmpdir") ;;
    plain) tar_cmd=(-xf "$archive" -C "$tmpdir") ;;
    *) rm -rf -- "$tmpdir"; die "Unsupported archive type: $kind" ;;
  esac

  local show_progress=0 tar_rc=0 unit=M scale=1024
  if (( total_kb >= 1048576 )); then unit=G; scale=1048576; else unit=M; scale=1024; fi
  if (( total_kb > 0 )) && [[ -t 2 ]] && tar --version 2>/dev/null | grep -q 'GNU tar'; then
    show_progress=1
    local cp_interval cp_action
    cp_interval=$(( total_kb / 1000 )); (( cp_interval < 1 )) && cp_interval=1
    cp_action="$(_tar_checkpoint_action)"
    : > "$prog"
    VMCTL_TOTAL_KB="$total_kb" VMCTL_SCALE="$scale" VMCTL_UNIT="$unit" \
      VMCTL_PROGRESS_FILE="$prog" \
      tar "${tar_cmd[@]}" --no-same-owner --checkpoint="$cp_interval" --checkpoint-action="exec=$cp_action" \
      || tar_rc=$?
    if (( tar_rc != 0 )); then
      tar_rc=0
      : > "$prog"
      VMCTL_TOTAL_KB="$total_kb" VMCTL_SCALE="$scale" VMCTL_UNIT="$unit" \
        VMCTL_PROGRESS_FILE="$prog" \
        tar "${tar_cmd[@]}" --checkpoint="$cp_interval" --checkpoint-action="exec=$cp_action" \
        || tar_rc=$?
    fi
  else
    tar "${tar_cmd[@]}" --no-same-owner 2>/dev/null || tar "${tar_cmd[@]}" 2>/dev/null || tar_rc=$?
  fi

  if (( tar_rc != 0 )); then
    (( show_progress )) && printf '\n' >&2
    rm -rf -- "$tmpdir"
    die "Extraction failed: $(pretty_path "$archive")"
  fi
  if (( show_progress )); then
    local t10=$(( total_kb * 10 / ${scale:-1024} ))
    printf '\r  [####################] 100%%  %d.%d%s total\n' \
      "$(( t10 / 10 ))" "$(( t10 % 10 ))" "${unit:-M}" >&2
  fi
  rm -f -- "$prog"

  local src=""
  if [[ -d "$tmpdir/$top" ]]; then
    src="$tmpdir/$top"
  elif [[ -f "$tmpdir/disk.qcow2" ]]; then
    src="$tmpdir"
  else
    rm -rf -- "$tmpdir"
    warn "Archive does not contain a VM folder."
    return
  fi

  if [[ ! -f "$src/disk.qcow2" && ! -f "$src/ports.conf" && ! -d "$src/bootstrap" ]]; then
    rm -rf -- "$tmpdir"
    warn "Archive does not look like a vmctl VM (no disk.qcow2/ports.conf/bootstrap)."
    return
  fi

  # The destination may exist as an empty folder (validated earlier).
  if [[ -d "$dest" ]]; then
    if ! rmdir -- "$dest" 2>/dev/null; then
      rm -rf -- "$tmpdir"
      warn "Destination is not empty: $dest"
      return
    fi
  fi

  info "[2/3] Importing as '$name'..."
  if ! mv -- "$src" "$dest"; then
    rm -rf -- "$tmpdir"
    die "Could not move imported files into place."
  fi
  rm -rf -- "$tmpdir"
  chmod -R u+rwX,go-rwx -- "$dest" 2>/dev/null || true
  if ! registry_register "$name" "$dest"; then
    rm -rf -- "$dest"
    die "Could not register imported VM."
  fi
  ensure_ports_file "$name" || true

  ok "[3/3] Imported: $name"
  echo "  Folder: $(pretty_path "$dest")"
  if [[ ! -f "$dest/disk.qcow2" ]]; then
    warn "No disk.qcow2 in this archive. Use Install / Reinstall to create one."
  fi
  trap - EXIT INT TERM
}

action_delete() {
  local name="$1" vm_dir parent
  vm_dir="$(find_vm_dir "$name" 2>/dev/null || true)"
  if [[ -z "$vm_dir" ]]; then
    if registry_lookup "$name" >/dev/null 2>&1; then
      registry_unregister "$name" && ok "Removed stale registry entry: $name"
    else
      warn "VM not found: $name"
    fi
    return
  fi
  if vm_is_running "$name"; then
    warn "VM '$name' is running. Stop it before deleting."
    return
  fi
  if [[ ! -O "$vm_dir" ]]; then
    warn "VM folder is not owned by you: $vm_dir"
    echo "  Fix: $(perm_chown_cmd "$vm_dir")"
    return
  fi
  parent="$(dirname "$vm_dir")"
  if [[ ! -w "$parent" || ! -x "$parent" ]]; then
    warn "Parent folder is not writable: $parent"
    echo "  Fix: chmod u+rwx -- \"$parent\""
    return
  fi

  echo
  echo "${C_RED}WARNING:${C_RST} This will permanently delete VM '$name' at:"
  echo "  $vm_dir"
  confirm_exact "Type ${C_RED}DELETE${C_RST} to confirm: " "DELETE" || { warn "Cancelled."; return; }
  if ! rm -rf -- "$vm_dir"; then
    warn "Could not delete: $vm_dir"
    return
  fi
  registry_unregister "$name" || true
  ok "VM '$name' deleted."
}

action_new() {
  local name existing
  while true; do
    name="$(pick_name)"
    [[ -n "$name" ]] || { warn "Cancelled (no name entered)."; return; }
    validate_vm_name "$name" || continue
    existing="$(find_vm_dir "$name" 2>/dev/null || true)"
    if [[ -z "$existing" ]]; then break; fi
    warn "VM name '$name' already exists: $(pretty_path "$existing")"
    warn "Please choose a different name."
  done

  local dest
  while true; do
    choose_vm_dest "$VMS_DIR/$name" || continue
    dest="$VM_DEST"
    break
  done

  check_space "$(dirname "$dest")" $(( 5 * 1024 * 1024 )) "VM installation" || { warn "Cancelled."; return; }

  if ! ensure_dir_private "$dest"; then
    warn "Cannot create VM folder: $dest"
    echo "  Fix: $(perm_chown_cmd "$(dirname "$dest")")"
    return
  fi
  if ! registry_register "$name" "$dest"; then
    rmdir -- "$dest" 2>/dev/null || true
    die "Could not register VM '$name'."
  fi
  ensure_ports_file "$name" || true

  ok "Created VM: $name"
  info "Folder: $(pretty_path "$dest")"
  if confirm "Start install now?"; then action_install "$name"; else vm_menu "$name"; fi
}

vm_menu() {
  local name="$1" dir
  dir="$(find_vm_dir "$name" 2>/dev/null || true)"
  [[ -n "$dir" ]] || { warn "VM not found: $name"; return; }
  while true; do
    local action
    action="$(pick_vm_action "$name")"
    case "$action" in
      Run) action_run "$name" ;;
      "Install / Reinstall (from ISO)") action_install "$name" ;;
      "Resize disk") action_resize "$name" ;;
      "Port forwards") action_ports "$name" ;;
      "Bootstrap") action_bootstrap "$name" ;;
      "VM Settings") action_vm_settings "$name" ;;
      "Export VM") action_export "$name" ;;
      "Delete VM") action_delete "$name"; return ;;
      Back|"") return ;;
      *) warn "Unknown action." ;;
    esac
  done
}
