#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Goodbye -- one command from Windows to awnix, inside WSL2. No reboot.

.DESCRIPTION
    Imports awnix as its own WSL2 distro named "awnix" (or -DistroName) and opens it.

    What it does, in order, and nothing else:
      1. Checks WSL2 is available. If WSL is missing it tells you the one command to
         install it (that needs admin and may need a reboot) and stops.
      2. Downloads the awnix container image from ghcr.io (public, anonymous pull) and
         turns its layers into one root filesystem tarball. Each layer is verified
         against the sha256 digest in the image manifest before it is used.
      3. Imports that tarball with `wsl --import` into a folder you own.
      4. Opens a shell in it.

    What it never does: touch boot entries, change Windows boot order, reboot,
    install drivers, or ask for admin. Removing it is `-Uninstall` (wsl --unregister).

.PARAMETER DistroName
    The WSL distro name. Default: awnix.

.PARAMETER InstallDir
    Where the distro's virtual disk lives. Default: %LOCALAPPDATA%\awnix\wsl.

.PARAMETER Image
    The image to import. Default: ghcr.io/aitherium/awnix:latest.

.PARAMETER Uninstall
    Unregister the distro (deletes its disk) and stop.

.PARAMETER DryRun
    Check everything and print the plan; download and import nothing.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\WindowsGoodbye.ps1
.EXAMPLE
    .\WindowsGoodbye.ps1 -DryRun
.EXAMPLE
    .\WindowsGoodbye.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$DistroName = 'awnix',
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'awnix\wsl'),
    [string]$Image = 'ghcr.io/aitherium/awnix:latest',
    [switch]$Uninstall,
    [switch]$DryRun,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Say([string]$m, [string]$c = 'Cyan') { Write-Host "[windowsgoodbye] $m" -ForegroundColor $c }
function Fail([string]$m) { Write-Host "[windowsgoodbye] $m" -ForegroundColor Red; exit 1 }

# wsl.exe prints UTF-16; read it as text we can match on.
function Invoke-Wsl([string[]]$WslArgs) {
    $old = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [Text.Encoding]::Unicode
        $out = & wsl.exe @WslArgs 2>&1 | Out-String
        return @{ Code = $LASTEXITCODE; Text = ($out -replace "`0", '') }
    } finally { [Console]::OutputEncoding = $old }
}

function Test-DistroExists([string]$Name) {
    $r = Invoke-Wsl @('--list', '--quiet')
    if ($r.Code -ne 0) { return $false }
    return @($r.Text -split "`r?`n" | ForEach-Object { $_.Trim() }) -contains $Name
}

# ── 0. Uninstall ─────────────────────────────────────────────────────────────
if ($Uninstall) {
    if (-not (Test-DistroExists $DistroName)) { Say "No distro named '$DistroName'. Nothing to remove." 'Yellow'; exit 0 }
    if ($DryRun) { Say "DRY RUN: would run wsl --unregister $DistroName (this deletes its disk)."; exit 0 }
    $r = Invoke-Wsl @('--unregister', $DistroName)
    if ($r.Code -ne 0) { Fail "wsl --unregister failed: $($r.Text.Trim())" }
    Say "Removed '$DistroName'. Windows is unchanged." 'Green'
    exit 0
}

# ── 1. WSL2 present? ─────────────────────────────────────────────────────────
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Fail "WSL is not installed. Run this once in an admin PowerShell, reboot if asked, then run Windows Goodbye again:`n    wsl --install --no-distribution"
}
$st = Invoke-Wsl @('--status')
if ($st.Code -ne 0 -and $st.Text -notmatch 'Default Version|Default Distribution|version') {
    Fail "WSL is present but not ready: $($st.Text.Trim())`nRun 'wsl --install --no-distribution' in an admin PowerShell, then try again."
}
if (Test-DistroExists $DistroName) {
    Say "awnix is already installed as '$DistroName'." 'Green'
    if (-not $NoLaunch -and -not $DryRun) { & wsl.exe -d $DistroName }
    exit 0
}

# ── 2. Pull the image (anonymous, verified) ──────────────────────────────────
if ($Image -notmatch '^ghcr\.io/([^:]+):(.+)$') { Fail "Image must look like ghcr.io/<owner>/<name>:<tag>, got: $Image" }
$repo = $Matches[1]; $tag = $Matches[2]
$reg = 'https://ghcr.io'
$accept = 'application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'

Say "Asking ghcr.io for $repo`:$tag ..."
$token = (Invoke-RestMethod "$reg/token?scope=repository:${repo}:pull").token
$h = @{ Authorization = "Bearer $token"; Accept = $accept }
$top = Invoke-RestMethod -Headers $h "$reg/v2/$repo/manifests/$tag"

# An index lists one manifest per platform: take linux/amd64.
if ($top.PSObject.Properties.Name -contains 'manifests') {
    $pick = $top.manifests | Where-Object { $_.platform.os -eq 'linux' -and $_.platform.architecture -eq 'amd64' } | Select-Object -First 1
    if (-not $pick) { Fail "The image has no linux/amd64 build. This PC needs x86_64." }
    $man = Invoke-RestMethod -Headers $h "$reg/v2/$repo/manifests/$($pick.digest)"
} else { $man = $top }

$layers = @($man.layers)
if (-not $layers.Count) { Fail "The image manifest lists no layers." }
$total = ($layers | Measure-Object -Property size -Sum).Sum
Say ("{0} layers, {1:N0} MB to download." -f $layers.Count, ($total / 1MB))

if ($DryRun) {
    Say "DRY RUN: would download $($layers.Count) layers, build a rootfs in $env:TEMP, and run:" 'Yellow'
    Say "  wsl --import $DistroName `"$InstallDir`" <rootfs.tar> --version 2" 'Yellow'
    exit 0
}

$work = Join-Path $env:TEMP ("windowsgoodbye-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    $i = 0
    $files = @()
    foreach ($l in $layers) {
        $i++
        $f = Join-Path $work ("layer{0:D3}.tar.gz" -f $i)
        Say ("Layer {0}/{1} ({2:N0} MB)..." -f $i, $layers.Count, ($l.size / 1MB))
        Invoke-WebRequest -UseBasicParsing -Headers @{ Authorization = "Bearer $token" } -Uri "$reg/v2/$repo/blobs/$($l.digest)" -OutFile $f
        $want = ($l.digest -replace '^sha256:', '').ToLower()
        $got = (Get-FileHash -Algorithm SHA256 -Path $f).Hash.ToLower()
        if ($got -ne $want) { Fail "Layer $i failed its checksum (wanted $want, got $got). Nothing was installed." }
        $files += $f
    }

    # ── 3. Layers -> one rootfs tar, stream to stream ───────────────────────
    # Never unpacked onto NTFS: it cannot hold Linux symlinks, hardlinks or modes
    # (measured: Windows tar lost 2,006 files and 768 symlinks from awnix's base layer).
    # merge_layers.py ships beside this script and needs only Python's standard library.
    $merger = Join-Path $PSScriptRoot 'merge_layers.py'
    if (-not (Test-Path $merger)) { Fail "merge_layers.py is missing next to this script." }
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    $pyArgs = @()
    if ($py) { $pyArgs = @('-3') } else { $py = Get-Command python.exe -ErrorAction SilentlyContinue }
    if (-not $py -or $py.Source -like '*WindowsApps*') {
        Fail "Python 3 is needed to build the awnix filesystem. Install it with:`n    winget install -e --id Python.Python.3.12`nthen run Windows Goodbye again."
    }
    $rootTar = Join-Path $work 'awnix-rootfs.tar'
    Say "Merging $($files.Count) layers into one filesystem..."
    & $py.Source @pyArgs $merger $rootTar @files
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $rootTar)) { Fail "Could not build the root filesystem." }

    # ── 4. Import + open ─────────────────────────────────────────────────────
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Say "Importing into WSL2 as '$DistroName' ($InstallDir)..."
    $r = Invoke-Wsl @('--import', $DistroName, $InstallDir, $rootTar, '--version', '2')
    if ($r.Code -ne 0) { Fail "wsl --import failed: $($r.Text.Trim())" }
    $probe = Invoke-Wsl @('-d', $DistroName, '--', 'cat', '/etc/os-release')
    if ($probe.Code -ne 0) { Fail "Imported, but it does not start: $($probe.Text.Trim()). Remove it with -Uninstall." }
    Say "awnix is installed. Remove it any time with: .\WindowsGoodbye.ps1 -Uninstall" 'Green'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not $NoLaunch) { & wsl.exe -d $DistroName }
