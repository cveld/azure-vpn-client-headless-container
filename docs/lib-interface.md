# Library interface & implementation

The three proprietary libraries from `microsoft-azurevpnclient_3.0.0_amd64.deb`.
All live in `src/libs/` and are mounted at `/opt/microsoft/lib/` in the container.

## Dependency tree

```
/vpnshim  (src/vpnshim.cpp — compiled into image)
  └─ dlopen libLinuxCore.so        ← only lib the shim drives directly
       └─ libXplatSharedLibrary.so ← loaded automatically as ELF dependency
            └─ libmat.so           ← loaded automatically as ELF dependency
```

The shim never calls `dlopen` or `dlsym` on `libXplatSharedLibrary.so` or `libmat.so`
directly. All control goes through `libLinuxCore.so`'s exported symbols.

---

## libXplatSharedLibrary.so — custom OpenVPN stack (C++, ~3.4 MB)

Microsoft's own cross-platform OpenVPN re-implementation. Not stock OpenVPN.

### Why it exists

The `wan.*` Entra gateway requires specific peer-info in the OpenVPN key-method-2
message:

```
IV_VER=0.1 IV_PLAT=AzMac IV_PROTO=1
```

This is hardcoded in `libXplatSharedLibrary.so` (class `OpenVpnSession::set_peer_info`).
Stock OpenVPN sends `IV_PLAT=linux` and is rejected by the gateway with a TCP reset
immediately after the TLS handshake — before authentication even begins.

### What it does

| Class | Responsibility |
|-------|---------------|
| `OpenVpnSession` | Peer-info, key-method-2, session negotiation |
| `OpenVpnFraming` | Control-channel packet framing (`P_CONTROL_HARD_RESET_CLIENT_V2` etc.) |
| `OpenVpnBuilder` | AAD token handling: passes `cacheJSON` → access token → OpenVPN `auth-user-pass` password field |
| `SdBus` | Sets DNS via systemd-resolved D-Bus after tunnel is up |
| `tls_openssl_common` | TLS layer; cert verification callback, peer cert validation |

### Token path inside this library

```
connectAadProfile(profile, cacheJSON, UPN)
  → acquireTokenSilently (MSAL-Go, in libLinuxCore.so)
  → access_token → OpenVpnBuilder
  → OpenVPN auth-user-pass: username=UPN, password=access_token
```

Log prefix: `OPENVPNBUILDER:` — visible in container logs.

### Cert verification

This library validates the gateway's TLS server certificate.
Without a cert loaded, you get:

```
No cert verification callback from client
Server cert validation failed because no certificates were passed
Root cert validation failed
```

**The fix** (implemented in the shim): `LD_PRELOAD=/certredirect.so` intercepts
`open()`/`fopen()` calls with empty or malformed paths (which `loadCerts()` produces
for AAD connections) and redirects them to `/dr.pem` (DigiCert Global Root G2).

### TLS control-channel buffer

Unlike stock OpenVPN (2048-byte limit), this library has no such constraint. It can
send the ~2.1 KB Entra access token in the key-method-2 message.

### Not called directly

The shim interacts with this library only indirectly:
- `setPlatformInfo("0.1", "AzMac", "x64", "")` in libLinuxCore.so passes the peer-info
  string that this library embeds in the OpenVPN handshake.
- `certredirect.so` (LD_PRELOAD) intercepts file opens at the libc level, so cert
  loading works without modifying this library.

---

## libmat.so — crypto / MSAL helpers (~1.7 MB)

Loaded as a dependency of `libLinuxCore.so`. Role: cryptographic helpers and MSAL
token-storage support (key derivation, secure string handling).

The shim has no direct interface with `libmat.so`. It is required at load time —
`dlopen(libLinuxCore.so)` fails with unresolved symbols if `libmat.so` is absent.
No behaviour differences were observed related to this library during RE.

---

## libLinuxCore.so — VPN engine (Go + CGo, ~7.5 MB)

The library the shim drives directly. Contains the MSAL-Go authentication stack and
the `ConnectionManager` C++ class that bridges to `libXplatSharedLibrary.so`.

How the shim drives it is documented below. Every non-obvious choice was forced by
binary analysis of the library — the reasoning is in `re/` and `docs/re/`.

### Exported C interface (dlsym)

Symbols resolved via `dlopen` + `dlsym`. All strings are null-terminated C strings
unless noted otherwise.

| Symbol | Signature | Notes |
|--------|-----------|-------|
| `initConnection` | `(profileName, gatewayFQDN, authority, int) → void` | Creates the ConnectionManager singleton. Must be called first. |
| `initAAD` | `(clientId, authority, clientId) → void` | Initialises MSAL. Must be called **after** initConnection (needs the singleton). Pass clientId as both 1st and 3rd arg. |
| `setPlatformInfo` | `("0.1", "AzMac", "x64", "") → void` | Sets `IV_PLAT=AzMac` in the OpenVPN peer-info. The gateway rejects any other value. |
| `connectAadProfile` | `(profileName, cacheJSON, username) → char*` | Starts the VPN. Returns immediately (async). See notes below. |
| `getConnectionStatus` | `(char* buf) → void` | Fills buf with a status string. **⚠ side-effect**: calls `disconnectVpnProfile()` if rawStatus==6 and tun is not yet connected. Do not poll before starting the pump. |
| `getFailureMessage` | `() → char*` | Returns the last failure string, or empty. |
| `disconnectProfile` | `() → void` | Disconnect. |
| `startDataPath` | `() → void` | Meant to start the data-path pump thread. Does **not** work headless — see pump section. |
| `getCache` | `() → GoString` | Returns the current MSAL cache JSON. `GoString.len` is unreliable (CGo export returns `*C.char`); use `strlen`. |
| `acquireTokenSilently` | `(a, b, c) → AcquireResult` | Safe to call only from within `connectAadProfile` context (needs non-nil logrus logger). |
| `connectionManager` | BSS symbol — pointer to singleton | `dlsym` returns the address of the pointer variable itself; dereference once to get the `ConnectionManager*`. |

### CGo ABI details

`libLinuxCore.so` is Go compiled with CGo. Two non-standard calling conventions apply:

```cpp
// GoString: 16 bytes, returned in rax:rdx (two registers)
typedef struct { const char *ptr; size_t len; } GoString;

// AcquireResult: 24 bytes — too large for registers.
// Caller allocates on stack; hidden pointer passed in rdi; real args shift to rsi/rdx/rcx.
typedef struct {
    GoString token;    // 16 bytes
    int64_t  errcode;  //  8 bytes
} AcquireResult;
```

## Exported C++ methods (mangled names, on ConnectionManager*)

These are C++ member functions called on the singleton pointer obtained via `connectionManager`.

| Demangled | Mangled symbol | Notes |
|-----------|---------------|-------|
| `setXmlProfileData(std::string)` | `_ZN17ConnectionManager17setXmlProfileDataENSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEE` | Load gateway FQDN + AAD config from XML. Call before connectAadProfile. |
| `loadCerts(std::string path)` → `CertVec24` | `_ZN17ConnectionManager9loadCertsENSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEE` | Load CA certs from file. Returns 24-byte struct via hidden pointer (rdi=&ret, rsi=this, rdx=&path). |
| `isTunConnected()` → `bool` | `_ZN17ConnectionManager14isTunConnectedEv` | Read tun-active flag. |
| `getStatus(char*)` → `int` | `_ZN17ConnectionManager9getStatusEPc` | **⚠ side-effect**: disconnects if status==6 and !isTunConnected. |

## Call sequence

```
dlopen("libLinuxCore.so")
  → patch cert-path global + start repatch thread   (see certredirect section)

initConnection(PROFILE_NAME, GATEWAY, AUTHORITY, 0)
sleep(1)                          ← Go runtime needs time to initialise the singleton

initAAD(CLIENT, AUTHORITY, CLIENT)

*connectionManager → setXmlProfileData(xml)   ← load gateway + AAD config
setPlatformInfo("0.1", "AzMac", "x64", "")

connectAadProfile(PROFILE_NAME, msalcache_json, UPN)
  ← arg 2 is the full msalcache.json blob (not a raw access token)
  ← arg 3 is the user UPN for silent token acquire

poll *(volatile int*)(*connectionManager) until == 6   ← rawStatus, NO side-effects
  → spawn pump thread directly (see pump section)
  → sleep 2s, then poll getConnectionStatus / getFailureMessage

disconnectProfile() + dlclose()
```

## Implementation choices in vpnshim.cpp

### C++ (not C)

`setXmlProfileData` and `loadCerts` take `std::string&`. Calling them from C would require
hand-rolling the std::string ABI. Using C++ lets the compiler handle it.
`src/vpnshim.cpp` — C++17, compiled with `g++ -std=c++17`.

### msalcache.json as VPN_TOKEN (not a raw access token)

`connectAadProfile`'s second argument is passed as-is to the library's internal
`CacheAccessor.Replace` — it is the full MSAL cache JSON, not a JWT bearer token.
The library then calls `acquireTokenSilently` internally using the cached refresh token.

`src/runner.sh`: `export VPN_TOKEN="$(cat /work/msalcache.json)"`

### Raw status poll, not getStatus()

`ConnectionManager::getStatus()` has a destructive side-effect: if `rawStatus==6` (OpenVPN
connected) but `isTunConnected()==false` (pump not yet running), it calls
`disconnectVpnProfile()`. This tears down the connection before the pump can start.

**Solution**: read the raw status field directly from the singleton's first int field:
```cpp
int raw = *(volatile int*)(*conn_mgr_slot);   // rawStatus, no side-effects
```
Only switch to `getConnectionStatus()` for status string reporting after the pump is running.

### Manual pump thread (not startDataPath)

`startDataPath()` contains a gate: an internal `string::compare` that always mismatches
headless (the string it checks is set by the GUI flow). It returns -1 without starting the
pump thread.

**Solution**: call the pump thread body directly via a raw function pointer computed from
the known file-vaddr of the body (`FUN_001b0ec0` @ `0xb0ec0`) relative to `connectAadProfile`
(@ `0xb1d00`, known export):

```cpp
uintptr_t base  = (uintptr_t)fn_connectAadProfile - 0xb1d00;
void (*pump_body)(void) = (void(*)(void))(base + 0xb0ec0);
pthread_create(&pth, nullptr, [](void*) -> void* { pump_body(); return nullptr; }, nullptr);
```

This is equivalent to what `startDataPath`'s `std::thread` would do if the gate passed.
These offsets are specific to the `microsoft-azurevpnclient` 3.0.0 binary.

## certredirect.c — LD_PRELOAD interceptor

**File**: `src/certredirect.c`  
**Loaded via**: `LD_PRELOAD=/certredirect.so` (set in `src/runner.sh`)

### Cert path redirect

`loadCerts()` builds the certificate file path as:
```
cert_path_global_string + authority_URL
```
For AAD connections the global string is empty (or gets reset by `connectAadProfile`),
so the resulting path is either empty or `"https://login.microsoftonline.com/..."` — both
cause "Failed to open file" → "no certificates were passed".

The interceptor wraps `open()`, `openat()`, `fopen()`, `fopen64()`. When the path is
empty, or contains `"://"` or `"login.microsoftonline.com"`, it redirects to `/dr.pem`.

### Cert-path global repatch thread (in vpnshim.cpp)

`connectAadProfile` resets the global std::string (SSO, 16-byte inline buffer at
`base + 0x779fc0`) to empty just before the worker thread calls `loadCerts`. Even with
LD_PRELOAD, if the global is reset after we patch it but before loadCerts runs, the redirect
fails. A background thread in the shim re-patches the global at 0.15 ms intervals to win
the race:

```cpp
// repatch_thread: runs at 150µs, forces cert_path_global → "/dr.pem"
static volatile char *g_cert_global = nullptr;  // set to base + 0x779fc0 after dlopen
```

### sd_bus stubs

After "Connected", the library calls `sd_bus_open_system_with_description` +
`sd_bus_message_new_method_call` + `sd_bus_call` to set DNS via systemd-resolved.
Without a D-Bus daemon in the container, this returns ENOENT and the library tears
down the tunnel.

`certredirect.c` provides stub implementations of all required `sd_bus_*` symbols that
return 0 (success) without doing anything. The DNS is set instead by a poller in
`src/runner.sh` that writes `resolv.conf` once the tun interface appears.

## syslogd — mandatory

busybox `syslogd` must be running before `dlopen`. Without it, Go's `logrus` logger
inside the library is nil. The first log write (in `CacheAccessor.Replace`) dereferences
the nil pointer → SIGSEGV.

`src/entrypoint.sh` starts syslogd before launching `/vpnshim`.

## dr.pem — DigiCert Global Root G2

The Azure VPN gateway's TLS certificate is signed by DigiCert Global Root G2.
`certredirect.c` redirects malformed cert-path opens to `/dr.pem`.

This is a **public CA certificate** — not a secret. It is committed to `src/dr.pem`.
Regenerate: `bash src/fetch-dr-pem.sh` (downloads from DigiCert CDN, verifies CN).
