#!/usr/bin/env bash
# =============================================================================
# Turnstone Debian PostgreSQL Server Installation & Setup Script
#
# Idempotent & User-Friendly script to:
# 1. Install and configure PostgreSQL on a Debian/Ubuntu VM.
# 2. Configure network listening (listen_addresses = '*') and remote auth (scram-sha-256).
# 3. Create/set the 'postgres' admin user password and save to /etc/turnstone/postgres_admin.env.
# 4. Optionally import a database dump (e.g. exported by backup_turnstone.sh).
# =============================================================================

set -euo pipefail

# Color Codes for Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

trap 'log_error "An error occurred on line $LINENO. PostgreSQL setup stopped."; exit 1' ERR

IMPORT_BACKUP_FILE=""

# Parse Command Line Flags
while [[ $# -gt 0 ]]; do
    case $1 in
        --import-backup)
            IMPORT_BACKUP_FILE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: sudo $0 [--import-backup <path_to_dump.sql.gz|path_to_dump.sql>]"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Usage: sudo $0 [--import-backup <path_to_dump.sql.gz>]"
            exit 1
            ;;
    esac
done

echo -e "${BLUE}=================================================================${NC}"
echo -e "${BLUE}       Turnstone PostgreSQL Debian VM Setup & Configuration      ${NC}"
echo -e "${BLUE}=================================================================${NC}"

# Step 1: Root / Sudo Check
log_info "Step 1: Checking permissions..."
if [ "$EUID" -ne 0 ]; then
    log_warn "This script must be run with sudo or as root to configure system packages and PostgreSQL."
    log_warn "Re-running with sudo..."
    exec sudo bash "$0" "$@"
fi
log_success "Permissions verified."

# Step 2: Install PostgreSQL Packages
log_info "Step 2: Installing PostgreSQL packages via apt..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq postgresql postgresql-contrib curl gzip ca-certificates > /dev/null
systemctl enable --now postgresql
log_success "PostgreSQL service enabled and active."

# Step 3: Locate Configuration Files
PG_VERSION=$(psql --version | awk '{print $3}' | cut -d'.' -f1)
PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/main"

if [ ! -d "${PG_CONF_DIR}" ]; then
    # Fallback search for PostgreSQL config directory
    PG_CONF_DIR=$(find /etc/postgresql -name "postgresql.conf" | head -n 1 | xargs dirname || true)
fi

if [ -z "${PG_CONF_DIR}" ] || [ ! -f "${PG_CONF_DIR}/postgresql.conf" ]; then
    log_error "Could not locate postgresql.conf. Please check PostgreSQL installation."
    exit 1
fi

log_info "Detected PostgreSQL version ${PG_VERSION} at ${PG_CONF_DIR}."

# Step 4: Configure Network Listening & Remote Auth
log_info "Step 4: Configuring network listening, authentication, and shared memory..."

# Enable listening on all network interfaces
if grep -q "^#listen_addresses =" "${PG_CONF_DIR}/postgresql.conf"; then
    sed -i "s/^#listen_addresses =.*/listen_addresses = '*'/" "${PG_CONF_DIR}/postgresql.conf"
elif grep -q "^listen_addresses =" "${PG_CONF_DIR}/postgresql.conf"; then
    sed -i "s/^listen_addresses =.*/listen_addresses = '*'/" "${PG_CONF_DIR}/postgresql.conf"
else
    echo "listen_addresses = '*'" >> "${PG_CONF_DIR}/postgresql.conf"
fi

# Configure dynamic_shared_memory_type = sysv to prevent POSIX /dev/shm file missing errors
if grep -q "^#dynamic_shared_memory_type =" "${PG_CONF_DIR}/postgresql.conf"; then
    sed -i "s/^#dynamic_shared_memory_type =.*/dynamic_shared_memory_type = sysv/" "${PG_CONF_DIR}/postgresql.conf"
elif grep -q "^dynamic_shared_memory_type =" "${PG_CONF_DIR}/postgresql.conf"; then
    sed -i "s/^dynamic_shared_memory_type =.*/dynamic_shared_memory_type = sysv/" "${PG_CONF_DIR}/postgresql.conf"
else
    echo "dynamic_shared_memory_type = sysv" >> "${PG_CONF_DIR}/postgresql.conf"
fi

# Ensure /dev/shm permissions are correct
chmod 1777 /dev/shm 2>/dev/null || true

# Disable systemd RemoveIPC to prevent systemd from deleting Postgres IPC shared memory segments
if [ -f "/etc/systemd/logind.conf" ]; then
    if grep -q "^#RemoveIPC=" /etc/systemd/logind.conf; then
        sed -i "s/^#RemoveIPC=.*/RemoveIPC=no/" /etc/systemd/logind.conf
    elif grep -q "^RemoveIPC=" /etc/systemd/logind.conf; then
        sed -i "s/^RemoveIPC=.*/RemoveIPC=no/" /etc/systemd/logind.conf
    else
        echo "RemoveIPC=no" >> /etc/systemd/logind.conf
    fi
    systemctl restart systemd-logind 2>/dev/null || true
fi

# Update pg_hba.conf to allow password-authenticated connections from any remote host
HBA_FILE="${PG_CONF_DIR}/pg_hba.conf"
if ! grep -q "0.0.0.0/0" "${HBA_FILE}"; then
    echo "" >> "${HBA_FILE}"
    echo "# Turnstone Coordinator Remote Connections" >> "${HBA_FILE}"
    echo "host    all             all             0.0.0.0/0               scram-sha-256" >> "${HBA_FILE}"
fi

systemctl restart postgresql
log_success "PostgreSQL configured and restarted successfully."

# Step 5: Admin User Password Configuration
log_info "Step 5: Setting up PostgreSQL superuser admin password..."

ADMIN_ENV_FILE="/etc/turnstone/postgres_admin.env"
mkdir -p /etc/turnstone
chmod 700 /etc/turnstone

if [ -f "${ADMIN_ENV_FILE}" ]; then
    log_info "Existing admin credentials file found at ${ADMIN_ENV_FILE}."
    source "${ADMIN_ENV_FILE}"
else
    if [ -n "${POSTGRES_ADMIN_PASS:-}" ]; then
        ADMIN_PASS="${POSTGRES_ADMIN_PASS}"
    else
        echo -e "${YELLOW}Generate random admin password or enter custom password below:${NC}"
        read -r -s -p "Enter PostgreSQL Admin ('postgres') Password [leave blank to auto-generate]: " USER_ADMIN_PASS
        echo ""
        if [ -z "${USER_ADMIN_PASS}" ]; then
            ADMIN_PASS=$(python3 -c "import secrets; print(secrets.token_hex(24))" 2>/dev/null || openssl rand -hex 24)
            log_info "Auto-generated secure admin password."
        else
            ADMIN_PASS="${USER_ADMIN_PASS}"
        fi
    fi

    # Set postgres password in PostgreSQL database
    sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '${ADMIN_PASS}';" > /dev/null

    # Save to admin credentials file
    cat > "${ADMIN_ENV_FILE}" <<EOF
# Turnstone Central PostgreSQL Admin Credentials
POSTGRES_ADMIN_USER=postgres
POSTGRES_ADMIN_PASS=${ADMIN_PASS}
POSTGRES_PORT=5432
EOF
    chmod 600 "${ADMIN_ENV_FILE}"
    log_success "PostgreSQL admin password set and saved to ${ADMIN_ENV_FILE}."
fi

# Step 6: Optional Database Backup Import
log_info "Step 6: Checking for database backup import..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESTORE_SCRIPT="${SCRIPT_DIR}/restore_postgres.sh"

if [ -z "${IMPORT_BACKUP_FILE}" ]; then
    echo ""
    read -r -p "Do you want to import an existing database dump (e.g. from backup_turnstone.sh)? [y/N]: " RESP_IMPORT
    if [[ "${RESP_IMPORT}" =~ ^[Yy]$ ]]; then
        read -r -p "Enter full path to backup file (.sql, .sql.gz, or .dump): " IMPORT_BACKUP_FILE
    fi
fi

if [ -n "${IMPORT_BACKUP_FILE}" ]; then
    if [ -f "${RESTORE_SCRIPT}" ]; then
        bash "${RESTORE_SCRIPT}" --file "${IMPORT_BACKUP_FILE}" --secret-file "${ADMIN_ENV_FILE}"
    else
        log_error "Restore script '${RESTORE_SCRIPT}' not found!"
    fi
fi


# Step 7: Summary & Output Instructions
source "${ADMIN_ENV_FILE}"
HOST_IP=$(hostname -I | awk '{print $1}')

echo -e "${GREEN}=================================================================${NC}"
echo -e "${GREEN}    PostgreSQL Server Configured & Ready for Coordinators!       ${NC}"
echo -e "${GREEN}=================================================================${NC}"
echo -e "${BLUE}PostgreSQL Host IP:${NC} ${HOST_IP}"
echo -e "${BLUE}PostgreSQL Port:${NC} 5432"
echo -e "${BLUE}Admin Superuser:${NC} ${POSTGRES_ADMIN_USER}"
echo -e "${YELLOW}Admin Password:${NC} ${POSTGRES_ADMIN_PASS}"
echo -e "${BLUE}Credentials File:${NC} ${ADMIN_ENV_FILE}"
echo -e "${GREEN}=================================================================${NC}"
echo -e "You can now run deploy_coordinator.sh on any VM and point it to Host IP: ${HOST_IP}."
