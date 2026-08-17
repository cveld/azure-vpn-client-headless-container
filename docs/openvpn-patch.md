# OpenVPN patch set for Azure Entra (AAD) P2S

A patched stock OpenVPN **2.6.14** can connect to an Azure VPN Gateway **Entra/AAD** P2S endpoint (`wan.*.vpn.azure.com`) and complete the session through `Initialization Sequence Completed`, including the full `PUSH_REPLY` (routes, DNS, tunnel IP).

This repository includes that OpenVPN-based path as an alternative to the existing `libLinuxCore.so` shim flow. It does not depend on the proprietary Microsoft Linux client binary; it uses a patched stock OpenVPN build instead.

## Scope

This document covers:

- the OpenVPN patch set and what each change does
- the runtime environment variables used by the patched client
- what changes were necessary versus merely helpful
- how to build and run the OpenVPN-based container path in this repo

## How the exact values were obtained

The Azure-specific values below were captured **byte-for-byte from the vendored Microsoft client on the wire**, by `LD_PRELOAD`-interposing OpenSSL `SSL_write` in the working shim container and dumping the plaintext `key-method-2` payload before encryption.

That capture was used as the authority for:

- the exact `peer-info` string
- the exact OCC/options string
- the required control-channel payload sizing

## Base and build

- **Upstream base:** OpenVPN tag `v2.6.14`
- **Patch:** `src-openvpn/openvpn-azure.patch`
- **Container build file:** `src-openvpn/Containerfile`

Build the image:

```powershell
docker build -f src-openvpn/Containerfile -t azurevpn-openvpn:local src-openvpn
```

To move to another OpenVPN version, rebuild with a different upstream tag, regenerate the patch, and re-verify the OCC and `peer-info` contents against the Microsoft client behavior.

## The changes, file by file

| File | Change | Gate | Why |
|------|--------|------|-----|
| `src/openvpn/misc.h` | `USER_PASS_LEN` 128 → 4096 | always | **The decisive fix.** The Entra access token is the OpenVPN password (~2.3 KB). The stock 128-byte cap silently truncates it to 127 chars, so the gateway receives an invalid token in `key-method-2` and resets. |
| `src/openvpn/common.h` | `TLS_CHANNEL_BUF_SIZE` 2048 → 8192 | always | The full `key-method-2` payload (`peer-info` + OCC + ~2.3 KB token) must fit in the control-channel cleartext buffer; stock 2048 overflows and causes `Key Method #2 write failed`. |
| `src/openvpn/ssl.c` | `push_peer_info()` emits the exact vendored `peer-info` and returns | `push_peer_info_detail>0` (true for pull clients) | Byte-exact, space-separated: `IV_VER=AzMac IV_PLAT=0.1 IV_PROTO=1 IV_PLAT_VER= IV_PLAT_DEVICE_ID=x64`. Note that the VER/PLAT values are the values the vendored client actually emits; the extra `IV_PLAT_VER=` and `IV_PLAT_DEVICE_ID=x64` fields matter. |
| `src/openvpn/options.c` | `options_string()` overrides the local (sent) OCC string verbatim | `OPENVPN_AZURE_OCC` | Byte-exact: `V4,dev-type tun,link-mtu 1500,tun-mtu 1551,proto TCPv4_CLIENT,keydir 1,cipher AES-256-GCM,auth [null-digest],keysize 256,tls-auth,key-method 2,tls-client`. `link-mtu 1500` and `tun-mtu 1551` are fixed values the vendored client reports that stock OpenVPN would not compute, so the whole string is replaced. The gateway resets on any OCC mismatch. |
| `src/openvpn/ssl_openssl.c` | Client TLS SNI + ALPN + `post_handshake_auth` + optional keylog | `OPENVPN_SNI`, `OPENVPN_ALPN`, `OPENVPN_PHA`, `OPENVPN_KEYLOG` | SNI is required for the multi-tenant front end. ALPN (`h2,http/1.1`) and PHA match the vendored ClientHello. Keylog writes NSS-format secrets for offline tshark decryption; diagnostic only, inert unless set. |

## Environment variables

All variables below are client-side runtime settings passed at `docker run` time.

| Var | Value used | Effect |
|-----|-----------|--------|
| `OPENVPN_SNI` | the gateway FQDN | sets TLS `server_name` |
| `OPENVPN_ALPN` | `h2,http/1.1` | ClientHello ALPN |
| `OPENVPN_PHA` | `1` | advertise `post_handshake_auth` |
| `OPENVPN_AZURE_OCC` | `1` | send the byte-exact OCC options string |
| `OPENVPN_KEYLOG` | *(unset in normal use)* | path for NSS TLS keylog output (debug) |

`USER_PASS_LEN`, `TLS_CHANNEL_BUF_SIZE`, and the custom `peer-info` string are compile-time changes and always enabled in the patched build. The remaining items are runtime toggles.

## What was necessary but not sufficient

Matching the ClientHello (SNI, ALPN, PHA, cipher ordering) did **not** change the gateway behavior on its own: the TLS handshake already completed successfully. The failure point was `key-method-2`, driven by the truncated token (`USER_PASS_LEN`) and, once that was addressed, by OCC and `peer-info` mismatches.

The ClientHello changes are still kept because they make the client behavior match the vendored implementation more closely, but the load-bearing fixes are:

- `USER_PASS_LEN`
- the exact OCC string
- the exact `peer-info` string

## Running the OpenVPN method

### What the launcher does

Use the OpenVPN launcher:

```powershell
.\connect-vpn-openvpn.ps1
```

This script is a sibling of the existing `connect-vpn.ps1` and reuses the same higher-level flow:

1. selects a VPN profile using the same `rasphone.pbk`-based profile picker
2. acquires an Entra token using the same token flow:
   - WAM when available
   - `src/device_code.py` device-code / refresh-token fallback otherwise

The OpenVPN launcher then performs the additional OpenVPN-specific steps:

1. extracts the profile's `<serversecret>` value and converts it into an OpenVPN static-key file
2. extracts the raw access token from the MSAL cache using `src-openvpn/extract_token.py`
3. renders `src-openvpn/openvpn.ovpn.template` with the gateway hostname
4. runs the `azurevpn-openvpn:local` container built from `src-openvpn/Containerfile`
5. waits for interface `tun0` to appear

Unlike the shim flow, the OpenVPN path always uses interface name `tun0`, so there is no profile-name truncation issue to account for.

### Config essentials

The rendered OpenVPN config is based on `src-openvpn/openvpn.ovpn.template` and includes the usual Azure P2S essentials:

- `proto tcp`
- `remote <gateway> 443`
- `tls-auth <serversecret> 1`
- `ca <gateway root>`
- `auth-user-pass`

Credentials are:

- username: `AzureAD`
- password: the Entra access token

The template does not use `route-nopull`, so the pushed routes and DNS settings are applied for a real tunnel.

### Manual build and run flow

Build the OpenVPN image:

```powershell
docker build -f src-openvpn/Containerfile -t azurevpn-openvpn:local src-openvpn
```

Then launch the connection:

```powershell
.\connect-vpn-openvpn.ps1
```

The launcher handles config rendering, token extraction, container startup, and waiting for `tun0` to come up.

## Notes

- This method is an alternative connection path in the repo, not a replacement for the existing shim-based method.
- The OpenVPN path depends on patched stock OpenVPN behavior matching Azure's expectations for `key-method-2`.
- The most important Azure-specific compatibility points are token length, control-channel buffer sizing, exact OCC, and exact `peer-info`.
