# rdp-connect.ps1 — combined VPN + VM discovery + RDP

Combined launcher: picks tenant/VPN profile, discovers Azure VMs, ensures VPN is up, opens RDP.

## Usage

```powershell
.\rdp-connect.ps1                          # fully interactive
.\rdp-connect.ps1 -Hostname vm.tenant.com  # skip VM discovery
.\rdp-connect.ps1 -Tenant contoso -Name myvm01
.\rdp-connect.ps1 -Tenant contoso -ResourceGroup rg-prod
.\rdp-connect.ps1 -ResourceId /subscriptions/.../virtualMachines/myvm
.\rdp-connect.ps1 -TenantTool az-context -Tenant fabrikam
.\rdp-connect.ps1 -Help
```

## Parameters

| Parameter | Alias | Default | Description |
|---|---|---|---|
| `-Tenant` | | `auto` | Friendly tenant name (matches `azTenant` in settings), `auto` = from VPN profile XML, `current` = skip switching |
| `-TenantTool` | | `''` | `''` = native az CLI, `az-context` = delegate to `c:\prg\az-context.ps1` |
| `-ResourceId` | | | Full Azure VM resource ID — skips VM menu |
| `-Subscription` | `-s` | | Filter `az vm list` by subscription |
| `-ResourceGroup` | `-g` | | Filter `az vm list` by resource group |
| `-Name` | `-n` | | Filter VMs by name (substring, VM name or computer name) |
| `-Hostname` | | | Internal FQDN — skips VM discovery, auto-matches tenant via `dnsSuffix` |
| `-LocalPort` | | auto | Local proxy port (auto-picks from 13389+) |
| `-RemotePort` | | 3389 | RDP port on target |
| `-Username` | | whoami /upn | Entra UPN pre-filled in credential dialog |
| `-NoEntraAuth` | | | Classic credential dialog instead of Entra WAM |
| `-KeepHostsEntry` | | | Keep the `127.0.0.1 <device>` hosts entry after mstsc closes (overrides `keepHostsEntry` in settings for this run) |
| `-CleanHosts` | | | Remove all `# rdp-vpn-ps-*` entries from the hosts file and exit (UAC prompt if not admin) |
| `-Help` | | | Show full help |

## Flow

```
-Hostname given?
  → match dnsSuffix in settings → auto-select VPN profile
  → deviceName = $Hostname.Split('.')[0]
  → skip to VPN check

No -Hostname:
  → TUI: two-column menu (Tenant | VPN Profile)
       E = edit azTenant inline → saved to rdp-connect-settings.json
       T = toggle az tool (native CLI ↔ az-context.ps1)
  → Switch-AzTenant → verify with az account show
  → Resource Graph VM query (cross-subscription, see below)
  → VM menu: Name / RG / Subscription / OS   (cache-first, R to reload)
  → deviceName = osProfile.computerName
  → dnsSuffix missing? → Resource Graph private DNS zone picker → saved to settings
  → FQDN = deviceName + "." + dnsSuffix, fallback: IP (fetched lazily from NIC)

VPN check → Start-VpnContainer
  → container already running? skip
  → else: call connect-vpn.ps1 -VpnProfile <name>

DNS preflight (skipped when target is a bare IP) → socat proxy → mstsc → cleanup
  → finally: remove hosts entry (unless keepHostsEntry=true) → stop socat → delete .rdp file
```

## Hosts file lifecycle

Each session adds `127.0.0.1 <device>  # rdp-vpn-ps-<device>` before launching mstsc and removes it in the `finally` block after mstsc closes.

**keepHostsEntry** (`false` by default):
- `false` — entry removed automatically (UAC prompt if non-admin)
- `true` — entry kept; cleanup message shows `-CleanHosts` hint

**Stale entry notice**: at startup the script scans the hosts file for any `# rdp-vpn-ps-*` lines (left from a crashed session or prior `keepHostsEntry=true` run) and prints a warning with the count.

**`-CleanHosts`**: removes all `# rdp-vpn-ps-*` entries and exits. Triggers UAC if not admin.

```powershell
.\rdp-connect.ps1 -CleanHosts        # remove all managed entries, then exit
.\rdp-connect.ps1 -KeepHostsEntry    # keep entry for this run only
```

## az-context tenant switch

`Switch-AzTenant` (used when `-TenantTool az-context`):

1. Calls `az-context.ps1 -tenant <name>` — sets `$env:AZURE_CONFIG_DIR`, no native command.
2. Calls `az account show` to verify the tenant matches.
3. Mismatch → "token expired" → calls `az-context.ps1 -tenant <name> -login` → re-verifies.

**Gotcha**: do NOT check `$LASTEXITCODE` after a pure PS script call. `$LASTEXITCODE` is only
updated by native executables. A PS script that does no native calls leaves `$LASTEXITCODE`
stale — and `$null -ne 0` is `$true` in PowerShell. Use `az account show` as the real gate.

## Resource Graph VM query

Replaces `az vm list` (subscription-scoped) with `az graph query` (tenant-wide).

Requires the `resource-graph` extension — auto-installed with `--yes` on first run.

**KQL multiline gotcha**: `az graph query -q` ignores newlines in the query string — only the first
line (`Resources`) is used as the query, returning ALL resource types unfiltered.
**Fix**: collapse the here-string to a single line before passing it to `az`:
```powershell
$kql = $kql -replace '\r?\n\s*', ' '
$graphArgs = @('graph', 'query', '-q', $kql, ...)
```

**KQL** (no NIC join — NIC join with nullable `nicId` causes cross-product explosion):
```kusto
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| project name, computerName=..., osType=..., rg=resourceGroup, subscriptionId,
  nicId=tolower(tostring(properties.networkProfile.networkInterfaces[0].id))
| join kind=leftouter (
    ResourceContainers | where type == 'microsoft.resources/subscriptions'
    | project subscriptionId, subscriptionName=name
) on subscriptionId
| project name, computerName, osType, rg, subscriptionId, subscriptionName, nicId
```

IP is **not** in the VM query. It is resolved on-demand via a second graph query on `nicId`
after VM selection — only when `dnsSuffix` is not configured and the IP is needed as fallback.

Result format: `{ "count": N, "data": [...] }` → extract with `($json | ConvertFrom-Json).data`.

## VM cache + background refresh

Cache stored at `.cache/vms-<tenantId>.json`:
```json
{ "timestamp": "2026-06-29T...", "vms": [...] }
```

Flow:
- Cache exists → show immediately with `[cached Xm ago]`, start background refresh.
- No cache → blocking query, then save to cache.
- Menu footer: `[refreshing...]` → `[R] reload (N VMs)` when done.
- Press R → cache overwritten with fresh data, menu redraws.

**ConstrainedLanguage workaround**: WDAC/AppLocker forces `.ps1` scripts outside trusted paths
to run in `ConstrainedLanguage` mode. `Start-Job` is blocked in this mode. Solution:
`Start-Process pwsh -WindowStyle Hidden -PassThru` + two temp files (args JSON + output JSON).
Child process inherits `$env:AZURE_CONFIG_DIR` automatically. Temp paths use `Get-Random`
instead of `[IO.Path]::GetTempFileName()` — `[IO.Path]` is not whitelisted in ConstrainedLanguage.

```powershell
$rnd       = Get-Random
$tmpArgs   = "$env:TEMP\rdp-vmq-args-$rnd.json"
$tmpOut    = "$env:TEMP\rdp-vmq-out-$rnd.json"
$tmpScript = "$env:TEMP\rdp-vmq-$rnd.ps1"
```

## Settings file: rdp-connect-settings.json

Located next to `rdp-connect.ps1` in the project root. Gitignored — not committed; real values (tenant names, DNS suffixes, UPNs) live there. Editable via the TUI (E key) or directly.

```json
{
  "tenantTool": "az-context",
  "profiles": {
    "<Profile Name>": {
      "azTenant": "<az-context-tenant-name>",
      "dnsSuffix": "<corp.example.com>",
      "rdpUsername": "<upn@tenant.onmicrosoft.com>"
    }
  }
  // Real values live in rdp-connect-settings.json (gitignored / OneDrive)
}
```

| Field | Description |
|---|---|
| `tenantTool` | `''` = native az CLI, `az-context` = delegate to `c:\prg\az-context.ps1`. Toggled with `T` in the profile picker. |
| `azTenant` | Friendly name passed to `az-context.ps1 -tenant` or used for display. Editable in TUI. |
| `dnsSuffix` | DNS suffix to construct FQDN: `computerName + "." + dnsSuffix`. Used for `-Hostname` auto-match and VM-resource path. |
| `rdpUsername` | Per-tenant Entra UPN for `username:s:` in the RDP file. Auto-populated on first successful tenant switch via `az ad signed-in-user show`. Falls back to `whoami /upn` when absent. |

### Auto-population of rdpUsername

After each successful `Switch-AzTenant`, the script runs:
```powershell
az ad signed-in-user show --query userPrincipalName -o tsv
```
and saves the result as `rdpUsername` for that profile. Runs once per profile (skips if already set and unchanged). This ensures the correct per-tenant B2B guest UPN is used in the RDP file — important because each tenant can assign a different guest UPN to the same home-tenant user.

**Why this matters**: With `enablerdsaadauth:i:1`, mstsc uses WAM to obtain an Entra access token. WAM uses the `username:s:` hint to select the right account. If the hint is the user's home-tenant UPN but the VM is in a different tenant and has no B2B relationship with that account, WAM returns an invalid token → `SEC_E_INVALID_TOKEN`.

## Device name vs hostname

| Source | Device name (Entra) | Hostname (socat/DNS) |
|---|---|---|
| `-Hostname` given | `$Hostname.Split('.')[0]` | `$Hostname` as-is |
| VM via az vm list/show | `osProfile.computerName` | `computerName + "." + dnsSuffix` |

The device name goes into the `.rdp` file's `full address` and the `hosts` entry for Entra WAM auth.

## Profile picker keys

| Key | Action |
|-----|--------|
| ↑ ↓ | Navigate |
| Enter | Select profile → proceed |
| E | Edit `azTenant` inline for the selected profile (saved immediately) |
| T | Toggle tenant tool: **native az CLI** ↔ **az-context.ps1** (saved immediately) |
| K | Toggle **keep-hosts**: `[on]` = keep `127.0.0.1 <device>` in hosts after mstsc closes; `[off]` = remove it (default). Saved immediately to `rdp-connect-settings.json`. |
| Esc / Q | Quit |

## VM menu keys

| Key | Action |
|-----|--------|
| ↑ ↓ | Navigate |
| Enter | Select VM → proceed to VPN + RDP |
| I | Info overlay: extensions + RBAC assignments for selected VM |
| H | Toggle hostname mode for selected VM: **FQDN** ↔ **device** (short computerName). Saved to `rdp-connect-settings.json` under `vms.<vmName>.connectAs`. |
| R | Reload from background refresh (appears when refresh is ready) |
| Esc / ← | Go **back** to the profile/tenant picker |
| Q | Quit |

**I — VM info overlay** (`Show-VmInfo`):
- Extensions: `az vm extension list --subscription` → name, type, provisioningState (green/red/yellow)
- RBAC: `az role assignment list --assignee <me> --scope <vm-resource-id> --include-inherited --include-groups`
  - Shows role + shortened scope (from `/resourceGroups/` onward)
  - Fails gracefully if user lacks `Microsoft.Authorization/roleAssignments/read`

## TUI behaviour notes

- `docker ps` is called **once before the render loop**, not on every keypress — avoids ~400 ms latency per keystroke.
- Running containers are shown in White; selected row in Green.
- Editing azTenant (E) saves immediately to `rdp-connect-settings.json` via `Save-ProfileSettings`.
- T toggle (tenant tool) and K toggle (keep-hosts) both persist to `rdp-connect-settings.json` immediately.
- VM menu columns: **Name / Resource Group / Subscription / OS**. Background refresh shown in footer.
- DNS suffix picker (when not configured): arrow-key menu of Resource Graph private DNS zones + manual entry + IP fallback. Chosen suffix saved automatically to `rdp-connect-settings.json`.
- DNS preflight (`nslookup` via VPN container) is **skipped** when target is a bare IP — forward DNS on an IP makes no sense.

**Column width formula** — ensures the row never exceeds terminal width:
```powershell
$var = $W - 17   # 17 = 4 (prefix "  > ") + 3×2 (separators) + 7 (OS "Windows")
$nW  = [Math]::Min(36, [int]($var * 0.44))
$rW  = [Math]::Min(28, [int]($var * 0.33))
$sW  = [Math]::Max(8,  $var - $nW - $rW)   # remainder — guaranteed to fit
```
`[Math]::Max(80, ...)` as minimum was removed: it forced column widths beyond the actual terminal, causing the last column to wrap mid-word.

**Key input — non-blocking with auto-refresh** (`PowerShell.Create()` pattern):
```
Task.Run + PS script block → FAILS: threadpool threads have no runspace
Fix: PowerShell.Create() + BeginInvoke() + AsyncWaitHandle.WaitOne(ms)
```
```powershell
$kPs = [System.Management.Automation.PowerShell]::Create()
$kPs.AddScript('[Console]::ReadKey($true)') | Out-Null
$keyTask = @{ Ps = $kPs; Ar = $kPs.BeginInvoke() }
# ...
$keyTask.Ar.AsyncWaitHandle.WaitOne($waitMs) | Out-Null  # -1 = infinite
```
- `WaitOne(ms)` returns early on keypress (zero spin), times out after `ms` ms
- One PS instance reused across iterations — never two threads on `ReadKey`
- `$waitMs = 300` only when a background refresh is pending; `-1` otherwise
- `$needsRedraw` flag: menu only redraws when selection changes or refresh status changes

## .rdp file signing

`rdp-connect.ps1` automatically signs the generated `.rdp` file to suppress the mstsc
"Unknown publisher" security warning. Signing runs after the `.rdp` file is written,
before `mstsc` is launched.

Functions involved: `Get-OrCreate-RdpSigningCert` + `Invoke-SignRdpFile`.

On first use a self-signed cert (`CN=rdp-connect publisher`, 10 years) is created and placed in
`CurrentUser\My`, `CurrentUser\Root`, and `CurrentUser\TrustedPublisher`. Windows may show a
one-time dialog to confirm the Root store addition.

**Test / debug**: `test-rdp-signing.ps1 -Inspect -OpenMstsc` — creates a minimal `.rdp`, signs it,
and opens it with mstsc so you can verify the warning is gone without going through the full VPN flow.

See [troubleshooting.md](troubleshooting.md) → *mstsc: "Caution: Unknown remote connection"* for
format details, cert recreation steps, and why `rdpsign.exe` is not used.

## query-vms.ps1 — standalone debug script

`query-vms.ps1` runs the same Resource Graph query in isolation, dumping raw JSON + parsed table.
Use it to verify tenant context and query results without going through the full rdp-connect flow.

```powershell
.\query-vms.ps1                        # all VMs in current az context
.\query-vms.ps1 -ResourceGroup rg-prod
.\query-vms.ps1 -Name myvm
.\query-vms.ps1 -Subscription "Sub Name"
```

Prints: KQL (raw + collapsed), az args, exit code, parsed VM count, table, raw JSON.
