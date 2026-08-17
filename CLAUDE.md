# WSL Container Azure VPN

Container-based Azure VPN P2S (OpenVPN + AAD) — multiple profiles supported.

## Quick start

The headless shim flow runs in Docker **in WSL distro `Ubuntu-20.04`**. Claude can
build/run/test it from PowerShell via the `wsl -d Ubuntu-20.04 --` bridge —
see **[Building & running the container](docs/running-the-container.md)**. Do not ask the user to type; execute yourself.

```powershell
# One-time: copy .env.example → .env and fill in SECRETS_DIR
.\fetch-libs.ps1        # fills src/libs/ (skip if already present)
.\connect-vpn.ps1       # interactive profile picker — selects profile, runs token flow, starts container
```

An alternative launcher, `connect-vpn-openvpn.ps1`, uses a patched stock OpenVPN
build (`src-openvpn/`) instead of the `libLinuxCore.so` shim — no proprietary binary
required. Same profile picker and token flow; see [docs/openvpn-patch.md](docs/openvpn-patch.md).

## Key facts

- Protocol: OpenVPN over TCP; auth-type `aad`, audience `41b23e61-6c1e-4545-b367-cd054e0ed4b4`
- **Token via client `41b23e61`** (= audience = own public client). az CLI does NOT work.
- Token cache: `SECRETS_DIR/token-cache/<ProfileName>.json` (2-level base64 MSAL format)
- **Tun interface**: the library strips spaces from the profile name → `My Profile` → `MyProfile`. Linux IFNAMSIZ limit is 15 usable chars; longer names are truncated by the kernel → `Long Profile Name Here` → `Long Profile Nam` (15 chars). Scripts use `| cut -c1-15` / `.Substring(0,15)` to find the correct name.
- **DNS**: set automatically from syslog PUSH_REPLY (`OPENVPNCONNECTION:Adding DNS <ip>`)
- Production code is in `src/` (shim method) and `src-openvpn/` (OpenVPN method) — `re/` is research/RE history, do not modify

## Profiles

Profiles are configured via `SECRETS_DIR` in `.env`. For each profile, `connect-vpn.ps1` expects:
- `SECRETS_DIR\token-cache\<ProfileName>.json` — MSAL token cache
- `SECRETS_DIR\vpn\<ProfileName>.xml` — Azure VPN profile XML

See `docs/architecture.md` for the container naming rules.

## Docs

- [Building & running the container (PowerShell → WSL)](docs/running-the-container.md)
- [connect-vpn.ps1 — interactive profile picker](docs/connect-vpn.md)
- [src/ folder — production container contents](docs/folder-src.md)
- [Architecture & auth flow](docs/architecture.md)
- [libLinuxCore.so interface & implementation choices](docs/lib-interface.md)
- [OpenVPN patch set (alternative method, no proprietary binary)](docs/openvpn-patch.md)
- [VPN verification: end-to-end acceptance criteria](docs/vpn-verification.md)
- [VPN profile: gateway, audience, routes, tls-auth, token](docs/vpn-profile.md)
- [Troubleshooting](docs/troubleshooting.md)

### RE docs (`docs/re/`)

- [re/ folder — reverse engineering research history](docs/re/folder-re.md)
- [Exploration index: OpenVPN + libLinuxCore.so shim status](docs/re/exploration-index.md)
- [Headless pipeline — shim implementation notes](docs/re/headless-pipeline.md)
- [Shim cert validation analysis](docs/re/shim-cert-validation.md)
- [Cache format (MSAL)](docs/re/cache-format.md)
- [Linux client analysis](docs/re/linux-client-analysis.md)
- [Azure VPN client download](docs/re/azure-vpn-client-download.md)
- [rasphone.pbk binary format (ThirdPartyProfileInfo)](docs/re/rasphone-pbk-format.md)
- [Session plans](docs/re/sessions/) (NEXT-SESSION.md + planned-session-*.md)
