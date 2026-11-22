#!/usr/bin/env bash
# registry.sh - map logical VM names to their folders
#
# By default a VM lives in "$VMS_DIR/<name>", but the user can pick any
# folder when creating/importing. The registry keeps that mapping in
# "$REGISTRY" (one "name<TAB>path" line per VM). Default VMs are also
# discovered by scanning "$VMS_DIR", so a lost registry never hides them.

# Create the state folder/registry with private permissions.
registry_init() {
  if [[ ! -d "$STATE_DIR" ]]; then
    mkdir -p -- "$STATE_DIR" 2>/dev/null || return 1
  fi
  [[ -O "$STATE_DIR" ]] && chmod 700 -- "$STATE_DIR" 2>/dev/null || true
  if [[ ! -f "$REGISTRY" ]]; then
    : > "$REGISTRY" 2>/dev/null || return 1
    chmod 600 -- "$REGISTRY" 2>/dev/null || true
  fi
  return 0
}

# Print registry lines without comments/blank lines.
_registry_entries() {
  [[ -f "$REGISTRY" ]] || return 0
  grep -v '^[[:space:]]*#' -- "$REGISTRY" 2>/dev/null || true
}

# Case-insensitive lookup by VM name. Prints the stored folder.
registry_lookup() {
  local name="$1" n p
  while IFS=$'\t' read -r n p; do
    [[ -z "$n" || -z "$p" ]] && continue
    if [[ "${n,,}" == "${name,,}" ]]; then
      printf '%s' "$p"
      return 0
    fi
  done < <(_registry_entries)
  return 1
}

# Print the VM name that already uses this exact folder (if any).
registry_name_for_path() {
  local path="$1" n p
  while IFS=$'\t' read -r n p; do
    [[ -z "$n" || -z "$p" ]] && continue
    if [[ "$p" == "$path" ]]; then
      printf '%s' "$n"
      return 0
    fi
  done < <(_registry_entries)
  return 1
}

registry_path_in_use() {
  registry_name_for_path "$1" >/dev/null 2>&1
}

# Add/replace a VM mapping. Rewrites atomically with private permissions.
registry_register() {
  local name="$1" path="$2" n p tmp other
  registry_init || { warn "Cannot write registry: $REGISTRY"; return 1; }

  other="$(registry_name_for_path "$path" 2>/dev/null || true)"
  if [[ -n "$other" && "${other,,}" != "${name,,}" ]]; then
    warn "Folder is already used by VM '$other': $path"
    return 1
  fi

  tmp="$(mktemp "$STATE_DIR/.vms.XXXXXX")" || return 1
  {
    printf '# name\tpath\n'
    while IFS=$'\t' read -r n p; do
      [[ -z "$n" || -z "$p" ]] && continue
      [[ "${n,,}" == "${name,,}" ]] && continue
      printf '%s\t%s\n' "$n" "$p"
    done < <(_registry_entries)
    printf '%s\t%s\n' "$name" "$path"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 -- "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$REGISTRY" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# Remove a VM mapping (safe if the VM was never registered).
registry_unregister() {
  local name="$1" n p tmp
  [[ -f "$REGISTRY" ]] || return 0
  registry_init || return 1
  tmp="$(mktemp "$STATE_DIR/.vms.XXXXXX")" || return 1
  {
    printf '# name\tpath\n'
    while IFS=$'\t' read -r n p; do
      [[ -z "$n" || -z "$p" ]] && continue
      [[ "${n,,}" == "${name,,}" ]] && continue
      printf '%s\t%s\n' "$n" "$p"
    done < <(_registry_entries)
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 -- "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$REGISTRY" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# Folder for a VM name. Falls back to "$VMS_DIR/<name>".
vm_dir_of() {
  local name="$1" p
  p="$(registry_lookup "$name" 2>/dev/null || true)"
  if [[ -n "$p" ]]; then
    printf '%s' "$p"
  else
    printf '%s' "$VMS_DIR/$name"
  fi
}

# Find an existing VM folder by name (case-insensitive).
find_vm_dir() {
  local name="$1" p d base n
  p="$(registry_lookup "$name" 2>/dev/null || true)"
  if [[ -n "$p" && -d "$p" ]]; then printf '%s' "$p"; return 0; fi
  if [[ -d "$VMS_DIR/$name" ]]; then printf '%s' "$VMS_DIR/$name"; return 0; fi

  while IFS= read -r d; do
    base="${d##*/}"
    [[ "$base" == .* ]] && continue
    if [[ "${base,,}" == "${name,,}" ]]; then printf '%s' "$d"; return 0; fi
  done < <(find "$VMS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

  while IFS=$'\t' read -r n d; do
    [[ -z "$n" || -z "$d" ]] && continue
    if [[ "${n,,}" == "${name,,}" && -d "$d" ]]; then printf '%s' "$d"; return 0; fi
  done < <(_registry_entries)
  return 1
}

# List every known VM name (default folders + live registry entries), deduped.
list_vms() {
  local d base n p
  local -A seen=()
  while IFS= read -r d; do
    base="${d##*/}"
    [[ "$base" == .* ]] && continue
    [[ -n "${seen[${base,,}]:-}" ]] && continue
    seen["${base,,}"]=1
    printf '%s\n' "$base"
  done < <(find "$VMS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

  while IFS=$'\t' read -r n p; do
    [[ -z "$n" || -z "$p" ]] && continue
    [[ -d "$p" ]] || continue
    [[ -n "${seen[${n,,}]:-}" ]] && continue
    seen["${n,,}"]=1
    printf '%s\n' "$n"
  done < <(_registry_entries)
}
