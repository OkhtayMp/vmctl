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

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  die "curl or wget is required."
fi
command -v tar >/dev/null 2>&1 || die "tar is required."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

info "Downloading ${REPO}@${BRANCH}..."
archive="$tmp/vmctl.tar.gz"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$TARBALL_URL" -o "$archive"
else
  wget -qO "$archive" "$TARBALL_URL"
fi

info "Installing to $INSTALL_DIR ..."
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR" "$BIN_DIR"
tar -xzf "$archive" -C "$tmp"

# GitHub tarball extracts to vmctl-<branch>/ (slashes replaced)
src_dir="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[[ -n "$src_dir" ]] || die "Failed to extract archive."

cp -R "$src_dir"/vmctl "$src_dir"/lib "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/vmctl"
ln -sfn "$INSTALL_DIR/vmctl" "$BIN_PATH"

ok "Installed: $BIN_PATH"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    warn "$BIN_DIR is not in PATH. Add this to your shell config:"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac

ok "Run: vmctl"
