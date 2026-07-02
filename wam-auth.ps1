#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Acquire an Azure VPN token via Windows Authentication Manager (WAM) and write
  the 2-level MSAL cache JSON that the VPN container (libLinuxCore.so) expects.
.DESCRIPTION
  Uses Microsoft.Identity.Client.Broker (from Az.Accounts) to acquire a token for
  the Azure VPN resource. Tries silent auth first (SSO from a previous Windows VPN
  Client login), then falls back to an interactive WAM popup.

  Writes the cache in the same 2-level base64 format as src/device_code.py:
    { "": "<base64(msalJson)>", "<homeId>": "<base64(msalJson)>" }

  Exits 0 on success, 1 on any failure (caller falls back to device code flow).
.PARAMETER ProfileName
  VPN profile name — for display only.
.PARAMETER TenantId
  Azure AD resource tenant ID (the tenant where the VPN gateway is registered).
.PARAMETER CachePath
  Windows path to write the 2-level JSON cache file.
.PARAMETER Force
  Force token acquisition even if the existing cache is still valid.
.EXAMPLE
  .\wam-auth.ps1 -ProfileName "My Company VPN" `
                 -TenantId 00000000-0000-0000-0000-000000000000 `
                 -CachePath "$env:USERPROFILE\.azure-vpn-shim\token-cache\My Company VPN.json"
#>
param(
    [Parameter(Mandatory)] [string]$ProfileName,
    [Parameter(Mandatory)] [string]$TenantId,
    [Parameter(Mandatory)] [string]$CachePath,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# VPN resource app (audience) — scope target
$VpnAudience = '41b23e61-6c1e-4545-b367-cd054e0ed4b4'
# MSAL client app ID used internally by libLinuxCore.so (= cache key client)
$MsalClient  = 'c632b3df-fb67-4d84-bdcf-b95ad541b5c8'
$Scope       = "$VpnAudience/.default"
$Authority   = "https://login.microsoftonline.com/$TenantId"
$MarginSecs  = 60

try {

# ── Skip if existing cache is still valid ─────────────────────────────────────
function Test-CacheValid ([string]$Path) {
    if (-not (Test-Path $Path)) { return $false }
    try {
        $outer = Get-Content $Path -Raw | ConvertFrom-Json
        $b64   = $outer.PSObject.Properties | Select-Object -First 1 -ExpandProperty Value
        if (-not $b64) { return $false }
        $inner = [System.Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String($b64)) | ConvertFrom-Json
        $at    = $inner.AccessToken.PSObject.Properties | Select-Object -First 1 -ExpandProperty Value
        if (-not $at) { return $false }
        return [long]$at.expires_on -gt ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $MarginSecs)
    } catch { return $false }
}

if (-not $Force -and (Test-CacheValid $CachePath)) {
    Write-Host "  = WAM: cache still valid — skipping" -ForegroundColor DarkGray
    exit 0
}

# If the access token is expired but an MSAL sidecar exists, the refresh token is
# still present — AcquireTokenSilent (below) will refresh silently. No popup needed
# to decide here; we fall through so MSAL can attempt silent auth.
# If the sidecar is also absent, we need interactive auth.

# ── Locate MSAL + Broker DLLs in Az.Accounts ─────────────────────────────────
$azMod = Get-Module -ListAvailable -Name Az.Accounts |
    Sort-Object Version -Descending | Select-Object -First 1

if (-not $azMod) {
    Write-Host '  x WAM: Az.Accounts not found — install it or use device code flow.' -ForegroundColor Red
    exit 1
}

$azLib        = Join-Path (Split-Path $azMod.Path) 'lib'
$identityPath = Join-Path $azLib 'netstandard2.0\Microsoft.IdentityModel.Abstractions.dll'
$msalPath     = Join-Path $azLib 'netcoreapp2.1\Microsoft.Identity.Client.dll'
$nativePath   = Join-Path $azLib 'netstandard2.0\Microsoft.Identity.Client.NativeInterop.dll'
$brokerPath   = Join-Path $azLib 'netstandard2.0\Microsoft.Identity.Client.Broker.dll'

foreach ($dll in $identityPath, $msalPath, $nativePath, $brokerPath) {
    if (-not (Test-Path $dll)) {
        Write-Host "  x WAM: required DLL not found: $dll" -ForegroundColor Red
        exit 1
    }
}

# Add-Type puts assemblies in the standard load context so inter-assembly type
# resolution works without a custom AssemblyResolve handler.
Add-Type -Path $identityPath
Add-Type -Path $msalPath

try {
    # ── Build MSAL PublicClientApplication (interactive browser, no WAM broker) ──
    # WAM broker cannot be used: 41b23e61 has no ms-appx-web redirect URI registered,
    # and c632b3df has no API permission for 41b23e61 in the WAM flow.
    # Use VpnAudience (41b23e61) as client — same as device_code.py.
    $app = [Microsoft.Identity.Client.PublicClientApplicationBuilder]::Create($VpnAudience).WithAuthority($Authority).WithDefaultRedirectUri().Build()

    # ── Persist MSAL token cache to a sidecar file so silent refresh works ────
    # The sidecar keeps the native MSAL cache (with 41b23e61 keys) for silent auth.
    # The 2-level cache (written below) is what libLinuxCore.so reads.
    $msalSidecar = [System.IO.Path]::ChangeExtension($CachePath, '.msal.json')

    # C# helper: SetBeforeAccess/SetAfterAccess callbacks must run on .NET threads,
    # PowerShell scriptblocks cannot be used there (no runspace).
    if (-not ([System.Management.Automation.PSTypeName]'MsalFileCache').Type) {
        Add-Type -TypeDefinition @"
using System.IO;
using Microsoft.Identity.Client;
public class MsalFileCache {
    private readonly string _path;
    public MsalFileCache(string path) { _path = path; }
    public void Register(ITokenCache cache) {
        cache.SetBeforeAccess(BeforeAccess);
        cache.SetAfterAccess(AfterAccess);
    }
    private void BeforeAccess(TokenCacheNotificationArgs a) {
        if (File.Exists(_path)) a.TokenCache.DeserializeMsalV3(File.ReadAllBytes(_path));
    }
    private void AfterAccess(TokenCacheNotificationArgs a) {
        if (a.HasStateChanged) {
            Directory.CreateDirectory(Path.GetDirectoryName(_path));
            File.WriteAllBytes(_path, a.TokenCache.SerializeMsalV3());
        }
    }
}
"@ -ReferencedAssemblies $msalPath -CompilerOptions '/nowarn:1701,1702'
    }

    $cacheHelper = [MsalFileCache]::new($msalSidecar)
    $cacheHelper.Register($app.UserTokenCache)

    $scopes = [string[]]@($Scope)

    # ── Silent auth first (uses refresh token from sidecar), then interactive ──
    $accounts = @($app.GetAccountsAsync().GetAwaiter().GetResult())
    $result   = $null

    if ($accounts.Count -gt 0) {
        try {
            $result = $app.AcquireTokenSilent($scopes, $accounts[0]).ExecuteAsync().GetAwaiter().GetResult()
            Write-Host "  + WAM: silent auth succeeded ($($accounts[0].Username))" -ForegroundColor DarkGreen
        } catch {
            Write-Host "  ~ WAM: no cached session — starting interactive login..." -ForegroundColor Yellow
        }
    }

    if (-not $result) {
        $result = $app.AcquireTokenInteractive($scopes).ExecuteAsync().GetAwaiter().GetResult()
        Write-Host "  + WAM: interactive auth succeeded ($($result.Account.Username))" -ForegroundColor DarkGreen
    }

} finally { }

# ── Decode JWT payload for oid / exp / ext_exp ────────────────────────────────
$jwt     = $result.AccessToken
$parts   = $jwt -split '\.'
$padded  = $parts[1].Replace('-', '+').Replace('_', '/')
switch ($padded.Length % 4) { 2 { $padded += '==' }; 3 { $padded += '=' } }
$claims  = [System.Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String($padded)) | ConvertFrom-Json

$localOid = $claims.oid   # OID in resource tenant (= local_account_id)
$expOn    = [long]$claims.exp
$extExp   = if ($claims.PSObject.Properties['ext_exp']) { [long]$claims.ext_exp } else { $expOn + 86400 }

# ── Build cache identifiers ───────────────────────────────────────────────────
# HomeAccountId.Identifier is correct for B2B/guest users (oid.homeTenantId).
$homeId = $result.Account.HomeAccountId.Identifier
$realm  = $TenantId
$upn    = $result.Account.Username
$now    = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

$atKey  = "$homeId-login.microsoftonline.com-accesstoken-$MsalClient-$realm-$Scope"
$accKey = "$homeId-login.microsoftonline.com-$realm"

# ── Build 2-level MSAL cache JSON (matches device_code.py output format) ─────
$inner = @{
    AccessToken  = @{
        $atKey = @{
            home_account_id     = $homeId
            environment         = 'login.microsoftonline.com'
            client_id           = $MsalClient
            target              = $Scope
            realm               = $realm
            credential_type     = 'AccessToken'
            token_type          = 'Bearer'
            secret              = $jwt
            cached_at           = "$now"
            expires_on          = "$expOn"
            extended_expires_on = "$extExp"
        }
    }
    RefreshToken = @{}
    IdToken      = @{}
    Account      = @{
        $accKey = @{
            home_account_id  = $homeId
            environment      = 'login.microsoftonline.com'
            realm            = $realm
            local_account_id = $localOid
            authority_type   = 'MSSTS'
            username         = $upn
        }
    }
    AppMetadata  = @{
        "appmetadata-login.microsoftonline.com-$MsalClient" = @{
            client_id   = $MsalClient
            environment = 'login.microsoftonline.com'
        }
    }
} | ConvertTo-Json -Depth 6 -Compress

$b64   = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($inner))
$outer = @{ '' = $b64; $homeId = $b64 } | ConvertTo-Json -Depth 2 -Compress

# ── Write cache file ──────────────────────────────────────────────────────────
$dir = Split-Path -Parent $CachePath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
[System.IO.File]::WriteAllText($CachePath, $outer, [System.Text.UTF8Encoding]::new($false))

$expStr = [DateTimeOffset]::FromUnixTimeSeconds($expOn).LocalDateTime.ToString('HH:mm')
Write-Host "  + WAM: cache written (expires $expStr)" -ForegroundColor DarkGreen

} catch {
    Write-Host "  x WAM: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
