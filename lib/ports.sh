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

# Check whether a TCP/UDP port is already bound on host:port.
# Returns 0 if in use, 1 if free, 2 if cannot check.
port_in_use() {
  local bind="$1" port="$2" proto="${3:-tcp}"
  if command -v python3 >/dev/null 2>&1; then
    local rc=0
    python3 - "$bind" "$port" "$proto" <<'PY' >/dev/null 2>&1 || rc=$?
import socket, sys
bind, port, proto = sys.argv[1], int(sys.argv[2]), sys.argv[3].lower()
family = socket.AF_INET6 if ':' in bind else socket.AF_INET
stype = socket.SOCK_DGRAM if proto == 'udp' else socket.SOCK_STREAM
s = socket.socket(family, stype)
try:
    if proto != 'udp':
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 0)
    addr = (bind, port, 0, 0) if family == socket.AF_INET6 else (bind, port)
    s.bind(addr)
except OSError:
    sys.exit(0)
finally:
    s.close()
sys.exit(1)
PY
    [[ $rc -eq 0 || $rc -eq 1 ]] && return "$rc"
  fi
  if command -v ss >/dev/null 2>&1; then
    local flag="-ltnH"
    [[ "$proto" == udp ]] && flag="-lunH"
    if ss $flag "sport = :$port" 2>/dev/null | awk '{print $4}' | grep -Fq "${bind}:${port}"; then
      return 0
    fi
    if [[ "$bind" == "0.0.0.0" || "$bind" == "::" ]] && ss $flag "sport = :$port" 2>/dev/null | grep -q .; then
      return 0
    fi
    return 1
  fi
  return 2
}

ports_host_conflict() {
  local f="$1" proto="$2" bind="$3" hp="$4"
  local line c p b h g
  while IFS= read -r line; do
    c="${line%%#*}"; c="$(echo "$c" | xargs)"
    [[ -z "$c" ]] && continue
    read -r p b h g <<<"$c"
    if [[ "$p" == "$proto" && "$b" == "$bind" && "$h" == "$hp" ]]; then
      printf '%s' "$c"
      return 0
    fi
  done < <(ports_read_entries "$f")
  return 1
}

port_in_use_details() {
  local bind="$1" port="$2" proto="${3:-tcp}"
  command -v ss >/dev/null 2>&1 || return 0
  local flag="-ltnp"
  [[ "$proto" == udp ]] && flag="-lunp"
  ss $flag "sport = :$port" 2>/dev/null | awk 'NR>1 {print}' | head -n 3 || true
}

# Preflight: verify configured hostfwd ports can be bound.
# Prints errors and returns 1 if any conflict is found.
ports_preflight() {
  local name="$1" f line c proto bind hp gp rc ok=0
  local -A seen=()
  f="$(ports_file "$name")"
  [[ -r "$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    c="${line%%#*}"; c="$(echo "$c" | xargs)"
    [[ -z "$c" ]] && continue
    proto="" bind="" hp="" gp=""
    read -r proto bind hp gp <<<"$c"
    [[ -n "$proto" && -n "$bind" && -n "$hp" && -n "$gp" ]] || continue
    local key="${proto}|${bind}|${hp}"
    if [[ -n "${seen[$key]+x}" ]]; then
      warn "Duplicate host forward in ports.conf: ${proto} ${bind}:${hp} (already used by: ${seen[$key]})"
      echo "  Fix: remove the duplicate in 'Port forwards' ($f)." >&2
      ok=1
      continue
    fi
    seen[$key]="${proto} ${bind}:${hp} -> ${gp}"
    rc=0; port_in_use "$bind" "$hp" "$proto" || rc=$?
    if [[ $rc -eq 0 ]]; then
      warn "Host port already in use: ${proto} ${bind}:${hp} -> guest :${gp}"
      local details
      details="$(port_in_use_details "$bind" "$hp" "$proto")" || details=""
      [[ -n "$details" ]] && echo "$details" | sed 's/^/  /' >&2
      echo "  Fix: stop the process using that port, or remove/change the forward in 'Port forwards'." >&2
      ok=1
    elif [[ $rc -eq 2 ]]; then
      warn "Cannot verify host port availability (need python3 or ss): ${proto} ${bind}:${hp}"
    fi
  done < "$f"
  return "$ok"
}

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
  read -r -p "Host port: " hp
  read -r -p "Guest port [${hp}]: " gp; gp="${gp:-$hp}"
  ports_valid_port "$hp" && ports_valid_port "$gp" || { warn "Ports must be numbers between 1 and 65535."; return; }
  local entry="$proto $bind $hp $gp"
  grep -qxF -- "$entry" "$f" 2>/dev/null && { warn "This forward already exists."; return; }
  local conflict
  conflict="$(ports_host_conflict "$f" "$proto" "$bind" "$hp")" || true
  if [[ -n "$conflict" ]]; then
    warn "Host ${proto} ${bind}:${hp} is already forwarded by: $conflict"
    echo "  Remove/change the existing forward first." >&2
    return
  fi
  local rc=0
  port_in_use "$bind" "$hp" "$proto" || rc=$?
  if [[ $rc -eq 0 ]]; then
    warn "Host ${proto} ${bind}:${hp} is currently in use."
    port_in_use_details "$bind" "$hp" "$proto" | sed 's/^/  /' >&2 || true
    confirm "Add this forward anyway?" || return
  elif [[ $rc -eq 2 ]]; then
    warn "Cannot verify whether ${proto} ${bind}:${hp} is free (need python3 or ss)."
  fi
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
