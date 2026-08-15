#!/usr/bin/env bash
# =============================================================================
# Turnstone Coordinator VM Deployment Script (TrueNAS silo-14 VM)
#
# Idempotent & User-Friendly script to deploy the Turnstone Coordinator Stack:
# PostgreSQL 18, turnstone-console, Caddy (HTTPS UI), channel gateway, & SearxNG.
# =============================================================================

set -euo pipefail

# Color Codes for Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

trap 'log_error "An error occurred on line $LINENO. Deployment stopped."; exit 1' ERR

# Determine repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." 2>/dev/null && pwd || pwd)"

# Default secret file locations
DEFAULT_SECRET_FILE="${REPO_ROOT}/secrets/postgres_admin.secret"
SYS_ADMIN_ENV="/etc/turnstone/postgres_admin.env"

SECRET_FILE="${POSTGRES_ADMIN_SECRET_FILE:-${SECRET_FILE:-}}"
POSTGRES_USER="${POSTGRES_USER:-}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
POSTGRES_HOST="${POSTGRES_HOST:-}"
POSTGRES_PORT="${POSTGRES_PORT:-}"
POSTGRES_DB="${POSTGRES_DB:-}"
EMBED_POSTGRES="${EMBED_POSTGRES:-false}"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -s, --secret-file <path> Path to secret file containing DB connection string or env vars"
    echo "  --embed-postgres         Force running an embedded PostgreSQL container in Docker Compose"
    echo "  -h, --help               Display this help message and exit"
    echo ""
    echo "Environment Variables Respected:"
    echo "  POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_HOST, POSTGRES_PORT, POSTGRES_DB,"
    echo "  POSTGRES_ADMIN_SECRET_FILE, SECRET_FILE, TURNSTONE_DB_URL, EMBED_POSTGRES"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--secret-file)
            SECRET_FILE="$2"
            shift 2
            ;;
        --embed-postgres)
            EMBED_POSTGRES="true"
            shift
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

parse_connection_uri() {
    local raw_url="$1"
    raw_url=$(echo "${raw_url}" | tr -d '\r' | xargs)
    local url="${raw_url#*://}"
    
    if [[ "${url}" == *"@"* ]]; then
        local userpass="${url%%@*}"
        local hostportdb="${url#*@}"
        
        if [ -z "${POSTGRES_USER:-}" ]; then
            local u="${userpass%%:*}"
            [ -n "${u}" ] && POSTGRES_USER="${u}"
        fi
        if [ -z "${POSTGRES_PASSWORD:-}" ] && [[ "${userpass}" == *":"* ]]; then
            local p="${userpass#*:}"
            [ -n "${p}" ] && POSTGRES_PASSWORD="${p}"
        fi
        
        local hostport="${hostportdb%%/*}"
        if [[ "${hostportdb}" == *"/"* ]]; then
            local db_in_url="${hostportdb#*/}"
            db_in_url="${db_in_url%%[?#]*}"
            if [ -n "${db_in_url}" ] && [ -z "${POSTGRES_DB:-}" ]; then
                POSTGRES_DB="${db_in_url}"
            fi
        fi
        
        if [ -z "${POSTGRES_HOST:-}" ]; then
            local h="${hostport%%:*}"
            [ -n "${h}" ] && POSTGRES_HOST="${h}"
        fi
        if [ -z "${POSTGRES_PORT:-}" ] && [[ "${hostport}" == *":"* ]]; then
            local pt="${hostport#*:}"
            [ -n "${pt}" ] && POSTGRES_PORT="${pt}"
        fi
    fi
}

load_secrets() {
    local target_file=""

    if [ -n "${SECRET_FILE}" ] && [ -f "${SECRET_FILE}" ]; then
        target_file="${SECRET_FILE}"
    elif [ -f "${DEFAULT_SECRET_FILE}" ]; then
        target_file="${DEFAULT_SECRET_FILE}"
    elif [ -f "${SYS_ADMIN_ENV}" ]; then
        target_file="${SYS_ADMIN_ENV}"
    fi

    if [ -n "${target_file}" ] && [ -f "${target_file}" ]; then
        log_info "Sourcing database connection credentials from '${target_file}'..."
        
        local first_line
        first_line=$(grep -v '^[[:space:]]*#' "${target_file}" | grep -v '^[[:space:]]*$' | tr -d '\r' | head -n 1 || true)
        
        if [[ "${first_line}" == *"://"* ]] || [[ "${first_line}" == *"@"* ]]; then
            parse_connection_uri "${first_line}"
        elif [[ "${first_line}" == *"="* ]]; then
            local cli_user="${POSTGRES_USER}"
            local cli_pass="${POSTGRES_PASSWORD}"
            local cli_host="${POSTGRES_HOST}"
            local cli_port="${POSTGRES_PORT}"
            local cli_db="${POSTGRES_DB}"

            set +e
            source "${target_file}"
            set -e

            POSTGRES_USER="${cli_user:-${POSTGRES_USER:-${POSTGRES_ADMIN_USER:-${POSTGRES_USER:-${PGUSER:-}}}}}"
            POSTGRES_PASSWORD="${cli_pass:-${POSTGRES_PASSWORD:-${POSTGRES_ADMIN_PASS:-${POSTGRES_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-${POSTGRES_PASS:-${PGPASSWORD:-}}}}}}}"
            POSTGRES_HOST="${cli_host:-${POSTGRES_HOST:-${PGHOST:-}}}"
            POSTGRES_PORT="${cli_port:-${POSTGRES_PORT:-${PGPORT:-}}}"
            POSTGRES_DB="${cli_db:-${POSTGRES_DB:-${TARGET_DB:-${POSTGRES_DATABASE:-}}}}"

            if [ -n "${TURNSTONE_DB_URL:-}" ]; then
                parse_connection_uri "${TURNSTONE_DB_URL}"
            elif [ -n "${DATABASE_URL:-}" ]; then
                parse_connection_uri "${DATABASE_URL}"
            fi
        fi
    fi
}

echo -e "${BLUE}=================================================================${NC}"
echo -e "${BLUE}       Turnstone Coordinator Stack Deployment (silo-14 VM)       ${NC}"
echo -e "${BLUE}=================================================================${NC}"

# Step 1: Root / Sudo Check
log_info "Step 1: Checking permissions..."
if [ "$EUID" -ne 0 ]; then
    log_warn "This script should be run with sudo or as root to configure directories and Docker services."
    log_warn "Re-running with sudo..."
    exec sudo bash "$0" "$@"
fi
log_success "Permissions verified."

# Step 2: Docker & Docker Compose Verification
log_info "Step 2: Checking Docker and Docker Compose installation..."
if ! command -v docker &> /dev/null; then
    log_info "Docker is not installed. Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    log_success "Docker installed successfully."
else
    log_success "Docker is already installed ($(docker --version))."
fi

if ! docker compose version &> /dev/null; then
    log_error "Docker Compose plugin is missing. Please install docker-compose-plugin."
    exit 1
fi
log_success "Docker Compose verified."

# Step 3: Directory Structure Setup
COORDINATOR_DIR="/opt/turnstone-coordinator"
log_info "Step 3: Setting up installation directory at ${COORDINATOR_DIR}..."
mkdir -p "${COORDINATOR_DIR}"
mkdir -p "${COORDINATOR_DIR}/caddy_config"
mkdir -p "${COORDINATOR_DIR}/searxng"
mkdir -p "/mnt/storage/backups/turnstone" 2>/dev/null || mkdir -p "/var/backups/turnstone"

SEARXNG_SETTINGS_FILE="${COORDINATOR_DIR}/searxng/settings.yml"
SEARXNG_LIMITER_FILE="${COORDINATOR_DIR}/searxng/limiter.toml"

if [ ! -f "${SEARXNG_LIMITER_FILE}" ]; then
    cat > "${SEARXNG_LIMITER_FILE}" <<EOF
# SearXNG Limiter Configuration
[real_ip]
x_for = 0

[botdetection.ip_limit]
default = 0
EOF
    chmod 644 "${SEARXNG_LIMITER_FILE}"
fi

log_info "Configuring SearXNG settings at ${SEARXNG_SETTINGS_FILE}..."
SEARXNG_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null || openssl rand -hex 32)
cat > "${SEARXNG_SETTINGS_FILE}" <<EOF
use_default_settings: true
server:
  secret_key: "${SEARXNG_SECRET}"
  limiter: false
  image_proxy: true
search:
  safe_search: 0
  autocomplete: ""
  default_lang: ""
  formats:
    - html
    - json
engines:
  - name: wikidata
    engine: wikidata
    disabled: true
  - name: ahmia
    engine: ahmia
    disabled: true
  - name: torch
    engine: torch
    disabled: true
EOF
chmod 644 "${SEARXNG_SETTINGS_FILE}"
log_success "Directory structure and SearXNG configuration created."

# Step 4: Environment Credentials Configuration
ENV_FILE="${COORDINATOR_DIR}/.env"
log_info "Step 4: Configuring secrets and environment (.env)..."

if [ -z "${SECRET_FILE}" ]; then
    if [ -f "${SYS_ADMIN_ENV}" ]; then
        log_info "System database configuration file found at '${SYS_ADMIN_ENV}'."
        SECRET_FILE="${SYS_ADMIN_ENV}"
    elif [ -f "${DEFAULT_SECRET_FILE}" ]; then
        log_info "Default secret file found at '${DEFAULT_SECRET_FILE}'."
        read -r -p "Enter path to .secret file [press Enter to use default '${DEFAULT_SECRET_FILE}']: " INPUT_SECRET
        SECRET_FILE="${INPUT_SECRET:-${DEFAULT_SECRET_FILE}}"
    else
        echo ""
        read -r -p "Enter path to .secret file containing DB connection string [leave blank to enter DB details interactively]: " INPUT_SECRET
        if [ -n "${INPUT_SECRET}" ]; then
            SECRET_FILE="${INPUT_SECRET}"
        fi
    fi
fi

if [ -n "${SECRET_FILE}" ]; then
    if [ ! -f "${SECRET_FILE}" ]; then
        log_error "Secret file '${SECRET_FILE}' not found!"
        exit 1
    fi
    load_secrets
fi

if [ -z "${POSTGRES_HOST}" ]; then
    read -r -p "Enter central PostgreSQL host IP / hostname [leave blank for local embedded DB]: " INPUT_HOST
    POSTGRES_HOST="${INPUT_HOST}"
fi

POSTGRES_USER="${POSTGRES_USER:-turnstone}"
POSTGRES_HOST="${POSTGRES_HOST:-postgres}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-turnstone}"

if [ -z "${POSTGRES_PASSWORD}" ]; then
    if [ "${POSTGRES_HOST}" != "postgres" ] && [ "${POSTGRES_HOST}" != "localhost" ] && [ "${POSTGRES_HOST}" != "127.0.0.1" ]; then
        read -r -s -p "Enter PostgreSQL Password for '${POSTGRES_USER}'@'${POSTGRES_HOST}': " INPUT_PASS
        echo ""
        POSTGRES_PASSWORD="${INPUT_PASS}"
    else
        POSTGRES_PASSWORD=$(python3 -c "import secrets; print(secrets.token_hex(24))" 2>/dev/null || openssl rand -hex 24)
        log_info "Auto-generated secure PostgreSQL password."
    fi
fi

mkdir -p /etc/turnstone
if [ ! -f "${SYS_ADMIN_ENV}" ]; then
    cat > "${SYS_ADMIN_ENV}" <<EOF
# Turnstone PostgreSQL Connection Credentials
POSTGRES_ADMIN_USER=${POSTGRES_USER}
POSTGRES_ADMIN_PASS=${POSTGRES_PASSWORD}
POSTGRES_HOST=${POSTGRES_HOST}
POSTGRES_PORT=${POSTGRES_PORT}
POSTGRES_DB=${POSTGRES_DB}
EOF
    chmod 600 "${SYS_ADMIN_ENV}"
    log_info "Saved database connection credentials to '${SYS_ADMIN_ENV}'."
fi

if [ ! -f "${ENV_FILE}" ]; then
    log_info "Generating new secure environment configuration..."
    JWT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null || openssl rand -hex 32)
    
    cat > "${ENV_FILE}" <<EOF
# Turnstone Coordinator Environment Configuration
TURNSTONE_JWT_SECRET=${JWT_SECRET}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_HOST=${POSTGRES_HOST}
POSTGRES_PORT=${POSTGRES_PORT}
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_MAX_CONNECTIONS=300
CONSOLE_HTTPS_PORT=9443
SEARXNG_API_PORT=8081
SEARXNG_HTTPS_PORT=8444
TURNSTONE_HOST_IP=0.0.0.0
EOF
    chmod 600 "${ENV_FILE}"
    log_success "Created ${ENV_FILE} with PostgreSQL credentials and generated JWT secret."
else
    log_info "Existing ${ENV_FILE} found. Preserving current secrets."
    source "${ENV_FILE}"
    if [ -n "${SECRET_FILE}" ]; then
        log_info "Updating PostgreSQL credentials in ${ENV_FILE} from '${SECRET_FILE}'..."
        sed -i '/^POSTGRES_USER=/d' "${ENV_FILE}"
        sed -i '/^POSTGRES_PASSWORD=/d' "${ENV_FILE}"
        sed -i '/^POSTGRES_HOST=/d' "${ENV_FILE}"
        sed -i '/^POSTGRES_PORT=/d' "${ENV_FILE}"
        sed -i '/^POSTGRES_DB=/d' "${ENV_FILE}"
        cat >> "${ENV_FILE}" <<EOF
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_HOST=${POSTGRES_HOST}
POSTGRES_PORT=${POSTGRES_PORT}
POSTGRES_DB=${POSTGRES_DB}
EOF
    fi
fi

# Step 5: Generate docker-compose.yaml for Coordinator Services
COMPOSE_FILE="${COORDINATOR_DIR}/docker-compose.yml"
log_info "Step 5: Writing Coordinator Docker Compose specification..."

USE_EMBEDDED_POSTGRES=false
if [ "${EMBED_POSTGRES}" = "true" ] || [ "${POSTGRES_HOST:-}" = "postgres" ] || [ "${POSTGRES_HOST:-}" = "localhost" ] || [ "${POSTGRES_HOST:-}" = "127.0.0.1" ] || [ -z "${POSTGRES_HOST:-}" ]; then
    USE_EMBEDDED_POSTGRES=true
fi

if [ "${USE_EMBEDDED_POSTGRES}" = "true" ]; then
    log_info "Configuring Coordinator with embedded PostgreSQL container service..."
else
    log_info "Configuring Coordinator to connect to central PostgreSQL server at ${POSTGRES_HOST}:${POSTGRES_PORT:-5432}..."
fi

cat > "${COMPOSE_FILE}" <<EOF
name: turnstone-coordinator

networks:
  turnstone-net:
    driver: bridge

volumes:
$(if [ "${USE_EMBEDDED_POSTGRES}" = "true" ]; then echo "  postgres-data:"; fi)
  caddy-data:
  caddy-config:
  searxng-cache:

services:
$(if [ "${USE_EMBEDDED_POSTGRES}" = "true" ]; then cat <<'PGEOF'
  postgres:
    image: pgautoupgrade/pgautoupgrade:18-alpine
    shm_size: '2gb'
    command:
      - postgres
      - -c
      - max_connections=${POSTGRES_MAX_CONNECTIONS:-300}
      - -c
      - shared_buffers=1024MB
    environment:
      POSTGRES_DB: ${POSTGRES_DB:-turnstone}
      POSTGRES_USER: ${POSTGRES_USER:-turnstone}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      PGDATA: /var/lib/postgresql/data
    ports:
      - "0.0.0.0:${POSTGRES_PORT:-5432}:5432"
    volumes:
      - postgres-data:/var/lib/postgresql/data
    networks:
      - turnstone-net
    healthcheck:
      test: [ "CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-turnstone}" ]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 20s
    restart: unless-stopped
PGEOF
fi)

  console:
    image: ghcr.io/turnstonelabs/turnstone:latest
    command:
      - turnstone-console
      - --host=0.0.0.0
      - --port=8090
    ports:
      - "0.0.0.0:8090:8090"
    environment:
      TURNSTONE_JWT_SECRET: \${TURNSTONE_JWT_SECRET}
      TURNSTONE_DB_BACKEND: postgresql
      TURNSTONE_DB_URL: postgresql+psycopg://\${POSTGRES_USER}:\${POSTGRES_PASSWORD}@\${POSTGRES_HOST:-postgres}:\${POSTGRES_PORT:-5432}/\${POSTGRES_DB:-turnstone}
      TURNSTONE_CONSOLE_URL: http://console:8090
    volumes:
      - ${REPO_ROOT}/turnstone:/app/.venv/lib/python3.14/site-packages/turnstone
    networks:
      - turnstone-net
$(if [ "${USE_EMBEDDED_POSTGRES}" = "true" ]; then cat <<'DEPSEOF'
    depends_on:
      postgres:
        condition: service_healthy
DEPSEOF
fi)
    healthcheck:
      test: [ "CMD", "python", "/usr/local/bin/healthcheck.py", "http://127.0.0.1:8090/health" ]
      interval: 10s
      timeout: 5s
      retries: 3
    restart: unless-stopped

  caddy:
    image: caddy:2.11
    depends_on:
      - console
    ports:
      - "\${CONSOLE_HTTPS_PORT:-9443}:443"
      - "127.0.0.1:\${SEARXNG_HTTPS_PORT:-8444}:8444"
    volumes:
      - caddy-data:/data
      - caddy-config:/config
    networks:
      - turnstone-net
    restart: unless-stopped

  channel:
    image: ghcr.io/turnstonelabs/turnstone:latest
    command:
      - turnstone-channel
      - --http-host=0.0.0.0
    environment:
      TURNSTONE_JWT_SECRET: \${TURNSTONE_JWT_SECRET}
      TURNSTONE_DB_BACKEND: postgresql
      TURNSTONE_DB_URL: postgresql+psycopg://\${POSTGRES_USER}:\${POSTGRES_PASSWORD}@\${POSTGRES_HOST:-postgres}:\${POSTGRES_PORT:-5432}/\${POSTGRES_DB:-turnstone}
      TURNSTONE_CHANNEL_ADVERTISE_URL: http://channel:8091
    volumes:
      - ${REPO_ROOT}/turnstone:/app/.venv/lib/python3.14/site-packages/turnstone
    networks:
      - turnstone-net
$(if [ "${USE_EMBEDDED_POSTGRES}" = "true" ]; then cat <<'DEPSEOF'
    depends_on:
      postgres:
        condition: service_healthy
DEPSEOF
fi)
    restart: unless-stopped

  searxng:
    image: searxng/searxng:latest
    ports:
      - "0.0.0.0:8081:8080"
    volumes:
      - ./searxng:/etc/searxng
      - searxng-cache:/var/cache/searxng
    networks:
      - turnstone-net
    healthcheck:
      test: [ "CMD", "wget", "--spider", "-q", "http://localhost:8080/healthz" ]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped
EOF
log_success "Docker Compose specification written."

# Step 6: Deploy / Update Coordinator Stack
log_info "Step 6: Launching Coordinator Docker containers..."
cd "${COORDINATOR_DIR}"
docker compose pull --quiet || true
docker compose up -d

if [ "${USE_EMBEDDED_POSTGRES}" = "true" ]; then
    log_info "Waiting for embedded PostgreSQL and Console containers to become healthy..."
    docker compose exec postgres pg_isready -U "${POSTGRES_USER:-turnstone}" -t 30 || sleep 5
else
    log_info "Coordinator containers deployed! Connecting to central PostgreSQL at ${POSTGRES_HOST}:${POSTGRES_PORT:-5432}..."
fi
log_success "Coordinator containers are running!"

# Step 7: Print Connection Details for Node Setup
echo -e "${GREEN}=================================================================${NC}"
echo -e "${GREEN}      Turnstone Coordinator VM Deployed Successfully!            ${NC}"
echo -e "${GREEN}=================================================================${NC}"
source "${ENV_FILE}"
IP_ADDR=$(hostname -I | awk '{print $1}')
echo -e "${BLUE}Dashboard Web UI:${NC} https://${IP_ADDR}:9443"
echo -e "${BLUE}PostgreSQL URL:${NC} postgresql+psycopg://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST:-${IP_ADDR}}:${POSTGRES_PORT:-5432}/${POSTGRES_DB:-turnstone}"
echo -e "${BLUE}ACME Console URL:${NC} http://${IP_ADDR}:8090"
echo -e "${BLUE}SearxNG API URL:${NC} http://${IP_ADDR}:8081"
echo -e "${YELLOW}JWT Secret:${NC} ${TURNSTONE_JWT_SECRET}"
echo -e "${GREEN}=================================================================${NC}"
echo -e "Save these credentials for configuring your physical LLM worker nodes!"

