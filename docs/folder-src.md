# `src/` — production container

The clean, minimal container solution. Everything needed to build and run the
headless Azure VPN shim — nothing else.

## Files

| File | Purpose |
|------|---------|
| `Containerfile` | OCI build file: compiles vpnshim + certredirect, copies `libs/`, installs apt deps |
| `vpnshim.cpp` | Headless VPN shim: dlopen libLinuxCore.so, drive the connection flow |
| `certredirect.c` | LD_PRELOAD: redirect empty cert paths → `/dr.pem`; stub sd_bus calls |
| `entrypoint.sh` | Container ENTRYPOINT: start busybox syslogd, run `/vpnshim` |
| `runner.sh` | Runs as `/work/runner.sh` inside container: load token/profile env vars, DNS poller, call entrypoint |
| `conntest.sh` | Acceptance test: tun up, routes, DNS 53, TCP 3389/443, forwarding |
| `setup_and_run.sh` | WSL-side launcher: copy secrets to `~/vpnwork`, `docker run` |
| `dr.pem` | DigiCert Global Root G2 CA — public cert, committed, safe to share |
| `fetch-dr-pem.sh` | Regenerate `dr.pem` from DigiCert CDN with CN verification |
| `make_cache_available.sh` | Unlock gnome-keyring via WSLg GUI, extract MSAL cache to `msalcache.json` |
| `unlock_extract.py` | Python worker for `make_cache_available.sh` (needs `/usr/bin/python3`) |
| `inspect_cache.py` | Inspect MSAL cache / token.json validity without showing secrets |
| `libs/` | **gitignored** — filled by `fetch-libs.ps1`/`fetch-libs.sh` |

## `libs/` contents (gitignored)

Proprietary Microsoft binaries from the `microsoft-azurevpnclient` deb package.

| Library | Role |
|---------|------|
| `libLinuxCore.so` | Auth + VPN connection logic (Go, ~7.5 MB) |
| `libXplatSharedLibrary.so` | Custom OpenVPN stack + TLS (C++, ~3.4 MB) |
| `libmat.so` | Crypto / MSAL helpers (~1.7 MB) |

Fill with: `.\fetch-libs.ps1` (see [running-the-container.md](running-the-container.md)).

## Docker build context

The build context is `src/` — so `COPY libs/` in the Containerfile refers to `src/libs/`,
and all source files (`vpnshim.cpp` etc.) must be in `src/`.

```powershell
$ROOT = "/mnt/c/work/git/github/cveld/Experiments/2026-06 wsl container azure vpn"
wsl -d Ubuntu-20.04 -- bash -lc "cd '$ROOT' && docker build -f src/Containerfile -t azurevpn-shim:local src"
```

## Work mount (`/work`)

`setup_and_run.sh` bind-mounts `~/vpnwork` (WSL) → `/work` (container).
The mount contains secrets and runner scripts — not baked into the image.

| File in `/work` | Source |
|---|---|
| `msalcache.json` | `SECRETS_DIR/token-cache/msalcache.json` (from `.env`) |
| `profile.xml` | `SECRETS_DIR/vpn/azurevpnconfig.xml` |
| `dr.pem` | `src/dr.pem` |
| `runner.sh`, `conntest.sh`, `*.sh` | copied from `src/` by `setup_and_run.sh` |
