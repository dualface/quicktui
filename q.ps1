# QuickTUI Windows bootstrap.
# This script only selects, verifies when possible, and launches the native
# quicktui-installer binary. Installation logic lives in the Rust installer and
# the downloaded quicktui-server setup entry.
#
# Compatible with Windows PowerShell 5.1 and PowerShell 7+. Keep this file
# pure ASCII with LF line endings: PowerShell 5.1 reads BOM-less scripts as
# ANSI, so any non-ASCII byte would be misdecoded.
#
# Exit strategy: when run as a file (pwsh -File q.ps1) failures use `exit` so
# the exit code propagates; when piped through `irm | iex` failures `throw`
# instead, because `exit` would close the user's console session.

# Under `irm | iex` these preference tweaks land in the caller's session, so
# snapshot them here and restore in the trailing finally.
$script:SavedErrorActionPreference = $ErrorActionPreference
$script:SavedProgressPreference = $ProgressPreference
$script:SavedSecurityProtocol = $null
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($PSVersionTable.PSVersion.Major -lt 6) {
    # Windows PowerShell 5.1 on older Windows 10 may not enable TLS 1.2.
    $script:SavedSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

$script:InvokedFromFile = [bool]$MyInvocation.MyCommand.Path

# Under `irm | iex` the $env: defaults below would otherwise leak into the
# caller's session and act as stale user overrides on the next run (e.g. after
# switching to the CN mirror). Snapshot the pre-run values here and restore
# them in the trailing finally, after the installer child has inherited them.
$script:QuickTuiEnvNames = @(
    'QUICKTUI_REPO', 'QUICKTUI_RELEASES', 'QUICKTUI_INSTALLER_RELEASE_TAG',
    'QUICKTUI_INSTALLER_RELEASES', 'QUICKTUI_UPDATE_MANIFEST_URL'
)
$script:QuickTuiEnvSaved = @{}
foreach ($name in $script:QuickTuiEnvNames) {
    $script:QuickTuiEnvSaved[$name] = [Environment]::GetEnvironmentVariable($name)
}
function Restore-QuickTuiEnv {
    foreach ($name in $script:QuickTuiEnvNames) {
        [Environment]::SetEnvironmentVariable($name, $script:QuickTuiEnvSaved[$name])
    }
}

# Default endpoint anchors. The exact shape of the five $env: lines below is a
# three-way contract consumed by (a) tools/qpublish/internal/q2 regexes that
# rewrite the default installer tag on the live site, (b) the awk exact-line
# rewrites in website/scripts/generate-q-sh-cn.sh that produce the China
# mirror variant, and (c) the assertions in website/tests. Do not reformat.
$env:QUICKTUI_REPO = if ($env:QUICKTUI_REPO) { $env:QUICKTUI_REPO } else { "dualface/quicktui" }
$env:QUICKTUI_RELEASES = if ($env:QUICKTUI_RELEASES) { $env:QUICKTUI_RELEASES } else { "https://github.com/$env:QUICKTUI_REPO/releases/latest/download" }
$env:QUICKTUI_INSTALLER_RELEASE_TAG = if ($env:QUICKTUI_INSTALLER_RELEASE_TAG) { $env:QUICKTUI_INSTALLER_RELEASE_TAG } else { "installer-20260719-01" }
$env:QUICKTUI_INSTALLER_RELEASES = if ($env:QUICKTUI_INSTALLER_RELEASES) { $env:QUICKTUI_INSTALLER_RELEASES } else { "https://github.com/$env:QUICKTUI_REPO/releases/download/$env:QUICKTUI_INSTALLER_RELEASE_TAG" }
$env:QUICKTUI_UPDATE_MANIFEST_URL = if ($env:QUICKTUI_UPDATE_MANIFEST_URL) { $env:QUICKTUI_UPDATE_MANIFEST_URL } else { "https://quicktui.ai/server-manifest.json" }

function Fail([string]$Message) {
    [Console]::Error.WriteLine("quicktui bootstrap: $Message")
    if ($script:InvokedFromFile) { exit 1 }
    throw "quicktui bootstrap: $Message"
}

function Write-Usage {
    $usage = @"
QuickTUI Installer Bootstrap

Usage:
  irm https://quicktui.ai/q.ps1 | iex
  & ([scriptblock]::Create((irm https://quicktui.ai/q.ps1))) --preview
  & ([scriptblock]::Create((irm https://quicktui.ai/q.ps1))) [installer options]

Legacy Windows PowerShell 5.1 with TLS 1.2 disabled (irm itself fails there;
run this variant instead):
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; irm https://quicktui.ai/q.ps1 | iex

This Windows bootstrap downloads quicktui-installer-windows-<arch>.exe for the
current CPU and executes it with the original arguments. macOS/Linux users
should run: curl -fsSL https://quicktui.ai/q.sh | sh

Common installer options:
  -y, --yes                 Non-interactive mode
      --release             Install release server
      --preview             Install preview server
      --publish-tag TAG     Install this exact release tag, bypassing manifest
      --token TOKEN         Set access token
      --rotate-token        Generate and save a new token
      --addr HOST[:PORT]    Listen host or host:port
      --port PORT           Listen port used with --addr host
      --no-service          Install binary/config without registering service
      --check               Check runtime dependencies only
      --uninstall           Uninstall existing service via installed server
      --help                Show this help

Environment:
  QUICKTUI_INSTALLER_RELEASES  Installer binary release base URL
  QUICKTUI_INSTALLER_RELEASE_TAG
                                Installer release tag used by default
  QUICKTUI_RELEASES            Server asset release base URL inherited by installer
  QUICKTUI_UPDATE_MANIFEST_URL Server manifest URL inherited by installer

Server channel:
  --release is added by default when neither --release, --preview, nor
  --publish-tag is passed. Use --preview explicitly to select the preview
  server build. Use --publish-tag TAG to install that exact release tag
  directly from the release host, bypassing server-manifest.json entirely.
  The current default installer tag is $env:QUICKTUI_INSTALLER_RELEASE_TAG
  and is independent from server release tags.
"@
    Write-Host $usage
}

function Get-RemoteFile([string]$Url, [string]$OutFile) {
    [Console]::Error.WriteLine("Downloading URL: $Url")
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing | Out-Null
}

$tmpDir = $null
try {
    $argv = @($args)
    if ($argv.Count -gt 0 -and ($argv[0] -eq '-h' -or $argv[0] -eq '--help')) {
        Write-Usage
        return
    }

    $hasChannelArg = $false
    foreach ($arg in $argv) {
        if ($arg -eq '--release' -or $arg -eq '--preview' -or $arg -eq '--publish-tag' -or $arg -like '--publish-tag=*') {
            $hasChannelArg = $true
            break
        }
    }
    if (-not $hasChannelArg) {
        $argv = @('--release') + $argv
    }

    $maxBytesRaw = if ($env:QUICKTUI_MAX_INSTALLER_BYTES) { $env:QUICKTUI_MAX_INSTALLER_BYTES } else { '52428800' }
    if ($maxBytesRaw -notmatch '^[0-9]+$') {
        Fail 'QUICKTUI_MAX_INSTALLER_BYTES must be a byte count'
    }
    $maxBytes = [int64]$maxBytesRaw

    $rawArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $arch = switch (("$rawArch").ToUpperInvariant()) {
        'AMD64' { 'amd64' }
        'ARM64' { 'arm64' }
        default { Fail "unsupported CPU architecture: $rawArch" }
    }

    $asset = "quicktui-installer-windows-$arch.exe"
    $baseUrl = $env:QUICKTUI_INSTALLER_RELEASES.TrimEnd('/')
    $installerUrl = "$baseUrl/$asset"
    $shaUrl = "$installerUrl.sha256"

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('quicktui-installer-' + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    $installerPath = Join-Path $tmpDir $asset
    $shaPath = "$installerPath.sha256"

    [Console]::Error.WriteLine("Downloading installer asset: $asset")
    try {
        Get-RemoteFile $installerUrl $installerPath
    } catch {
        Fail "download failed: $installerUrl"
    }

    $installerSize = (Get-Item -LiteralPath $installerPath).Length
    if ($installerSize -gt $maxBytes) {
        Fail "installer download exceeds $maxBytes bytes"
    }

    $checksumAvailable = $true
    try {
        Get-RemoteFile $shaUrl $shaPath
    } catch {
        $checksumAvailable = $false
        [Console]::Error.WriteLine('quicktui bootstrap: warning: installer checksum not available; continuing without local verification')
    }
    if ($checksumAvailable) {
        $shaText = [System.IO.File]::ReadAllText($shaPath)
        $expected = @($shaText -split '\s+' | Where-Object { $_ })[0]
        if (-not $expected -or $expected -notmatch '^[0-9a-fA-F]{64}$') {
            Fail 'invalid installer checksum file'
        }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $installerPath).Hash.ToLowerInvariant()
        if ($actual -ne $expected.ToLowerInvariant()) {
            Fail 'installer sha256 mismatch'
        }
    }

    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
        # Contract tests run this bootstrap under pwsh on Linux with a mock
        # installer; downloaded files need the executable bit there.
        chmod +x $installerPath
    }

    & $installerPath @argv
    $exitCode = $LASTEXITCODE
} finally {
    # The installer child has already inherited the exported defaults; undo
    # them so an `irm | iex` run leaves the caller's session untouched.
    Restore-QuickTuiEnv
    if ($tmpDir) {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue -LiteralPath $tmpDir
    }
    if ($null -ne $script:SavedSecurityProtocol) {
        [Net.ServicePointManager]::SecurityProtocol = $script:SavedSecurityProtocol
    }
    $ProgressPreference = $script:SavedProgressPreference
    $ErrorActionPreference = $script:SavedErrorActionPreference
}

if ($script:InvokedFromFile) {
    exit $exitCode
}
if ($exitCode -ne 0) {
    throw "quicktui-installer exited with code $exitCode"
}
