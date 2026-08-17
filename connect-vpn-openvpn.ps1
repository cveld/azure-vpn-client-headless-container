#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Azure VPN profile selector (OpenVPN variant) — interactive or non-interactive.
  Reads installed profiles from the Azure VPN Client, lets you pick one,
  extracts the profile XML and starts the OpenVPN container.
  Sibling launcher to connect-vpn.ps1.
.PARAMETER Profile
  Profile name (or substring). When set, skips the interactive menu.
.EXAMPLE
  .\connect-vpn-openvpn.ps1
  .\connect-vpn-openvpn.ps1 -Profile "IGH - Insurances"
#>
param(
    [string]$VpnProfile = ''
)
$ErrorActionPreference = 'Stop'
$Interactive = [string]::IsNullOrEmpty($VpnProfile)

# ── Paths ─────────────────────────────────────────────────────────────────────
$PBK   = "$env:LOCALAPPDATA\Packages\Microsoft.AzureVpn_8wekyb3d8bbwe\LocalState\rasphone.pbk"
$IMAGE = 'azurevpn-openvpn:local'

# Project root → WSL path (derived from script location, no hardcoding)
$_drive = $PSScriptRoot[0].ToString().ToLower()
$_path  = $PSScriptRoot.Substring(2) -replace '\\', '/'
$ROOT   = "/mnt/$_drive$_path"

# ── .env ─────────────────────────────────────────────────────────────────────
$_envFile = Join-Path $PSScriptRoot '.env'
if (-not (Test-Path $_envFile)) {
    if (-not $Interactive) {
        Write-Host '  x .env not found — run connect-vpn-openvpn.ps1 interactively once to set up.' -ForegroundColor Red; exit 1
    }
    Write-Host ''
    Write-Host '  No .env file found — first-time setup' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  SECRETS_DIR  folder for token caches and profile XMLs (keep outside the git repo)' -ForegroundColor Gray
    Write-Host "  Suggestion : $env:USERPROFILE\.azure-vpn-shim" -ForegroundColor DarkGray
    $secretsInput = Read-Host '  SECRETS_DIR'
    if ([string]::IsNullOrWhiteSpace($secretsInput)) { $secretsInput = "$env:USERPROFILE\.azure-vpn-shim" }
    Write-Host ''
    Write-Host '  LIBS_SOURCE  (optional) path to existing .so files — leave empty to download via apt' -ForegroundColor Gray
    $libsInput = Read-Host '  LIBS_SOURCE'
    $envLines = @("SECRETS_DIR=$secretsInput")
    if (-not [string]::IsNullOrWhiteSpace($libsInput)) { $envLines += "LIBS_SOURCE=$libsInput" }
    [System.IO.File]::WriteAllText($_envFile, ($envLines -join "`n"), [System.Text.UTF8Encoding]::new($false))
    Write-Host ''
    Write-Host "  + .env written to $_envFile" -ForegroundColor DarkGreen
    Write-Host ''
}

Get-Content $_envFile -ErrorAction SilentlyContinue |
    ForEach-Object {
        if ($_ -match '^([^#=\s][^=]*)=(.*)') {
            [Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim())
        }
    }
$SECRETS = $env:SECRETS_DIR

if ([string]::IsNullOrWhiteSpace($SECRETS)) {
    Write-Host '  x SECRETS_DIR is not set in .env' -ForegroundColor Red; exit 1
}

# ── Parse rasphone.pbk ────────────────────────────────────────────────────────
function Read-Pbk ([string]$Path) {
    $list = [System.Collections.Generic.List[hashtable]]::new()
    $cur  = $null
    $hex  = $null

    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ($line -match '^\[(.+)\]$') {
            if ($cur) { $cur.Hex = $hex.ToArray(); $list.Add($cur) }
            $cur = @{ Name=''; Phone=''; Hex=@() }
            $cur.Name = $Matches[1]
            $hex = [System.Collections.Generic.List[string]]::new()
        } elseif ($cur) {
            if   ($line -match '^ThirdPartyProfileInfo=(.+)$') { $hex.Add($Matches[1]) }
            elseif ($line -match '^PhoneNumber=(.+)$')          { $cur.Phone = $Matches[1] }
        }
    }
    if ($cur) { $cur.Hex = $hex.ToArray(); $list.Add($cur) }
    ,$list   # force List return as single object
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
        for ($j = 0; $j -lt $sig.Length; $j++) {
            if ($bytes[$i+$j] -ne $sig[$j]) { $ok=$false; break }
        }
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

# ── Arrow-key menu ────────────────────────────────────────────────────────────
function Get-RunningContainers {
    $names = wsl -d Ubuntu-20.04 -- docker ps --format '{{.Names}}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $names) { @($names) } else { @() }
}

function Show-Menu ([hashtable[]]$Items) {
    $sel     = 0
    $n       = $Items.Count
    $running = @(Get-RunningContainers)
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            # Recalculate on each redraw to handle terminal resize
            $W     = [Math]::Max(60, [Console]::WindowWidth - 1)
            $nameW = [Math]::Min(28, [Math]::Max(12, [int](($W - 14) * 0.35)))
            $gwW   = [Math]::Max(16, $W - 4 - $nameW - 2 - 6 - 4)
            $hr    = "─" * ($W - 2)

            Clear-Host
            Write-Host ''
            Write-Host '  Azure VPN Connect (OpenVPN)' -ForegroundColor Cyan
            Write-Host "  $hr" -ForegroundColor DarkGray
            Write-Host ''

            for ($i = 0; $i -lt $n; $i++) {
                $p    = $Items[$i]
                $name = if ($p.Name.Length -gt $nameW) { $p.Name.Substring(0,$nameW-3)+'...' } else { $p.Name }
                $gw   = if ($p.Gw.Length   -gt $gwW)   { $p.Gw.Substring(0,$gwW-3)+'...'     } else { $p.Gw   }
                $tag  = switch ($p.Auth) {
                    'Entra' { 'Entra' }
                    'Cert'  { 'Cert!' }
                    default { '?    ' }
                }
                $cacheOk     = $p.CachePath -and (Test-Path $p.CachePath)
                $cacheIcon   = if ($cacheOk) { '+' } else { '-' }
                $isRunning   = $running -contains $p.ContainerName
                $runningIcon = if ($isRunning) { '*' } else { ' ' }
                $row = ('{0,-' + $nameW + '} {1,-' + $gwW + '} {2} {3}{4}') -f $name, $gw, $tag, $cacheIcon, $runningIcon

                if ($i -eq $sel) {
                    Write-Host "  > $row" -ForegroundColor Green
                } elseif ($isRunning) {
                    Write-Host "    $row" -ForegroundColor White
                } else {
                    $col = if ($p.Auth -eq 'Cert') { 'DarkGray' } else { 'Gray' }
                    Write-Host "    $row" -ForegroundColor $col
                }
            }

            Write-Host ''
            Write-Host "  $hr" -ForegroundColor DarkGray
            Write-Host '  ↑↓ navigate   Enter connect   S stop   D clear cache   Q quit' -ForegroundColor DarkGray

            $k = [Console]::ReadKey($true)
            switch ($k.Key) {
                'UpArrow'   { if ($sel -gt 0)    { $sel-- } }
                'DownArrow' { if ($sel -lt $n-1) { $sel++ } }
                'Enter'     { return $sel }
                'Escape'    { return -1 }
                default     {
                    if ($k.KeyChar -eq 'q' -or $k.KeyChar -eq 'Q') { return -1 }
                    if ($k.KeyChar -eq 'd' -or $k.KeyChar -eq 'D') {
                        $cp = $Items[$sel].CachePath
                        if ($cp -and (Test-Path $cp)) { Remove-Item $cp -Force }
                    }
                    if ($k.KeyChar -eq 's' -or $k.KeyChar -eq 'S') {
                        $cn = $Items[$sel].ContainerName
                        if ($running -contains $cn) {
                            wsl -d Ubuntu-20.04 -- docker stop $cn 2>$null | Out-Null
                            $running = @(Get-RunningContainers)
                        }
                    }
                }
            }
        }
    } finally {
        [Console]::CursorVisible = $true
    }
}

function Write-Step ([string]$Msg, [string]$Color = 'Gray') {
    Write-Host "  $Msg" -ForegroundColor $Color
}

function ConvertTo-StaticKey ([string]$Xml) {
    if ($Xml -notmatch '<serversecret>([0-9a-fA-F]+)<') {
        Write-Step 'x serversecret missing in profile XML.' Red; exit 1
    }
    $hex = $Matches[1]
    if ($hex.Length -ne 512) {
        Write-Step "x serversecret length invalid ($($hex.Length)); expected 512 hex chars." Red; exit 1
    }
    $lines = @()
    for ($i = 0; $i -lt 16; $i++) {
        $lines += $hex.Substring($i * 32, 32)
    }
    "-----BEGIN OpenVPN Static key V1-----`n$($lines -join "`n")`n-----END OpenVPN Static key V1-----"
}

# ── Build profile list ────────────────────────────────────────────────────────
if ($Interactive) { Clear-Host }
Write-Step 'Reading profiles from Azure VPN Client...' DarkGray

if (-not (Test-Path $PBK)) {
    Write-Step "rasphone.pbk not found: $PBK" Red; exit 1
}

$raw      = Read-Pbk $PBK
$profiles = @(foreach ($r in $raw) {
    if ($r.Hex.Count -eq 0) { continue }
    $xml = ConvertFrom-ProfileHex $r.Hex
    if (-not $xml) { continue }

    $gwHost = $r.Phone -replace '^https?://','' -replace '/.*',''
    $auth   = if   ($gwHost -match '^(wan|hub)\d*\.') { 'Entra' }
              elseif ($gwHost -match '^azuregateway-') { 'Cert'  }
              else                                      { '?'     }
    $tenant = if ($xml -match '<tenant>https://login\.microsoftonline\.com/([^/]+)') { $Matches[1] } else { '' }
    $aud    = if ($xml -match '<audience>([^<]+)<')   { $Matches[1] } else { '' }

    $safeName      = $r.Name -replace '[\\/:*?"<>|]', '_'
    $containerName = 'vpn-' + ($r.Name -replace '[^a-zA-Z0-9-]', '-' -replace '-{2,}', '-').ToLower().Trim('-')
    @{ Name=$r.Name; SafeName=$safeName; ContainerName=$containerName
       CachePath=(Join-Path $SECRETS "token-cache\$safeName.json")
       Gw=$gwHost; Auth=$auth; Tenant=$tenant; Audience=$aud; Xml=$xml }
})

if ($profiles.Count -eq 0) {
    Write-Step 'No VPN profiles found.' Red; exit 1
}

# ── Select ────────────────────────────────────────────────────────────────────
if ($Interactive) {
    $idx = Show-Menu $profiles
    if ($idx -lt 0) { Clear-Host; exit 0 }
} else {
    $idx = -1
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        if ($profiles[$i].Name -like "*$VpnProfile*") { $idx = $i; break }
    }
    if ($idx -lt 0) {
        Write-Step "x No profile matching '$VpnProfile'" Red
        Write-Step "  Available: $(($profiles | ForEach-Object { $_.Name }) -join ', ')" Gray
        exit 1
    }
}

$p    = $profiles[$idx]
$CNTR = $p.ContainerName + '-ovpn'
if ($Interactive) { Clear-Host }
Write-Host ''
Write-Host "  ┌─ $($p.Name)" -ForegroundColor Cyan
Write-Host "  │  Container: $CNTR" -ForegroundColor Gray
Write-Host "  │  Gateway  : $($p.Gw)" -ForegroundColor Gray
Write-Host "  │  Tenant   : $($p.Tenant)" -ForegroundColor Gray
Write-Host "  │  Audience : $($p.Audience)" -ForegroundColor Gray
Write-Host "  │  Auth     : $($p.Auth)" -ForegroundColor Gray
Write-Host "  └─$("─" * 50)" -ForegroundColor Cyan
Write-Host ''

if ($p.Auth -ne 'Entra') {
    Write-Step '  Cert profile — OpenVPN path only supports Entra authentication.' Yellow
    if (-not $Interactive) { Write-Step 'x Cannot connect to Cert profile non-interactively.' Red; exit 1 }
    $c = Read-Host '   Connect anyway? (y/N)'
    if ($c -notmatch '^[yY]') { exit 0 }
    Write-Host ''
}

# ── Write profile XML to secrets dir ─────────────────────────────────────────
$xmlDst    = Join-Path $SECRETS "vpn\$($p.SafeName).xml"
New-Item -ItemType Directory -Force (Split-Path $xmlDst) | Out-Null
[System.IO.File]::WriteAllText($xmlDst, $p.Xml, [System.Text.UTF8Encoding]::new($false))
Write-Step "+ Profile XML written to $xmlDst" DarkGreen

# ── Token cache (per profiel) ─────────────────────────────────────────────────
$cache    = $p.CachePath
$cacheWsl = '/mnt/' + $cache[0].ToString().ToLower() + ($cache.Substring(2) -replace '\\','/')

if ([string]::IsNullOrEmpty($p.Tenant) -or [string]::IsNullOrEmpty($p.Audience)) {
    Write-Step 'x Tenant or audience missing in profile XML — cannot acquire token.' Red; exit 1
}

# ── Token: WAM first (silent/popup), device code as fallback ─────────────────
if ($p.Auth -eq 'Entra') {
    $wamScript = Join-Path $PSScriptRoot 'wam-auth.ps1'
    if (Test-Path $wamScript) {
        Write-Step 'Trying WAM authentication...' Cyan
        try {
            & $wamScript -ProfileName $p.Name -TenantId $p.Tenant -CachePath $cache
        } catch {
            Write-Step "~ WAM error: $($_.Exception.Message)" Yellow
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Step '~ WAM failed — device code flow will be used if needed' Yellow
        }
    }
}

# msal available in WSL?
wsl -d Ubuntu-20.04 -- python3 -c "import msal" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Step 'Installing msal in WSL...' Yellow
    wsl -d Ubuntu-20.04 -- pip3 install --quiet msal
}

# device_code.py: validates format and exits 0 if WAM wrote a valid token;
# otherwise refreshes via refresh token or runs the device code flow.
Write-Step 'Validating/refreshing token cache...' Cyan
wsl -d Ubuntu-20.04 -- python3 "$ROOT/src/device_code.py" $p.Tenant $p.Audience $cacheWsl
if ($LASTEXITCODE -ne 0) { Write-Step 'x Token flow failed.' Red; exit 1 }
Write-Step '+ Token cache ready' DarkGreen

# ── Extract raw access token for the OpenVPN password field ──────────────────
$accessToken = wsl -d Ubuntu-20.04 -- python3 "$ROOT/src-openvpn/extract_token.py" $cacheWsl
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accessToken)) {
    Write-Step 'x Failed to extract access token from cache.' Red; exit 1
}

# ── Per-profile OpenVPN work dir (creds, tls-auth key, rendered config) ──────
$workDir    = Join-Path $SECRETS "vpn-openvpn\$($p.SafeName)"
$workDirWsl = '/mnt/' + $workDir[0].ToString().ToLower() + ($workDir.Substring(2) -replace '\\','/')
New-Item -ItemType Directory -Force $workDir | Out-Null

$credsPath = Join-Path $workDir 'creds'
[System.IO.File]::WriteAllText($credsPath, "AzureAD`n$accessToken", [System.Text.UTF8Encoding]::new($false))

$tlsPath   = Join-Path $workDir 'tls-auth.key'
$staticKey = ConvertTo-StaticKey $p.Xml
[System.IO.File]::WriteAllText($tlsPath, $staticKey, [System.Text.UTF8Encoding]::new($false))

Copy-Item (Join-Path $PSScriptRoot 'src\dr.pem') (Join-Path $workDir 'dr.pem') -Force
Copy-Item (Join-Path $PSScriptRoot 'src-openvpn\up-dns.sh') (Join-Path $workDir 'up-dns.sh') -Force
wsl -d Ubuntu-20.04 -- chmod +x "$workDirWsl/up-dns.sh"

$ovpnTemplate = Get-Content (Join-Path $PSScriptRoot 'src-openvpn\openvpn.ovpn.template') -Raw
$ovpnBody     = $ovpnTemplate -replace '__GATEWAY__', $p.Gw
$ovpnPath     = Join-Path $workDir "$($p.SafeName).ovpn"
[System.IO.File]::WriteAllText($ovpnPath, $ovpnBody, [System.Text.UTF8Encoding]::new($false))
Write-Step "+ OpenVPN work dir ready: $workDir" DarkGreen

# ── Docker daemon ─────────────────────────────────────────────────────────────
Write-Step 'Checking Docker...'

# Ensure Docker Desktop is running
$ddProcess = Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue
if (-not $ddProcess) {
    $ddExe = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
    if (Test-Path $ddExe) {
        Write-Step 'Starting Docker Desktop...' Yellow
        Start-Process $ddExe
    }
}

# Wait for docker to become available in WSL (max 45s)
$deadline = (Get-Date).AddSeconds(45)
$dockerOk = $false
while ((Get-Date) -lt $deadline) {
    wsl -d Ubuntu-20.04 -- docker info 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $dockerOk = $true; break }
    Start-Sleep -Seconds 3
}

if (-not $dockerOk) {
    Write-Host ''
    Write-Step 'x Docker not available in WSL distro Ubuntu-20.04.' Red
    Write-Step '  Check: Docker Desktop -> Settings -> Resources -> WSL Integration -> Ubuntu-20.04.' Yellow
    exit 1
}
Write-Step '+ Docker available' DarkGreen

# ── Build image if needed ─────────────────────────────────────────────────────
wsl -d Ubuntu-20.04 -- docker image inspect $IMAGE 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Step "Building image $IMAGE (this may take a while)..." Yellow
    wsl -d Ubuntu-20.04 -- bash -lc "cd '$ROOT' && docker build -f src-openvpn/Containerfile -t $IMAGE src-openvpn"
    if ($LASTEXITCODE -ne 0) {
        Write-Step "x Image build failed." Red; exit 1
    }
}

# ── Start container ───────────────────────────────────────────────────────────
Write-Step "Starting container ($CNTR)..." Cyan
wsl -d Ubuntu-20.04 -- bash -lc "docker rm -f $CNTR >/dev/null 2>&1; docker run -d --name $CNTR --cap-add=NET_ADMIN --device=/dev/net/tun -e OPENVPN_SNI=$($p.Gw) -e OPENVPN_ALPN=h2,http/1.1 -e OPENVPN_PHA=1 -e OPENVPN_AZURE_OCC=1 -v '${workDirWsl}:/work' $IMAGE --config '/work/$($p.SafeName).ovpn'"
if ($LASTEXITCODE -ne 0) {
    Write-Step "x Container start failed." Red; exit 1
}

# ── Wait for tunnel ───────────────────────────────────────────────────────────
Write-Step "Waiting for tunnel '$($p.Name)'..." Yellow

$timeout = 120; $elapsed = 0; $up = $false; $nextLog = 4
# Stock OpenVPN always names the interface tun0 — no profile-name truncation to handle here.
while ($elapsed -lt $timeout) {
    $null = wsl -d Ubuntu-20.04 -- bash -c "docker exec $CNTR ip link show tun0" 2>$null
    if ($LASTEXITCODE -eq 0) { $up = $true; break }
    if ($elapsed -ge $nextLog) {
        wsl -d Ubuntu-20.04 -- docker logs --tail 6 $CNTR 2>&1 |
            ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        Write-Host ''
        $nextLog += 8
    }
    Start-Sleep -Seconds 2; $elapsed += 2
}

if (-not $up) {
    Write-Host ''
    Write-Step "x Tunnel not up after ${timeout}s" Red
    Write-Step "Logs: wsl -d Ubuntu-20.04 -- docker logs $CNTR" Yellow
    exit 1
}

Write-Step "✓ Tunnel UP (${elapsed}s)" Green
Write-Host ''
Write-Step "Stop: wsl -d Ubuntu-20.04 -- docker stop $CNTR" DarkGray
Write-Host ''
if ($Interactive) {
    Write-Step 'Shell in container. VPN stays active after exit.' Cyan
    wsl -d Ubuntu-20.04 -- docker exec -it $CNTR bash
}
