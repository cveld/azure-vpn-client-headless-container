# rasphone.pbk — Azure VPN Client profile format

Location: `%LOCALAPPDATA%\Packages\Microsoft.AzureVpn_8wekyb3d8bbwe\LocalState\rasphone.pbk`

## Text structure

Standard Windows RAS phonebook format:

```
[ProfileName]
ThirdPartyProfileInfo=<hex>
ThirdPartyProfileInfo=<hex continued>
PhoneNumber=https://wan.xxx.vpn.azure.com/
...
```

- `ThirdPartyProfileInfo` can span multiple lines — concatenate the hex strings
- `PhoneNumber` = gateway URL (determines auth type, see below)

## ThirdPartyProfileInfo binary structure

| Offset (bytes) | Content |
|---|---|
| 0–3 | XML char count (little-endian uint32) |
| 4–259 | 256 bytes header: UTF-16LE package name (`Microsoft.AzureVpn_8wekyb3d8bbwe`) + null-padding |
| 260–267 | 8 bytes Windows FILETIME (last modified) |
| 268–… | UTF-16LE XML: `<azurevpnprofile>…</azurevpnprofile>` |
| end | 2 bytes null-terminator (00 00) |

**Finding the XML without fixed offset**: search for `3C 00 61 00 7A 00` (`<az` in UTF-16LE) — more robust than a fixed offset.
**XML end**: read until double-null (00 00) at an even offset from the XML start.

## Determining auth type from gateway

| PhoneNumber pattern | Auth type |
|---|---|
| `wan.*` or `hub*.*` | Entra ID (AAD) |
| `azuregateway-*` | Certificate |

## XML content (relevant fields)

```xml
<azurevpnprofile>
  <clientconfig>
    <vpnserver>wan.xxx.vpn.azure.com</vpnserver>
  </clientconfig>
  <aad>
    <tenant>https://login.microsoftonline.com/<TENANT-GUID>/</tenant>
    <audience><CLIENT-ID></audience>
    <issuer>https://sts.windows.net/<TENANT-GUID>/</issuer>
  </aad>
  ...
</azurevpnprofile>
```

## Usage in connect-vpn.ps1

`connect-vpn.ps1` reads the pbk file, decodes the hex and parses the XML:
- `ConvertFrom-ProfileHex` handles the byte conversion and UTF-16LE decoding
- `Read-Pbk` iterates over profile sections
- The selected XML is written to `SECRETS_DIR/vpn/<SafeName>.xml` (per profile)
