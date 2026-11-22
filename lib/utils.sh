#!/usr/bin/env bash
# utils.sh - shared helpers: colors, logging, prompts, small utilities

# --- Colors (disabled when stdout is not a TTY) ---
if [[ -t 1 ]]; then
  C_RED=$'\033[1;31m'; C_YEL=$'\033[1;33m'; C_GRN=$'\033[1;32m'
  C_CYN=$'\033[1;36m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_RED=""; C_YEL=""; C_GRN=""; C_CYN=""; C_DIM=""; C_RST=""
fi

# --- Logging ---
die()  { echo "${C_RED}Error:${C_RST} $*" >&2; exit 1; }
info() { echo "${C_CYN}::${C_RST} $*"; }
warn() { echo "${C_YEL}::${C_RST} $*" >&2; }
ok()   { echo "${C_GRN}✓${C_RST} $*"; }

# --- Command checks ---
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "$1 not found in PATH. Install it and retry."; }
has_fzf()  { [[ -t 0 ]] && command -v fzf >/dev/null 2>&1; }

# Generic menu: prints selected item, or empty on cancel.
# Usage: menu_pick <prompt> <header> <height> <items...>
menu_pick() {
  local prompt="$1" header="$2" height="$3"; shift 3
  local -a items=("$@") fzf_cmd
  if has_fzf; then
    local -a cmd=(fzf --prompt="$prompt" --height="$height" --reverse --border)
    [[ -n "$header" ]] && cmd+=(--header="$header")
    printf '%s\n' "${items[@]}" | "${cmd[@]}" || true
  else
    [[ -n "$header" ]] && printf '%s\n' "$header" >&2
    local i=1 it idx=""
    for it in "${items[@]}"; do printf '  %d) %s\n' "$i" "$it" >&2; i=$((i+1)); done
    read -r -p "Choice: " idx || true
    if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx>=1 && idx<=${#items[@]} )); then
      printf '%s' "${items[$((idx-1))]}"
    fi
  fi
}

# Read input with default; prints value.
ask_default() {
  local prompt="$1" def="${2:-}" ans=""
  read -e -r -p "$prompt" ans || true
  printf '%s' "${ans:-$def}"
}

# --- Tiny key=value config helpers ---
conf_get() {
  local file="$1" key="$2" def="${3:-}" val
  [[ -f "$file" ]] || { printf '%s' "$def"; return 0; }
  val="$(awk -F= -v k="$key" '
    /^[[:space:]]*#/ {next}
    {n=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", n); v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)}
    n==k {print v; found=1; exit}
    END {if (!found) exit 1}
  ' "$file" 2>/dev/null)" || val="$def"
  printf '%s' "$val"
}

conf_set() {
  local file="$1" key="$2" value="$3" mode="${4:-}" tmp dir
  dir="$(dirname -- "$file")"
  mkdir -p -- "$dir" 2>/dev/null || return 1
  [[ -f "$file" ]] || : > "$file"
  tmp="$(mktemp "${file}.XXXXXX")" || return 1
  if awk -F= -v k="$key" -v v="$value" '
    BEGIN {found=0}
    /^[[:space:]]*#/ {print; next}
    { line=$0; n=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", n)
      if (n==k) {print k "=" v; found=1} else print line }
    END {if (!found) print k "=" v}
  ' "$file" > "$tmp"; then
    mv -f -- "$tmp" "$file"
    [[ -n "$mode" ]] && chmod "$mode" -- "$file" 2>/dev/null || true
  else
    rm -f -- "$tmp"
    return 1
  fi
}

# --- Prompts ---
confirm() {
  local prompt="$1" answer
  read -r -p "$prompt [y/N]: " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]]
}

confirm_exact() {
  local prompt="$1" expected="$2" answer
  read -r -p "$prompt " answer
  [[ "$answer" == "$expected" ]]
}

# --- Text helpers ---
sanitize_name() {
  local name="$1"
  name="$(printf '%s' "$name" | sed 's/[[:cntrl:]]//g; s#[/\\]#-#g; s/^[[:space:].]*//; s/[[:space:]]*$//')"
  name="$(printf '%s' "$name" | sed 's/[[:space:]]\+/ /g')"
  printf '%s' "$name"
}

# --- Path helpers ---
# Expand a leading ~ or $HOME (literal, never eval).
expand_path() {
  local p="$1"
  [[ -n "$p" ]] || return 1
  case "$p" in
    "~")   p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  p="${p/#\$HOME/$HOME}"
  printf '%s' "$p"
}

# Lexically normalize a path: //, /./, /../ (no filesystem access).
normalize_path() {
  local p="$1" part
  local -a parts=() out=()
  [[ "$p" == /* ]] || p="$PWD/$p"
  IFS='/' read -r -a parts <<< "$p"
  for part in "${parts[@]}"; do
    case "$part" in
      ''|.) ;;
      ..) (( ${#out[@]} > 0 )) && unset "out[$(( ${#out[@]} - 1 ))]" ;;
      *) out+=("$part") ;;
    esac
  done
  (( ${#out[@]} == 0 )) && { printf '/'; return; }
  printf '/%s' "${out[@]}"
}

# Make a path absolute + normalized (target may not exist yet).
to_abs_path() {
  local p
  p="$(expand_path "$1")" || return 1
  normalize_path "$p"
}

# Print ~/... when the path is inside $HOME.
pretty_path() {
  local p="$1"
  if [[ "$p" == "$HOME" ]]; then printf '~'
  elif [[ "$p" == "$HOME"/* ]]; then printf '~/%s' "${p#"$HOME"/}"
  else printf '%s' "$p"
  fi
}

# Resolve a path typed by the user.
# Normal forms (absolute, ~, ./, ../) behave as usual. A bare path whose
# first component exists at the filesystem root (e.g. "run/media/..."
# pasted without the leading "/") is treated as absolute instead of being
# silently created inside the current directory.
resolve_user_path() {
  local raw="$1" first
  [[ -n "$raw" ]] || return 1
  case "$raw" in
    /*|"~"|"~/"*|'$HOME'|'$HOME'/*) to_abs_path "$raw"; return ;;
    .*) to_abs_path "$raw"; return ;;
  esac
  first="${raw%%/*}"
  if [[ -n "$first" && "$first" != "$raw" && -d "/$first" ]]; then
    normalize_path "/$raw"
  else
    to_abs_path "$raw"
  fi
}

# --- Disk space ---
# check_space DIR NEED_KB LABEL - warn and confirm if free space is low.
check_space() {
  local dir="$1" need_kb="$2" label="${3:-data}" avail
  avail="$(df -Pk "$dir" 2>/dev/null | awk 'NR==2{print $4}')"
  [[ -n "$avail" ]] || return 0
  if (( avail < need_kb )); then
    warn "Low disk space in $dir for $label (need ~$(( need_kb / 1024 )) MB, free $(( avail / 1024 )) MB)."
    confirm "Continue anyway?" || return 1
  fi
  return 0
}

# --- Progress bar ---
progress_bar() {
  local current="$1" total="$2" width=28 label="${3:-}" suffix="${4:-}"
  local pct=0 filled=0 empty=0 bar=""
  if (( total > 0 )); then pct=$(( current * 100 / total )); fi
  if (( pct > 100 )); then pct=100; fi
  filled=$(( pct * width / 100 ))
  empty=$(( width - filled ))
  bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '-')"
  printf '\r%s[%s] %3d%% %s' "${C_CYN}${label}${C_RST}" "$bar" "$pct" "$suffix"
  if (( current >= total )); then printf '\n'; fi
}
