# Windows Goodbye

One command from Windows to [awnix](https://github.com/Aitherium/awnix), inside WSL2. No reboot.

```powershell
powershell -ExecutionPolicy Bypass -File .\WindowsGoodbye.ps1           # install + open
.\WindowsGoodbye.ps1 -DryRun                                            # check, change nothing
.\WindowsGoodbye.ps1 -Uninstall                                         # remove it
```

## What it does

1. Checks WSL2 is ready. If WSL is missing, it prints the one admin command to install it and stops.
2. Downloads the prebuilt awnix filesystem from this repo's latest release and checks every part
   against `SHA256SUMS`.
3. `wsl --import awnix %LOCALAPPDATA%wnix\wsl <awnix-rootfs.tar.gz> --version 2`, checks it
   starts, and opens it.

The filesystem is built by `.github/workflows/rootfs.yml` on Linux: `docker export` of the public
`ghcr.io/aitherium/awnix` image (the engine applies OCI layers and whiteouts), then the tarball is
imported back and booted (`/etc/os-release`, bash, systemd) before the release is published.
`tools/merge_layers.py` is a pure-Python fallback for building it without Docker.

## What it never does

No boot entries, no boot-order change, no reboot, no drivers, no admin prompt. `-Uninstall` is
`wsl --unregister awnix`, and Windows is exactly as it was.

## Needs

Windows 10/11 x86_64 with WSL2 and PowerShell 5.1+. About 1.6 GB of download.

## Status

**Early release.** Verified so far:
- the script parses under Windows PowerShell 5.1 and PowerShell 7, and its checksum parser
  matches real `sha256sum` output;
- the CI build boots the exported filesystem before publishing it;
- `tools/merge_layers.py`: 5 offline tests plus a real merge of the awnix base layer (every
  symlink and hardlink kept; Windows `tar.exe` lost 2,006 files and 768 symlinks from it).
- the full install runs on a real Windows machine in CI (`windows-install.yml`): download,
  checksum, `wsl --import`, start, `/etc/os-release`, bash, then `-Uninstall` leaves nothing.
  GitHub's Windows runners cannot nest WSL2, so CI imports as WSL1; on your PC it is WSL2.

The reboot-into-awnix path (bare metal) and Hyper-V are not in this version.

MIT licence.
