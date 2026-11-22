# vmctl

A simple, precise QEMU VM manager for Linux.

`vmctl` gives you a fast terminal UI to create, run, install, resize, and manage QEMU virtual machines. It checks dependencies, shows clear install hints, and keeps each VM organized in its own folder.

## Features

- **Simple TUI** - `fzf` menu when available, numbered menu fallback otherwise
- **Per-VM management** - default `vms/<name>/`, or any custom folder you choose
- **300 OS suggestions** - searchable Windows/Linux/BSD/macOS/Unix names with **Tab completion** (free-text names still allowed)
- **Run / Install / Reinstall** - boot an existing disk or install from ISO
- **Disk resize** - grow qcow2 disks with guided size options
- **Port forwards** - add/remove per-VM QEMU user-network port forwards
- **Bootstrap scripts** - per-VM host scripts that auto-run on VM start and stop on VM close
- **Import / Export** - backup or move VMs as timestamped `.vmctl.tar.zst` / `.vmctl.tar.gz` archives (fast, with progress)
- **Safe names** - unique VM names (case-insensitive); duplicates must be renamed
- **Settings** - global defaults in `.vmctl/settings.conf`; per-VM overrides (memory/CPUs/monitors) in VM menu > **VM Settings**
- **Permissions check** - private 700/600 modes, clear `chmod`/`chown` fixes, optional sudo fix
- **SPICE integration** - auto-connect with `remote-viewer` for clipboard/resize/drag-drop when guest tools are installed
- **Multi-monitor** - at run time choose 1–4 SPICE/QXL monitors; per-VM choice is remembered (`VM Settings` or prompt). Global default comes from Settings; `VMCTL_MONITORS=2` overrides. If a second window does not open, enable Extend inside the guest (`DisplaySwitch.exe /extend` on Windows)
- **Dependency checks** - detects missing tools and prints install commands
- **Cross-distro friendly** - works on common Linux distros with QEMU/KVM

## Requirements

Required:
- `qemu-system-x86_64`
- `qemu-img`

Recommended:
- `remote-viewer` (virt-viewer) - best SPICE display, resize, clipboard, drag-drop
- `python3` - SPICE port readiness check
- `fzf` - better interactive menus

`vmctl` checks these at startup and shows install hints if something is missing.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/okhtaymp/vmctl/main/install.sh | bash
```

Or with `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/okhtaymp/vmctl/main/install.sh | bash
```

The installer places files in `~/.local/share/vmctl` and links `vmctl` into `~/.local/bin`.

## Usage

Run inside the folder where you want VM data stored:

```bash
vmctl
```

`vmctl` creates/uses a `vms/` directory in the current working directory.

### Main flow

1. Select an existing VM, or choose **New VM**
2. For a new VM, pick an OS suggestion (300 built-in, searchable) or type any custom name. In the picker: type to filter, **Tab** inserts the highlighted suggestion into the query (the menu stays open so you can keep editing or append text), **Enter** confirms, **Esc** cancels. Names are validated and must be unique (case-insensitive); duplicates must be renamed
3. Choose the VM folder: press **Enter** for the default `vms/<name>/`, or type any folder (it must be empty or not exist)
4. Choose an action:
   - **Run** - boot the VM
   - **Install / Reinstall (from ISO)** - wipe disk and install from ISO
   - **Resize disk** - grow virtual disk size
   - **Port forwards** - manage host/guest forwards
   - **Bootstrap** - manage host scripts auto-run on VM start
   - **Export VM** - export VM to a compressed `.vmctl.tar.zst` / `.tar.gz` archive
   - **Delete VM** - remove VM directory

Use **Import VM** from the main menu to restore an exported archive.

### Storage paths

- Default: `vms/<name>/` inside the workspace
- Custom: any folder, chosen at creation/import time
- Mappings are stored in `.vmctl/vms.list` as `name<TAB>absolute-path`
- Default folders are also discovered by scanning `vms/`, so the registry is only required for custom paths
- Environment overrides: `VMCTL_HOME` (workspace), `VMCTL_VMS_DIR` (default VM root), `VMCTL_UMASK` (default `077`)

Names are logical and global inside a workspace: two VMs cannot share a name, even with different folders or letter case.

### Export / Import

**Export VM** writes a compressed archive of the whole VM folder (disk, ports, bootstrap scripts).

- Default location: `~/Documents/ExVMcli/` (follows XDG `Documents` when available)
- Default filename: `<vm-name>-YYYYmmdd-HHMMSS.vmctl.tar.zst` (`.gz` without zstd)
- Press **Enter** to accept the default, or type another file/folder path
- If you give a folder, the timestamped filename is created inside it
- An explicit `.tar.gz`/`.tgz` or `.tar.zst`/`.tzst` suffix selects that format
- `bootstrap/*.log` and `*.pid` files are excluded to keep archives small
- Export is refused while the VM is running (to avoid an inconsistent disk)
- The archive is written to a temporary `.part` file first, so a failed export never leaves a broken file;
  the same files are cleaned up on **Ctrl-C**, errors, and after success
- A live progress bar shows the percentage, transferred/total size, speed, and ETA during export:
  ```text
  [############------------]  52%  4.0/7.6G  85 MB/s  ETA 00:42
  ```
  - The unit switches between `M` and `G` so small VMs do not show `0.0/0.2G`
  - Speed and ETA come from a **sliding ~4 second window**, so if the target slows down
    (USB stick, network share, page-cache flushing) the estimate corrects itself within seconds
  - Until the first window completes the ETA is `--:--` (it never shows a made-up number)
  - ETA longer than an hour is shown as `H:MM:SS`
- Path handling: absolute paths, `~`, `~/...`, `./...`, and `../...` work as usual. A bare path whose first
  component exists at `/` (for example `run/media/you/USB/x.zst`, pasted without the leading slash) is treated
  as absolute instead of being created inside the workspace. Use `./run/...` to force a relative path
- The resolved target is printed as `Output:` before packing
- Export is refused inside the VM folder, `vms/`, or `.vmctl/`; writing inside the workspace asks for confirmation
- Export to a **FAT32** target is refused when the VM is larger than 4 GB (one file cannot exceed that)
- **Speed:** `zstd` is used automatically when installed (all CPU cores), then `pigz`, then `gzip -1`
  - Force a format: `VMCTL_EXPORT_FORMAT=auto|zst|gz` (default `auto`)
  - Compression level: `VMCTL_EXPORT_LEVEL` (zstd default `1` = fastest, up to `19`; gzip default `1`, up to `9`)
  - Without `zstd`/`pigz`, install one for the biggest speedup (`sudo apt install zstd pigz`, `sudo dnf install zstd pigz`, …)

**Import VM** accepts an archive path, asks for a VM name (defaults to the archive's folder name), then asks for a destination folder.

- Compression is detected from the file contents, so both new `.tar.zst` and old `.tar.gz` exports work regardless of the extension
- If a `.zst` archive is selected and `zstd` is missing, the exact install command is shown
- Names are validated and checked case-insensitively against existing VMs
- If the name exists, you **must choose a different name** (import never overwrites)
- Destination defaults to `vms/<name>/`; any empty/nonexistent folder is accepted
- Unsafe archive paths (`/...` or `../...`) are rejected
- Archives without a VM folder are rejected
- Extracted files are moved into place atomically from a temp folder on the same filesystem

### Permissions

Created data is private by default (`umask 077`):

- VM folders: `700`
- Disks, `ports.conf`, logs: `600`
- Bootstrap scripts: `700` (executable)
- Registry `.vmctl/vms.list`: `600` inside a `700` folder

At startup, `vmctl` checks ownership and writability and prints exact fixes. Use **Permissions check** in the main menu to:

- review every VM folder with a status label
- fix owned files with `chmod -R u+rwX,go-rwx`
- show (and optionally run) the exact `sudo chown -R <uid>:<gid> -- <path>` command for root-owned files

`vmctl` never silently changes ownership.

### Port forwards

Format stored in `<vm-folder>/ports.conf`:

```text
# proto bind_host host_port guest_port
tcp 127.0.0.1 1080 1080
```

After changing port forwards, restart the VM.

### Bootstrap scripts

Stored in `<vm-folder>/bootstrap/*.sh`.

- Enabled scripts run automatically when VM starts
- Scripts run in background and are stopped when VM closes (including child processes)
- Logs are written next to scripts as `*.log`
- Scripts not owned by you are skipped, with the exact `chown` fix

## VM layout

Default layout:

```text
.
├── .vmctl/
│   └── vms.list          # name <TAB> custom-path (only needed for custom folders)
└── vms/
    └── <vm-name>/
        ├── disk.qcow2
        ├── ports.conf
        └── bootstrap/
            ├── example.sh
            └── example.log
```

With a custom folder, only the location changes; the files inside are identical.

## Notes

- For best Windows guest experience (auto-resize, clipboard, drag-drop), install SPICE Guest Tools inside the guest.
- Growing a disk only changes virtual size; extend the partition inside the guest OS afterward.
- `vmctl` uses QEMU user networking by default.

## Project structure

```text
vmctl            # entrypoint, globals, main loop
lib/
  utils.sh       # logging, prompts, paths, disk-space helpers
  registry.sh    # name -> folder registry, VM discovery
  permissions.sh # ownership/mode checks and the fix menu
  checks.sh      # dependency and environment checks
  os-list.sh     # 300 OS name suggestions
  vm.sh          # VM lifecycle, QEMU, import/export, menus
  ports.sh       # per-VM port forwards
  bootstrap.sh   # per-VM bootstrap scripts
install.sh
README.md
LICENSE
```

## License

MIT
