#!/bin/sh
# Configures git for Azure DevOps auth (if terraform-vpn.ps1 supplied
# GIT_AZDO_USERNAME/GIT_AZDO_PASSWORD via -AzDoOrg), then hands off to
# terraform. This is the sidecar's ENTRYPOINT.
set -e

# /workspace is a bind-mounted Windows volume (via Docker Desktop's WSL2 file
# sharing). Its reported ownership doesn't match the container's user, so
# git's safe.directory check (CVE-2022-24765 mitigation) refuses to fully
# trust any repo cloned under it -- ref/tag lookups silently come back empty
# instead of erroring, which is what actually caused "invalid ref" errors for
# real tags that resolve fine everywhere else. Trust everything under /workspace.
git config --global --add safe.directory '*'

# The VPN container's network namespace only has a link-local IPv6 address
# (no real IPv6 route), but DNS still returns AAAA records for dev.azure.com
# ahead of A records, so every new connection wastes a fast-failing IPv6
# attempt before falling back to IPv4. That per-connection churn is a
# plausible cause of git's protocol negotiation silently dropping refs (a
# clone missing a tag that resolves fine outside this network). Pin
# dev.azure.com to its real IPv4 address so nothing tries IPv6 at all.
azdo_ahosts="$(getent ahostsv4 dev.azure.com 2>/dev/null)"
azdo_first_line="${azdo_ahosts%%
*}"
azdo_ipv4="${azdo_first_line%% *}"
if [ -n "$azdo_ipv4" ]; then
    echo "$azdo_ipv4 dev.azure.com" >> /etc/hosts
fi

if [ -n "$GIT_AZDO_PASSWORD" ]; then
    header="AUTHORIZATION: Basic $(printf '%s:%s' "$GIT_AZDO_USERNAME" "$GIT_AZDO_PASSWORD" | base64 -w0)"
    git config --global http."https://dev.azure.com/".extraheader "$header"
fi

exec terraform "$@"
