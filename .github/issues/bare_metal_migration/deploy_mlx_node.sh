#!/usr/bin/env bash
# =============================================================================
# Turnstone LLM Node 1 (Apple Silicon M5 Max - mbp-ai-core.lan) Deployment
#
# Installs Apple MLX server (mlx-lm.server) + bare-metal turnstone-server,
# configures 384k context window, and sets up macOS launchd services.
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
COORDINATOR_IP="${COORDINATOR_IP:-}"
JWT_SECRET="${JWT_SECRET:-}"
SMB_PATH="${SMB_PATH:-}"
SMB_USER="${SMB_USER:-}"
SMB_PASSWORD="${SMB_PASSWORD:-}"
TURNSTONE_USER="${TURNSTONE_USER:-}"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -u, --user, --postgres-user <user> PostgreSQL username (e.g. turnstone-np, postgres)"
    echo "  -s, --secret-file <path>           Path to secret file containing DB connection string or env vars"
    echo "  -c, --coordinator <ip>             Coordinator VM IP address or hostname"
    echo "      --smb-path <path>              Remote SMB path + protocol (e.g. smb://silo-14.lan/ai-playground)"
    echo "      --smb-user <user>              SMB username (e.g. turnstone-np)"
    echo "      --smb-pass <pass>              SMB password"
    echo "      --turnstone-user <user>        Local system user [default: turnstone or current user]"
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
        --turnstone-user|--local-user)
            TURNSTONE_USER="$2"
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
        SHARE_NAME="ai_playground"
    else
        # If user passed a full TrueNAS storage path (e.g. /mnt/silo-14/ai_playground), extract the SMB share name
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
echo -e "${BLUE}   Turnstone Node 1 Deployment (M5 Max MacBook Pro - MLX Engine)  ${NC}"
echo -e "${BLUE}=================================================================${NC}"

# macOS User Session Check
if [ "$EUID" -eq 0 ]; then
    if [ -n "${SUDO_USER:-}" ]; then
        log_warn "On macOS, MLX Server and LaunchAgents must run as the regular login user ('${SUDO_USER}'), not root."
        log_info "Switching execution to user '${SUDO_USER}'..."
        exec sudo -u "${SUDO_USER}" -i bash -c "cd '$(pwd)' && '$0' $*"
    else
        log_warn "Running as root on macOS is discouraged for user LaunchAgents."
    fi
fi

# Step 1: Prompt / Environment Credentials
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

MOUNT_POINT="/mnt/${SERVER_HOSTNAME}/${REMOTE_USERNAME}/${SHARE_NAME}"

NODE_ID="mbp-ai-core"
LAN_IP=$(ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | head -n 1)

# Step 2: Check Python & UV Installation
log_info "Step 2: Checking Python 3 and UV package manager..."
export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv &> /dev/null; then
    log_info "Installing uv package manager..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi
log_success "Package manager verified."

# Step 3: Set up MLX and Turnstone Virtual Environments
if [ -z "${TURNSTONE_USER}" ]; then
    if id "turnstone" &>/dev/null; then
        TURNSTONE_USER="turnstone"
    else
        TURNSTONE_USER="$(whoami)"
    fi
fi

if [ "${TURNSTONE_USER}" = "$(whoami)" ]; then
    USER_HOME="${HOME}"
else
    USER_HOME="$(dscl . -read "/Users/${TURNSTONE_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || eval echo "~${TURNSTONE_USER}")"
fi

mkdir -p "${USER_HOME}"

VENV_DIR="$HOME/.local/share/turnstone-venv"
log_info "Step 3: Creating virtual environment at ${VENV_DIR}..."
mkdir -p "$HOME/.local/share"
if [ ! -d "${VENV_DIR}" ]; then
    uv venv "${VENV_DIR}" --python 3.12
fi
log_info "Installing mlx-lm, turnstone, and psycopg packages into virtualenv..."
if [ -f "${REPO_ROOT}/pyproject.toml" ]; then
    uv pip install --python "${VENV_DIR}" mlx-lm "psycopg[binary]"
    uv pip install --python "${VENV_DIR}" --reinstall "${REPO_ROOT}"
else
    uv pip install --python "${VENV_DIR}" mlx-lm turnstone "psycopg[binary]"
fi
log_success "MLX and Turnstone installed successfully."

# Step 3b: Install Local Homebrew & all-smi Hardware Monitor for Turnstone User
LOCAL_BREW_DIR="${USER_HOME}/.homebrew"
log_info "Checking local Homebrew installation in ${LOCAL_BREW_DIR}..."
if [ ! -x "${LOCAL_BREW_DIR}/bin/brew" ]; then
    log_info "Installing standalone Homebrew into ${LOCAL_BREW_DIR} for '${TURNSTONE_USER}'..."
    rm -rf "${LOCAL_BREW_DIR}"
    if [ "$(whoami)" = "${TURNSTONE_USER}" ]; then
        git clone --depth=1 https://github.com/Homebrew/brew "${LOCAL_BREW_DIR}"
    else
        sudo -u "${TURNSTONE_USER}" git clone --depth=1 https://github.com/Homebrew/brew "${LOCAL_BREW_DIR}"
    fi
fi

if [ "$(whoami)" != "${TURNSTONE_USER}" ]; then
    sudo chown -R "${TURNSTONE_USER}" "${LOCAL_BREW_DIR}" 2>/dev/null || true
fi

# Persist Homebrew environment across all future shell sessions
BREW_ENV_CMD="eval \"\$(${LOCAL_BREW_DIR}/bin/brew shellenv)\""
for rc_file in "${USER_HOME}/.zprofile" "${USER_HOME}/.zshrc" "${USER_HOME}/.bash_profile" "${USER_HOME}/.bashrc"; do
    if [ ! -f "${rc_file}" ]; then
        if [ "$(whoami)" = "${TURNSTONE_USER}" ]; then
            touch "${rc_file}"
        else
            sudo -u "${TURNSTONE_USER}" touch "${rc_file}" 2>/dev/null || true
        fi
    fi
    if ! grep -qF "${LOCAL_BREW_DIR}/bin/brew shellenv" "${rc_file}" 2>/dev/null; then
        if [ "$(whoami)" = "${TURNSTONE_USER}" ]; then
            echo "" >> "${rc_file}"
            echo "# Homebrew environment" >> "${rc_file}"
            echo "${BREW_ENV_CMD}" >> "${rc_file}"
        else
            sudo -u "${TURNSTONE_USER}" bash -c "echo '' >> '${rc_file}'; echo '# Homebrew environment' >> '${rc_file}'; echo 'eval \"\$(${LOCAL_BREW_DIR}/bin/brew shellenv)\"' >> '${rc_file}'" 2>/dev/null || true
        fi
    fi
done

# Install all-smi via Homebrew
log_info "Installing all-smi utility via Homebrew for user '${TURNSTONE_USER}'..."
if [ "$(whoami)" = "${TURNSTONE_USER}" ]; then
    eval "$(${LOCAL_BREW_DIR}/bin/brew shellenv)"
    brew tap lablup/tap --quiet 2>/dev/null || true
    brew install lablup/tap/all-smi || brew install all-smi
else
    sudo -u "${TURNSTONE_USER}" -H bash -c "
        eval \"\$(${LOCAL_BREW_DIR}/bin/brew shellenv)\"
        brew tap lablup/tap --quiet 2>/dev/null || true
        brew install lablup/tap/all-smi || brew install all-smi
    "
fi

ALL_SMI_BIN="${LOCAL_BREW_DIR}/bin/all-smi"
if [ -x "${ALL_SMI_BIN}" ]; then
    sudo mkdir -p /usr/local/bin 2>/dev/null || true
    sudo ln -sfn "${ALL_SMI_BIN}" /usr/local/bin/all-smi 2>/dev/null || true
    log_success "all-smi utility successfully installed at ${ALL_SMI_BIN} (symlinked to /usr/local/bin/all-smi)."
fi

# Configure Passwordless Sudo for all-smi
log_info "Configuring passwordless sudo for '${TURNSTONE_USER}' to execute all-smi..."
SUDOERS_FILE="/etc/sudoers.d/turnstone-all-smi"
TMP_SUDOERS="$(mktemp -t sudoers-all-smi-XXXXXX 2>/dev/null || mktemp /tmp/sudoers-all-smi-XXXXXX)"
cat > "${TMP_SUDOERS}" <<EOF
# Allow ${TURNSTONE_USER} to execute all-smi with sudo without a password
${TURNSTONE_USER} ALL=(ALL) NOPASSWD: ${ALL_SMI_BIN}, /usr/local/bin/all-smi
EOF
chmod 0440 "${TMP_SUDOERS}"

if command -v visudo &>/dev/null; then
    if sudo visudo -cf "${TMP_SUDOERS}" 2>/dev/null || visudo -cf "${TMP_SUDOERS}" 2>/dev/null; then
        sudo mkdir -p /etc/sudoers.d 2>/dev/null || true
        sudo cp "${TMP_SUDOERS}" "${SUDOERS_FILE}"
        sudo chmod 0440 "${SUDOERS_FILE}"
        log_success "Passwordless sudo configured and validated: ${SUDOERS_FILE}"
    else
        log_warn "visudo validation failed on temporary sudoers rule; skipping sudoers file installation."
    fi
else
    sudo mkdir -p /etc/sudoers.d 2>/dev/null || true
    sudo cp "${TMP_SUDOERS}" "${SUDOERS_FILE}"
    sudo chmod 0440 "${SUDOERS_FILE}"
    log_success "Passwordless sudo configured: ${SUDOERS_FILE}"
fi
rm -f "${TMP_SUDOERS}"

# Step 4: Configure ~/.config/turnstone/config.toml
CONFIG_DIR="$HOME/.config/turnstone"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
log_info "Step 4: Configuring secrets at ${CONFIG_FILE}..."

mkdir -p "${CONFIG_DIR}"
cat > "${CONFIG_FILE}" <<EOF
[auth]
jwt_secret = "${JWT_SECRET}"

[database]
backend = "postgresql"
url = "postgresql+psycopg://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"

[api]
base_url = "http://127.0.0.1:8000/v1"
api_key = "dummy"
EOF

chmod 600 "${CONFIG_FILE}"
log_success "Configuration written and secured (0600)."

# Ensure LaunchAgents and Logs directories exist
mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$HOME/Library/Logs"

# Step 5: Configure & Mount Remote SMB Storage at Startup
log_info "Step 5: Configuring remote SMB mount at ${MOUNT_POINT}..."

if [ ! -d "/mnt" ]; then
    sudo mkdir -p "/System/Volumes/Data/mnt" 2>/dev/null || true
    if [ -f "/etc/synthetic.conf" ]; then
        if ! grep -q "^mnt" /etc/synthetic.conf 2>/dev/null; then
            printf "mnt\t/System/Volumes/Data/mnt\n" | sudo tee -a /etc/synthetic.conf >/dev/null 2>&1 || true
        fi
    else
        printf "mnt\t/System/Volumes/Data/mnt\n" | sudo tee /etc/synthetic.conf >/dev/null 2>&1 || true
    fi
    sudo /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs_synthetic_links 2>/dev/null || true
fi

sudo mkdir -p "${MOUNT_POINT}" 2>/dev/null || mkdir -p "${MOUNT_POINT}" 2>/dev/null || true
sudo chown -R "$(whoami)" "${MOUNT_POINT}" 2>/dev/null || true
sudo chmod 775 "${MOUNT_POINT}" 2>/dev/null || true

cat > "${CONFIG_DIR}/mount_smb.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "${MOUNT_POINT}" 2>/dev/null || true
if ! mount | grep -Fq "on ${MOUNT_POINT} "; then
    mount_smbfs "//${REMOTE_USERNAME}:${SMB_PASSWORD}@${SERVER_HOSTNAME}/${SHARE_NAME}" "${MOUNT_POINT}" 2>/dev/null || true
fi
EOF
chmod 700 "${CONFIG_DIR}/mount_smb.sh"

SMB_MOUNT_PLIST="$HOME/Library/LaunchAgents/com.turnstone.smb-mount.plist"
cat > "${SMB_MOUNT_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.turnstone.smb-mount</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${CONFIG_DIR}/mount_smb.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>NetworkState</key>
        <true/>
    </dict>
    <key>StandardOutPath</key>
    <string>${HOME}/Library/Logs/smb-mount.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/Library/Logs/smb-mount.err</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/com.turnstone.smb-mount" 2>/dev/null || launchctl unload "${SMB_MOUNT_PLIST}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "${SMB_MOUNT_PLIST}" 2>/dev/null || launchctl load "${SMB_MOUNT_PLIST}" 2>/dev/null || true
bash "${CONFIG_DIR}/mount_smb.sh" 2>/dev/null || true
log_success "SMB storage configured for startup mount at ${MOUNT_POINT}."

# Step 6: Setup MLX Launchd Service (mlx-lm.server)
MLX_PLIST="$HOME/Library/LaunchAgents/com.turnstone.mlx-server.plist"
log_info "Step 6: Configuring MLX Server launchd service..."

cat > "${MLX_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.turnstone.mlx-server</string>
    <key>ProgramArguments</key>
    <array>
        <string>${VENV_DIR}/bin/python</string>
        <string>-m</string>
        <string>mlx_lm.server</string>
        <string>--model</string>
        <string>mlx-community/Qwen2.5-Coder-32B-Instruct-4bit</string>
        <string>--port</string>
        <string>8000</string>
        <string>--max-kv-size</string>
        <string>384000</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${HOME}/Library/Logs/mlx-server.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/Library/Logs/mlx-server.err</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/com.turnstone.mlx-server" 2>/dev/null || launchctl unload "${MLX_PLIST}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "${MLX_PLIST}" 2>/dev/null || launchctl load "${MLX_PLIST}"
log_success "MLX Server service loaded."

# Step 7: Setup Turnstone Server Launchd Service
SERVER_PLIST="$HOME/Library/LaunchAgents/com.turnstone.server.plist"
log_info "Step 7: Configuring turnstone-server launchd service..."

cat > "${SERVER_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.turnstone.server</string>
    <key>WorkingDirectory</key>
    <string>${MOUNT_POINT}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>TURNSTONE_NODE_ID</key>
        <string>${NODE_ID}</string>
        <key>TURNSTONE_ADVERTISE_URL</key>
        <string>http://${LAN_IP}:8080</string>
        <key>TURNSTONE_CONSOLE_URL</key>
        <string>http://${COORDINATOR_IP}:8090</string>
        <key>TURNSTONE_SEARXNG_URL</key>
        <string>http://${COORDINATOR_IP}:8081</string>
        <key>TURNSTONE_CONFIG</key>
        <string>${CONFIG_FILE}</string>
        <key>TURNSTONE_DB_BACKEND</key>
        <string>postgresql</string>
        <key>TURNSTONE_DB_URL</key>
        <string>postgresql+psycopg://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}</string>
        <key>TURNSTONE_STORAGE_DIR</key>
        <string>${MOUNT_POINT}</string>
        <key>TURNSTONE_SMB_MOUNT</key>
        <string>${MOUNT_POINT}</string>
        <key>TURNSTONE_WORKSPACE</key>
        <string>${MOUNT_POINT}</string>
    </dict>
    <key>ProgramArguments</key>
    <array>
        <string>${VENV_DIR}/bin/turnstone-server</string>
        <string>--host</string>
        <string>0.0.0.0</string>
        <string>--port</string>
        <string>8080</string>
        <string>--config</string>
        <string>${CONFIG_FILE}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${HOME}/Library/Logs/turnstone-server.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/Library/Logs/turnstone-server.err</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/com.turnstone.server" 2>/dev/null || launchctl unload "${SERVER_PLIST}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "${SERVER_PLIST}" 2>/dev/null || launchctl load "${SERVER_PLIST}"
log_success "Turnstone Server service loaded and connected to PostgreSQL."

echo -e "${GREEN}=================================================================${NC}"
echo -e "${GREEN}  Node 1 (M5 Max MacBook Pro) Deployed Successfully!            ${NC}"
echo -e "${GREEN}=================================================================${NC}"
echo -e "Node ID: ${NODE_ID}"
echo -e "Advertise URL: http://${LAN_IP}:8080"
echo -e "PostgreSQL Backend: ${POSTGRES_USER}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
echo -e "MLX Server API: http://127.0.0.1:8000/v1 (384k Context Window)"
echo -e "SMB Storage Mount: ${MOUNT_POINT} (${SMB_PATH})"
echo -e "Homebrew Prefix: ${LOCAL_BREW_DIR}"
echo -e "all-smi Utility: ${ALL_SMI_BIN} (sudo NOPASSWD enabled)"

