# Findings

## Repository / jj State

- jj version: `0.44.0-...`.
- `local-bare-metal-install` → `zlpuxxmp 29caa464` "Enhance LLM cluster proxy with
  Mac prioritization and model cooldown logic".
- Working copy was on `sstnokxy` "Add secret file parsing to Ryzen deployment script"
  with **uncommitted** changes (litellm unified proxy + coordinator setup).
- The two commits were **divergent** (neither ancestor of the other).
- Action taken: committed the uncommitted changes, then `jj rebase -d local-bare-metal-install`
  (clean, no conflicts). Created bookmark `bare-metal-migration-updates` at the working copy.
- A full working-copy tarball backup was written to `/tmp/tq_wc_backup_*.tar.gz` before rebase.

## `deploy_ryzen_node.sh` structure (AMD Ryzen AI Halo, Linux/systemd)

- **Inference side (KEEP):**
  - Step 3 — `ryzenadj` power-management utility (TDP).
  - Assumes a **local Lemonade** model server already runs at `LEMONADE_URL`
    (default `http://127.0.0.1:8000/v1`); the script does not start it.
- **Turnstone-node side (REMOVE):**
  - Step 4 — create `turnstone` system user + home + mount point.
  - Step 5 / 5b / 5c — uv venv at `/opt/turnstone-venv`, install `turnstone` pkg,
    Homebrew + `all-smi`, Rust/Cargo + Jujutsu.
  - Step 6 — write `/etc/turnstone/config.toml` (jwt, db, api→Lemonade).
  - Step 7 — SMB credentials + fstab automount + `/data` `/workspace` symlinks.
  - Step 8 — `turnstone-server.service` systemd unit + `node.conf` drop-in.
  - Step 9 — enable/restart `turnstone-server.service`, health check.

## `deploy_mlx_node.sh` structure (Apple M5 Max, macOS/launchd)

- **Inference side (KEEP):**
  - Step 2 — Python + uv.
  - Step 3a — `mlx-lm` CLI wrapper.
  - Step 3b — Homebrew + `all-smi` + **Ollama**.
  - Step 6 — `com.turnstone.mlx-server` daemon (MLX server, port 8000).
  - Step 6b — `com.turnstone.ollama` daemon (port 11434).
  - Step 6c — model downloads (HF MLX + Ollama pulls).
  - Step 8 (partial) — health checks for MLX (8000) + Ollama (11434).
- **Turnstone-node side (REMOVE):**
  - `turnstone` package install (in Step 3 venv install line).
  - Step 4 — `~/.config/turnstone/config.toml`.
  - Step 7 — `com.turnstone.server` launchd daemon (port 8080).
  - Step 8 (partial) — Turnstone Server (8080) health check.
  - `turnstone-server` symlink in the Step 3 bin loop.

## `deploy_turnstone_debian12.sh` (NEW)

- Target: a **fresh Debian 12 container** acting as the Turnstone node.
- Template: the Turnstone-node logic from `deploy_ryzen_node.sh` (Steps 4–9).
- Container-friendly adaptations:
  - No `systemd` (containers usually don't run a PID-1 init) → run
    `turnstone-server` as the foreground process / provide an entrypoint.
  - Keep: user creation, uv venv, `turnstone` install, `/etc/turnstone/config.toml`,
    SMB/CIFS mount (or bind mount), `all-smi` optional.
  - Idempotent + `set -euo pipefail`.

## README architecture

- **Ryzen Nodes** → LLM inference (Lemonade).
- **MLX Node** → LLM inference (MLX server + Ollama).
- **Debian 12 Container** → Turnstone node (registers with coordinator, proxies LLM).
- **Coordinator (TrueNAS VM)** → Turnstone coordinator (console :8090, searxng :8081, Postgres).
