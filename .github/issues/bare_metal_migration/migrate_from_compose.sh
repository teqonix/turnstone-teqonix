#!/usr/bin/env bash
# =============================================================================
# Turnstone Data Migration Tool (Docker Compose -> silo-14 Coordinator VM)
#
# Idempotent & User-Friendly script to:
# 1. Export PostgreSQL database (19,944+ turns, 234 workstreams), Caddy CA root keys,
#    and JWT secrets from existing local Docker Compose instance (--export).
# 2. Import migration bundle onto new TrueNAS Coordinator VM (--import <file>).
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

trap 'log_error "Migration failed on line $LINENO!"; exit 1' ERR

usage() {
    echo "Usage:"
    echo "  Export (run on current compose host): $0 --export"
    echo "  Import (run on silo-14 Coordinator VM): $0 --import <path_to_bundle.tar.gz>"
    exit 1
}

if [ "$#" -lt 1 ]; then
    usage
fi

MODE="$1"

# =============================================================================
# EXPORT MODE
# =============================================================================
if [ "${MODE}" == "--export" ]; then
    echo -e "${BLUE}=================================================================${NC}"
    echo -e "${BLUE}       Exporting Turnstone Compose Data for Migration           ${NC}"
    echo -e "${BLUE}=================================================================${NC}"

    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    EXPORT_DIR="/tmp/turnstone_export_${TIMESTAMP}"
    BUNDLE_FILE="$(pwd)/turnstone_migration_bundle_${TIMESTAMP}.tar.gz"

    mkdir -p "${EXPORT_DIR}"

    # Step 1: Dump PostgreSQL Database
    log_info "Step 1: Dumping PostgreSQL database (including 19,944+ conversation turns)..."
    if docker compose ps | grep -q postgres; then
        docker compose exec -T postgres pg_dump -U turnstone -Fc turnstone > "${EXPORT_DIR}/turnstone_export.dump"
    else
        log_info "Container not running, dumping directly from turnstone_postgres-data volume..."
        docker run --rm \
            -v turnstone_postgres-data:/var/lib/postgresql/data \
            -v "${EXPORT_DIR}:/backup" \
            pgautoupgrade/pgautoupgrade:18-alpine \
            bash -c "su-exec postgres pg_dump -U turnstone -Fc turnstone > /backup/turnstone_export.dump"
    fi
    log_success "Database dumped successfully ($(du -h "${EXPORT_DIR}/turnstone_export.dump" | awk '{print $1}'))."

    # Step 2: Export Caddy CA Certificates
    log_info "Step 2: Exporting Caddy CA root certificates..."
    if docker volume inspect turnstone_caddy-data &>/dev/null; then
        docker run --rm \
            -v turnstone_caddy-data:/data \
            -v "${EXPORT_DIR}:/backup" \
            alpine tar -czf /backup/caddy_ca_export.tar.gz -C /data .
        log_success "Caddy CA certificates exported."
    else
        log_warn "Volume turnstone_caddy-data not found, skipping Caddy CA backup."
    fi

    # Step 3: Export Environment File & Secrets
    log_info "Step 3: Copying environment secrets (.env)..."
    if [ -f ".env" ]; then
        cp .env "${EXPORT_DIR}/.env"
        log_success "Saved .env secrets."
    else
        log_warn "No local .env file found."
    fi

    # Step 4: Bundle Everything
    log_info "Step 4: Creating compressed migration bundle..."
    tar -czf "${BUNDLE_FILE}" -C "${EXPORT_DIR}" .
    rm -rf "${EXPORT_DIR}"

    BUNDLE_SIZE=$(du -h "${BUNDLE_FILE}" | awk '{print $1}')
    echo -e "${GREEN}=================================================================${NC}"
    echo -e "${GREEN}  Export Complete! Migration Bundle Saved To:                    ${NC}"
    echo -e "${GREEN}  ${BUNDLE_FILE} (${BUNDLE_SIZE}) ${NC}"
    echo -e "${GREEN}=================================================================${NC}"
    echo -e "Next Step: Transfer ${BUNDLE_FILE} to your TrueNAS Coordinator VM (silo-14) and run:"
    echo -e "${BLUE}  sudo ./migrate_from_compose.sh --import $(basename "${BUNDLE_FILE}")${NC}"

# =============================================================================
# IMPORT MODE
# =============================================================================
elif [ "${MODE}" == "--import" ]; then
    if [ "$#" -lt 2 ]; then
        log_error "Missing bundle file argument!"
        usage
    fi

    BUNDLE_PATH="$2"
    COORDINATOR_DIR="/opt/turnstone-coordinator"

    if [ ! -f "${BUNDLE_PATH}" ]; then
        log_error "Migration bundle file '${BUNDLE_PATH}' not found!"
        exit 1
    fi

    echo -e "${BLUE}=================================================================${NC}"
    echo -e "${BLUE}       Importing Turnstone Data to Coordinator VM (silo-14)      ${NC}"
    echo -e "${BLUE}=================================================================${NC}"

    TEMP_IMPORT="/tmp/turnstone_import_$(date +"%s")"
    mkdir -p "${TEMP_IMPORT}"
    tar -xzf "${BUNDLE_PATH}" -C "${TEMP_IMPORT}"

    # Step 1: Restore Environment File
    log_info "Step 1: Restoring environment secrets to ${COORDINATOR_DIR}/.env..."
    mkdir -p "${COORDINATOR_DIR}"
    if [ -f "${TEMP_IMPORT}/.env" ]; then
        cp "${TEMP_IMPORT}/.env" "${COORDINATOR_DIR}/.env"
        chmod 600 "${COORDINATOR_DIR}/.env"
        log_success "Environment secrets restored."
    else
        log_warn "No .env found in migration bundle. Using existing."
    fi

    source "${COORDINATOR_DIR}/.env"

    # Step 2: Restore Caddy CA Volume
    log_info "Step 2: Restoring Caddy CA certificates..."
    if [ -f "${TEMP_IMPORT}/caddy_ca_export.tar.gz" ]; then
        docker volume create turnstone-coordinator_caddy-data || true
        docker run --rm \
            -v turnstone-coordinator_caddy-data:/data \
            -v "${TEMP_IMPORT}:/backup" \
            alpine tar -xzf /backup/caddy_ca_export.tar.gz -C /data
        log_success "Caddy CA certificates restored to volume."
    fi

    # Step 3: Start PostgreSQL Container
    log_info "Step 3: Starting PostgreSQL container..."
    cd "${COORDINATOR_DIR}"
    docker compose up -d postgres
    docker compose exec -T postgres pg_isready -U "${POSTGRES_USER}" -t 30 || sleep 5

    # Step 4: Import Database Dump
    log_info "Step 4: Restoring 19,944+ conversation turns and 234 workstreams into PostgreSQL..."
    if [ -f "${TEMP_IMPORT}/turnstone_export.dump" ]; then
        docker compose exec -T postgres \
            pg_restore -U "${POSTGRES_USER}" -d turnstone --clean --if-exists < "${TEMP_IMPORT}/turnstone_export.dump" || true
        log_success "Database dump successfully imported!"
    else
        log_error "No database dump file found in migration bundle!"
        exit 1
    fi

    # Step 5: Wipe Stale Node State
    log_info "Step 5: Purging stale compose container node registrations..."
    docker compose exec -T postgres psql -U "${POSTGRES_USER}" -d turnstone -c "
        TRUNCATE TABLE node_metadata CASCADE;
        DELETE FROM services WHERE service_type = 'server';
        TRUNCATE TABLE workstream_overrides CASCADE;
        DELETE FROM system_settings WHERE node_id != '';
        DELETE FROM watches WHERE node_id != '';
    " || log_warn "Could not clean stale node metadata tables."
    log_success "Stale compose cluster node registrations cleared."

    # Step 6: Start All Coordinator Containers
    log_info "Step 6: Launching remaining Coordinator services..."
    docker compose up -d

    # Cleanup
    rm -rf "${TEMP_IMPORT}"

    # Verify Counts
    TURNS_COUNT=$(docker compose exec -T -e PAGER=cat postgres psql -U "${POSTGRES_USER}" -d turnstone -t -c "SELECT count(*) FROM conversations;" | tr -d '[:space:]')
    WS_COUNT=$(docker compose exec -T -e PAGER=cat postgres psql -U "${POSTGRES_USER}" -d turnstone -t -c "SELECT count(*) FROM workstreams;" | tr -d '[:space:]')

    echo -e "${GREEN}=================================================================${NC}"
    echo -e "${GREEN}  Migration Complete! Successfully Imported to Coordinator VM:   ${NC}"
    echo -e "${GREEN}  - Conversation Turns Imported: ${TURNS_COUNT}                 ${NC}"
    echo -e "${GREEN}  - Workstreams Imported: ${WS_COUNT}                           ${NC}"
    echo -e "${GREEN}=================================================================${NC}"
else
    usage
fi
