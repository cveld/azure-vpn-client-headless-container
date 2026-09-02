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
.\terraform-vpn.ps1 -VpnProfile "IGH - Insurances" plan

# VPN container already running under a known name
.\terraform-vpn.ps1 -Container vpn-igh-insurances apply -auto-approve

# Exactly one vpn-* container running — auto-detected
.\terraform-vpn.ps1 init

# Terraform working directory defaults to the current directory; override with -Dir
.\terraform-vpn.ps1 -Dir C:\work\terraform\my-stack plan
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

## Azure auth

Inherited from the current PowerShell session — same environment
`az-context.ps1` (see the `az-cli` skill) leaves behind:

| Session state | Sidecar behavior |
|---|---|
| `$env:ARM_CLIENT_ID` set (service principal) | `ARM_CLIENT_ID`/`ARM_CLIENT_SECRET`/`ARM_TENANT_ID`/`ARM_SUBSCRIPTION_ID` passed through as-is. The az CLI baked into the sidecar image is unused. |
| Otherwise | `AZURE_CONFIG_DIR` (or `~/.azure` if unset) is bind-mounted into the sidecar at `/root/.azure`, and `ARM_USE_CLI=true` is set so the azurerm provider shells out to the already-logged-in `az`. |

Secrets never touch the `wsl`/`docker` command line: they're written to a
per-run `--env-file` (temp file under `$env:TEMP`, deleted in a `finally`
block) instead of `-e VAR=value` args.

Run `az login` (or `az-context.ps1 -Login`) on the host first if the second
row applies and no cached session exists — the script errors out early if
`AZURE_CONFIG_DIR`/`~/.azure` doesn't exist and no `ARM_CLIENT_ID` is set.

## Image

```powershell
wsl -d Ubuntu-20.04 -- bash -lc "cd '$ROOT' && docker build -f src-terraform/Containerfile -t terraform-az:local src-terraform"
```

`terraform-vpn.ps1` builds this automatically on first run (checks
`docker image inspect terraform-az:local` first, same pattern as
`connect-vpn.ps1`'s shim image build). Bump the pinned version by rebuilding
with `--build-arg TERRAFORM_VERSION=x.y.z`, or edit the `ARG` default in
`src-terraform/Containerfile`.
