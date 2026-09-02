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

  Azure auth is inherited from the current PowerShell session, same as
  az-context.ps1 leaves it:
    - ARM_CLIENT_ID/ARM_CLIENT_SECRET/ARM_TENANT_ID/ARM_SUBSCRIPTION_ID set
      (service principal) -> passed straight through, az CLI in the sidecar
      is unused.
    - otherwise -> AZURE_CONFIG_DIR (or ~/.azure) is bind-mounted into the
      sidecar and ARM_USE_CLI=true, so the azurerm provider shells out to the
      already-logged-in az CLI.
.PARAMETER VpnProfile
  VPN profile name (exact match, as shown by connect-vpn.ps1). Starts the
  container if it isn't running yet.
.PARAMETER Container
  Explicit VPN container name — use when it's already running. Skips profile
  lookup/auto-start.
.PARAMETER Dir
  Terraform working directory (Windows path). Defaults to the current
  directory. Mounted into the sidecar at /workspace.
.PARAMETER ListProfiles
  List installed VPN profiles (name, derived container name, running status)
  and exit — same source (rasphone.pbk) as connect-vpn.ps1's picker.
.PARAMETER TerraformArgs
  Everything else is passed straight through to `terraform` inside the
  sidecar, e.g. `plan`, `apply -auto-approve`, `init`.
.EXAMPLE
  .\terraform-vpn.ps1 -ListProfiles
.EXAMPLE
  .\terraform-vpn.ps1 -VpnProfile "IGH - Insurances" plan
.EXAMPLE
  .\terraform-vpn.ps1 -Container vpn-my-profile apply -auto-approve
.EXAMPLE
  .\terraform-vpn.ps1 init
  # auto-detects the VPN container if exactly one is running
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$VpnProfile = '',
    [string]$Container  = '',
    [string]$Dir        = (Get-Location).Path,
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
    $azConfigDir = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.azure' }
    if (-not (Test-Path $azConfigDir)) {
        Write-Step "x No az CLI login found ($azConfigDir missing) and ARM_CLIENT_ID not set." Red
        Write-Step '  Run az login (or az-context.ps1) first, or set ARM_CLIENT_ID/... for a service principal.' Yellow
        exit 1
    }
    Write-Step "+ Using az CLI auth (mounting $azConfigDir)" DarkGreen
    $azConfigWsl = ConvertTo-WslPath $azConfigDir
    $azMountArgs = @('-v', "${azConfigWsl}:/root/.azure")
    $envLines += 'ARM_USE_CLI=true'
    if ($env:ARM_SUBSCRIPTION_ID) { $envLines += "ARM_SUBSCRIPTION_ID=$($env:ARM_SUBSCRIPTION_ID)" }
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
