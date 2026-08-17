# CacheAccessor JSON – Full Format (Confirmed)

## Background

`connectAadProfile(profileName, cacheJSON, username)` expects `cacheJSON` in a 2-level format.
This format was confirmed through iterative tests (see exploration-index.md §4).

## Format (2 levels)

### Level 1: VPN_TOKEN (flat partition map)

```json
{
  "":          "<base64(msal_cache_json)>",
  "<homeAccountId>": "<base64(msal_cache_json)>"
}
```

- Type in Go: `map[string][]byte`
- Keys are PARTITION KEYS, NOT section names
- `""` → used by `AllAccounts()` → `base.go:438`
- `homeAccountId` → used by `AcquireTokenSilent()` with `ReplaceHints{PartitionKey: homeId}`
- Both keys MUST be present

### Level 2: Standard MSAL cache JSON (per partition)

The base64-decoded value for each partition is the standard MSAL cache format:

```json
{
  "AccessToken": {
    "<at_cache_key>": {
      "home_account_id":     "<user-oid>.<tenant-id>",
      "environment":         "login.microsoftonline.com",
      "client_id":           "c632b3df-fb67-4d84-bdcf-b95ad541b5c8",
      "target":              "41b23e61-6c1e-4545-b367-cd054e0ed4b4/.default",
      "realm":               "<tenant-id>",
      "credential_type":     "AccessToken",
      "secret":              "eyJ...",
      "cached_at":           "1234567890",
      "expires_on":          "1234571490",
      "extended_expires_on": "1234657890"
    }
  },
  "RefreshToken": {},
  "IdToken":      {},
  "Account": {
    "<account_cache_key>": {
      "home_account_id":    "<user-oid>.<tenant-id>",
      "environment":        "login.microsoftonline.com",
      "realm":              "<tenant-id>",
      "local_account_id":   "<user-oid>",
      "authority_type":     "MSSTS",
      "preferred_username": "user@example.com"
    }
  },
  "AppMetadata":  {}
}
```

### Cache key formats (lowercase!)

```
at_cache_key = "{homeId}-login.microsoftonline.com-accesstoken-{msalClientId}-{tenantId}-{scope}"
account_key  = "{homeId}-login.microsoftonline.com-{tenantId}"
```

Example:
```
at_cache_key = "<user-oid>.<tenant-id>-login.microsoftonline.com-accesstoken-c632b3df-fb67-4d84-bdcf-b95ad541b5c8-<tenant-id>-41b23e61-6c1e-4545-b367-cd054e0ed4b4/.default"
account_key  = "<user-oid>.<tenant-id>-login.microsoftonline.com-<tenant-id>"
```

## PowerShell build script

Core logic:

```powershell
function B64([string]$json) {
    [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
}

# Level 2: full MSAL cache JSON per partition
$msalCacheJson = @{
    AccessToken = @{
        $atCacheKey = @{
            home_account_id     = $homeId
            environment         = "login.microsoftonline.com"
            client_id           = $msalClient
            target              = "$vpnAppId/.default"
            realm               = $tenantId
            credential_type     = "AccessToken"
            secret              = $rawJwtToken
            cached_at           = "$cachedAt"
            expires_on          = "$expiresOn"
            extended_expires_on = "$extExpiresOn"
        }
    }
    RefreshToken = @{}
    IdToken      = @{}
    Account      = @{
        $accountKey = @{
            home_account_id    = $homeId
            environment        = "login.microsoftonline.com"
            realm              = $tenantId
            local_account_id   = $oid
            authority_type     = "MSSTS"
            preferred_username = $upn
        }
    }
    AppMetadata  = @{}
} | ConvertTo-Json -Depth 5 -Compress

$partitionB64 = B64 $msalCacheJson

# Level 1: flat partition map
$vpnToken = @{
    ""       = $partitionB64
    $homeId  = $partitionB64
} | ConvertTo-Json -Depth 2 -Compress
```

## Evidence per level

### Level 1: flat map confirmed
- `{"nested_obj": {}}` as map value → "cannot unmarshal object into []uint8"
  → map values must be base64 strings (Go `[]byte`)
- `{"": "base64"}` (1 key) → "No data for key" on homeId lookup
  → the flat map structure works! Only homeId key was missing
- `{"":"e30=","homeId":"e30="}` (with syslogd) → NO Replace error → confirmed!
- `{"AccessToken":{"":"..."}}` → "cannot unmarshal object into []uint8"
  → nested section names are NOT partition keys

### Level 2: standard MSAL format
- After Level 1 confirmation: the bytes per partition are passed to `cache.Unmarshal`
- `cache.Unmarshal` expects the standard MSAL cache contract (AccessToken map, Account map, etc.)

## Open discrepancy: `username` vs `preferred_username` (unresolved, 2026-07-05)

This doc's confirmed format above (and the PowerShell snippet) uses `preferred_username`
in the `Account` object. But `src/device_code.py`'s `build_two_level()` deliberately writes
`username` instead, with the comment: *"libLinuxCore.so gebruikt 'username' (niet
'preferred_username') als JSON-veld"* — i.e. a later finding claims the opposite of what
this doc documents. `wam-auth.ps1` also writes `username`, matching device_code.py, not
this doc.

Neither convention was confirmed to reliably work in a 2026-07-05 debugging session: caches
built by both `device_code.py` (fresh device-code and refresh-token paths) and `wam-auth.ps1`
consistently hit `"no account was specified with public.WithSilentAccount()"` inside
`connectAadProfile` (see `docs/troubleshooting.md`), while a real successful session's
captured cache was structurally different again. This was not root-caused — worth a focused
session to build one cache with each field name (all else identical) and compare outcomes
directly, ideally using a byte-for-byte diff against a cache pulled via
`make_cache_available.sh` from the native Windows client's own keyring (the one path known
to have produced a working connection).

## Cache builder: src/device_code.py

`src/device_code.py <tenant_id> <audience> <cache_path>` is the canonical tool for creating and
maintaining per-profile caches. It:

- **Validates** existing cache: 2-level format with unexpired token → exit 0 (no user action needed)
- **Migrates** Python MSAL format → 2-level format in-place (preserves the existing token)
- **Runs device code flow** when token is missing or expired

Always use this script rather than constructing the JSON by hand. It handles both partition keys
(`""` and `homeId`) and the correct `c632b3df` client_id in cache key strings.

## Known errors and causes

| Error | Cause | Fix |
|---|---|---|
| "cannot unmarshal string into main.CacheAccessor" | VPN_TOKEN is bare JWT string | Use JSON object format |
| "cannot unmarshal object into []uint8" | Map value is JSON object, not base64 string | Use `map[partKey][]byte` format |
| "No data exists for the key in accessor" | homeId partition key missing | Add both `""` and `homeId` as keys |
| SIGSEGV (nil logrus Logger) | syslogd not running → logrus does not initialize | Start busybox syslogd first |
| "xdg-open not found" | No browser → interactive auth fails | Supply valid cache with valid token |
