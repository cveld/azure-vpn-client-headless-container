#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Combined VPN + RDP launcher — pick tenant, discover VMs, connect.
.DESCRIPTION
  1. Select VPN profile / tenant (interactive or via parameters)
  2. Discover VMs in that tenant via Azure CLI
  3. Ensure VPN container is running (starts it if needed)
  4. Launch RDP via socat tunnel
.PARAMETER Tenant
  Friendly tenant name (matches azTenant in rdp-connect-settings.json),
  'auto' to derive from the VPN profile, or 'current' to skip tenant switching.
.PARAMETER TenantTool
  '' (default) to use native az CLI for tenant switching, or
  'az-context' to delegate to c:\prg\az-context.ps1.
.PARAMETER ResourceId
  Full Azure resource ID of the target VM — skips the VM discovery menu.
.PARAMETER Subscription
  Filter VMs by subscription name or ID.
.PARAMETER ResourceGroup
  Filter VMs by resource group name.
.PARAMETER Name
  Filter VMs by name (substring match against VM name or computer name).
.PARAMETER Hostname
  Internal FQDN of the target VM — skips VM discovery.
  The tool auto-matches the tenant via dnsSuffix in settings.
.PARAMETER LocalPort
  Local proxy port (default: auto-pick starting at 13389).
.PARAMETER RemotePort
  RDP port on the target host (default: 3389).
.PARAMETER Username
  Entra ID UPN to pre-fill, e.g. user@tenant.onmicrosoft.com.
  Auto-detected from the current Windows session when omitted.
.PARAMETER NoEntraAuth
  Use classic credential dialog instead of Entra WAM auth.
.EXAMPLE
  .\rdp-connect.ps1
  .\rdp-connect.ps1 -Hostname myvm01.corp.example.com
  .\rdp-connect.ps1 -Tenant contoso -Name myvm01
  .\rdp-connect.ps1 -Tenant contoso -ResourceGroup rg-prod
  .\rdp-connect.ps1 -ResourceId /subscriptions/.../virtualMachines/myvm
  .\rdp-connect.ps1 -TenantTool az-context -Tenant fabrikam
#>
param(
    [string]$Tenant     = 'auto',
    [string]$TenantTool = '',

    [string]$ResourceId     = '',
    [Alias('s')][string]$Subscription   = '',
    [Alias('g')][string]$ResourceGroup  = '',
    [Alias('n')][string]$Name           = '',

    [string]$Hostname   = '',
    [int]$LocalPort     = 0,
    [int]$RemotePort    = 3389,
    [string]$Username   = '',

    [switch]$NoEntraAuth,
    [switch]$KeepHostsEntry,
    [switch]$CleanHosts,
    [switch]$Help
)

if ($Help) { Get-Help $PSCommandPath -Detailed; exit 0 }

$ErrorActionPreference = 'Stop'

# ── Paths ─────────────────────────────────────────────────────────────────────
$_drive  = $PSScriptRoot[0].ToString().ToLower()
$_path   = $PSScriptRoot.Substring(2) -replace '\\', '/'
$WslRoot  = "/mnt/$_drive$_path"
$WslProxy = "$WslRoot/src/rdp-proxy.sh"
$PBK      = "$env:LOCALAPPDATA\Packages\Microsoft.AzureVpn_8wekyb3d8bbwe\LocalState\rasphone.pbk"

function Write-Step ([string]$Msg, [string]$Color = 'Gray') {
    Write-Host "  $Msg" -ForegroundColor $Color
}

# ── .env ─────────────────────────────────────────────────────────────────────
$_envFile = Join-Path $PSScriptRoot '.env'
if (-not (Test-Path $_envFile)) {
    Write-Step 'x .env not found — run connect-vpn.ps1 first to set up.' Red; exit 1
}
Get-Content $_envFile -ErrorAction SilentlyContinue |
    ForEach-Object {
        if ($_ -match '^([^#=\s][^=]*)=(.*)') {
            [Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim())
        }
    }
$SECRETS = $env:SECRETS_DIR
if ([string]::IsNullOrWhiteSpace($SECRETS)) {
    Write-Step 'x SECRETS_DIR not set in .env' Red; exit 1
}

# ── Settings ──────────────────────────────────────────────────────────────────
$settingsPath = Join-Path $PSScriptRoot 'rdp-connect-settings.json'
if (-not (Test-Path $settingsPath)) {
    Write-Step "x rdp-connect-settings.json not found: $settingsPath" Red
    Write-Step '  Create it with VPN profile → azTenant + dnsSuffix mappings.' Yellow
    exit 1
}
$settings = Get-Content $settingsPath -Raw | ConvertFrom-Json

# Load tenantTool from settings if not overridden via -TenantTool parameter
if ([string]::IsNullOrWhiteSpace($TenantTool) -and -not [string]::IsNullOrWhiteSpace($settings.tenantTool)) {
    $TenantTool = [string]$settings.tenantTool
}

# ── Hosts-entry cleanup setting ───────────────────────────────────────────────
$keepEntry = [bool]($settings.keepHostsEntry) -or $KeepHostsEntry.IsPresent

# ── -CleanHosts: remove all managed hosts entries and exit ────────────────────
if ($CleanHosts) {
    $_hp      = "$env:windir\System32\drivers\etc\hosts"
    $_managed = @(Get-Content -LiteralPath $_hp -ErrorAction SilentlyContinue |
                    Where-Object { $_ -match '# rdp-vpn-ps-' })
    if ($_managed.Count -eq 0) { Write-Step 'No managed hosts entries found.' DarkGray; exit 0 }
    $plural = if ($_managed.Count -eq 1) { 'entry' } else { 'entries' }
    Write-Step "Removing $($_managed.Count) managed hosts ${plural}:" DarkGray
    $_managed | ForEach-Object { Write-Step "  $_" DarkGray }
    $_isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                    [Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($_isAdmin) {
        (Get-Content -LiteralPath $_hp) |
            Where-Object { $_ -notmatch '# rdp-vpn-ps-' } |
            Set-Content -LiteralPath $_hp -Encoding UTF8
    } else {
        $_tmp = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.ps1'
        [System.IO.File]::WriteAllText($_tmp,
            "(Get-Content -LiteralPath '$_hp') | Where-Object { `$_ -notmatch '# rdp-vpn-ps-' } | Set-Content -LiteralPath '$_hp' -Encoding UTF8",
            [System.Text.UTF8Encoding]::new($false))
        Write-Step '! UAC prompt: editing hosts file requires admin' Yellow
        Start-Process powershell -Verb RunAs -Wait `
            -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$_tmp`""
        Remove-Item $_tmp -ErrorAction SilentlyContinue
    }
    Write-Step "+ Managed hosts $plural removed." DarkGreen
    exit 0
}

# ── Stale entry notice ────────────────────────────────────────────────────────
$_staleCount = @(Get-Content -LiteralPath "$env:windir\System32\drivers\etc\hosts" `
                    -ErrorAction SilentlyContinue |
                    Where-Object { $_ -match '# rdp-vpn-ps-' }).Count
if ($_staleCount -gt 0) {
    $plural = if ($_staleCount -eq 1) { 'entry' } else { 'entries' }
    Write-Step "~ $_staleCount managed hosts $plural found — run -CleanHosts to remove." Yellow
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
    ,$list
}

function ConvertFrom-ProfileHex ([string[]]$HexLines) {
    $hex   = $HexLines -join ''
    $bytes = [byte[]]::new($hex.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($hex.Substring($i*2, 2), 16)
    }
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

# ── Build VPN profile list ────────────────────────────────────────────────────
if (-not (Test-Path $PBK)) { Write-Step "x rasphone.pbk not found: $PBK" Red; exit 1 }
$raw = Read-Pbk $PBK
$vpnProfiles = @(foreach ($r in $raw) {
    if ($r.Hex.Count -eq 0) { continue }
    $xml = ConvertFrom-ProfileHex $r.Hex
    if (-not $xml) { continue }
    $gwHost = $r.Phone -replace '^https?://','' -replace '/.*',''
    $auth   = if ($gwHost -match '^(wan|hub)\d*\.') { 'Entra' } `
              elseif ($gwHost -match '^azuregateway-') { 'Cert' } else { '?' }
    $tenantId = if ($xml -match '<tenant>https://login\.microsoftonline\.com/([^/]+)') { $Matches[1] } else { '' }
    $safeName      = $r.Name -replace '[\\/:*?"<>|]', '_'
    $containerName = 'vpn-' + ($r.Name -replace '[^a-zA-Z0-9-]', '-' -replace '-{2,}', '-').ToLower().Trim('-')
    $ps = if ($settings.profiles.PSObject.Properties[$r.Name]) { $settings.profiles.($r.Name) } else { $null }
    @{
        Name          = $r.Name
        SafeName      = $safeName
        ContainerName = $containerName
        Gw            = $gwHost
        Auth          = $auth
        TenantId      = $tenantId
        AzTenant      = if ($ps) { $ps.azTenant  } else { '' }
        DnsSuffix     = if ($ps) { $ps.dnsSuffix } else { '' }
        RdpUsername   = if ($ps) { [string]$ps.rdpUsername } else { '' }
        CachePath     = Join-Path $SECRETS "token-cache\$safeName.json"
    }
})

if ($vpnProfiles.Count -eq 0) { Write-Step 'x No VPN profiles found in rasphone.pbk.' Red; exit 1 }

# ── Arrow-key menu ────────────────────────────────────────────────────────────
function Show-ArrowMenu ([string]$Title, [string[]]$Lines) {
    $sel = 0; $n = $Lines.Count
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            $W  = [Math]::Max(60, [Console]::WindowWidth - 1)
            $hr = '─' * ($W - 2)
            Clear-Host
            Write-Host ''
            Write-Host "  $Title" -ForegroundColor Cyan
            Write-Host "  $hr" -ForegroundColor DarkGray
            Write-Host ''
            for ($i = 0; $i -lt $n; $i++) {
                if ($i -eq $sel) { Write-Host "  > $($Lines[$i])" -ForegroundColor Green }
                else             { Write-Host "    $($Lines[$i])" -ForegroundColor Gray  }
            }
            Write-Host ''
            Write-Host "  $hr" -ForegroundColor DarkGray
            Write-Host '  ↑↓ navigate   Enter select   Q quit' -ForegroundColor DarkGray
            $k = [Console]::ReadKey($true)
            switch ($k.Key) {
                'UpArrow'   { if ($sel -gt 0)    { $sel-- } }
                'DownArrow' { if ($sel -lt $n-1) { $sel++ } }
                'Enter'     { return $sel }
                'Escape'    { return -1 }
                default     { if ($k.KeyChar -in 'q','Q') { return -1 } }
            }
        }
    } finally { [Console]::CursorVisible = $true }
}

# ── Save profile settings (azTenant + dnsSuffix + rdpUsername + keepHostsEntry) ─
function Save-ProfileSettings ([hashtable[]]$Profiles, [string]$ToolName = '__unchanged__', [object]$SaveKeepHosts = $null) {
    $effectiveTool = if ($ToolName -eq '__unchanged__') { if ($settings.tenantTool) { [string]$settings.tenantTool } else { '' } } else { $ToolName }
    $effectiveKeep = if ($null -eq $SaveKeepHosts) {
        if ($settings.PSObject.Properties['keepHostsEntry']) { [bool]$settings.keepHostsEntry } else { $false }
    } else { [bool]$SaveKeepHosts }

    $obj = [ordered]@{ profiles = [ordered]@{} }
    if (-not [string]::IsNullOrWhiteSpace($effectiveTool)) { $obj['tenantTool'] = $effectiveTool }
    if ($effectiveKeep) { $obj['keepHostsEntry'] = $true }
    foreach ($p in $Profiles) {
        $obj.profiles[$p.Name] = [ordered]@{
            azTenant    = $p.AzTenant
            dnsSuffix   = $p.DnsSuffix
            rdpUsername = $p.RdpUsername
        }
    }
    $obj | ConvertTo-Json -Depth 4 | Set-Content -Path $settingsPath -Encoding UTF8
}

function Save-VmConnectAs ([string]$VmName, [string]$Value) {
    $obj = Get-Content $settingsPath -Raw | ConvertFrom-Json
    if (-not ($obj.PSObject.Properties.Name -contains 'vms')) {
        $obj | Add-Member -NotePropertyName 'vms' -NotePropertyValue ([PSCustomObject]@{})
    }
    if ($obj.vms.PSObject.Properties.Name -contains $VmName) {
        $obj.vms.$VmName.connectAs = $Value
    } else {
        $obj.vms | Add-Member -NotePropertyName $VmName -NotePropertyValue ([PSCustomObject]@{ connectAs = $Value })
    }
    $obj | ConvertTo-Json -Depth 6 | Set-Content -Path $settingsPath -Encoding UTF8
    $script:settings = $obj
}

# ── VM cache ──────────────────────────────────────────────────────────────────
function Get-VmCachePath ([string]$TenantId) {
    $dir = Join-Path $PSScriptRoot '.cache'
    if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory | Out-Null }
    Join-Path $dir "vms-$($TenantId -replace '[^a-zA-Z0-9-]','_').json"
}
function Read-VmCache ([string]$TenantId) {
    $p = Get-VmCachePath $TenantId
    if (-not (Test-Path $p)) { return $null }
    try { Get-Content $p -Raw | ConvertFrom-Json } catch { $null }
}
function Write-VmCache ([string]$TenantId, $Vms) {
    $p = Get-VmCachePath $TenantId
    @{ timestamp = [datetime]::UtcNow.ToString('o'); vms = $Vms } |
        ConvertTo-Json -Depth 10 | Set-Content $p -Encoding UTF8
}

# ── VM selection menu with optional background refresh ────────────────────────
function Get-RefreshDone ([object]$job) {
    if ($job -is [hashtable]) { return $job.Process.HasExited }
    return $job.State -eq 'Completed'
}
function Get-RefreshRunning ([object]$job) {
    if ($job -is [hashtable]) { return -not $job.Process.HasExited }
    return $job.State -eq 'Running'
}
function Receive-RefreshOutput ([object]$job) {
    if ($job -is [hashtable]) {
        if (Test-Path $job.OutFile) { return Get-Content $job.OutFile -Raw } else { return $null }
    }
    return Receive-Job $job 2>$null
}
function Stop-RefreshJob ([object]$job) {
    if ($null -eq $job) { return }
    if ($job -is [hashtable]) {
        if (-not $job.Process.HasExited) { try { $job.Process.Kill() } catch {} }
        foreach ($f in $job.TmpFiles + $job.OutFile) { Remove-Item $f -ErrorAction SilentlyContinue }
    } else {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -ErrorAction SilentlyContinue
    }
}

# ── VM info overlay (RBAC + extensions) ──────────────────────────────────────
function Show-VmInfo ([object]$Vm) {
    $resourceId = "/subscriptions/$($Vm.subscriptionId)/resourceGroups/$($Vm.rg)" +
                  "/providers/Microsoft.Compute/virtualMachines/$($Vm.name)"

    Clear-Host
    Write-Host ''
    Write-Host "  $($Vm.name)  [$($Vm.subscriptionName)]" -ForegroundColor Cyan
    Write-Host "  $resourceId" -ForegroundColor DarkGray
    Write-Host ''

    # ── Extensions ────────────────────────────────────────────────────────────
    Write-Host '  Extensions' -ForegroundColor Cyan
    Write-Host '  ──────────' -ForegroundColor DarkGray
    Write-Host '  (querying...)' -ForegroundColor DarkGray
    $extJson = az vm extension list `
        --resource-group $Vm.rg --vm-name $Vm.name `
        --subscription $Vm.subscriptionId `
        -o json 2>$null
    # erase the "(querying...)" line
    [Console]::SetCursorPosition(0, [Console]::CursorTop - 1)
    Write-Host (' ' * 20)
    [Console]::SetCursorPosition(0, [Console]::CursorTop - 1)

    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($extJson)) {
        $exts = @($extJson | ConvertFrom-Json)
        if ($exts.Count -eq 0) {
            Write-Host '  (geen extensions)' -ForegroundColor DarkGray
        } else {
            foreach ($ext in $exts) {
                $state = [string]$ext.provisioningState
                $color = switch ($state) { 'Succeeded' { 'DarkGreen' } 'Failed' { 'Red' } default { 'Yellow' } }
                $extType = [string]$ext.typePropertiesType
                if ([string]::IsNullOrWhiteSpace($extType)) { $extType = [string]$ext.type }
                Write-Host ("  {0,-36}  {1}" -f [string]$ext.name, $extType) -NoNewline -ForegroundColor Gray
                Write-Host "  $state" -ForegroundColor $color
            }
        }
    } else {
        Write-Host '  (az vm extension list failed — no read access?)' -ForegroundColor Yellow
    }

    Write-Host ''

    # ── RBAC ──────────────────────────────────────────────────────────────────
    Write-Host '  RBAC (current user, including parent scopes)' -ForegroundColor Cyan
    Write-Host '  ─────────────────────────────────────────────' -ForegroundColor DarkGray
    Write-Host '  (querying...)' -ForegroundColor DarkGray
    $objectId = az ad signed-in-user show --query id -o tsv 2>$null
    $rbacJson = if (-not [string]::IsNullOrWhiteSpace($objectId)) {
        az role assignment list `
            --assignee-object-id $objectId --scope $resourceId `
            --include-inherited --include-groups `
            --subscription $Vm.subscriptionId `
            -o json 2>$null
    } else { $null }
    [Console]::SetCursorPosition(0, [Console]::CursorTop - 1)
    Write-Host (' ' * 20)
    [Console]::SetCursorPosition(0, [Console]::CursorTop - 1)

    $assignments = @()
    if (-not [string]::IsNullOrWhiteSpace($rbacJson)) {
        $assignments = @($rbacJson | ConvertFrom-Json)
    }

    if ($assignments.Count -gt 0) {
        foreach ($a in $assignments) {
            $scopeShort = if ($a.scope -match '(/resourceGroups/.*)') { $Matches[1] } else { $a.scope }
            $principal  = if (-not [string]::IsNullOrWhiteSpace([string]$a.principalName)) { "  [$($a.principalType): $($a.principalName)]" } else { '' }
            Write-Host ("  {0,-40}  {1}{2}" -f [string]$a.roleDefinitionName, $scopeShort, $principal) -ForegroundColor Gray
        }
    } else {
        # No direct assignments — may be foreign principal / Lighthouse; show all on scope
        Write-Host '  (no direct assignments — showing all on scope, access may be via foreign principal)' -ForegroundColor Yellow
        $allJson = az role assignment list `
            --scope $resourceId --include-inherited `
            --subscription $Vm.subscriptionId `
            -o json 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($allJson)) {
            $all = @($allJson | ConvertFrom-Json)
            foreach ($a in $all) {
                $scopeShort = if ($a.scope -match '(/resourceGroups/.*)') { $Matches[1] } else { $a.scope }
                $principal  = if (-not [string]::IsNullOrWhiteSpace([string]$a.principalName)) { "  [$($a.principalType): $($a.principalName)]" } else { '' }
                Write-Host ("  {0,-40}  {1}{2}" -f [string]$a.roleDefinitionName, $scopeShort, $principal) -ForegroundColor DarkGray
            }
        } else {
            Write-Host '  (az role assignment list failed — no read access on Microsoft.Authorization?)' -ForegroundColor Yellow
        }
    }

    Write-Host ''
    Write-Host '  Press any key to go back...' -ForegroundColor DarkGray
    [Console]::ReadKey($true) | Out-Null
}

function Show-VmMenu ([string]$Title, [object[]]$Vms, [object]$RefreshJob) {
    # Returns: @{Index=N; UseDeviceName=bool} | @{Index=-1} (quit) | @{Back=$true} | @{Refresh=$true; Vms=[...]}
    $sel         = 0
    $n           = $Vms.Count
    $freshVms    = $null
    $keyTask     = $null   # Task[ConsoleKeyInfo] — one task alive at a time, reused across waits
    $needsRedraw = $true
    $lastLine    = ''      # track refreshLine to detect when status changes without a keypress

    # Per-VM connectAs state (device | fqdn), seeded from persisted settings
    $vmConnectAs = @{}
    if ($script:settings.vms) {
        foreach ($prop in $script:settings.vms.PSObject.Properties) {
            $vmConnectAs[$prop.Name] = [string]$prop.Value.connectAs
        }
    }
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            # Check background refresh job
            if ($null -ne $RefreshJob -and $null -eq $freshVms -and (Get-RefreshDone $RefreshJob)) {
                $out = Receive-RefreshOutput $RefreshJob
                if (-not [string]::IsNullOrWhiteSpace($out)) {
                    try   { $freshVms = @(($out | ConvertFrom-Json).data) }
                    catch { $freshVms = @() }
                } else { $freshVms = @() }
                $needsRedraw = $true
            }

            $refreshLine = if     ($null -eq $RefreshJob)                              { '' }
                           elseif ($null -ne $freshVms -and $freshVms.Count -gt 0)    { "   [R] reload ($($freshVms.Count) VMs)" }
                           elseif ($null -ne $freshVms)                                { '   [refresh: 0 VMs]' }
                           elseif (Get-RefreshRunning $RefreshJob)                     { '   [refreshing...]' }
                           else                                                         { '' }

            if ($refreshLine -ne $lastLine) { $needsRedraw = $true; $lastLine = $refreshLine }

            if ($needsRedraw) {
                $W   = [Math]::Max(72, [Console]::WindowWidth - 1)
                $hr  = '─' * ($W - 2)
                # fixed overhead = 4 (prefix "  > ") + 3×2 (separators) + 7 (OS "Windows")
                $var = $W - 17
                $nW  = [Math]::Min(36, [int]($var * 0.44))
                $rW  = [Math]::Min(28, [int]($var * 0.33))
                $sW  = [Math]::Max(8,  $var - $nW - $rW)
                Clear-Host
                Write-Host ''
                Write-Host "  $Title" -ForegroundColor Cyan
                Write-Host "  $hr" -ForegroundColor DarkGray
                Write-Host ''
                Write-Host ("    {0,-$nW}  {1,-$rW}  {2,-$sW}  {3}" -f 'Name','Resource Group','Subscription','OS') -ForegroundColor DarkGray
                Write-Host "    $('─'*$nW)  $('─'*$rW)  $('─'*$sW)  $('─'*7)" -ForegroundColor DarkGray
                Write-Host ''
                for ($i = 0; $i -lt $n; $i++) {
                    $v  = $Vms[$i]
                    $nm = [string]$v.name;             if ($nm.Length -gt $nW) { $nm = $nm.Substring(0,$nW-1)+'…' }
                    $rg = [string]$v.rg;               if ($rg.Length -gt $rW) { $rg = $rg.Substring(0,$rW-1)+'…' }
                    $sn = [string]$v.subscriptionName; if ($sn.Length -gt $sW) { $sn = $sn.Substring(0,$sW-1)+'…' }
                    $os = if ([string]$v.osType -eq 'Windows') { 'Windows' } elseif ([string]$v.osType -eq 'Linux') { 'Linux  ' } else { [string]$v.osType }
                    $row = "{0,-$nW}  {1,-$rW}  {2,-$sW}  {3}" -f $nm,$rg,$sn,$os
                    if ($i -eq $sel) { Write-Host "  > $row" -ForegroundColor Green }
                    else             { Write-Host "    $row" -ForegroundColor Gray  }
                }
                Write-Host ''
                Write-Host "  $hr" -ForegroundColor DarkGray
                $curVmName = [string]$Vms[$sel].name
                $hostLabel = if ($vmConnectAs[$curVmName] -eq 'device') { 'device' } else { 'FQDN' }
                Write-Host "  ↑↓ navigate   Enter select   I info   H host:$hostLabel   Esc/← back   Q quit$refreshLine" -ForegroundColor DarkGray
                $needsRedraw = $false
            }

            # Key input: PowerShell.Create() + BeginInvoke() + AsyncWaitHandle.WaitOne(ms).
            # Task.Run fails because PS script blocks need a runspace — threadpool threads
            # don't have one. PowerShell.Create() supplies its own runspace.
            # AsyncWaitHandle.WaitOne returns early on keypress; -1 = wait forever.
            # One PS instance is kept alive across wait iterations — never two threads on ReadKey.
            if ($null -eq $keyTask) {
                $kPs = [System.Management.Automation.PowerShell]::Create()
                $kPs.AddScript('[Console]::ReadKey($true)') | Out-Null
                $keyTask = @{ Ps = $kPs; Ar = $kPs.BeginInvoke() }
            }
            $waitMs = if ($null -ne $RefreshJob -and $null -eq $freshVms) { 300 } else { -1 }
            $keyTask.Ar.AsyncWaitHandle.WaitOne($waitMs) | Out-Null
            if (-not $keyTask.Ar.IsCompleted) { continue }  # timeout → loop to re-check refresh

            $k = ($keyTask.Ps.EndInvoke($keyTask.Ar))[0]
            $keyTask.Ps.Dispose()
            $keyTask = $null
            $needsRedraw = $true
            switch ($k.Key) {
                'UpArrow'   { if ($sel -gt 0)    { $sel-- } }
                'DownArrow' { if ($sel -lt $n-1) { $sel++ } }
                'Enter'     { return @{ Index = $sel; UseDeviceName = ($vmConnectAs[[string]$Vms[$sel].name] -eq 'device') } }
                'Escape'    { return @{ Back  = $true } }
                'Backspace' { return @{ Back  = $true } }
                default {
                    switch ($k.KeyChar) {
                        { $_ -in 'q','Q' } { return @{ Index = -1 } }
                        { $_ -in 'r','R' -and $null -ne $freshVms -and $freshVms.Count -gt 0 } {
                            return @{ Refresh = $true; Vms = $freshVms }
                        }
                        { $_ -in 'h','H' } {
                            $vmName = [string]$Vms[$sel].name
                            $newVal = if ($vmConnectAs[$vmName] -eq 'device') { 'fqdn' } else { 'device' }
                            $vmConnectAs[$vmName] = $newVal
                            Save-VmConnectAs $vmName $newVal
                        }
                        { $_ -in 'i','I' } {
                            Show-VmInfo $Vms[$sel]
                            $needsRedraw = $true
                        }
                    }
                }
            }
        }
    } finally {
        [Console]::CursorVisible = $true
        if ($null -ne $keyTask) { try { $keyTask.Ps.Dispose() } catch {} }
    }
}

# ── Profile picker TUI ────────────────────────────────────────────────────────
function Show-ProfileMenu ([hashtable[]]$Profiles, [string]$CurrentTool, [bool]$CurrentKeep = $false) {
    $sel  = 0
    $n    = $Profiles.Count
    $tool = $CurrentTool
    $keep = $CurrentKeep
    $running = @(wsl -d Ubuntu-20.04 -- docker ps --format '{{.Names}}' 2>$null)
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            $W        = [Math]::Max(72, [Console]::WindowWidth - 1)
            $tenantW  = [Math]::Min(26, [int]($W * 0.30))
            $profileW = [Math]::Max(20, $W - 4 - $tenantW - 2 - 10 - 2)
            $hr       = '─' * ($W - 2)
            $toolName = if ($tool -eq 'az-context') { 'az-context.ps1' } else { 'native az CLI' }

            Clear-Host
            Write-Host ''
            Write-Host '  Select tenant' -ForegroundColor Cyan
            Write-Host "  $hr" -ForegroundColor DarkGray
            Write-Host ''
            $hdr = ('{0,-' + $tenantW + '}  {1,-' + $profileW + '}  {2}') -f 'Tenant', 'VPN Profile', 'VPN'
            Write-Host "    $hdr" -ForegroundColor DarkGray
            Write-Host "    $('─' * $tenantW)  $('─' * $profileW)  ─────────" -ForegroundColor DarkGray
            Write-Host ''

            for ($i = 0; $i -lt $n; $i++) {
                $p      = $Profiles[$i]
                $tenant = if ([string]::IsNullOrWhiteSpace($p.AzTenant)) { '(not set)' } else { $p.AzTenant }
                $name   = $p.Name
                $isRun  = $running -contains $p.ContainerName
                $status = if ($isRun) { '[running]' } else { '' }
                if ($tenant.Length -gt $tenantW) { $tenant = $tenant.Substring(0, $tenantW - 3) + '...' }
                if ($name.Length   -gt $profileW) { $name  = $name.Substring(0, $profileW - 3)  + '...' }
                $row = ('{0,-' + $tenantW + '}  {1,-' + $profileW + '}  {2}') -f $tenant, $name, $status

                if ($i -eq $sel)    { Write-Host "  > $row" -ForegroundColor Green }
                elseif ($isRun)     { Write-Host "    $row" -ForegroundColor White }
                else                { Write-Host "    $row" -ForegroundColor Gray  }
            }

            Write-Host ''
            Write-Host "  $hr" -ForegroundColor DarkGray
            $keepLabel = if ($keep) { 'on' } else { 'off' }
            Write-Host "  ↑↓ navigate   Enter select   E edit tenant   T toggle [$toolName]   K keep-hosts:[$keepLabel]   Q quit" -ForegroundColor DarkGray
            if ($script:_staleCount -gt 0) {
                $stalePlural = if ($script:_staleCount -eq 1) { 'entry' } else { 'entries' }
                Write-Host "  ~ $($script:_staleCount) managed hosts $stalePlural found — run -CleanHosts to remove." -ForegroundColor Yellow
            }

            $k = [Console]::ReadKey($true)
            switch ($k.Key) {
                'UpArrow'   { if ($sel -gt 0)    { $sel-- } }
                'DownArrow' { if ($sel -lt $n-1) { $sel++ } }
                'Enter'     { return @{ Index = $sel; TenantTool = $tool; KeepHostsEntry = $keep } }
                'Escape'    { return @{ Index = -1;   TenantTool = $tool; KeepHostsEntry = $keep } }
                default {
                    switch ($k.KeyChar) {
                        { $_ -in 'q','Q' } { return @{ Index = -1; TenantTool = $tool; KeepHostsEntry = $keep } }
                        { $_ -in 'e','E' } {
                            [Console]::CursorVisible = $true
                            $editRow = [Math]::Min([Console]::CursorTop + 1, [Console]::WindowHeight - 3)
                            [Console]::SetCursorPosition(0, $editRow)
                            $cur = if ([string]::IsNullOrWhiteSpace($Profiles[$sel].AzTenant)) { '' } else { $Profiles[$sel].AzTenant }
                            Write-Host "  Edit tenant for '$($Profiles[$sel].Name)'" -ForegroundColor Cyan
                            Write-Host -NoNewline "  New value (blank = keep '$cur'): "
                            $newVal = Read-Host
                            [Console]::CursorVisible = $false
                            if (-not [string]::IsNullOrWhiteSpace($newVal)) {
                                $Profiles[$sel].AzTenant = $newVal.Trim()
                                Save-ProfileSettings $Profiles
                            }
                        }
                        { $_ -in 't','T' } {
                            $tool = if ($tool -eq 'az-context') { '' } else { 'az-context' }
                            Save-ProfileSettings $Profiles $tool
                        }
                        { $_ -in 'k','K' } {
                            $keep = -not $keep
                            Save-ProfileSettings $Profiles '__unchanged__' $keep
                            $script:settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
                        }
                    }
                }
            }
        }
    } finally { [Console]::CursorVisible = $true }
}

# ── Tenant switching ──────────────────────────────────────────────────────────
function Switch-AzTenant ([string]$AzTenantName, [string]$ExpectedTenantId) {
    if ($Tenant -eq 'current') { return }

    if ($TenantTool -eq 'az-context') {
        Write-Step "Switching az context → $AzTenantName  (via az-context)..." Cyan
        # az-context.ps1 without -Login only sets AZURE_CONFIG_DIR (no native commands).
        # $LASTEXITCODE is unreliable here ($null -ne 0 is $true in PowerShell).
        & 'c:\prg\az-context.ps1' -tenant $AzTenantName
        $check = (az account show --query tenantId -o tsv 2>$null)
        if ($check -ne $ExpectedTenantId) {
            Write-Step "~ Token expired or no cached session — running az-context -login for $AzTenantName..." Yellow
            & 'c:\prg\az-context.ps1' -tenant $AzTenantName -login
        }
    } else {
        $cur = (az account show --query tenantId -o tsv 2>$null)
        if ($cur -ne $ExpectedTenantId) {
            Write-Step "Switching az tenant → $ExpectedTenantId..." Cyan
            $subId = (az account list --query "[?tenantId=='$ExpectedTenantId'] | [0].id" -o tsv 2>$null)
            if (-not [string]::IsNullOrWhiteSpace($subId)) {
                az account set --subscription $subId 2>$null | Out-Null
            }
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($subId)) {
                Write-Step "No cached subscription for tenant, running az login..." Yellow
                az login --tenant $ExpectedTenantId --allow-no-subscriptions | Out-Null
                if ($LASTEXITCODE -ne 0) { Write-Step 'x az login failed.' Red; exit 1 }
            }
        }
    }

    $actual = (az account show --query tenantId -o tsv 2>$null)
    if ($actual -ne $ExpectedTenantId) {
        Write-Step "x Tenant mismatch after switch: got '$actual', expected '$ExpectedTenantId'" Red; exit 1
    }
    Write-Step "+ Tenant OK: $ExpectedTenantId" DarkGreen
}

# ── Ensure VPN container running ──────────────────────────────────────────────
function Start-VpnContainer ([hashtable]$VpnProfile) {
    $running = @(wsl -d Ubuntu-20.04 -- docker ps --format '{{.Names}}' 2>$null)
    if ($running -contains $VpnProfile.ContainerName) {
        Write-Step "+ VPN already active: $($VpnProfile.ContainerName)" DarkGreen
        return
    }
    Write-Step "Starting VPN for '$($VpnProfile.Name)'..." Yellow
    & (Join-Path $PSScriptRoot 'connect-vpn.ps1') -VpnProfile $VpnProfile.Name
    if ($LASTEXITCODE -ne 0) { Write-Step 'x VPN connect failed.' Red; exit 1 }
}

# ── RDP file signing ──────────────────────────────────────────────────────────
function Get-OrCreate-RdpSigningCert {
    $certName = 'rdp-connect publisher'
    $cert = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq "CN=$certName" -and $_.NotAfter -gt (Get-Date).AddDays(30) } |
        Select-Object -First 1
    if (-not $cert) {
        Write-Step 'Creating RDP signing certificate...' DarkGray
        $cert = New-SelfSignedCertificate `
            -Subject "CN=$certName" `
            -CertStoreLocation 'Cert:\CurrentUser\My' `
            -KeyUsage DigitalSignature `
            -Type CodeSigningCert `
            -NotAfter (Get-Date).AddYears(10) `
            -ErrorAction SilentlyContinue
        if (-not $cert) { return $null }

        # Root: self-signed cert must be its own trusted root for the chain to validate.
        # CurrentUser\Root addition may show a one-time Windows confirmation dialog.
        $rootStore = [System.Security.Cryptography.X509Certificates.X509Store]::new(
            [System.Security.Cryptography.X509Certificates.StoreName]::Root,
            [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
        $rootStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $rootStore.Add($cert)
        $rootStore.Close()

        # TrustedPublisher: mstsc checks this to show "Verified publisher" instead of warning.
        $tpStore = [System.Security.Cryptography.X509Certificates.X509Store]::new(
            [System.Security.Cryptography.X509Certificates.StoreName]::TrustedPublisher,
            [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
        $tpStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $tpStore.Add($cert)
        $tpStore.Close()

        Write-Step '+ RDP signing cert created (Root + TrustedPublisher)' DarkGreen
    }
    return $cert
}

function Invoke-SignRdpFile ([string]$Path, [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert) {
    # Use rdpsign.exe — it produces the proprietary Microsoft CMS wrapper with SHA-256 that
    # mstsc actually verifies. It reads the cert from CurrentUser\My (or LocalMachine\My).
    $rdpsign = Join-Path $env:SystemRoot 'System32\rdpsign.exe'
    if (-not (Test-Path $rdpsign)) { throw 'rdpsign.exe not found — Remote Desktop client must be installed' }

    # rdpsign.exe expects UTF-16LE with CRLF line endings.
    $text = [System.IO.File]::ReadAllText($Path)
    $text = $text -replace '\r?\n', "`r`n"
    if (-not $text.EndsWith("`r`n")) { $text += "`r`n" }
    [System.IO.File]::WriteAllText($Path, $text, [System.Text.Encoding]::Unicode)

    $out = & $rdpsign /sha256 $Cert.Thumbprint $Path 2>&1
    if ($LASTEXITCODE -ne 0) { throw "rdpsign.exe failed (exit $LASTEXITCODE): $out" }
}

# ── Free local port ───────────────────────────────────────────────────────────
function Get-FreePort ([int]$Start = 13389) {
    $p = $Start
    while ($true) {
        try {
            $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $p)
            $l.Start(); $l.Stop(); return $p
        } catch { $p++ }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

$targetProfile  = $null
$targetHostname = ''
$targetDevice   = ''

# ── Path A: -Hostname given — skip VM discovery ───────────────────────────────
if (-not [string]::IsNullOrWhiteSpace($Hostname)) {
    $targetHostname = $Hostname
    $targetDevice   = $Hostname.Split('.')[0]

    # Auto-match VPN profile via dnsSuffix
    $matched = @($vpnProfiles | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.DnsSuffix) -and
        $Hostname.ToLower().EndsWith('.' + $_.DnsSuffix.ToLower().TrimStart('.'))
    })

    if ($matched.Count -eq 1) {
        $targetProfile = $matched[0]
        Write-Step "Auto-matched profile: $($targetProfile.Name)  (suffix: $($targetProfile.DnsSuffix))" DarkGreen
    } elseif ($matched.Count -gt 1) {
        $lines = @($matched | ForEach-Object { "$($_.Name)  [$($_.DnsSuffix)]" })
        $idx = Show-ArrowMenu 'Multiple profiles match hostname suffix — pick one' $lines
        if ($idx -lt 0) { exit 0 }
        $targetProfile = $matched[$idx]
    } else {
        Write-Step "~ No dnsSuffix matched '$Hostname' — pick VPN profile manually:" Yellow
        $lines = @($vpnProfiles | ForEach-Object { "$($_.Name)  [$($_.Gw)]" })
        $idx = Show-ArrowMenu 'Select VPN profile' $lines
        if ($idx -lt 0) { exit 0 }
        $targetProfile = $vpnProfiles[$idx]
    }
}

# ── Path B: VM discovery ──────────────────────────────────────────────────────
else {
    $usingMenu = -not ($Tenant -ne 'current' -and $Tenant -ne 'auto' -and -not [string]::IsNullOrWhiteSpace($Tenant))
    :tenantloop while ($true) {
    # Select VPN profile ───────────────────────────────────────────────────────
    if ($Tenant -ne 'current' -and $Tenant -ne 'auto' -and -not [string]::IsNullOrWhiteSpace($Tenant)) {
        $matched = @($vpnProfiles | Where-Object { $_.AzTenant -eq $Tenant })
        if ($matched.Count -eq 0) { Write-Step "x No VPN profile found for tenant '$Tenant'." Red; exit 1 }
        if ($matched.Count -eq 1) {
            $targetProfile = $matched[0]
        } else {
            $lines = @($matched | ForEach-Object { $_.Name })
            $idx = Show-ArrowMenu "Multiple profiles for tenant '$Tenant' — pick one" $lines
            if ($idx -lt 0) { exit 0 }
            $targetProfile = $matched[$idx]
        }
    } else {
        $result = Show-ProfileMenu $vpnProfiles $TenantTool $keepEntry
        if ($result.Index -lt 0) { exit 0 }
        $targetProfile = $vpnProfiles[$result.Index]
        $TenantTool    = $result.TenantTool
        $keepEntry     = $result.KeepHostsEntry
    }

    Clear-Host
    Write-Host ''
    Write-Host "  ┌─ $($targetProfile.Name)" -ForegroundColor Cyan
    Write-Host "  │  Container : $($targetProfile.ContainerName)" -ForegroundColor Gray
    Write-Host "  │  Tenant    : $($targetProfile.TenantId)" -ForegroundColor Gray
    Write-Host "  │  az tenant : $($targetProfile.AzTenant)" -ForegroundColor Gray
    Write-Host "  └─$("─" * 50)" -ForegroundColor Cyan
    Write-Host ''

    # Switch az tenant ─────────────────────────────────────────────────────────
    if ($Tenant -ne 'current' -and -not [string]::IsNullOrWhiteSpace($targetProfile.AzTenant)) {
        Switch-AzTenant $targetProfile.AzTenant $targetProfile.TenantId
    }

    # Query and cache tenant-specific RDP username ─────────────────────────────
    if ($Tenant -ne 'current' -and -not [string]::IsNullOrWhiteSpace($targetProfile.AzTenant)) {
        $tenantUpn = (az ad signed-in-user show --query userPrincipalName -o tsv 2>$null)?.Trim()
        if (-not [string]::IsNullOrWhiteSpace($tenantUpn) -and $tenantUpn -ne $targetProfile.RdpUsername) {
            $targetProfile.RdpUsername = $tenantUpn
            Save-ProfileSettings $vpnProfiles
            Write-Step "+ Cached RDP username for '$($targetProfile.Name)': $tenantUpn" DarkGreen
        }
    }

    # Query VMs ────────────────────────────────────────────────────────────────

    if (-not [string]::IsNullOrWhiteSpace($ResourceId)) {
        if ($ResourceId -notmatch '/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Compute/virtualMachines/[^/]+') {
            Write-Step 'x Invalid -ResourceId format.' Red; exit 1
        }
        $azArgs = @('vm', 'show', '--ids', $ResourceId, '--show-details',
            '--query', '{name:name, computerName:osProfile.computerName, ip:privateIps, rg:resourceGroup}',
            '-o', 'json')
        $vmJson = az @azArgs 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vmJson)) {
            Write-Step 'x az vm show failed.' Red; exit 1
        }
        $vms      = @($vmJson | ConvertFrom-Json)
        $targetVm = $vms[0]
        $useDeviceName = ($settings.vms -and $settings.vms.PSObject.Properties[$targetVm.name] -and
                          [string]$settings.vms.($targetVm.name).connectAs -eq 'device')
        Write-Step "VM: $($targetVm.name)  ($($targetVm.computerName) / $($targetVm.ip))" DarkGreen
    } else {
        # Resource Graph: cross-subscription VM discovery.
        # Ensure extension is present before querying (avoids an interactive install prompt).
        az extension show --name resource-graph -o none 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Step 'Installing resource-graph extension...' DarkGray
            az extension add --name resource-graph --yes 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Step 'x resource-graph extension install failed.' Red; exit 1 }
        }

        $kqlFilters = @("type =~ 'microsoft.compute/virtualmachines'")
        if (-not [string]::IsNullOrWhiteSpace($ResourceGroup)) { $kqlFilters += "resourceGroup =~ '$ResourceGroup'" }
        $kql = @"
Resources
| where $($kqlFilters -join ' and ')
| project name,
    computerName=tostring(properties.osProfile.computerName),
    osType=tostring(properties.storageProfile.osDisk.osType),
    rg=resourceGroup, subscriptionId,
    nicId=tolower(tostring(properties.networkProfile.networkInterfaces[0].id))
| join kind=leftouter (
    ResourceContainers
    | where type == 'microsoft.resources/subscriptions'
    | project subscriptionId, subscriptionName=name
) on subscriptionId
| project name, computerName, osType, rg, subscriptionId, subscriptionName, nicId
| order by name asc
"@
        $kql = $kql -replace '\r?\n\s*', ' '
        $graphArgs = @('graph', 'query', '-q', $kql, '--first', '500', '-o', 'json')
        if (-not [string]::IsNullOrWhiteSpace($Subscription)) { $graphArgs += '--subscription', $Subscription }

        # Cache-first: show cached list immediately, refresh in background
        $vmCache    = Read-VmCache $targetProfile.TenantId
        $cacheLabel = ''
        $refreshJob = $null

        if ($vmCache) {
            $ageMin     = [int]([datetime]::UtcNow - [datetime]$vmCache.timestamp).TotalMinutes
            $cacheLabel = "[cached ${ageMin}m ago]"
            $vms        = @($vmCache.vms)

            # Start-Job is blocked in ConstrainedLanguage mode (WDAC/AppLocker).
            # Use a hidden pwsh child process + temp files instead.
            $rnd       = Get-Random
            $tmpArgs   = "$env:TEMP\rdp-vmq-args-$rnd.json"
            $tmpOut    = "$env:TEMP\rdp-vmq-out-$rnd.json"
            $tmpScript = "$env:TEMP\rdp-vmq-$rnd.ps1"
            $graphArgs | ConvertTo-Json | Set-Content $tmpArgs -Encoding UTF8
            # Child inherits $env:AZURE_CONFIG_DIR automatically; script uses only cmdlets (ConstrainedLanguage-safe)
            Set-Content $tmpScript -Encoding UTF8 -Value @"
`$a = @(Get-Content '$tmpArgs' -Raw | ConvertFrom-Json)
az @a 2>`$null | Set-Content '$tmpOut' -Encoding UTF8
"@
            $refreshJob = @{
                Process    = Start-Process pwsh -WindowStyle Hidden -PassThru `
                                 -ArgumentList "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$tmpScript`""
                OutFile    = $tmpOut
                TmpFiles   = @($tmpArgs, $tmpScript)
            }
        } else {
            Write-Step 'Querying VMs...' DarkGray
            $vmJson = az @graphArgs 2>$null
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vmJson)) {
                Write-Step 'x az graph query failed.' Red; exit 1
            }
            $vms        = @(($vmJson | ConvertFrom-Json).data)
            $cacheLabel = '[live]'
            Write-VmCache $targetProfile.TenantId $vms
        }

        # Apply name filter for display
        $displayVms = if ([string]::IsNullOrWhiteSpace($Name)) { $vms } else {
            @($vms | Where-Object { $_.name -like "*$Name*" -or $_.computerName -like "*$Name*" })
        }
        if ($displayVms.Count -eq 0) { Write-Step 'x No VMs found matching filters.' Red; exit 1 }

        # Pick VM — always via menu so the user can trigger background refresh with R
        $targetVm = $null
        while ($true) {
            $result = Show-VmMenu "Select VM  $cacheLabel" $displayVms $refreshJob
            if ($result.Back) {
                Stop-RefreshJob $refreshJob
                if ($usingMenu) { continue tenantloop } else { exit 0 }
            }
            if ($result.Index -eq -1) {
                Stop-RefreshJob $refreshJob
                exit 0
            }
            if ($result.Refresh) {
                $vms = $result.Vms
                Write-VmCache $targetProfile.TenantId $vms
                $refreshJob = $null
                $cacheLabel = '[live]'
                $displayVms = if ([string]::IsNullOrWhiteSpace($Name)) { $vms } else {
                    @($vms | Where-Object { $_.name -like "*$Name*" -or $_.computerName -like "*$Name*" })
                }
                if ($displayVms.Count -eq 0) { Write-Step '~ No VMs match filter after refresh.' Yellow }
                continue
            }
            $targetVm      = $displayVms[$result.Index]
            $useDeviceName = [bool]$result.UseDeviceName
            break
        }
        Stop-RefreshJob $refreshJob

        # Resolve IP lazily — only needed when no DNS suffix is configured
        if ([string]::IsNullOrWhiteSpace($targetProfile.DnsSuffix) -and
            [string]::IsNullOrWhiteSpace($targetVm.ip) -and
            -not [string]::IsNullOrWhiteSpace($targetVm.nicId)) {
            Write-Step 'Resolving VM IP address...' DarkGray
            $nicKql  = "Resources | where type =~ 'microsoft.network/networkinterfaces' and tolower(id) == '$($targetVm.nicId)' | project ip=tostring(properties.ipConfigurations[0].properties.privateIPAddress)"
            $nicJson = az graph query -q $nicKql --first 1 -o json 2>$null
            if (-not [string]::IsNullOrWhiteSpace($nicJson)) {
                $nicIp = (($nicJson | ConvertFrom-Json).data | Select-Object -First 1).ip
                if (-not [string]::IsNullOrWhiteSpace($nicIp)) {
                    $targetVm | Add-Member -NotePropertyName ip -NotePropertyValue $nicIp -Force
                }
            }
        }
    }

    $targetDevice = $targetVm.computerName
    $dnsSuffix    = $targetProfile.DnsSuffix

    if ([string]::IsNullOrWhiteSpace($dnsSuffix)) {
        Write-Step 'Querying private DNS zones...' DarkGray
        $zonesJson = az graph query -q "Resources | where type =~ 'microsoft.network/privatednszones' | project name | order by name asc" --first 200 -o json 2>$null
        $zones = @(if (-not [string]::IsNullOrWhiteSpace($zonesJson)) { ($zonesJson | ConvertFrom-Json).data | ForEach-Object { $_.name } })
        $menuItems = @()
        if ($zones.Count -gt 0) { $menuItems += $zones }
        $menuItems += '(enter manually)'
        $menuItems += '(use IP address)'
        $idx = Show-ArrowMenu "No DNS suffix for '$($targetProfile.Name)' — pick one" $menuItems
        if ($idx -lt 0) { exit 0 }
        $chosen = $menuItems[$idx]
        switch ($chosen) {
            '(use IP address)' { $dnsSuffix = '' }
            '(enter manually)' {
                Write-Host -NoNewline '  DNS suffix (e.g. corp.example.com): '
                $dnsSuffix = (Read-Host).Trim()
            }
            default { $dnsSuffix = $chosen }
        }
        if (-not [string]::IsNullOrWhiteSpace($dnsSuffix)) {
            $targetProfile.DnsSuffix = $dnsSuffix
            Save-ProfileSettings $vpnProfiles
            Write-Step "+ DNS suffix saved to settings: $dnsSuffix" DarkGreen
        }
    }

    $targetHostname = if (-not [string]::IsNullOrWhiteSpace($dnsSuffix)) {
        "$targetDevice.$dnsSuffix"
    } else {
        Write-Step "~ No DNS suffix — using IP: $($targetVm.ip)" Yellow
        $targetVm.ip
    }
    # RDP address: short device name when toggled, FQDN otherwise
    $targetDevice = if ($useDeviceName) { $targetVm.computerName } else { $targetHostname }
    Write-Step "Target : $targetHostname  (rdp: $targetDevice)" DarkGreen
    break tenantloop
    } # :tenantloop
}

# ── Ensure VPN ────────────────────────────────────────────────────────────────
Write-Host ''
Start-VpnContainer $targetProfile
$containerName = $targetProfile.ContainerName

# ── DNS preflight ─────────────────────────────────────────────────────────────
Write-Host ''
$isIpTarget = $targetHostname -match '^\d+\.\d+\.\d+\.\d+$'
if ($isIpTarget) {
    Write-Step "~ Skipping DNS check (connecting directly to IP: $targetHostname)" DarkGray
} else {
    Write-Step "Checking DNS: $targetHostname  →  net:$containerName" DarkGray
    $dnsOut = wsl -d Ubuntu-20.04 -- docker run --rm "--net=container:$containerName" busybox nslookup $targetHostname 2>&1
    if ($LASTEXITCODE -ne 0 -or ($dnsOut -match "can't resolve" -or $dnsOut -match 'NXDOMAIN')) {
        Write-Step "x Cannot resolve '$targetHostname' via $containerName." Red
        Write-Step "  VPN active? Try: .\nslookup-vpn.ps1 $targetHostname -Container $containerName" DarkGray
        exit 1
    }
    Write-Step '+ DNS OK' DarkGreen
}

# ── Local port ────────────────────────────────────────────────────────────────
if ($LocalPort -eq 0) { $LocalPort = Get-FreePort }

# ── Socat proxy ───────────────────────────────────────────────────────────────
Write-Host ''
Write-Step "Starting RDP proxy  →  $targetHostname" Cyan
Write-Step "VPN container : $containerName"
Write-Step "Local port    : $LocalPort"
Write-Host ''

$result = wsl -d Ubuntu-20.04 -- bash $WslProxy start $containerName $targetHostname $LocalPort $RemotePort
if ($LASTEXITCODE -ne 0 -or $result -ne 'ok') {
    Write-Step 'x Proxy start failed.' Red; exit 1
}

# ── Wait for port ─────────────────────────────────────────────────────────────
Write-Step 'Waiting for proxy port...' DarkGray
$deadline = (Get-Date).AddSeconds(15)
do {
    $ready = (Test-NetConnection -ComputerName 127.0.0.1 -Port $LocalPort `
        -WarningAction SilentlyContinue -ErrorAction SilentlyContinue).TcpTestSucceeded
    if (-not $ready) { Start-Sleep -Milliseconds 500 }
} while (-not $ready -and (Get-Date) -lt $deadline)

if (-not $ready) {
    Write-Step "x Port $LocalPort not responding after 15s." Red
    wsl -d Ubuntu-20.04 -- bash $WslProxy stop $containerName $targetHostname 2>$null | Out-Null; exit 1
}

# ── RDP ───────────────────────────────────────────────────────────────────────
$RdpFile     = "$env:TEMP\vpn-rdp-$targetDevice.rdp"
$hostsPath   = "$env:windir\System32\drivers\etc\hosts"
$hostsMarker = "# rdp-vpn-ps-$targetDevice"
$hostsLine   = "127.0.0.1 $targetDevice  $hostsMarker"
$hostsAdded  = $false
$isAdmin     = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                 [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $NoEntraAuth) {
    Write-Step "Adding to hosts: $hostsLine" DarkGray
    if ($isAdmin) {
        Add-Content -LiteralPath $hostsPath -Value "`n$hostsLine" -Encoding UTF8
    } else {
        $tmp = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.ps1'
        [System.IO.File]::WriteAllText($tmp,
            "Add-Content -LiteralPath '$hostsPath' -Value `"``n$hostsLine`" -Encoding UTF8",
            [System.Text.UTF8Encoding]::new($false))
        Write-Step '! UAC prompt: editing hosts file requires admin' Yellow
        try {
            Start-Process powershell -Verb RunAs -Wait `
                -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$tmp`""
        } catch {
            Remove-Item $tmp -ErrorAction SilentlyContinue
            Write-Step "x Hosts update cancelled: $($_.Exception.Message)" Red; exit 1
        }
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    $hostsAdded = $true
    Write-Step "+ Hosts: 127.0.0.1 $targetDevice" DarkGreen
}

if (-not $Username) {
    if (-not [string]::IsNullOrWhiteSpace($targetProfile.RdpUsername)) {
        $Username = $targetProfile.RdpUsername
    } else {
        try { $Username = (whoami /upn 2>$null)?.Trim() } catch {}
    }
}

try {
    if ($NoEntraAuth) {
        $rdpBody = @"
full address:s:127.0.0.1:${LocalPort}
prompt for credentials:i:1
authentication level:i:0
enablecredsspsupport:i:1
targetisaadjoined:i:1
redirectclipboard:i:1
redirectprinters:i:0
"@
        Write-Step 'Mode: classic (no Entra auth)' DarkGray
    } else {
        $rdpBody = @"
full address:s:${targetDevice}:${LocalPort}
prompt for credentials:i:0
authentication level:i:0
enablecredsspsupport:i:1
enablerdsaadauth:i:1
targetisaadjoined:i:1
redirectclipboard:i:1
redirectprinters:i:0
"@
        Write-Step 'Mode: Entra ID (WAM)' DarkGray
    }
    if ($Username) { $rdpBody += "username:s:$Username`r`n" }
    $rdpBody | Set-Content -Path $RdpFile

    # Sign the .rdp file — suppresses the "Unknown publisher" security warning in mstsc
    $signingCert = Get-OrCreate-RdpSigningCert
    if ($signingCert) {
        try {
            Invoke-SignRdpFile $RdpFile $signingCert
            Write-Step '+ RDP file signed (publisher warning suppressed)' DarkGreen
        } catch {
            Write-Step "~ RDP signing failed: $_" Yellow
        }
    }

    Write-Step "+ RDP profile: $RdpFile" DarkGreen

    Write-Host ''
    Write-Step "Launching mstsc  →  $targetHostname  (close window to clean up)" Cyan
    Write-Host ''
    Start-Process -FilePath mstsc -ArgumentList $RdpFile -Wait
} finally {
    Write-Host ''
    Write-Step 'Cleaning up...' DarkGray

    if ($hostsAdded -and -not $keepEntry) {
        $rmPat = [regex]::Escape($hostsMarker)
        if ($isAdmin) {
            (Get-Content -LiteralPath $hostsPath) |
                Where-Object { $_ -notmatch $rmPat } |
                Set-Content -LiteralPath $hostsPath -Encoding UTF8
        } else {
            $tmp = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.ps1'
            [System.IO.File]::WriteAllText($tmp,
                "(Get-Content -LiteralPath '$hostsPath') | Where-Object { `$_ -notmatch '$rmPat' } | Set-Content -LiteralPath '$hostsPath' -Encoding UTF8",
                [System.Text.UTF8Encoding]::new($false))
            Start-Process powershell -Verb RunAs -Wait `
                -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$tmp`""
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }
        Write-Step "- Hosts entry removed ($targetDevice)" DarkGray
    } elseif ($hostsAdded) {
        Write-Step "~ Hosts entry kept: 127.0.0.1 $targetDevice  (run -CleanHosts to remove later)" DarkGray
    }

    wsl -d Ubuntu-20.04 -- bash $WslProxy stop $containerName $targetHostname 2>$null | Out-Null
    Write-Step '- Proxy containers stopped' DarkGray
    Remove-Item -Path $RdpFile -ErrorAction SilentlyContinue
    Write-Step 'Done.' DarkGray
}
