# Shared service configuration for proxy-vpn.ps1 and forward-vpn.ps1.
function Assert-VpnServices ([string]$VpnContainer) {
    wsl -d Ubuntu-20.04 -- docker exec $VpnContainer test -x /usr/local/sbin/vpn-services 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "VPN container '$VpnContainer' uses an old or shim image. Rebuild src-openvpn/Containerfile and reconnect with OpenVPN before configuring built-in services."
    }
}

function Stop-VpnService ([string]$VpnContainer, [ValidateSet('proxy', 'forward')][string]$Service) {
    $info = wsl -d Ubuntu-20.04 -- docker inspect $VpnContainer --format '{{.State.Running}}|{{index .Config.Labels "local.azurevpn.services"}}' 2>$null
    # Legacy containers have only sidecars; callers remove those separately.
    if ($LASTEXITCODE -ne 0 -or $info -notmatch '\|1$') { return }
    if ($info -like 'true|*') {
        Set-VpnService -VpnContainer $VpnContainer -Service $Service -Disable
        return
    }
    # docker cp works with stopped containers too. Empty desired configuration
    # prevents the service returning on the next VPN start, without starting it.
    $temp = [System.IO.Path]::GetTempFileName()
    $wslTemp = '/mnt/' + $temp[0].ToString().ToLower() + ($temp.Substring(2) -replace '\\', '/')
    try {
        wsl -d Ubuntu-20.04 -- docker cp "${VpnContainer}:/work/vpn-services/$Service.conf" $wslTemp 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return } # No persisted service to disable.
        [System.IO.File]::WriteAllText($temp, '')
        wsl -d Ubuntu-20.04 -- docker cp $wslTemp "${VpnContainer}:/work/vpn-services/$Service.conf"
        if ($LASTEXITCODE -ne 0) { throw "Could not disable persisted $Service in '$VpnContainer'." }
    } finally {
        Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue
    }
}

function Set-VpnService {
    param(
        [Parameter(Mandatory)][string]$VpnContainer,
        [Parameter(Mandatory)][ValidateSet('proxy', 'forward')][string]$Service,
        [string]$Configuration,
        [switch]$Disable
    )
    Assert-VpnServices $VpnContainer
    if ($Disable) {
        wsl -d Ubuntu-20.04 -- docker exec $VpnContainer /usr/local/sbin/vpn-services disable $Service
        if ($LASTEXITCODE -ne 0) { throw "Could not stop $Service in '$VpnContainer'." }
        return
    }
    # Atomically publish desired configuration so the watchdog cannot read a
    # partially copied file.
    $temp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($temp, $Configuration.Replace("`r", '') + "`n", [System.Text.UTF8Encoding]::new($false))
        $wslTemp = '/mnt/' + $temp[0].ToString().ToLower() + ($temp.Substring(2) -replace '\\', '/')
        wsl -d Ubuntu-20.04 -- docker exec $VpnContainer mkdir -p /work/vpn-services
        if ($LASTEXITCODE -ne 0) { throw 'Could not create VPN service configuration directory.' }
        wsl -d Ubuntu-20.04 -- docker cp $wslTemp "${VpnContainer}:/work/vpn-services/$Service.conf.new"
        if ($LASTEXITCODE -ne 0) { throw 'Could not copy VPN service configuration.' }
        wsl -d Ubuntu-20.04 -- docker exec $VpnContainer mv "/work/vpn-services/$Service.conf.new" "/work/vpn-services/$Service.conf"
        if ($LASTEXITCODE -ne 0) { throw 'Could not publish VPN service configuration.' }
        wsl -d Ubuntu-20.04 -- docker exec $VpnContainer /usr/local/sbin/vpn-services reconcile $Service
        if ($LASTEXITCODE -ne 0) { throw "Could not start $Service in '$VpnContainer'." }
    } finally {
        Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue
    }
}
