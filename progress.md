# Progress Log

> Chronological log of actions. Newest at the bottom.

## 2026-08-27

- [04:37] **Env & planning**
  - Inspected repo + both deployment scripts.
  - Backed up working copy to `/tmp/tq_wc_backup_1787801877.tar.gz`.
  - Committed uncommitted changes (litellm unified proxy + coordinator setup).
  - Rebased working copy onto `local-bare-metal-install` (clean).
  - Created bookmark `bare-metal-migration-updates` at working copy.
  - Initialized `task_plan.md`, `findings.md`, `progress.md`.
- [04:43] **`deploy_ryzen_node.sh`** — rewrote to inference-only. Removed:
  - Turnstone system-user creation, `/opt/turnstone-venv` + `turnstone` pkg install,
    Homebrew/all-smi, Rust/jj, `/etc/turnstone/config.toml`, SMB/fstab mount,
    `turnstone-server.service` systemd unit + enable/restart + health.
  - Kept: ryzenadj TDP, Lemonade `:8000/v1` health check. `bash -n` passes.
- [04:50] **`deploy_mlx_node.sh`** — removed Turnstone-node side:
  - Dropped `turnstone` pkg install, `~/.config/turnstone/config.toml`,
    `com.turnstone.server` launchd daemon, port-8080 health check, `turnstone-server` symlink.
  - Kept: MLX server + Ollama daemons, mlx-lm wrapper, model pulls, all-smi, 8000/11434 health.
  - Renamed venv to `inference-venv`; `bash -n` passes.
- [04:58] **`deploy_turnstone_debian12.sh`** — created (new). Container-adapted Turnstone node:
  - user + `/opt/turnstone-venv` + `turnstone` pkg + `/etc/turnstone/config.toml` + SMB mount,
    optional Homebrew/all-smi + Rust/jj (skippable), entrypoint wrapper, foreground exec
    (container) OR systemd unit (host). `bash -n` passes; `chmod +x` applied.
- [05:0x] **`README.md`** — added Mermaid cluster architecture + participant table
  (Ryzen/MLX = inference, Debian 12 = Turnstone node, TrueNAS = coordinator),
  updated script inventory + added Step 5 (deploy Turnstone node) + verification note.
- [pending] Commit to `bare-metal-migration-updates`; verify file modes (non-scripts not executable).
