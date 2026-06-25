# Building & running the container — from Claude (PowerShell → WSL)

> **For Claude/agents:** do NOT ask the user to type WSL commands. You run on Windows PowerShell
> and can control Docker in WSL yourself via the `wsl -d Ubuntu-20.04 --` bridge.
> Build, run and verify yourself.

## Environment (check once)

```powershell
wsl -l -v                              # Ubuntu-20.04 = the docker distro (Running)
wsl -d Ubuntu-20.04 -- docker ps       # running containers (e.g. 'azurevpntunnel')
```

Docker is used via **Docker Desktop on Windows** with WSL integration enabled for `Ubuntu-20.04`.
The `docker` command in Ubuntu-20.04 talks to the Docker Desktop daemon via that integration.
Image name: `azurevpn-shim:local`. Container name: `azurevpntunnel` by convention.

**Required setting:** Docker Desktop → Settings → Resources → WSL Integration → Ubuntu-20.04 ✓

## Paths

| | Path |
|---|---|
| Project root (WSL) | `/mnt/c/path/to/azure-vpn-client-headless-container` |
| Secrets (WSL, synced) | set via `.env` → `SECRETS_DIR` (auto-converted to WSL path) |
| MS libs (build input, gitignored) | `src/libs/` (filled by `fetch-libs.ps1`) |
| Work mount in container | `~/vpnwork` (host) → `/work` (container) |

## First-time setup (fresh clone)

### Step 0 — configure `.env`

```powershell
Copy-Item .env.example .env
# Edit .env: set SECRETS_DIR to your secrets folder
# Optionally set LIBS_SOURCE if you already have the .so files
```

### Step 1 — fetch Microsoft libs into src/libs/

```powershell
.\fetch-libs.ps1                      # apt download (version from .env or default 3.0.0)
.\fetch-libs.ps1 -LibsDir "C:\...\libs"  # copy from existing folder (skips apt)
.\fetch-libs.ps1 -Local "C:\...\azurevpnclient.deb"  # from local .deb
```

`fetch-libs.ps1` is idempotent: skips if `src/libs/libLinuxCore.so` already exists.
Use `-Force` to re-fetch.

## Build → run → verify (the three commands)

```powershell
$ROOT = "/mnt/c/path/to/azure-vpn-client-headless-container"

# 1. Build image (after any change to src/Containerfile, vpnshim.cpp, certredirect.c):
wsl -d Ubuntu-20.04 -- bash -lc "cd '$ROOT' && docker build -f src/Containerfile -t azurevpn-shim:local src"

# 2. Start container (copies secrets + scripts to ~/vpnwork, starts 'azurevpntunnel' with runner.sh):
wsl -d Ubuntu-20.04 -- bash -lc "cd '$ROOT' && bash src/setup_and_run.sh azurevpntunnel runner.sh"

# 3. Verify tunnel is up (tun interface, routes, DNS):
wsl -d Ubuntu-20.04 -- docker exec azurevpntunnel ip link
wsl -d Ubuntu-20.04 -- docker exec azurevpntunnel ip route
wsl -d Ubuntu-20.04 -- docker exec azurevpntunnel cat /etc/resolv.conf
```

Or use `connect-vpn.ps1` which handles steps 1–2 automatically with an interactive profile picker.

`setup_and_run.sh` does NOT build the image — it only copies files and does `docker run`.
After changing `vpnshim.cpp` / `certredirect.c` / `Containerfile`: rebuild first (step 1).
After changing only `src/*.sh` runners: step 2 is enough (re-copies to workdir).

## Logs & live inspection

```powershell
wsl -d Ubuntu-20.04 -- docker logs --tail 80 azurevpntunnel
wsl -d Ubuntu-20.04 -- docker exec azurevpntunnel ip route
wsl -d Ubuntu-20.04 -- docker exec azurevpntunnel cat /etc/resolv.conf
```

## `/work` bind-mount ≠ git repo

The container's `/work` is a bind-mount of `~/vpnwork` in WSL — **not** the Windows git repo.
Changes to `src/*.sh` in the Windows checkout are **not** automatically visible in a running container.

**Sync options:**

| Situation | Solution |
|---|---|
| Shell script changed (`*.sh`) | `wsl -d Ubuntu-20.04 -- cp "/mnt/c/.../src/runner.sh" ~/vpnwork/runner.sh` |
| Restart container | `setup_and_run.sh` re-copies everything from `src/` |
| `vpnshim.cpp` / `certredirect.c` changed | Rebuild image (step 1), then restart container |

`docker inspect azurevpntunnel --format "{{json .Mounts}}"` always shows the current mount source.

## Git Bash path conversion (Bash tool / Monitor tool)

The **Monitor** and **Bash** tools run in **Git Bash**, not PowerShell. Git Bash converts
Unix absolute paths (`/work/runner.sh`) to Windows paths (`C:/Program Files/Git/work/runner.sh`)
before they reach `wsl.exe`.

**Symptom**: `sh: 0: cannot open C:/Program Files/Git/work/runner.sh: No such file`

**Fix**: always use the **PowerShell tool** for WSL commands containing absolute container paths:

```powershell
wsl -d Ubuntu-20.04 -- docker exec azurevpntunnel ip link   # ✅ PowerShell tool
```

## PowerShell quoting pitfall

PowerShell expands `$(...)`, `$VAR` and `$((...))` inside **double** quotes before the string
reaches WSL. For scripts with variables: run a script file that is already in the mount
(`docker exec azurevpntunnel sh /work/runner.sh`) rather than inlining shell code.
Single-quoted `wsl -d Ubuntu-20.04 -- bash -c '…'` also works (PowerShell leaves the content
untouched — beware of single-quote conflicts inside).

## WSL socket buffer error (0x80072747)

After multiple VPN sessions the WSL2 socket pool can be exhausted. Fix:

```powershell
wsl --shutdown
wsl -d Ubuntu-20.04 -- sudo service docker start
```
