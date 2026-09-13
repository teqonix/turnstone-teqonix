#!/usr/bin/env bash
# =============================================================================
# Turnstone LLM Inference Node Deployment (AMD Ryzen AI Halo - Linux)
#
# This node acts as an LLM inference server. It provisions:
#   1) ryzenadj power-management utility (TDP control)
#   2) NVIDIA Personal AI Router (PAIR) package and ROCm Ollama manifest
#   3) Systemd service running nvpair-tui in a dedicated tmux session (teqonix)
#   4) Shared NFS workspace storage
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

# Configuration & Defaults
PAIR_ENGINE="${PAIR_ENGINE:-lmstudio}"
PAIR_LMSTUDIO_URL="${PAIR_LMSTUDIO_URL:-http://127.0.0.1:1235/v1}"
PAIR_OLLAMA_URL="${PAIR_OLLAMA_URL:-http://127.0.0.1:11434/v1}"
LEMONADE_URL="${LEMONADE_URL:-http://127.0.0.1:8000/v1}"
SKIP_RYZENADJ="${SKIP_RYZENADJ:-false}"
SKIP_PAIR="${SKIP_PAIR:-false}"
SKIP_TMUX_DAEMON="${SKIP_TMUX_DAEMON:-false}"
NFS_SERVER="${NFS_SERVER:-silo-14.lan}"
NFS_SHARE="${NFS_SHARE:-/mnt/silo-14/ai-playground}"
MOUNT_POINT="${MOUNT_POINT:-/home/turnstone/silo-14/ai-playground}"
SKIP_NFS="${SKIP_NFS:-false}"

# Auto-discover NFS server / share from secret files if present
auto_discover_nfs() {
    local secret_candidates=(
        "${SCRIPT_DIR}/secrets/turnstone_np_nfs.secret"
        "${SCRIPT_DIR}/secrets/turnstone_np_smb.secret"
        "${SCRIPT_DIR}/secrets/turnstone_np.secret"
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
    echo "LLM inference node deployment (NVIDIA Personal AI Router + ROCm 10.0 Llama + RyzenAdj)."
    echo ""
    echo "Options:"
    echo "      --engine <engine>          PAIR engine backend: 'lmstudio' (ROCm 10.0 llama drop-in), 'ollama', or 'both' [default: ${PAIR_ENGINE}]"
    echo "      --pair-url <url>           Local PAIR API base URL [default: ${PAIR_LMSTUDIO_URL}]"
    echo "      --lemonade-url <url>       Local Lemonade API base URL [default: ${LEMONADE_URL}]"
    echo "      --skip-pair                Skip downloading/installing NVIDIA Personal AI Router"
    echo "      --skip-tmux-daemon         Skip configuring/enabling the nvpair.service tmux daemon"
    echo "      --skip-ryzenadj            Skip checking/installing ryzenadj / TDP service"
    echo "      --nfs-server <host>        NFS server hostname [default: ${NFS_SERVER}]"
    echo "      --nfs-share <path>         NFS share export path [default: ${NFS_SHARE}]"
    echo "      --mount-point <path>       Local NFS mount point [default: ${MOUNT_POINT}]"
    echo "      --skip-nfs                 Skip NFS utilities and share mounting"
    echo "  -h, --help                     Display this help message and exit"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --engine|--pair-engine)
            PAIR_ENGINE="$2"
            shift 2
            ;;
        --lemonade-url)
            LEMONADE_URL="$2"
            shift 2
            ;;
        --pair-url)
            PAIR_LMSTUDIO_URL="$2"
            PAIR_OLLAMA_URL="$2"
            shift 2
            ;;
        --skip-pair)
            SKIP_PAIR="true"
            shift
            ;;
        --skip-tmux-daemon)
            SKIP_TMUX_DAEMON="true"
            shift
            ;;
        --skip-ryzenadj)
            SKIP_RYZENADJ="true"
            shift
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
echo -e "${BLUE}  LLM Inference Node Deployment (AMD Ryzen AI Halo - PAIR/ROCm)  ${NC}"
echo -e "${BLUE}=================================================================${NC}"

# Step 1: Root Check
log_info "Step 1: Checking permissions..."
if [ "$EUID" -ne 0 ]; then
    log_warn "This script must be run with sudo or as root."
    exec sudo bash "$0" "$@"
fi
log_success "Permissions verified."

# Step 2: Check and Install RyzenAdj Power Management Utility
log_info "Step 2: Checking for ryzenadj power management utility..."
if [ "${SKIP_RYZENADJ}" != "true" ]; then
    if ! command -v ryzenadj &>/dev/null && [ ! -x "/usr/local/bin/ryzenadj" ] && [ ! -x "/usr/bin/ryzenadj" ]; then
        log_warn "'ryzenadj' is not installed on this node."
        RYZENADJ_INSTALLER=""
        for cand in "${SCRIPT_DIR}/ryzen_node_custom/install_ryzenadj.sh" "${SCRIPT_DIR}/install_ryzenadj.sh"; do
            if [ -f "${cand}" ]; then
                RYZENADJ_INSTALLER="${cand}"
                break
            fi
        done
        if [ -n "${RYZENADJ_INSTALLER}" ] && [ -f "${RYZENADJ_INSTALLER}" ]; then
            log_info "Executing RyzenAdj installer (${RYZENADJ_INSTALLER})..."
            bash "${RYZENADJ_INSTALLER}"
            log_success "RyzenAdj and TDP service installation complete."
        else
            log_warn "RyzenAdj installer script not found at '${SCRIPT_DIR}/ryzen_node_custom/install_ryzenadj.sh'. Continuing deployment."
        fi
    else
        INSTALLED_RYZENADJ="$(command -v ryzenadj 2>/dev/null || ( [ -x "/usr/local/bin/ryzenadj" ] && echo "/usr/local/bin/ryzenadj" ) || echo "/usr/bin/ryzenadj")"
        log_success "'ryzenadj' is already installed at: ${INSTALLED_RYZENADJ}"
    fi
else
    log_info "Skipping RyzenAdj check (--skip-ryzenadj specified)."
fi

# Step 3: Install NVIDIA Personal AI Router (PAIR)
if [ "${SKIP_PAIR}" != "true" ]; then
    log_info "Step 3: Installing/Updating NVIDIA Personal AI Router (PAIR)..."

    # Install prerequisites
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl tmux jq ca-certificates python3

    log_info "Fetching latest PAIR release metadata..."
    PAIR_YML_CONTENT=""
    PAIR_RELEASE_URLS=(
        "https://github.com/NVIDIA/Personal-AI-Router/releases/latest/download/latest-linux.yml"
        "https://github.com/NVIDIA/Personal-AI-Router/releases/download/latest/latest-linux.yml"
    )
    for r_url in "${PAIR_RELEASE_URLS[@]}"; do
        if PAIR_YML_CONTENT=$(curl -sSL -f "${r_url}" 2>/dev/null); then
            [ -n "${PAIR_YML_CONTENT}" ] && break
        fi
    done

    PAIR_DEB_NAME=""
    if [ -n "${PAIR_YML_CONTENT}" ]; then
        PAIR_DEB_NAME=$(echo "${PAIR_YML_CONTENT}" | awk -F': ' '/url:.*\.deb/{print $2}' | tr -d ' "\r' | head -n 1)
        if [ -z "${PAIR_DEB_NAME}" ]; then
            PAIR_DEB_NAME=$(echo "${PAIR_YML_CONTENT}" | awk -F': ' '/path:.*\.deb/{print $2}' | tr -d ' "\r' | head -n 1)
        fi
    fi

    if [ -z "${PAIR_DEB_NAME}" ]; then
        PAIR_DEB_NAME="NVPAIR-Setup-0.1.1-amd64.deb"
        log_warn "Could not parse deb filename from release YAML. Using fallback: ${PAIR_DEB_NAME}"
    fi

    log_info "Target PAIR package: ${PAIR_DEB_NAME}"
    PAIR_DOWNLOAD_URLS=(
        "https://github.com/NVIDIA/Personal-AI-Router/releases/latest/download/${PAIR_DEB_NAME}"
        "https://github.com/NVIDIA/Personal-AI-Router/releases/download/latest/${PAIR_DEB_NAME}"
    )

    TEMP_DEB="/tmp/${PAIR_DEB_NAME}"
    DOWNLOADED=false
    for dl_url in "${PAIR_DOWNLOAD_URLS[@]}"; do
        log_info "Attempting download from ${dl_url}..."
        if curl -sSL -f -o "${TEMP_DEB}" "${dl_url}"; then
            DOWNLOADED=true
            break
        fi
    done

    if [ "${DOWNLOADED}" = true ] && [ -s "${TEMP_DEB}" ]; then
        log_info "Installing ${TEMP_DEB}..."
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${TEMP_DEB}"; then
            log_warn "apt-get install returned non-zero; attempting dpkg -i and apt-get install -f..."
            dpkg -i "${TEMP_DEB}" || true
            DEBIAN_FRONTEND=noninteractive apt-get install -f -y -qq
        fi
        rm -f "${TEMP_DEB}"
        log_success "NVIDIA Personal AI Router package installed."
    else
        log_warn "Failed to download PAIR .deb. Checking if /opt/PAIR already exists..."
        if [ ! -d "/opt/PAIR" ]; then
            log_error "PAIR is not installed and package download failed."
            exit 1
        fi
    fi

    # Ensure container engine (podman or docker) is available for ROCm 10.0 llama-server
    if ! command -v podman &>/dev/null && ! command -v docker &>/dev/null; then
        log_info "Installing podman container engine for llama.cpp ROCm runtime..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq podman || log_warn "podman installation returned non-zero."
    fi

    # Ensure users teqonix and turnstone belong to render and video groups for ROCm GPU access
    for u in "teqonix" "turnstone"; do
        if id -u "${u}" &>/dev/null; then
            usermod -aG render,video "${u}" 2>/dev/null || true
            if getent group docker &>/dev/null; then
                usermod -aG docker "${u}" 2>/dev/null || true
            fi
        fi
    done

    # Enable lingering for service user teqonix so rootless Podman user session stays active
    loginctl enable-linger teqonix 2>/dev/null || true
    if id -u teqonix &>/dev/null; then
        systemctl start "user@$(id -u teqonix).service" 2>/dev/null || true
    fi

    if [ -e "/dev/kfd" ]; then
        chmod 666 /dev/kfd 2>/dev/null || true
    fi
    if [ -d "/dev/dri" ]; then
        chmod 666 /dev/dri/* 2>/dev/null || true
    fi

    # Install pair-llama-server runner script
    PAIR_RUNNER_SRC=""
    CANDIDATE_RUNNERS=(
        "${SCRIPT_DIR}/nvidia_personal_ai_router/pair-llama-server"
        "${REPO_ROOT}/.github/issues/bare_metal_migration/nvidia_personal_ai_router/pair-llama-server"
    )
    for cand_run in "${CANDIDATE_RUNNERS[@]}"; do
        if [ -f "${cand_run}" ]; then
            PAIR_RUNNER_SRC="${cand_run}"
            break
        fi
    done

    if [ -n "${PAIR_RUNNER_SRC}" ]; then
        log_info "Installing pair-llama-server from ${PAIR_RUNNER_SRC} to /usr/local/bin..."
        cp -f "${PAIR_RUNNER_SRC}" "/usr/local/bin/pair-llama-server"
        chmod 755 "/usr/local/bin/pair-llama-server"
        ln -sf "/usr/local/bin/pair-llama-server" "/usr/bin/pair-llama-server"
        ln -sf "/usr/local/bin/pair-llama-server" "/usr/local/bin/lms"
        ln -sf "/usr/local/bin/pair-llama-server" "/usr/bin/lms"

        # Create user ~/.lmstudio/bin/lms symlinks so PAIR detect check passes unconditionally
        for u_home in "/home/teqonix" "/root"; do
            if [ -d "${u_home}" ]; then
                mkdir -p "${u_home}/.lmstudio/bin"
                ln -sf "/usr/local/bin/pair-llama-server" "${u_home}/.lmstudio/bin/lms"
                if [ "${u_home}" = "/home/teqonix" ] && id -u teqonix &>/dev/null; then
                    chown -R teqonix:teqonix "${u_home}/.lmstudio" 2>/dev/null || true
                fi
            fi
        done
        log_success "pair-llama-server and LMS drop-in wrappers installed."
    else
        log_warn "pair-llama-server not found locally. Skipping runner copy."
    fi

    # Install pair-model-multiplexer (LM Studio Multi-Model OpenAI proxy)
    PAIR_MUX_SRC=""
    CANDIDATE_MUX=(
        "${SCRIPT_DIR}/nvidia_personal_ai_router/pair_model_multiplexer.py"
        "${REPO_ROOT}/.github/issues/bare_metal_migration/nvidia_personal_ai_router/pair_model_multiplexer.py"
    )
    for cand_mux in "${CANDIDATE_MUX[@]}"; do
        if [ -f "${cand_mux}" ]; then
            PAIR_MUX_SRC="${cand_mux}"
            break
        fi
    done

    if [ -n "${PAIR_MUX_SRC}" ]; then
        log_info "Installing pair-model-multiplexer from ${PAIR_MUX_SRC} to /usr/local/bin..."
        cp -f "${PAIR_MUX_SRC}" "/usr/local/bin/pair-model-multiplexer"
        chmod 755 "/usr/local/bin/pair-model-multiplexer"
        ln -sf "/usr/local/bin/pair-model-multiplexer" "/usr/bin/pair-model-multiplexer"
        log_success "pair-model-multiplexer installed."
    else
        log_warn "pair_model_multiplexer.py not found locally. Skipping multiplexer copy."
    fi

    # Install /etc/turnstone/llama_rocm.conf template and configure resident models
    mkdir -p /etc/turnstone /models
    chmod 755 /etc/turnstone /models 2>/dev/null || true

    if [ -d "/home/turnstone/models" ]; then
        ln -sfn "/home/turnstone/models" /models/local 2>/dev/null || true
    fi
    if [ -d "/home/turnstone/.lmstudio/models" ]; then
        ln -sfn "/home/turnstone/.lmstudio/models" /models/lmstudio 2>/dev/null || true
    fi

    CONF_EXAMPLE_SRC=""
    CANDIDATE_CONFS=(
        "${SCRIPT_DIR}/nvidia_personal_ai_router/llama_rocm.conf.example"
        "${REPO_ROOT}/.github/issues/bare_metal_migration/nvidia_personal_ai_router/llama_rocm.conf.example"
    )
    for cand_c in "${CANDIDATE_CONFS[@]}"; do
        if [ -f "${cand_c}" ]; then
            CONF_EXAMPLE_SRC="${cand_c}"
            break
        fi
    done

    if [ -n "${CONF_EXAMPLE_SRC}" ]; then
        cp -f "${CONF_EXAMPLE_SRC}" "/etc/turnstone/llama_rocm.conf.example"
        chmod 644 "/etc/turnstone/llama_rocm.conf.example"
        if [ ! -f "/etc/turnstone/llama_rocm.conf" ]; then
            log_info "Deploying default /etc/turnstone/llama_rocm.conf from template..."
            cp -f "${CONF_EXAMPLE_SRC}" "/etc/turnstone/llama_rocm.conf"
            chmod 644 "/etc/turnstone/llama_rocm.conf"
            log_success "Created /etc/turnstone/llama_rocm.conf with Multi-Model Resident Stacking configuration."
        else
            log_info "Preserving existing /etc/turnstone/llama_rocm.conf (template updated at /etc/turnstone/llama_rocm.conf.example)."
        fi
    fi

    # Ensure nvpair-tui is accessible on standard PATH
    if [ -x "/opt/PAIR/resources/cli-bin/nvpair-tui" ]; then
        ln -sf "/opt/PAIR/resources/cli-bin/nvpair-tui" "/usr/bin/nvpair-tui"
        ln -sf "/opt/PAIR/resources/cli-bin/nvpair-tui" "/usr/local/bin/nvpair-tui"
    fi
    if [ -x "/opt/PAIR/resources/cli-bin/nvpair" ]; then
        ln -sf "/opt/PAIR/resources/cli-bin/nvpair" "/usr/bin/nvpair"
        ln -sf "/opt/PAIR/resources/cli-bin/nvpair" "/usr/local/bin/nvpair"
    fi

    # Step 4: Inject Custom PAIR Configurations
    log_info "Step 4: Injecting custom PAIR manifest configurations (Engine: ${PAIR_ENGINE})..."

    # 4a. LM Studio drop-in manifest (ROCm 10.0 Llama)
    if [ "${PAIR_ENGINE}" = "lmstudio" ] || [ "${PAIR_ENGINE}" = "both" ]; then
        LMS_MANIFEST_SRC=""
        CANDIDATE_LMS_MANIFESTS=(
            "${SCRIPT_DIR}/nvidia_personal_ai_router/ryzen_lmstudio.json"
            "${REPO_ROOT}/.github/issues/bare_metal_migration/nvidia_personal_ai_router/ryzen_lmstudio.json"
        )
        for cand in "${CANDIDATE_LMS_MANIFESTS[@]}"; do
            if [ -f "${cand}" ]; then
                LMS_MANIFEST_SRC="${cand}"
                break
            fi
        done

        if [ -z "${LMS_MANIFEST_SRC}" ]; then
            log_info "Fetching ryzen_lmstudio.json at runtime from remote repository..."
            REMOTE_LMS_URL="https://raw.githubusercontent.com/teqonix/turnstone-teqonix/main/.github/issues/bare_metal_migration/nvidia_personal_ai_router/ryzen_lmstudio.json"
            TMP_LMS_MANIFEST="/tmp/ryzen_lmstudio.json"
            if curl -sSfL "${REMOTE_LMS_URL}" -o "${TMP_LMS_MANIFEST}" 2>/dev/null; then
                LMS_MANIFEST_SRC="${TMP_LMS_MANIFEST}"
                log_success "Downloaded ryzen_lmstudio.json from remote."
            fi
        fi

        if [ -n "${LMS_MANIFEST_SRC}" ]; then
            log_info "Found ryzen_lmstudio.json at: ${LMS_MANIFEST_SRC}"
            mkdir -p "/opt/PAIR/resources/services/nvpair-engine-manager/manifests"
            cp -f "${LMS_MANIFEST_SRC}" "/opt/PAIR/resources/services/nvpair-engine-manager/manifests/lmstudio.json"

            if [ -d "/opt/PAIR/resources/cli-bin" ]; then
                mkdir -p "/opt/PAIR/resources/cli-bin/manifests"
                cp -f "${LMS_MANIFEST_SRC}" "/opt/PAIR/resources/cli-bin/manifests/lmstudio.json"
            fi

            for u_home in "/home/teqonix" "/root"; do
                if [ -d "${u_home}" ]; then
                    u_dir="${u_home}/.config/Nvidia Corporation/Personal AI Router/manifests"
                    mkdir -p "${u_dir}"
                    cp -f "${LMS_MANIFEST_SRC}" "${u_dir}/lmstudio.json"
                    if [ "${u_home}" = "/home/teqonix" ] && id -u teqonix &>/dev/null; then
                        chown -R teqonix:teqonix "${u_home}/.config"
                    fi
                    log_success "Injected LM Studio drop-in manifest to: ${u_dir}/lmstudio.json"
                fi
            done
        else
            log_warn "ryzen_lmstudio.json not found. Skipping LM Studio manifest injection."
        fi
    fi

    # 4b. Ollama manifest
    if [ "${PAIR_ENGINE}" = "ollama" ] || [ "${PAIR_ENGINE}" = "both" ]; then
        OLLAMA_MANIFEST_SRC=""
        CANDIDATE_OLLAMA_MANIFESTS=(
            "${SCRIPT_DIR}/nvidia_personal_ai_router/ryzen_ollama.json"
            "${REPO_ROOT}/.github/issues/bare_metal_migration/nvidia_personal_ai_router/ryzen_ollama.json"
        )
        for cand in "${CANDIDATE_OLLAMA_MANIFESTS[@]}"; do
            if [ -f "${cand}" ]; then
                OLLAMA_MANIFEST_SRC="${cand}"
                break
            fi
        done

        if [ -z "${OLLAMA_MANIFEST_SRC}" ]; then
            log_info "Fetching ryzen_ollama.json at runtime from remote repository..."
            REMOTE_OLLAMA_URL="https://raw.githubusercontent.com/teqonix/turnstone-teqonix/main/.github/issues/bare_metal_migration/nvidia_personal_ai_router/ryzen_ollama.json"
            TMP_OLLAMA_MANIFEST="/tmp/ryzen_ollama.json"
            if curl -sSfL "${REMOTE_OLLAMA_URL}" -o "${TMP_OLLAMA_MANIFEST}" 2>/dev/null; then
                OLLAMA_MANIFEST_SRC="${TMP_OLLAMA_MANIFEST}"
                log_success "Downloaded ryzen_ollama.json from remote."
            fi
        fi

        if [ -n "${OLLAMA_MANIFEST_SRC}" ]; then
            log_info "Found ryzen_ollama.json at: ${OLLAMA_MANIFEST_SRC}"
            mkdir -p "/opt/PAIR/resources/services/nvpair-engine-manager/manifests"
            cp -f "${OLLAMA_MANIFEST_SRC}" "/opt/PAIR/resources/services/nvpair-engine-manager/manifests/ryzen_ollama.json"

            if [ -d "/opt/PAIR/resources/cli-bin" ]; then
                mkdir -p "/opt/PAIR/resources/cli-bin/manifests"
                cp -f "${OLLAMA_MANIFEST_SRC}" "/opt/PAIR/resources/cli-bin/manifests/ryzen_ollama.json"
            fi

            for u_home in "/home/teqonix" "/root"; do
                if [ -d "${u_home}" ]; then
                    u_dir="${u_home}/.config/Nvidia Corporation/Personal AI Router/manifests"
                    mkdir -p "${u_dir}"
                    cp -f "${OLLAMA_MANIFEST_SRC}" "${u_dir}/ryzen_ollama.json"
                    if [ "${u_home}" = "/home/teqonix" ] && id -u teqonix &>/dev/null; then
                        chown -R teqonix:teqonix "${u_home}/.config"
                    fi
                    log_success "Injected Ollama manifest to: ${u_dir}/ryzen_ollama.json"
                fi
            done
        else
            log_warn "ryzen_ollama.json not found. Skipping Ollama manifest injection."
        fi
    fi
else
    log_info "Step 3-4: Skipping PAIR installation (--skip-pair specified)."
fi

# Step 5: Configure and Start nvpair tmux Daemon Service
if [ "${SKIP_TMUX_DAEMON}" != "true" ]; then
    log_info "Step 5: Configuring nvpair tmux daemon service..."
    NVPAIR_INSTALLER=""
    CANDIDATE_INSTALLERS=(
        "${SCRIPT_DIR}/nvidia_personal_ai_router/install_nvpair_service.sh"
        "${REPO_ROOT}/.github/issues/bare_metal_migration/nvidia_personal_ai_router/install_nvpair_service.sh"
    )
    for cand in "${CANDIDATE_INSTALLERS[@]}"; do
        if [ -f "${cand}" ]; then
            NVPAIR_INSTALLER="${cand}"
            break
        fi
    done

    if [ -z "${NVPAIR_INSTALLER}" ]; then
        log_info "Fetching install_nvpair_service.sh at runtime from remote repository..."
        REMOTE_INSTALLER_URL="https://raw.githubusercontent.com/teqonix/turnstone-teqonix/main/.github/issues/bare_metal_migration/nvidia_personal_ai_router/install_nvpair_service.sh"
        TMP_INSTALLER="/tmp/install_nvpair_service.sh"
        if curl -sSfL "${REMOTE_INSTALLER_URL}" -o "${TMP_INSTALLER}" 2>/dev/null; then
            NVPAIR_INSTALLER="${TMP_INSTALLER}"
            log_success "Downloaded install_nvpair_service.sh from remote."
        fi
    fi

    if [ -n "${NVPAIR_INSTALLER}" ]; then
        bash "${NVPAIR_INSTALLER}" --user "teqonix"
    else
        log_error "Failed to locate or download install_nvpair_service.sh."
        exit 1
    fi
else
    log_info "Step 5: Skipping nvpair tmux daemon setup (--skip-tmux-daemon specified)."
fi

# Step 6: Verify Local Inference Endpoints
log_info "Step 6: Verifying local inference endpoints..."

# Check LM Studio drop-in endpoint if selected (port 1235)
if [ "${PAIR_ENGINE}" = "lmstudio" ] || [ "${PAIR_ENGINE}" = "both" ]; then
    LMS_READY=false
    for _attempt in {1..10}; do
        if curl -sf "${PAIR_LMSTUDIO_URL}/models" &>/dev/null 2>&1 || curl -sf "http://127.0.0.1:1235/v1/models" &>/dev/null 2>&1; then
            LMS_READY=true
            break
        fi
        sleep 1
    done

    if [ "${LMS_READY}" = true ]; then
        log_success "PAIR LM Studio (ROCm 10.0 llama) endpoint is active on port 1235."
        DETECTED_MODELS=$(curl -sf "http://127.0.0.1:1235/v1/models" 2>/dev/null | jq -r '.data[].id' 2>/dev/null | tr '\n' ' ' || true)
        if [ -n "${DETECTED_MODELS}" ]; then
            log_info "Active resident models on port 1235: ${DETECTED_MODELS}"
        fi
    else
        log_warn "PAIR LM Studio endpoint not yet responding on port 1235 (will start with nvpair tmux session)."
    fi
fi

# Check Ollama endpoint if selected (port 11434)
if [ "${PAIR_ENGINE}" = "ollama" ] || [ "${PAIR_ENGINE}" = "both" ]; then
    OLLAMA_READY=false
    for _attempt in {1..10}; do
        if curl -sf "${PAIR_OLLAMA_URL%/*}/api/tags" &>/dev/null 2>&1 || curl -sf "http://127.0.0.1:11434/" &>/dev/null 2>&1; then
            OLLAMA_READY=true
            break
        fi
        sleep 1
    done

    if [ "${OLLAMA_READY}" = true ]; then
        log_success "PAIR Ollama endpoint is active and responding on port 11434."
    else
        log_warn "PAIR Ollama endpoint not yet responding on port 11434 (will start with nvpair tmux session)."
    fi
fi

# Optional Lemonade check
if curl -sf "${LEMONADE_URL}/models" &>/dev/null 2>&1; then
    log_success "Lemonade inference server is active at ${LEMONADE_URL}."
fi

# Step 7: Configure NFS Shared Storage for AI Workspace
if [ "${SKIP_NFS}" != "true" ]; then
    log_info "Step 7: Configuring NFS shared storage (${NFS_SERVER}:${NFS_SHARE} -> ${MOUNT_POINT})..."

    if ! dpkg -s nfs-common &>/dev/null; then
        log_info "Installing nfs-common package..."
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nfs-common
        log_success "nfs-common installed successfully."
    else
        log_success "nfs-common is already installed."
    fi

    # Ensure /etc/fstab exists
    [ -f /etc/fstab ] || touch /etc/fstab

    # Normalize paths (remove trailing slash except for root)
    [ "${MOUNT_POINT}" != "/" ] && MOUNT_POINT="${MOUNT_POINT%/}"
    [ "${NFS_SHARE}" != "/" ] && NFS_SHARE="${NFS_SHARE%/}"

    FSTAB_LINE="${NFS_SERVER}:${NFS_SHARE}  ${MOUNT_POINT}  nfs  nfsvers=4,noatime,hard,intr,rsize=1048576,wsize=1048576  0  0"

    # 1. Comment out any legacy SMB/CIFS entries for the target mount point
    if grep -qE "^[[:space:]]*[^#]*[[:space:]]+${MOUNT_POINT}[[:space:]]+(cifs|smbfs)" /etc/fstab 2>/dev/null; then
        log_info "Commenting out obsolete SMB/CIFS entry for ${MOUNT_POINT} in /etc/fstab..."
        sed -i.bak -E "\#^[[:space:]]*[^#]*[[:space:]]+${MOUNT_POINT}[[:space:]]+(cifs|smbfs)#s/^/# Obsolete SMB: /" /etc/fstab
    fi

    # 2. Check for obsolete mount points in /etc/fstab for this NFS share
    OLD_NFS_MOUNTS=$(awk -v share="${NFS_SERVER}:${NFS_SHARE}" '$1 == share && $0 !~ /^[[:space:]]*#/ {print $2}' /etc/fstab 2>/dev/null || true)
    for old_mp in ${OLD_NFS_MOUNTS}; do
        if [ "${old_mp}" != "${MOUNT_POINT}" ]; then
            log_info "Found obsolete mount point '${old_mp}' for '${NFS_SERVER}:${NFS_SHARE}' in /etc/fstab."
            if mountpoint -q "${old_mp}" 2>/dev/null; then
                log_info "Unmounting obsolete NFS mount point '${old_mp}'..."
                umount "${old_mp}" 2>/dev/null || umount -l "${old_mp}" 2>/dev/null || true
            fi
            log_info "Commenting out obsolete mount point '${old_mp}' in /etc/fstab..."
            sed -i.bak -E "\#^[[:space:]]*[^#]*[[:space:]]*${NFS_SERVER}:${NFS_SHARE}[[:space:]]+${old_mp}([[:space:]]|$)#s/^/# Obsolete NFS mountpoint: /" /etc/fstab 2>/dev/null || true
        fi
    done

    # 3. Check for obsolete NFS sources in /etc/fstab for this mount point
    OLD_NFS_SOURCES=$(awk -v mp="${MOUNT_POINT}" '$2 == mp && ($3 == "nfs" || $3 == "nfs4") && $0 !~ /^[[:space:]]*#/ {print $1}' /etc/fstab 2>/dev/null || true)
    for old_src in ${OLD_NFS_SOURCES}; do
        if [ "${old_src}" != "${NFS_SERVER}:${NFS_SHARE}" ]; then
            log_info "Found obsolete NFS source '${old_src}' for '${MOUNT_POINT}' in /etc/fstab."
            if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
                log_info "Unmounting previous NFS share from '${MOUNT_POINT}'..."
                umount "${MOUNT_POINT}" 2>/dev/null || umount -l "${MOUNT_POINT}" 2>/dev/null || true
            fi
            log_info "Commenting out obsolete NFS source '${old_src}' in /etc/fstab..."
            sed -i.bak -E "\#^[[:space:]]*[^#]*[[:space:]]*${old_src}[[:space:]]+${MOUNT_POINT}([[:space:]]|$)#s/^/# Obsolete NFS source: /" /etc/fstab 2>/dev/null || true
        fi
    done

    # 4. Unmount any stale active mounts of this share elsewhere
    ACTIVE_STALE_MOUNTS=$(awk -v share="${NFS_SERVER}:${NFS_SHARE}" -v target="${MOUNT_POINT}" '$1 == share && $2 != target {print $2}' /proc/mounts 2>/dev/null || true)
    for stale_mp in ${ACTIVE_STALE_MOUNTS}; do
        log_info "Unmounting stale active mount at '${stale_mp}'..."
        umount "${stale_mp}" 2>/dev/null || umount -l "${stale_mp}" 2>/dev/null || true
    done

    # 5. Add or update NFS mount in /etc/fstab
    if grep -qE "^[[:space:]]*[^#]*[[:space:]]*${NFS_SERVER}:${NFS_SHARE}[[:space:]]+${MOUNT_POINT}[[:space:]]+(nfs|nfs4)" /etc/fstab 2>/dev/null; then
        log_info "Updating existing NFS entry for ${MOUNT_POINT} in /etc/fstab..."
        sed -i.bak -E "s#^[[:space:]]*[^#]*[[:space:]]*${NFS_SERVER}:${NFS_SHARE}[[:space:]]+${MOUNT_POINT}[[:space:]]+(nfs|nfs4).*#${FSTAB_LINE}#" /etc/fstab
        log_success "NFS entry in /etc/fstab updated."
    else
        log_info "Adding NFS mount to /etc/fstab..."
        echo "" >> /etc/fstab
        echo "# Turnstone shared NFS storage for AI playground" >> /etc/fstab
        echo "${FSTAB_LINE}" >> /etc/fstab
        log_success "Added NFS entry to /etc/fstab."
    fi

    # 6. Ensure target mount point directory exists
    mkdir -p "${MOUNT_POINT}"

    # Check if MOUNT_POINT is mounted to an unexpected remote NFS share
    if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
        CURRENT_MOUNT_SRC="$(awk -v mp="${MOUNT_POINT}" '$2 == mp {print $1}' /proc/mounts 2>/dev/null | head -n 1 || true)"
        if [ -n "${CURRENT_MOUNT_SRC}" ] && [ "${CURRENT_MOUNT_SRC}" != "${NFS_SERVER}:${NFS_SHARE}" ] && [[ "${CURRENT_MOUNT_SRC}" == *":"* ]]; then
            log_info "Mount at '${MOUNT_POINT}' points to unexpected source '${CURRENT_MOUNT_SRC}'. Remounting..."
            umount "${MOUNT_POINT}" 2>/dev/null || umount -l "${MOUNT_POINT}" 2>/dev/null || true
        fi
    fi

    # 7. Mount NFS share if not already mounted
    if ! mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
        log_info "Mounting ${MOUNT_POINT}..."
        mount "${MOUNT_POINT}" 2>/dev/null || mount -t nfs -o nfsvers=4,noatime,hard,intr,rsize=1048576,wsize=1048576 "${NFS_SERVER}:${NFS_SHARE}" "${MOUNT_POINT}" 2>/dev/null || mount -a 2>/dev/null || log_warn "Mount command returned non-zero. Check network connection to ${NFS_SERVER}."
    fi

    if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
        log_success "NFS storage successfully mounted at ${MOUNT_POINT}."
        if id "turnstone" &>/dev/null; then
            chown -R turnstone:turnstone "${MOUNT_POINT}" 2>/dev/null || true
            chmod a+rx /home/turnstone 2>/dev/null || true
        fi
        # Create convenient system-wide /models link for container engines and PAIR runner
        mkdir -p /models /etc/turnstone
        chmod 755 /etc/turnstone 2>/dev/null || true
        if [ -d "${MOUNT_POINT}/models" ]; then
            ln -sfn "${MOUNT_POINT}/models" /models/shared 2>/dev/null || true
        else
            ln -sfn "${MOUNT_POINT}" /models/shared 2>/dev/null || true
        fi
    else
        log_warn "NFS share could not be mounted at ${MOUNT_POINT} during deployment. It will mount automatically at boot via /etc/fstab."
    fi
else
    log_info "Step 7: Skipping NFS mount setup (--skip-nfs specified)."
fi

LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || hostname -i 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")"
[ -z "${LAN_IP}" ] && LAN_IP="127.0.0.1"

echo -e "${GREEN}=================================================================${NC}"
echo -e "${GREEN}  LLM Inference Node (AMD Ryzen AI Halo) Provisioned!          ${NC}"
echo -e "${GREEN}=================================================================${NC}"
echo -e "Node role: LLM inference server (NVIDIA PAIR + ROCm 10.0 Llama / Ollama)"
if [ "${PAIR_ENGINE}" = "lmstudio" ] || [ "${PAIR_ENGINE}" = "both" ]; then
    echo -e "PAIR Engine (LM Studio alias): http://${LAN_IP}:1235/v1 (ROCm 10.0 multi-model resident stack)"
    echo -e "Engine Configuration:          /etc/turnstone/llama_rocm.conf"
fi
if [ "${PAIR_ENGINE}" = "ollama" ] || [ "${PAIR_ENGINE}" = "both" ]; then
    echo -e "PAIR Ollama endpoint:          http://${LAN_IP}:11434"
fi
echo -e "nvpair tmux session:  nvpair.service (user: teqonix, session: pair)"
echo -e "LAN IP: ${LAN_IP}"
echo -e "Power management: ryzenadj (TDP)"
if [ "${SKIP_NFS}" != "true" ]; then
    echo -e "Shared storage (NFS): ${NFS_SERVER}:${NFS_SHARE} mounted at ${MOUNT_POINT}"
fi
echo -e ""
echo -e "To attach to the PAIR TUI directly on this host:"
echo -e "  sudo -u teqonix tmux attach -t pair"

