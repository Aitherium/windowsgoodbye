# Windows Goodbye

One command from Windows to [awnix](https://github.com/Aitherium/awnix), inside WSL2. No reboot.

```powershell
powershell -ExecutionPolicy Bypass -File .\WindowsGoodbye.ps1           # install + open
.\WindowsGoodbye.ps1 -DryRun                                            # check, change nothing
.\WindowsGoodbye.ps1 -Uninstall                                         # remove it
```

## What it does

1. Checks WSL2 is ready. If WSL is missing, it prints the one admin command to install it and stops.
2. Pulls the public awnix image (`ghcr.io/aitherium/awnix:latest`, linux/amd64) anonymously and
   checks every layer against the sha256 digest in the image manifest.
3. Merges the layers into one root filesystem **stream to stream** (`merge_layers.py`), applying
   OCI whiteouts. It never unpacks onto NTFS, which cannot hold Linux symlinks, hardlinks or modes.
4. `wsl --import awnix %LOCALAPPDATA%\awnix\wsl <rootfs.tar> --version 2`, checks it starts, and opens it.

## What it never does

No boot entries, no boot-order change, no reboot, no drivers, no admin prompt. `-Uninstall` is
`wsl --unregister awnix`, and Windows is exactly as it was.

## Needs

Windows 10/11 x86_64 with WSL2, PowerShell 5.1+, and Python 3 (for the layer merge;
`winget install -e --id Python.Python.3.12`). About 1.6 GB of download.

## Status

**Private until tested.** Verified so far:
- the script parses under Windows PowerShell 5.1 and PowerShell 7;
- `-DryRun` against the live image: 89 layers, about 1.6 GB, plan printed, nothing changed;
- `merge_layers.py`: 5 offline tests (newest wins, whiteouts, opaque dirs, symlinks/hardlinks,
  root dotfiles) plus a real merge of the awnix base layer (768 symlinks and every hardlink kept;
  Windows `tar.exe` lost 2,006 files and 768 symlinks from the same layer).

**Not yet run:** a full `wsl --import` end to end. It has to run on a machine that is not hosting
a live WSL fleet; starting a second distro there has taken the fleet down before.

The reboot-into-awnix path (bare metal) and Hyper-V are not in this version.

MIT licence.
