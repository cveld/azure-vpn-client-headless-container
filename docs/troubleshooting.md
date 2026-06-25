# Troubleshooting

## TLS key negotiation failed to occur within 60 seconds

```
TLS Error: TLS key negotiation failed to occur within 60 seconds (check your network connectivity)
TLS Error: TLS handshake failed
```

**Cause**: a second TLS layer (stunnel) in front of OpenVPN. An earlier setup had
OpenVPN talking plaintext to `127.0.0.1:11194`, where stunnel wrapped it in TLS to
`gateway:443`:

```
OpenVPN ──plaintext──> stunnel(127.0.0.1:11194) ──TLS──> gateway:443
```

The Azure gateway multiplexes on `:443` (HTTPS / SSTP / OpenVPN). stunnel opens a
TLS connection → the gateway treats it as HTTPS/SSTP and is not in OpenVPN mode after
the handshake. OpenVPN then tries its own control-channel TLS inside, but the
OpenVPN handler never replies → timeout after 60 s.

Important: this error is at the **transport layer**, before authentication. The AAD token
is not involved yet — a token problem only produces `AUTH_FAILED` *after* the TLS
handshake succeeds.

**Fix**: no stunnel. The Azure gateway speaks standard OpenVPN directly on TCP/443.
Connect directly (`remote <gateway>.vpn.azure.com 443`).
Confirmed by binary analysis of `libXplatSharedLibrary.so`: the official client does a
plain OpenVPN handshake (`OPENVPNBUILDER:Reset received from Server. Starting Tls handshake.`)
without an outer TLS wrapper; the `.deb` contains no stunnel.

Diagnostic decision tree after this fix:
1. `Reset received from server` → TLS handshake → connected → resolved.
2. TLS succeeds, then `AUTH_FAILED` → transport OK, now the auth layer (see below).
3. Cert verification error → gateway CA missing from system bundle (see "TLS/CA").

## Connection reset, restarting [0] (immediately after TCP connect)

```
TCP connection established with [AF_INET]<gateway-ip>:443
Connection reset, restarting [0]
SIGUSR1[soft,connection-reset] received, process restarting
```

**Cause**: missing `tls-auth` key. The Azure gateway protects the OpenVPN control channel
with an HMAC (tls-auth). Control packets without a valid HMAC are immediately rejected with
a TCP reset — before the TLS handshake.

The key is stored in the profile as `<serversecret>` (256 bytes hex) in the
`azvpnprofile` XML inside `rasphone.pbk`. Decode the `ThirdPartyProfileInfo` (UTF-16LE hex)
from the `[YourProfileName]` section and extract `<serversecret>`. Convert it to an
OpenVPN static-key file (16 lines of 32 hex chars):

```
-----BEGIN OpenVPN Static key V1-----
<16 lines>
-----END OpenVPN Static key V1-----
```

And in the ovpn:
```
tls-auth /vpn/azure-tls-auth.key 1
```

Confirmed by binary analysis of `libXplatSharedLibrary.so`: strings `tls-auth`,
`keydir`, `SERVER_SECRET` (no `tls-crypt`). key-direction = `1` for the client
(the gateway is the server = `0`).

**Fallback if resets persist**:
- Try key-direction `0`, or `tls-auth` without direction (bidirectional).
- Check the `auth` digest (`auth SHA256`): if the gateway uses a different
  CONTROL_PATH_DIGEST, the tls-auth HMAC won't verify → reset.

## TLS Error: Key Method #2 write failed

```
TLS: Initial packet from [AF_INET]<gw>:443, sid=...
TLS Error: Key Method #2 write failed
TLS Error: TLS handshake failed
```

**Cause**: the Entra/AAD access token is too large for stock OpenVPN. OpenVPN writes
username + password (= the token) into the OpenVPN key-method-2 message, which must fit
in the control-channel plaintext buffer. That buffer is hard-capped in stock OpenVPN at
`TLS_CHANNEL_BUF_SIZE` = **2048 bytes**. An Azure v1.0 token is ~2.1 KB → does not fit →
the write fails locally (the error appears within microseconds of the initial packet,
without a network round-trip).

Reproduced: a password of 1300 chars works, 2151 chars (the real token) fails.
`--max-packet-size` does not help (control-channel payload caps at ~2148).

**Fix**: rebuild OpenVPN with a larger buffer. The `Containerfile` compiles
OpenVPN from source with `TLS_CHANNEL_BUF_SIZE = 8192`:
```dockerfile
RUN F=$(grep -rl 'define TLS_CHANNEL_BUF_SIZE' src/) \
    && sed -i 's/#define TLS_CHANNEL_BUF_SIZE[[:space:]].*/#define TLS_CHANNEL_BUF_SIZE 8192/' "$F"
```

Background: the official Azure VPN client does not use stock OpenVPN but its own C++
reimplementation of the OpenVPN protocol (`Networking-VPNXplatLib`, class `OpenVpnFraming`)
without this buffer limit — see `docs/linux-client-analysis.md`.

## Connection reset after VERIFY OK (after TLS handshake)

```
VERIFY OK: depth=0, CN=<gateway>.vpn.azure.com
Connection reset, restarting [0]
SIGUSR1[soft,connection-reset] received, process restarting
```

This is a **different** reset from "immediately after TCP connect" (see above). Here the
full TLS handshake succeeds and the server certificate is verified — the reset follows
after the gateway has received and acknowledged (`P_ACK_V1`) our `P_CONTROL_V1` packet
(key-method-2 + credentials).

**Root cause**: the Azure Entra auth gateway (`wan.*`) checks the OpenVPN
**peer-info/options** in the key-method-2 message. Stock OpenVPN sends standard values
like `IV_VER=2.6.x IV_PLAT=linux IV_NCP=2 IV_TCPNL=1`. The official Azure client sends:

```
IV_VER=0.1
IV_PLAT=AzMac      ← platform identifier of the Microsoft engine
IV_PROTO=1
```

Binary analysis of `libXplatSharedLibrary.so` confirms these strings. The gateway
rejects clients that do not advertise the expected Microsoft peer-info — with a bare
TCP reset, no TLS alert or OpenVPN error code.

**Tried (all without effect)**:

| Attempt | Result |
|---|---|
| `--tls-version-min 1.2 --tls-version-max 1.2` | reset |
| `--tls-version-min 1.3 --tls-version-max 1.3` | reset |
| `--tls-cipher ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256` | reset |
| `--tls-groups secp256r1:secp384r1` | reset |
| SNI via `SSL_set_tlsext_host_name` (source-patch, confirmed in packet-capture) | reset |

All these parameters affect the TLS layer; the gateway accepts the TLS handshake
but rejects the OpenVPN layer.

**Fundamental limitation**: the Azure Entra P2S gateway (`wan.*`) is exclusively
documented for use with the Azure VPN Client; interoperability with stock
OpenVPN is not provided or guaranteed by Microsoft.

## AUTH_FAILED / token rejected

**Cause**: wrong order in the credentials file.

OpenVPN `auth-user-pass` expects: line 1 = username, line 2 = password.
Azure VPN gateway expects the Bearer token in the **password** field (not the username field).
Confirmed by binary analysis of `libLinuxCore.so`: `connectAadProfile(username, token)`
and log `"OPENVPNBUILDER:AAD token or password is not valid"`.

**Correct**:
```
AzureAD          ← line 1: username (any non-empty string)
<Bearer token>   ← line 2: password (the AAD token)
```

**Wrong (old situation)**:
```
<Bearer token>   ← line 1: username (too long for OpenVPN username field)
AzureAD          ← line 2: password (wrong field)
```

## "Enter Auth Password:" prompt

OpenVPN prompts interactively when the password line in the credentials file is empty.
Fixed by using `AzureAD` as a non-empty string on line 1 (username), token on line 2.

## `request_failed` immediately after device code is shown

Caused by `curl -sf` on the token poll endpoint. The `-f` flag treats HTTP 4xx
(`authorization_pending`) as a curl error → empty response → jq fails → fallback fires.
Fix: use `-s` only (no `-f`) on the token poll curl call.

## TLS/CA verification failure

The system CA bundle may not include the gateway's root cert. Options:
1. Download the VPN client package from Azure Portal and copy the `<ca>` block from
   `OpenVPN/vpnconfig.ovpn` into your ovpn config.
2. Temporarily add `--tls-noverify` to the openvpn call for diagnosis (insecure).

## Tun interface does not appear — tunnel seems connected but `ip link` does not show it

**Symptom**: syslog shows "OpenVPN connected successfully", "Tun Interface is up",
keepalives running — but `connect-vpn.ps1` waits until timeout and the DNS watcher
reports "TIMEOUT".

**Cause**: the profile name is longer than 15 chars after space-stripping. The Linux
kernel has an IFNAMSIZ limit of 16 bytes including null → maximum 15 usable chars.
The library creates the interface with the truncated name; scripts were looking for
the full name.

Example:
```
"Long Profile Name (extra)"  →  tr -d ' '  →  "LongProfileName(extra)"  (22 chars)
                                               kernel truncates to:
                                               "LongProfileName"         (15 chars)
```

**Diagnose**: check the actual interface name in the container:
```bash
docker exec <container> ip link
```

**Fix** (already in the code): `runner.sh` and `connect-vpn.ps1` use `| cut -c1-15`
resp. `.Substring(0,15)` to look up the correct name.

---

## `[redir] LD_PRELOAD certredirect ACTIEF` spam in docker logs

**Symptom**: docker logs shows dozens of `[redir] LD_PRELOAD certredirect ACTIEF (target=/dr.pem)`
lines, causing useful debug output (shim status, failure messages) to disappear in
`docker logs --tail 6`.

**Cause**: `certredirect.c` has a `__attribute__((constructor))` that prints the message on
every process load. If `export LD_PRELOAD=/certredirect.so` is set before the DNS-watcher
subshell, the subshell inherits it and every `ip link show`, `grep`, `seq` etc. triggers
the constructor.

**Fix** (already in the code): `runner.sh` exports `LD_PRELOAD` only after the `(&)` subshell
fork, just before `exec /entrypoint.sh`. The DNS watcher runs without the preload; the shim
and syslogd do get it.

---

## WSL socket buffer error `0x80072747`

```
An operation on a socket could not be performed because the system lacked
sufficient buffer space or because a queue was full.
Error code: Wsl/Service/0x80072747
```

Occurs after multiple consecutive VPN sessions (each session creates and tears down a tun
interface). WSL2's network socket pool gets exhausted.

**Fix**:
```powershell
wsl --shutdown
# wait 5s
wsl -d Ubuntu-20.04 -- bash -lc "sudo service docker start"
```

After the restart the Docker daemon is stopped — manual restart is required
(Docker in WSL does not start automatically after `wsl --shutdown`).

## Docker daemon stopped after WSL restart

After `wsl --shutdown` the Docker daemon is no longer running. Symptom:
```
failed to connect to docker API at unix:///var/run/docker.sock
```

**Fix**:
```powershell
wsl -d Ubuntu-20.04 -- bash -lc "sudo service docker start"
wsl -d Ubuntu-20.04 -- docker info   # verify
```

## Docker Desktop not running

`run-openvpn.ps1` (archived) fails with `pipe not found`. Start Docker Desktop first.
`connect-vpn.ps1` (shim flow) uses Docker in WSL — see above.

## VPN routes not pushed to container

With `route-nopull` in the ovpn config, no routes are pushed by the gateway. Add
explicit routes to the ovpn file:
```
route 10.x.x.0 255.255.255.0
```
Remove `route-nopull` to accept all routes pushed by the gateway (redirects all traffic).

## Azure CLI not logged in to tenant

`az account get-access-token` will fail if you are not logged in to the correct tenant.
Run once:
```powershell
az login --tenant <your-tenant-id>
```
After that, the cached token will be reused silently.
