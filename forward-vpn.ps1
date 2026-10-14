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
.PARAMETER Caddy
  Also publish every forwarded host under its own name through the local Caddy (admin API, -CaddyAdmin): adds a hosts
  entry 127.0.0.1 <host>, a `tls internal` policy and a reverse_proxy route <host> -> 127.0.0.1:<local port> that talks
  TLS to the upstream with SNI <host>. Browsers then open https://<host>/ with the real name, so cookies, SSO redirect
  URIs and the Host header stay as on the real site. Intended for HTTPS hosts (target port 443). The routes are runtime
  routes (@id fwd-vpn-*) and disappear on a Caddy restart/reload; rerun the script to restore them. -Stop removes them
  and the hosts entries again.
.PARAMETER CaddyAdmin
  Caddy admin API URL. Default http://127.0.0.1:2019 (never localhost: that resolves to ::1 first and hangs).
.PARAMETER Stop
  Remove the forwarding sidecar (and the -Caddy routes and hosts entries) and exit.
.EXAMPLE
  .\forward-vpn.ps1 -VpnProfile "igh-insurances-refresh" -Forward "1433=sql-x.database.windows.net:1433","8443=aif-x.openai.azure.com:443"
.EXAMPLE
  .\forward-vpn.ps1 -VpnProfile "igh-insurances-refresh" -Caddy -Forward "8443=dev-int-aiexperiments.ighinsurances.inssolu.com:443"
#>
[CmdletBinding()]
param(
    [string[]]$Forward = @(),
    [string]$VpnProfile = '',
    [string]$Container = '',
    [ValidateSet('shim', 'openvpn')][string]$Method = 'openvpn',
    [switch]$Caddy,
    [string]$CaddyAdmin = 'http://127.0.0.1:2019',
    [switch]$Stop
)
$ErrorActionPreference = 'Stop'
$IMAGE = 'alpine/socat:latest'
$HOSTS_PATH = "$env:windir\System32\drivers\etc\hosts"
$HOSTS_MARKER = '# fwd-vpn-caddy'
$ID_PREFIX = 'fwd-vpn-'

function Write-Step ([string]$Msg, [string]$Color = 'Gray') { Write-Host "  $Msg" -ForegroundColor $Color }
function Invoke-Wsl { wsl -d Ubuntu-20.04 -- @args }

function Invoke-CaddyApi ([string]$Method, [string]$Path, $Body = $null) {
    $p = @{ Method = $Method; Uri = "$CaddyAdmin$Path"; TimeoutSec = 10 }
    if ($null -ne $Body) { $p.ContentType = 'application/json'; $p.Body = ($Body | ConvertTo-Json -Depth 20 -Compress) }
    Invoke-RestMethod @p
}

# Removes the Caddy objects (@id fwd-vpn-*) of earlier runs. Best effort: Caddy may be down.
function Remove-CaddyObjects {
    try {
        $routes = Invoke-CaddyApi GET '/config/apps/http/servers/srv0/routes'
        $policies = Invoke-CaddyApi GET '/config/apps/tls/automation/policies'
    } catch { Write-Step "~ Caddy admin API not reachable at $CaddyAdmin, nothing removed there." Yellow; return }
    # Invoke-RestMethod can hand back a JSON array as one object: flatten both levels before reading @id.
    foreach ($id in @($routes, $policies | ForEach-Object { $_ } | ForEach-Object { $_.'@id' } | Where-Object { $_ -like "$ID_PREFIX*" })) {
        Invoke-CaddyApi DELETE "/id/$id" | Out-Null
        Write-Step "+ Removed Caddy object $id" DarkGreen
    }
}

# Adds/removes marker-tagged hosts lines; elevates once through UAC when not admin.
function Update-HostsEntries ([string[]]$AddHosts = @()) {
    $current = @(Get-Content -LiteralPath $HOSTS_PATH -ErrorAction SilentlyContinue)
    $keep = @($current | Where-Object { $_ -notmatch [regex]::Escape($HOSTS_MARKER) })
    $new = @($AddHosts | ForEach-Object { "127.0.0.1 $_  $HOSTS_MARKER" })
    if ((@($current | Where-Object { $_ -match [regex]::Escape($HOSTS_MARKER) }) -join "`n") -eq ($new -join "`n")) { return }
    $content = (($keep + $new) -join "`r`n") + "`r`n"
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) { [System.IO.File]::WriteAllText($HOSTS_PATH, $content, [System.Text.UTF8Encoding]::new($false)); return }
    $data = [System.IO.Path]::GetTempFileName()
    $tmp = $data -replace '\.tmp$', '.ps1'
    [System.IO.File]::WriteAllText($data, $content, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($tmp, "Copy-Item -LiteralPath '$data' -Destination '$HOSTS_PATH' -Force", [System.Text.UTF8Encoding]::new($false))
    Write-Step '! UAC prompt: editing the hosts file requires admin' Yellow
    try { Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$tmp`"" }
    finally { Remove-Item $data, $tmp -ErrorAction SilentlyContinue }
}

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
    Remove-CaddyObjects
    Update-HostsEntries
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

if ($Caddy) {
    # Idempotent: drop what an earlier run registered, then add one route + one internal-TLS policy per host.
    Remove-CaddyObjects
    foreach ($m in $maps) {
        $h = $m.Host
        Invoke-CaddyApi POST '/config/apps/tls/automation/policies' @{
            '@id' = "${ID_PREFIX}tls-$h"; subjects = @($h); issuers = @(@{ module = 'internal' })
        } | Out-Null
        Invoke-CaddyApi POST '/config/apps/http/servers/srv0/routes' @{
            '@id' = "$ID_PREFIX$h"; match = @(@{ host = @($h) }); terminal = $true
            handle = @(@{
                handler = 'reverse_proxy'; upstreams = @(@{ dial = "127.0.0.1:$($m.Local)" })
                transport = @{ protocol = 'http'; tls = @{ server_name = $h } }
            })
        } | Out-Null
        Write-Step "+ Caddy: https://$h/ -> 127.0.0.1:$($m.Local) (TLS upstream, SNI $h)" DarkGreen
    }
    Update-HostsEntries -AddHosts @($maps.Host | Select-Object -Unique)
    Write-Step "+ Hosts: 127.0.0.1 $(@($maps.Host | Select-Object -Unique) -join ', ')" DarkGreen
}
