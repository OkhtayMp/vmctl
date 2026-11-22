#!/usr/bin/env bash
# permissions.sh - ownership/mode checks, safe defaults, and the fix menu
#
# Rules:
#   - VM folders: 700 (owner only)
#   - VM files:   600 (disks, ports, logs); scripts keep their exec bit
#   - Registry:   600 inside a 700 state folder
# vmctl never silently chowns files. If something is owned by root it prints
# the exact sudo command, and offers to run it from the permissions menu.

# Exact copy/paste fix command for a foreign-owned path.
perm_chown_cmd() {
  printf 'sudo chown -R %s:%s -- %q' "$(id -u)" "$(id -g)" "$1"
}

# mkdir -p with private permissions (only when we own the folder).
ensure_dir_private() {
  local p="$1"
  mkdir -p -- "$p" 2>/dev/null || return 1
  [[ -O "$p" ]] && chmod 700 -- "$p" 2>/dev/null || true
  return 0
}

# Check that a folder exists, is owned by us, and is writable.
require_dir_writable() {
  local p="$1" label="${2:-Folder}"
  if [[ ! -d "$p" ]]; then
    warn "$label does not exist: $p"
    return 1
  fi
  if [[ ! -O "$p" ]]; then
    warn "$label is not owned by you: $p"
    echo "  Fix: $(perm_chown_cmd "$p")"
    return 1
  fi
  if [[ ! -w "$p" || ! -x "$p" ]]; then
    warn "$label is not writable: $p"
    echo "  Fix: chmod u+rwx -- \"$p\""
    return 1
  fi
  return 0
}

# VM folder must exist and be readable (export, disk info).
require_vm_readable() {
  local name="$1" dir
  dir="$(find_vm_dir "$name" 2>/dev/null || true)"
  if [[ -z "$dir" ]]; then
    warn "VM not found: $name"
    return 1
  fi
  if [[ ! -O "$dir" ]]; then
    warn "VM folder is not owned by you: $dir"
    echo "  Fix: $(perm_chown_cmd "$dir")"
    return 1
  fi
  if [[ ! -r "$dir" || ! -x "$dir" ]]; then
    warn "VM folder is not readable: $dir"
    echo "  Fix: chmod u+rx -- \"$dir\""
    return 1
  fi
  return 0
}

# VM folder must exist and be writable (ports/bootstrap/delete/install).
require_vm_dir_writable() {
  local name="$1" dir
  require_vm_readable "$name" || return 1
  dir="$(find_vm_dir "$name")"
  if [[ ! -w "$dir" ]]; then
    warn "VM folder is not writable: $dir"
    echo "  Fix: chmod u+rwx -- \"$dir\""
    return 1
  fi
  return 0
}

# VM folder and disk must be writable (run/resize).
require_vm_writable() {
  local name="$1" disk
  require_vm_dir_writable "$name" || return 1
  disk="$(vm_disk "$name")"
  if [[ -f "$disk" && ! -w "$disk" ]]; then
    warn "VM disk is not writable: $disk"
    echo "  Fix: chmod u+rw -- \"$disk\""
    return 1
  fi
  return 0
}

_perm_add() { local cur="$1" add="$2"; [[ "$cur" == ok ]] && printf '%s' "$add" || printf '%s,%s' "$cur" "$add"; }

# Short status label used by the permissions menu.
vm_perm_label() {
  local name="$1" dir label="ok"
  dir="$(vm_dir_of "$name")"
  [[ -d "$dir" ]] || { printf 'missing'; return 0; }
  if [[ ! -O "$dir" ]]; then label="not-owned"
  elif [[ ! -w "$dir" || ! -x "$dir" ]]; then label="folder-read-only"; fi
  [[ -f "$dir/disk.qcow2" && ! -w "$dir/disk.qcow2" ]] && label="$(_perm_add "$label" disk-read-only)"
  [[ -f "$dir/ports.conf" && ! -w "$dir/ports.conf" ]] && label="$(_perm_add "$label" ports-read-only)"
  [[ -f "$dir/vm.conf" && ! -w "$dir/vm.conf" ]] && label="$(_perm_add "$label" vmconf-read-only)"
  [[ -f "$dir/display.conf" && ! -w "$dir/display.conf" ]] && label="$(_perm_add "$label" display-read-only)"
  printf '%s' "$label"
}

# Startup check: report problems with exact fixes, but never modify anything.
check_permissions() {
  local issues=0 name dir
  if [[ ! -O "$STATE_DIR" ]]; then
    warn "State folder is not owned by you: $STATE_DIR"
    echo "  Fix: $(perm_chown_cmd "$STATE_DIR")"
    issues=1
  elif [[ ! -w "$STATE_DIR" || ! -x "$STATE_DIR" ]]; then
    warn "State folder is not writable: $STATE_DIR"
    echo "  Fix: chmod u+rwx -- \"$STATE_DIR\""
    issues=1
  fi
  if [[ ! -O "$VMS_DIR" ]]; then
    warn "VM root is not owned by you: $VMS_DIR"
    echo "  Fix: $(perm_chown_cmd "$VMS_DIR")"
    issues=1
  elif [[ ! -w "$VMS_DIR" || ! -x "$VMS_DIR" ]]; then
    warn "VM root is not writable: $VMS_DIR"
    echo "  Fix: chmod u+rwx -- \"$VMS_DIR\""
    issues=1
  fi
  while IFS= read -r name; do
    dir="$(vm_dir_of "$name")"
    [[ -d "$dir" ]] || continue
    if [[ ! -O "$dir" ]]; then
      warn "VM '$name' is not owned by you: $dir"
      echo "  Fix: $(perm_chown_cmd "$dir")"
      issues=1
    elif [[ ! -w "$dir" || ! -x "$dir" ]]; then
      warn "VM '$name' folder is not writable: $dir"
      echo "  Fix: chmod u+rwx -- \"$dir\""
      issues=1
    fi
  done < <(list_vms | sort)
  local n p
  while IFS=$'\t' read -r n p; do
    [[ -z "$n" || -z "$p" ]] && continue
    if [[ ! -d "$p" ]]; then
      warn "VM '$n' folder is missing: $p"
      issues=1
    fi
  done < <(_registry_entries)
  if (( issues )); then
    echo "  Tip: choose 'Permissions check' in the main menu to review and fix."
  fi
}

perms_fix_modes() {
  local fixed=0 name dir path mode
  for path in "$STATE_DIR" "$VMS_DIR"; do
    [[ -e "$path" && -O "$path" ]] && chmod 700 -- "$path" 2>/dev/null && fixed=1
  done
  for path in "$REGISTRY" "$STATE_DIR/settings.conf"; do
    [[ -f "$path" && -O "$path" ]] && chmod 600 -- "$path" 2>/dev/null && fixed=1
  done
  while IFS= read -r name; do
    dir="$(vm_dir_of "$name")"
    [[ -d "$dir" && -O "$dir" ]] || continue
    chmod -R u+rwX,go-rwx -- "$dir" 2>/dev/null && fixed=1 || warn "Could not chmod: $dir"
  done < <(list_vms | sort)
  (( fixed )) && ok "Modes updated (folders 700, files 600, scripts keep +x)." || warn "Nothing to change."
}

perms_fix_ownership() {
  local -a foreign=() dir name
  for dir in "$STATE_DIR" "$VMS_DIR"; do [[ -e "$dir" && ! -O "$dir" ]] && foreign+=("$dir"); done
  while IFS= read -r name; do
    dir="$(vm_dir_of "$name")"
    [[ -d "$dir" && ! -O "$dir" ]] && foreign+=("$dir")
  done < <(list_vms | sort)
  (( ${#foreign[@]} )) || { ok "Nothing is owned by another user."; return; }
  echo "  Command:"
  printf '    sudo chown -R %s:%s --' "$(id -u)" "$(id -g)"
  printf ' %q' "${foreign[@]}"; echo
  if confirm "Run this now with sudo?"; then
    sudo chown -R "$(id -u):$(id -g)" -- "${foreign[@]}" && ok "Ownership fixed." || warn "chown failed. Run the command manually."
  fi
}

# Interactive permission review/fix.
action_permissions() {
  local -a acts=("Fix modes (chmod)" "Show / run sudo chown" "Back")
  while true; do
    echo
    info "Permissions check"
    echo "  Workspace: $(pretty_path "$DIR")"
    echo "  State:     $(pretty_path "$STATE_DIR")"

    local name dir label issues=0
    while IFS= read -r name; do
      dir="$(vm_dir_of "$name")"
      label="$(vm_perm_label "$name")"
      printf '  %-28s %-30s %s\n' "$name" "[$label]" "$(pretty_path "$dir")"
      [[ "$label" == ok ]] || issues=1
    done < <(list_vms | sort)
    if (( issues == 0 )); then
      ok "All VM folders look good."
    else
      warn "Some items need attention."
    fi

    local choice
    choice="$(menu_pick "Permissions> " "Fix modes or ownership" "30%" "${acts[@]}")"

    case "$choice" in
      "Fix modes (chmod)")     perms_fix_modes ;;
      "Show / run sudo chown") perms_fix_ownership ;;
      Back|"") return ;;
    esac
  done
}
