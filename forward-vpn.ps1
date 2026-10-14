#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Forwards local ports (127.0.0.1 on Windows) to hosts that are only reachable through the VPN tunnel.
.DESCRIPTION
  Runs a socat sidecar in the VPN container's network namespace (--network container:<vpn>), so it uses tun0 and the
  tunnel DNS. A sidecar cannot publish ports itself: the VPN container must have been started with the same ports
  (connect-vpn.ps1 -VpnProfile <name> -Publish 1433,8443). The sidecar is named fwd-<vpn container> and is replaced on
  every run; stop it with -Stop.
.PARAMETER Forward
  One or more "<local port>=<host>:<port>" mappings, e.g. "1433=sql-x.database.windows.net:1433".
.PARAMETER VpnProfile
  VPN profile name; starts the VPN container (publishing the local ports) when it is not running yet.
.PARAMETER Container
  Explicit VPN container name. Without -VpnProfile and -Container the only running vpn-* container is used.
.PARAMETER Method
  Launcher used to start the VPN container: openvpn (default, connect-vpn-openvpn.ps1) or shim (connect-vpn.ps1).
.PARAMETER Stop
  Remove the forwarding sidecar and exit.
.EXAMPLE
  .\forward-vpn.ps1 -VpnProfile "igh-insurances-refresh" -Forward "1433=sql-x.database.windows.net:1433","8443=aif-x.openai.azure.com:443"
#>
[CmdletBinding()]
param(
    [string[]]$Forward = @(),
    [string]$VpnProfile = '',
    [string]$Container = '',
    [ValidateSet('shim', 'openvpn')][string]$Method = 'openvpn',
    [switch]$Stop
)
$ErrorActionPreference = 'Stop'
$IMAGE = 'alpine/socat:latest'

function Write-Step ([string]$Msg, [string]$Color = 'Gray') { Write-Host "  $Msg" -ForegroundColor $Color }
function Invoke-Wsl { wsl -d Ubuntu-20.04 -- @args }

function Get-ContainerNameFromProfile ([string]$Name) {
    'vpn-' + ($Name -replace '[^a-zA-Z0-9-]', '-' -replace '-{2,}', '-').ToLower().Trim('-')
}

$maps = foreach ($f in $Forward) {
    if ($f -notmatch '^(\d{1,5})=([A-Za-z0-9.-]+):(\d{1,5})$') { throw "Bad -Forward '$f', expected <local port>=<host>:<port>" }
    [pscustomobject]@{ Local = [int]$Matches[1]; Host = $Matches[2]; Port = [int]$Matches[3] }
}

$running = @(Invoke-Wsl docker ps --format '{{.Names}}' 2>$null)
if ($Container) { $CNTR = $Container }
elseif ($VpnProfile) { $CNTR = (Get-ContainerNameFromProfile $VpnProfile) + $(if ($Method -eq 'openvpn') { '-ovpn' } else { '' }) }
else {
    $candidates = @($running | Where-Object { $_ -like 'vpn-*' -or $_ -eq 'azurevpntunnel' })
    if ($candidates.Count -ne 1) { throw "Expected exactly one running VPN container, found $($candidates.Count): pass -Container or -VpnProfile." }
    $CNTR = $candidates[0]
}
$SIDECAR = "fwd-$CNTR"

if ($Stop) {
    Invoke-Wsl docker rm -f $SIDECAR 2>&1 | Out-Null
    Write-Step "+ Removed $SIDECAR" DarkGreen
    exit 0
}
if (-not $maps) { throw 'Pass at least one -Forward mapping.' }

if ($running -notcontains $CNTR) {
    if (-not $VpnProfile) { throw "VPN container '$CNTR' is not running; pass -VpnProfile to start it." }
    Write-Step "Starting VPN container for '$VpnProfile' (publishing $($maps.Local -join ', '))..." Cyan
    & (Join-Path $PSScriptRoot $(if ($Method -eq 'shim') { 'connect-vpn.ps1' } else { 'connect-vpn-openvpn.ps1' })) -VpnProfile $VpnProfile -Publish $maps.Local
    if ($LASTEXITCODE -ne 0) { throw 'VPN connect failed.' }
}

# The VPN container must publish every local port; that cannot be added to a running container.
$published = @(Invoke-Wsl docker port $CNTR | ForEach-Object { if ($_ -match '^(\d+)/tcp') { [int]$Matches[1] } })
$missing = @($maps.Local | Where-Object { $published -notcontains $_ })
if ($missing) {
    throw "VPN container '$CNTR' does not publish port(s) $($missing -join ', '). Recreate it: docker rm -f $CNTR, then connect-vpn.ps1 -VpnProfile <name> -Publish $($maps.Local -join ',')."
}

Invoke-Wsl docker image inspect $IMAGE 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Step "Pulling $IMAGE (one-time)..." Yellow; Invoke-Wsl docker pull $IMAGE | Out-Null }

# The tunnel DNS lives in the VPN container's /etc/resolv.conf, which --network container: does not share.
$resolv = "/tmp/fwd-vpn-resolv-$CNTR.conf"
Invoke-Wsl bash -lc "docker exec $CNTR cat /etc/resolv.conf > '$resolv'"
if ($LASTEXITCODE -ne 0) { throw 'Could not read /etc/resolv.conf from the VPN container.' }

# One socat per mapping; the shell keeps the container alive.
$script = (($maps | ForEach-Object { "socat TCP-LISTEN:$($_.Local),fork,reuseaddr,bind=0.0.0.0 TCP:$($_.Host):$($_.Port) &" }) -join ' ') + ' wait'
Invoke-Wsl docker rm -f $SIDECAR 2>&1 | Out-Null
Invoke-Wsl docker run -d --name $SIDECAR --restart unless-stopped --network "container:$CNTR" `
    -v "${resolv}:/etc/resolv.conf:ro" --entrypoint sh $IMAGE -c $script | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not start the forwarding sidecar.' }

foreach ($m in $maps) { Write-Step "+ 127.0.0.1:$($m.Local) -> $($m.Host):$($m.Port) (via $CNTR)" DarkGreen }
