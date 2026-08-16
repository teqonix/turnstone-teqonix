#!/usr/bin/env bash
# =============================================================================
# Turnstone LLM Node 2 & 3 Deployment (AMD Ryzen AI Halo - Linux Systemd)
#
# Installs bare-metal turnstone-server systemd unit connecting to local Lemonade
# model server and registering back to the TrueNAS Coordinator VM.
# =============================================================================

set -euo pipefail

# Color Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

trap 'log_error "An error occurred on line $LINENO. Deployment stopped."; exit 1' ERR

# Determine repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." 2>/dev/null && pwd || pwd)"

SYS_ADMIN_ENV="/etc/turnstone/postgres_admin.env"
DEFAULT_SECRET_FILE="${SCRIPT_DIR}/secrets/postgres_admin.secret"
[ -f "${DEFAULT_SECRET_FILE}" ] || DEFAULT_SECRET_FILE="${REPO_ROOT}/secrets/postgres_admin.secret"

SECRET_FILE="${POSTGRES_ADMIN_SECRET_FILE:-${SECRET_FILE:-}}"
POSTGRES_USER="${POSTGRES_USER:-}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
POSTGRES_HOST="${POSTGRES_HOST:-}"
POSTGRES_PORT="${POSTGRES_PORT:-}"
POSTGRES_DB="${POSTGRES_DB:-}"
NODE_ID="${NODE_ID:-}"
COORDINATOR_IP="${COORDINATOR_IP:-}"
JWT_SECRET="${JWT_SECRET:-}"
LEMONADE_URL="${LEMONADE_URL:-http://127.0.0.1:8000/v1}"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -u, --user, --postgres-user <user> PostgreSQL username (e.g. turnstone-np, postgres)"
    echo "  -s, --secret-file <path>           Path to secret file containing DB connection string or env vars"
    echo "  -n, --node-id <id>                 Node ID (e.g. ryzen-halo-1, ryzen-halo-2)"
    echo "  -c, --coordinator <ip>             Coordinator VM IP address or hostname"
    echo "  -h, --help                         Display this help message and exit"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--user|--postgres-user)
            POSTGRES_USER="$2"
            shift 2
            ;;
        -s|--secret-file)
            SECRET_FILE="$2"
            shift 2
            ;;
        -n|--node-id)
            NODE_ID="$2"
            shift 2
            ;;
        -c|--coordinator)
            COORDINATOR_IP="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            ;;
        *)
            shift
            ;;
    esac
done

find_secret_by_user() {
    local target_user="$1"
    [ -z "${target_user}" ] && return 0

    local search_dirs=("${SCRIPT_DIR}/secrets" "${REPO_ROOT}/secrets")
    local sanitized_user
    sanitized_user=$(echo "${target_user}" | tr '-' '_')

    for sdir in "${search_dirs[@]}"; do
        if [ -d "${sdir}" ]; then
            if [ -f "${sdir}/postgres_${sanitized_user}.secret" ]; then
                echo "${sdir}/postgres_${sanitized_user}.secret"
                return 0
            elif [ -f "${sdir}/postgres_${target_user}.secret" ]; then
                echo "${sdir}/postgres_${target_user}.secret"
                return 0
            elif [ -f "${sdir}/${target_user}.secret" ]; then
                echo "${sdir}/${target_user}.secret"
                return 0
            fi

            for f in "${sdir}"/*.secret "${sdir}"/*.env; do
                [ -f "${f}" ] || continue
                if grep -qE "://(${target_user}|${target_user}:)" "${f}" 2>/dev/null || \
                   grep -qE "^[[:space:]]*(POSTGRES_USER|POSTGRES_ADMIN_USER)=[\"']?${target_user}[\"']?[[:space:]]*$" "${f}" 2>/dev/null; then
                    echo "${f}"
                    return 0
                fi
            done
        fi
    done
}

parse_connection_uri() {
    local raw_url="$1"
    raw_url=$(echo "${raw_url}" | tr -d '\r' | xargs)
    local url="${raw_url#*://}"
    
    if [[ "${url}" == *"@"* ]]; then
        local userpass="${url%%@*}"
        local hostportdb="${url#*@}"
        
        local u="${userpass%%:*}"
        [ -n "${u}" ] && POSTGRES_USER="${u}"

        if [[ "${userpass}" == *":"* ]]; then
            local p="${userpass#*:}"
            [ -n "${p}" ] && POSTGRES_PASSWORD="${p}"
        fi
        
        local hostport="${hostportdb%%/*}"
        if [[ "${hostportdb}" == *"/"* ]]; then
            local db_in_url="${hostportdb#*/}"
            db_in_url="${db_in_url%%[?#]*}"
            [ -n "${db_in_url}" ] && POSTGRES_DB="${db_in_url}"
        fi
        
        local h="${hostport%%:*}"
        [ -n "${h}" ] && POSTGRES_HOST="${h}"

        if [[ "${hostport}" == *":"* ]]; then
            local pt="${hostport#*:}"
            [ -n "${pt}" ] && POSTGRES_PORT="${pt}"
        fi
    fi
}

load_secrets() {
    local target_file=""

    if [ -n "${SECRET_FILE}" ] && [ -f "${SECRET_FILE}" ]; then
        target_file="${SECRET_FILE}"
    elif [ -n "${POSTGRES_USER}" ]; then
        local matched
        matched=$(find_secret_by_user "${POSTGRES_USER}")
        if [ -n "${matched}" ]; then
            target_file="${matched}"
        fi
    fi

    if [ -n "${target_file}" ] && [ -f "${target_file}" ]; then
        log_info "Sourcing database connection credentials from '${target_file}'..."
        local first_line
        first_line=$(grep -v '^[[:space:]]*#' "${target_file}" | grep -v '^[[:space:]]*$' | tr -d '\r' | head -n 1 || true)
        
        if [[ "${first_line}" == *"://"* ]] || [[ "${first_line}" == *"@"* ]]; then
            parse_connection_uri "${first_line}"
        elif [[ "${first_line}" == *"="* ]]; then
            set +e
            source "${target_file}"
            set -e
            POSTGRES_USER="${POSTGRES_USER:-${POSTGRES_ADMIN_USER:-turnstone}}"
            POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-${POSTGRES_ADMIN_PASS:-}}"
            POSTGRES_HOST="${POSTGRES_HOST:-${PGHOST:-}}"
            POSTGRES_PORT="${POSTGRES_PORT:-${PGPORT:-}}"
            POSTGRES_DB="${POSTGRES_DB:-turnstone}"
        fi
    fi
}

echo -e "${BLUE}=================================================================${NC}"
echo -e "${BLUE}     Turnstone Node Deployment (AMD Ryzen AI Halo - Lemonade)    ${NC}"
echo -e "${BLUE}=================================================================${NC}"

# Step 1: Root Check
log_info "Step 1: Checking permissions..."
if [ "$EUID" -ne 0 ]; then
    log_warn "This script must be run with sudo or as root to create systemd units and users."
    exec sudo bash "$0" "$@"
fi
log_success "Permissions verified."

# Step 2: Prompt / Environment Inputs
if [ -z "${NODE_ID}" ]; then
    read -rp "Enter Node ID (e.g. ryzen-halo-1 or ryzen-halo-2): " NODE_ID
fi

if [ -z "${SECRET_FILE}" ]; then
    if [ -z "${POSTGRES_USER}" ]; then
        read -rp "Enter PostgreSQL username [default: turnstone-np]: " INPUT_USER
        POSTGRES_USER="${INPUT_USER:-turnstone-np}"
    fi

    MATCHED_SECRET=$(find_secret_by_user "${POSTGRES_USER}")
    if [ -n "${MATCHED_SECRET}" ]; then
        log_info "Found matching secret file '${MATCHED_SECRET}' for PostgreSQL user '${POSTGRES_USER}'."
        SECRET_FILE="${MATCHED_SECRET}"
    fi
fi

load_secrets

if [ -z "${COORDINATOR_IP}" ]; then
    read -rp "Enter Coordinator VM IP Address / Hostname [default: turnstone-coordinator-nerd-projects.lan]: " INPUT_COORD
    COORDINATOR_IP="${INPUT_COORD:-turnstone-coordinator-nerd-projects.lan}"
fi
if [ -z "${POSTGRES_HOST}" ]; then
    read -rp "Enter PostgreSQL DB Host IP / Hostname [default: turnstone-postgres.lan]: " INPUT_PGHOST
    POSTGRES_HOST="${INPUT_PGHOST:-turnstone-postgres.lan}"
fi
POSTGRES_USER="${POSTGRES_USER:-turnstone-np}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-turnstone}"

if [ -z "${POSTGRES_PASSWORD}" ]; then
    read -r -s -p "Enter PostgreSQL Password for user '${POSTGRES_USER}'@'${POSTGRES_HOST}': " POSTGRES_PASSWORD
    echo ""
fi

if [ -z "${JWT_SECRET}" ]; then
    read -rp "Enter TURNSTONE_JWT_SECRET from Coordinator setup: " JWT_SECRET
fi

LAN_IP=$(hostname -I | awk '{print $1}')

# Step 3: Create Dedicated System User
log_info "Step 3: Creating dedicated 'turnstone' system user..."
if ! id "turnstone" &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin turnstone
    log_success "Created system user 'turnstone'."
else
    log_success "System user 'turnstone' already exists."
fi

# Step 4: Install UV and Python Virtualenv
log_info "Step 4: Setting up Python virtual environment..."
VENV_DIR="/opt/turnstone-venv"

if command -v apt-get &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 python3-venv python3-pip
fi

if ! command -v uv &> /dev/null; then
    log_info "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi

SYSTEM_PYTHON=$(command -v python3 || echo "/usr/bin/python3")

# Remove any old venv that might have symlinks into /root/.local
if [ -d "${VENV_DIR}" ]; then
    rm -rf "${VENV_DIR}"
fi

log_info "Creating virtual environment at ${VENV_DIR} using system ${SYSTEM_PYTHON}..."
uv venv "${VENV_DIR}" --python "${SYSTEM_PYTHON}"

log_info "Installing turnstone package into virtualenv..."
if [ -f "${REPO_ROOT}/pyproject.toml" ]; then
    uv pip install --python "${VENV_DIR}" --reinstall "${REPO_ROOT}"
else
    uv pip install --python "${VENV_DIR}" turnstone
fi

# Fix ownership and execution permissions for turnstone user
chown -R turnstone:turnstone "${VENV_DIR}"
chmod -R a+rX "${VENV_DIR}"
chmod +x "${VENV_DIR}/bin"/* 2>/dev/null || true
log_success "Virtualenv created and permissions secured at ${VENV_DIR}."

# Step 5: Configure /etc/turnstone/config.toml Secrets
log_info "Step 5: Writing secrets configuration to /etc/turnstone/config.toml..."
mkdir -p /etc/turnstone

cat > /etc/turnstone/config.toml <<EOF
[auth]
jwt_secret = "${JWT_SECRET}"

[database]
backend = "postgresql"
url = "postgresql+psycopg://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"

[api]
base_url = "${LEMONADE_URL}"
api_key = "dummy"
EOF

chown -R turnstone:turnstone /etc/turnstone
chmod 600 /etc/turnstone/config.toml
log_success "Configuration written and permissions secured (0600 turnstone:turnstone)."

# Step 6: Install Systemd Service Unit & Drop-in
log_info "Step 6: Installing Systemd units..."

cat > /etc/systemd/system/turnstone-server.service <<'EOF'
[Unit]
Description=Turnstone Server Node
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=turnstone
Group=turnstone
WorkingDirectory=/data
ExecStart=/opt/turnstone-venv/bin/turnstone-server --host 0.0.0.0 --port 8080 --config /etc/turnstone/config.toml
Restart=always
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /etc/systemd/system/turnstone-server.service.d
cat > /etc/systemd/system/turnstone-server.service.d/node.conf <<EOF
[Service]
Environment="TURNSTONE_NODE_ID=${NODE_ID}"
Environment="TURNSTONE_ADVERTISE_URL=http://${LAN_IP}:8080"
Environment="TURNSTONE_CONSOLE_URL=http://${COORDINATOR_IP}:8090"
Environment="TURNSTONE_SEARXNG_URL=http://${COORDINATOR_IP}:8081"
Environment="TURNSTONE_CONFIG=/etc/turnstone/config.toml"
Environment="TURNSTONE_DB_BACKEND=postgresql"
Environment="TURNSTONE_DB_URL=postgresql+psycopg://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
EOF

# Ensure /data working directory exists for turnstone user and remove stale SQLite DBs
mkdir -p /data
rm -f /data/.turnstone.db* 2>/dev/null || true
chown -R turnstone:turnstone /data

# Step 7: Reload and Restart Systemd Service
log_info "Step 7: Enabling and restarting turnstone-server service..."
systemctl daemon-reload
systemctl enable turnstone-server.service
systemctl restart turnstone-server.service

sleep 2
if systemctl is-active --quiet turnstone-server.service; then
    log_success "turnstone-server.service is ACTIVE and connected to PostgreSQL at ${POSTGRES_HOST}:${POSTGRES_PORT}."
else
    log_warn "turnstone-server.service is not active! Showing recent service logs:"
    journalctl -u turnstone-server.service -n 25 --no-pager || true
fi

echo -e "${GREEN}=================================================================${NC}"
echo -e "${GREEN}  Node ${NODE_ID} (AMD Ryzen AI Halo) Deployed Successfully!       ${NC}"
echo -e "${GREEN}=================================================================${NC}"
echo -e "Node ID: ${NODE_ID}"
echo -e "Advertise URL: http://${LAN_IP}:8080"
echo -e "PostgreSQL Backend: ${POSTGRES_USER}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
echo -e "Lemonade Backend: ${LEMONADE_URL}"
