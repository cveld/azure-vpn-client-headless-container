# connect-vpn.ps1 — interactive profile picker

Reads all Azure VPN Client profiles from `rasphone.pbk`, shows an arrow-key menu, and starts a
per-profile container with the selected profile.

## Usage

```powershell
.\connect-vpn.ps1
```

Requirements: `.env` with `SECRETS_DIR`, Docker Desktop running with WSL Integration for `Ubuntu-20.04`.

## Per-profile isolation

Each profile gets its own isolated resources:

| Resource | Path |
|---|---|
| Container | `vpn-<safename>` (e.g. `vpn-igh-degoudse`) |
| Token cache | `SECRETS_DIR\token-cache\<SafeName>.json` |
| Profile XML | `SECRETS_DIR\vpn\<SafeName>.xml` |

`SafeName` = profile name with `\/:*?"<>|` replaced by `_`.  
`ContainerName` = `vpn-` prefix + name lowercased, non-alphanumeric replaced by `-`, consecutive `-` collapsed.

## Menu

```
  Azure VPN Connect
  ─────────────────────────────────────────────────────────────────
  > IGH-DeGoudse          wan.xxx.vpn.azure.com   Entra +*
    CorpVPN-Cert          azuregateway-xxx.xxx     Cert! -

  ↑↓ navigate   Enter connect   S stop   D clear cache   Q quit
```

Icons after each row:
- `+` = token cache file exists, `-` = no cache (device code required on connect)
- `*` = container is running, ` ` = not running

Keys:
- **Enter** — connect with selected profile
- **S** — stop the running container for the selected profile
- **D** — delete token cache for the selected profile (triggers device code on next connect)
- **Q / Esc** — quit

## Flow after selection

1. Write profile XML → `SECRETS_DIR\vpn\<SafeName>.xml`
2. Check token cache → run device code flow via `src/device_code.py` if missing or expired
3. Ensure Docker Desktop is running (auto-start if needed + 45s wait for WSL integration)
4. Build image `azurevpn-shim:local` if not present
5. Start container `vpn-<safename>` via `src/setup_and_run.sh <container> runner.sh <cache> <xml>`
6. Poll up to 120s for tunnel interface `ip link show <profileName>`; show last 6 log lines every 8s
7. Open interactive bash shell in container — VPN stays active after exit

## Token cache / device code

`src/device_code.py` manages token caches. On invocation it:

1. If cache exists: detect format
   - 2-level CacheAccessor format with valid token → exit 0 (no flow needed)
   - Python MSAL format with valid token → **convert in-place** to 2-level format → exit 0
   - Token expired or format unrecognised → run device code flow
2. If cache missing → run device code flow

Device code flow uses the VPN app's own `client_id` (`41b23e61`). After auth it writes the
2-level CacheAccessor format. See [docs/re/cache-format.md](re/cache-format.md) for format details.

`msal` Python package is auto-installed in WSL if absent.

## Docker Desktop detection

1. `Get-Process -Name 'Docker Desktop'` — if found, continue
2. If not found: launch `%ProgramFiles%\Docker\Docker\Docker Desktop.exe`
3. Wait up to 45s polling `docker info` in WSL (every 3s)
4. If still unavailable: print instructions for WSL Integration and exit 1

## Live logs during tunnel wait

While polling `ip link show <name>`, the last 6 container log lines are printed every 8 seconds.
This makes connection failures (cache errors, auth errors) immediately visible without running
`docker logs` manually.

## Auth-type detection

| Gateway pattern | Tag in menu |
|---|---|
| `wan.*` or `hub*.*` | `Entra` |
| `azuregateway-*` | `Cert!` (confirmation prompt on connect) |

## Menu column widths

Dynamic: `W = max(60, [Console]::WindowWidth - 1)` per redraw.  
`nameW = min(28, max(12, (W-14)*0.35))`, `gwW = max(16, W - 4 - nameW - 2 - 6 - 4)`.

## Gotchas

- Cert profiles are shown but the shim only supports Entra. A confirmation prompt appears on connect.
- The old shared cache `token-cache\msalcache.json` is **not** used. Each profile has its own file.
- Image is built automatically only if `azurevpn-shim:local` is absent. After changing `src/*.cpp` or `src/Containerfile`, rebuild manually: `wsl -d Ubuntu-20.04 -- bash -lc "cd '$ROOT' && docker build -f src/Containerfile -t azurevpn-shim:local src"`
- pbk binary format: see [docs/re/rasphone-pbk-format.md](re/rasphone-pbk-format.md)
