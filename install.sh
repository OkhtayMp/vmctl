#!/usr/bin/env bash
set -euo pipefail

REPO="okhtaymp/vmctl"
BRANCH="${VMCTL_BRANCH:-main}"
TARBALL_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
INSTALL_DIR="${VMCTL_INSTALL_DIR:-$HOME/.local/share/vmctl}"
BIN_DIR="${VMCTL_BIN_DIR:-$HOME/.local/bin}"
BIN_PATH="$BIN_DIR/vmctl"

info() { printf '\033[1;36m::\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m::\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# Resolve local source when running from a repo checkout (update/install locally).
SCRIPT_PATH="${BASH_SOURCE[0]:-}"
LOCAL_SRC=""
if [[ -n "$SCRIPT_PATH" && -f "$SCRIPT_PATH" ]]; then
  SCRIPT_PATH="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd)/$(basename "$SCRIPT_PATH")"
  LOCAL_SRC="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd)"
  [[ -f "$LOCAL_SRC/vmctl" && -d "$LOCAL_SRC/lib" ]] || LOCAL_SRC=""
fi

tmp=""
cleanup() { [[ -n "$tmp" ]] && rm -rf -- "$tmp" || true; }
trap cleanup EXIT

src_dir=""
if [[ -n "$LOCAL_SRC" ]]; then
  info "Installing from local source: $LOCAL_SRC"
  src_dir="$LOCAL_SRC"
else
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    die "curl or wget is required."
  fi
  command -v tar >/dev/null 2>&1 || die "tar is required."
  tmp="$(mktemp -d)"
  info "Downloading ${REPO}@${BRANCH}..."
  archive="$tmp/vmctl.tar.gz"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$TARBALL_URL" -o "$archive"
  else
    wget -qO "$archive" "$TARBALL_URL"
  fi
  tar -xzf "$archive" -C "$tmp"
  src_dir="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [[ -n "$src_dir" ]] || die "Failed to extract archive."
fi

[[ -f "$src_dir/vmctl" && -d "$src_dir/lib" ]] || die "Invalid source: missing vmctl/lib"

info "Installing to $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR" "$BIN_DIR"

# Update-safe install: replace program files, preserve user data (vms/, .vmctl/, ISOs, etc.).
rm -rf -- "$INSTALL_DIR/lib"
rm -f -- "$INSTALL_DIR/vmctl"
cp -R "$src_dir"/vmctl "$src_dir"/lib "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/vmctl"
ln -sfn "$INSTALL_DIR/vmctl" "$BIN_PATH"

ok "Installed: $BIN_PATH -> $INSTALL_DIR/vmctl"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    warn "$BIN_DIR is not in PATH. Add this to your shell config:"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac

ok "Run: vmctl"
