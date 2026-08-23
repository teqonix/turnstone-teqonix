#!/usr/bin/env bash
# =============================================================================
# TrueNAS Container LiteLLM Deployment Script (Debian Trixie)
#
# Idempotent setup script to install LiteLLM Proxy on a Debian Trixie container
# (e.g. `debian/trixie/default` on TrueNAS SCALE / Incus / LXC / System Container).
#
# Balances workloads across 3 physical LLM nodes:
#   1) amd-ai-core-one.lan (Ryzen Strix Halo 128GB | Lemonade)
#   2) amd-ai-core-two.lan (Ryzen Strix Halo 128GB | Lemonade)
#   3) mbp-ai-core.lan     (MacBook Pro M5 128GB  | Ollama / MLX)
#
# Includes:
#   - PostgreSQL local server install & configuration for LiteLLM DB & GUI (/ui)
#   - Idempotent instance detection & connectivity verification using .secret file
#   - Automated secret extraction from postgres_litellm_admin.secret
#   - LiteLLM Salt Key & Master Key generation / persistence
# =============================================================================

set -euo pipefail

# ANSI Styling
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() {
    echo -e "\n${CYAN}=================================================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}=================================================================${NC}"
}

trap 'log_error "An error occurred on line $LINENO. Deployment stopped."; exit 1' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." 2>/dev/null && pwd || pwd)"

# Default Configuration Values
LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_HOST="${LITELLM_HOST:-0.0.0.0}"
LITELLM_USER="turnstone"
LITELLM_DIR="/etc/litellm"
LITELLM_CONFIG="${LITELLM_DIR}/config.yaml"
VENV_DIR="/opt/litellm-venv"
NUM_WORKERS="${NUM_WORKERS:-1}"

# Database and Secrets Configuration
DEFAULT_SECRET_FILE="${SCRIPT_DIR}/secrets/postgres_litellm_admin.secret"
[ -f "${DEFAULT_SECRET_FILE}" ] || DEFAULT_SECRET_FILE="${REPO_ROOT}/secrets/postgres_litellm_admin.secret"
SECRET_FILE="${POSTGRES_ADMIN_SECRET_FILE:-${SECRET_FILE:-}}"

DEFAULT_MASTER_KEY_FILE="${SCRIPT_DIR}/secrets/litellm_proxy_master_key.secret"
[ -f "${DEFAULT_MASTER_KEY_FILE}" ] || DEFAULT_MASTER_KEY_FILE="${REPO_ROOT}/secrets/litellm_proxy_master_key.secret"
MASTER_KEY_FILE="${LITELLM_MASTER_KEY_FILE:-}"

DATABASE_URL="${DATABASE_URL:-}"
SALT_KEY="${LITELLM_SALT_KEY:-${SALT_KEY:-}}"
INSTALL_POSTGRES=true
POSTGRES_USER="postgres"
POSTGRES_PASSWORD=""
POSTGRES_HOST="litellm-proxy.lan"
POSTGRES_PORT="5432"
POSTGRES_DB="postgres"

# Node Endpoints (Defaults match Turnstone cluster hostnames & ports)
NODE_RYZEN_ONE="${NODE_RYZEN_ONE:-http://amd-ai-core-one.lan:13306/v1}"
NODE_RYZEN_TWO="${NODE_RYZEN_TWO:-http://amd-ai-core-two.lan:13306/v1}"
NODE_MBP_MLX="${NODE_MBP_MLX:-http://mbp-ai-core.lan:8000/v1}"
NODE_MBP_OLLAMA="${NODE_MBP_OLLAMA:-${NODE_MBP:-http://mbp-ai-core.lan:11434/v1}}"
NODE_MBP="${NODE_MBP:-${NODE_MBP_OLLAMA}}"
MBP_COOLDOWN_SECONDS="${MBP_COOLDOWN_SECONDS:-60}"

MASTER_KEY="${LITELLM_MASTER_KEY:-${MASTER_KEY:-}}"
ROUTING_STRATEGY="${ROUTING_STRATEGY:-simple-shuffle}"
FORCE_RESTART=false
DESTRUCTIVE="${DESTRUCTIVE:-false}"
ACTION_INSPECT=false

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -s, --status, --inspect        Inspect current configuration & status without modifying anything
  -p, --port <port>              Port for LiteLLM Proxy to listen on (default: 4000)
  -k, --master-key <key>         LiteLLM Master API Key (auto-generated if empty)
  --master-key-file <path>       Path to Master API Key secret file (default: secrets/litellm_proxy_master_key.secret)
  --salt-key <key>               LiteLLM Salt Key for DB credential encryption (auto-generated if empty)
  --secret-file, -s <path>       Path to PostgreSQL secret file (default: secrets/postgres_litellm_admin.secret)
  --db-url, --database-url <url> PostgreSQL connection URL (e.g. postgresql://postgres:pass@litellm-proxy.lan:5432)
  --no-postgres                  Skip local PostgreSQL server installation / configuration
  --destructive                  Destroy existing PostgreSQL instance & LiteLLM Proxy, deploying fresh
  -w, --workers <num>            Number of Uvicorn workers (default: 1)
  --node-ryzen-1 <url>           URL for Ryzen AI Halo Node 1 (default: http://amd-ai-core-one.lan:13305/v1)
  --node-ryzen-2 <url>           URL for Ryzen AI Halo Node 2 (default: http://amd-ai-core-two.lan:13305/v1)
  --node-mbp-mlx <url>           URL for MacBook Pro MLX Server (default: http://mbp-ai-core.lan:8000/v1)
  --node-mbp-ollama <url>        URL for MacBook Pro Ollama Server (default: http://mbp-ai-core.lan:11434/v1)
  --node-mbp <url>               Alias for MacBook Pro Ollama Server (default: http://mbp-ai-core.lan:11434/v1)
  --mbp-cooldown <seconds>       Cooldown window for qwen-3.8-27b priority (default: 60)
  --strategy <strategy>          Routing strategy: least-busy, latency-based-routing, simple-shuffle (default: simple-shuffle)
  --restart                      Force restart the service
  -h, --help                     Display this help message

EOF
    exit 0
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

load_master_key() {
    # If MASTER_KEY is already populated via CLI or env, export LITELLM_MASTER_KEY and return
    if [ -n "${MASTER_KEY}" ]; then
        export LITELLM_MASTER_KEY="${MASTER_KEY}"
        return 0
    fi

    local candidate=""
    if [ -n "${MASTER_KEY_FILE}" ] && [ -f "${MASTER_KEY_FILE}" ]; then
        candidate="${MASTER_KEY_FILE}"
    elif [ -f "${DEFAULT_MASTER_KEY_FILE}" ]; then
        candidate="${DEFAULT_MASTER_KEY_FILE}"
    elif [ -f "${LITELLM_DIR}/litellm_proxy_master_key.secret" ]; then
        candidate="${LITELLM_DIR}/litellm_proxy_master_key.secret"
    elif [ -f "${LITELLM_DIR}/master_key.secret" ]; then
        candidate="${LITELLM_DIR}/master_key.secret"
    elif [ -f "/etc/turnstone/litellm_proxy_master_key.secret" ]; then
        candidate="/etc/turnstone/litellm_proxy_master_key.secret"
    fi

    if [ -n "${candidate}" ] && [ -f "${candidate}" ] && [ -r "${candidate}" ]; then
        local first_line
        first_line=$(grep -v '^[[:space:]]*#' "${candidate}" | grep -v '^[[:space:]]*$' | tr -d '\r\n ' | head -n 1 || true)
        if [ -n "${first_line}" ]; then
            MASTER_KEY="${first_line}"
            export LITELLM_MASTER_KEY="${MASTER_KEY}"
            log_info "Sourced LiteLLM Master API Key from '${candidate}'."
            return 0
        fi
    fi
}

load_database_credentials() {
    local target_file=""

    if [ -n "${SECRET_FILE}" ] && [ -f "${SECRET_FILE}" ]; then
        target_file="${SECRET_FILE}"
    elif [ -f "${DEFAULT_SECRET_FILE}" ]; then
        target_file="${DEFAULT_SECRET_FILE}"
    elif [ -f "${LITELLM_DIR}/postgres_litellm_admin.secret" ]; then
        target_file="${LITELLM_DIR}/postgres_litellm_admin.secret"
    elif [ -f "/etc/turnstone/postgres_litellm_admin.secret" ]; then
        target_file="/etc/turnstone/postgres_litellm_admin.secret"
    fi

    if [ -n "${target_file}" ] && [ -f "${target_file}" ]; then
        log_info "Sourcing PostgreSQL connection credentials from '${target_file}'..."
        local first_line
        first_line=$(grep -v '^[[:space:]]*#' "${target_file}" | grep -v '^[[:space:]]*$' | tr -d '\r' | head -n 1 || true)

        if [[ "${first_line}" == *"://"* ]] || [[ "${first_line}" == *"@"* ]]; then
            DATABASE_URL="${first_line}"
            parse_connection_uri "${first_line}"
        elif [[ "${first_line}" == *"="* ]]; then
            set +e
            source "${target_file}"
            set -e
            POSTGRES_USER="${POSTGRES_USER:-${POSTGRES_ADMIN_USER:-postgres}}"
            POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-${POSTGRES_ADMIN_PASS:-${POSTGRES_ADMIN_PASSWORD:-}}}"
            POSTGRES_HOST="${POSTGRES_HOST:-litellm-proxy.lan}"
            POSTGRES_PORT="${POSTGRES_PORT:-5432}"
            POSTGRES_DB="${POSTGRES_DB:-postgres}"
            [ -n "${DATABASE_URL:-}" ] && parse_connection_uri "${DATABASE_URL}"
        fi
    fi

    # If DATABASE_URL was provided directly via env or CLI
    if [ -n "${DATABASE_URL}" ]; then
        parse_connection_uri "${DATABASE_URL}"
    fi

    # Build canonical DATABASE_URL if not already set, ensuring database path /litellm is present
    if [ -z "${DATABASE_URL}" ]; then
        DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/litellm"
    elif [[ "${DATABASE_URL}" =~ :[0-9]+$ ]] || [[ "${DATABASE_URL}" == *":5432" ]]; then
        DATABASE_URL="${DATABASE_URL%/}/litellm"
    fi

    # Persist secret to /etc/litellm and repo secrets folder if missing
    mkdir -p "${LITELLM_DIR}"
    local litellm_secret_dest="${LITELLM_DIR}/postgres_litellm_admin.secret"
    if [ ! -f "${litellm_secret_dest}" ]; then
        echo -n "${DATABASE_URL}" > "${litellm_secret_dest}"
        chmod 600 "${litellm_secret_dest}"
        chown "${LITELLM_USER}:${LITELLM_USER}" "${litellm_secret_dest}" 2>/dev/null || true
        log_info "Saved database credentials to ${litellm_secret_dest}"
    fi

    if [ -d "${SCRIPT_DIR}/secrets" ] && [ ! -f "${SCRIPT_DIR}/secrets/postgres_litellm_admin.secret" ] && [ -w "${SCRIPT_DIR}/secrets" ]; then
        echo -n "${DATABASE_URL}" > "${SCRIPT_DIR}/secrets/postgres_litellm_admin.secret"
        chmod 600 "${SCRIPT_DIR}/secrets/postgres_litellm_admin.secret"
    fi
}

verify_postgres_connectivity() {
    local target_host="${1:-${POSTGRES_HOST}}"
    local target_port="${POSTGRES_PORT}"
    local target_user="${POSTGRES_USER}"
    local target_pass="${POSTGRES_PASSWORD}"

    # Try TCP connection with target_host
    if PGPASSWORD="${target_pass}" psql -h "${target_host}" -p "${target_port}" -U "${target_user}" -d postgres -c "SELECT 1;" &>/dev/null; then
        return 0
    fi

    # Try TCP connection with 127.0.0.1 if hostname wasn't resolved yet
    if [ "${target_host}" != "127.0.0.1" ] && [ "${target_host}" != "localhost" ]; then
        if PGPASSWORD="${target_pass}" psql -h "127.0.0.1" -p "${target_port}" -U "${target_user}" -d postgres -c "SELECT 1;" &>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# -----------------------------------------------------------------------------
# Function: Inspect & Display Current LiteLLM Cluster Configuration
# -----------------------------------------------------------------------------
show_status_summary() {
    local host_ip
    host_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")

    load_master_key
    local current_key="${MASTER_KEY}"

    if [ -z "${current_key}" ]; then
        local key_file="${LITELLM_DIR}/master_key.secret"
        if [ -f "${key_file}" ] && [ -r "${key_file}" ]; then
            current_key="$(cat "${key_file}" 2>/dev/null || echo "<permission-denied: run as sudo>")"
        elif [ -f "${key_file}" ]; then
            current_key="<restricted: present in ${key_file}>"
        else
            current_key="<not-found: not generated yet>"
        fi
    fi

    local salt_file="${LITELLM_DIR}/salt_key.secret"
    local current_salt="${SALT_KEY}"
    if [ -z "${current_salt}" ]; then
        if [ -f "${salt_file}" ] && [ -r "${salt_file}" ]; then
            current_salt="$(cat "${salt_file}" 2>/dev/null || echo "<permission-denied: run as sudo>")"
        elif [ -f "${salt_file}" ]; then
            current_salt="<restricted: present in ${salt_file}>"
        else
            current_salt="<not-found: not generated yet>"
        fi
    fi

    # Detect service status
    local service_status="UNKNOWN"
    if command -v systemctl &>/dev/null && systemctl is-active --quiet litellm.service 2>/dev/null; then
        service_status="${GREEN}ACTIVE (systemd)${NC}"
    elif pgrep -f "litellm.*--config" &>/dev/null; then
        service_status="${GREEN}ACTIVE (background process)${NC}"
    else
        service_status="${RED}INACTIVE / STOPPED${NC}"
    fi

    # Detect PostgreSQL status
    local pg_status="UNKNOWN"
    if command -v systemctl &>/dev/null && systemctl is-active --quiet postgresql 2>/dev/null; then
        pg_status="${GREEN}ACTIVE (systemd on port 5432)${NC}"
    elif pg_isready -q -h 127.0.0.1 -p 5432 2>/dev/null || pgrep -x postgres &>/dev/null; then
        pg_status="${GREEN}ACTIVE (listening on port 5432)${NC}"
    else
        pg_status="${RED}INACTIVE / STOPPED${NC}"
    fi

    # Read routing strategy from config if file exists
    local configured_strategy="${ROUTING_STRATEGY}"
    if [ -f "${LITELLM_CONFIG}" ]; then
        local extracted_strat
        extracted_strat=$(grep -E 'routing_strategy:\s*' "${LITELLM_CONFIG}" 2>/dev/null | head -n1 | awk -F': ' '{print $2}' | tr -d '"' | tr -d "'" || true)
        [ -n "${extracted_strat}" ] && configured_strategy="${extracted_strat}"
    fi

    local masked_db_url="<not-configured>"
    if [ -n "${DATABASE_URL}" ]; then
        masked_db_url=$(echo "${DATABASE_URL}" | sed -E 's/:([^@:]+)@/:***@/')
    elif [ -f "${LITELLM_DIR}/postgres_litellm_admin.secret" ]; then
        masked_db_url=$(cat "${LITELLM_DIR}/postgres_litellm_admin.secret" 2>/dev/null | sed -E 's/:([^@:]+)@/:***@/' || echo "<restricted: /etc/litellm/postgres_litellm_admin.secret>")
    elif [ -f "${DEFAULT_SECRET_FILE}" ]; then
        masked_db_url=$(cat "${DEFAULT_SECRET_FILE}" 2>/dev/null | sed -E 's/:([^@:]+)@/:***@/' || echo "<restricted: ${DEFAULT_SECRET_FILE}>")
    fi

    local ssh_secret_file="${LITELLM_DIR}/turnstone_ssh.secret"
    local ssh_pass="<not-configured>"
    if [ -f "${ssh_secret_file}" ] && [ -r "${ssh_secret_file}" ]; then
        ssh_pass="$(cat "${ssh_secret_file}" 2>/dev/null || echo "<permission-denied: run as sudo>")"
    elif [ -f "${ssh_secret_file}" ]; then
        ssh_pass="<restricted: present in ${ssh_secret_file}>"
    fi

    echo -e "\n${CYAN}=================================================================${NC}"
    echo -e "${CYAN}       Turnstone LiteLLM Proxy Status & Cluster Summary          ${NC}"
    echo -e "${CYAN}=================================================================${NC}"
    echo -e "${BOLD}Proxy Service Status:${NC}    ${service_status}"
    echo -e "${BOLD}PostgreSQL Status:${NC}       ${pg_status}"
    echo -e "${BOLD}LiteLLM Web GUI:${NC}         http://${host_ip}:${LITELLM_PORT}/ui"
    echo -e "${BOLD}Single OpenAI Endpoint:${NC}  http://${host_ip}:${LITELLM_PORT}/v1"
    echo -e "${BOLD}Master API Key:${NC}          ${current_key}"
    echo -e "${BOLD}Database URL:${NC}            ${masked_db_url}"
    echo -e "${BOLD}Routing Strategy:${NC}        ${configured_strategy} (MBP Activity Priority + Least-Busy)"
    echo -e "${BOLD}MBP Cooldown Lock:${NC}       ${MBP_COOLDOWN_SECONDS}s (qwen-3.8-27b warm cache reservation)"
    echo -e "${BOLD}Config File:${NC}             ${LITELLM_CONFIG}"
    echo -e "${BOLD}Router Module:${NC}           ${LITELLM_DIR}/turnstone_router.py"
    echo -e "${BOLD}Virtualenv:${NC}              ${VENV_DIR}"
    echo ""
    echo -e "${CYAN}LiteLLM GUI Admin Access Instructions:${NC}"
    echo -e "  - Open in browser:          http://${host_ip}:${LITELLM_PORT}/ui"
    echo -e "  - Enter Master Key:         ${current_key}"
    echo ""
    echo -e "${CYAN}Container SSH & Troubleshooting Access:${NC}"
    echo -e "  - ${BOLD}SSH Command:${NC}        ssh turnstone@${host_ip}"
    echo -e "  - ${BOLD}SSH Password:${NC}       ${ssh_pass}"
    echo -e "  - ${BOLD}Sudo Access:${NC}        sudo -i (Full Admin Privileges)"
    echo ""
    echo -e "${CYAN}Load-Balanced Physical Nodes:${NC}"
    echo -e "  - Node 1: ${NODE_RYZEN_ONE} (AMD Ryzen Strix Halo 128GB - Lemonade)"
    echo -e "  - Node 2: ${NODE_RYZEN_TWO} (AMD Ryzen Strix Halo 128GB - Lemonade)"
    echo -e "  - Node 3 (MLX):    ${NODE_MBP_MLX} (MacBook Pro M5 128GB - MLX Pinned Server)"
    echo -e "  - Node 3 (Ollama): ${NODE_MBP_OLLAMA} (MacBook Pro M5 128GB - Ollama Dynamic Engine)"
    echo ""
    echo -e "${CYAN}Unified OpenAI Models Available:${NC}"
    echo -e "  - ${BOLD}qwen-3.8-27b${NC}           -> Pinned to MBP MLX (${NODE_MBP_MLX}) w/ ${MBP_COOLDOWN_SECONDS}s priority lock"
    echo -e "  - ${BOLD}gemma-4-31b${NC}            -> Balanced across Node 1, Node 2, & Node 3 Ollama"
    echo -e "  - ${BOLD}Mistral-Nemo-Base-2407${NC} -> Primary: Node 3 MBP Ollama, Fallback: Node 1 & Node 2 Ryzen Halo"
    echo -e "  - ${BOLD}ornith-latest${NC}          -> Node 1 & Node 2 agentic fast tasks"
    echo -e "  - ${BOLD}default${NC}                -> Fallback balanced across all nodes"
    echo ""
    echo -e "${CYAN}Health Check & Verification Commands:${NC}"
    echo "  curl -X GET 'http://${host_ip}:${LITELLM_PORT}/health/readiness' -H 'Authorization: Bearer ${current_key}'"
    echo "  curl -X GET 'http://${host_ip}:${LITELLM_PORT}/v1/models' -H 'Authorization: Bearer ${current_key}'"
    echo ""
    echo "  curl -X POST 'http://${host_ip}:${LITELLM_PORT}/v1/chat/completions' \\"
    echo "    -H 'Content-Type: application/json' \\"
    echo "    -H 'Authorization: Bearer ${current_key}' \\"
    echo "    -d '{\"model\": \"qwen-3.8-27b\", \"messages\": [{\"role\": \"user\", \"content\": \"def quicksort(arr):\"}]}'"
    echo "================================================================="
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--status|--inspect|--info)
            ACTION_INSPECT=true
            shift
            ;;
        -p|--port)
            LITELLM_PORT="$2"
            shift 2
            ;;
        -k|--master-key)
            MASTER_KEY="$2"
            shift 2
            ;;
        --master-key-file)
            MASTER_KEY_FILE="$2"
            shift 2
            ;;
        --salt-key)
            SALT_KEY="$2"
            shift 2
            ;;
        -s|--secret-file)
            SECRET_FILE="$2"
            shift 2
            ;;
        --db-url|--database-url)
            DATABASE_URL="$2"
            shift 2
            ;;
        --no-postgres)
            INSTALL_POSTGRES=false
            shift
            ;;
        --destructive)
            DESTRUCTIVE=true
            shift
            ;;
        -w|--workers)
            NUM_WORKERS="$2"
            shift 2
            ;;
        --node-ryzen-1)
            NODE_RYZEN_ONE="$2"
            shift 2
            ;;
        --node-ryzen-2)
            NODE_RYZEN_TWO="$2"
            shift 2
            ;;
        --node-mbp-mlx)
            NODE_MBP_MLX="$2"
            shift 2
            ;;
        --node-mbp-ollama)
            NODE_MBP_OLLAMA="$2"
            NODE_MBP="$2"
            shift 2
            ;;
        --node-mbp)
            NODE_MBP="$2"
            NODE_MBP_OLLAMA="$2"
            shift 2
            ;;
        --mbp-cooldown)
            MBP_COOLDOWN_SECONDS="$2"
            shift 2
            ;;
        --strategy)
            ROUTING_STRATEGY="$2"
            shift 2
            ;;
        --restart)
            FORCE_RESTART=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# If inspect/status requested, show summary and exit immediately
if [ "${ACTION_INSPECT}" = true ]; then
    show_status_summary
    exit 0
fi

log_section "LiteLLM Proxy Installation (Debian Trixie Container)"

# -----------------------------------------------------------------------------
# Step 1: Verify Root Privileges
# -----------------------------------------------------------------------------
log_info "Step 1: Checking user privileges..."
if [ "$EUID" -ne 0 ]; then
    log_warn "This script requires root privileges in the container. Re-executing with sudo..."
    exec sudo bash "$0" "$@"
fi
log_success "Running with root privileges."

# -----------------------------------------------------------------------------
# Step 1b: Destructive Purge & Reset (if --destructive requested)
# -----------------------------------------------------------------------------
if [ "${DESTRUCTIVE}" = true ]; then
    log_section "DESTRUCTIVE MODE: Purging PostgreSQL & LiteLLM Proxy"
    log_warn "Stopping and removing existing LiteLLM Proxy services, processes, and virtualenv..."

    # Stop and disable systemd service / kill background processes
    if command -v systemctl &>/dev/null; then
        systemctl stop litellm.service 2>/dev/null || true
        systemctl disable litellm.service 2>/dev/null || true
    fi
    pkill -9 -f "litellm.*--config" 2>/dev/null || true
    pkill -9 -f "start-litellm" 2>/dev/null || true
    pkill -9 -f "uvicorn.*litellm" 2>/dev/null || true

    # Remove virtualenv and config files
    rm -rf "${VENV_DIR}"
    rm -f "${LITELLM_CONFIG}" "${LITELLM_DIR}/turnstone_router.py" "/var/log/litellm.log" "/usr/local/bin/start-litellm" "/etc/systemd/system/litellm.service"
    command -v systemctl &>/dev/null && systemctl daemon-reload 2>/dev/null || true

    # Stop PostgreSQL and drop all existing clusters
    log_warn "Purging existing PostgreSQL clusters and data directories..."
    if command -v systemctl &>/dev/null; then
        systemctl stop postgresql 2>/dev/null || true
    else
        /etc/init.d/postgresql stop 2>/dev/null || service postgresql stop 2>/dev/null || true
    fi
    pkill -9 -f "postgres" 2>/dev/null || true

    if command -v pg_dropcluster &>/dev/null && command -v pg_lsclusters &>/dev/null; then
        for cluster_entry in $(pg_lsclusters --no-header 2>/dev/null | awk '{print $1":"$2}'); do
            local_ver="${cluster_entry%%:*}"
            local_name="${cluster_entry#*:}"
            log_info "Dropping PostgreSQL cluster ${local_ver}/${local_name}..."
            pg_dropcluster "${local_ver}" "${local_name}" --stop 2>/dev/null || true
        done
    fi

    rm -rf /var/lib/postgresql/*
    rm -rf /etc/postgresql/*

    # Re-initialize fresh default cluster
    log_info "Reinstalling base PostgreSQL cluster packages..."
    apt-get update -qq
    apt-get install --reinstall -y -qq postgresql postgresql-contrib

    PG_VER_DETECT=$(psql --version 2>/dev/null | awk '{print $3}' | cut -d'.' -f1 || echo "17")
    if command -v pg_createcluster &>/dev/null && [ ! -d "/etc/postgresql/${PG_VER_DETECT}/main" ]; then
        log_info "Creating fresh PostgreSQL ${PG_VER_DETECT} main cluster..."
        pg_createcluster "${PG_VER_DETECT}" main 2>/dev/null || true
    fi

    log_success "Destructive teardown complete. Proceeding with clean installation."
fi

# -----------------------------------------------------------------------------
# Step 2: Install Debian System Packages, OpenSSH Server & Astral UV
# -----------------------------------------------------------------------------
log_section "Step 2: Installing Base Packages, PostgreSQL, OpenSSH & UV"

export DEBIAN_FRONTEND=noninteractive

log_info "Updating apt package index..."
apt-get update -qq

log_info "Installing core system utilities, PostgreSQL, nodejs, openssh-server, sudo, and build tools..."
apt-get install -y -qq \
    curl \
    ca-certificates \
    openssh-server \
    sudo \
    postgresql \
    postgresql-contrib \
    nodejs \
    npm \
    python3 \
    python3-venv \
    python3-pip \
    jq \
    openssl \
    procps \
    net-tools \
    iproute2 \
    systemd

# Install uv (astral.sh) for fast, isolated Python package management (avoids PEP 668 conflicts)
if ! command -v uv &>/dev/null; then
    log_info "Installing Astral uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="/root/.local/bin:$HOME/.local/bin:$PATH"
fi

log_success "Base system packages, PostgreSQL packages, OpenSSH server, and uv ready."

# -----------------------------------------------------------------------------
# Step 3: Configure OpenSSH Server & Troubleshooting User 'turnstone'
# -----------------------------------------------------------------------------
log_section "Step 3: Setting Up OpenSSH & Troubleshooting User 'turnstone'"

mkdir -p "${LITELLM_DIR}"
SSH_KEY_FILE="${LITELLM_DIR}/turnstone_ssh.secret"

if [ -f "${SSH_KEY_FILE}" ]; then
    TURNSTONE_SSH_PASS="$(cat "${SSH_KEY_FILE}")"
    log_info "Reusing existing password for 'turnstone' from ${SSH_KEY_FILE}"
else
    TURNSTONE_SSH_PASS="$(openssl rand -hex 12)"
    echo -n "${TURNSTONE_SSH_PASS}" > "${SSH_KEY_FILE}"
    chmod 600 "${SSH_KEY_FILE}"
    log_info "Generated new password for troubleshooting user 'turnstone'."
fi

if ! id "turnstone" &>/dev/null; then
    useradd -m -s /bin/bash "turnstone"
    log_success "Created troubleshooting user 'turnstone'."
else
    log_info "User 'turnstone' already exists."
fi

# Set password & ensure sudo group membership
echo "turnstone:${TURNSTONE_SSH_PASS}" | chpasswd
usermod -aG sudo turnstone

# Sudoers drop-in configuration for turnstone
cat > /etc/sudoers.d/turnstone <<EOF
turnstone ALL=(ALL) NOPASSWD: ALL
EOF
chmod 0440 /etc/sudoers.d/turnstone

# Configure and start OpenSSH daemon
mkdir -p /run/sshd /var/run/sshd
if [ -f /etc/ssh/sshd_config ]; then
    sed -i -E 's/^#?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || true
fi

if command -v systemctl &>/dev/null && (pidof systemd &>/dev/null || [ -d /run/systemd/system ]); then
    systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    log_success "OpenSSH service enabled and restarted."
else
    # Background sshd if systemd is not active
    pkill -x sshd || true
    /usr/sbin/sshd || true
    log_info "Started sshd in background."
fi

# -----------------------------------------------------------------------------
# Step 4: Install, Configure & Secure PostgreSQL Server for LiteLLM GUI & DB
# -----------------------------------------------------------------------------
if [ "${INSTALL_POSTGRES}" = true ]; then
    log_section "Step 4: Setting Up PostgreSQL Database for LiteLLM GUI & Storage"

    load_database_credentials

    # Ensure hostname resolution for litellm-proxy.lan
    if ! getent hosts litellm-proxy.lan &>/dev/null; then
        log_info "Adding '127.0.0.1 litellm-proxy.lan' to /etc/hosts for local loopback resolution..."
        if ! grep -q "litellm-proxy.lan" /etc/hosts; then
            echo "127.0.0.1 litellm-proxy.lan" >> /etc/hosts
        fi
    fi

    # Ensure PostgreSQL packages are installed
    if ! command -v psql &>/dev/null; then
        log_info "Installing PostgreSQL packages via apt..."
        apt-get update -qq
        apt-get install -y -qq postgresql postgresql-contrib
    fi

    PG_VERSION=$(psql --version 2>/dev/null | awk '{print $3}' | cut -d'.' -f1 || echo "17")
    PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/main"
    if [ ! -d "${PG_CONF_DIR}" ]; then
        PG_CONF_DIR=$(find /etc/postgresql -name "postgresql.conf" 2>/dev/null | head -n 1 | xargs dirname || true)
    fi

    # If cluster config directory is missing, create default cluster
    if [ -z "${PG_CONF_DIR}" ] || [ ! -f "${PG_CONF_DIR}/postgresql.conf" ]; then
        log_info "Creating default PostgreSQL cluster for version ${PG_VERSION}..."
        pg_createcluster "${PG_VERSION}" main 2>/dev/null || true
        PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/main"
    fi

    if [ -n "${PG_CONF_DIR}" ] && [ -f "${PG_CONF_DIR}/postgresql.conf" ]; then
        log_info "Configuring PostgreSQL (${PG_VERSION}) network listening and container shared memory..."
        
        # Listen on all network interfaces
        if grep -q "^#listen_addresses =" "${PG_CONF_DIR}/postgresql.conf"; then
            sed -i "s/^#listen_addresses =.*/listen_addresses = '*'/" "${PG_CONF_DIR}/postgresql.conf"
        elif grep -q "^listen_addresses =" "${PG_CONF_DIR}/postgresql.conf"; then
            sed -i "s/^listen_addresses =.*/listen_addresses = '*'/" "${PG_CONF_DIR}/postgresql.conf"
        else
            echo "listen_addresses = '*'" >> "${PG_CONF_DIR}/postgresql.conf"
        fi

        # Container / LXC shared memory fix (sysv)
        if grep -q "^#dynamic_shared_memory_type =" "${PG_CONF_DIR}/postgresql.conf"; then
            sed -i "s/^#dynamic_shared_memory_type =.*/dynamic_shared_memory_type = sysv/" "${PG_CONF_DIR}/postgresql.conf"
        elif grep -q "^dynamic_shared_memory_type =" "${PG_CONF_DIR}/postgresql.conf"; then
            sed -i "s/^dynamic_shared_memory_type =.*/dynamic_shared_memory_type = sysv/" "${PG_CONF_DIR}/postgresql.conf"
        else
            echo "dynamic_shared_memory_type = sysv" >> "${PG_CONF_DIR}/postgresql.conf"
        fi

        # Authentication in pg_hba.conf
        HBA_FILE="${PG_CONF_DIR}/pg_hba.conf"
        if [ -f "${HBA_FILE}" ]; then
            if ! grep -q "0.0.0.0/0" "${HBA_FILE}" 2>/dev/null; then
                echo "" >> "${HBA_FILE}"
                echo "# LiteLLM Proxy & Turnstone Connections" >> "${HBA_FILE}"
                echo "host    all             all             0.0.0.0/0               scram-sha-256" >> "${HBA_FILE}"
                echo "host    all             all             ::0/0                   scram-sha-256" >> "${HBA_FILE}"
            fi
        fi
    fi

    # Container IPC & /dev/shm configuration
    chmod 1777 /dev/shm 2>/dev/null || true
    if [ -f "/etc/systemd/logind.conf" ]; then
        if grep -q "^#RemoveIPC=" /etc/systemd/logind.conf; then
            sed -i "s/^#RemoveIPC=.*/RemoveIPC=no/" /etc/systemd/logind.conf
        elif grep -q "^RemoveIPC=" /etc/systemd/logind.conf; then
            sed -i "s/^RemoveIPC=.*/RemoveIPC=no/" /etc/systemd/logind.conf
        fi
    fi

    # Start & enable PostgreSQL
    if command -v systemctl &>/dev/null && (pidof systemd &>/dev/null || [ -d /run/systemd/system ]); then
        systemctl enable postgresql 2>/dev/null || true
        systemctl restart postgresql
        log_success "PostgreSQL service enabled and restarted via systemd."
    else
        /etc/init.d/postgresql restart 2>/dev/null || service postgresql restart 2>/dev/null || true
        log_info "Started PostgreSQL service via sysvinit/service."
    fi

    # Wait for PostgreSQL to accept local connections
    log_info "Waiting for PostgreSQL to accept connections..."
    for attempt in {1..20}; do
        if sudo -u postgres psql -c "SELECT 1;" &>/dev/null || pg_isready -q -p "${POSTGRES_PORT}" 2>/dev/null; then
            break
        fi
        sleep 1
    done

    # Ensure password synchronization with secret file
    log_info "Ensuring PostgreSQL credentials match secret file..."
    if ! verify_postgres_connectivity; then
        log_info "Configuring PostgreSQL superuser '${POSTGRES_USER}' password from secret file..."
        sudo -u postgres psql -c "ALTER USER ${POSTGRES_USER} WITH PASSWORD '${POSTGRES_PASSWORD}';" >/dev/null 2>&1 || true
    fi

    # Ensure litellm database exists
    log_info "Ensuring 'litellm' database exists..."
    if ! sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname = 'litellm'" 2>/dev/null | grep -q 1; then
        sudo -u postgres psql -c "CREATE DATABASE litellm OWNER ${POSTGRES_USER};" >/dev/null 2>&1 || true
        log_success "Created 'litellm' database."
    else
        log_info "Database 'litellm' already exists."
    fi

    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE postgres TO ${POSTGRES_USER};" >/dev/null 2>&1 || true
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE litellm TO ${POSTGRES_USER};" >/dev/null 2>&1 || true

    # Final connectivity verification using secret credentials
    log_info "Verifying PostgreSQL connectivity using credentials from '${SECRET_FILE:-${DEFAULT_SECRET_FILE}}'..."
    if ! verify_postgres_connectivity; then
        log_error "PostgreSQL connectivity check failed using '${SECRET_FILE:-${DEFAULT_SECRET_FILE}}'."
        log_error "Attempted connection URL: ${DATABASE_URL}"
        exit 1
    fi
    log_success "PostgreSQL database ready and verified successfully."
else
    log_info "Skipping local PostgreSQL server setup (--no-postgres). Loading database credentials..."
    load_database_credentials
    if ! verify_postgres_connectivity; then
        log_error "Failed to connect to PostgreSQL database at '${DATABASE_URL}'. Please check host and credentials."
        exit 1
    fi
    log_success "Remote PostgreSQL connection verified."
fi

# -----------------------------------------------------------------------------
# Step 5: Verify Dedicated Service User '${LITELLM_USER}'
# -----------------------------------------------------------------------------
log_section "Step 5: Verifying Service User '${LITELLM_USER}'"

if ! id "${LITELLM_USER}" &>/dev/null; then
    useradd -m -s /bin/bash "${LITELLM_USER}"
    log_success "Created system user '${LITELLM_USER}'."
else
    log_info "System user '${LITELLM_USER}' verified."
fi

# -----------------------------------------------------------------------------
# Step 6: Python Virtual Environment & LiteLLM Package Installation
# -----------------------------------------------------------------------------
log_section "Step 6: Installing LiteLLM Proxy into ${VENV_DIR}"

SYSTEM_PYTHON=$(command -v python3 || echo "/usr/bin/python3")

if [ ! -d "${VENV_DIR}" ] || [ ! -f "${VENV_DIR}/bin/litellm" ]; then
    log_info "Creating virtual environment at ${VENV_DIR}..."
    mkdir -p /opt
    rm -rf "${VENV_DIR}"
    uv venv "${VENV_DIR}" --python "${SYSTEM_PYTHON}"
    
    log_info "Installing 'litellm[proxy]', prisma, asyncpg, psycopg2-binary, fastapi, uvicorn, and dependencies..."
    uv pip install --python "${VENV_DIR}" "fastapi>=0.112.0,<0.116.0" "litellm[proxy]" uvicorn gunicorn backoff asyncpg psycopg2-binary prisma
    log_success "LiteLLM and database drivers installed successfully."
else
    log_info "Virtual environment exists at ${VENV_DIR}. Enforcing FastAPI compatibility and updating dependencies..."
    uv pip install --python "${VENV_DIR}" "fastapi>=0.112.0,<0.116.0" "litellm[proxy]" uvicorn gunicorn backoff asyncpg psycopg2-binary prisma --reinstall-package fastapi
fi

# Ensure PATH includes venv bin so Prisma CLI can locate prisma-client-py generator
export PATH="${VENV_DIR}/bin:$PATH"
export HOME="/home/${LITELLM_USER}"
export PRISMA_CACHE_DIR="/home/${LITELLM_USER}/.cache/prisma-python"
mkdir -p "/home/${LITELLM_USER}/.cache/prisma-python" "${LITELLM_DIR}"

log_info "Fetching Prisma database query engine binaries..."
"${VENV_DIR}/bin/prisma" py fetch || true

log_info "Locating LiteLLM Prisma database schema..."
LITELLM_SCHEMA=$("${VENV_DIR}/bin/python3" -c "import litellm, os, glob; paths = glob.glob(os.path.join(os.path.dirname(litellm.__file__), 'proxy', '**', 'schema.prisma'), recursive=True) + glob.glob(os.path.join(os.path.dirname(litellm.__file__), '**', 'schema.prisma'), recursive=True); print(paths[0] if paths else '')" 2>/dev/null || true)

if [ -n "${LITELLM_SCHEMA}" ] && [ -f "${LITELLM_SCHEMA}" ]; then
    log_info "Generating Prisma client schema from ${LITELLM_SCHEMA}..."
    "${VENV_DIR}/bin/prisma" generate --schema="${LITELLM_SCHEMA}"
else
    log_info "Generating default Prisma client schema..."
    "${VENV_DIR}/bin/prisma" generate
fi

# Pre-populate LiteLLM database schema with prisma db push
if [ -n "${LITELLM_SCHEMA}" ] && [ -f "${LITELLM_SCHEMA}" ] && [ -n "${DATABASE_URL}" ]; then
    log_info "Synchronizing PostgreSQL database tables via Prisma db push..."
    DATABASE_URL="${DATABASE_URL}" "${VENV_DIR}/bin/prisma" db push --schema="${LITELLM_SCHEMA}" --accept-data-loss || true
fi

# Ensure user permissions on venv and config directories
chown -R "${LITELLM_USER}:${LITELLM_USER}" "${VENV_DIR}" "${LITELLM_DIR}" "/home/${LITELLM_USER}"
chmod -R a+rX "${VENV_DIR}" "${LITELLM_DIR}"
chmod +x "${VENV_DIR}/bin"/* 2>/dev/null || true

# Test Python imports before continuing
log_info "Verifying LiteLLM proxy server module imports..."
if ! "${VENV_DIR}/bin/python3" -c "import litellm; from litellm.proxy.proxy_server import app; print('Python imports: OK')" 2>/dev/null; then
    log_error "LiteLLM module import test failed. Running with full traceback:"
    "${VENV_DIR}/bin/python3" -c "import litellm; from litellm.proxy.proxy_server import app"
    exit 1
fi
log_success "Python package import verification passed."

# -----------------------------------------------------------------------------
# Step 7: Configure LiteLLM Routing & Cluster Model Definitions
# -----------------------------------------------------------------------------
log_section "Step 7: Writing Cluster Configuration & Router to ${LITELLM_DIR}"

mkdir -p "${LITELLM_DIR}"

# Master API Key
KEY_FILE="${LITELLM_DIR}/master_key.secret"
LITELLM_KEY_ALIAS_FILE="${LITELLM_DIR}/litellm_proxy_master_key.secret"

load_master_key

if [ -z "${MASTER_KEY}" ]; then
    if [ -f "${KEY_FILE}" ]; then
        MASTER_KEY="$(cat "${KEY_FILE}")"
        export LITELLM_MASTER_KEY="${MASTER_KEY}"
        log_info "Reusing existing Master API Key from ${KEY_FILE}"
    else
        MASTER_KEY="sk-turnstone-$(openssl rand -hex 16)"
        export LITELLM_MASTER_KEY="${MASTER_KEY}"
        log_info "Generated new Master API Key: ${MASTER_KEY}"
    fi
fi

echo -n "${MASTER_KEY}" > "${KEY_FILE}"
chmod 600 "${KEY_FILE}"
chown "${LITELLM_USER}:${LITELLM_USER}" "${KEY_FILE}" 2>/dev/null || true

echo -n "${MASTER_KEY}" > "${LITELLM_KEY_ALIAS_FILE}"
chmod 600 "${LITELLM_KEY_ALIAS_FILE}"
chown "${LITELLM_USER}:${LITELLM_USER}" "${LITELLM_KEY_ALIAS_FILE}" 2>/dev/null || true

if [ -d "${SCRIPT_DIR}/secrets" ] && [ ! -f "${SCRIPT_DIR}/secrets/litellm_proxy_master_key.secret" ] && [ -w "${SCRIPT_DIR}/secrets" ]; then
    echo -n "${MASTER_KEY}" > "${SCRIPT_DIR}/secrets/litellm_proxy_master_key.secret"
    chmod 600 "${SCRIPT_DIR}/secrets/litellm_proxy_master_key.secret"
fi

# LiteLLM Encryption Salt Key (used to encrypt/decrypt credentials stored in DB)
SALT_KEY_FILE="${LITELLM_DIR}/salt_key.secret"
if [ -z "${SALT_KEY}" ]; then
    if [ -f "${SALT_KEY_FILE}" ]; then
        SALT_KEY="$(cat "${SALT_KEY_FILE}")"
        log_info "Reusing existing Salt Key from ${SALT_KEY_FILE}"
    else
        SALT_KEY="sk-salt-$(openssl rand -hex 16)"
        echo -n "${SALT_KEY}" > "${SALT_KEY_FILE}"
        chmod 600 "${SALT_KEY_FILE}"
        chown "${LITELLM_USER}:${LITELLM_USER}" "${SALT_KEY_FILE}"
        log_info "Generated new Salt Key: ${SALT_KEY}"
    fi
else
    echo -n "${SALT_KEY}" > "${SALT_KEY_FILE}"
    chmod 600 "${SALT_KEY_FILE}"
    chown "${LITELLM_USER}:${LITELLM_USER}" "${SALT_KEY_FILE}"
fi

# -----------------------------------------------------------------------------
# Step 7a: Fetch and Configure LiteLLM Router and Config
# -----------------------------------------------------------------------------
log_info "Fetching LiteLLM Router and Configuration files..."

fetch_and_install_file() {
    local filename="$1"
    local dest="$2"
    local interpolate="${3:-false}"
    
    local local_path="${SCRIPT_DIR}/litellm/${filename}"
    local remote_url="https://raw.githubusercontent.com/teqonix/turnstone-teqonix/main/.github/issues/bare_metal_migration/litellm/${filename}"
    
    local tmp_file="/tmp/${filename}"
    
    if [ -f "${local_path}" ]; then
        log_info "Found local ${filename}, copying..."
        cp "${local_path}" "${tmp_file}"
    else
        log_info "Fetching ${filename} from remote..."
        curl -sSfL "${remote_url}" -o "${tmp_file}" || {
            log_error "Failed to fetch ${filename}"
            exit 1
        }
    fi
    
    if [ "${interpolate}" = true ]; then
        log_info "Interpolating variables in ${filename}..."
        export NODE_RYZEN_ONE NODE_RYZEN_TWO NODE_MBP_OLLAMA NODE_MBP_MLX MASTER_KEY DATABASE_URL
        eval "cat <<EOF
$(cat "${tmp_file}")
EOF
" > "${dest}"
    else
        cp "${tmp_file}" "${dest}"
    fi
    
    rm -f "${tmp_file}"
}

fetch_and_install_file "hardware_group_router_litellm.py" "${LITELLM_DIR}/hardware_group_router_litellm.py" false
chown "${LITELLM_USER}:${LITELLM_USER}" "${LITELLM_DIR}/hardware_group_router_litellm.py" 2>/dev/null || true

# Fetch models config and generator script
fetch_and_install_file "config.yaml.template" "${LITELLM_DIR}/config.yaml.template" true
fetch_and_install_file "../models.json" "${LITELLM_DIR}/models.json" false
fetch_and_install_file "generate_config.py" "${LITELLM_DIR}/generate_config.py" false

log_info "Generating dynamic LiteLLM config from models.json..."
export MODELS_CONFIG_PATH="${LITELLM_DIR}/models.json"
export CONFIG_TEMPLATE_PATH="${LITELLM_DIR}/config.yaml.template"
export CONFIG_OUTPUT_PATH="${LITELLM_CONFIG}"
export NODE_RYZEN_ONE="${NODE_RYZEN_ONE}"
export NODE_RYZEN_TWO="${NODE_RYZEN_TWO}"
export NODE_MBP_MLX="${NODE_MBP_MLX}"
export NODE_MBP_OLLAMA="${NODE_MBP_OLLAMA}"
"${VENV_DIR}/bin/python3" "${LITELLM_DIR}/generate_config.py"

chown -R "${LITELLM_USER}:${LITELLM_USER}" "${LITELLM_DIR}"
chmod 600 "${LITELLM_CONFIG}"
log_success "Configuration created at ${LITELLM_CONFIG}."

# -----------------------------------------------------------------------------
# Step 8: Configure & Start Service
# -----------------------------------------------------------------------------
log_section "Step 8: Setting Up & Starting LiteLLM Service"

SERVICE_FILE="/etc/systemd/system/litellm.service"

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=LiteLLM Least-Busy Proxy Server
After=network.target network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=${LITELLM_USER}
Group=${LITELLM_USER}
WorkingDirectory=${LITELLM_DIR}
Environment="HOME=/home/${LITELLM_USER}"
Environment="LITELLM_MASTER_KEY=${MASTER_KEY}"
Environment="LITELLM_SALT_KEY=${SALT_KEY}"
Environment="DATABASE_URL=${DATABASE_URL}"
Environment="STORE_MODEL_IN_DB=True"
Environment="PYTHONUNBUFFERED=1"
Environment="PYTHONPATH=${LITELLM_DIR}"
Environment="MBP_COOLDOWN_SECONDS=${MBP_COOLDOWN_SECONDS}"
Environment="PATH=${VENV_DIR}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=${VENV_DIR}/bin/python3 -m litellm.proxy.proxy_cli --config ${LITELLM_CONFIG} --host ${LITELLM_HOST} --port ${LITELLM_PORT}
Restart=always
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

USE_SYSTEMD=false
if pidof systemd &>/dev/null || [ -d /run/systemd/system ]; then
    USE_SYSTEMD=true
    log_info "Detected active systemd init. Enabling and restarting litellm.service..."
    systemctl daemon-reload
    systemctl enable litellm.service
    systemctl restart litellm.service
else
    log_warn "Systemd not active as PID 1 in this container. Using background runner."
    log_info "Creating helper start script at /usr/local/bin/start-litellm..."
    
    cat > /usr/local/bin/start-litellm <<EOF
#!/usr/bin/env bash
export HOME="/home/${LITELLM_USER}"
export LITELLM_MASTER_KEY="${MASTER_KEY}"
export LITELLM_SALT_KEY="${SALT_KEY}"
export DATABASE_URL="${DATABASE_URL}"
export STORE_MODEL_IN_DB="True"
export PYTHONUNBUFFERED=1
export PYTHONPATH="${LITELLM_DIR}:\${PYTHONPATH:-}"
export MBP_COOLDOWN_SECONDS="${MBP_COOLDOWN_SECONDS}"
export PATH="${VENV_DIR}/bin:\$PATH"
exec ${VENV_DIR}/bin/python3 -m litellm.proxy.proxy_cli --config ${LITELLM_CONFIG} --host ${LITELLM_HOST} --port ${LITELLM_PORT}
EOF
    chmod +x /usr/local/bin/start-litellm
    
    # Kill previous instances if restarting
    pkill -f "litellm.*--config" || true
    sleep 1
    
    log_info "Starting LiteLLM proxy in background..."
    nohup /usr/local/bin/start-litellm > /var/log/litellm.log 2>&1 &
fi

# -----------------------------------------------------------------------------
# Step 9: Service Health & Readiness Polling
# -----------------------------------------------------------------------------
log_section "Step 9: Verifying Service Startup & Health"

log_info "Waiting for LiteLLM to bind port ${LITELLM_PORT} and respond to health checks..."

SERVICE_HEALTHY=false
for i in $(seq 1 45); do
    if [ "${USE_SYSTEMD}" = true ]; then
        if ! systemctl is-active --quiet litellm.service; then
            log_warn "litellm.service is not active yet (attempt ${i}/45)..."
            sleep 1
            continue
        fi
    fi

    # Check HTTP readiness endpoint
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:${LITELLM_PORT}/health/readiness" -H "Authorization: Bearer ${MASTER_KEY}" || true)
    if [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "401" ] || [ "${HTTP_CODE}" = "403" ]; then
        SERVICE_HEALTHY=true
        log_success "LiteLLM Proxy is responsive (HTTP ${HTTP_CODE})!"
        break
    fi

    # Alternative check on root/health, liveliness or models
    HTTP_CODE_ALT=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:${LITELLM_PORT}/health" || curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:${LITELLM_PORT}/health/liveliness" || true)
    if [ "${HTTP_CODE_ALT}" = "200" ] || [ "${HTTP_CODE_ALT}" = "401" ] || [ "${HTTP_CODE_ALT}" = "403" ]; then
        SERVICE_HEALTHY=true
        log_success "LiteLLM Proxy health endpoint is responsive (HTTP ${HTTP_CODE_ALT})!"
        break
    fi

    sleep 1
done

if [ "${SERVICE_HEALTHY}" = true ]; then
    log_success "LiteLLM Proxy started and verified successfully!"
else
    log_error "LiteLLM Proxy failed to become healthy within 45 seconds."
    if [ "${USE_SYSTEMD}" = true ]; then
        echo -e "\n${YELLOW}--- Systemd Service Status ---${NC}"
        systemctl status litellm.service --no-pager || true
        echo -e "\n${YELLOW}--- Recent Journal Logs (litellm.service) ---${NC}"
        journalctl -u litellm.service -n 50 --no-pager || true
    else
        echo -e "\n${YELLOW}--- /var/log/litellm.log ---${NC}"
        tail -n 50 /var/log/litellm.log || true
    fi
    exit 1
fi

# -----------------------------------------------------------------------------
# Step 10: Output Cluster Endpoints & Summary
# -----------------------------------------------------------------------------
log_section "Deployment Completed Successfully"
show_status_summary
