#!/usr/bin/env bash
# ports.sh - per-VM QEMU user-network port forwards

ports_file() {
  local d; d="$(vm_dir_of "$1")"
  printf '%s/ports.conf' "$d"
}

# Create ports config if missing (no default forwards)
ensure_ports_file() {
  local f dir
  f="$(ports_file "$1")"
  dir="$(dirname "$f")"
  if [[ ! -f "$f" ]]; then
    if ! printf '# proto bind_host host_port guest_port\n' > "$f" 2>/dev/null; then
      warn "Cannot write $f (permission issue)."
      echo "  Fix: $(perm_chown_cmd "$dir")"
      return 1
    fi
    chmod 600 -- "$f" 2>/dev/null || true
  fi
  return 0
}

# Build QEMU -nic user,... argument including hostfwd rules
nic_arg() {
  local name="$1" f line proto bind hp gp arg="user,model=e1000"
  f="$(ports_file "$name")"
  ensure_ports_file "$name" >&2 || true
  if [[ ! -r "$f" ]]; then
    warn "Ports file is not readable, starting without forwards: $f"
    printf '%s' "$arg"
    return 0
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [[ -z "$line" ]] && continue
    proto="" bind="" hp="" gp=""
    read -r proto bind hp gp <<<"$line"
    [[ -n "$proto" && -n "$bind" && -n "$hp" && -n "$gp" ]] || continue
    arg+=",hostfwd=${proto}:${bind}:${hp}-:${gp}"
  done < "$f"
  printf '%s' "$arg"
}

# --- Internal helpers ---
ports_read_entries() {
  local f="$1"
  [[ -r "$f" ]] || return 0
  local line c
  while IFS= read -r line || [[ -n "$line" ]]; do
    c="${line%%#*}"; c="$(echo "$c" | xargs)"
    [[ -z "$c" ]] || printf '%s\n' "$c"
  done < "$f"
  return 0
}

ports_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

ports_print_entries() {
  local -a entries=("$@")
  if (( ${#entries[@]} == 0 )); then echo "  (none)"; return; fi
  local i=1 e
  for e in "${entries[@]}"; do printf '  %d) %s  (proto bind host_port guest_port)\n' "$i" "$e"; i=$((i+1)); done
}

ports_add() {
  local f="$1" proto hp gp bind="127.0.0.1"
  read -r -p "Protocol (tcp/udp) [tcp]: " proto; proto="${proto:-tcp}"; proto="${proto,,}"
  [[ "$proto" == tcp || "$proto" == udp ]] || { warn "Protocol must be tcp or udp."; return; }
  read -r -p "Port: " hp
  read -r -p "Guest port [${hp}]: " gp; gp="${gp:-$hp}"
  ports_valid_port "$hp" && ports_valid_port "$gp" || { warn "Ports must be numbers between 1 and 65535."; return; }
  local entry="$proto $bind $hp $gp"
  grep -qxF -- "$entry" "$f" 2>/dev/null && { warn "This forward already exists."; return; }
  printf '%s\n' "$entry" >> "$f"
  ok "Added: $proto $bind $hp -> $gp (restart VM to apply)"
}

ports_remove() {
  local f="$1"; shift
  local -a entries=("$@")
  (( ${#entries[@]} )) || { warn "No entries."; return; }
  local pick
  pick="$(menu_pick "Remove> " "Select forward to remove" "40%" "${entries[@]}")"
  [[ -n "$pick" ]] || return
  local tmp removed=0 line c
  tmp="$(mktemp)" || { warn "Cannot create temp file."; return; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    c="${line%%#*}"; c="$(echo "$c" | xargs)"
    if [[ "$removed" -eq 0 && "$c" == "$pick" ]]; then removed=1; continue; fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$f"
  mv -f -- "$tmp" "$f"
  chmod 600 -- "$f" 2>/dev/null || true
  ok "Removed: $pick"
}

# Interactive port forward manager
action_ports() {
  local name="$1" f
  f="$(ports_file "$name")"
  ensure_ports_file "$name" || true
  [[ -w "$f" ]] || { warn "Ports file is not writable: $f"; echo "  Fix: chmod u+rw -- \"$f\""; return; }

  while true; do
    echo
    info "Port forwards for '$name' ($f)"
    local -a entries=()
    while IFS= read -r e; do [[ -n "$e" ]] && entries+=("$e"); done < <(ports_read_entries "$f")
    ports_print_entries "${entries[@]}"

    local choice
    choice="$(menu_pick "Ports> " "Port forwards: $name" "40%" "Add" "Remove" "Back")"
    case "$choice" in
      Add)    ports_add "$f" ;;
      Remove) ports_remove "$f" "${entries[@]}" ;;
      Back|"") return ;;
    esac
  done
}
