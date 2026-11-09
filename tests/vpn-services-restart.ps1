# Exercise real container restarts and stopping persisted services while stopped.
# Uses no VPN profiles, credentials or host ports.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\vpn-services.ps1')
$name = 'azurevpn-services-restart-test'
wsl -d Ubuntu-20.04 -- docker inspect $name 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { throw "Test container '$name' already exists; refusing to replace it." }
function Wait-Proxy {
    for ($i = 0; $i -lt 30; $i++) {
        wsl -d Ubuntu-20.04 -- docker exec $name /usr/local/sbin/vpn-services status proxy 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Milliseconds 200
    }
    throw 'Proxy did not recover after container restart.'
}
try {
    # Replace only this disposable container's VPN executable with a fake tunnel.
    # Exercise the real entrypoint, including bootstrap DNS after a hard stop.
    $command = 'mkdir -p /work/vpn-services; if [ ! -f /work/vpn-services/proxy.conf ]; then printf "Port 18888\nListen 0.0.0.0\nAllow 127.0.0.1\nLogLevel Warning\n" > /work/vpn-services/proxy.conf; fi; printf "#!/bin/bash\nprintf \"nameserver 10.123.0.4\\n\" > /etc/resolv.conf\nexec sleep infinity\n" > /usr/local/sbin/openvpn; chmod +x /usr/local/sbin/openvpn; exec /usr/local/sbin/vpn-entrypoint'
    wsl -d Ubuntu-20.04 -- docker run -d --name $name --entrypoint /usr/bin/tini azurevpn-openvpn:local -- bash -c $command | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not start test container.' }
    Wait-Proxy
    $bootstrap = wsl -d Ubuntu-20.04 -- docker exec $name cat /run/vpn-services/bootstrap-resolv.conf
    if ($LASTEXITCODE -ne 0 -or -not $bootstrap -or $bootstrap -contains 'nameserver 10.123.0.4') { throw 'Entrypoint did not capture bootstrap DNS.' }
    wsl -d Ubuntu-20.04 -- docker kill $name | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not hard-stop test container.' }
    wsl -d Ubuntu-20.04 -- docker start $name | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not restart test container.' }
    Wait-Proxy
    $afterRestart = wsl -d Ubuntu-20.04 -- docker exec $name cat /run/vpn-services/bootstrap-resolv.conf
    if ($LASTEXITCODE -ne 0 -or ($afterRestart -join "`n") -ne ($bootstrap -join "`n")) { throw 'Hard restart replaced bootstrap DNS with tunnel DNS.' }
    wsl -d Ubuntu-20.04 -- docker stop $name | Out-Null
    Stop-VpnService $name proxy
    wsl -d Ubuntu-20.04 -- docker start $name | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not start stopped test container.' }
    Start-Sleep -Seconds 3
    wsl -d Ubuntu-20.04 -- docker exec $name /usr/local/sbin/vpn-services status proxy 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { throw 'Disabled proxy returned after container restart.' }
    'VPN service restart tests passed'
} finally {
    wsl -d Ubuntu-20.04 -- docker rm -f $name 2>$null | Out-Null
}
