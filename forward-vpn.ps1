#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Forwards local ports (127.0.0.1 on Windows) to hosts that are only reachable through the VPN tunnel.
.DESCRIPTION
  Runs socat inside the OpenVPN container, using its tunnel and DNS. The VPN container must have been started with
  the same ports (connect-vpn-openvpn.ps1 -VpnProfile <name> -Publish 1433,8443).
  Configuration persists with the profile and is restored after restarts; stop forwarding with -Stop.
.PARAMETER Forward
  One or more "<local port>=<host>:<port>" mappings, e.g. "1433=sql-x.database.windows.net:1433".
.PARAMETER VpnProfile
  VPN profile name; starts the VPN container (publishing the local ports) when it is not running yet.
.PARAMETER Container
  Explicit VPN container name. Without -VpnProfile and -Container the only running vpn-* container is used.
.PARAMETER Method
  Built-in services require openvpn. The shim option is retained only to stop legacy sidecars.
.PARAMETER ExtraPublish
  Extra ports the VPN container has to publish on 127.0.0.1 when this script starts it, for other services that share its
  namespace (proxy-vpn.ps1 uses 8888). They are not forwarded here; the container is only created with them.
.PARAMETER Caddy
  Also publish every forwarded host under its own name through the local Caddy (admin API, -CaddyAdmin): adds a hosts
  entry 127.0.0.1 <host>, a `tls internal` policy and a reverse_proxy route <host> -> 127.0.0.1:<local port> that talks
  TLS to the upstream with SNI <host>. Browsers then open https://<host>/ with the real name, so cookies, SSO redirect
  URIs and the Host header stay as on the real site. Intended for HTTPS hosts (target port 443). The routes are runtime
  routes (@id fwd-vpn-*) and disappear on a Caddy restart/reload; rerun the script to restore them. -Stop removes them
  and the hosts entries again.
.PARAMETER CaddyHost
  Like -Caddy, but only for the listed forwarded hosts (the other -Forward mappings stay plain 127.0.0.1 ports, without a
  hosts entry). Use it when only a web site has to be browsed under its real name and SQL or other services must keep
  resolving normally.
.PARAMETER CaddyOff
  Remove the Caddy routes and hosts entries of an earlier -Caddy/-CaddyHost run, without touching forwarding.
.PARAMETER CaddyAdmin
  Caddy admin API URL. Default http://127.0.0.1:2019 (never localhost: that resolves to ::1 first and hangs).
.PARAMETER NoPrompt
  Unattended run (openvpn method): when the VPN container has to be started, refresh the token silently only and exit 4
  instead of opening a sign-in window or printing a device code when an interactive sign-in is needed.
.PARAMETER Stop
  Stop built-in forwarding (and the -Caddy routes and hosts entries) and exit.
.EXAMPLE
  .\forward-vpn.ps1 -VpnProfile "igh-insurances-refresh" -Forward "1433=sql-x.database.windows.net:1433","8443=aif-x.openai.azure.com:443"
.EXAMPLE
  .\forward-vpn.ps1 -VpnProfile "igh-insurances-refresh" -Caddy -Forward "8443=dev-int-aiexperiments.ighinsurances.inssolu.com:443"
#>
[CmdletBinding()]
param(
    [string[]]$Forward = @(),
    [int[]]$ExtraPublish = @(),
    [string]$VpnProfile = '',
    [string]$Container = '',
    [ValidateSet('shim', 'openvpn')][string]$Method = 'openvpn',
    [switch]$Caddy,
    [string[]]$CaddyHost = @(),
    [switch]$CaddyOff,
    [switch]$NoPrompt,
    [string]$CaddyAdmin = 'http://127.0.0.1:2019',
    [switch]$Stop
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'vpn-services.ps1')
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
    try { Start-Process powershell -WindowStyle Hidden -Verb RunAs -Wait -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$tmp`"" }
    finally { Remove-Item $data, $tmp -ErrorAction SilentlyContinue }
}

function Get-ContainerNameFromProfile ([string]$Name) {
    'vpn-' + ($Name -replace '[^a-zA-Z0-9-]', '-' -replace '-{2,}', '-').ToLower().Trim('-')
}

$maps = foreach ($f in $Forward) {
    if ($f -notmatch '^(\d{1,5})=([A-Za-z0-9.-]+):(\d{1,5})$') { throw "Bad -Forward '$f', expected <local port>=<host>:<port>" }
    if ([int]$Matches[1] -lt 1 -or [int]$Matches[1] -gt 65535 -or [int]$Matches[3] -lt 1 -or [int]$Matches[3] -gt 65535) { throw "Port out of range in -Forward '$f'." }
    [pscustomobject]@{ Local = [int]$Matches[1]; Host = $Matches[2]; Port = [int]$Matches[3] }
}

if ($maps -and @($maps.Local | Select-Object -Unique).Count -ne @($maps).Count) { throw 'Duplicate local ports in -Forward.' }

# -CaddyOff alone (no -Forward) only needs Caddy and the hosts file, so it also works while Docker or the VPN container is down.
# With -Forward it is the keeper's "site off" state: forward as usual, just without the Caddy routes.
if ($CaddyOff -and -not $Stop -and -not $maps) {
    Remove-CaddyObjects
    Update-HostsEntries
    exit 0
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
    Stop-VpnService $CNTR forward
    Invoke-Wsl docker rm -f $SIDECAR 2>&1 | Out-Null
    Write-Step "+ Stopped forwarding in $CNTR" DarkGreen
    Remove-CaddyObjects
    Update-HostsEntries
    exit 0
}
if ($Method -eq 'shim') { throw 'Built-in forwarding services require -Method openvpn.' }
if (-not $maps) { throw 'Pass at least one -Forward mapping.' }

if ($running -notcontains $CNTR) {
    if (-not $VpnProfile) { throw "VPN container '$CNTR' is not running; pass -VpnProfile to start it." }
    Write-Step "Starting VPN container for '$VpnProfile' (publishing $((@($maps.Local) + $ExtraPublish) -join ', '))..." Cyan
    $connect = @{ VpnProfile = $VpnProfile; Publish = [int[]](@($maps.Local) + $ExtraPublish) }
    if ($NoPrompt -and $Method -ne 'shim') { $connect.NoPrompt = $true }
    & (Join-Path $PSScriptRoot $(if ($Method -eq 'shim') { 'connect-vpn.ps1' } else { 'connect-vpn-openvpn.ps1' })) @connect
    if ($LASTEXITCODE -eq 4) { Write-Step 'x Interactive sign-in needed for the VPN token.' Red; exit 4 }
    if ($LASTEXITCODE -ne 0) { throw 'VPN connect failed.' }
}

# The VPN container must publish every local port; that cannot be added to a running container.
$published = @(Invoke-Wsl docker port $CNTR | ForEach-Object { if ($_ -match '^(\d+)/tcp') { [int]$Matches[1] } })
$missing = @($maps.Local | Where-Object { $published -notcontains $_ })
if ($missing) {
    throw "VPN container '$CNTR' does not publish port(s) $($missing -join ', '). Recreate it: docker rm -f $CNTR, then connect-vpn-openvpn.ps1 -VpnProfile <name> -Publish $($maps.Local -join ',')."
}

# Remove the legacy sidecar before the built-in processes bind the same ports.
Assert-VpnServices $CNTR
Invoke-Wsl docker rm -f $SIDECAR 2>&1 | Out-Null
$conf = ($maps | ForEach-Object { "$($_.Local) $($_.Host) $($_.Port)" }) -join "`n"
Set-VpnService -VpnContainer $CNTR -Service forward -Configuration $conf

foreach ($m in $maps) { Write-Step "+ 127.0.0.1:$($m.Local) -> $($m.Host):$($m.Port) (via $CNTR)" DarkGreen }

$caddyMaps = if ($Caddy) { @($maps) } else { @($maps | Where-Object { $CaddyHost -contains $_.Host }) }
if ($caddyMaps) {
    # Idempotent: drop what an earlier run registered, then add one route + one internal-TLS policy per host.
    Remove-CaddyObjects
    foreach ($m in $caddyMaps) {
        $h = $m.Host
        Invoke-CaddyApi POST '/config/apps/tls/automation/policies' @{
            '@id' = "${ID_PREFIX}tls-$h"; subjects = @($h); issuers = @(@{ module = 'internal' })
        } | Out-Null
        Invoke-CaddyApi POST '/config/apps/http/servers/srv0/routes' @{
            '@id' = "$ID_PREFIX$h"; match = @(@{ host = @($h) }); terminal = $true
            handle = @(@{
                handler = 'reverse_proxy'; upstreams = @(@{ dial = "127.0.0.1:$($m.Local)" })
                # Caddy would otherwise send the upstream address as Host; the site answers 404 for that.
                headers = @{ request = @{ set = @{ Host = @('{http.request.host}') } } }
                transport = @{ protocol = 'http'; tls = @{ server_name = $h } }
            })
        } | Out-Null
        Write-Step "+ Caddy: https://$h/ -> 127.0.0.1:$($m.Local) (TLS upstream, SNI $h)" DarkGreen
    }
    Update-HostsEntries -AddHosts @($caddyMaps.Host | Select-Object -Unique)
    Write-Step "+ Hosts: 127.0.0.1 $(@($caddyMaps.Host | Select-Object -Unique) -join ', ')" DarkGreen
} elseif ($CaddyOff) {
    Remove-CaddyObjects
    Update-HostsEntries
}
