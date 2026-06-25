# Shim — last blocker: server cert validation

Status June 2026: everything works headless except server cert validation in the
proprietary OpenVPN stack.

## What works (fully headless, no login)
1. Cache from gnome-keyring of the working WSL client (item
   `microsoft-azurevpnclient.secureStorage`, key `AzureVpnClient_AzVPNClientMsalcache_`).
2. `connectAadProfile(profile, cacheJSON, UPN)` with UPN = `user@tenant.onmicrosoft.com`:
   → `Found cached account` + `Acquired access token silently`. No browser.
3. Profile via `PROFILE_XML` (real azurevpnconfig.xml).
4. Custom OpenVPN stack runs: TCP → TLS1.3 handshake → 3 server certs received.

## The blocker
```
TId:[24] num certs 3
TId:[24] No cert verification callback from client
TId:[24] Server cert validation failed because no certificates were passed
         error 610af0100000012 tls_openssl_common.cpp:175  "Root cert validation failed"
```
The official Dart client registers a cert verification callback + loads CA certs;
the shim does not.

## Investigated routes (all blocked)

### loadCerts
- `ConnectionManager::loadCerts(std::string)` @ 0xb67a0 in libLinuxCore.so.
- Opens a FILE (basic_filebuf), parses certs → vector<CertificateData>.
- ABI: returns 24-byte object → `(rdi=&ret, rsi=this, rdx=&pathstring)`.
- Shim now calls it correctly (CertVec24 return), shim log shows the correct path,
  BUT loadCerts still opens an EMPTY path ("Failed to open file: ").
- Internal loadCerts calls (during connect) read the path from a GLOBAL @ 0x779fc0
  (s_PLATFORM+0x700) — which is empty. Hence "Certs loaded 0".
- The pinned hash from the profile DOES work: `Adding root cert hash df3c24f9...` +
  `Root certs received count: 1`. But without the callback, validation still fails.

### cert verification callback
- String "No cert verification callback from client" @ libXplatSharedLibrary.so rodata 0x207fe0.
- Xref search (lea to 0x207fe0/0x208036/0x205c12) yields NOTHING → strings are
  probably loaded via GOT/PIC indirection, not via direct lea. Patch location
  therefore hard to find.

## UPDATE: loadCerts ABI + prefix cracked (but callback remains)

- The global @ 0x779fc0 is a static `std::string = "/etc/ssl/certs/"` (dir PREFIX,
  set via static initializer @ 0xae9b9).
- `loadCerts(filename)` opens `"/etc/ssl/certs/" + filename`. With arg `"ca-certificates.crt"`
  → **"Certs loaded 1"** (our shim call now works!). Loads apparently 1 cert (first PEM block).
- ABI definitive: `CertVec24 loadCerts(rsi=this, rdx=&path)` with hidden ret-ptr in rdi.
- BUT: loadCerts RETURNS the vector (shim discards it); does not store in mgr.
  The internal loadCerts (during connect) gets empty filename → "Certs loaded 0".
- No direct `call b67a0` in the binary → internal call is indirect/virtual;
  filename source not traceable with objdump.
- Net: even with loaded certs "No cert verification callback from client" remains →
  loaded certs do not wire to TLS validation without the callback registration.

## UPDATE 2: Ghidra analysis

Ghidra 12.1.2 + JDK 21 running headless in WSL.

Findings:
- `loadCerts` (0xb67a0) callers: **`connectOpenVPN`** (0x1b7a78 Ghidra base) + cgo export.
- `loadCerts` returns the cert vector (`CertVec24`), does NOT store in mgr.
- `loadCerts` builds path = global(0x779fc0) + arg. Global = static `std::string
  "/etc/ssl/certs/"` (set @ static-init 0xae9b9).
- **Global patch works technically** (base via `connectAadProfile`@0xb1d00 → base+0x779fc0;
  re-patch confirms global = "/dr.pem" just before connect, not reset). BUT the
  connect-time cert load still opens an EMPTY path → that loader does NOT use 0x779fc0.
- Conclusion: the connect-time cert load is a **different** function/path from loadCerts(0xb67a0);
  it reads a cert path from a config member (connectOpenVPN arg+0x28) that is empty for AAD,
  and does not use the "/etc/ssl/certs/" global. Source of that member not traced
  (Ghidra decompile of connectOpenVPN is too noisy due to poor var recovery).

Remaining: decompile of the connect-time cert loader (possibly in libXplatSharedLibrary.so)
+ the OpenVPNBuilder cert config / cert-verify-callback registration. Substantial.

## UPDATE 3: re-patch thread — definitive conclusion

- "Certs loaded"/"Failed to open file" is ONLY in libLinuxCore.so (loadCerts);
  "cert verification callback"/"No cert verification" ONLY in libXplatSharedLibrary.so.
- A background thread forcing the cert-path global (base+0x779fc0) every 0.15ms
  to "/dr.pem" → connect-time loadCerts STILL opens an empty path.
- **Conclusion**: `connectAadProfile` takes the cert path from the PROFILE (empty for AAD)
  and copies it to a per-connection copy/member that loadCerts uses — NOT the live global.
  Memory patches on the global are therefore fundamentally useless.
  (Standalone loadCerts does use the global → that is why our standalone call worked.)
- The cert path source is the profile / a per-connection config field that is empty headless.

## Next technique: DYNAMIC debugging (gdb)
Static RE + memory patching is exhausted by the above contradiction.
Needed: gdb (with --cap-add=SYS_PTRACE) → breakpoint on loadCerts (base+0xb67a0) during
connect → inspect rsi (this) and rdx (&path string) → find which config field provides the
(empty) path and where it is set. Then fill that field (via profile XML or a targeted patch)
with a path to the DigiCert root. Possibly also register the cert-verify callback in
libXplatSharedLibrary.

## Remaining options (substantial RE work)
0. **Ghidra**: trace connect-time cert loader + OpenVPNBuilder cert config;
   import libXplatSharedLibrary.so and find the cert-verify callback setter.
1. **Cert-path global @ 0x779fc0**: determine who fills that std::string global
   (possibly setPlatformInfo's 4th arg, currently "") and put a CA file path there →
   internal loadCerts loads the CA → callback may register automatically.
2. **Register cert-verify callback**: find the C++ registration API (PIC/GOT analysis
   or Ghidra) and call it with the correct signature.
3. **Patch validation**: bypass tls_openssl_common.cpp:175 (PoC hack; we trust the
   pinned gateway). Requires finding the code location via GOT resolution first.

## Key facts for resumption
- cert-path global: vaddr 0x779fc0 in libLinuxCore.so
- `connectAadProfile` @ file-vaddr 0xb1d00 (use as anchor for base calculation)
- `loadCerts` @ file-vaddr 0xb67a0
