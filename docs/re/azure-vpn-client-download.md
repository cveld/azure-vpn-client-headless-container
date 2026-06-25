# Azure VPN Client Download

## Info

- **Version:** 4.0.5.0
- **Package:** MSIX sideload (zip)
- **winget ID:** `Microsoft.AzureVPNClient`

## Direct download URL

```
https://download.microsoft.com/download/1fa24e82-5a8b-41be-90a9-957b1064f51e/AzVpnAppx_4.0.5.0_sideload.zip
```

## Notes

- `https://aka.ms/azvpnclientdownload` redirects to the Microsoft Download Center page (`https://www.microsoft.com/en-us/download/details.aspx?id=108598`), not a direct file download.
- The direct URL above was retrieved via `winget show Microsoft.AzureVPNClient`.
- SHA256: `edec567ee58fe142a1f070328e35cbc7c79b73aba6182662b6390f18215ad2d4`

## Installation

```powershell
# Download
Invoke-WebRequest -Uri "https://download.microsoft.com/download/1fa24e82-5a8b-41be-90a9-957b1064f51e/AzVpnAppx_4.0.5.0_sideload.zip" -OutFile "AzVpnAppx_4.0.5.0_sideload.zip"

# Extract and install MSIX
Expand-Archive AzVpnAppx_4.0.5.0_sideload.zip -DestinationPath AzVpnAppx
Add-AppxPackage .\AzVpnAppx\AzureVPN.msixbundle
```

## Dependencies

- Microsoft.VCLibs.Desktop.14
- Microsoft.UI.Xaml.2.8
- Microsoft.VCLibs.14
