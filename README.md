# azure-vpn-client-headless-container

Headless Azure VPN Point-to-Site client running in a Docker container inside WSL. Supports multiple VPN profiles, each with isolated token cache and container instance.

Uses the proprietary `libLinuxCore.so` from the official [Azure VPN Client for Linux](https://learn.microsoft.com/en-us/azure/vpn-gateway/point-to-site-entra-vpn-client-linux) combined with a custom C++ shim to drive it without a GUI.

## How it works

The Azure VPN Client for Linux is a GUI app — it does not expose a headless mode. This project reverse-engineered its internal API (`libLinuxCore.so`) and provides:

- **`vpnshim.cpp`** — calls `initConnection` → `initAAD` → `connectAadProfile` directly via `dlopen`
- **`certredirect.c`** — LD_PRELOAD interceptor that redirects broken cert paths and stubs out D-Bus calls the library makes but doesn't need in a container
- **`device_code.py`** — acquires and caches MSAL tokens using the device code flow (the library's own hardcoded client ID)

The container runs in WSL (`Ubuntu-20.04`) with `NET_ADMIN` / `NET_RAW` / `SYS_PTRACE` capabilities and a `/dev/net/tun` device. It establishes a TUN interface, sets routes via netlink, and configures sDNS from the OpenVPN `PUSH_REPLY`.

## Prerequisites

- Windows 11 with WSL2 (`Ubuntu-20.04` distro)
- Docker Desktop with WSL2 backend
- **Azure VPN Client for Windows** installed and at least one Entra ID (AAD) P2S profile configured in it — `connect-vpn.ps1` reads profiles directly from the app's `rasphone.pbk` store

## Setup

```powershell
.\connect-vpn.ps1
```

That's it. On first run `connect-vpn.ps1` guides you through everything interactively:

1. **`.env` setup** — prompts for `SECRETS_DIR` (where token caches are stored) and optionally `LIBS_SOURCE`, then writes `.env` for future runs.
2. **Proprietary libraries** — if `src/libs/` is missing, offers to run `fetch-libs.ps1` which downloads `libLinuxCore.so`, `libXplatSharedLibrary.so`, and `libmat.so` from the Microsoft apt repository. Set `LIBS_SOURCE` in `.env` to copy from an existing local directory instead.
3. **Profile selection** — reads VPN profiles directly from the **Azure VPN Client for Windows** app's `rasphone.pbk` store (`%LOCALAPPDATA%\Packages\Microsoft.AzureVpn_8wekyb3d8bbwe\LocalState\rasphone.pbk`) and presents an arrow-key menu. You do not need to export or copy profile XML files manually — the selected profile's XML is extracted and staged automatically.
4. **Token acquisition** — runs a device code flow on first use; subsequent runs use the cached refresh token.
5. **Container build & connect** — builds the Docker image if not yet present, starts the container, and waits for the TUN interface to come up.

## Repository layout

```
connect-vpn.ps1         # Interactive launcher with profile picker
run.ps1                 # Simple fixed-name launcher (single profile)
fetch-libs.ps1          # One-time setup: downloads libLinuxCore.so etc.
fetch-libs.sh           # WSL-side helper for fetch-libs.ps1
.env.example            # Config template

src/
├── Containerfile       # Active container image (compiles shim + certredirect)
├── vpnshim.cpp         # Core: dlopen libLinuxCore.so, drive the VPN connection
├── certredirect.c      # LD_PRELOAD: fix cert paths, stub sd_bus
├── entrypoint.sh       # Container ENTRYPOINT: start syslogd, run vpnshim
├── runner.sh           # Runs inside container: load token, set LD_PRELOAD, call entrypoint
├── setup_and_run.sh    # WSL-side: stage secrets, docker run
├── device_code.py      # MSAL token manager (device code flow + refresh)
├── inspect_cache.py    # Check token cache validity without printing secrets
├── make_cache_available.sh  # Extract MSAL cache from gnome-keyring (if needed)
├── conntest.sh         # Acceptance test: TUN interface, routes, DNS, TCP
├── dr.pem              # DigiCert Global Root G2 (public; the TLS CA for Azure gateways)
├── fetch-dr-pem.sh     # Regenerates dr.pem
└── libs/               # gitignored — filled by fetch-libs.ps1

docs/                   # Architecture, troubleshooting, profile details, RE notes
```

## `.env` variables

| Variable | Required | Description |
|---|---|---|
| `SECRETS_DIR` | Yes | Windows path to folder where token caches are stored (populated automatically) |
| `LIBS_SOURCE` | No | Windows path to a folder with pre-existing `.so` files; skips apt download |
| `DEB_VERSION` | No | apt version pin for the Azure VPN Client deb (default: `3.0.0`) |

## How the auth flow works

```
connect-vpn.ps1
  ├─ device_code.py  (acquire/refresh MSAL token if needed)
  ├─ docker build -f src/Containerfile -t azurevpn-shim:local src
  └─ wsl -- src/setup_and_run.sh vpn-<profile> runner.sh <cache.json> <profile.xml>
       └─ docker run azurevpn-shim:local
            └─ runner.sh
                 ├─ LD_PRELOAD=/certredirect.so
                 ├─ DNS poller (reads PUSH_REPLY from syslog, writes resolv.conf)
                 └─ entrypoint.sh
                      ├─ busybox syslogd  (required — library crashes without it)
                      └─ vpnshim
                           └─ dlopen libLinuxCore.so
                           └─ initConnection → initAAD → connectAadProfile
                           └─ library sets TUN + routes via netlink
```

Token audience: `41b23e61-6c1e-4545-b367-cd054e0ed4b4` (Azure VPN Client app ID).
The library uses its own hardcoded MSAL client ID (`c632b3df-…`); `az` CLI tokens do not work.

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md).

## Documentation

- [Architecture & auth flow](docs/architecture.md)
- [connect-vpn.ps1 — profile picker](docs/connect-vpn.md)
- [Building & running the container](docs/running-the-container.md)
- [src/ folder contents](docs/folder-src.md)
- [libLinuxCore.so interface](docs/lib-interface.md)
- [VPN profile format](docs/vpn-profile.md)
- [Verification & acceptance criteria](docs/vpn-verification.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Reverse engineering notes](docs/re/)

## License

Scripts and shim code in this repository are MIT licensed.
`libLinuxCore.so`, `libXplatSharedLibrary.so`, and `libmat.so` are proprietary Microsoft binaries — they are not included and must be obtained via the official Microsoft apt repository.
