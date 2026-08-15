#!/usr/bin/env bash
# =============================================================================
# Turnstone PostgreSQL Coordinator Node User Onboarding Script
#
# Idempotent & User-Friendly script to:
# 1. Create a dedicated PostgreSQL user for a coordinator node (e.g. turnstone-megamul).
# 2. Assign the user to a shared group role (turnstone_app_group) with full DDL/migration & CRUD privileges.
# 3. Configure default privileges for future tables/sequences.
# 4. Generate a secret file (.secret) with the connection URI for deploy_coordinator.sh.
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

trap 'log_error "An error occurred on line $LINENO. User onboarding stopped."; exit 1' ERR

# Determine repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." 2>/dev/null && pwd || pwd)"

SYS_ADMIN_ENV="/etc/turnstone/postgres_admin.env"
DEFAULT_SECRET_FILE="${REPO_ROOT}/secrets/postgres_admin.secret"
TARGET_DB="turnstone"
GROUP_ROLE="turnstone_app_group"

NEW_USER="${1:-}"
NEW_PASS="${2:-}"

usage() {
    echo "Usage: sudo $0 <username> [password]"
    echo ""
    echo "Example:"
    echo "  sudo $0 turnstone-megamul"
    echo "  sudo $0 turnstone-np mysecurepassword"
    exit 0
}

if [ -z "${NEW_USER}" ] || [ "${NEW_USER}" == "-h" ] || [ "${NEW_USER}" == "--help" ]; then
    usage
fi

echo -e "${BLUE}=================================================================${NC}"
echo -e "${BLUE}       Turnstone Coordinator User Onboarding                     ${NC}"
echo -e "${BLUE}=================================================================${NC}"

# Step 1: Root / Sudo Check
log_info "Step 1: Checking permissions..."
if [ "$EUID" -ne 0 ]; then
    log_warn "This script must be run with sudo or as root to configure PostgreSQL users."
    log_warn "Re-running with sudo..."
    exec sudo bash "$0" "$@"
fi
log_success "Permissions verified."

# Step 2: Load Admin Credentials
log_info "Step 2: Loading PostgreSQL admin credentials..."
ADMIN_USER="postgres"
ADMIN_PASS=""

if [ -f "${SYS_ADMIN_ENV}" ]; then
    source "${SYS_ADMIN_ENV}"
    ADMIN_USER="${POSTGRES_ADMIN_USER:-postgres}"
    ADMIN_PASS="${POSTGRES_ADMIN_PASS:-}"
elif [ -f "${DEFAULT_SECRET_FILE}" ]; then
    first_line=$(grep -v '^[[:space:]]*#' "${DEFAULT_SECRET_FILE}" | grep -v '^[[:space:]]*$' | tr -d '\r' | head -n 1 || true)
    if [[ "${first_line}" == *"://"* ]]; then
        url="${first_line#*://}"
        userpass="${url%%@*}"
        ADMIN_USER="${userpass%%:*}"
        ADMIN_PASS="${userpass#*:}"
    fi
fi

run_psql_admin() {
    local sql_cmd="$1"
    if [ -n "${ADMIN_PASS}" ]; then
        PGPASSWORD="${ADMIN_PASS}" psql -h localhost -U "${ADMIN_USER}" -d postgres -c "${sql_cmd}"
    else
        sudo -u postgres psql -d postgres -c "${sql_cmd}"
    fi
}

run_psql_target_db() {
    local sql_cmd="$1"
    if [ -n "${ADMIN_PASS}" ]; then
        PGPASSWORD="${ADMIN_PASS}" psql -h localhost -U "${ADMIN_USER}" -d "${TARGET_DB}" -c "${sql_cmd}"
    else
        sudo -u postgres psql -d "${TARGET_DB}" -c "${sql_cmd}"
    fi
}

# Step 3: Ensure User Password
if [ -z "${NEW_PASS}" ]; then
    read -r -s -p "Enter password for new DB user '${NEW_USER}' [leave blank to auto-generate]: " USER_PASS_INPUT
    echo ""
    if [ -z "${USER_PASS_INPUT}" ]; then
        NEW_PASS=$(python3 -c "import secrets; print(secrets.token_hex(24))" 2>/dev/null || openssl rand -hex 24)
        log_info "Auto-generated secure password for '${NEW_USER}'."
    else
        NEW_PASS="${USER_PASS_INPUT}"
    fi
fi

# Step 4: Create Group Role & User in PostgreSQL
log_info "Step 4: Provisioning user '${NEW_USER}' and group role '${GROUP_ROLE}'..."

run_psql_admin "
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${GROUP_ROLE}') THEN
        CREATE ROLE ${GROUP_ROLE} NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${NEW_USER}') THEN
        CREATE ROLE \"${NEW_USER}\" LOGIN PASSWORD '${NEW_PASS}';
    ELSE
        ALTER ROLE \"${NEW_USER}\" WITH PASSWORD '${NEW_PASS}';
    END IF;
END \$\$;
GRANT ${GROUP_ROLE} TO \"${NEW_USER}\";
ALTER ROLE \"${NEW_USER}\" SET role TO '${GROUP_ROLE}';
"

# Step 5: Grant Privileges & Reassign Ownership to Group Role
log_info "Step 5: Granting database, table, and migration privileges to '${NEW_USER}'..."

run_psql_target_db "
GRANT ALL ON DATABASE ${TARGET_DB} TO ${GROUP_ROLE};
GRANT ALL ON SCHEMA public TO ${GROUP_ROLE};

DO \$\$
DECLARE r RECORD;
BEGIN
    FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP
        EXECUTE format('ALTER TABLE public.%I OWNER TO %I;', r.tablename, '${GROUP_ROLE}');
    END LOOP;
    FOR r IN (SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema = 'public') LOOP
        EXECUTE format('ALTER SEQUENCE public.%I OWNER TO %I;', r.sequence_name, '${GROUP_ROLE}');
    END LOOP;
END \$\$;

GRANT ALL ON ALL TABLES IN SCHEMA public TO ${GROUP_ROLE};
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO ${GROUP_ROLE};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${GROUP_ROLE};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${GROUP_ROLE};
"

log_success "User '${NEW_USER}' provisioned with full cluster migration and CRUD permissions."

# Step 6: Generate Secret File
SECRETS_DIR="${SCRIPT_DIR}/secrets"
mkdir -p "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}"

SECRET_OUTPUT_FILE="${SECRETS_DIR}/postgres_${NEW_USER}.secret"
HOST_IP=$(hostname -I | awk '{print $1}')

cat > "${SECRET_OUTPUT_FILE}" <<EOF
postgresql://${NEW_USER}:${NEW_PASS}@${HOST_IP}:5432/${TARGET_DB}
EOF
chmod 600 "${SECRET_OUTPUT_FILE}"

log_success "Saved connection secret URI to '${SECRET_OUTPUT_FILE}'."

echo -e "${GREEN}=================================================================${NC}"
echo -e "${GREEN}    Coordinator User '${NEW_USER}' Onboarded Successfully!       ${NC}"
echo -e "${GREEN}=================================================================${NC}"
echo -e "${BLUE}Connection URI:${NC} postgresql://${NEW_USER}:${NEW_PASS}@${HOST_IP}:5432/${TARGET_DB}"
echo -e "${BLUE}Secret File:${NC} ${SECRET_OUTPUT_FILE}"
echo -e "${GREEN}=================================================================${NC}"
echo -e "You can now run deploy_coordinator.sh on the target coordinator node:"
echo -e "${BLUE}  sudo ./deploy_coordinator.sh -s ${SECRET_OUTPUT_FILE}${NC}"
