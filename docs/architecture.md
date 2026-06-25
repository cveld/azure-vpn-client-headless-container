# Architecture & auth flow

## Components

| File | Role |
|------|------|
| `connect-vpn.ps1` | **Interactive launcher**: arrow-key menu over all installed profiles, per-profile container/cache/XML isolation, Docker Desktop detection, device code flow, live logs during tunnel wait |
| `fetch-libs.ps1` / `fetch-libs.sh` | One-time setup: downloads Microsoft libs into `src/libs/` (apt, local .deb, or existing dir via `LIBS_SOURCE`) |
| `src/Containerfile` | Container image: compiles vpnshim + certredirect, copies `src/libs/`, installs runtime deps |
| `src/setup_and_run.sh` | WSL-side: copies secrets + scripts to `~/vpnwork`, does `docker run` |
| `src/device_code.py` | Token cache manager: detects 2-level vs Python MSAL format, converts in-place, runs device code flow if needed; writes canonical 2-level CacheAccessor JSON |
| `src/runner.sh` | Runs inside container as `/work/runner.sh`: loads token/profile, starts DNS-watcher subshell, then exports LD_PRELOAD (after the subshell — otherwise spam), calls entrypoint |
| `src/entrypoint.sh` | Container ENTRYPOINT: starts busybox syslogd + runs `/vpnshim` |
| `src/vpnshim.cpp` | Headless shim: dlopen libLinuxCore.so, calls initConnection/initAAD/connectAadProfile, manual pump thread |
| `src/certredirect.c` | LD_PRELOAD interceptor: redirects empty/malformed cert paths → `/dr.pem`; stubs sd_bus (DNS) |
| `src/dr.pem` | DigiCert Global Root G2 — public CA cert, safe to commit; regenerate with `src/fetch-dr-pem.sh` |
| `src/make_cache_available.sh` | Token refresh step 1: unlock gnome-keyring via WSLg GUI, extract MSAL cache to msalcache.json |
| `src/inspect_cache.py` | Token refresh step 0: inspect MSAL cache validity without exposing secrets |
| `.env` / `.env.example` | Machine-local config (gitignored): `SECRETS_DIR`, `LIBS_SOURCE` |
| `run-openvpn.ps1` | **ARCHIVE** — stock OpenVPN flow; does not work with Entra ID (peer-info mismatch) |

## Per-profile container naming (connect-vpn.ps1)

Each profile selected via `connect-vpn.ps1` gets its own resources:

| Resource | Derivation |
|---|---|
| Container name | `vpn-` + profile name lowercased, non-alphanumeric → `-`, consecutive `-` collapsed |
| Token cache | `SECRETS_DIR\token-cache\<SafeName>.json` (`SafeName` = name with `\/:*?"<>|` → `_`) |
| Profile XML | `SECRETS_DIR\vpn\<SafeName>.xml` |

Example: profile `MyProfile` → container `vpn-my-profile`, cache `MyProfile.json`, xml `MyProfile.xml`.

## setup_and_run.sh parameters

```bash
src/setup_and_run.sh <container-name> <runner-script> [cache-wsl-path] [xml-wsl-path]
```

- arg 1: container name (e.g. `vpn-my-profile`)
- arg 2: runner script name (e.g. `runner.sh`)
- arg 3: WSL path to per-profile token cache — falls back to `$SECRETS/token-cache/msalcache.json`
- arg 4: WSL path to per-profile XML — falls back to `$SECRETS/vpn/azurevpnconfig.xml`

## Auth flow (working shim flow)

```
connect-vpn.ps1
  └─ src/device_code.py <tenant> <audience> <cache-path>  (if cache missing/expired)
  └─ docker build -f src/Containerfile -t azurevpn-shim:local src  (if image missing)
  └─ wsl -d Ubuntu-20.04 -- src/setup_and_run.sh vpn-<name> runner.sh <cache> <xml>
       └─ docker run azurevpn-shim:local  (bind-mount ~/vpnwork → /work)
            └─ /work/runner.sh
                 ├─ VPN_TOKEN = cat /work/msalcache.json   (MSAL-cache JSON, incl. refresh_token)
                 ├─ LD_PRELOAD=/certredirect.so            (cert-redirect + sd_bus stubs)
                 ├─ DNS poller: sets resolv.conf once tun interface is up (from PUSH_REPLY syslog)
                 └─ /entrypoint.sh
                      └─ busybox syslogd (required: nil logrus logger without it → SIGSEGV)
                      └─ /vpnshim
                           └─ dlopen libLinuxCore.so
                           └─ initConnection → initAAD → setXmlProfileData → connectAadProfile
                           └─ library sets routes via netlink (no manual ip route needed)
                           └─ rawStatus==6 → pump thread (FUN_001b0ec0 @ base+0xb0ec0)
```

## Folder layout

```
src/                    ← production container (clean, committed)
├── Containerfile
├── vpnshim.cpp
├── certredirect.c
├── entrypoint.sh
├── runner.sh
├── setup_and_run.sh
├── dr.pem              ← public DigiCert G2 cert, committed
├── fetch-dr-pem.sh     ← regenerates dr.pem from DigiCert CDN
├── make_cache_available.sh
├── unlock_extract.py
├── inspect_cache.py
└── libs/               ← gitignored; filled by fetch-libs.sh
    ├── libLinuxCore.so
    ├── libXplatSharedLibrary.so
    └── libmat.so

re/                     ← reverse engineering research (keep, do not clean up)
fetch-libs.ps1          ← one-time setup: fills src/libs/
connect-vpn.ps1         ← primary entry point (interactive, multi-profile)
.env                    ← gitignored; SECRETS_DIR, LIBS_SOURCE
.env.example            ← committed template
```

## .env configuration

| Variable | Required | Description |
|---|---|---|
| `SECRETS_DIR` | Yes | Windows path to secrets folder (msalcache.json, azurevpnconfig.xml) |
| `LIBS_SOURCE` | No | Windows path to folder with pre-existing .so files; skips apt download |
| `DEB_VERSION` | No | apt version pin (default 3.0.0); ignored when `LIBS_SOURCE` set |

WSL scripts auto-convert Windows paths (`C:\foo`) to `/mnt/c/foo`.

## Container run flags required

```
--cap-add=NET_ADMIN          # manage TUN interface
--cap-add=NET_RAW            # raw sockets
--cap-add=SYS_PTRACE         # required by vpnshim diagnostics
--device=/dev/net/tun        # TUN device
--sysctl net.ipv4.ip_forward=1
```

## VPN credentials

`connectAadProfile(profileName, cacheJSON, username)` — 3 args:
- arg 1: profile name (from `<name>` in the Azure VPN profile XML)
- arg 2: MSAL cache JSON (the full `msalcache.json` blob, not a raw access token)
- arg 3: AAD username / UPN for silent token acquire (e.g. `user@tenant.onmicrosoft.com`)

## Key IDs

| ID | Value |
|---|---|
| VPN app / resource | `41b23e61-6c1e-4545-b367-cd054e0ed4b4` |
| Internal MSAL client (library hardcoded) | `c632b3df-fb67-4d84-bdcf-b95ad541b5c8` |
| Tenant | your Azure AD tenant ID (from the VPN profile XML) |
| Gateway | your VPN gateway FQDN (from the VPN profile XML) |

## dr.pem

DigiCert Global Root G2 — the CA that signs the Azure VPN gateway's TLS certificate.
`certredirect.c` intercepts `open()`/`fopen()` calls with empty or malformed paths (which
`loadCerts()` produces for AAD connections) and redirects them to `/dr.pem`.
Not a secret — freely available from DigiCert. Regenerate: `bash src/fetch-dr-pem.sh`.

## Auth flow (archived OpenVPN flow — not functional with Entra ID)

```
run-openvpn.ps1
  └─ WAM token (WinRT, silent) or device code flow
  └─ docker --context desktop-linux run Containerfile-image
       └─ entrypoint.sh (root-level, not src/)
            └─ openvpn --daemon + wait for tun0 + exec bash
```

Does not work: `wan.*` Entra gateway rejects stock OpenVPN due to peer-info mismatch
(`IV_PLAT=AzMac` required). See `docs/troubleshooting.md`.
