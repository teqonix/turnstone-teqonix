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
DEFAULT_SECRET_FILE="${SCRIPT_DIR}/secrets/postgres_admin.secret"
[ -f "${DEFAULT_SECRET_FILE}" ] || DEFAULT_SECRET_FILE="${REPO_ROOT}/secrets/postgres_admin.secret"
SYS_ADMIN_ENV="/etc/turnstone/postgres_admin.env"

SECRET_FILE="${POSTGRES_ADMIN_SECRET_FILE:-${SECRET_FILE:-}}"
POSTGRES_USER="${POSTGRES_USER:-}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
POSTGRES_HOST="${POSTGRES_HOST:-}"
POSTGRES_PORT="${POSTGRES_PORT:-}"
POSTGRES_DB="${POSTGRES_DB:-}"
EMBED_POSTGRES="${EMBED_POSTGRES:-false}"
DISABLE_STACK="${DISABLE_STACK:-false}"
PURGE_STACK="${PURGE_STACK:-false}"
TURNSTONE_USER_DEBIAN="${TURNSTONE_USER_DEBIAN:-turnstone}"
SMB_PATH="${SMB_PATH:-}"
SMB_USER="${SMB_USER:-}"
SMB_PASSWORD="${SMB_PASSWORD:-}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/home/turnstone/silo-14.lan/ai-playground}"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -u, --user, --postgres-user <user> PostgreSQL username (e.g. turnstone-np, postgres)"
    echo "  -s, --secret-file <path>           Path to secret file containing DB connection string or env vars"
    echo "  --embed-postgres                   Force running an embedded PostgreSQL container in Docker Compose"
    echo "  --workspace-dir <path>             Host workspace directory to mount into containers [default: /home/turnstone/silo-14.lan/ai-playground]"
    echo "      --smb-path <path>              Remote SMB path + protocol (e.g. smb://silo-14.lan/ai-playground)"
    echo "      --smb-user <user>              SMB username (e.g. turnstone-np)"
    echo "      --smb-pass <pass>              SMB password"
    echo "      --turnstone-user <user>        Local Debian system user [default: turnstone]"
    echo "  --disable, --stop, --down          Stop and remove coordinator containers and services"
    echo "  --purge                            When used with --disable, remove configs and volumes (/opt/turnstone-coordinator)"
    echo "  -h, --help                         Display this help message and exit"
    echo ""
    echo "Environment Variables Respected:"
    echo "  POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_HOST, POSTGRES_PORT, POSTGRES_DB,"
    echo "  POSTGRES_ADMIN_SECRET_FILE, SECRET_FILE, TURNSTONE_DB_URL, EMBED_POSTGRES,"
    echo "  WORKSPACE_DIR, SMB_PATH, SMB_USER, SMB_PASSWORD, TURNSTONE_USER_DEBIAN"
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
        --embed-postgres)
            EMBED_POSTGRES="true"
            shift
            ;;
        --workspace-dir)
            WORKSPACE_DIR="$2"
            shift 2
            ;;
        --smb-path)
            SMB_PATH="$2"
            shift 2
            ;;
        --smb-user)
            SMB_USER="$2"
            shift 2
            ;;
        --smb-pass|--smb-password)
            SMB_PASSWORD="$2"
            shift 2
            ;;
        --turnstone-user|--debian-user)
            TURNSTONE_USER_DEBIAN="$2"
            shift 2
            ;;
        --disable|--down|--stop)
            DISABLE_STACK="true"
            shift
            ;;
        --purge)
            PURGE_STACK="true"
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

parse_smb_path() {
    local raw_path="$1"
    raw_path=$(echo "${raw_path}" | tr -d '\r' | xargs)
    
    # Convert Windows-style backslashes to forward slashes
    raw_path="${raw_path//\\//}"
    
    # Strip protocol prefix (smb://, cifs://, etc.)
    local stripped="${raw_path#*://}"
    stripped="${stripped#//}"
    stripped="${stripped#/}"
    stripped="${stripped%/}"
    
    # Parse user:password@ if present
    if [[ "${stripped}" == *"@"* ]]; then
        local userinfo="${stripped%%@*}"
        stripped="${stripped#*@}"
        userinfo=$(echo "${userinfo}" | tr -d '=')
        if [[ "${userinfo}" == *":"* ]]; then
            [ -z "${SMB_USER:-}" ] && SMB_USER="${userinfo%%:*}"
            [ -z "${SMB_PASSWORD:-}" ] && SMB_PASSWORD="${userinfo#*:}"
        else
            [ -z "${SMB_USER:-}" ] && SMB_USER="${userinfo}"
        fi
    fi
    
    # Remove accidental leading '=' from hostname
    stripped="${stripped#=}"
    
    SERVER_HOSTNAME="${stripped%%/*}"
    local path_part=""
    if [[ "${stripped}" == *"/"* ]]; then
        path_part="${stripped#*/}"
        path_part="${path_part#/}"
        path_part="${path_part%/}"
    fi
    
    if [ -z "${path_part}" ] || [ "${SERVER_HOSTNAME}" = "${path_part}" ]; then
        SHARE_NAME="ai-playground"
    else
        # If user passed a full TrueNAS storage path (e.g. /mnt/silo-14/ai-playground), extract the SMB share name
        if [[ "${path_part}" =~ ^mnt/[^/]+/(.+)$ ]]; then
            SHARE_NAME="${BASH_REMATCH[1]}"
        else
            SHARE_NAME="${path_part}"
        fi
    fi
}

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

if [ "${DISABLE_STACK}" = "true" ]; then
    echo -e "${YELLOW}=================================================================${NC}"
    echo -e "${YELLOW}       Disabling Turnstone Coordinator Stack                     ${NC}"
    echo -e "${YELLOW}=================================================================${NC}"

    COORDINATOR_DIR="/opt/turnstone-coordinator"
    
    # Configure DOCKER_HOST if using podman socket
    if [ -S /run/podman/podman.sock ] && [ ! -S /var/run/docker.sock ]; then
        export DOCKER_HOST="unix:///run/podman/podman.sock"
    elif [ -S /var/run/docker.sock ]; then
        export DOCKER_HOST="unix:///var/run/docker.sock"
    fi

    if [ -d "${COORDINATOR_DIR}" ] && [ -f "${COORDINATOR_DIR}/docker-compose.yml" ]; then
        log_info "Stopping and removing coordinator containers in ${COORDINATOR_DIR}..."
        cd "${COORDINATOR_DIR}"
        if [ "${PURGE_STACK}" = "true" ]; then
            docker compose down --volumes --remove-orphans || true
            cd /
            rm -rf "${COORDINATOR_DIR}"
            rm -f /etc/turnstone/postgres_admin.env
            log_success "Coordinator stack, volumes, and configuration purged completely."
        else
            docker compose down --remove-orphans || true
            log_success "Coordinator containers stopped and removed."
        fi
    elif docker compose -p turnstone-coordinator ps &>/dev/null; then
        docker compose -p turnstone-coordinator down --remove-orphans || true
        log_success "Coordinator containers stopped."
    else
        log_warn "No running coordinator compose stack found at ${COORDINATOR_DIR}."
    fi

    exit 0
fi

# Step 2: Container Engine & Docker Compose Verification
log_info "Step 2: Checking container engine (Docker / Podman)..."

# Quiet podman emulation notice if present
mkdir -p /etc/containers 2>/dev/null || true
touch /etc/containers/nodocker 2>/dev/null || true

if command -v podman &>/dev/null && ! command -v dockerd &>/dev/null; then
    log_info "Podman detected as container engine. Ensuring 'podman.socket' is enabled and active..."
    systemctl enable --now podman.socket || true
    export DOCKER_HOST="${DOCKER_HOST:-unix:///run/podman/podman.sock}"
    log_success "Podman socket configured at ${DOCKER_HOST}."
elif [ -S /run/podman/podman.sock ] && [ ! -S /var/run/docker.sock ]; then
    log_info "Active Podman socket detected at /run/podman/podman.sock."
    export DOCKER_HOST="${DOCKER_HOST:-unix:///run/podman/podman.sock}"
else
    if ! command -v docker &> /dev/null; then
        log_info "Docker is not installed. Installing Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
        log_success "Docker installed successfully."
    else
        log_success "Docker is installed ($(docker --version 2>/dev/null || echo 'docker'))."
    fi
    systemctl enable --now docker 2>/dev/null || true
    export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
fi

if ! docker compose version &> /dev/null && ! command -v podman-compose &> /dev/null; then
    log_error "Compose plugin is missing. Please install docker-compose-plugin or podman-compose."
    exit 1
fi
log_success "Container compose environment verified."

# Step 3: Directory Structure Setup
COORDINATOR_DIR="/opt/turnstone-coordinator"
log_info "Step 3: Setting up installation directory at ${COORDINATOR_DIR}..."
mkdir -p "${COORDINATOR_DIR}"
mkdir -p "${COORDINATOR_DIR}/caddy_config"
mkdir -p "${COORDINATOR_DIR}/searxng"
mkdir -p "/mnt/storage/backups/turnstone" 2>/dev/null || mkdir -p "/var/backups/turnstone"

SEARXNG_SETTINGS_FILE="${COORDINATOR_DIR}/searxng/settings.yml"

# Remove obsolete limiter.toml that causes TypeError in modern SearXNG botdetection schema
rm -f "${COORDINATOR_DIR}/searxng/limiter.toml" 2>/dev/null || true

log_info "Configuring SearXNG settings at ${SEARXNG_SETTINGS_FILE}..."
cat > "${SEARXNG_SETTINGS_FILE}" <<EOF
# Turnstone-bundled SearxNG configuration
use_default_settings: true

server:
  secret_key: "turnstone-bundled-searxng-not-secret"
  limiter: false
  public_instance: false

search:
  formats:
    - html
    - json
EOF
chmod 644 "${SEARXNG_SETTINGS_FILE}"
log_success "Directory structure and SearXNG configuration created."

# Step 4: Environment Credentials Configuration
ENV_FILE="${COORDINATOR_DIR}/.env"
log_info "Step 4: Configuring secrets and environment (.env)..."

if [ -z "${SECRET_FILE}" ]; then
    if [ -z "${POSTGRES_USER}" ]; then
        read -r -p "Enter PostgreSQL username [e.g. turnstone-np, postgres, turnstone]: " INPUT_USER
        if [ -n "${INPUT_USER}" ]; then
            POSTGRES_USER=$(echo "${INPUT_USER}" | xargs)
        fi
    fi

    if [ -n "${POSTGRES_USER}" ]; then
        MATCHED_SECRET=$(find_secret_by_user "${POSTGRES_USER}")
        if [ -n "${MATCHED_SECRET}" ]; then
            log_info "Found matching secret file '${MATCHED_SECRET}' for PostgreSQL user '${POSTGRES_USER}'."
            SECRET_FILE="${MATCHED_SECRET}"
        fi
    fi
fi

if [ -z "${SECRET_FILE}" ]; then
    if [ -f "${DEFAULT_SECRET_FILE}" ]; then
        log_info "Default secret file found at '${DEFAULT_SECRET_FILE}'."
        read -r -p "Enter path to .secret file [press Enter to use default '${DEFAULT_SECRET_FILE}']: " INPUT_SECRET
        SECRET_FILE="${INPUT_SECRET:-${DEFAULT_SECRET_FILE}}"
    elif [ -f "${SYS_ADMIN_ENV}" ]; then
        log_info "System database configuration file found at '${SYS_ADMIN_ENV}'."
        SECRET_FILE="${SYS_ADMIN_ENV}"
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

# Preserve existing JWT secret if available, otherwise generate new
JWT_SECRET=""
if [ -f "${ENV_FILE}" ]; then
    log_info "Existing ${ENV_FILE} found. Preserving JWT secret and updating DB credentials..."
    EXISTING_JWT=$(grep '^TURNSTONE_JWT_SECRET=' "${ENV_FILE}" 2>/dev/null | cut -d'=' -f2- | tr -d '\r' | xargs || true)
    [ -n "${EXISTING_JWT}" ] && JWT_SECRET="${EXISTING_JWT}"
fi

if [ -z "${JWT_SECRET}" ]; then
    JWT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null || openssl rand -hex 32)
fi

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
log_success "Saved ${ENV_FILE} with PostgreSQL credentials for '${POSTGRES_USER}'@'${POSTGRES_HOST}'."

# Ensure local workspace directory exists and is accessible
if [ -n "${SMB_PATH}" ]; then
    parse_smb_path "${SMB_PATH}"
    WORKSPACE_DIR="/home/${TURNSTONE_USER_DEBIAN}/${SERVER_HOSTNAME}/${SHARE_NAME}"
fi

log_info "Ensuring host workspace directory exists at ${WORKSPACE_DIR}..."
mkdir -p "${WORKSPACE_DIR}"
chown -R "${TURNSTONE_USER_DEBIAN}:${TURNSTONE_USER_DEBIAN}" "${WORKSPACE_DIR}" 2>/dev/null || chown -R "${TURNSTONE_USER_DEBIAN}" "${WORKSPACE_DIR}" 2>/dev/null || true

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
      TURNSTONE_WORKSPACE: /workspace
    volumes:
      - ${REPO_ROOT}/turnstone:/app/.venv/lib/python3.14/site-packages/turnstone
      - ${WORKSPACE_DIR}:/workspace
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
      TURNSTONE_WORKSPACE: /workspace
    volumes:
      - ${REPO_ROOT}/turnstone:/app/.venv/lib/python3.14/site-packages/turnstone
      - ${WORKSPACE_DIR}:/workspace
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
log_info "Step 6: Launching Coordinator containers..."
cd "${COORDINATOR_DIR}"

if [ -z "${DOCKER_HOST:-}" ]; then
    if [ -S /run/podman/podman.sock ] && [ ! -S /var/run/docker.sock ]; then
        export DOCKER_HOST="unix:///run/podman/podman.sock"
    elif [ -S /var/run/docker.sock ]; then
        export DOCKER_HOST="unix:///var/run/docker.sock"
    fi
fi

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

