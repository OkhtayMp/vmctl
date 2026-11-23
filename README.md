# vmctl

Terminal VM manager for QEMU/KVM on Linux. Simple TUI, per-VM folders, safe import/export, and clear permission handling.

## Highlights

- **TUI workflow**: `fzf` menu when available, numbered fallback otherwise.
- **Per-VM layout**: disk, ports, bootstrap, and per-VM settings in one folder.
- **Safe import/export**: `.vmctl.tar.zst` / `.vmctl.tar.gz`, progress + ETA, atomic extract, no overwrite on name conflict.
- **Portable paths**: stable default workspace, custom VM folders, env overrides.
- **Practical defaults**: private permissions (`700/600`), dependency checks, SPICE viewer integration.

## Requirements

- Required: `qemu-system-x86_64`, `qemu-img`, `tar`
- Recommended: `remote-viewer` (virt-viewer), `python3`, `fzf`, `zstd` or `pigz`

## Install

```bash
# Local checkout (recommended for this repo)
./install.sh

# Or from GitHub
curl -fsSL https://raw.githubusercontent.com/okhtaymp/vmctl/main/install.sh | bash
```

Installs to `~/.local/share/vmctl` and symlinks `~/.local/bin/vmctl`. Reinstall/update is safe: program files are replaced, user data (`vms/`, `.vmctl/`) is preserved.

## Usage

```bash
vmctl
```

Main actions: **New VM**, **Import VM**, **Run**, **Install/Reinstall (ISO)**, **Resize disk**, **Port forwards**, **Bootstrap**, **VM Settings**, **Export VM**, **Delete VM**.

## Storage & Paths

- Default workspace: `${XDG_DATA_HOME:-$HOME/.local/share}/vmctl`
- Default VM root: `<workspace>/vms`
- Default VM folder: `<workspace>/vms/<name>/` (or any custom empty/new folder)
- Registry: `<workspace>/.vmctl/vms.list` (`name<TAB>absolute-path`)

Workspace resolution:
1. `VMCTL_HOME` if set
2. Current directory if it contains vmctl state (`.vmctl/vms.list` or `.vmctl/settings.conf`)
3. `${XDG_DATA_HOME:-$HOME/.local/share}/vmctl`

Overrides: `VMCTL_HOME`, `VMCTL_VMS_DIR`, `VMCTL_UMASK` (default `077`).

## Import / Export

- **Export**: whole VM folder archive; default `~/Documents/ExVMcli/<name>-YYYYmmdd-HHMMSS.vmctl.tar.<zst|gz>`.
- **Progress**: live percent, transferred/total, speed, ETA.
- **Import**: reads index with progress, validates unsafe paths, asks for unique VM name, extracts atomically on same filesystem.
- Formats: zstd/gzip auto-detected by content; `.tar.zst` preferred when `zstd` is available.

## Security & Permissions

- Private by default: VM dirs `700`, files `600`, bootstrap scripts executable.
- Startup and **Permissions check** menu report exact `chmod/chown` fixes.
- Ownership is never changed silently.

## VM Layout

```text
<workspace>/
├── .vmctl/
│   ├── vms.list
│   └── settings.conf
└── vms/
    └── <vm-name>/
        ├── disk.qcow2
        ├── vm.conf
        ├── ports.conf
        └── bootstrap/
```

## License

MIT
