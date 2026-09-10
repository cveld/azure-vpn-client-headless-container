#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Run `terraform` through the VPN tunnel — as a sidecar container sharing the
  VPN container's network namespace, so private-endpoint / internal-only Azure
  resources are reachable.
.DESCRIPTION
  Builds (once) a terraform-az:local image (Azure CLI + terraform, see
  src-terraform/Containerfile), then runs it with
  `--network container:<vpn-container-name>` so it reuses the VPN container's
  tun interface and routes. DNS is copied from the VPN container's
  /etc/resolv.conf (it isn't shared via --network container:, only the network
  stack is).

  Azure auth:
    - ARM_CLIENT_ID/ARM_CLIENT_SECRET/ARM_TENANT_ID/ARM_SUBSCRIPTION_ID set
      (service principal) -> passed straight through, az CLI in the sidecar
      is unused.
    - otherwise -> the sidecar gets its own, separate, Linux-native az CLI
      login (ARM_USE_CLI=true), stored at
      %USERPROFILE%\.azurecustomers-container\<vpn-container-name> and kept
      across runs. This is NOT your Windows az CLI session inherited or
      mounted -- Windows az CLI defaults to WAM (Web Account Manager) as its
      sign-in broker, and WAM-issued tokens can't be handed to a Linux
      container at all (the refresh capability lives in the Windows account
      broker, not in a portable cache file). The first time a given VPN
      container's az CLI cache doesn't exist yet, this runs
      Connect-AzCliForContainer.ps1 automatically -- a one-time (or
      occasional, once the login eventually expires) interactive device-code
      prompt, auto-scoped to the right tenant from the VPN profile's own XML.
.PARAMETER VpnProfile
  VPN profile name (exact match, as shown by connect-vpn.ps1). Starts the
  container if it isn't running yet.
.PARAMETER Container
  Explicit VPN container name — use when it's already running. Skips profile
  lookup/auto-start.
.PARAMETER Dir
  Terraform working directory (Windows path). Defaults to the current
  directory. Mounted into the sidecar at /workspace.
.PARAMETER AzDoOrg
  Azure DevOps organization name (e.g. "MyOrg"). When set, pulls a
  cached OAuth token for https://dev.azure.com/<org> from the host's git
  credential helper (git credential fill — same Git Credential Manager
  flow a normal `git clone` on this machine already uses) and hands it to
  the sidecar so `terraform init` can fetch git:: module sources from that
  org without prompting. The container has no git credentials of its own
  and no TTY to prompt on, so without this a private git:: source just
  hangs forever waiting for input that never arrives. Best-effort: if the
  host has no cached credential for that org, this warns and continues —
  useful only when your modules actually live in that org.
.PARAMETER ListProfiles
  List installed VPN profiles (name, derived container name, running status)
  and exit — same source (rasphone.pbk) as connect-vpn.ps1's picker.
.PARAMETER TerraformArgs
  Everything else is passed straight through to `terraform` inside the
  sidecar, e.g. `plan`, `apply -auto-approve`, `init`.
.EXAMPLE
  .\terraform-vpn.ps1 -ListProfiles
.EXAMPLE
  .\terraform-vpn.ps1 -VpnProfile "My Profile" plan
.EXAMPLE
  .\terraform-vpn.ps1 -Container vpn-my-profile apply -auto-approve
.EXAMPLE
  .\terraform-vpn.ps1 init
  # auto-detects the VPN container if exactly one is running
.EXAMPLE
  .\terraform-vpn.ps1 -AzDoOrg MyOrg init
  # also authenticates git:: module sources hosted in that AzDO org
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$VpnProfile = '',
    [string]$Container  = '',
    [string]$Dir        = (Get-Location).Path,
    [string]$AzDoOrg    = '',
    [switch]$ListProfiles,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$TerraformArgs = @()
)

$ErrorActionPreference = 'Stop'
$IMAGE = 'terraform-az:local'
$PBK   = "$env:LOCALAPPDATA\Packages\Microsoft.AzureVpn_8wekyb3d8bbwe\LocalState\rasphone.pbk"

function Write-Step ([string]$Msg, [string]$Color = 'Gray') {
    Write-Host "  $Msg" -ForegroundColor $Color
}

# ── rasphone.pbk parsing (same format as connect-vpn.ps1) ────────────────────
function Read-Pbk ([string]$Path) {
    $list = [System.Collections.Generic.List[hashtable]]::new()
    $cur  = $null
    $hex  = $null
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ($line -match '^\[(.+)\]$') {
            if ($cur) { $cur.Hex = $hex.ToArray(); $list.Add($cur) }
            $cur = @{ Name=''; Hex=@() }
            $cur.Name = $Matches[1]
            $hex = [System.Collections.Generic.List[string]]::new()
        } elseif ($cur -and $line -match '^ThirdPartyProfileInfo=(.+)$') {
            $hex.Add($Matches[1])
        }
    }
    if ($cur) { $cur.Hex = $hex.ToArray(); $list.Add($cur) }
    ,$list
}

function ConvertFrom-ProfileHex ([string[]]$HexLines) {
    $hex   = $HexLines -join ''
    $bytes = [byte[]]::new($hex.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($hex.Substring($i*2, 2), 16)
    }
    # Find <azurevpnprofile> = 3C 00 61 00 7A 00 in UTF-16LE
    $sig = [byte[]]@(0x3C,0x00,0x61,0x00,0x7A,0x00)
    $s   = -1
    for ($i = 0; $i -le $bytes.Length - $sig.Length; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $sig.Length; $j++) { if ($bytes[$i+$j] -ne $sig[$j]) { $ok=$false; break } }
        if ($ok) { $s=$i; break }
    }
    if ($s -lt 0) { return $null }
    $e = $s
    while ($e+1 -lt $bytes.Length) {
        if ($bytes[$e]-eq 0 -and $bytes[$e+1]-eq 0 -and (($e-$s)%2)-eq 0) { break }
        $e += 2
    }
    [System.Text.Encoding]::Unicode.GetString($bytes, $s, $e - $s)
}

function ConvertTo-WslPath ([string]$WinPath) {
    $full = [System.IO.Path]::GetFullPath($WinPath)
    if ($full -notmatch '^[A-Za-z]:\\') {
        Write-Step "x Not a drive path, can't convert to a WSL mount: $full" Red; exit 1
    }
    $drive = $full[0].ToString().ToLower()
    '/mnt/' + $drive + ($full.Substring(2) -replace '\\', '/')
}

# ── Project root → WSL path ───────────────────────────────────────────────────
$_drive = $PSScriptRoot[0].ToString().ToLower()
$_path  = $PSScriptRoot.Substring(2) -replace '\\', '/'
$ROOT   = "/mnt/$_drive$_path"

# ── Resolve the VPN container name ────────────────────────────────────────────
function Get-ContainerNameFromProfile ([string]$Name) {
    'vpn-' + ($Name -replace '[^a-zA-Z0-9-]', '-' -replace '-{2,}', '-').ToLower().Trim('-')
}

# Looks up the AAD tenant ID for whichever installed VPN profile derives to
# $ContainerName, so Connect-AzCliForContainer.ps1 can sign into the right
# tenant without the caller needing to know/pass it explicitly.
function Get-VpnProfileTenantId ([string]$ContainerName) {
    if (-not (Test-Path $PBK)) { return $null }
    foreach ($r in (Read-Pbk $PBK)) {
        if ($r.Hex.Count -eq 0) { continue }
        if ((Get-ContainerNameFromProfile $r.Name) -ne $ContainerName) { continue }
        $xml = ConvertFrom-ProfileHex $r.Hex
        if ($xml -match '<tenant>https://login\.microsoftonline\.com/([^/]+)') { return $Matches[1] }
        return $null
    }
    return $null
}

# ── -ListProfiles: print installed VPN profiles and exit ─────────────────────
if ($ListProfiles) {
    if (-not (Test-Path $PBK)) { Write-Step "x rasphone.pbk not found: $PBK" Red; exit 1 }
    $running = @(wsl -d Ubuntu-20.04 -- docker ps --format '{{.Names}}' 2>$null)
    $profiles = @(foreach ($r in (Read-Pbk $PBK)) {
        if ($r.Hex.Count -eq 0) { continue }
        $xml = ConvertFrom-ProfileHex $r.Hex
        if (-not $xml) { continue }
        [pscustomobject]@{
            Name      = $r.Name
            Container = Get-ContainerNameFromProfile $r.Name
            Running   = if ($running -contains (Get-ContainerNameFromProfile $r.Name)) { 'yes' } else { '' }
        }
    })
    if ($profiles.Count -eq 0) { Write-Step 'No VPN profiles found.' Red; exit 1 }
    $profiles | Format-Table -AutoSize
    exit 0
}

$running = @(wsl -d Ubuntu-20.04 -- docker ps --format '{{.Names}}' 2>$null)

if ($Container) {
    $CNTR = $Container
} elseif ($VpnProfile) {
    $CNTR = Get-ContainerNameFromProfile $VpnProfile
} else {
    $candidates = @($running | Where-Object { $_ -like 'vpn-*' -or $_ -eq 'azurevpntunnel' })
    if ($candidates.Count -eq 1) {
        $CNTR = $candidates[0]
        Write-Step "+ Auto-detected VPN container: $CNTR" DarkGreen
    } elseif ($candidates.Count -eq 0) {
        Write-Step 'x No VPN container running.' Red
        Write-Step '  Pass -VpnProfile <name> to start one, or -Container <name> if it runs under a custom name.' Yellow
        exit 1
    } else {
        Write-Step "x Multiple VPN containers running: $($candidates -join ', ')" Red
        Write-Step '  Pass -Container <name> to disambiguate.' Yellow
        exit 1
    }
}

# ── Ensure it's running ───────────────────────────────────────────────────────
if ($running -notcontains $CNTR) {
    if ($VpnProfile) {
        Write-Step "Starting VPN container for '$VpnProfile'..." Cyan
        & (Join-Path $PSScriptRoot 'connect-vpn.ps1') -VpnProfile $VpnProfile
        if ($LASTEXITCODE -ne 0) { Write-Step 'x VPN connect failed.' Red; exit 1 }
    } else {
        Write-Step "x Container '$CNTR' is not running." Red
        Write-Step '  Start it first (connect-vpn.ps1), or pass -VpnProfile to start it automatically.' Yellow
        exit 1
    }
}

# ── Build the terraform-az sidecar image if missing ───────────────────────────
wsl -d Ubuntu-20.04 -- docker image inspect $IMAGE 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Step "Building image $IMAGE (one-time)..." Yellow
    wsl -d Ubuntu-20.04 -- bash -lc "cd '$ROOT' && docker build -f src-terraform/Containerfile -t $IMAGE src-terraform"
    if ($LASTEXITCODE -ne 0) { Write-Step 'x Image build failed.' Red; exit 1 }
}

# ── Copy DNS from the VPN container ───────────────────────────────────────────
# --network container:<name> shares the network stack (tun0, routes) but NOT
# /etc/resolv.conf — that's a filesystem file the runner.sh DNS-poller wrote
# inside the VPN container only. Grab it so the sidecar can resolve private
# endpoints reachable only over the tunnel.
$resolvWsl = "/tmp/terraform-vpn-resolv-$CNTR.conf"
wsl -d Ubuntu-20.04 -- bash -lc "docker exec $CNTR cat /etc/resolv.conf > '$resolvWsl'"
if ($LASTEXITCODE -ne 0) { Write-Step 'x Could not read /etc/resolv.conf from the VPN container.' Red; exit 1 }

# ── Azure auth: service principal env vars, or az CLI config mount ───────────
$envLines = @()
$azMountArgs = @()
if ($env:ARM_CLIENT_ID) {
    Write-Step '+ Using service-principal auth (ARM_CLIENT_ID set)' DarkGreen
    foreach ($v in 'ARM_CLIENT_ID', 'ARM_CLIENT_SECRET', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID') {
        $val = [Environment]::GetEnvironmentVariable($v)
        if ($val) { $envLines += "$v=$val" }
    }
} else {
    # Windows az CLI defaults to WAM (Web Account Manager) as its sign-in
    # broker; WAM-issued tokens aren't portable (the refresh capability lives
    # in the Windows account broker, not in msal_token_cache.bin), so a
    # Windows az CLI login can't be handed to a Linux container at all. Give
    # the sidecar its own, separate, Linux-native az CLI login instead --
    # keyed on $CNTR so it's always resolvable regardless of whether this run
    # used -VpnProfile, -Container, or auto-detection.
    $containerAzDir = Join-Path $env:USERPROFILE ".azurecustomers-container\$CNTR"
    # Linux az CLI (no keyring available -> unencrypted FilePersistence) names
    # this msal_token_cache.json, not .bin like Windows' DPAPI-protected one.
    $cacheFile = Join-Path $containerAzDir 'msal_token_cache.json'
    if (-not (Test-Path $cacheFile)) {
        Write-Step "No container-side az login found for '$CNTR' yet." Yellow
        $tenantId = Get-VpnProfileTenantId $CNTR
        $connectParams = @{ Dir = $containerAzDir }
        if ($tenantId) { $connectParams.TenantId = $tenantId }
        & (Join-Path $PSScriptRoot 'Connect-AzCliForContainer.ps1') @connectParams
        if ($LASTEXITCODE -ne 0) { Write-Step 'x az login for the sidecar failed.' Red; exit 1 }
    }
    Write-Step "+ Using az CLI auth (container login: $containerAzDir)" DarkGreen
    $azConfigWsl = ConvertTo-WslPath $containerAzDir
    $azMountArgs = @('-v', "${azConfigWsl}:/root/.azure")
    $envLines += 'ARM_USE_CLI=true'
    if ($env:ARM_SUBSCRIPTION_ID) { $envLines += "ARM_SUBSCRIPTION_ID=$($env:ARM_SUBSCRIPTION_ID)" }
}

# Never let git block forever on a prompt the sidecar has no TTY to answer.
$envLines += 'GIT_TERMINAL_PROMPT=0'

# ── Azure DevOps git auth: hand the host's cached credential to the sidecar ──
if ($AzDoOrg) {
    Write-Step "Fetching cached git credential for dev.azure.com/$AzDoOrg..." Cyan
    $credInput = "protocol=https`nhost=dev.azure.com`npath=$AzDoOrg`n`n"
    $credOutput = $credInput | git credential fill 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Step "~ Could not get a cached git credential for '$AzDoOrg' ($($credOutput -join ' ')) — git:: module sources in that org will fail." Yellow
    } else {
        $azdoUser = ($credOutput | Where-Object { $_ -match '^username=' }) -replace '^username=', ''
        $azdoPass = ($credOutput | Where-Object { $_ -match '^password=' }) -replace '^password=', ''
        if ($azdoUser -and $azdoPass) {
            Write-Step '+ Git credential for dev.azure.com found' DarkGreen
            $envLines += "GIT_AZDO_USERNAME=$azdoUser"
            $envLines += "GIT_AZDO_PASSWORD=$azdoPass"
        } else {
            Write-Step "~ git credential fill returned no username/password for '$AzDoOrg'." Yellow
        }
    }
}

# env-file so secrets never appear on the wsl/docker command line.
$envFileWin = Join-Path $env:TEMP "terraform-vpn-$([guid]::NewGuid()).env"
[System.IO.File]::WriteAllText($envFileWin, ($envLines -join "`n"), [System.Text.UTF8Encoding]::new($false))
$envFileWsl = ConvertTo-WslPath $envFileWin

# ── Terraform working directory ───────────────────────────────────────────────
$tfDirWsl = ConvertTo-WslPath $Dir

# ── Run ────────────────────────────────────────────────────────────────────────
Write-Step "Running terraform in $Dir (via $CNTR)..." Cyan
try {
    $dockerArgs = @(
        'docker', 'run', '--rm', '-it',
        '--network', "container:$CNTR",
        '-v', "${resolvWsl}:/etc/resolv.conf:ro",
        '-v', "${tfDirWsl}:/workspace",
        '--env-file', $envFileWsl
    ) + $azMountArgs + @($IMAGE) + $TerraformArgs

    wsl -d Ubuntu-20.04 -- @dockerArgs
    exit $LASTEXITCODE
} finally {
    Remove-Item $envFileWin -ErrorAction SilentlyContinue
    wsl -d Ubuntu-20.04 -- rm -f $resolvWsl 2>$null | Out-Null
}
