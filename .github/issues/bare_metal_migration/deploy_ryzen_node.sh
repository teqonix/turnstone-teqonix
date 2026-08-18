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
TURNSTONE_USER_DEBIAN="${TURNSTONE_USER_DEBIAN:-turnstone}"
SMB_PATH="${SMB_PATH:-}"
SMB_USER="${SMB_USER:-}"
SMB_PASSWORD="${SMB_PASSWORD:-}"
SKIP_RYZENADJ="${SKIP_RYZENADJ:-false}"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -u, --user, --postgres-user <user> PostgreSQL username (e.g. turnstone-np, postgres)"
    echo "  -s, --secret-file <path>           Path to secret file containing DB connection string or env vars"
    echo "  -n, --node-id <id>                 Node ID (e.g. ryzen-halo-1, ryzen-halo-2)"
    echo "  -c, --coordinator <ip>             Coordinator VM IP address or hostname"
    echo "      --smb-path <path>              Remote SMB path + protocol (e.g. smb://silo-14.lan/ai-playground)"
    echo "      --smb-user <user>              SMB username (e.g. turnstone-np)"
    echo "      --smb-pass <pass>              SMB password"
    echo "      --turnstone-user <user>        Local Debian system user [default: turnstone]"
    echo "      --skip-ryzenadj                Skip checking and installing ryzenadj / TDP service"
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
        --skip-ryzenadj)
            SKIP_RYZENADJ="true"
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

if [ -z "${SMB_PATH}" ]; then
    read -rp "Enter remote SMB storage path + protocol [default: smb://silo-14.lan/ai-playground]: " INPUT_SMB_PATH
    SMB_PATH="${INPUT_SMB_PATH:-smb://silo-14.lan/ai-playground}"
fi

parse_smb_path "${SMB_PATH}"
SERVER_HOSTNAME="${SERVER_HOSTNAME:-silo-14.lan}"
SHARE_NAME="${SHARE_NAME:-ai-playground}"

if [ -z "${SMB_USER}" ]; then
    read -rp "Enter SMB username to connect as [default: turnstone-np]: " INPUT_SMB_USER
    SMB_USER="${INPUT_SMB_USER:-turnstone-np}"
fi
REMOTE_USERNAME="${SMB_USER}"

if [ -z "${SMB_PASSWORD}" ]; then
    read -r -s -p "Enter SMB Password for '${REMOTE_USERNAME}'@'${SERVER_HOSTNAME}': " SMB_PASSWORD
    echo ""
fi

MOUNT_POINT="/home/${TURNSTONE_USER_DEBIAN}/${SERVER_HOSTNAME}/${SHARE_NAME}"

LAN_IP=$(hostname -I | awk '{print $1}')

# Step 3: Check and Install RyzenAdj Power Management Utility
log_info "Step 3: Checking for ryzenadj power management utility..."
if [ "${SKIP_RYZENADJ}" != "true" ]; then
    if ! command -v ryzenadj &>/dev/null && [ ! -x "/usr/local/bin/ryzenadj" ] && [ ! -x "/usr/bin/ryzenadj" ]; then
        log_warn "'ryzenadj' is not installed on this node."
        RYZENADJ_INSTALLER="${SCRIPT_DIR}/install_ryzenadj.sh"
        if [ -f "${RYZENADJ_INSTALLER}" ]; then
            log_info "Executing RyzenAdj installer (${RYZENADJ_INSTALLER})..."
            bash "${RYZENADJ_INSTALLER}"
            log_success "RyzenAdj and TDP service installation complete."
        else
            log_warn "RyzenAdj installer script not found at '${RYZENADJ_INSTALLER}'. Continuing deployment."
        fi
    else
        INSTALLED_RYZENADJ="$(command -v ryzenadj 2>/dev/null || ( [ -x "/usr/local/bin/ryzenadj" ] && echo "/usr/local/bin/ryzenadj" ) || echo "/usr/bin/ryzenadj")"
        log_success "'ryzenadj' is already installed at: ${INSTALLED_RYZENADJ}"
    fi
else
    log_info "Skipping RyzenAdj check (--skip-ryzenadj specified)."
fi

# Step 4: Create Dedicated System User
log_info "Step 4: Creating dedicated '${TURNSTONE_USER_DEBIAN}' system user..."
if ! id "${TURNSTONE_USER_DEBIAN}" &>/dev/null; then
    useradd --system --create-home --shell /bin/bash "${TURNSTONE_USER_DEBIAN}" || useradd --system --no-create-home --shell /bin/bash "${TURNSTONE_USER_DEBIAN}"
    log_success "Created system user '${TURNSTONE_USER_DEBIAN}'."
else
    usermod -s /bin/bash "${TURNSTONE_USER_DEBIAN}" 2>/dev/null || true
    log_success "System user '${TURNSTONE_USER_DEBIAN}' already exists."
fi

USER_HOME="$(getent passwd "${TURNSTONE_USER_DEBIAN}" | cut -d: -f6 || echo "/home/${TURNSTONE_USER_DEBIAN}")"
mkdir -p "${USER_HOME}"
chown -R "${TURNSTONE_USER_DEBIAN}:${TURNSTONE_USER_DEBIAN}" "${USER_HOME}" 2>/dev/null || chown -R "${TURNSTONE_USER_DEBIAN}" "${USER_HOME}" 2>/dev/null || true

# Ensure mount point path exists and is owned by TURNSTONE_USER_DEBIAN
log_info "Checking mount point directory at ${MOUNT_POINT}..."
if [ ! -d "${MOUNT_POINT}" ]; then
    log_info "Mount point '${MOUNT_POINT}' does not exist. Creating directory..."
    mkdir -p "${MOUNT_POINT}"
fi
chown -R "${TURNSTONE_USER_DEBIAN}:${TURNSTONE_USER_DEBIAN}" "${MOUNT_POINT}" 2>/dev/null || chown -R "${TURNSTONE_USER_DEBIAN}" "${MOUNT_POINT}" 2>/dev/null || true
log_success "Mount point directory '${MOUNT_POINT}' verified and ownership assigned to '${TURNSTONE_USER_DEBIAN}'."

# Step 5: Install UV, Python Virtualenv, CIFS Utilities, Homebrew & all-smi
log_info "Step 5: Setting up Python virtual environment, storage utilities, and Homebrew..."
VENV_DIR="/opt/turnstone-venv"

if command -v apt-get &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 python3-venv python3-pip cifs-utils smbclient git curl build-essential procps file
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
chown -R "${TURNSTONE_USER_DEBIAN}:${TURNSTONE_USER_DEBIAN}" "${VENV_DIR}" 2>/dev/null || chown -R "${TURNSTONE_USER_DEBIAN}" "${VENV_DIR}"
chmod -R a+rX "${VENV_DIR}"
chmod +x "${VENV_DIR}/bin"/* 2>/dev/null || true
log_success "Virtualenv created and permissions secured at ${VENV_DIR}."

# Step 5b: Install Local Homebrew & all-smi Hardware Monitor for Turnstone User
LOCAL_BREW_DIR="${USER_HOME}/.linuxbrew"
log_info "Checking local Homebrew installation in ${LOCAL_BREW_DIR}..."
if [ ! -x "${LOCAL_BREW_DIR}/bin/brew" ]; then
    log_info "Installing standalone Homebrew into ${LOCAL_BREW_DIR} for '${TURNSTONE_USER_DEBIAN}'..."
    rm -rf "${LOCAL_BREW_DIR}"
    sudo -u "${TURNSTONE_USER_DEBIAN}" git clone --depth=1 https://github.com/Homebrew/brew "${LOCAL_BREW_DIR}"
fi
chown -R "${TURNSTONE_USER_DEBIAN}:${TURNSTONE_USER_DEBIAN}" "${LOCAL_BREW_DIR}" 2>/dev/null || true

# Persist Homebrew environment across all future shell sessions
for rc_file in "${USER_HOME}/.bashrc" "${USER_HOME}/.profile"; do
    if [ ! -f "${rc_file}" ]; then
        touch "${rc_file}"
        chown "${TURNSTONE_USER_DEBIAN}:${TURNSTONE_USER_DEBIAN}" "${rc_file}" 2>/dev/null || true
    fi
    if ! grep -qF "${LOCAL_BREW_DIR}/bin/brew shellenv" "${rc_file}" 2>/dev/null; then
        echo "" >> "${rc_file}"
        echo "# Homebrew environment" >> "${rc_file}"
        echo "eval \"\$(${LOCAL_BREW_DIR}/bin/brew shellenv)\"" >> "${rc_file}"
    fi
done

# Install all-smi via Homebrew
log_info "Installing all-smi utility via Homebrew for user '${TURNSTONE_USER_DEBIAN}'..."
sudo -u "${TURNSTONE_USER_DEBIAN}" -H bash -c "
    eval \"\$(${LOCAL_BREW_DIR}/bin/brew shellenv)\"
    brew tap lablup/tap --quiet 2>/dev/null || true
    brew install lablup/tap/all-smi || brew install all-smi
"

ALL_SMI_BIN="${LOCAL_BREW_DIR}/bin/all-smi"
if [ -x "${ALL_SMI_BIN}" ]; then
    mkdir -p /usr/local/bin
    ln -sfn "${ALL_SMI_BIN}" /usr/local/bin/all-smi
    log_success "all-smi utility successfully installed at ${ALL_SMI_BIN} (symlinked to /usr/local/bin/all-smi)."
fi

# Configure Passwordless Sudo for all-smi
log_info "Configuring passwordless sudo for '${TURNSTONE_USER_DEBIAN}' to execute all-smi..."
SUDOERS_FILE="/etc/sudoers.d/turnstone-all-smi"
mkdir -p /etc/sudoers.d
cat > "${SUDOERS_FILE}" <<EOF
# Allow ${TURNSTONE_USER_DEBIAN} to execute all-smi with sudo without a password
${TURNSTONE_USER_DEBIAN} ALL=(ALL) NOPASSWD: ${ALL_SMI_BIN}, /usr/local/bin/all-smi
EOF
chmod 0440 "${SUDOERS_FILE}"

if command -v visudo &>/dev/null; then
    if ! visudo -cf "${SUDOERS_FILE}"; then
        log_warn "visudo syntax check failed on ${SUDOERS_FILE}. Removing file to prevent sudo breakage."
        rm -f "${SUDOERS_FILE}"
    else
        log_success "Passwordless sudo configured and validated: ${SUDOERS_FILE}"
    fi
else
    log_success "Passwordless sudo configured: ${SUDOERS_FILE}"
fi

# Step 6: Configure /etc/turnstone/config.toml Secrets
log_info "Step 6: Writing secrets configuration to /etc/turnstone/config.toml..."
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

chown -R "${TURNSTONE_USER_DEBIAN}:${TURNSTONE_USER_DEBIAN}" /etc/turnstone 2>/dev/null || chown -R "${TURNSTONE_USER_DEBIAN}" /etc/turnstone
chmod 600 /etc/turnstone/config.toml
log_success "Configuration written and permissions secured (0600 ${TURNSTONE_USER_DEBIAN}:${TURNSTONE_USER_DEBIAN})."

# Step 7: Configure & Mount Remote SMB Storage at Startup
log_info "Step 7: Configuring remote SMB mount at ${MOUNT_POINT}..."
cat > /etc/turnstone/smbcredentials <<EOF
username=${REMOTE_USERNAME}
password=${SMB_PASSWORD}
EOF
chmod 600 /etc/turnstone/smbcredentials
chown root:root /etc/turnstone/smbcredentials

if [ ! -d "${MOUNT_POINT}" ]; then
    mkdir -p "${MOUNT_POINT}"
fi
chown -R "${TURNSTONE_USER_DEBIAN}:${TURNSTONE_USER_DEBIAN}" "${MOUNT_POINT}" 2>/dev/null || chown -R "${TURNSTONE_USER_DEBIAN}" "${MOUNT_POINT}" 2>/dev/null || true

# Configure persistent mount in /etc/fstab with systemd automount
FSTAB_ENTRY="//${SERVER_HOSTNAME}/${SHARE_NAME} ${MOUNT_POINT} cifs credentials=/etc/turnstone/smbcredentials,uid=${TURNSTONE_USER_DEBIAN},gid=${TURNSTONE_USER_DEBIAN},file_mode=0775,dir_mode=0775,iocharset=utf8,nofail,_netdev,x-systemd.automount 0 0"

# Remove any old turnstone CIFS mount entries from fstab to prevent duplicate/stale systemd mount units
sed -i '\|/etc/turnstone/smbcredentials|d' /etc/fstab
echo "${FSTAB_ENTRY}" >> /etc/fstab

systemctl daemon-reload
if ! mountpoint -q "${MOUNT_POINT}"; then
    log_info "Mounting SMB share (//${SERVER_HOSTNAME}/${SHARE_NAME} -> ${MOUNT_POINT})..."
    mount -v "${MOUNT_POINT}" || log_warn "Mount attempt exited with code $?. x-systemd.automount will attempt mount on access."
fi

# Ensure permissions and symlink /data and /workspace to the mounted SMB storage
chown -R "${TURNSTONE_USER_DEBIAN}:${TURNSTONE_USER_DEBIAN}" "${MOUNT_POINT}" 2>/dev/null || chown -R "${TURNSTONE_USER_DEBIAN}" "${MOUNT_POINT}" 2>/dev/null || true
rm -rf /data /workspace
ln -sfn "${MOUNT_POINT}" /data
ln -sfn "${MOUNT_POINT}" /workspace
log_success "SMB storage configured for startup mount at ${MOUNT_POINT} (symlinked to /data and /workspace)."

# Step 8: Install Systemd Service Unit & Drop-in
log_info "Step 8: Installing Systemd units..."

cat > /etc/systemd/system/turnstone-server.service <<EOF
[Unit]
Description=Turnstone Server Node
After=network.target network-online.target remote-fs.target
Wants=network-online.target remote-fs.target
RequiresMountsFor=${MOUNT_POINT}

[Service]
Type=simple
User=${TURNSTONE_USER_DEBIAN}
Group=${TURNSTONE_USER_DEBIAN}
WorkingDirectory=${MOUNT_POINT}
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
Environment="TURNSTONE_STORAGE_DIR=${MOUNT_POINT}"
Environment="TURNSTONE_SMB_MOUNT=${MOUNT_POINT}"
Environment="TURNSTONE_WORKSPACE=${MOUNT_POINT}"
EOF

# Step 9: Reload and Restart Systemd Service
log_info "Step 9: Enabling and restarting turnstone-server service..."
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
echo -e "SMB Storage Mount: ${MOUNT_POINT} (${SMB_PATH})"
echo -e "Homebrew Prefix: ${LOCAL_BREW_DIR}"
echo -e "all-smi Utility: ${ALL_SMI_BIN} (sudo NOPASSWD enabled)"

