#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Goodbye -- one command from Windows to awnix, inside WSL2. No reboot.

.DESCRIPTION
    Imports awnix as its own WSL2 distro named "awnix" (or -DistroName) and opens it.

    What it does, in order, and nothing else:
      1. Checks WSL2 is available. If WSL is missing it tells you the one command to
         install it (that needs admin and may need a reboot) and stops.
      2. Downloads the prebuilt awnix filesystem from this repo's latest release and
         checks every part against SHA256SUMS. It was built from the public awnix image
         on Linux and booted in CI before it was published.
      3. Imports it with `wsl --import` into a folder you own.
      4. Opens a shell in it.

    What it never does: touch boot entries, change Windows boot order, reboot,
    install drivers, or ask for admin. Removing it is `-Uninstall` (wsl --unregister).

.PARAMETER DistroName
    The WSL distro name. Default: awnix.

.PARAMETER InstallDir
    Where the distro's virtual disk lives. Default: %LOCALAPPDATA%\awnix\wsl.

.PARAMETER Repo
    The GitHub repo whose latest release carries the awnix filesystem. Default: Aitherium/windowsgoodbye.

.PARAMETER Uninstall
    Unregister the distro (deletes its disk) and stop.

.PARAMETER WslVersion
    2 (default). 1 exists for CI: GitHub's Windows runners cannot nest WSL2.

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
    [string]$Repo = 'Aitherium/windowsgoodbye',
    [switch]$Uninstall,
    [switch]$DryRun,
    [switch]$NoLaunch,
    [ValidateSet('1','2')][string]$WslVersion = '2'
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

# ── 2. Download the prebuilt awnix filesystem (verified) ────────────────────
# Built once on Linux by this repo's rootfs workflow (docker export, then booted and checked
# before release). Split under GitHub's 2 GiB asset cap; every part is checked against
# SHA256SUMS before anything is imported. No Python and no layer handling on this PC.
# A private repo (before the public release) needs a token; GITHUB_TOKEN is used when set.
$gh = @{ 'User-Agent' = 'windowsgoodbye' }
if ($env:GITHUB_TOKEN) { $gh['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }
$rel = Invoke-RestMethod -Headers $gh "https://api.github.com/repos/$Repo/releases/latest"
$parts = @($rel.assets | Where-Object { $_.name -like 'awnix-rootfs.tar.gz.part*' } | Sort-Object name)
$sums = $rel.assets | Where-Object { $_.name -eq 'SHA256SUMS' } | Select-Object -First 1
if (-not $parts.Count -or -not $sums) { Fail "The release $($rel.tag_name) has no awnix filesystem yet." }
$total = ($parts | Measure-Object -Property size -Sum).Sum
Say ("Release {0}: {1} part(s), {2:N0} MB to download." -f $rel.tag_name, $parts.Count, ($total / 1MB))

if ($DryRun) {
    Say "DRY RUN: would download $($parts.Count) part(s), check SHA256SUMS, and run:" 'Yellow'
    Say "  wsl --import $DistroName `"$InstallDir`" <awnix-rootfs.tar.gz> --version 2" 'Yellow'
    exit 0
}

$work = Join-Path $env:TEMP ("windowsgoodbye-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    $want = @{}
    function Get-Asset($a, $out) {
        if ($env:GITHUB_TOKEN) {
            $hh = @{ 'User-Agent' = 'windowsgoodbye'; Authorization = "Bearer $($env:GITHUB_TOKEN)"; Accept = 'application/octet-stream' }
            Invoke-WebRequest -UseBasicParsing -Headers $hh -Uri $a.url -OutFile $out
        } else { Invoke-WebRequest -UseBasicParsing -Uri $a.browser_download_url -OutFile $out }
    }
    $sumsFile = Join-Path $work 'SHA256SUMS'
    Get-Asset $sums $sumsFile
    foreach ($line in ((Get-Content -Raw $sumsFile) -split "`r?`n")) {
        if ($line -match '^([0-9a-f]{64})\s+\*?(\S+)$') { $want[$Matches[2]] = $Matches[1] }
    }
    $rootTar = Join-Path $work 'awnix-rootfs.tar.gz'
    $outStream = [IO.File]::Create($rootTar)
    try {
        $i = 0
        foreach ($p in $parts) {
            $i++
            $f = Join-Path $work $p.name
            Say ("Part {0}/{1} ({2:N0} MB)..." -f $i, $parts.Count, ($p.size / 1MB))
            Get-Asset $p $f
            $got = (Get-FileHash -Algorithm SHA256 -Path $f).Hash.ToLower()
            if (-not $want.ContainsKey($p.name) -or $want[$p.name] -ne $got) {
                Fail "$($p.name) failed its checksum. Nothing was installed."
            }
            $in = [IO.File]::OpenRead($f)
            try { $in.CopyTo($outStream) } finally { $in.Dispose() }
            Remove-Item -LiteralPath $f -Force
        }
    } finally { $outStream.Dispose() }

    # ── 4. Import + open ─────────────────────────────────────────────────────
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Say "Importing into WSL2 as '$DistroName' ($InstallDir)..."
    $r = Invoke-Wsl @('--import', $DistroName, $InstallDir, $rootTar, '--version', $WslVersion)
    if ($r.Code -ne 0) { Fail "wsl --import failed: $($r.Text.Trim())" }
    $probe = Invoke-Wsl @('-d', $DistroName, '--', 'cat', '/etc/os-release')
    if ($probe.Code -ne 0) { Fail "Imported, but it does not start: $($probe.Text.Trim()). Remove it with -Uninstall." }
    Say "awnix is installed. Remove it any time with: .\WindowsGoodbye.ps1 -Uninstall" 'Green'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not $NoLaunch) { & wsl.exe -d $DistroName }
