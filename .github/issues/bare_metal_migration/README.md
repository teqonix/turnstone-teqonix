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
| [`deploy_litellm_proxy.sh`](deploy_litellm_proxy.sh) | Load Balancer VM | Dedicated Proxy VM | Idempotently deploys LiteLLM proxy with least-busy routing across Ryzen and Apple Silicon nodes. |
| [`backup_turnstone.sh`](backup_turnstone.sh) | Backup Cron | `silo-14` TrueNAS VM | Runs daily compressed `pg_dump` of all conversation history, settings, and configs into TrueNAS ZFS dataset. |
| [`sync_repo.sh`](sync_repo.sh) | Cluster Sync | Cluster Nodes (`turnstone-postgres.lan`, `turnstone-coordinator-nerd-projects.lan`, `amd-ai-core-one.lan`, `amd-ai-core-two.lan`, `mbp-ai-core.lan`, `litellm-proxy.lan`) | Syncs local turnstone repo copy to LLM cluster nodes via rsync over passwordless SSH. |
| [`set_concurrency_limit.sh`](set_concurrency_limit.sh) | Cluster / Node Config | All Cluster Nodes / Local | Auto-detects installed inference engines and Turnstone configs, setting concurrency limits to 1. |
| [`install_ryzenadj.sh`](install_ryzenadj.sh) | Worker Node (Ryzen) | Ryzen Halo #1 & #2 (Linux) | Fetches, builds, and installs `ryzen_smu` DKMS driver, `ryzenadj`, and sets up `ryzen-tdp.service` systemd unit for persistent boot TDP limits. |



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

### Choosing Your Migration Path (Mutually Exclusive)

There are two distinct migration and restoration paths. **Choose Path A or Path B based on your deployment topology — do NOT combine them:**

```
               ┌─────────────────────────────────────────────────────────┐
               │              Choose Your Migration Strategy             │
               └────────────┬───────────────────────────────┬────────────┘
                            │                               │
                            ▼                               ▼
       ┌────────────────────────────────────────┐ ┌────────────────────────────────────────┐
       │ Path A: Distributed / Dedicated DB     │ │ Path B: All-in-One Compose Migration   │
       │ (Recommended Multi-Node Topology)      │ │ (Single Standalone VM Bundle)          │
       ├────────────────────────────────────────┤ ├────────────────────────────────────────┤
       │ 1. deploy_coordinator.sh (silo-14 VM)  │ │ 1. migrate_from_compose.sh --export    │
       │ 2. restore_postgres.sh (DB Host/VM)    │ │    (Run on old Compose machine)        │
       │ 3. restart console (silo-14 VM)        │ │ 2. scp bundle to silo-14 VM            │
       │ 4. deploy_ryzen_node / deploy_mlx_node │ │ 3. migrate_from_compose.sh --import    │
       │    (Run on each bare-metal worker node)│ │    (Imports DB, Caddy CA, and .env)    │
       └────────────────────────────────────────┘ └────────────────────────────────────────┘
```

---

### Path A: Distributed Architecture & Dedicated Database (Recommended)

Use this path when running a distributed infrastructure with a dedicated central PostgreSQL instance (or embedded coordinator DB) and bare-metal LLM nodes:

#### Step 1: Deploy Coordinator VM on TrueNAS (`silo-14`)
1. SSH into the `silo-14` Coordinator VM and run:
   ```bash
   sudo ./.github/issues/bare_metal_migration/deploy_coordinator.sh
   ```
2. Note the generated credentials and PostgreSQL URL.

#### Step 2: Restore Database Backup (`restore_postgres.sh`)
Run `restore_postgres.sh` on the database host (`turnstone-postgres.lan`) or Coordinator VM:
```bash
./.github/issues/bare_metal_migration/restore_postgres.sh \
  -s .github/issues/bare_metal_migration/secrets/postgres_admin.secret \
  -f .github/issues/bare_metal_migration/db_backup/db/turnstone_db_20260815_130936.sql.gz
```
- **What it does**:
  - Automatically takes a safety backup (`existing_database_backup_${DATE}_${TIME}.sql.gz`).
  - Drops and recreates the `public` schema cleanly to prevent relation/constraint duplicate errors.
  - Imports all conversation history turns, workstreams, prompt templates, users, and tokens.
  - Reassigns table ownership to the application user (`turnstone-np` / `turnstone`).
  - Wipes stale 11-node container metadata so bare-metal nodes register freshly.

#### Step 3: Refresh Coordinator Console Connection Pool
Restart the console container on `silo-14` so its database connection pool binds cleanly to the newly restored schema:
```bash
sudo docker compose -f /opt/turnstone-coordinator/docker-compose.yml restart console
```

#### Step 4: Deploy & Register Bare-Metal Worker Nodes
Run the node scripts on each respective machine:
```bash
# On AMD Ryzen AI Halo #1 (amd-ai-core-one.lan):
NODE_ID="ryzen-halo-1" sudo -E ./.github/issues/bare_metal_migration/deploy_ryzen_node.sh

# On AMD Ryzen AI Halo #2 (amd-ai-core-two.lan):
NODE_ID="ryzen-halo-2" sudo -E ./.github/issues/bare_metal_migration/deploy_ryzen_node.sh

# On Apple Silicon M5 Max (mbp-ai-core.lan):
./.github/issues/bare_metal_migration/deploy_mlx_node.sh
```

---

### Path B: All-in-One Standalone Compose Migration (`migrate_from_compose.sh`)

Use this path only if you are migrating a standalone self-contained Docker Compose stack (including local Caddy CA root certificates, `.env` secrets, and database dump) onto a single all-in-one Coordinator VM:

1. **Export on Current Docker Compose Host**:
   ```bash
   ./.github/issues/bare_metal_migration/migrate_from_compose.sh --export
   ```
   *Output*: Creates a compressed migration bundle, e.g. `turnstone_migration_bundle_20260812_211111.tar.gz`.

2. **Transfer Bundle to `silo-14`**:
   ```bash
   scp turnstone_migration_bundle_*.tar.gz user@silo-14:/tmp/
   ```

3. **Import on Standalone Coordinator VM (`silo-14`)**:
   ```bash
   sudo ./.github/issues/bare_metal_migration/migrate_from_compose.sh --import /tmp/turnstone_migration_bundle_*.tar.gz
   ```
   *Output*: Restores environment secrets, Caddy CA keys, imports the database dump, and automatically purges old compose container node metadata.

> [!NOTE]
> Do not execute `migrate_from_compose.sh --import` after running `restore_postgres.sh`. `migrate_from_compose.sh` is an all-in-one standalone importer, whereas `restore_postgres.sh` is for direct database-level restoration in the distributed architecture.

---

## Verification & Health Checks

1. **Dashboard Access**:
   Open browser at `https://silo-14:9443` (or `http://turnstone-coordinator-nerd-projects.lan:8090`). Confirm all conversation history turns and workstreams load cleanly.
2. **Node Heartbeat Status**:
   In the Dashboard under **Nodes** (and the top-left Cluster status counter), confirm active worker nodes (`ryzen-halo-1`, `ryzen-halo-2`, `mbp-ai-core`) show as `idle` with green heartbeats and auto-detected hardware metadata.
3. **Decommission Old Instance**:
   Once verified, stop the local docker compose service:
   ```bash
   systemctl --user disable --now turnstone.service
   ```
