# Turnstone Bare-Metal & TrueNAS Coordinator Migration Guide

This directory contains the complete deployment and migration tooling for transitioning Turnstone from a single-host Docker Compose setup to a distributed, multi-node infrastructure.

---

## Infrastructure Overview

```
                          ┌────────────────────────────────────────────────────────┐
                          │         Coordinator Server: silo-14 (TrueNAS VM)       │
                          │  - 4 vCPUs, 10 GB RAM, 200 GB NVMe                     │
                          │  - PostgreSQL 18 (Port 5432)                           │
                          │  - turnstone-console UI / ACME CA (Port 8090 / 9443)   │
                          │  - Caddy HTTPS Reverse Proxy                           │
                          │  - SearxNG Metasearch Engine (Port 8081)               │
                          └───────────────────────────┬────────────────────────────┘
                                                      │
             ┌────────────────────────────────────────┼────────────────────────────────────────┐
             │                                        │                                        │
             ▼                                        ▼                                        ▼
┌──────────────────────────┐             ┌──────────────────────────┐             ┌──────────────────────────┐
│  LLM Node 1: M5 Max MBP  │             │ LLM Node 2: Ryzen Halo 1 │             │ LLM Node 3: Ryzen Halo 2 │
│ - Engine: Apple MLX      │             │ - Engine: Lemonade ROCm  │             │ - Engine: Lemonade ROCm  │
│ - Model: qwen3-coder-next│             │ - Model: gemma-4-31b     │             │ - Model: nemotron-3-nano │
│ - Context: 384k Tokens   │             │ - Context: 384k Tokens   │             │ - Context: 384k Tokens   │
│ - Role: Burst Coding     │             │ - Role: Orchestrator     │             │ - Role: Judge / Eval     │
└──────────────────────────┘             └──────────────────────────┘             └──────────────────────────┘
```

---

## Script Inventory

| Script | Location | Host Target | Description |
|--------|----------|-------------|-------------|
| [`deploy_coordinator.sh`](deploy_coordinator.sh) | Coordinator | `silo-14` TrueNAS VM | Deploys PostgreSQL 18, Console UI, Caddy, Channel, and SearxNG containers. |
| [`install_postgres.sh`](install_postgres.sh) | Database Host | Debian VM / Host | Installs and configures PostgreSQL on a Debian VM for remote connections. |
| [`add_coordinator_user.sh`](add_coordinator_user.sh) | Database Host | Debian VM / Host | Provisions a new coordinator DB user (e.g. `turnstone-megamul`), grants shared `turnstone_app_group` DDL & migration privileges, and outputs a `.secret` file. |
| [`restore_postgres.sh`](restore_postgres.sh) | Migration | Database Host | Restores Turnstone PostgreSQL backup (.sql, .sql.gz, .dump) to an existing PostgreSQL database. |
| [`migrate_from_compose.sh`](migrate_from_compose.sh) | Migration | Local Host & `silo-14` | Exports database (19,944+ turns), Caddy CA root keys, and secrets (`--export`), then imports them onto `silo-14` (`--import`). |
| [`deploy_mlx_node.sh`](deploy_mlx_node.sh) | Worker Node | `mbp-ai-core.lan` (M5 Max) | Sets up Apple MLX (`mlx-lm.server`) with 384k context and installs macOS `launchd` service. |
| [`deploy_ryzen_node.sh`](deploy_ryzen_node.sh) | Worker Node | Ryzen Halo #1 & #2 (Linux) | Installs `turnstone-server` virtualenv, configures secrets, and starts systemd service. |
| [`backup_turnstone.sh`](backup_turnstone.sh) | Backup Cron | `silo-14` TrueNAS VM | Runs daily compressed `pg_dump` of all conversation history, settings, and configs into TrueNAS ZFS dataset. |
| [`sync_repo.sh`](../../../scripts/sync_repo.sh) | Cluster Sync | Cluster Nodes (`turnstone-postgres.lan`, `turnstone-coordinator-nerd-projects.lan`) | Syncs local turnstone repo copy to LLM cluster nodes via rsync over passwordless SSH. |


---

## Step-by-Step Migration Guide

### Phase 1: Deploy Coordinator VM on TrueNAS (`silo-14`)

1. Provision a Linux VM on TrueNAS `silo-14`:
   - **vCPUs**: 4
   - **RAM**: 10 GB
   - **Storage**: 200 GB NVMe
2. SSH into the `silo-14` VM and run the coordinator deployment script:
   ```bash
   sudo ./.github/issues/bare_metal_migration/deploy_coordinator.sh
   ```
3. Save the printed output credentials:
   - **JWT Secret**: `TURNSTONE_JWT_SECRET`
   - **Postgres Password**: `POSTGRES_PASSWORD`

---

### Phase 2: Export & Import Existing Docker Compose Data

1. **Export on Current Host**:
   Run the migration export command on your current Docker Compose machine:
   ```bash
   ./.github/issues/bare_metal_migration/migrate_from_compose.sh --export
   ```
   *Output*: Creates a compressed migration bundle, e.g. `turnstone_migration_bundle_20260812_211111.tar.gz` containing all 19,944 conversation turns, 234 workstreams, and Caddy CA root keys.

2. **Transfer Bundle to `silo-14`**:
   ```bash
   scp turnstone_migration_bundle_*.tar.gz user@silo-14:/tmp/
   ```

3. **Import on Coordinator VM (`silo-14`)**:
   SSH into `silo-14` and run:
   ```bash
   sudo ./.github/issues/bare_metal_migration/migrate_from_compose.sh --import /tmp/turnstone_migration_bundle_*.tar.gz
   ```
   *Output*: Restores environment secrets, Caddy CA keys, imports PostgreSQL dump, and verifies turn and workstream counts.

---

### Phase 3: Deploy LLM Node 1 (M5 Max MacBook Pro)

Run on `mbp-ai-core.lan`:
```bash
./.github/issues/bare_metal_migration/deploy_mlx_node.sh
```
- Interactive prompts will ask for `COORDINATOR_IP`, `JWT_SECRET`, and `POSTGRES_PASSWORD`.
- Launches `mlx-lm.server` with 384k context window on port `8080` and registers `turnstone-server` via `launchd`.

---

### Phase 4: Deploy LLM Nodes 2 & 3 (AMD Ryzen AI Halo #1 & #2)

Run on each Ryzen box:
```bash
# On Ryzen Halo #1 (Orchestrator):
NODE_ID="ryzen-halo-1" sudo -E ./.github/issues/bare_metal_migration/deploy_ryzen_node.sh

# On Ryzen Halo #2 (Judge):
NODE_ID="ryzen-halo-2" sudo -E ./.github/issues/bare_metal_migration/deploy_ryzen_node.sh
```
- Installs `/etc/turnstone/config.toml` (chmod 0600) and starts `/etc/systemd/system/turnstone-server.service`.

---

### Phase 5: Configure Automated Daily ZFS Backups

On `silo-14` Coordinator VM, install a crontab entry for daily backups at `02:00 AM`:
```bash
(crontab -l 2>/dev/null; echo "0 2 * * * /bin/bash /path/to/.github/issues/bare_metal_migration/backup_turnstone.sh >> /var/log/turnstone_backup.log 2>&1") | crontab -
```

---

## Verification & Health Checks

1. **Dashboard Access**:
   Open browser at `https://silo-14:9443`. Confirm all 19,944 conversation history turns load cleanly.
2. **Node Heartbeat Status**:
   In the Dashboard under **Nodes**, confirm `mbp-ai-core`, `ryzen-halo-1`, and `ryzen-halo-2` display active heartbeats.
3. **Decommission Old Instance**:
   Once verified, stop the local docker compose service:
   ```bash
   systemctl --user disable --now turnstone.service
   ```
