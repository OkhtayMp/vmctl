#!/usr/bin/env bash
# checks.sh - dependency checks, environment detection, permission checks

# Suggest install command for common package managers
pkg_install_hint() {
  local pkg="$1"
  if command -v apt-get >/dev/null 2>&1; then echo "sudo apt-get install -y $pkg"
  elif command -v dnf >/dev/null 2>&1; then echo "sudo dnf install -y $pkg"
  elif command -v pacman >/dev/null 2>&1; then echo "sudo pacman -S --needed $pkg"
  elif command -v zypper >/dev/null 2>&1; then echo "sudo zypper install -y $pkg"
  elif command -v brew >/dev/null 2>&1; then echo "brew install $pkg"
  else echo "Install package: $pkg"; fi
}

# Detect CPU acceleration (KVM/HVF/TCG)
detect_accel() {
  ACCEL="tcg"; CPU="max"; CPU_EXTRA=""
  case "$(uname -s)" in
    Linux)
      if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
        ACCEL="kvm"; CPU="host"
        CPU_EXTRA=",hv_relaxed,hv_vapic,hv_spinlocks=0x1fff,hv_vpindex,hv_runtime,hv_synic,hv_stimer,hv_time,hv_frequencies,hv_tlbflush,hv_ipi"
      fi
      ;;
    Darwin) ACCEL="hvf"; CPU="host" ;;
  esac
}

# Check required/recommended dependencies and show compact status
check_requirements() {
  local missing_req=0 warns=() ok_items=()

  req() {
    local cmd="$1" pkg="$2" label="$3"
    if command -v "$cmd" >/dev/null 2>&1; then ok_items+=("$label")
    else
      echo "${C_RED}✗${C_RST} $label: MISSING (required)"
      echo "  Install: $(pkg_install_hint "$pkg")"
      missing_req=1
    fi
  }
  opt() {
    local cmd="$1" pkg="$2" label="$3" why="$4"
    if command -v "$cmd" >/dev/null 2>&1; then ok_items+=("$label")
    else warns+=("$label missing: $why | Install: $(pkg_install_hint "$pkg")"); fi
  }

  req qemu-system-x86_64 qemu-system-x86 "qemu"; req qemu-img qemu-utils "qemu-img" || true
  req tar tar "tar" || true
  opt remote-viewer virt-viewer "remote-viewer" "SPICE display/resize/drag-drop"
  opt python3 python3 "python3" "port check"
  opt fzf fzf "fzf" "better menus"

  case "$(uname -s)" in
    Linux)
      if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then ok_items+=("kvm")
      elif [[ -e /dev/kvm ]]; then warns+=("kvm not accessible | Fix: sudo usermod -aG kvm $USER && re-login")
      else warns+=("kvm missing (slow TCG) | Check BIOS VT-x/AMD-V"); fi
      ;;
    Darwin) ok_items+=("hvf") ;;
  esac

  if (( missing_req )); then die "Required dependencies missing. Install them and run again."; fi
  ok "Ready: ${ok_items[*]}"
  local w; for w in "${warns[@]}"; do warn "$w"; done
}

# Ensure the VM root exists and is private. Never aborts the whole app:
# a read-only/foreign-owned root should still let the user open the
# "Permissions check" menu and fix it.
ensure_vms_dir() {
  if ! mkdir -p -- "$VMS_DIR" 2>/dev/null; then
    warn "Cannot create VM root: $VMS_DIR"
    echo "  Fix: $(perm_chown_cmd "$(dirname "$VMS_DIR")")"
    return 0
  fi
  if [[ -O "$VMS_DIR" ]]; then
    chmod 700 -- "$VMS_DIR" 2>/dev/null || true
  fi
  return 0
}

