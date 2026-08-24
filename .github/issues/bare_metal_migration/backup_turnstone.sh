#!/usr/bin/env bash
# =============================================================================
# Turnstone Cluster Backup Script (TrueNAS silo-14 / Coordinator VM)
#
# Idempotent script for automated daily backups of:
# 1. Complete PostgreSQL database (conversations, workstreams, turns, settings)
# 2. Coordinator secrets and container configuration
# 3. Node configurations across the cluster
# 4. Retention policy (prunes database backups older than 30 days)
# =============================================================================

set -euo pipefail

# Configuration
BACKUP_DIR="${BACKUP_DIR:-./db_backup/}"
COORDINATOR_DIR="/home/teqonix/nerd_projects/turnstone"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RETENTION_DAYS=30
POSTGRES_USER=turnstone

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

trap 'log_error "Backup job failed at line $LINENO!"; exit 1' ERR

echo -e "${BLUE}=================================================================${NC}"
echo -e "${BLUE}        Turnstone Automated Daily Backup Job                     ${NC}"
echo -e "${BLUE}=================================================================${NC}"

# Step 1: Ensure Backup Target Directory Exists
log_info "Step 1: Verifying backup target directory at ${BACKUP_DIR}..."
mkdir -p "${BACKUP_DIR}/db"
mkdir -p "${BACKUP_DIR}/config"
log_success "Backup directories verified."

# Step 2: Database Backup (Full PostgreSQL dump including conversation history)
log_info "Step 2: Performing PostgreSQL dump (including conversations, turns, settings)..."
ENV_FILE="${COORDINATOR_DIR}/.env"
if [ ! -f "${ENV_FILE}" ]; then
    log_error "Coordinator environment file not found at ${ENV_FILE}."
    exit 1
fi

source "${ENV_FILE}"
DB_DUMP_FILE="${BACKUP_DIR}/db/turnstone_db_${TIMESTAMP}.sql.gz"

docker compose -f "${COORDINATOR_DIR}/compose.yaml" exec -T postgres \
    pg_dump -U "${POSTGRES_USER}" turnstone | gzip -9 > "${DB_DUMP_FILE}"

log_success "Database successfully backed up to ${DB_DUMP_FILE} ($(du -h "${DB_DUMP_FILE}" | awk '{print $1}'))."

# Step 3: Backup Coordinator Configs & Environment Secrets
log_info "Step 3: Backing up Coordinator configuration files..."
CONFIG_TAR="${BACKUP_DIR}/config/coordinator_config_${TIMESTAMP}.tar.gz"

tar -czf "${CONFIG_TAR}" -C "${COORDINATOR_DIR}" .env compose.yaml
chmod 600 "${CONFIG_TAR}"
log_success "Coordinator configuration backed up to ${CONFIG_TAR}."

# Step 4: Prune Old Backups (Retention Policy)
log_info "Step 4: Applying retention policy (purging backups older than ${RETENTION_DAYS} days)..."
find "${BACKUP_DIR}/db" -type f -name "turnstone_db_*.sql.gz" -mtime +${RETENTION_DAYS} -delete
find "${BACKUP_DIR}/config" -type f -name "coordinator_config_*.tar.gz" -mtime +${RETENTION_DAYS} -delete
log_success "Retention policy applied."

echo -e "${GREEN}=================================================================${NC}"
echo -e "${GREEN}  Turnstone Daily Backup Completed Successfully!                 ${NC}"
echo -e "${GREEN}=================================================================${NC}"
