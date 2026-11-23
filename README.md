# vmctl

`vmctl` is a lightweight QEMU/KVM virtual machine manager for Linux with a terminal UI. It helps you create, run, import, export, and manage VMs without manual QEMU command setup.

## Problems it solves

- **Manual QEMU commands**: manage VM lifecycle from a simple TUI/menu.
- **Disorganized VM files**: keep each VM in its own folder (disk, ports, bootstrap, settings).
- **Unreliable VM transfer**: import/export VM archives (`.vmctl.tar.zst`, `.vmctl.tar.gz`) with progress, ETA, path validation, atomic extraction, and no overwrite on existing VM names.
- **Path confusion**: stable default workspace with optional `VMCTL_HOME` / `VMCTL_VMS_DIR` overrides.
- **Permission issues**: private defaults (`700` dirs, `600` files) and clear `chmod/chown` fix guidance.

## Install

```bash
# Local checkout
./install.sh

# Or install from GitHub
curl -fsSL https://raw.githubusercontent.com/okhtaymp/vmctl/main/install.sh | bash
```

Installs to `~/.local/share/vmctl` and links `~/.local/bin/vmctl`. Updates are safe: user data (`vms/`, `.vmctl/`) is preserved.

## Usage

```bash
vmctl
```

Actions: **New VM**, **Import VM**, **Run**, **Install/Reinstall (ISO)**, **Resize disk**, **Port forwards**, **Bootstrap**, **VM Settings**, **Export VM**, **Delete VM**.

## Defaults

- Workspace: `${XDG_DATA_HOME:-$HOME/.local/share}/vmctl`
- VM root: `<workspace>/vms` or `VMCTL_VMS_DIR`
- Workspace resolution: `VMCTL_HOME` → current dir with vmctl state → XDG default
- File mask: `VMCTL_UMASK` (default `077`)

## Requirements

- Required: `qemu-system-x86_64`, `qemu-img`, `tar`
- Recommended: `remote-viewer`, `python3`, `fzf`, `zstd` or `pigz`

## License

MIT
