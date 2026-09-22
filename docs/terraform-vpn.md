# terraform-vpn.ps1 — running Terraform through the VPN tunnel

Runs `terraform` inside a sidecar container that shares the VPN container's
network namespace (`docker run --network container:<vpn-container>`), so
Terraform can reach Azure resources that are only reachable over the P2S
tunnel (private endpoints, private DNS zones, internal load balancers, ...).

## Why a sidecar, not `terraform` inside the shim container

The VPN container (`src/`) has one job: hold the tunnel up. Terraform lives in
its own image (`src-terraform/Containerfile`) built FROM
`mcr.microsoft.com/azure-cli:latest` with a pinned terraform binary added.
Keeping it separate means:

- the VPN image doesn't need rebuilding to bump the Terraform version
- Terraform state/workspace stays a plain bind-mount, independent of the
  tunnel's own `/work` mount
- `--network container:<name>` gives the sidecar the tun0 interface and
  routes for free — no extra networking code needed

## Usage

```powershell
# VPN container not running yet — starts it via connect-vpn.ps1
.\terraform-vpn.ps1 -VpnProfile "My Profile" plan

# VPN container already running under a known name
.\terraform-vpn.ps1 -Container vpn-igh-insurances apply -auto-approve

# Exactly one vpn-* container running — auto-detected
.\terraform-vpn.ps1 init

# Terraform working directory defaults to the current directory; override with -Dir
.\terraform-vpn.ps1 -Dir C:\work\terraform\my-stack plan

# Module sources are git:: URLs in this AzDO org -- see "Git module auth" below
.\terraform-vpn.ps1 -VpnProfile "My Profile" -AzDoOrg MyOrg init
```

Everything after the recognized parameters is passed straight through to
`terraform` inside the sidecar (`plan`, `apply -auto-approve`, `init -upgrade`, ...).

## DNS

`--network container:<name>` shares the network *stack* (interfaces, routes)
but **not** `/etc/resolv.conf` — that's a filesystem file, not part of the
network namespace. `runner.sh`'s DNS-poller writes the tunnel's DNS server
into `/etc/resolv.conf` **inside the VPN container only** once PUSH_REPLY
arrives (see `docs/architecture.md`). `terraform-vpn.ps1` copies that file out
via `docker exec <vpn-container> cat /etc/resolv.conf` and bind-mounts it into
the sidecar before every run, so private-zone / internal FQDNs resolve the
same way they do inside the VPN container itself.

## Azure auth (ARM / azurerm provider)

| Session state | Sidecar behavior |
|---|---|
| `$env:ARM_CLIENT_ID` set (service principal) | `ARM_CLIENT_ID`/`ARM_CLIENT_SECRET`/`ARM_TENANT_ID`/`ARM_SUBSCRIPTION_ID` passed through as-is. The az CLI baked into the sidecar image is unused. |
| Otherwise | The sidecar gets its own, separate, **Linux-native** az CLI login (`ARM_USE_CLI=true`). |

The "otherwise" row is *not* your Windows az CLI session inherited or
mounted — that was the original design, and it never actually worked. Windows
az CLI defaults to WAM (Web Account Manager) as its sign-in broker, and
WAM-issued tokens aren't portable: the refresh capability lives in the
Windows account broker itself, not in a file a Linux container can read.
Bind-mounting `AZURE_CONFIG_DIR` as-is left the sidecar's `az` with no usable
token — `az account show` still "worked" (it just reads local profile
metadata, no live token needed), but anything needing a real token failed
with `User '...' does not exist in MSAL token cache`, even right after a
fresh `az login` on the host.

So instead: the sidecar's login is stored at
`%USERPROFILE%\.azurecustomers-container\<vpn-container-name>` (keyed on the
container name so it's stable across `-VpnProfile`/`-Container`/auto-detect),
bind-mounted at `/root/.azure`. The first time a given container's cache
doesn't exist yet, `terraform-vpn.ps1` automatically runs
`Connect-AzCliForContainer.ps1` — a one-time (or occasional, once the login
eventually expires) **interactive device-code sign-in**, scoped to the right
tenant by parsing it straight out of the VPN profile's own XML (same
`rasphone.pbk` source `connect-vpn.ps1` reads), so you never have to look up
or pass a tenant ID yourself. Since it's a real Linux MSAL login, a portable
refresh token lands in the cache this time, so it survives across `--rm`
container runs until it eventually expires.

Secrets never touch the `wsl`/`docker` command line: they're written to a
per-run `--env-file` (temp file under `$env:TEMP`, deleted in a `finally`
block) instead of `-e VAR=value` args.

## Git module auth (`git::` source URLs)

Fetching a private `git::` module source (e.g. an Azure DevOps repo) from
inside the sidecar needs its own auth, separate from the ARM/azurerm side
above — pass `-AzDoOrg <org-name>`:

```powershell
.\terraform-vpn.ps1 -VpnProfile "My Profile" -AzDoOrg MyOrg init
```

This pulls a cached git credential for `dev.azure.com/<org>` from the
**host's own git credential helper** (`git credential fill` — the exact same
flow a normal `git clone` on this machine already uses, so if that already
works for you, this works too) and hands it to the sidecar as an
`http.extraheader`, scoped to `https://dev.azure.com/`. Best-effort: if the
host has no cached credential for that org, this warns and continues — only
useful when your modules actually live in that org.

Without a credential, a private `git::` source doesn't just fail — the
sidecar has no TTY to prompt on, so it hangs forever waiting for input that
can never arrive. `GIT_TERMINAL_PROMPT=0` is set unconditionally as a safety
net so any future auth gap fails fast with an error instead.

Two more fixes live in `entrypoint.sh`, both specific to this containerized
setup and invisible from a plain host-side `git clone`:

- **`dev.azure.com` is pinned to its IPv4 address in `/etc/hosts`.** DNS
  returns its AAAA record first, but this network namespace (shared with the
  VPN container) has no real IPv6 route — only a link-local address — so
  every new connection was wasting a fast-failing IPv6 attempt before falling
  back to IPv4. Harmless on its own, but a plausible cause of intermittent,
  hard-to-reproduce partial clones.
- **`git config --global --add safe.directory '*'`.** `/workspace` is a
  bind-mounted Windows volume (via Docker Desktop's WSL2 file sharing); its
  reported ownership doesn't match the container's user, so git's
  `safe.directory` check (a CVE-2022-24765 mitigation) silently refused to
  fully trust anything cloned under it — ref/tag lookups came back empty
  instead of erroring, producing `invalid ref` for tags that resolve fine
  everywhere else (confirmed: a bind-mounted clone showed 0 tags vs 215 for
  the identical clone on the container's own native filesystem).

## AzDO provider token (`azuredevops` Terraform provider)

Separate again from both the ARM/azurerm auth and the git module auth above:
if the terraform config declares a literal `provider "azuredevops" {}` block
(e.g. a module that manages AzDO resources, not just fetches its own source
from one), that provider needs a *bearer token for the AzDO REST API*. Unless
told otherwise it fetches this itself, internally, via
`az account get-access-token` — and since terraform runs inside the sidecar,
that call uses the sidecar's own az CLI login, which is scoped for ARM access
and typically has no membership in the AzDO org at all. Symptom:

```
Error: You are not authorized to access Azure DevOps Organization https://dev.azure.com/<org>
```

Pass `-AzDoTenant <az-context-alias>` — the `az-context.ps1` tenant alias
that *does* have membership in the `-AzDoOrg` organization (often a different
tenant than the one holding the Azure subscriptions you deploy into — check
before assuming they're the same):

```powershell
.\terraform-vpn.ps1 -VpnProfile "My Profile" -AzDoOrg MyOrg -AzDoTenant mycompany.com plan
```

This switches the **host's** az CLI to that tenant via `az-context.ps1`
(isolated per-tenant config dir, doesn't clobber any other tenant's cached
login), fetches a token there, and hands it to the sidecar through the same
`--env-file` mechanism as everything else in this script — as
`TF_VAR_azuredevops_accesstoken` /
`TF_VAR_azuredevops_accesstoken_bring_your_own_enabled=true`. Best-effort:
only needed when the config actually uses the `azuredevops` provider.

## Image

```powershell
wsl -d Ubuntu-20.04 -- bash -lc "cd '$ROOT' && docker build -f src-terraform/Containerfile -t terraform-az:local src-terraform"
```

`terraform-vpn.ps1` builds this automatically on first run (checks
`docker image inspect terraform-az:local` first, same pattern as
`connect-vpn.ps1`'s shim image build). Bump the pinned version by rebuilding
with `--build-arg TERRAFORM_VERSION=x.y.z`, or edit the `ARG` default in
`src-terraform/Containerfile`.
