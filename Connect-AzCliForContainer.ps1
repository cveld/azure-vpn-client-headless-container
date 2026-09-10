<#
.SYNOPSIS
  One-time (or occasional) interactive az login for a container-only,
  Linux-native az CLI cache.
.DESCRIPTION
  Windows az CLI defaults to WAM (Web Account Manager) as its sign-in broker.
  WAM-issued tokens aren't portable -- the actual refresh capability lives in
  the Windows account broker, not in msal_token_cache.bin, so there's no way
  to hand a Windows az CLI login to a Linux container.

  This runs `az login` INSIDE a throwaway Linux container instead, storing
  the result in -Dir (a plain Windows folder, but dedicated to container use
  only -- never point this at a real AZURE_CONFIG_DIR you also use natively
  on Windows; a Linux login would overwrite msal_token_cache.bin with a
  format your native az CLI can no longer read). That login is Linux-native
  MSAL: a normal, portable RefreshToken lands in the cache, so it keeps
  working across container runs until the refresh token itself expires.

  You'll see a device-code prompt (open a URL, enter a code) -- complete it
  in any browser. terraform-vpn.ps1 calls this automatically the first time
  it needs a given container's az CLI cache and it isn't there yet.
.PARAMETER Dir
  Destination directory for the container's az CLI config (mounted at
  /root/.azure). Created if missing.
.PARAMETER TenantId
  Azure AD tenant ID (or domain) to sign into. Passed to `az login --tenant`.
  If omitted, az CLI falls back to your default/home tenant, which is
  usually wrong for a guest/B2B customer tenant.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]
    $Dir,
    [string]
    $TenantId = ''
)

$ErrorActionPreference = 'Stop'
$IMAGE = 'terraform-az:local'

New-Item -ItemType Directory -Force -Path $Dir | Out-Null

function ConvertTo-WslPath ([string]$WinPath) {
    $full = [System.IO.Path]::GetFullPath($WinPath)
    if ($full -notmatch '^[A-Za-z]:\\') {
        Write-Host "  x Not a drive path, can't convert to a WSL mount: $full" -ForegroundColor Red
        exit 1
    }
    $drive = $full[0].ToString().ToLower()
    '/mnt/' + $drive + ($full.Substring(2) -replace '\\', '/')
}

$dirWsl = ConvertTo-WslPath $Dir

# --output none suppresses az login's own post-success dump of every
# accessible subscription (can be a long list) -- we don't need it, ARM_USE_CLI
# just needs a working login; terraform's own backend/provider config
# supplies whichever subscription id it actually needs.
$loginArgs = @('login', '--allow-no-subscriptions', '--output', 'none')
if ($TenantId) { $loginArgs += @('--tenant', $TenantId) }

Write-Host ''
Write-Host "  Signing in (device code) for a Linux-native az CLI cache..." -ForegroundColor Cyan
Write-Host "  Stored separately from your Windows az CLI login, at: $Dir" -ForegroundColor Gray
Write-Host "  A device-code URL + code will appear below -- open it in any browser and sign in." -ForegroundColor Gray
Write-Host ''

# login_experience_v2 adds an interactive tenant/subscription picker to
# `az login` when the account has access to more than one -- not useful here
# since we already pin -tenant, and the specific subscription az CLI ends up
# defaulting to doesn't matter.
wsl -d Ubuntu-20.04 -- docker run --rm -v "${dirWsl}:/root/.azure" --entrypoint az $IMAGE config set core.login_experience_v2=no --only-show-errors
wsl -d Ubuntu-20.04 -- docker run --rm -it -v "${dirWsl}:/root/.azure" --entrypoint az $IMAGE @loginArgs
$exitCode = $LASTEXITCODE

Write-Host ''
if ($exitCode -eq 0) {
    Write-Host "  + Signed in -- container az CLI cache ready." -ForegroundColor DarkGreen
} else {
    Write-Host "  x Sign-in failed (exit $exitCode)." -ForegroundColor Red
}
exit $exitCode
