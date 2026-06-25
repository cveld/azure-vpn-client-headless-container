# Headless Azure VPN via libLinuxCore.so — working pipeline

Status June 2026: **control-plane fully working headless** — Microsoft's
proprietary OpenVPN stack establishes a CONNECTED tunnel without GUI/login. Only
remaining link: the data-path pump thread (tun ↔ socket forwarding).

## The complete working chain (control-plane)

1. **Silent auth, no login**
   - Real MSAL cache from gnome-keyring of the WSL client: item
     `microsoft-azurevpnclient.secureStorage`, key `AzureVpnClient_AzVPNClientMsalcache_`
     = `{"":"base64(single-map MSAL contract)"}`. Contains refresh token.
   - Extraction: `extract_cache.py` (python3 + secretstorage in WSL).
   - `connectAadProfile(profile, cacheJSON, UPN)` with UPN = `user@tenant.onmicrosoft.com`
     → `Found cached account` + `Acquired access token silently`.

2. **Tenant fix** (by admin, one-time) — makes c632b3df usable:
   ```
   az ad sp create --id c632b3df-fb67-4d84-bdcf-b95ad541b5c8
   az ad app permission grant --id c632b3df-... --api 41b23e61-... --scope user_impersonation
   ```

3. **Profile** via env `PROFILE_XML` = real azurevpnconfig.xml.

4. **Server cert validation** — `LD_PRELOAD=/certredirect.so` (`re/certredirect.c`):
   loadCerts builds path = prefix + authority-URL ("/dr.pemhttps://login..."); the
   interceptor redirects any path containing "://" or "login.microsoftonline.com" → `/dr.pem`
   (DigiCert Global Root G2). → `Certs loaded 1`, validation succeeds.

5. **DNS set** — sd_bus stubs in `certredirect.c`: the lib sets DNS after Connected via
   systemd-resolved over sd_bus; without dbus/resolved this fails (ENOENT) → teardown.
   Stubs (`sd_bus_open_system_with_description`, `sd_bus_call`, etc. → return 0)
   make the DNS step "successful".

→ Result: **`Connected`** + PUSH_REPLY (routes, ifconfig, DNS), tun device with all VPN routes.

## Remaining link: data-path pump

> **CORRECTION 2026-06-21 — read `docs/NEXT-SESSION.md` (⛔ section) for the current analysis.**
> The "0 reads on fd 19 / tx=0" mentioned below were MEASUREMENT ARTIFACTS: strace injects
> EINTR → worker teardown; and the WSL2 kernel keeps tun `/sys` counters at 0 while
> xmit actually works. The tun-fd IS in the worker epoll. Real bug: no thread pumps the tun
> (epoll 20/22 unmanned) → outbound forwarding (eth0 TX) stays 0. Text below is historical.

- After Connected no thread reads the tun-fd (strace: no read/epoll_wait on fd 19).
- `startDataPath()` (export @ 0xb1390) decompiled: `if (getStatus()!=6) return -1;
  else std::thread::_M_start_thread()`. The shim calls it, no disconnect anymore,
  but the pump loop does not run (possibly dual-tunnel-specific, or status-timing,
  or the primary pump needs a different trigger).
- CRITICAL resolved: `getConnectionStatus` disconnects the VPN if status==6 but tun
  not connected ("Tun is disconnected but OpenVPN is connected. Disconnecting").
  Therefore: startDataPath first, THEN poll status.
- Symptom: tun_tx=0, dropped=0 (packets queuing, no reader).

## Files (RE research directory)
- `vpnshim.cpp` — shim (cert-prefix patch + re-patch thread + startDataPath + poll order)
- `certredirect.c` — LD_PRELOAD: cert-redirect + sd_bus stubs
- `Dockerfile.shim` — builds /vpnshim + /certredirect.so
- `runner9.sh` / `runner_long.sh` — runner (cache + profile + UPN + LD_PRELOAD + dr.pem)
- `dr.pem` — DigiCert Global Root G2
- `msalcache.json` — real MSAL cache (from keyring)

## Data-path analysis (Ghidra)

- libLinuxCore: "Certs loaded"/"Failed to open file" (loadCerts). libXplatSharedLibrary:
  "cert verification callback"/"No cert verification" (TLS validation).
- libXplat data-path functions: `set_up_xpoll` @0x1e5ee0 ("Created Xpoll fds"),
  `start_worker`, `stop_worker`, `do_connect` — called by `connect`/`os_connect`
  (FdTransport). The Xpoll loop reads tun + data socket.
- `isTunConnected()` = `TunDevice::isTunActive() != 0`.
- `startDataPath()` (libLinuxCore @0xb1390): `if getStatus()!=6 return -1; else
  new(vtable PTR_LAB_005ab2f0) + std::thread::_M_start_thread()` → starts the data-path thread.
- **Clean strace (without re-patch thread)**: an epoll loop runs (3x
  epoll_pwait/4s, keepalive sendto), but **0 reads on tun-fd** → tun is not in
  the active epoll set; the data-path tun↔socket loop is not running.
- CRITICAL resolved: getConnectionStatus disconnects at status6+tun-not-active → startDataPath first, then poll.

### Precise remaining task
Activate the tun FdTransport worker so the tun enters the data-path Xpoll and the loop
reads the tun. Routes/IP/device are correct; packets queue to the tun (tx=0, dropped=0 =
no reader). startDataPath starts a thread but the tun read loop does not become effective.
Next steps (Ghidra):
1. Decompile the thread-run of `startDataPath` (vtable PTR_LAB_005ab2f0) → what does it do?
2. Decompile libXplat `connect`/`do_connect`/`start_worker` → when is the tun-fd added
   to the Xpoll, and which condition is missing headless?
3. Possibly call tun-FdTransport::connect directly, or set the missing condition.
