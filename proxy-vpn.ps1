#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Runs an HTTP(S) forward proxy (tinyproxy) on 127.0.0.1 of Windows whose outbound traffic goes through the VPN tunnel.
.DESCRIPTION
  A tinyproxy sidecar shares the VPN container's network namespace (--network container:<vpn>), so it uses tun0 and the
  tunnel DNS. The VPN container publishes the proxy port on 127.0.0.1 (connect-vpn.ps1 -Publish <port>, done
  automatically when -VpnProfile starts it). Point a browser proxy extension (FoxyProxy) at 127.0.0.1:<port> for the
  private sites only; the browser keeps the real host name, so TLS, cookies and SSO redirect URIs work unchanged.
  The sidecar is named proxy-<vpn container> and is replaced on every run; stop it with -Stop.
.PARAMETER Port
  Proxy port on 127.0.0.1. Default 8888.
.PARAMETER VpnProfile
  VPN profile name; starts the VPN container (publishing the proxy port) when it is not running yet.
.PARAMETER Container
  Explicit VPN container name. Without -VpnProfile and -Container the only running vpn-* container is used.
.PARAMETER Method
  Launcher used to start the VPN container: openvpn (default, connect-vpn-openvpn.ps1) or shim (connect-vpn.ps1).
.PARAMETER Stop
  Remove the proxy sidecar and exit.
.EXAMPLE
  .\proxy-vpn.ps1 -VpnProfile "IGH - Insurances (refresh)"
  # FoxyProxy: HTTP proxy 127.0.0.1:8888, pattern *.ighinsurances.inssolu.com
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)][int]$Port = 8888,
    [string]$VpnProfile = '',
    [string]$Container = '',
    [ValidateSet('shim', 'openvpn')][string]$Method = 'openvpn',
    [switch]$Stop
)
$ErrorActionPreference = 'Stop'
$IMAGE = 'tinyproxy-vpn:local'

function Write-Step ([string]$Msg, [string]$Color = 'Gray') { Write-Host "  $Msg" -ForegroundColor $Color }
function Invoke-Wsl { wsl -d Ubuntu-20.04 -- @args }
function Get-ContainerNameFromProfile ([string]$Name) {
    'vpn-' + ($Name -replace '[^a-zA-Z0-9-]', '-' -replace '-{2,}', '-').ToLower().Trim('-')
}

$running = @(Invoke-Wsl docker ps --format '{{.Names}}' 2>$null)
if ($Container) { $CNTR = $Container }
elseif ($VpnProfile) { $CNTR = (Get-ContainerNameFromProfile $VpnProfile) + $(if ($Method -eq 'openvpn') { '-ovpn' } else { '' }) }
else {
    $candidates = @($running | Where-Object { $_ -like 'vpn-*' -or $_ -eq 'azurevpntunnel' })
    if ($candidates.Count -ne 1) { throw "Expected exactly one running VPN container, found $($candidates.Count): pass -Container or -VpnProfile." }
    $CNTR = $candidates[0]
}
$SIDECAR = "proxy-$CNTR"

if ($Stop) {
    Invoke-Wsl docker rm -f $SIDECAR 2>&1 | Out-Null
    Write-Step "+ Removed $SIDECAR" DarkGreen
    exit 0
}

if ($running -notcontains $CNTR) {
    if (-not $VpnProfile) { throw "VPN container '$CNTR' is not running; pass -VpnProfile to start it." }
    Write-Step "Starting VPN container for '$VpnProfile' (publishing $Port)..." Cyan
    & (Join-Path $PSScriptRoot $(if ($Method -eq 'shim') { 'connect-vpn.ps1' } else { 'connect-vpn-openvpn.ps1' })) -VpnProfile $VpnProfile -Publish $Port
    if ($LASTEXITCODE -ne 0) { throw 'VPN connect failed.' }
}

# The VPN container must publish the port; that cannot be added to a running container.
$published = @(Invoke-Wsl docker port $CNTR | ForEach-Object { if ($_ -match '^(\d+)/tcp') { [int]$Matches[1] } })
if ($published -notcontains $Port) {
    throw "VPN container '$CNTR' does not publish port $Port. Recreate it: docker rm -f $CNTR, then connect-vpn-openvpn.ps1 -VpnProfile <name> -Publish $Port."
}

Invoke-Wsl docker image inspect $IMAGE 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Step "Building $IMAGE (one-time)..." Yellow
    # Built on Docker's normal network; no ConnectPort restriction so any HTTPS port can be tunnelled.
    # The Dockerfile is piped inside WSL: piping from PowerShell into the Invoke-Wsl function does not reach docker's stdin.
    Invoke-Wsl bash -lc "printf 'FROM alpine:3.20\nRUN apk add --no-cache tinyproxy\n' | docker build -t $IMAGE - >/dev/null"
    if ($LASTEXITCODE -ne 0) { throw 'Could not build the tinyproxy image.' }
}

# The tunnel DNS lives in the VPN container's /etc/resolv.conf, which --network container: does not share.
$resolv = "/tmp/proxy-vpn-resolv-$CNTR.conf"
Invoke-Wsl bash -lc "docker exec $CNTR cat /etc/resolv.conf > '$resolv'"
if ($LASTEXITCODE -ne 0) { throw 'Could not read /etc/resolv.conf from the VPN container.' }

# Listen on every address of the shared namespace and allow all clients: the only way in is the 127.0.0.1 publish.
$conf = "Port $Port`nListen 0.0.0.0`nTimeout 600`nAllow 0.0.0.0/0`nLogLevel Info`nDisableViaHeader Yes"
$script = "printf '%s\n' '$($conf -replace "`n", "' '")' > /tmp/tinyproxy.conf && exec tinyproxy -d -c /tmp/tinyproxy.conf"
Invoke-Wsl docker rm -f $SIDECAR 2>&1 | Out-Null
Invoke-Wsl docker run -d --name $SIDECAR --restart unless-stopped --network "container:$CNTR" `
    -v "${resolv}:/etc/resolv.conf:ro" --entrypoint sh $IMAGE -c $script | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not start the proxy sidecar.' }

Write-Step "+ HTTP proxy 127.0.0.1:$Port -> tunnel of $CNTR" DarkGreen
Write-Step "FoxyProxy: type HTTP, host 127.0.0.1, port $Port, patterns only for the private sites."
