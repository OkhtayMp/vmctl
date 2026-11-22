#!/usr/bin/env bash
# settings.sh - global vmctl defaults (stored in $STATE_DIR/settings.conf)

SETTINGS_FILE=""

settings_path() {
  printf '%s/settings.conf' "$STATE_DIR"
}

settings_defaults() {
  cat <<'EOF'
# vmctl global defaults
# Edit via "Settings" menu, or manually (key=value).
default_monitors=1
default_memory=4G
default_cpus=2
default_spice_port=5900
EOF
}

settings_ensure() {
  SETTINGS_FILE="$(settings_path)"
  if [[ ! -f "$SETTINGS_FILE" ]]; then
    mkdir -p -- "$STATE_DIR" 2>/dev/null || return 0
    settings_defaults > "$SETTINGS_FILE" 2>/dev/null || return 0
    chmod 600 "$SETTINGS_FILE" 2>/dev/null || true
  fi
}

settings_get() { conf_get "$(settings_path)" "$1" "${2:-}"; }

settings_set() {
  settings_ensure
  conf_set "$(settings_path)" "$1" "$2" 600
}

settings_validate_monitors() { [[ "$1" =~ ^[1-4]$ ]]; }
settings_validate_memory()   { [[ "$1" =~ ^[0-9]+[MGmg]$ ]] && [[ "$1" =~ ^[1-9] ]]; }
settings_validate_cpus()     { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 32 )); }
settings_validate_port()     { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1024 && $1 <= 65535 )); }

settings_load() {
  settings_ensure
  DEFAULT_MONITORS="$(settings_get default_monitors 1)"
  DEFAULT_MEMORY="$(settings_get default_memory 4G)"
  DEFAULT_CPUS="$(settings_get default_cpus 2)"
  DEFAULT_SPICE_PORT="$(settings_get default_spice_port 5900)"

  settings_validate_monitors "$DEFAULT_MONITORS" || DEFAULT_MONITORS=1
  settings_validate_memory "$DEFAULT_MEMORY" || DEFAULT_MEMORY=4G
  settings_validate_cpus "$DEFAULT_CPUS" || DEFAULT_CPUS=2
  settings_validate_port "$DEFAULT_SPICE_PORT" || DEFAULT_SPICE_PORT=5900

  # Normalize memory to uppercase suffix
  DEFAULT_MEMORY="$(printf '%s' "$DEFAULT_MEMORY" | tr 'mg' 'MG')"
  # Apply spice port unless explicitly set by env
  if [[ -z "${SPICE_PORT_ENV_SET:-}" ]]; then
    SPICE_PORT="$DEFAULT_SPICE_PORT"
  fi
}

settings_summary() {
  echo "  Default monitors:   $DEFAULT_MONITORS"
  echo "  Default memory:     $DEFAULT_MEMORY"
  echo "  Default CPUs:       $DEFAULT_CPUS"
  echo "  Default SPICE port: $DEFAULT_SPICE_PORT"
  echo "  Config file:        $(pretty_path "$(settings_path)")"
}

# Prompt, validate, normalize, and persist a single setting.
settings_prompt_set() {
  local key="$1" prompt="$2" validator="$3" err="$4" def="$5" normalize="${6:-}" v
  v="$(ask_default "$prompt [$def]: " "$def")"
  [[ -n "$normalize" ]] && v="$("$normalize" "$v")"
  if "$validator" "$v"; then settings_set "$key" "$v"; ok "Saved."
  else warn "$err"; fi
}

_upper() { printf '%s' "$1" | tr 'mg' 'MG'; }

action_settings() {
  while true; do
    settings_ensure
    settings_load
    local -a acts=(
      "Monitors:   $DEFAULT_MONITORS"
      "Memory:     $DEFAULT_MEMORY"
      "CPUs:       $DEFAULT_CPUS"
      "SPICE port: $DEFAULT_SPICE_PORT"
      "Reset defaults"
      "Back"
    )
    local choice
    choice="$(menu_pick "Settings> " "Global defaults (saved in .vmctl/settings.conf). Per-VM overrides: VM menu > VM Settings" "45%" "${acts[@]}")"

    case "$choice" in
      Monitors:*)      settings_prompt_set default_monitors "Default monitors (1-4)" settings_validate_monitors "Invalid value. Use 1-4." "$DEFAULT_MONITORS" ;;
      Memory:*)        settings_prompt_set default_memory "Default memory (e.g. 2G, 4G, 8G)" settings_validate_memory "Invalid value. Use like 2G or 4096M." "$DEFAULT_MEMORY" _upper ;;
      CPUs:*)          settings_prompt_set default_cpus "Default CPU cores (1-32)" settings_validate_cpus "Invalid value. Use 1-32." "$DEFAULT_CPUS" ;;
      "SPICE port:"*)  settings_prompt_set default_spice_port "Default SPICE port (1024-65535)" settings_validate_port "Invalid value. Use 1024-65535." "$DEFAULT_SPICE_PORT" ;;
      "Reset defaults")
        if confirm "Reset all settings to defaults?"; then
          settings_defaults > "$(settings_path)"
          chmod 600 "$(settings_path)" 2>/dev/null || true
          ok "Defaults restored."
        fi
        ;;
      "Back"|"") return 0 ;;
    esac
  done
}
