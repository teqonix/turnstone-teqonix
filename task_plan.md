# Task Plan: Bare-Metal Migration Deployment Updates

> **Bookmark:** `bare-metal-migration-updates` (based on `local-bare-metal-install`)
> **Project root:** `/home/turnstone/nerd_projects/turnstone-teqonix/`
> **Scripts dir:** `.github/issues/bare_metal_migration/`
> **Pattern:** planning-with-files (keep `task_plan.md`, `findings.md`, `progress.md` in sync)

## Objective

Refactor the bare-metal deployment scripts so that the hardware LLM nodes act
**only** as LLM inference servers, and the Turnstone node role moves to a
dedicated **Debian 12 container**. Document the resulting cluster architecture.

## Work Items

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | Create `jj` bookmark `bare-metal-migration-updates` on `local-bare-metal-install` | ✅ Done | Created at working copy after rebase |
| 2 | Initialize planning files (`task_plan.md`, `findings.md`, `progress.md`) | ✅ Done | In project root |
| 3 | `deploy_ryzen_node.sh`: remove Turnstone-node install sections | ✅ Done | Rewrote to inference-only (ryzenadj + Lemonade health); dropped Steps 4–9 |
| 4 | `deploy_mlx_node.sh`: remove Turnstone-node install sections | ✅ Done | Kept MLX+Ollama inference; dropped turnstone pkg, config.toml, `com.turnstone.server`, port-8080 health |
| 5 | Create `deploy_turnstone_debian12.sh` (Turnstone node on fresh Debian 12 container) | ✅ Done | Container-adapted from Ryzen Turnstone logic; foreground entrypoint + optional systemd |
| 6 | Update `README.md` with cluster architecture diagram + participant descriptions | ✅ Done | Mermaid diagram + participant table + step 5 |
| 7 | Commit all changes to `bare-metal-migration-updates` | ⏳ In progress | Atomic commits; strip exec bit from non-scripts |

## Acceptance Criteria

- [ ] `deploy_ryzen_node.sh` no longer installs the `turnstone` package, does not
      create a `turnstone-server` systemd unit, and does not write `/etc/turnstone/config.toml`.
- [ ] `deploy_mlx_node.sh` no longer installs the Turnstone node (no `turnstone-server`
      launchd daemon, no turnstone venv install). MLX + Ollama inference remain.
- [ ] `deploy_turnstone_debian12.sh` exists, is executable, and installs a full
      Turnstone node (user, venv, config, storage) on a fresh Debian 12 container.
- [ ] `README.md` has a clear architecture diagram and participant descriptions.
- [ ] All changes committed to `bare-metal-migration-updates`.
- [ ] Non-script files (README.md, planning files) are NOT executable; `.sh` scripts ARE.

## Out of Scope

- Modifying `deploy_coordinator.sh` (TrueNAS coordinator) — unchanged.
- Changing the LLM inference engines themselves (Lemonade / MLX / Ollama).
