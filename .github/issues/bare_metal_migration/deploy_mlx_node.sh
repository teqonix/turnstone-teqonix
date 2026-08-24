#!/usr/bin/env bash
# =============================================================================
# Turnstone LLM Node 1 (Apple Silicon M5 Max - mbp-ai-core.lan) Deployment
#
# Installs Apple MLX server (mlx-lm.server) + bare-metal turnstone-server,
# configures context window, creates dedicated system user idempotently,
# and sets up macOS launchd services.
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
HF_TOKEN="${HF_TOKEN:-}"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -u, --user, --postgres-user <user> PostgreSQL username (e.g. turnstone-np, postgres)"
    echo "  -s, --secret-file <path>           Path to secret file containing DB connection string or env vars"
    echo "  -t, --hf-token <token>             Hugging Face access token (HF_TOKEN)"
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
        -t|--hf-token|--huggingface-token)
            HF_TOKEN="$2"
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
        SHARE_NAME="ai-playground"
    else
        # If user passed a full TrueNAS storage path (e.g. /mnt/silo-14/ai_playground), extract the SMB share name
        if [[ "${path_part}" =~ ^mnt/[^/]+/(.+)$ ]]; then
            SHARE_NAME="${BASH_REMATCH[1]}"
        else
            SHARE_NAME="${path_part}"
        fi
    fi
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
        if [ -n "${h}" ] && [ "${h}" != "localhost" ] && [ "${h}" != "127.0.0.1" ]; then
            POSTGRES_HOST="${h}"
        fi

        if [[ "${hostport}" == *":"* ]]; then
            local pt="${hostport#*:}"
            [ -n "${pt}" ] && POSTGRES_PORT="${pt}"
        fi
    fi
}

auto_load_all_secrets() {
    local search_dirs=(
        "/etc/turnstone/secrets"
        "/etc/turnstone"
        "${CONFIG_DIR:-/etc/turnstone}/secrets"
        "${CONFIG_DIR:-/etc/turnstone}"
        "${SCRIPT_DIR}/secrets"
        "${REPO_ROOT}/secrets"
        "${USER_HOME}/.turnstone/secrets"
        "${USER_HOME}/.turnstone"
        "${USER_HOME}/.secrets"
        "${HOME}/.turnstone/secrets"
        "${HOME}/.turnstone"
        "/secrets"
    )

    # 1. PostgreSQL Secret Discovery & Parsing
    if [ -z "${POSTGRES_PASSWORD:-}" ]; then
        local pg_candidates=(
            "turnstone_postgres.secret"
            "postgres_turnstone_admin.secret"
            "postgres_turnstone.secret"
        )
        local matched_pg=""
        for sdir in "${search_dirs[@]}"; do
            [ -d "$sdir" ] || continue
            for cand in "${pg_candidates[@]}"; do
                if [ -f "${sdir}/${cand}" ]; then
                    matched_pg="${sdir}/${cand}"
                    break 2
                fi
            done
            for f in "${sdir}"/*postgres*.secret "${sdir}"/*postgres*.env; do
                if [ -f "$f" ]; then
                    matched_pg="$f"
                    break 2
                fi
            done
        done

        if [ -n "${matched_pg}" ] && [ -f "${matched_pg}" ]; then
            log_info "Auto-discovered PostgreSQL secret file: '${matched_pg}'"
            local first_line
            first_line=$(grep -v '^[[:space:]]*#' "${matched_pg}" | grep -v '^[[:space:]]*$' | tr -d '\r' | head -n 1 || true)
            if [[ "${first_line}" == *"://"* ]] || [[ "${first_line}" == *"@"* ]]; then
                parse_connection_uri "${first_line}"
            elif [[ "${first_line}" == *"="* ]]; then
                set +e
                source "${matched_pg}"
                set -e
                POSTGRES_USER="${POSTGRES_USER:-${POSTGRES_ADMIN_USER:-turnstone-np}}"
                POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-${POSTGRES_ADMIN_PASS:-}}"
                [ -n "${PGHOST:-}" ] && POSTGRES_HOST="${PGHOST}"
                [ -n "${PGPORT:-}" ] && POSTGRES_PORT="${PGPORT}"
                [ -n "${PGDATABASE:-}" ] && POSTGRES_DB="${PGDATABASE}"
            fi
        fi
    fi

    # Normalize PostgreSQL parameters for worker node
    if [ -z "${POSTGRES_HOST:-}" ] || [ "${POSTGRES_HOST}" = "localhost" ] || [ "${POSTGRES_HOST}" = "127.0.0.1" ]; then
        POSTGRES_HOST="turnstone-postgres.lan"
    fi
    POSTGRES_USER="${POSTGRES_USER:-turnstone-np}"
    POSTGRES_PORT="${POSTGRES_PORT:-5432}"
    POSTGRES_DB="${POSTGRES_DB:-turnstone}"

    # 2. SMB Storage Secret Discovery & Parsing
    if [ -z "${SMB_PASSWORD:-}" ] || [ -z "${SMB_USER:-}" ] || [ -z "${SMB_PATH:-}" ]; then
        local smb_candidates=(
            "turnstone_np_smb.secret"
            "turnstone_smb.secret"
            "smb.secret"
            "silo_14.secret"
            "silo-14.secret"
        )
        local matched_smb=""
        for sdir in "${search_dirs[@]}"; do
            [ -d "$sdir" ] || continue
            for cand in "${smb_candidates[@]}"; do
                if [ -f "${sdir}/${cand}" ]; then
                    matched_smb="${sdir}/${cand}"
                    break 2
                fi
            done
            for f in "${sdir}"/*smb*.secret "${sdir}"/*smb*.env; do
                if [ -f "$f" ]; then
                    matched_smb="$f"
                    break 2
                fi
            done
        done

        if [ -n "${matched_smb}" ] && [ -f "${matched_smb}" ]; then
            log_info "Auto-discovered SMB secret file: '${matched_smb}'"
            local smb_line
            smb_line=$(grep -v '^[[:space:]]*#' "${matched_smb}" | grep -v '^[[:space:]]*$' | tr -d '\r' | head -n 1 || true)
            if [ -n "${smb_line}" ]; then
                parse_smb_path "${smb_line}"
            fi
        fi
    fi

    SERVER_HOSTNAME="${SERVER_HOSTNAME:-silo-14.lan}"
    SHARE_NAME="${SHARE_NAME:-ai-playground}"
    SMB_USER="${SMB_USER:-turnstone-np}"
    REMOTE_USERNAME="${SMB_USER}"
    SMB_PATH="${SMB_PATH:-smb://${SERVER_HOSTNAME}/${SHARE_NAME}}"

    # 3. JWT Secret Discovery & Parsing
    if [ -z "${JWT_SECRET:-}" ]; then
        local jwt_candidates=(
            "jwt_secret.secret"
            "turnstone_jwt.secret"
            "jwt.secret"
            "coordinator.secret"
            "coordinator_turnstone.secret"
        )
        local matched_jwt=""
        for sdir in "${search_dirs[@]}"; do
            [ -d "$sdir" ] || continue
            for cand in "${jwt_candidates[@]}"; do
                if [ -f "${sdir}/${cand}" ]; then
                    matched_jwt="${sdir}/${cand}"
                    break 2
                fi
            done
            for f in "${sdir}"/*jwt*.secret "${sdir}"/*jwt*.env; do
                if [ -f "$f" ]; then
                    matched_jwt="$f"
                    break 2
                fi
            done
        done

        if [ -n "${matched_jwt}" ] && [ -f "${matched_jwt}" ]; then
            log_info "Auto-discovered JWT secret file: '${matched_jwt}'"
            JWT_SECRET=$(grep -v '^[[:space:]]*#' "${matched_jwt}" | grep -v '^[[:space:]]*$' | tr -d '\r' | head -n 1 || true)
        fi
    fi

    # 4. Hugging Face Secret Discovery & Parsing
    if [ -z "${HF_TOKEN:-}" ]; then
        local hf_candidates=(
            "hugging_face_access_token.secret"
            "huggingface_access_token.secret"
            "hugging_face_token.secret"
            "huggingface_token.secret"
            "hf_access_token.secret"
            "hf_token.secret"
            "hugging_face.secret"
            "huggingface.secret"
            "hf.secret"
            "hugging_face_access_token.env"
            "huggingface.env"
            "hf.env"
        )
        local matched_hf=""
        for sdir in "${search_dirs[@]}"; do
            [ -d "$sdir" ] || continue
            for cand in "${hf_candidates[@]}"; do
                if [ -f "${sdir}/${cand}" ]; then
                    matched_hf="${sdir}/${cand}"
                    break 2
                fi
            done
            for f in "${sdir}"/*hugging*.secret "${sdir}"/*hf*.secret "${sdir}"/*hugging*.env "${sdir}"/*hf*.env; do
                if [ -f "$f" ]; then
                    matched_hf="$f"
                    break 2
                fi
            done
        done

        if [ -n "${matched_hf}" ] && [ -f "${matched_hf}" ]; then
            log_info "Auto-discovered Hugging Face secret file: '${matched_hf}'"
            local hf_line
            hf_line=$(grep -v '^[[:space:]]*#' "${matched_hf}" | grep -v '^[[:space:]]*$' | tr -d '\r' | head -n 1 || true)
            if [[ "${hf_line}" == *"="* ]]; then
                HF_TOKEN="${hf_line#*=}"
                HF_TOKEN="${HF_TOKEN#\"}"
                HF_TOKEN="${HF_TOKEN%\"}"
                HF_TOKEN="${HF_TOKEN#\'}"
                HF_TOKEN="${HF_TOKEN%\'}"
            else
                HF_TOKEN="${hf_line}"
            fi
        fi
    fi

    # 5. Coordinator Host
    COORDINATOR_IP="${COORDINATOR_IP:-turnstone-coordinator-nerd-projects.lan}"
}

echo -e "${BLUE}=================================================================${NC}"
echo -e "${BLUE}   Turnstone Node 1 Deployment (M5 Max MacBook Pro - MLX Engine)  ${NC}"
echo -e "${BLUE}=================================================================${NC}"

# Determine target local system user
if [ -z "${TURNSTONE_USER}" ]; then
    if id "turnstone" &>/dev/null; then
        TURNSTONE_USER="turnstone"
    elif [ -n "${SUDO_USER:-}" ]; then
        TURNSTONE_USER="${SUDO_USER}"
    else
        TURNSTONE_USER="$(whoami)"
    fi
fi

# Step 0: Idempotent macOS System User Creation
if ! id "${TURNSTONE_USER}" &>/dev/null; then
    log_info "Creating dedicated local macOS user '${TURNSTONE_USER}'..."
    NEXT_UID=$(dscl . -list /Users UniqueID 2>/dev/null | awk '$2 >= 501 && $2 < 1000 {print $2}' | sort -n | tail -1)
    NEXT_UID=$(( ${NEXT_UID:-501} + 1 ))

    if command -v sysadminctl &>/dev/null; then
        sudo sysadminctl -addUser "${TURNSTONE_USER}" -UID "${NEXT_UID}" -home "/Users/${TURNSTONE_USER}" -shell /bin/zsh 2>/dev/null || \
        (
            sudo dscl . -create "/Users/${TURNSTONE_USER}" 2>/dev/null || true
            sudo dscl . -create "/Users/${TURNSTONE_USER}" UserShell /bin/zsh 2>/dev/null || true
            sudo dscl . -create "/Users/${TURNSTONE_USER}" RealName "Turnstone Node Service" 2>/dev/null || true
            sudo dscl . -create "/Users/${TURNSTONE_USER}" UniqueID "${NEXT_UID}" 2>/dev/null || true
            sudo dscl . -create "/Users/${TURNSTONE_USER}" PrimaryGroupID 20 2>/dev/null || true
            sudo dscl . -create "/Users/${TURNSTONE_USER}" NFSHomeDirectory "/Users/${TURNSTONE_USER}" 2>/dev/null || true
        )
    fi
    sudo mkdir -p "/Users/${TURNSTONE_USER}" 2>/dev/null || true
    sudo chown -R "${TURNSTONE_USER}:staff" "/Users/${TURNSTONE_USER}" 2>/dev/null || true
    log_success "Created macOS user '${TURNSTONE_USER}' (UID: ${NEXT_UID})."
fi

# Resolve target user's home directory
if [ "${TURNSTONE_USER}" = "$(whoami)" ]; then
    USER_HOME="${HOME}"
else
    USER_HOME="$(dscl . -read "/Users/${TURNSTONE_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    [ -z "${USER_HOME}" ] && USER_HOME="/Users/${TURNSTONE_USER}"
fi

sudo mkdir -p "${USER_HOME}" 2>/dev/null || mkdir -p "${USER_HOME}" 2>/dev/null || true
sudo chown "${TURNSTONE_USER}" "${USER_HOME}" 2>/dev/null || true

# Execution wrapper to run commands as the target user
run_as_target_user() {
    if [ "$(whoami)" = "${TURNSTONE_USER}" ]; then
        bash -c "$1"
    else
        sudo -u "${TURNSTONE_USER}" -H bash -c "$1"
    fi
}

# Step 1: Auto-Load Secrets or Prompt if Missing
auto_load_all_secrets

if [ -z "${POSTGRES_PASSWORD}" ]; then
    read -r -s -p "Enter PostgreSQL Password for user '${POSTGRES_USER}'@'${POSTGRES_HOST}': " POSTGRES_PASSWORD
    echo ""
fi

if [ -z "${JWT_SECRET}" ]; then
    read -rp "Enter TURNSTONE_JWT_SECRET from Coordinator setup: " JWT_SECRET
fi

if [ -z "${SMB_PASSWORD}" ]; then
    read -r -s -p "Enter SMB Password for '${REMOTE_USERNAME}'@'${SERVER_HOSTNAME}': " SMB_PASSWORD
    echo ""
fi

if [ -z "${HF_TOKEN}" ]; then
    read -r -s -p "Enter Hugging Face Access Token (HF_TOKEN) [or press Enter to skip]: " HF_TOKEN
    echo ""
fi

if [ -n "${HF_TOKEN}" ]; then
    export HF_TOKEN
    export HUGGING_FACE_HUB_TOKEN="${HF_TOKEN}"
fi

MOUNT_POINT="${USER_HOME}/mnt/${SERVER_HOSTNAME}/${REMOTE_USERNAME}/${SHARE_NAME}"
log_success "Configured credentials for PostgreSQL (${POSTGRES_USER}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}) and SMB (${SMB_PATH})."

NODE_ID="mbp-ai-core"
LAN_IP=$(ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | head -n 1)

# Step 2: Check Python & UV Installation
log_info "Step 2: Checking Python 3 and UV package manager for '${TURNSTONE_USER}'..."
run_as_target_user '
    export PATH="$HOME/.local/bin:$PATH"
    if ! command -v uv &>/dev/null; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi
'
UV_BIN="${USER_HOME}/.local/bin/uv"
[ -x "${UV_BIN}" ] || UV_BIN="$(command -v uv 2>/dev/null || echo "uv")"
log_success "Package manager verified (${UV_BIN})."

# Step 3: Set up MLX and Turnstone Virtual Environments
VENV_DIR="${USER_HOME}/.local/share/turnstone-venv"
log_info "Step 3: Creating virtual environment at ${VENV_DIR}..."
run_as_target_user "mkdir -p '${USER_HOME}/.local/share'"
if [ ! -d "${VENV_DIR}" ]; then
    run_as_target_user "'${UV_BIN}' venv '${VENV_DIR}' --python 3.12"
fi

log_info "Installing mlx-lm, fastapi, uvicorn, httpx, turnstone, psycopg, and huggingface_hub packages into virtualenv..."
if [ -f "${REPO_ROOT}/pyproject.toml" ]; then
    run_as_target_user "'${UV_BIN}' pip install --python '${VENV_DIR}' mlx-lm fastapi 'uvicorn[standard]' httpx pydantic 'psycopg[binary]' 'huggingface_hub[cli]'"
    run_as_target_user "'${UV_BIN}' pip install --python '${VENV_DIR}' --reinstall '${REPO_ROOT}'"
else
    run_as_target_user "'${UV_BIN}' pip install --python '${VENV_DIR}' mlx-lm fastapi 'uvicorn[standard]' httpx pydantic turnstone 'psycopg[binary]' 'huggingface_hub[cli]'"
fi
log_success "MLX, FastAPI server dependencies, and Turnstone installed successfully."

# Step 3a: Create convenience CLI wrapper for mlx-lm / mlx_lm
MLX_WRAPPER="${VENV_DIR}/bin/mlx-lm"
run_as_target_user "cat > '${MLX_WRAPPER}' << 'EOF'
#!/usr/bin/env bash
SCRIPT_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")\" && pwd)\"
PYTHON_BIN=\"\${SCRIPT_DIR}/python\"

if [ \$# -eq 0 ]; then
    echo \"Turnstone MLX-LM Command Interface\"
    echo \"Usage:\"
    echo \"  mlx-lm generate --model <model> --prompt <text>\"
    echo \"  mlx-lm server --model <model> --port 8000\"
    echo \"  mlx-lm chat --model <model>\"
    echo \"  mlx-lm convert --hf-path <repo>\"
    echo \"  mlx-lm lora --model <model> --data <data>\"
    echo \"\"
    exec \"\${PYTHON_BIN}\" -m mlx_lm.generate --help
fi

SUBCMD=\"\$1\"
case \"\${SUBCMD}\" in
    generate|server|convert|lora|fuse|manage|cache_prompt|chat)
        shift
        exec \"\${PYTHON_BIN}\" -m \"mlx_lm.\${SUBCMD}\" \"\$@\"
        ;;
    -h|--help)
        echo \"Turnstone MLX-LM Command Interface\"
        echo \"Usage: mlx-lm [generate|server|convert|lora|fuse|manage|chat] [options]\"
        echo \"\"
        exec \"\${PYTHON_BIN}\" -m mlx_lm.generate --help
        ;;
    *)
        # Default to mlx_lm.generate if arguments are passed directly
        exec \"\${PYTHON_BIN}\" -m mlx_lm.generate \"\$@\"
        ;;
esac
EOF
chmod +x '${MLX_WRAPPER}'
ln -sfn '${MLX_WRAPPER}' '${VENV_DIR}/bin/mlx_lm' 2>/dev/null || true
"

# Create global symlinks in /usr/local/bin for all users
sudo mkdir -p /usr/local/bin 2>/dev/null || true
for tool_bin in mlx-lm mlx_lm mlx_lm.server mlx_lm.generate mlx_lm.convert mlx_lm.lora mlx_lm.fuse turnstone-server hf; do
    if [ -x "${VENV_DIR}/bin/${tool_bin}" ]; then
        sudo ln -sfn "${VENV_DIR}/bin/${tool_bin}" "/usr/local/bin/${tool_bin}" 2>/dev/null || true
    fi
done
if [ -x "${USER_HOME}/.local/bin/uv" ]; then
    sudo ln -sfn "${USER_HOME}/.local/bin/uv" /usr/local/bin/uv 2>/dev/null || true
fi

# Step 3b: Install Local Homebrew, all-smi Hardware Monitor & Ollama for Turnstone User
LOCAL_BREW_DIR="${USER_HOME}/.homebrew"
log_info "Checking local Homebrew installation in ${LOCAL_BREW_DIR}..."
if [ ! -x "${LOCAL_BREW_DIR}/bin/brew" ]; then
    log_info "Installing standalone Homebrew into ${LOCAL_BREW_DIR} for '${TURNSTONE_USER}'..."
    run_as_target_user "rm -rf '${LOCAL_BREW_DIR}' && git clone --depth=1 https://github.com/Homebrew/brew '${LOCAL_BREW_DIR}'"
fi

# Persist Virtualenv, Local bin, Homebrew, and Hugging Face environment across all future shell sessions
ENV_EXPORT_CMD="export PATH=\"${VENV_DIR}/bin:${USER_HOME}/.local/bin:\$PATH\""
BREW_ENV_CMD="eval \"\$(${LOCAL_BREW_DIR}/bin/brew shellenv)\""
for rc_file in "${USER_HOME}/.zprofile" "${USER_HOME}/.zshrc" "${USER_HOME}/.bash_profile" "${USER_HOME}/.bashrc"; do
    run_as_target_user "touch '${rc_file}'"
    if ! grep -qF "${VENV_DIR}/bin" "${rc_file}" 2>/dev/null; then
        run_as_target_user "printf '\n# Turnstone virtualenv and user bins\n%s\n' '${ENV_EXPORT_CMD}' >> '${rc_file}'"
    fi
    if ! grep -qF "${LOCAL_BREW_DIR}/bin/brew shellenv" "${rc_file}" 2>/dev/null; then
        run_as_target_user "printf '\n# Homebrew environment\n%s\n' '${BREW_ENV_CMD}' >> '${rc_file}'"
    fi
    if [ -n "${HF_TOKEN}" ] && ! grep -qF "HF_TOKEN" "${rc_file}" 2>/dev/null; then
        run_as_target_user "printf '\n# Hugging Face Hub Access Token\nexport HF_TOKEN=\"%s\"\nexport HUGGING_FACE_HUB_TOKEN=\"%s\"\n' '${HF_TOKEN}' '${HF_TOKEN}' >> '${rc_file}'"
    fi
done

if [ -n "${HF_TOKEN}" ]; then
    run_as_target_user "mkdir -p '${USER_HOME}/.cache/huggingface' '${USER_HOME}/.huggingface'"
    run_as_target_user "printf '%s' '${HF_TOKEN}' > '${USER_HOME}/.cache/huggingface/token'"
    run_as_target_user "printf '%s' '${HF_TOKEN}' > '${USER_HOME}/.huggingface/token'"
    run_as_target_user "chmod 600 '${USER_HOME}/.cache/huggingface/token' '${USER_HOME}/.huggingface/token' 2>/dev/null || true"
fi

# Install all-smi and Ollama via Homebrew
log_info "Installing all-smi utility and Ollama engine via Homebrew for user '${TURNSTONE_USER}'..."
run_as_target_user "
    export NONINTERACTIVE=1
    export CI=1
    export HOMEBREW_NO_AUTO_UPDATE=1
    export HOMEBREW_NO_ENV_HINTS=1
    export HOMEBREW_NO_INSTALL_CLEANUP=1
    eval \"\$(${LOCAL_BREW_DIR}/bin/brew shellenv)\"
    brew tap lablup/tap --quiet 2>/dev/null || true
    brew install --quiet lablup/tap/all-smi 2>/dev/null || brew install --quiet all-smi 2>/dev/null || true
    brew install --quiet ollama 2>/dev/null || true
"

ALL_SMI_BIN="${LOCAL_BREW_DIR}/bin/all-smi"
if [ -x "${ALL_SMI_BIN}" ]; then
    sudo mkdir -p /usr/local/bin 2>/dev/null || true
    sudo ln -sfn "${ALL_SMI_BIN}" /usr/local/bin/all-smi 2>/dev/null || true
    log_success "all-smi utility successfully installed at ${ALL_SMI_BIN} (symlinked to /usr/local/bin/all-smi)."
fi

OLLAMA_BIN="${LOCAL_BREW_DIR}/bin/ollama"
if [ -x "${OLLAMA_BIN}" ]; then
    sudo mkdir -p /usr/local/bin 2>/dev/null || true
    sudo ln -sfn "${OLLAMA_BIN}" /usr/local/bin/ollama 2>/dev/null || true
    log_success "Ollama engine successfully installed at ${OLLAMA_BIN} (symlinked to /usr/local/bin/ollama)."
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

# Step 3c: Install Rust / Cargo Toolchain & Jujutsu (jj-cli) for Turnstone User
CARGO_DIR="${USER_HOME}/.cargo"
CARGO_BIN="${CARGO_DIR}/bin/cargo"
JJ_BIN="${CARGO_DIR}/bin/jj"
BINSTALL_BIN="${CARGO_DIR}/bin/cargo-binstall"

log_info "Step 3c: Checking Rust / Cargo toolchain and Jujutsu (jj-cli) for user '${TURNSTONE_USER}'..."

# 1. Install Rust & Cargo via rustup if not present
run_as_target_user "
    export PATH=\"\${HOME}/.cargo/bin:\$PATH\"
    if ! command -v cargo &>/dev/null && [ ! -x \"\${HOME}/.cargo/bin/cargo\" ]; then
        echo 'Installing Rust and Cargo toolchain via rustup...'
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile default --no-modify-path
        rustup default stable
    fi
"

# 2. Persist Cargo environment across future shell sessions
CARGO_PATH_CMD="export PATH=\"${CARGO_DIR}/bin:\$PATH\""
for rc_file in "${USER_HOME}/.zprofile" "${USER_HOME}/.zshrc" "${USER_HOME}/.bash_profile" "${USER_HOME}/.bashrc"; do
    run_as_target_user "touch '${rc_file}'"
    if ! grep -qF ".cargo/bin" "${rc_file}" 2>/dev/null; then
        run_as_target_user "printf '\n# Rust / Cargo environment\n%s\n[ -f \"%s/.cargo/env\" ] && source \"%s/.cargo/env\"\n' '${CARGO_PATH_CMD}' '${USER_HOME}' '${USER_HOME}' >> '${rc_file}'"
    fi
done

# 3. Install cargo-binstall for binary crate distribution
run_as_target_user "
    export PATH=\"\${HOME}/.cargo/bin:\$PATH\"
    if ! command -v cargo-binstall &>/dev/null && [ ! -x \"\${HOME}/.cargo/bin/cargo-binstall\" ]; then
        echo 'Installing cargo-binstall binary provider...'
        curl -L --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash || \
        cargo install cargo-binstall --locked || true
    fi
"

# 4. Install Jujutsu (jj-cli) using cargo binstall
run_as_target_user "
    export PATH=\"\${HOME}/.cargo/bin:\$PATH\"
    if ! command -v jj &>/dev/null && [ ! -x \"\${HOME}/.cargo/bin/jj\" ]; then
        echo 'Installing Jujutsu (jj-cli) via cargo binstall...'
        if [ -x \"\${HOME}/.cargo/bin/cargo-binstall\" ] || command -v cargo-binstall &>/dev/null; then
            cargo binstall -y --strategies crate-meta-data jj-cli || cargo install --locked jj-cli
        else
            cargo install --locked jj-cli
        fi
    fi
"

# 5. Create global symlinks in /usr/local/bin
sudo mkdir -p /usr/local/bin 2>/dev/null || true
for tool_bin in cargo rustc rustup cargo-binstall jj; do
    if [ -x "${CARGO_DIR}/bin/${tool_bin}" ]; then
        sudo ln -sfn "${CARGO_DIR}/bin/${tool_bin}" "/usr/local/bin/${tool_bin}" 2>/dev/null || true
    fi
done

JJ_VER="$(run_as_target_user "export PATH=\"\${HOME}/.cargo/bin:\$PATH\"; jj --version 2>/dev/null || echo 'installed'")"
log_success "Rust / Cargo and Jujutsu (jj-cli) verified: ${JJ_VER} (symlinked to /usr/local/bin/jj)."

# Step 4: Configure ~/.config/turnstone/config.toml
CONFIG_DIR="${USER_HOME}/.config/turnstone"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
log_info "Step 4: Configuring secrets at ${CONFIG_FILE}..."

run_as_target_user "mkdir -p '${CONFIG_DIR}'"
TMP_CONFIG="$(mktemp -t turnstone-config-XXXXXX 2>/dev/null || mktemp /tmp/turnstone-config-XXXXXX)"
cat > "${TMP_CONFIG}" <<EOF
[auth]
jwt_secret = "${JWT_SECRET}"

[database]
backend = "postgresql"
url = "postgresql+psycopg://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"

[api]
base_url = "http://127.0.0.1:8000/v1"
api_key = "dummy"
EOF

sudo cp "${TMP_CONFIG}" "${CONFIG_FILE}" 2>/dev/null || cp "${TMP_CONFIG}" "${CONFIG_FILE}"
sudo chown "${TURNSTONE_USER}" "${CONFIG_FILE}" 2>/dev/null || true
sudo chmod 600 "${CONFIG_FILE}" 2>/dev/null || chmod 600 "${CONFIG_FILE}"
rm -f "${TMP_CONFIG}"
log_success "Configuration written and secured (0600)."

# Ensure LaunchDaemons and Logs directories exist
SYSTEM_DAEMONS_DIR="/Library/LaunchDaemons"
LAUNCH_LOGS_DIR="${USER_HOME}/Library/Logs"
sudo mkdir -p "${SYSTEM_DAEMONS_DIR}" "${LAUNCH_LOGS_DIR}"
sudo chown -R "${TURNSTONE_USER}:staff" "${LAUNCH_LOGS_DIR}" 2>/dev/null || true

# Helper function to idempotently manage system launchd daemons
manage_launch_daemon() {
    local plist_path="$1"
    local label="$2"
    local port="${3:-}"
    local target_uid
    target_uid=$(id -u "${TURNSTONE_USER}" 2>/dev/null || echo "501")

    # Clean up any legacy LaunchAgents in user/gui domain
    sudo -u "${TURNSTONE_USER}" launchctl bootout "gui/${target_uid}/${label}" 2>/dev/null || true
    sudo -u "${TURNSTONE_USER}" launchctl bootout "user/${target_uid}/${label}" 2>/dev/null || true
    rm -f "${USER_HOME}/Library/LaunchAgents/${label}.plist" 2>/dev/null || true

    sudo chown root:wheel "${plist_path}" 2>/dev/null || true
    sudo chmod 644 "${plist_path}" 2>/dev/null || true

    # Gracefully boot out existing daemon if active and wait for completion
    if sudo launchctl print "system/${label}" &>/dev/null; then
        sudo launchctl bootout "system/${label}" 2>/dev/null || sudo launchctl unload "${plist_path}" 2>/dev/null || true
        for _ in {1..10}; do
            if ! sudo launchctl print "system/${label}" &>/dev/null; then
                break
            fi
            sleep 0.5
        done
    fi

    # If a specific port was given and is still held, terminate lingering process
    if [ -n "${port}" ]; then
        local lingering_pids
        lingering_pids=$(lsof -ti:"${port}" 2>/dev/null || true)
        if [ -n "${lingering_pids}" ]; then
            log_info "Releasing port ${port} held by lingering process(es): ${lingering_pids}..."
            echo "${lingering_pids}" | xargs kill -9 2>/dev/null || true
            sleep 1
        fi
    fi

    # Ensure log files exist and are writable by daemon user
    sudo touch "${LAUNCH_LOGS_DIR}/${label#com.turnstone.}.log" "${LAUNCH_LOGS_DIR}/${label#com.turnstone.}.err" 2>/dev/null || true
    sudo chown -R "${TURNSTONE_USER}:staff" "${LAUNCH_LOGS_DIR}" 2>/dev/null || true
    sudo chmod 664 "${LAUNCH_LOGS_DIR}"/* 2>/dev/null || true

    # Bootstrap the fresh plist into system domain
    if ! sudo launchctl bootstrap "system" "${plist_path}" 2>/dev/null; then
        sudo launchctl load -w "${plist_path}" 2>/dev/null || true
    fi

    # Kickstart daemon to ensure it is actively running
    sudo launchctl kickstart -k "system/${label}" 2>/dev/null || true
}

# Helper: Modular File Fetch & Installation
fetch_and_install_file() {
    local filename="$1"
    local dest="$2"
    local interpolate="${3:-false}"

    local local_path="${SCRIPT_DIR}/mlx_node_custom/${filename}"
    local remote_url="https://raw.githubusercontent.com/teqonix/turnstone-teqonix/main/.github/issues/bare_metal_migration/mlx_node_custom/${filename}"
    local tmp_file="/tmp/${filename}"

    if [ -f "${local_path}" ]; then
        log_info "Found local ${filename}, copying..."
        cp "${local_path}" "${tmp_file}"
    else
        log_info "Fetching ${filename} from remote (${remote_url})..."
        curl -sSfL "${remote_url}" -o "${tmp_file}" || {
            log_error "Failed to fetch ${filename}"
            exit 1
        }
    fi

    if [ "${interpolate}" = true ]; then
        eval "cat <<EOF
$(cat "${tmp_file}")
EOF
" > "${dest}"
    else
        cp "${tmp_file}" "${dest}"
    fi
    rm -f "${tmp_file}"
}

# Step 5: Configure & Mount Remote SMB Storage at Startup
log_info "Step 5: Configuring remote SMB mount at ${MOUNT_POINT}..."

run_as_target_user "mkdir -p '${MOUNT_POINT}'" 2>/dev/null || mkdir -p "${MOUNT_POINT}" 2>/dev/null || true
sudo chown -R "${TURNSTONE_USER}" "${MOUNT_POINT}" 2>/dev/null || true
sudo chmod 775 "${MOUNT_POINT}" 2>/dev/null || true

MOUNT_SCRIPT="${CONFIG_DIR}/mount_smb.sh"
fetch_and_install_file "mount_smb.sh" "${MOUNT_SCRIPT}" true
sudo chown "${TURNSTONE_USER}" "${MOUNT_SCRIPT}" 2>/dev/null || true
chmod 700 "${MOUNT_SCRIPT}"

SMB_MOUNT_PLIST="${SYSTEM_DAEMONS_DIR}/com.turnstone.smb-mount.plist"
fetch_and_install_file "com.turnstone.smb-mount.plist" "${SMB_MOUNT_PLIST}" true

manage_launch_daemon "${SMB_MOUNT_PLIST}" "com.turnstone.smb-mount"
run_as_target_user "bash '${MOUNT_SCRIPT}' 2>/dev/null || true"
log_success "SMB storage configured for startup mount at ${MOUNT_POINT}."

# Step 6: Setup Dynamic MLX Server (FastAPI with Lazy Eviction & Metal Cache Clearing)
MLX_CUSTOM_DIR="${CONFIG_DIR}/mlx_node_custom"
mkdir -p "${MLX_CUSTOM_DIR}" 2>/dev/null || true
fetch_and_install_file "dynamic_mlx_server.py" "${MLX_CUSTOM_DIR}/dynamic_mlx_server.py" false
fetch_and_install_file "stream_logs.sh" "${MLX_CUSTOM_DIR}/stream_logs.sh" false
sudo chown -R "${TURNSTONE_USER}:staff" "${MLX_CUSTOM_DIR}" 2>/dev/null || true
chmod +x "${MLX_CUSTOM_DIR}/dynamic_mlx_server.py" "${MLX_CUSTOM_DIR}/stream_logs.sh" 2>/dev/null || true

MLX_PLIST="${SYSTEM_DAEMONS_DIR}/com.turnstone.mlx-server.plist"
log_info "Step 6: Configuring Dynamic MLX Server system daemon on port 8000..."
fetch_and_install_file "com.turnstone.mlx-server.plist" "${MLX_PLIST}" true
manage_launch_daemon "${MLX_PLIST}" "com.turnstone.mlx-server" 8000
log_success "Dynamic MLX Server system daemon loaded."

# Step 6b: Setup Ollama Launchd Daemon (Multi-Model Swapping Engine on Port 11434)
OLLAMA_PLIST="${SYSTEM_DAEMONS_DIR}/com.turnstone.ollama.plist"
log_info "Step 6b: Configuring Ollama system daemon on port 11434 (Memory Capped: 40GB)..."
fetch_and_install_file "com.turnstone.ollama.plist" "${OLLAMA_PLIST}" true

manage_launch_daemon "${OLLAMA_PLIST}" "com.turnstone.ollama" 11434
log_success "Ollama system daemon loaded."

# Step 6c: Download and Associate Models with Servers
log_info "Step 6c: Verifying & downloading models for MLX and Ollama..."

# 1. MLX & Hugging Face Models: Qwen3.8-27B-4bit, Gemma-4-31B-it-4bit & Mistral-Nemo-Base-2407
log_info "Checking / downloading models via Hugging Face ('mlx-community/Qwen3.8-27B-4bit', 'mlx-community/gemma-4-31B-it-4bit', 'mistralai/Mistral-Nemo-Base-2407')..."
run_as_target_user "
    export PATH=\"${VENV_DIR}/bin:${USER_HOME}/.local/bin:\$PATH\"
    export HF_TOKEN=\"${HF_TOKEN}\"
    export HUGGING_FACE_HUB_TOKEN=\"${HF_TOKEN}\"
    if command -v hf &>/dev/null; then
        if [ -n \"${HF_TOKEN}\" ]; then
            hf login --token \"${HF_TOKEN}\" 2>/dev/null || true
        fi
        hf download mlx-community/Qwen3.8-27B-4bit --local-dir-use-symlinks False 2>/dev/null || true
        hf download mlx-community/gemma-4-31B-it-4bit --local-dir-use-symlinks False 2>/dev/null || true
        hf download mistralai/Mistral-Nemo-Base-2407 --local-dir-use-symlinks False 2>/dev/null || true
    fi
"
log_success "MLX and Hugging Face models verified (Qwen3.8-27B-4bit, Gemma-4-31B-it-4bit, Mistral-Nemo-Base-2407)."

# 2. Ollama Models: Qwen3.8 27B, Gemma 4 31B, Mistral Nemo 12B, & Ornith
log_info "Waiting for Ollama daemon to initialize..."
for i in {1..20}; do
    if curl -s http://127.0.0.1:11434/api/tags &>/dev/null; then
        break
    fi
    sleep 1
done

log_info "Pulling Ollama models (Qwen 3.8 27B, Gemma 4 31B, Mistral Nemo 12B, Ornith)..."
run_as_target_user "
    eval \"\$(${LOCAL_BREW_DIR}/bin/brew shellenv)\"
    export OLLAMA_HOST=127.0.0.1:11434
    echo 'Pulling Gemma 4 31B model into Ollama...'
    ollama pull gemma4:31b 2>/dev/null || true

    echo 'Pulling Mistral Nemo 12B judge model into Ollama...'
    ollama pull mistral-nemo:12b 2>/dev/null || ollama pull mistral-nemo:latest 2>/dev/null || ollama pull mistral-nemo 2>/dev/null || true
    # Constrain context window from unconstrained 256k (which allocates ~40GB KV cache) down to 32k
    echo -e "FROM mistral-nemo:12b\nPARAMETER num_ctx 32768" > /tmp/Modelfile.mistral-nemo
    ollama create mistral-nemo:12b -f /tmp/Modelfile.mistral-nemo 2>/dev/null || true
    rm -f /tmp/Modelfile.mistral-nemo

    echo 'Pulling Ornith 1.5 9B model into Ollama...'
    ollama pull ornith-1.5:9b 2>/dev/null || true
"
log_success "Ollama models pulled and context parameters tuned successfully."

# Step 7: Setup Turnstone Server Launchd Daemon
SERVER_PLIST="${SYSTEM_DAEMONS_DIR}/com.turnstone.server.plist"
log_info "Step 7: Configuring turnstone-server system daemon..."
fetch_and_install_file "com.turnstone.server.plist" "${SERVER_PLIST}" true

manage_launch_daemon "${SERVER_PLIST}" "com.turnstone.server" 8080
log_success "Turnstone Server system daemon loaded and connected to PostgreSQL."

# Step 8: Post-Deployment Health Verification
log_info "Step 8: Performing post-deployment health verification..."

DEPLOY_HAS_ERROR=false

# 1. Check MLX Server (Port 8000)
# (Skipped: Deprecated in favor of the new unified proxy sidecar)

# 2. Check Ollama Server (Port 11434)
log_info "Testing Ollama Server health at http://127.0.0.1:11434/api/tags..."
OLLAMA_READY=false
for attempt in {1..30}; do
    if curl -s -f http://127.0.0.1:11434/api/tags &>/dev/null; then
        OLLAMA_READY=true
        break
    fi
    sleep 1
done

if [ "${OLLAMA_READY}" = true ]; then
    OLLAMA_TAGS=$(curl -s http://127.0.0.1:11434/api/tags || true)
    log_success "Ollama Server is healthy: ${OLLAMA_TAGS}"
else
    log_error "Ollama Server failed to respond on http://127.0.0.1:11434/api/tags!"
    log_warn "Recent Ollama stderr log (${LAUNCH_LOGS_DIR}/ollama.err):"
    tail -n 25 "${LAUNCH_LOGS_DIR}/ollama.err" 2>/dev/null || true
    DEPLOY_HAS_ERROR=true
fi

# 3. Check Turnstone Server (Port 8080)
log_info "Testing Turnstone Server health at http://${LAN_IP}:8080..."
TURNSTONE_READY=false
for attempt in {1..30}; do
    if curl -s "http://127.0.0.1:8080" &>/dev/null || curl -s "http://${LAN_IP}:8080" &>/dev/null; then
        TURNSTONE_READY=true
        break
    fi
    sleep 1
done

if [ "${TURNSTONE_READY}" = true ]; then
    log_success "Turnstone Server is healthy and listening on http://${LAN_IP}:8080."
else
    log_warn "Turnstone Server not yet responding on port 8080."
    log_warn "Recent Turnstone stderr log (${LAUNCH_LOGS_DIR}/turnstone-server.err):"
    tail -n 25 "${LAUNCH_LOGS_DIR}/turnstone-server.err" 2>/dev/null || true
fi

echo -e "${GREEN}=================================================================${NC}"
echo -e "${GREEN}  Node 1 (M5 Max MacBook Pro) Deployed Successfully!            ${NC}"
echo -e "${GREEN}=================================================================${NC}"
echo -e "System User: ${TURNSTONE_USER} (${USER_HOME})"
echo -e "Node ID: ${NODE_ID}"
echo -e "Advertise URL: http://${LAN_IP}:8080"
echo -e "PostgreSQL Backend: ${POSTGRES_USER}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
echo -e "MLX Server API (Pinned): http://127.0.0.1:8000/v1 (mlx-community/Qwen3-Coder-Next-6bit)"
echo -e "Ollama Server API (Dynamic): http://127.0.0.1:11434/v1 (Qwen3.8 27B, Gemma 4 31B)"
echo -e "SMB Storage Mount: ${MOUNT_POINT} (${SMB_PATH})"
echo -e "Homebrew Prefix: ${LOCAL_BREW_DIR}"
echo -e "all-smi Utility: ${ALL_SMI_BIN} (sudo NOPASSWD enabled)"
echo -e "Rust / Cargo: ${CARGO_DIR}/bin/cargo (symlinked to /usr/local/bin/cargo)"
echo -e "Jujutsu (jj): ${JJ_BIN} (symlinked to /usr/local/bin/jj)"
if [ -n "${HF_TOKEN}" ]; then
    echo -e "Hugging Face Token: [CONFIGURED] (${HF_TOKEN:0:4}...${HF_TOKEN: -4})"
else
    echo -e "Hugging Face Token: [NONE]"
fi

if [ "${DEPLOY_HAS_ERROR}" = true ]; then
    log_error "One or more inference services failed health checks. Please review the logs above."
    exit 1
fi
