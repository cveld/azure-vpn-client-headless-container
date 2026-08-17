# Linux Azure VPN Client — Binary Analysis

Package: `microsoft-azurevpnclient_3.0.0_amd64.deb` (12.5 MB, date: 2023-03-14)

## Structure

The package installs to `/opt/microsoft/microsoft-azurevpnclient/`.

```
microsoft-azurevpnclient      # ELF executable, 19 KB (bootstrapper only)
lib/
  libLinuxCore.so             # 7.5 MB  — auth + VPN connection logic (Go)
  libXplatSharedLibrary.so    # 3.4 MB  — OpenVPN protocol + TLS (C++)
  libapp.so                   # 5.8 MB  — Flutter/Dart UI logic
  libflutter_linux_gtk.so     # 14 MB   — Flutter engine (open source)
  libmat.so                   # 1.7 MB  — crypto/MSAL helper functions
  libflutter_secure_storage_linux_plugin.so
  libflutter_window_close_plugin.so
  liburl_launcher_linux_plugin.so
data/flutter_assets/          # fonts, assets, version info
```

All binaries are **stripped** (no debug symbols).

## libLinuxCore.so — Go binary

`file` output: `ELF 64-bit LSB shared object, x86-64, dynamically linked, stripped`

Notable: this is compiled **Go code**. Go stores reflection metadata in the binary, so
full struct definitions are readable without decompilation.

### Dependency: MSAL for Go (open source)

```
github.com/AzureAD/microsoft-authentication-library-for-go/...
```

Visible types and packages:
- `accesstokens.TokenResponse`, `accesstokens.RefreshToken`, `accesstokens.IDToken`
- `authority.AuthParams`, `authority.Endpoints`, `authority.UserRealm`
- `accesstokens.DeviceCodeResult` — confirms device code flow
- `oauth.cacheEntry` — token caching

Auth-type enum (visible in strings):
```
ATDeviceCode  ATRefreshToken  ATClientCredentials  ATInteractive
ATAuthCode    ATUsername Password  ATWindowsIntegrated
```

### Exported C++ symbols (de-mangled)

The `ConnectionManager` class (written in C++, driven from Go):

| Method | Meaning |
|---|---|
| `connectVpnProfile()` | Start VPN connection |
| `connectOpenVPN()` | Open OpenVPN datapath |
| `connectAadProfile(char*, char*)` | Connect AAD profile (username + token) |
| `acquireAadToken()` | Acquire AAD token via MSAL |
| `getNewAadToken()` | Refresh token — see static-analysis note below |
| `disconnectVpnProfile()` | Disconnect |
| `setXmlProfileDataName(string)` | Load VPN profile from XML |
| `getMSALCache()` / `setCertCreds()` | Cache + certificate management |
| `getDualTunnelStatus()` | HA dual-tunnel status |

`TunDevice` class:
- `createIoctlSocket()`, `setTunRoutes()`, `setTunNetMask()`, `actionTunRoute()`
- Uses `/dev/net/tun` (confirmed in strings)

`SdBus` class:
- `setDNSServer()`, `setDNSDomain()` — DNS via systemd-resolved (D-Bus)

`AadConfig` class:
- `setAadConfigFromXML()`, `getAuthority()`, `getClientId()`, `getAudience()`
- Loads tenant/client_id from the VPN profile file (XML format)

### Auth flow (reconstructed)

```
setXmlProfileData()
  └─ AadConfig::setAadConfigFromXML()     ← reads tenant, client_id, audience
acquireAadToken()
  └─ MSAL device code flow                ← https://login.microsoftonline.com/{tenant}/oauth2/v2.0/...
connectAadProfile(username, token)
  └─ connectVpnProfile()
      └─ connectOpenVPN()                 ← passes token to libXplatSharedLibrary
```

## libXplatSharedLibrary.so — C++ OpenVPN implementation

This is a **custom OpenVPN implementation** (not the standard openvpn binary), built on top of OpenSSL.

### Evidence: custom reimplementation, not stock OpenVPN

| Evidence | Strings in the binary |
|---|---|
| Custom C++ classes (stock OpenVPN is C) | `OpenVpnFraming::process_up_control_packet`, `OpenVpnSession::set_peer_info` |
| OpenVPN wire protocol manually reimplemented | `Sending P_CONTROL_HARD_RESET_CLIENT_V2`, `P_CONTROL_SOFT_RESET_V1`, `IV_PROTO=1`, `IV_VER=0.1 IV_PLAT=AzMac`, `OpenVPN master secret`, `OpenVPN key expansion` |
| Microsoft's cross-platform lib (Azure DevOps build path) | `/__w/1/s/platform/Networking-VPNXplatLib/XplatSharedLibrary/core/src/backend/common/tls_openssl_common.cpp` |
| Multi-protocol engine — OpenVPN is one builder | `MobileAccessVPNBuilder.cpp`, `OpenConnectVPNBuilder.cpp`, `CSTPMsg.cpp` (Cisco AnyConnect), `dtls_channel.cpp` |
| No GPL notice / `OpenVPN 2.x` version string | (absent — compiled stock OpenVPN would have these) |

**Consequence**: this custom `OpenVpnFraming` does not have the stock limit `TLS_CHANNEL_BUF_SIZE`
(2048 bytes), and can therefore send the ~2.1 KB Entra token in the key-method-2 message.
Stock OpenVPN fails on this with `Key Method #2 write failed` — which is why the
`Containerfile` rebuilds OpenVPN with a larger buffer (see troubleshooting).

### Log strings that reveal the protocol

```
OPENVPNBUILDER:Authentication Type is %s
OPENVPNBUILDER:AAD token or password is not valid so using it as empty...
OPENVPNBUILDER:AAD token or password is still valid so credential_refresh is not needed.
OPENVPNBUILDER:Marked AAD token or password as valid.
OPENVPNBUILDER:Recevied empty token value
OPENVPNBUILDER:Reset received from Server. Starting Tls handshake. ServerName: %s
OPENVPNBUILDER:Server requested rekey operation
OPENVPNBUILDER:OpenVPN attempting to connect
OPENVPNBUILDER:OpenVPN connected
OPENVPNBUILDER:Primary connection completed
OPENVPNBUILDER:Dual tunnel is enabled. Start reconnection threads
OPENVPNBUILDER:Dual tunnel is not supported on server
OPENVPNTLS:  [TLS submodule]
OPENVPNCONNECTION:Terminating datapath connection as callback is terminated.
```

### Token usage

The token is treated internally as the **password** field in the OpenVPN `auth-user-pass` mechanism:
- `connectAadProfile(char* username, char* token)` — two parameters
- Log name `"AAD token or password"` — token is the password field
- `"Received empty token value"` — empty token = immediate error

### Cipher restrictions

```
Prohibited TLS 1.2 Cipher Suite: %x
```
The client rejects certain TLS 1.2 cipher suites. Standard OpenVPN supports the same suites,
but the gateway may have specific requirements.

### Dual tunnel (HA)

Servers can optionally offer dual-tunnel (HA failover). The client detects this automatically.

## System integration

| Component | Detail |
|---|---|
| Capabilities | `cap_net_admin+eip` via `setcap` (postinst) |
| Polkit | `org.freedesktop.resolve1.set-dns-servers` + `set-domains` |
| DNS | systemd-resolved via D-Bus (`SdBus`) |
| Logging | rsyslog to `/var/log/azurevpnclient/AzureVPNClient.log` |
| TUN device | `/dev/net/tun` directly via ioctl |

## getNewAadToken() static analysis — does it support mid-session token refresh? (2026-07-05, inconclusive)

Investigated as groundwork for handling the ~60-minute AAD token expiry (the P2S connection
drops after exactly 3609s — see `docs/troubleshooting.md` if that entry exists, or the
session history — because the access token used to authenticate it expires and the gateway
tears down the connection). The question: can `ConnectionManager::getNewAadToken()` be called
on a *live* connection to refresh the credential in place, avoiding a full reconnect?

`nm -D --defined-only src/libs/libLinuxCore.so | c++filt` resolves the mangled symbol to
`_ZN17ConnectionManager14getNewAadTokenEv` at file-vaddr `0xb3fd0`, ending at `0xb4010`
(next symbol `getCertCreds`) — only 64 bytes. `objdump -d` shows **no calls and no
branches**: it builds a fixed 24-byte struct (hidden-return-pointer ABI, same convention as
`loadCerts`/`AcquireResult` elsewhere in this file) from `rsi` (the `this` pointer, echoed
into offset 0) and two other addresses (`rdx`, `rcx`) that point into the *code* ranges of
`acquireAadToken` and `print_capabilities` (not `.rodata` — confirmed via `objdump -s -j
.rodata` returning nothing for those addresses).

Two readings are both consistent with the disassembly:
1. **Dead/stub implementation** — returns a fixed placeholder immediately, does no real work.
2. **Lazy closure / Go interface value** — the 16-byte (code-ptr, code-ptr) pair could encode
   a Go `interface{}` (itab + data pointer) that only does real work when something later
   *calls* it — in which case `getNewAadToken()` itself is just a constructor for a deferred
   operation, not the operation.

**Not resolved.** A live test (call it via `dlsym` on a running connection near the 60-minute
mark, observe via syslog/strace whether it does any network I/O or changes `rawStatus`) was
attempted 2026-07-05 but never reached a connected state to test against — see
`docs/troubleshooting.md`'s "no account was specified" entry for why. The instrumented shim
for this test (adds `fn_getNewAadToken` dlsym + a `TEST_REFRESH_AT_SEC`-gated call in the
poll loop, plus the pump-thread-segfault fix noted in `docs/lib-interface.md`) was not
committed to `src/` — it lived only in a scratch build context. Whoever picks this up next
should rebuild it fresh rather than search for it.

## Relevance for container approach

### Confirmed assumptions ✓
- Token via device code flow or pre-acquired: correct
- OpenVPN over TCP to gateway: correct
- TUN device needed (`--device=/dev/net/tun`): correct
- `cap_net_admin` needed: correct
- Token as credentials to OpenVPN: correct

### Identified risks ⚠️

**Credentials order**: `connectAadProfile(username, token)` + log `"AAD token or password"` suggests:
- line 1 = username (e.g. `AzureAD`)
- line 2 = the Bearer token

**DNS**: The client uses systemd-resolved via D-Bus. In a container without systemd this does not work.
DNS must be configured manually.

**Custom OpenVPN implementation**: `libXplatSharedLibrary.so` is not standard openvpn. If the gateway
expects custom protocol extensions (such as specific PUSH options or renegotiation), the standard
`openvpn` binary cannot handle that.

## Gateway types: `azuregateway-*` vs `wan.*`

Azure P2S has two fundamentally different gateway variants:

| Type | Hostname pattern | Auth method | Stock OpenVPN? |
|---|---|---|---|
| Certificate / RADIUS | `azuregateway-<guid>.vpn.azure.com` | Cert or RADIUS | Yes — standard profile |
| Microsoft Entra (AAD) | `wan.<hash>.vpn.azure.com` | Entra device code / token | No — Azure VPN Client only |

Entra-type gateways use the `wan.*` or `hub*.*` pattern. Microsoft does not publish a
standard OpenVPN profile for these. The gateway expects the Azure client's own peer-info
in the OpenVPN key-method-2 message and rejects stock OpenVPN with a TCP reset after the
TLS handshake (see `docs/troubleshooting.md`).

### Confirmed protocol requirements of the `wan.*` gateway

| Requirement | Status | Solution |
|---|---|---|
| Direct TCP/443 (no TLS wrapper) | ✅ resolved | stunnel removed |
| tls-auth HMAC (`<serversecret>`) | ✅ resolved | key from rasphone.pbk |
| TLS cert verification (DigiCert chain) | ✅ works | system CA bundle |
| Control-channel buffer ≥ 2.1 KB | ✅ resolved | `TLS_CHANNEL_BUF_SIZE 8192` |
| SNI on control-channel TLS | ✅ patched | `SSL_set_tlsext_host_name` |
| Microsoft peer-info (`IV_PLAT=AzMac`) | ❌ **blocker** | stock OpenVPN does not send this |

The peer-info (`IV_VER=0.1 IV_PLAT=AzMac IV_PROTO=1`) is hardcoded in
`libXplatSharedLibrary.so` and identifies the client as the official Microsoft engine.
The gateway rejects other values.

## Further decompilation

For deeper insight:
- **Ghidra** (free): import `libXplatSharedLibrary.so` for C++ pseudocode
- **blutter**: Dart AOT decompiler for `libapp.so` (UI logic)
- Go binaries: symbols already readable via `strings` + `nm -D`

For the peer-info blocker specifically: look in `libXplatSharedLibrary.so` for the
`set_peer_info` method of `OpenVpnSession` and the full key-method-2 options string
sent to the gateway.
