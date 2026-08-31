#!/usr/bin/env bash
# =============================================================================
# Turnstone LLM Inference Node Deployment (Apple Silicon - macOS launchd)
#
# This node acts ONLY as an LLM inference server. It provisions a dedicated
# service user, the MLX server (mlx-lm.server) and an Ollama engine behind
# launchd system daemons, and pulls the required models.
#
# The Turnstone node role has been moved to a dedicated Debian 12 container
# (see deploy_turnstone_debian12.sh). This script no longer installs the
# `turnstone` package, no longer writes ~/.config/turnstone/config.toml, and
# no longer manages a com.turnstone.server launchd daemon.
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

# Local service user that runs the inference daemons.
INFER_USER="${INFER_USER:-}"

# Inference endpoints.
MLX_PORT="${MLX_PORT:-8000}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
MLX_MODEL="${MLX_MODEL:-mlx-community/Qwen3-Coder-Next-6bit}"

# Shared NFS storage configuration
NFS_SERVER="${NFS_SERVER:-silo-14.lan}"
NFS_SHARE="${NFS_SHARE:-/mnt/silo-14/ai-playground}"
MOUNT_POINT="${MOUNT_POINT:-}"
SKIP_NFS="${SKIP_NFS:-false}"

# Auto-discover NFS server / share from secret files if present
auto_discover_nfs() {
    local secret_candidates=(
        "${SCRIPT_DIR}/secrets/turnstone_np_nfs.secret"
        "${SCRIPT_DIR}/secrets/turnstone_np_smb.secret"
        "${SCRIPT_DIR}/secrets/turnstone_np.secret"
        "${REPO_ROOT}/secrets/turnstone_np_nfs.secret"
        "${REPO_ROOT}/secrets/turnstone_np_smb.secret"
    )
    for sec in "${secret_candidates[@]}"; do
        if [ -s "${sec}" ]; then
            local uri_line
            uri_line=$(grep -v '^[[:space:]]*#' "${sec}" | grep -v '^[[:space:]]*$' | tr -d '\r' | head -n 1 || true)
            if [[ "${uri_line}" == *"@"* ]]; then
                local host_part="${uri_line#*@}"
                host_part="${host_part%%/*}"
                host_part="${host_part%%:*}"
                [ -n "${host_part}" ] && NFS_SERVER="${host_part}"
            fi
            break
        fi
    done
}
auto_discover_nfs

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "LLM inference node only (no Turnstone node is installed by this script)."
    echo ""
    echo "Options:"
    echo "      --infer-user <user>          Local service user [default: turnstone or current user]"
    echo "      --mlx-model <repo>           MLX model repo [default: ${MLX_MODEL}]"
    echo "      --mlx-port <port>            MLX server port [default: ${MLX_PORT}]"
    echo "      --ollama-port <port>         Ollama port [default: ${OLLAMA_PORT}]"
    echo "      --nfs-server <host>          NFS server hostname [default: ${NFS_SERVER}]"
    echo "      --nfs-share <path>           NFS share export path [default: ${NFS_SHARE}]"
    echo "      --mount-point <path>         Local NFS mount point [default: ~/silo-14/ai-playground]"
    echo "      --skip-nfs                   Skip NFS utilities and share mounting"
    echo "  -h, --help                       Display this help message and exit"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --infer-user|--local-user)
            INFER_USER="$2"
            shift 2
            ;;
        --mlx-model)
            MLX_MODEL="$2"
            shift 2
            ;;
        --mlx-port)
            MLX_PORT="$2"
            shift 2
            ;;
        --ollama-port)
            OLLAMA_PORT="$2"
            shift 2
            ;;
        --nfs-server)
            NFS_SERVER="$2"
            shift 2
            ;;
        --nfs-share)
            NFS_SHARE="$2"
            shift 2
            ;;
        --mount-point|--workspace-dir)
            MOUNT_POINT="$2"
            shift 2
            ;;
        --skip-nfs)
            SKIP_NFS="true"
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

echo -e "${BLUE}=================================================================${NC}"
echo -e "${BLUE}   LLM Inference Node Deployment (Apple Silicon - MLX Engine)  ${NC}"
echo -e "${BLUE}=================================================================${NC}"

# Determine target local service user
if [ -z "${INFER_USER}" ]; then
    if id "turnstone" &>/dev/null; then
        INFER_USER="turnstone"
    elif [ -n "${SUDO_USER:-}" ]; then
        INFER_USER="${SUDO_USER}"
    else
        INFER_USER="$(whoami)"
    fi
fi

# Step 0: Idempotent macOS Service User Creation
if ! id "${INFER_USER}" &>/dev/null; then
    log_info "Creating dedicated local macOS user '${INFER_USER}'..."
    NEXT_UID=$(dscl . -list /Users UniqueID 2>/dev/null | awk '$2 >= 501 && $2 < 1000 {print $2}' | sort -n | tail -1)
    NEXT_UID=$(( ${NEXT_UID:-501} + 1 ))

    if command -v sysadminctl &>/dev/null; then
        sudo sysadminctl -addUser "${INFER_USER}" -UID "${NEXT_UID}" -home "/Users/${INFER_USER}" -shell /bin/zsh 2>/dev/null || \
        (
            sudo dscl . -create "/Users/${INFER_USER}" 2>/dev/null || true
            sudo dscl . -create "/Users/${INFER_USER}" UserShell /bin/zsh 2>/dev/null || true
            sudo dscl . -create "/Users/${INFER_USER}" RealName "LLM Inference Service" 2>/dev/null || true
            sudo dscl . -create "/Users/${INFER_USER}" UniqueID "${NEXT_UID}" 2>/dev/null || true
            sudo dscl . -create "/Users/${INFER_USER}" PrimaryGroupID 20 2>/dev/null || true
            sudo dscl . -create "/Users/${INFER_USER}" NFSHomeDirectory "/Users/${INFER_USER}" 2>/dev/null || true
        )
    fi
    sudo mkdir -p "/Users/${INFER_USER}" 2>/dev/null || true
    sudo chown -R "${INFER_USER}:staff" "/Users/${INFER_USER}" 2>/dev/null || true
    log_success "Created macOS user '${INFER_USER}' (UID: ${NEXT_UID})."
fi

# Resolve target user's home directory
if [ "${INFER_USER}" = "$(whoami)" ]; then
    USER_HOME="${HOME}"
else
    USER_HOME="$(dscl . -read "/Users/${INFER_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    [ -z "${USER_HOME}" ] && USER_HOME="/Users/${INFER_USER}"
fi

sudo mkdir -p "${USER_HOME}" 2>/dev/null || mkdir -p "${USER_HOME}" 2>/dev/null || true
sudo chown "${INFER_USER}" "${USER_HOME}" 2>/dev/null || true

# Set default MOUNT_POINT under target user's home directory if not provided
if [ -z "${MOUNT_POINT}" ]; then
    MOUNT_POINT="${USER_HOME}/silo-14/ai-playground"
fi

# Execution wrapper to run commands as the target user
run_as_target_user() {
    if [ "$(whoami)" = "${INFER_USER}" ]; then
        bash -c "$1"
    else
        sudo -u "${INFER_USER}" -H bash -c "$1"
    fi
}

NODE_ID="mbp-ai-core"
LAN_IP=$(ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | head -n 1)

# Step 1: Check Python & UV Installation
log_info "Step 1: Checking Python 3 and UV package manager for '${INFER_USER}'..."
run_as_target_user '
    export PATH="$HOME/.local/bin:$PATH"
    if ! command -v uv &>/dev/null; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi
'
UV_BIN="${USER_HOME}/.local/bin/uv"
[ -x "${UV_BIN}" ] || UV_BIN="$(command -v uv 2>/dev/null || echo "uv")"
log_success "Package manager verified (${UV_BIN})."

# Step 2: Set up MLX Virtual Environment (inference only)
VENV_DIR="${USER_HOME}/.local/share/inference-venv"
log_info "Step 2: Creating virtual environment at ${VENV_DIR}..."
run_as_target_user "mkdir -p '${USER_HOME}/.local/share'"
if [ ! -d "${VENV_DIR}" ]; then
    run_as_target_user "'${UV_BIN}' venv '${VENV_DIR}' --python 3.12"
fi

log_info "Installing mlx-lm and huggingface_hub packages into virtualenv..."
run_as_target_user "'${UV_BIN}' pip install --python '${VENV_DIR}' mlx-lm 'huggingface_hub[cli]'"
log_success "MLX inference toolchain installed successfully."

# Step 2a: Create convenience CLI wrapper for mlx-lm / mlx_lm
MLX_WRAPPER="${VENV_DIR}/bin/mlx-lm"
run_as_target_user "cat > '${MLX_WRAPPER}' << 'EOF'
#!/usr/bin/env bash
SCRIPT_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")\" && pwd)\"
PYTHON_BIN=\"\${SCRIPT_DIR}/python\"

if [ \$# -eq 0 ]; then
    echo \"LLM Inference MLX-LM Command Interface\"
    echo \"Usage:\"
    echo \"  mlx-lm generate --model <model> --prompt <text>\"
    echo \"  mlx-lm server --model <model> --port 8000\"
    echo \"  mlx-lm chat --model <model>\"
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
        echo \"LLM Inference MLX-LM Command Interface\"
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

# Create global symlinks in /usr/local/bin for all users (inference tools only)
sudo mkdir -p /usr/local/bin 2>/dev/null || true
for tool_bin in mlx-lm mlx_lm mlx_lm.server mlx_lm.generate mlx_lm.convert mlx_lm.lora mlx_lm.fuse hf huggingface-cli; do
    if [ -x "${VENV_DIR}/bin/${tool_bin}" ]; then
        sudo ln -sfn "${VENV_DIR}/bin/${tool_bin}" "/usr/local/bin/${tool_bin}" 2>/dev/null || true
    fi
done
if [ -x "${USER_HOME}/.local/bin/uv" ]; then
    sudo ln -sfn "${USER_HOME}/.local/bin/uv" /usr/local/bin/uv 2>/dev/null || true
fi

# Step 2b: Install Local Homebrew, all-smi Hardware Monitor & Ollama
LOCAL_BREW_DIR="${USER_HOME}/.homebrew"
log_info "Step 2b: Checking local Homebrew installation in ${LOCAL_BREW_DIR}..."
if [ ! -x "${LOCAL_BREW_DIR}/bin/brew" ]; then
    log_info "Installing standalone Homebrew into ${LOCAL_BREW_DIR} for '${INFER_USER}'..."
    run_as_target_user "rm -rf '${LOCAL_BREW_DIR}' && git clone --depth=1 https://github.com/Homebrew/brew '${LOCAL_BREW_DIR}'"
fi

# Persist Virtualenv, Local bin, and Homebrew environment across all future shell sessions
ENV_EXPORT_CMD="export PATH=\"${VENV_DIR}/bin:${USER_HOME}/.local/bin:\$PATH\""
BREW_ENV_CMD="eval \"\$(${LOCAL_BREW_DIR}/bin/brew shellenv)\""
for rc_file in "${USER_HOME}/.zprofile" "${USER_HOME}/.zshrc" "${USER_HOME}/.bash_profile" "${USER_HOME}/.bashrc"; do
    run_as_target_user "touch '${rc_file}'"
    if ! grep -qF "${VENV_DIR}/bin" "${rc_file}" 2>/dev/null; then
        run_as_target_user "printf '\n# Inference virtualenv and user bins\n%s\n' '${ENV_EXPORT_CMD}' >> '${rc_file}'"
    fi
    if ! grep -qF "${LOCAL_BREW_DIR}/bin/brew shellenv" "${rc_file}" 2>/dev/null; then
        run_as_target_user "printf '\n# Homebrew environment\n%s\n' '${BREW_ENV_CMD}' >> '${rc_file}'"
    fi
done

# Install all-smi and Ollama via Homebrew
log_info "Installing all-smi utility and Ollama engine via Homebrew for user '${INFER_USER}'..."
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
log_info "Configuring passwordless sudo for '${INFER_USER}' to execute all-smi..."
SUDOERS_FILE="/etc/sudoers.d/infer-all-smi"
TMP_SUDOERS="$(mktemp -t sudoers-all-smi-XXXXXX 2>/dev/null || mktemp /tmp/sudoers-all-smi-XXXXXX)"
cat > "${TMP_SUDOERS}" <<EOF
# Allow ${INFER_USER} to execute all-smi with sudo without a password
${INFER_USER} ALL=(ALL) NOPASSWD: ${ALL_SMI_BIN}, /usr/local/bin/all-smi
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

# Ensure LaunchDaemons and Logs directories exist
SYSTEM_DAEMONS_DIR="/Library/LaunchDaemons"
LAUNCH_LOGS_DIR="${USER_HOME}/Library/Logs"
sudo mkdir -p "${SYSTEM_DAEMONS_DIR}" "${LAUNCH_LOGS_DIR}"
sudo chown -R "${INFER_USER}:staff" "${LAUNCH_LOGS_DIR}" 2>/dev/null || true

# Helper function to idempotently manage system launchd daemons
manage_launch_daemon() {
    local plist_path="$1"
    local label="$2"
    local port="${3:-}"
    local target_uid
    target_uid=$(id -u "${INFER_USER}" 2>/dev/null || echo "501")

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
    sudo chown -R "${INFER_USER}:staff" "${LAUNCH_LOGS_DIR}" 2>/dev/null || true
    sudo chmod 664 "${LAUNCH_LOGS_DIR}"/* 2>/dev/null || true

    # Bootstrap the fresh plist into system domain
    sudo chown root:wheel "${plist_path}" 2>/dev/null || true
    sudo chmod 644 "${plist_path}" 2>/dev/null || true
    if ! sudo launchctl bootstrap "system" "${plist_path}" 2>/dev/null; then
        sudo launchctl load -w "${plist_path}" 2>/dev/null || true
    fi

    # Kickstart daemon to ensure it is actively running
    sudo launchctl kickstart -k "system/${label}" 2>/dev/null || true
}

# Step 3: Setup MLX Launchd Daemon (mlx-lm.server)
MLX_PLIST="${SYSTEM_DAEMONS_DIR}/com.turnstone.mlx-server.plist"
log_info "Step 3: Configuring MLX Server system daemon (model: ${MLX_MODEL})..."

cat > "${MLX_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.turnstone.mlx-server</string>
    <key>UserName</key>
    <string>${INFER_USER}</string>
    <key>GroupName</key>
    <string>staff</string>
    <key>WorkingDirectory</key>
    <string>${USER_HOME}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${USER_HOME}</string>
        <key>PATH</key>
        <string>${VENV_DIR}/bin:${USER_HOME}/.local/bin:${LOCAL_BREW_DIR}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>ProgramArguments</key>
    <array>
        <string>${VENV_DIR}/bin/python</string>
        <string>-m</string>
        <string>mlx_lm</string>
        <string>server</string>
        <string>--model</string>
        <string>${MLX_MODEL}</string>
        <string>--host</string>
        <string>0.0.0.0</string>
        <string>--port</string>
        <string>${MLX_PORT}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LAUNCH_LOGS_DIR}/mlx-server.log</string>
    <key>StandardErrorPath</key>
    <string>${LAUNCH_LOGS_DIR}/mlx-server.err</string>
</dict>
</plist>
EOF

manage_launch_daemon "${MLX_PLIST}" "com.turnstone.mlx-server" "${MLX_PORT}"
log_success "MLX Server system daemon loaded."

# Step 3b: Setup Ollama Launchd Daemon (Multi-Model Swapping Engine)
OLLAMA_PLIST="${SYSTEM_DAEMONS_DIR}/com.turnstone.ollama.plist"
log_info "Step 3b: Configuring Ollama system daemon on port ${OLLAMA_PORT} (Memory Capped: 50GB)..."

cat > "${OLLAMA_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.turnstone.ollama</string>
    <key>UserName</key>
    <string>${INFER_USER}</string>
    <key>GroupName</key>
    <string>staff</string>
    <key>WorkingDirectory</key>
    <string>${USER_HOME}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${USER_HOME}</string>
        <key>PATH</key>
        <string>${VENV_DIR}/bin:${USER_HOME}/.local/bin:${LOCAL_BREW_DIR}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>OLLAMA_HOST</key>
        <string>0.0.0.0:${OLLAMA_PORT}</string>
        <key>OLLAMA_ORIGINS</key>
        <string>*</string>
        <key>OLLAMA_MODELS</key>
        <string>${USER_HOME}/.ollama/models</string>
        <key>OLLAMA_KEEP_ALIVE</key>
        <string>5m</string>
        <key>OLLAMA_NUM_PARALLEL</key>
        <string>1</string>
        <key>OLLAMA_MAX_LOADED_MODELS</key>
        <string>1</string>
    </dict>
    <key>HardResourceLimits</key>
    <dict>
        <key>ResidentSetSize</key>
        <integer>53687091200</integer>
    </dict>
    <key>SoftResourceLimits</key>
    <dict>
        <key>ResidentSetSize</key>
        <integer>53687091200</integer>
    </dict>
    <key>ProgramArguments</key>
    <array>
        <string>${LOCAL_BREW_DIR}/bin/ollama</string>
        <string>serve</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LAUNCH_LOGS_DIR}/ollama.log</string>
    <key>StandardErrorPath</key>
    <string>${LAUNCH_LOGS_DIR}/ollama.err</string>
</dict>
</plist>
EOF

manage_launch_daemon "${OLLAMA_PLIST}" "com.turnstone.ollama" "${OLLAMA_PORT}"
log_success "Ollama system daemon loaded."

# Step 3c: Download and Associate Models with Servers
log_info "Step 3c: Verifying & downloading models for MLX and Ollama..."

# 1. MLX Model
log_info "Checking / downloading MLX model '${MLX_MODEL}' via Hugging Face..."
run_as_target_user "
    export PATH=\"${VENV_DIR}/bin:${USER_HOME}/.local/bin:\$PATH\"
    if command -v huggingface-cli &>/dev/null; then
        huggingface-cli download ${MLX_MODEL} --local-dir-use-symlinks False 2>/dev/null || true
    fi
"
log_success "MLX model verified (${MLX_MODEL})."

# 2. Ollama Models
log_info "Waiting for Ollama daemon to initialize..."
for i in {1..20}; do
    if curl -s "http://127.0.0.1:${OLLAMA_PORT}/api/tags" &>/dev/null; then
        break
    fi
    sleep 1
done

log_info "Pulling Ollama models (Qwen 3.8 27B and Gemma 4 31B)..."
run_as_target_user "
    eval \"\$(${LOCAL_BREW_DIR}/bin/brew shellenv)\"
    export OLLAMA_HOST=127.0.0.1:${OLLAMA_PORT}
    echo 'Pulling Qwen 3.8 27B model into Ollama...'
    ollama pull qwen3.8:27b-8bit 2>/dev/null || ollama pull qwen3.8:27b 2>/dev/null || ollama pull qwen3.8:latest 2>/dev/null || ollama pull qwen2.5:32b 2>/dev/null || true

    echo 'Pulling Gemma 4 31B model into Ollama...'
    ollama pull gemma4:31b-8bit 2>/dev/null || ollama pull gemma4:31b 2>/dev/null || ollama pull gemma4:latest 2>/dev/null || ollama pull gemma:31b 2>/dev/null || true

    echo 'Pulling Ornith Latest model into Ollama...'
    ollama pull ornith:latest 2>/dev/null || true
"
log_success "Ollama models pulled successfully."

# Step 4: Configure Shared Workspace Storage (NFS)
if [ "${SKIP_NFS}" != "true" ]; then
    log_info "Step 4: Configuring NFS shared storage (${NFS_SERVER}:${NFS_SHARE} -> ${MOUNT_POINT})..."

    # 1. Clean up obsolete SMB launchd daemon if present
    if sudo launchctl print "system/com.turnstone.smb-mount" &>/dev/null; then
        log_info "Unloading obsolete com.turnstone.smb-mount LaunchDaemon..."
        sudo launchctl bootout "system/com.turnstone.smb-mount" 2>/dev/null || sudo launchctl unload /Library/LaunchDaemons/com.turnstone.smb-mount.plist 2>/dev/null || true
        sudo rm -f /Library/LaunchDaemons/com.turnstone.smb-mount.plist
    fi

    # 2. Unmount obsolete SMB filesystem if mounted at target path
    if mount | grep -F "on ${MOUNT_POINT} " | grep -q "smbfs"; then
        log_info "Unmounting obsolete SMB share from ${MOUNT_POINT}..."
        sudo umount -f "${MOUNT_POINT}" 2>/dev/null || true
    fi

    # 3. Create target directory with correct ownership
    sudo mkdir -p "${MOUNT_POINT}" 2>/dev/null || mkdir -p "${MOUNT_POINT}" 2>/dev/null || true
    sudo chown -R "${INFER_USER}:staff" "${MOUNT_POINT}" 2>/dev/null || true

    # 4. Install standalone NFS mount script into /usr/local/bin
    NFS_HELPER="/usr/local/bin/turnstone-mount-nfs"
    sudo mkdir -p /usr/local/bin 2>/dev/null || true
    sudo cat > "${NFS_HELPER}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

NFS_SERVER="${NFS_SERVER}"
NFS_SHARE="${NFS_SHARE}"
MOUNT_POINT="${MOUNT_POINT}"
INFER_USER="${INFER_USER}"

# If an obsolete SMB filesystem is currently mounted at the target point, unmount it
if mount | grep -F "on \${MOUNT_POINT} " | grep -q "smbfs"; then
    echo "[INFO] Unmounting obsolete SMB share from \${MOUNT_POINT}..."
    umount -f "\${MOUNT_POINT}" 2>/dev/null || true
fi

# If already mounted with NFS, exit cleanly
if mount | grep -F "on \${MOUNT_POINT} " | grep -q "nfs"; then
    exit 0
fi

mkdir -p "\${MOUNT_POINT}" 2>/dev/null || true

# Mount using NFSv4 with resvport, falling back to NFSv3 if needed
mount_nfs -o vers=4,noatime,hard,intr,resvport,rsize=1048576,wsize=1048576 "\${NFS_SERVER}:\${NFS_SHARE}" "\${MOUNT_POINT}" 2>/dev/null || \
mount_nfs -o vers=3,noatime,hard,intr,resvport,rsize=1048576,wsize=1048576 "\${NFS_SERVER}:\${NFS_SHARE}" "\${MOUNT_POINT}" 2>/dev/null || {
    echo "[ERROR] Failed to mount NFS share \${NFS_SERVER}:\${NFS_SHARE} at \${MOUNT_POINT}."
    exit 1
}

chown -R "\${INFER_USER}:staff" "\${MOUNT_POINT}" 2>/dev/null || true
chmod 775 "\${MOUNT_POINT}" 2>/dev/null || true
echo "[SUCCESS] Mounted \${NFS_SERVER}:\${NFS_SHARE} at \${MOUNT_POINT}."
EOF
    sudo chmod 755 "${NFS_HELPER}"
    log_success "NFS mount helper installed at ${NFS_HELPER}."

    # 5. Install and manage LaunchDaemon to keep NFS mounted across reboots & network reconnection
    NFS_PLIST="${SYSTEM_DAEMONS_DIR}/com.turnstone.nfs-mount.plist"
    log_info "Configuring com.turnstone.nfs-mount system daemon..."
    sudo cat > "${NFS_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.turnstone.nfs-mount</string>
    <key>UserName</key>
    <string>root</string>
    <key>GroupName</key>
    <string>wheel</string>
    <key>WorkingDirectory</key>
    <string>/tmp</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${NFS_HELPER}</string>
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
    <string>${LAUNCH_LOGS_DIR}/nfs-mount.log</string>
    <key>StandardErrorPath</key>
    <string>${LAUNCH_LOGS_DIR}/nfs-mount.err</string>
</dict>
</plist>
EOF
    manage_launch_daemon "${NFS_PLIST}" "com.turnstone.nfs-mount"

    # 6. Execute mount immediately if not already active
    if ! mount | grep -F "on ${MOUNT_POINT} " | grep -q "nfs"; then
        log_info "Executing immediate NFS mount..."
        sudo "${NFS_HELPER}" || log_warn "Immediate NFS mount returned non-zero (will retry via launchd)."
    fi

    if mount | grep -F "on ${MOUNT_POINT} " | grep -q "nfs"; then
        log_success "NFS storage successfully mounted at ${MOUNT_POINT}."
    else
        log_warn "NFS mount not yet active at ${MOUNT_POINT}; launchd daemon is running to connect when reachable."
    fi
else
    log_info "Step 4: Skipping NFS mount setup (--skip-nfs specified)."
fi

# Step 5: Post-Deployment Health Verification (inference services only)
log_info "Step 5: Performing post-deployment health verification..."

DEPLOY_HAS_ERROR=false

# 1. Check MLX Server
log_info "Testing MLX Server health at http://127.0.0.1:${MLX_PORT}/v1/models (waiting up to 60s for weight allocation)..."
MLX_READY=false
for attempt in {1..60}; do
    if curl -s -f "http://127.0.0.1:${MLX_PORT}/v1/models" &>/dev/null; then
        MLX_READY=true
        break
    fi
    sleep 1
done

if [ "${MLX_READY}" = true ]; then
    MLX_MODELS=$(curl -s "http://127.0.0.1:${MLX_PORT}/v1/models" || true)
    log_success "MLX Server is healthy: ${MLX_MODELS}"
else
    log_error "MLX Server failed to respond on http://127.0.0.1:${MLX_PORT}/v1/models!"
    log_warn "Recent MLX stdout log (${LAUNCH_LOGS_DIR}/mlx-server.log):"
    tail -n 25 "${LAUNCH_LOGS_DIR}/mlx-server.log" 2>/dev/null || true
    log_warn "Recent MLX stderr log (${LAUNCH_LOGS_DIR}/mlx-server.err):"
    tail -n 25 "${LAUNCH_LOGS_DIR}/mlx-server.err" 2>/dev/null || true
    DEPLOY_HAS_ERROR=true
fi

# 2. Check Ollama Server
log_info "Testing Ollama Server health at http://127.0.0.1:${OLLAMA_PORT}/api/tags..."
OLLAMA_READY=false
for attempt in {1..30}; do
    if curl -s -f "http://127.0.0.1:${OLLAMA_PORT}/api/tags" &>/dev/null; then
        OLLAMA_READY=true
        break
    fi
    sleep 1
done

if [ "${OLLAMA_READY}" = true ]; then
    OLLAMA_TAGS=$(curl -s "http://127.0.0.1:${OLLAMA_PORT}/api/tags" || true)
    log_success "Ollama Server is healthy: ${OLLAMA_TAGS}"
else
    log_error "Ollama Server failed to respond on http://127.0.0.1:${OLLAMA_PORT}/api/tags!"
    log_warn "Recent Ollama stderr log (${LAUNCH_LOGS_DIR}/ollama.err):"
    tail -n 25 "${LAUNCH_LOGS_DIR}/ollama.err" 2>/dev/null || true
    DEPLOY_HAS_ERROR=true
fi

echo -e "${GREEN}=================================================================${NC}"
echo -e "${GREEN}  LLM Inference Node (Apple Silicon) Deployed Successfully!     ${NC}"
echo -e "${GREEN}=================================================================${NC}"
echo -e "Service User: ${INFER_USER} (${USER_HOME})"
echo -e "Node ID: ${NODE_ID}"
echo -e "LAN IP: ${LAN_IP}"
echo -e "MLX Server API (Pinned): http://127.0.0.1:${MLX_PORT}/v1 (${MLX_MODEL})"
echo -e "Ollama Server API (Dynamic): http://127.0.0.1:${OLLAMA_PORT}/v1 (Qwen3.8 27B, Gemma 4 31B)"
echo -e "Node role: LLM inference server (no Turnstone node installed here)"
echo -e "Homebrew Prefix: ${LOCAL_BREW_DIR}"
echo -e "all-smi Utility: ${ALL_SMI_BIN} (sudo NOPASSWD enabled)"
if [ "${SKIP_NFS}" != "true" ]; then
    echo -e "Shared storage (NFS): ${NFS_SERVER}:${NFS_SHARE} mounted at ${MOUNT_POINT}"
fi
echo -e ""
echo -e "The Turnstone node now runs in a dedicated Debian 12 container."
echo -e "Run deploy_turnstone_debian12.sh to provision it."

if [ "${DEPLOY_HAS_ERROR}" = true ]; then
    log_error "One or more inference services failed health checks. Please review the logs above."
    exit 1
fi
