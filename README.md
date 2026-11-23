# vmctl

Terminal VM manager for QEMU/KVM on Linux. Simple TUI, per-VM folders, safe import/export, and clear permission handling.

## What it solves

- **Messy VM files**: keeps each VM in its own managed folder (disk, ports, bootstrap, settings).
- **Path confusion**: uses a stable default workspace, supports custom VM folders, and respects `VMCTL_HOME`/`VMCTL_VMS_DIR`.
- **Risky import/export**: exports/imports `.vmctl.tar.zst`/`.tar.gz` with progress/ETA, validates archive paths, extracts atomically, and never overwrites existing VMs.
- **Permission issues**: creates private files by default and shows exact `chmod/chown` fixes when needed.
- **Manual QEMU setup**: gives a simple menu for run/install/resize/ports/bootstrap/settings.

## Install

```bash
# Local checkout
./install.sh

# Or from GitHub
curl -fsSL https://raw.githubusercontent.com/okhtaymp/vmctl/main/install.sh | bash
```

Installs to `~/.local/share/vmctl` and links `~/.local/bin/vmctl`. Reinstall/update is safe: user data (`vms/`, `.vmctl/`) is preserved.

## Usage

```bash
vmctl
```

Main actions: **New VM**, **Import VM**, **Run**, **Install/Reinstall (ISO)**, **Resize disk**, **Port forwards**, **Bootstrap**, **VM Settings**, **Export VM**, **Delete VM**.

## Defaults & Overrides

- Workspace: `${XDG_DATA_HOME:-$HOME/.local/share}/vmctl`
- VM root: `<workspace>/vms` (or `VMCTL_VMS_DIR`)
- Workspace resolution: `VMCTL_HOME` → cwd with vmctl state → XDG default
- Permissions mask: `VMCTL_UMASK` (default `077`)

## Requirements

- Required: `qemu-system-x86_64`, `qemu-img`, `tar`
- Recommended: `remote-viewer`, `python3`, `fzf`, `zstd` or `pigz`

## License

MIT
