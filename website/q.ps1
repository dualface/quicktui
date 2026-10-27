# QuickTUI Windows bootstrap.
# This script only selects, downloads, and launches the native
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

# IEX inherits MyInvocation from its caller, which can itself be a .ps1.
# The active frame's source path distinguishes a file from evaluated text.
$script:InvokedFromFile = [bool](Get-PSCallStack)[0].ScriptName

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
$env:QUICKTUI_INSTALLER_RELEASE_TAG = if ($env:QUICKTUI_INSTALLER_RELEASE_TAG) { $env:QUICKTUI_INSTALLER_RELEASE_TAG } else { "installer-20261024-03" }
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
  & ([scriptblock]::Create((irm https://quicktui.ai/q.ps1))) install --channel preview
  & ([scriptblock]::Create((irm https://quicktui.ai/q.ps1))) [installer command and options]

Legacy Windows PowerShell 5.1 with TLS 1.2 disabled (irm itself fails there;
run this variant instead):
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; irm https://quicktui.ai/q.ps1 | iex

This Windows bootstrap downloads quicktui-installer-windows-<arch>.exe for the
current CPU and executes it with the original arguments. macOS/Linux users
should run: curl -fsSL https://quicktui.ai/q.sh | sh

Installer commands:
  install                   Install or upgrade the QuickTUI server
  check [--server PATH]     Check runtime dependencies of the selected server
  uninstall                 Uninstall existing service via installed server

Install source (choose at most one):
  --channel server2|preview
                            Install from the server2 (official) or preview
                            channel
  --tag TAG                 Install this exact release tag, bypassing manifest
  (none)                    Install the server manifest default channel
                            (server2 when the manifest sets none)

Install options:
  -y, --yes                 Non-interactive mode
      --addr HOST[:PORT]|URL Listen host, host:port, or http(s)://host:port
                            (scheme/quotes stripped; listen stays plain HTTP)
      --port PORT           Listen port used with --addr host
      --term TERM           TERM value for tmux
      --lang LANG           LANG value for tmux
      --no-service          Install binary/config without registering service
  -h, --help                Show this help

Legacy flat compatibility:
  --preview | --publish-tag TAG
  --check [--server PATH] | --uninstall
  --required-version-2      Accepted as a compatibility no-op
  Flat install options without a source use the manifest default channel.

Check source:
  check uses --server PATH when given, then an installed server if available.
  Otherwise it downloads a signed server temporarily. Check does not install it.

Environment:
  QUICKTUI_INSTALLER_RELEASES  Installer binary release base URL
  QUICKTUI_INSTALLER_RELEASE_TAG
                                Installer release tag used by default
  QUICKTUI_RELEASES            Server asset release base URL inherited by installer
  QUICKTUI_UPDATE_MANIFEST_URL Server manifest URL inherited by installer

Server channel:
  With no arguments, bootstrap maps to "install"; the installer then picks
  the server manifest default channel.
  Non-empty command-tree and legacy flat arguments are passed through unchanged.
  The current default installer tag is $env:QUICKTUI_INSTALLER_RELEASE_TAG
  and is independent from server release tags.
"@
    Write-Host $usage
}

function Get-RemoteFile([string]$Url, [string]$OutFile) {
    [Console]::Error.WriteLine("Downloading URL: $Url")
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing | Out-Null
}

function Invoke-Installer([string]$Path, [string[]]$Arguments, [ref]$ExitCode) {
    # Keep these preferences local: a nonzero child exit is a result, while
    # failure to create the child is an exception (also on PowerShell 7.3+).
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    # A failed CreateProcess does not set LASTEXITCODE. Do not reuse a
    # previous native command result from the caller.
    # PowerShell writes native results to global scope even inside a function.
    $global:LASTEXITCODE = $null
    try {
        & $Path @Arguments
    } catch {
        throw (("quicktui bootstrap: installer could not be started: {0}`n" +
            "If Windows reports an Application Control block, check Microsoft-Windows-CodeIntegrity/Operational in Event Viewer. " +
            "A trusted Authenticode signature or an administrator-approved policy may be required.") -f $_.Exception.Message)
    }
    $ExitCode.Value = $global:LASTEXITCODE
}

$tmpDir = $null
$bootstrapError = $null
try {
    $argv = @($args)
    if ($argv.Count -gt 0 -and ($argv[0] -eq '-h' -or $argv[0] -eq '--help' -or $argv[0] -eq 'help')) {
        Write-Usage
        return
    }

    # Zero-arg shortcut: plain install, so the installer applies the manifest
    # default channel. Non-empty args pass through unchanged.
    if ($argv.Count -eq 0) {
        $argv = @('install')
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

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('quicktui-installer-' + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    $installerPath = Join-Path $tmpDir $asset

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

    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
        # Contract tests run this bootstrap under pwsh on Linux with a mock
        # installer; downloaded files need the executable bit there.
        chmod +x $installerPath
    }

    $exitCode = $null
    Invoke-Installer $installerPath $argv ([ref]$exitCode)
    if ($null -eq $exitCode) {
        # No result alone does not prove that UAC launched a detached child.
        Fail 'installer returned no exit code; installation success cannot be confirmed. If a separate UAC window opened, check that window for the result'
    }
} catch {
    # Delay propagation until preferences have been restored. Otherwise a
    # native launch error can resume under the caller's Continue preference
    # after finally and fall through to a misleading empty exit-code error.
    $bootstrapError = $_
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

if ($null -ne $bootstrapError) {
    if ($script:InvokedFromFile) {
        [Console]::Error.WriteLine($bootstrapError.Exception.Message)
        exit 1
    }
    throw $bootstrapError
}
if ($script:InvokedFromFile) {
    exit $exitCode
}
if ($exitCode -ne 0) {
    throw "quicktui-installer exited with code $exitCode"
}
