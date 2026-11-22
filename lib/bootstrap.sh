#!/usr/bin/env bash
# bootstrap.sh - per-VM host bootstrap scripts (auto-run on VM start, stop on VM close)

BOOTSTRAP_PIDS=()

bootstrap_dir() {
  local d; d="$(vm_dir_of "$1")"
  printf '%s/bootstrap' "$d"
}

# Pick an editor for script editing
pick_editor() {
  if [[ -n "${EDITOR:-}" ]] && command -v "$EDITOR" >/dev/null 2>&1; then echo "$EDITOR"; return; fi
  if command -v nano >/dev/null 2>&1; then echo "nano"; return; fi
  if command -v vim  >/dev/null 2>&1; then echo "vim";  return; fi
  if command -v vi   >/dev/null 2>&1; then echo "vi";   return; fi
  echo ""
}

# Ensure a selected script belongs to us before edit/run/toggle/delete.
require_script_owned() {
  local f="$1"
  if [[ ! -O "$f" ]]; then
    warn "Script is not owned by you: $f"
    echo "  Fix: $(perm_chown_cmd "$f")"
    return 1
  fi
  return 0
}

# Start enabled bootstrap scripts in background
run_bootstraps() {
  local name="$1" dir
  dir="$(bootstrap_dir "$name")"
  [[ -d "$dir" ]] || return 0
  local -a scripts=()
  while IFS= read -r s; do scripts+=("$s"); done < <(find "$dir" -maxdepth 1 -type f -name '*.sh' | sort)
  (( ${#scripts[@]} == 0 )) && return 0
  info "Running bootstrap scripts..."
  local s
  for s in "${scripts[@]}"; do
    local base logf pid
    base="$(basename "$s")"
    logf="$dir/${base%.sh}.log"
    if [[ ! -r "$s" ]]; then
      warn "Bootstrap not readable, skipped: $base"; continue
    fi
    if [[ ! -O "$s" ]]; then
      warn "Bootstrap not owned by you, skipped: $base"
      echo "  Fix: $(perm_chown_cmd "$s")"
      continue
    fi
    if ! ( : > "$logf" ) 2>/dev/null; then
      logf="/tmp/vmctl-${name}-${base%.sh}.log"
      : > "$logf" 2>/dev/null || logf="/dev/null"
      warn "Bootstrap log not writable, using: $logf"
    fi
    chmod 600 -- "$logf" 2>/dev/null || true
    # Own process group so cleanup can stop child processes too.
    if command -v setsid >/dev/null 2>&1; then
      setsid bash "$s" >"$logf" 2>&1 &
    else
      nohup bash "$s" >"$logf" 2>&1 &
    fi
    pid=$!
    BOOTSTRAP_PIDS+=("$pid")
    ok "Bootstrap started: $base (pid $pid, log: $logf)"
  done
}

# Stop all bootstrap scripts started for this VM run, including children.
cleanup_bootstraps() {
  local pid
  (( ${#BOOTSTRAP_PIDS[@]} == 0 )) && return 0
  info "Stopping bootstrap scripts..."
  for pid in "${BOOTSTRAP_PIDS[@]}"; do
    if kill -0 -- "-$pid" 2>/dev/null; then
      kill -TERM -- "-$pid" 2>/dev/null || true
    else
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
  sleep 0.2
  for pid in "${BOOTSTRAP_PIDS[@]}"; do
    if kill -0 -- "-$pid" 2>/dev/null; then
      kill -KILL -- "-$pid" 2>/dev/null || true
    else
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
  for pid in "${BOOTSTRAP_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
  BOOTSTRAP_PIDS=()
}

# --- Internal helpers for bootstrap menu ---
bootstrap_list() {
  local dir="$1"
  find "$dir" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.sh.disabled' \) -print 2>/dev/null | sed 's#.*/##' | sort
}

bootstrap_require_writable() {
  local dir="$1"
  [[ -w "$dir" ]] && return 0
  warn "Directory not writable: $dir"
  echo "  Fix: $(perm_chown_cmd "$dir")"
  return 1
}

bootstrap_pick_script() {
  local prompt="$1" header="$2" dir="$3"; shift 3
  local -a scripts=("$@")
  (( ${#scripts[@]} )) || { warn "No scripts."; return 1; }
  local pick
  pick="$(menu_pick "$prompt" "$header" "40%" "${scripts[@]}")"
  [[ -n "$pick" ]] || return 1
  require_script_owned "$dir/$pick" || return 1
  printf '%s' "$pick"
}

bootstrap_print_list() {
  local -a scripts=("$@")
  if (( ${#scripts[@]} == 0 )); then echo "  (none)"; return; fi
  local i=1 s label
  for s in "${scripts[@]}"; do
    label="$s"; [[ "$s" == *.disabled ]] && label="${s%.disabled} [disabled]" || label="$s [enabled]"
    printf '  %d) %s\n' "$i" "$label"
    i=$((i+1))
  done
}

# Interactive bootstrap manager
action_bootstrap() {
  local name="$1" dir
  dir="$(bootstrap_dir "$name")"
  if ! ensure_dir_private "$dir"; then
    warn "Cannot create bootstrap folder: $dir"
    echo "  Fix: $(perm_chown_cmd "$(vm_dir_of "$name")")"
    return
  fi

  while true; do
    echo
    info "Bootstrap scripts for '$name' ($dir)"
    local -a scripts=()
    while IFS= read -r s; do [[ -n "$s" ]] && scripts+=("$s"); done < <(bootstrap_list "$dir")
    bootstrap_print_list "${scripts[@]}"

    local choice
    choice="$(menu_pick "Bootstrap> " "Bootstrap: $name" "40%" "Add" "Edit" "Run now" "Enable/Disable" "Delete" "Back")"

    case "$choice" in
      Add)
        local bname file ed
        read -r -p "Bootstrap name: " bname
        bname="$(sanitize_name "$bname")"
        [[ -n "$bname" ]] || { warn "Empty name."; continue; }
        file="$dir/${bname}.sh"
        [[ -f "$file" ]] && { warn "Already exists: $file"; continue; }
        bootstrap_require_writable "$dir" || continue
        cat > "$file" <<'SCRIPT' || { warn "Could not create file: $file"; continue; }
#!/usr/bin/env bash
set -euo pipefail

# Write your bootstrap commands here

SCRIPT
        chmod 700 -- "$file" 2>/dev/null || true
        ed="$(pick_editor)"
        if [[ -n "$ed" ]]; then "$ed" "$file"; ok "Saved: $file"; else warn "No editor found. File created: $file"; fi
        ;;
      Edit)
        local pick ed
        pick="$(bootstrap_pick_script "Edit> " "Select script to edit" "$dir" "${scripts[@]}")" || continue
        ed="$(pick_editor)"; [[ -n "$ed" ]] || { warn "No editor found."; continue; }
        "$ed" "$dir/$pick"; ok "Saved: $dir/$pick"
        ;;
      "Run now")
        local pick
        pick="$(bootstrap_pick_script "Run> " "Select script to run" "$dir" "${scripts[@]}")" || continue
        info "Running $pick ..."
        if bash "$dir/$pick"; then ok "Done: $pick"; else warn "Script exited with error: $pick"; fi
        ;;
      "Enable/Disable")
        local pick
        pick="$(bootstrap_pick_script "Toggle> " "Select script to enable/disable" "$dir" "${scripts[@]}")" || continue
        bootstrap_require_writable "$dir" || continue
        if [[ "$pick" == *.disabled ]]; then
          mv -- "$dir/$pick" "$dir/${pick%.disabled}"; ok "Enabled: ${pick%.disabled}"
        else
          mv -- "$dir/$pick" "$dir/$pick.disabled"; ok "Disabled: $pick"
        fi
        ;;
      Delete)
        local pick
        pick="$(bootstrap_pick_script "Delete> " "Select script to delete" "$dir" "${scripts[@]}")" || continue
        bootstrap_require_writable "$dir" || continue
        confirm "Delete $pick?" && { rm -f -- "$dir/$pick"; ok "Deleted: $pick"; }
        ;;
      Back|"") return ;;
    esac
  done
}
