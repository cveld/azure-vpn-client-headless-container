<#
.SYNOPSIS
  Fetches Microsoft Azure VPN Client libs and places them in src/libs/.

.DESCRIPTION
  PowerShell wrapper for fetch-libs.sh (runs in WSL Ubuntu-20.04).
  Automatically reads .env for LIBS_SOURCE and DEB_VERSION.

  Modes (priority order):
    1. -LibsDir DIR   — copy .so files from an existing directory, skip apt
    2. LIBS_SOURCE in .env — same as -LibsDir, picked up automatically from .env
    3. -Local FILE.deb — use a local .deb file, skip apt
    4. apt download    — download via Microsoft apt repo (version from .env or default 3.0.0)

.PARAMETER LibsDir
  Windows path to a directory containing existing .so files.
  Example: -LibsDir "C:\Users\...\libs"

.PARAMETER Local
  Windows path to a local .deb file.
  Example: -Local "C:\...\microsoft-azurevpnclient_3.0.0_amd64.deb"

.PARAMETER Force
  Re-downloads/copies even if libs are already present.

.EXAMPLE
  .\fetch-libs.ps1                                         # apt, version from .env
  .\fetch-libs.ps1 -LibsDir "C:\OneDrive\...\libs"         # copy from existing directory
  .\fetch-libs.ps1 -Local "C:\...\azurevpnclient.deb"      # local .deb
  .\fetch-libs.ps1 -Force                                  # always re-fetch
#>
param(
    [string]$LibsDir = "",
    [string]$Local   = "",
    [switch]$Force
)

# Windows path → WSL path: C:\foo\bar → /mnt/c/foo/bar
function ConvertTo-WslPath {
    param([string]$WinPath)
    if ($WinPath -match '^[A-Za-z]:\\') {
        $drive = $WinPath[0].ToString().ToLower()
        $rest  = $WinPath.Substring(2) -replace '\\', '/'
        return "/mnt/$drive$rest"
    }
    return $WinPath  # al een Unix-pad
}

# Load .env (for LIBS_SOURCE, DEB_VERSION)
function Import-DotEnv {
    param([string]$Path)
    $env_vars = @{}
    if (Test-Path $Path) {
        Get-Content $Path | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith('#') -and $line -match '^([^=]+)=(.*)$') {
                $env_vars[$Matches[1].Trim()] = $Matches[2].Trim()
            }
        }
    }
    return $env_vars
}

$ROOT_WIN = $PSScriptRoot
$ROOT_WSL = ConvertTo-WslPath $ROOT_WIN
$EnvFile  = Join-Path $ROOT_WIN ".env"
$DotEnv   = Import-DotEnv $EnvFile

# Build arguments for the bash script
$BashArgs = @()
if ($Force) { $BashArgs += "--force" }

if ($LibsDir -ne "") {
    # Explicit -LibsDir parameter
    $BashArgs += "--libs-dir `"$(ConvertTo-WslPath $LibsDir)`""
} elseif ($DotEnv.ContainsKey("LIBS_SOURCE") -and $DotEnv["LIBS_SOURCE"] -ne "") {
    # LIBS_SOURCE from .env
    $src = $DotEnv["LIBS_SOURCE"]
    Write-Host "LIBS_SOURCE from .env: $src" -ForegroundColor DarkGray
    $BashArgs += "--libs-dir `"$(ConvertTo-WslPath $src)`""
} elseif ($Local -ne "") {
    $BashArgs += "--local `"$(ConvertTo-WslPath $Local)`""
}

# Pass DEB_VERSION from .env as env var (unless already set)
$EnvPrefix = ""
$debVer = if ($env:DEB_VERSION) { $env:DEB_VERSION } elseif ($DotEnv.ContainsKey("DEB_VERSION")) { $DotEnv["DEB_VERSION"] } else { "" }
if ($debVer -ne "") { $EnvPrefix = "DEB_VERSION=$debVer " }

$BashArgStr = $BashArgs -join " "

Write-Host "fetch-libs: root = $ROOT_WSL" -ForegroundColor Cyan

wsl -d Ubuntu-20.04 -- bash -lc "cd '$ROOT_WSL' && ${EnvPrefix}bash fetch-libs.sh $BashArgStr"
