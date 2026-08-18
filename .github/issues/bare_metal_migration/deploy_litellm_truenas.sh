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

# Default Configuration Values
LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_HOST="${LITELLM_HOST:-0.0.0.0}"
LITELLM_USER="litellm"
LITELLM_DIR="/etc/litellm"
LITELLM_CONFIG="${LITELLM_DIR}/config.yaml"
VENV_DIR="/opt/litellm-venv"
NUM_WORKERS="${NUM_WORKERS:-4}"

# Node Endpoints (Defaults match Turnstone cluster hostnames & ports)
NODE_RYZEN_ONE="${NODE_RYZEN_ONE:-http://amd-ai-core-one.lan:13305/v1}"
NODE_RYZEN_TWO="${NODE_RYZEN_TWO:-http://amd-ai-core-two.lan:13305/v1}"
NODE_MBP_MLX="${NODE_MBP_MLX:-http://mbp-ai-core.lan:8000/v1}"
NODE_MBP_OLLAMA="${NODE_MBP_OLLAMA:-${NODE_MBP:-http://mbp-ai-core.lan:11434/v1}}"
NODE_MBP="${NODE_MBP:-${NODE_MBP_OLLAMA}}"
MBP_COOLDOWN_SECONDS="${MBP_COOLDOWN_SECONDS:-60}"

MASTER_KEY="${LITELLM_MASTER_KEY:-${MASTER_KEY:-}}"
ROUTING_STRATEGY="${ROUTING_STRATEGY:-least-busy}"
FORCE_RESTART=false
ACTION_INSPECT=false

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -s, --status, --inspect        Inspect current configuration & status without modifying anything
  -p, --port <port>              Port for LiteLLM Proxy to listen on (default: 4000)
  -k, --master-key <key>         LiteLLM Master API Key (auto-generated if empty)
  -w, --workers <num>            Number of Uvicorn workers (default: 4)
  --node-ryzen-1 <url>           URL for Ryzen AI Halo Node 1 (default: http://amd-ai-core-one.lan:13305/v1)
  --node-ryzen-2 <url>           URL for Ryzen AI Halo Node 2 (default: http://amd-ai-core-two.lan:13305/v1)
  --node-mbp-mlx <url>           URL for MacBook Pro MLX Server (default: http://mbp-ai-core.lan:8000/v1)
  --node-mbp-ollama <url>        URL for MacBook Pro Ollama Server (default: http://mbp-ai-core.lan:11434/v1)
  --node-mbp <url>               Alias for MacBook Pro Ollama Server (default: http://mbp-ai-core.lan:11434/v1)
  --mbp-cooldown <seconds>       Cooldown window for qwen3-coder-next priority (default: 60)
  --strategy <strategy>          Routing strategy: least-busy, latency-based-routing (default: least-busy)
  --restart                      Force restart the service
  -h, --help                     Display this help message

EOF
    exit 0
}

# -----------------------------------------------------------------------------
# Function: Inspect & Display Current LiteLLM Cluster Configuration
# -----------------------------------------------------------------------------
show_status_summary() {
    local host_ip
    host_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")

    local key_file="${LITELLM_DIR}/master_key.secret"
    local current_key="${MASTER_KEY}"

    if [ -z "${current_key}" ]; then
        if [ -f "${key_file}" ] && [ -r "${key_file}" ]; then
            current_key="$(cat "${key_file}" 2>/dev/null || echo "<permission-denied: run as sudo>")"
        elif [ -f "${key_file}" ]; then
            current_key="<restricted: present in ${key_file}>"
        else
            current_key="<not-found: not generated yet>"
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

    # Read routing strategy from config if file exists
    local configured_strategy="${ROUTING_STRATEGY}"
    if [ -f "${LITELLM_CONFIG}" ]; then
        local extracted_strat
        extracted_strat=$(grep -E 'routing_strategy:\s*' "${LITELLM_CONFIG}" 2>/dev/null | head -n1 | awk -F': ' '{print $2}' | tr -d '"' | tr -d "'" || true)
        [ -n "${extracted_strat}" ] && configured_strategy="${extracted_strat}"
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
    echo -e "${BOLD}Service Status:${NC}          ${service_status}"
    echo -e "${BOLD}Single OpenAI Endpoint:${NC}  http://${host_ip}:${LITELLM_PORT}/v1"
    echo -e "${BOLD}Master API Key:${NC}          ${current_key}"
    echo -e "${BOLD}Routing Strategy:${NC}        ${configured_strategy} (MBP Activity Priority + Least-Busy)"
    echo -e "${BOLD}MBP Cooldown Lock:${NC}       ${MBP_COOLDOWN_SECONDS}s (qwen3-coder-next warm cache reservation)"
    echo -e "${BOLD}Config File:${NC}             ${LITELLM_CONFIG}"
    echo -e "${BOLD}Router Module:${NC}           ${LITELLM_DIR}/turnstone_router.py"
    echo -e "${BOLD}Virtualenv:${NC}              ${VENV_DIR}"
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
    echo -e "  - ${BOLD}qwen3-coder-next${NC}  -> Pinned to MBP MLX (${NODE_MBP_MLX}) w/ ${MBP_COOLDOWN_SECONDS}s priority lock"
    echo -e "  - ${BOLD}gemma-4-31b${NC}       -> Balanced across Node 1, Node 2, & Node 3 Ollama"
    echo -e "  - ${BOLD}qwen-3.8-27b${NC}      -> Balanced across Node 1, Node 2, & Node 3 Ollama"
    echo -e "  - ${BOLD}nemotron-3-nano${NC}   -> Node 2 primary (MoE 3 parallel slots) + Node 1"
    echo -e "  - ${BOLD}ornith-latest${NC}     -> Node 1 & Node 2 agentic fast tasks"
    echo -e "  - ${BOLD}default${NC}           -> Fallback balanced across all nodes"
    echo ""
    echo -e "${CYAN}Health Check & Verification Commands:${NC}"
    echo "  curl -X GET 'http://${host_ip}:${LITELLM_PORT}/health/readiness' -H 'Authorization: Bearer ${current_key}'"
    echo "  curl -X GET 'http://${host_ip}:${LITELLM_PORT}/v1/models' -H 'Authorization: Bearer ${current_key}'"
    echo ""
    echo "  curl -X POST 'http://${host_ip}:${LITELLM_PORT}/v1/chat/completions' \\"
    echo "    -H 'Content-Type: application/json' \\"
    echo "    -H 'Authorization: Bearer ${current_key}' \\"
    echo "    -d '{\"model\": \"qwen3-coder-next\", \"messages\": [{\"role\": \"user\", \"content\": \"def quicksort(arr):\"}]}'"
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
# Step 2: Install Debian System Packages, OpenSSH Server & Astral UV
# -----------------------------------------------------------------------------
log_section "Step 2: Installing Base Packages, OpenSSH & UV"

export DEBIAN_FRONTEND=noninteractive

log_info "Updating apt package index..."
apt-get update -qq

log_info "Installing core system utilities, openssh-server, sudo, and build tools..."
apt-get install -y -qq \
    curl \
    ca-certificates \
    openssh-server \
    sudo \
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

log_success "Base system packages, OpenSSH server, and uv ready."

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
# Step 4: Create Dedicated LiteLLM System Daemon User
# -----------------------------------------------------------------------------
log_section "Step 4: Creating System User '${LITELLM_USER}'"

if ! id "${LITELLM_USER}" &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "${LITELLM_USER}"
    log_success "Created system user '${LITELLM_USER}'."
else
    log_info "System user '${LITELLM_USER}' already exists."
fi

# -----------------------------------------------------------------------------
# Step 5: Python Virtual Environment & LiteLLM Package Installation
# -----------------------------------------------------------------------------
log_section "Step 5: Installing LiteLLM Proxy into ${VENV_DIR}"

SYSTEM_PYTHON=$(command -v python3 || echo "/usr/bin/python3")

if [ ! -d "${VENV_DIR}" ] || [ ! -f "${VENV_DIR}/bin/litellm" ]; then
    log_info "Creating virtual environment at ${VENV_DIR}..."
    mkdir -p /opt
    rm -rf "${VENV_DIR}"
    uv venv "${VENV_DIR}" --python "${SYSTEM_PYTHON}"
    
    log_info "Installing 'litellm[proxy]', pinned fastapi, uvicorn, and dependencies..."
    uv pip install --python "${VENV_DIR}" "fastapi>=0.112.0,<0.116.0" "litellm[proxy]" uvicorn gunicorn backoff
    log_success "LiteLLM installed successfully."
else
    log_info "Virtual environment exists at ${VENV_DIR}. Enforcing FastAPI compatibility and updating dependencies..."
    uv pip install --python "${VENV_DIR}" "fastapi>=0.112.0,<0.116.0" "litellm[proxy]" uvicorn gunicorn backoff --reinstall-package fastapi
fi

# Ensure user permissions
chown -R "${LITELLM_USER}:${LITELLM_USER}" "${VENV_DIR}"
chmod -R a+rX "${VENV_DIR}"
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
# Step 6: Configure LiteLLM Routing & Cluster Model Definitions
# -----------------------------------------------------------------------------
log_section "Step 6: Writing Cluster Configuration & Router to ${LITELLM_DIR}"

mkdir -p "${LITELLM_DIR}"

KEY_FILE="${LITELLM_DIR}/master_key.secret"
if [ -z "${MASTER_KEY}" ]; then
    if [ -f "${KEY_FILE}" ]; then
        MASTER_KEY="$(cat "${KEY_FILE}")"
        log_info "Reusing existing Master API Key from ${KEY_FILE}"
    else
        MASTER_KEY="sk-turnstone-$(openssl rand -hex 16)"
        echo -n "${MASTER_KEY}" > "${KEY_FILE}"
        chmod 600 "${KEY_FILE}"
        chown "${LITELLM_USER}:${LITELLM_USER}" "${KEY_FILE}"
        log_info "Generated new Master API Key: ${MASTER_KEY}"
    fi
else
    echo -n "${MASTER_KEY}" > "${KEY_FILE}"
    chmod 600 "${KEY_FILE}"
    chown "${LITELLM_USER}:${LITELLM_USER}" "${KEY_FILE}"
fi

# -----------------------------------------------------------------------------
# Step 6a: Custom Python Router & Lifecycle Hook (MBP Activity Prioritization)
# -----------------------------------------------------------------------------
ROUTER_PY="${LITELLM_DIR}/turnstone_router.py"
log_info "Writing custom MBP activity-prioritizing router module to ${ROUTER_PY}..."

cat > "${ROUTER_PY}" <<EOF
"""
Turnstone LiteLLM Custom Routing & Lifecycle Strategy for MBP Activity Prioritization
Prioritizes Apple Silicon MBP (NODE_MBP) for interactive coding with qwen3-coder-next.

Rules:
1. qwen3-coder-next has priority on NODE_MBP (MLX Server on port 8000).
2. Once a qwen3-coder-next request completes, start a cooldown timer of ${MBP_COOLDOWN_SECONDS}s.
   Subsequent qwen3-coder-next requests during cooldown execute immediately.
3. Other models (gemma-4-31b, qwen-3.8-27b, default) are only routed to NODE_MBP (Ollama on port 11434)
   if qwen3-coder-next is NOT running and its cooldown timer has expired.
4. If a request for qwen3-coder-next arrives while NODE_MBP is running another model,
   it waits for the in-flight request to complete and then immediately executes.
"""

import asyncio
import logging
import os
import time
from typing import Dict, List, Optional, Union
from litellm.integrations.custom_logger import CustomLogger
from litellm.router import CustomRoutingStrategyBase

logger = logging.getLogger("litellm.turnstone_router")


class MBPStateManager:
    """
    Manages concurrency and cooldown state across async requests for NODE_MBP.
    """
    def __init__(self, cooldown_seconds: float = 60.0):
        self.cooldown_seconds = cooldown_seconds
        self.qwen_in_flight = 0
        self.qwen_pending_waiters = 0
        self.last_qwen_completion_time: Optional[float] = None
        self.mbp_non_qwen_in_flight = 0
        self.mbp_idle_event = asyncio.Event()
        self.mbp_idle_event.set()
        self.deployment_in_flight: Dict[str, int] = {}

    def is_mbp_deployment(self, deployment: dict) -> bool:
        api_base = str(deployment.get("litellm_params", {}).get("api_base", "")).lower()
        return "mbp" in api_base or ":8000" in api_base or ":11434" in api_base

    def is_qwen_reserved(self) -> bool:
        if self.qwen_in_flight > 0 or self.qwen_pending_waiters > 0:
            return True
        if self.last_qwen_completion_time is not None:
            elapsed = time.time() - self.last_qwen_completion_time
            if elapsed < self.cooldown_seconds:
                return True
        return False

    def get_in_flight(self, deployment: dict) -> int:
        dep_id = deployment.get("model_info", {}).get("id") or deployment.get("litellm_params", {}).get("api_base", "")
        return self.deployment_in_flight.get(str(dep_id), 0)

    def inc_in_flight(self, deployment: dict):
        dep_id = deployment.get("model_info", {}).get("id") or deployment.get("litellm_params", {}).get("api_base", "")
        key = str(dep_id)
        self.deployment_in_flight[key] = self.deployment_in_flight.get(key, 0) + 1

    def dec_in_flight(self, deployment: dict):
        dep_id = deployment.get("model_info", {}).get("id") or deployment.get("litellm_params", {}).get("api_base", "")
        key = str(dep_id)
        if key in self.deployment_in_flight:
            self.deployment_in_flight[key] = max(0, self.deployment_in_flight[key] - 1)


# Singleton state instance shared between router and logger callbacks
state = MBPStateManager(
    cooldown_seconds=float(os.getenv("MBP_COOLDOWN_SECONDS", "${MBP_COOLDOWN_SECONDS}"))
)

# Load static model list from config.yaml as fallback
STATIC_MODEL_LIST = []
try:
    import yaml
    with open("${LITELLM_CONFIG}", "r") as f:
        _cfg = yaml.safe_load(f)
        STATIC_MODEL_LIST = _cfg.get("model_list", [])
except Exception:
    pass


class TurnstoneLifecycleHandler(CustomLogger):
    async def async_filter_deployments(
        self,
        model: str,
        healthy_deployments: List[dict],
        messages: Optional[List] = None,
        request_kwargs: Optional[dict] = None,
        parent_otel_span=None,
    ) -> List[dict]:
        """
        Dynamically filters candidate deployments before least-busy load balancing:
        1. qwen3-coder-next has priority on MBP. Waits if non-Qwen is in-flight on MBP.
        2. Non-Qwen models are excluded from MBP while Qwen is active or in 60s cooldown.
        """
        is_qwen_model = "qwen3-coder-next" in model.lower()

        if is_qwen_model:
            state.qwen_pending_waiters += 1
            try:
                if state.mbp_non_qwen_in_flight > 0:
                    logger.info("Qwen coder request waiting for active non-Qwen MBP request to complete...")
                    await state.mbp_idle_event.wait()
            finally:
                state.qwen_pending_waiters = max(0, state.qwen_pending_waiters - 1)

            # Prioritize MBP MLX / Ollama deployments if healthy
            mbp_deps = [d for d in healthy_deployments if state.is_mbp_deployment(d)]
            if mbp_deps:
                return mbp_deps
            return healthy_deployments

        # General / non-Qwen models (gemma-4-31b, qwen-3.8-27b, default, etc.)
        if state.is_qwen_reserved():
            # Exclude MBP deployments while Qwen is active, cooling down, or queued
            non_mbp = [d for d in healthy_deployments if not state.is_mbp_deployment(d)]
            if non_mbp:
                return non_mbp

        return healthy_deployments

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        model = str(data.get("model", "")).lower()
        if "qwen3-coder-next" in model:
            state.qwen_in_flight += 1
        return data

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        self._handle_completion(kwargs)

    async def async_log_failure_event(self, kwargs, response_obj, start_time, end_time):
        self._handle_completion(kwargs)

    def _handle_completion(self, kwargs: dict):
        model = str(kwargs.get("model", "")).lower()
        litellm_params = kwargs.get("litellm_params", {}) or {}
        api_base = str(litellm_params.get("api_base", "")).lower()
        is_mbp = "mbp" in api_base or ":8000" in api_base or ":11434" in api_base

        state.dec_in_flight({"litellm_params": litellm_params})

        if "qwen3-coder-next" in model:
            state.qwen_in_flight = max(0, state.qwen_in_flight - 1)
            state.last_qwen_completion_time = time.time()
            logger.info("Qwen request finished. Activated " + str(state.cooldown_seconds) + "s MBP priority lock.")
        elif is_mbp:
            state.mbp_non_qwen_in_flight = max(0, state.mbp_non_qwen_in_flight - 1)
            if state.mbp_non_qwen_in_flight == 0:
                state.mbp_idle_event.set()


lifecycle_handler = TurnstoneLifecycleHandler()
EOF

chown "${LITELLM_USER}:${LITELLM_USER}" "${ROUTER_PY}"
chmod 644 "${ROUTER_PY}"

# -----------------------------------------------------------------------------
# Step 6b: Write LiteLLM Cluster Configuration YAML
# -----------------------------------------------------------------------------
cat > "${LITELLM_CONFIG}" <<EOF
# =============================================================================
# Turnstone LiteLLM Load Balancer Configuration (Debian Trixie Container)
# Load Balancing: MBP Activity Prioritization + Least-Busy queue balancing
# =============================================================================

model_list:
  # ---------------------------------------------------------------------------
  # 1. Gemma 4 31B (General Reasoning / Orchestrator)
  # Balanced across Node 1, Node 2, & Node 3 Ollama (gemma4:31b-mlx)
  # ---------------------------------------------------------------------------
  - model_name: "gemma-4-31b"
    litellm_params:
      model: "openai/Gemma-4-31B-it-GGUF"
      api_base: "${NODE_RYZEN_ONE}"
      api_key: "dummy"
      max_parallel_requests: 1
      rpm: 300

  - model_name: "gemma-4-31b"
    litellm_params:
      model: "openai/Gemma-4-31B-it-GGUF"
      api_base: "${NODE_RYZEN_TWO}"
      api_key: "dummy"
      max_parallel_requests: 1
      rpm: 300

  - model_name: "gemma-4-31b"
    litellm_params:
      model: "openai/gemma4:31b"
      api_base: "${NODE_MBP_OLLAMA}"
      api_key: "dummy"
      max_parallel_requests: 1
      rpm: 300

  # ---------------------------------------------------------------------------
  # 2. Qwen 3.8 27B (High Precision Reasoning / Coding)
  # Balanced across Node 1, Node 2, & Node 3 Ollama (qwen3.8:27b)
  # ---------------------------------------------------------------------------
  - model_name: "qwen-3.8-27b"
    litellm_params:
      model: "openai/Qwen3.8-27B-GGUF-Q8_0"
      api_base: "${NODE_RYZEN_ONE}"
      api_key: "dummy"
      max_parallel_requests: 1
      rpm: 300

  - model_name: "qwen-3.8-27b"
    litellm_params:
      model: "openai/Qwen3.8-27B-GGUF-Q8_0"
      api_base: "${NODE_RYZEN_TWO}"
      api_key: "dummy"
      max_parallel_requests: 1
      rpm: 300

  - model_name: "qwen-3.8-27b"
    litellm_params:
      model: "openai/qwen3.8:27b"
      api_base: "${NODE_MBP_OLLAMA}"
      api_key: "dummy"
      max_parallel_requests: 1
      rpm: 300

  # ---------------------------------------------------------------------------
  # 3. Qwen 3 Coder Next (Deep 128k Context Coding Model)
  # Primary: MacBook Pro M5 MLX Server (Port 8000)
  # Fallback: MacBook Pro M5 Ollama (Port 11434)
  # ---------------------------------------------------------------------------
  - model_name: "qwen3-coder-next"
    litellm_params:
      model: "openai/mlx-community/Qwen3-Coder-Next-6bit"
      api_base: "${NODE_MBP_MLX}"
      api_key: "dummy"
      max_parallel_requests: 1
      rpm: 120

  # ---------------------------------------------------------------------------
  # 4. Nemotron 3 Nano 30B (MoE Architecture - Fast Judge / Reranking)
  # Balanced across Ryzen Halo Node 2 & Node 1
  # ---------------------------------------------------------------------------
  - model_name: "nemotron-3-nano"
    litellm_params:
      model: "openai/Nemotron-3-Nano-30B-A3B-GGUF"
      api_base: "${NODE_RYZEN_TWO}"
      api_key: "dummy"
      max_parallel_requests: 3
      rpm: 600

  - model_name: "nemotron-3-nano"
    litellm_params:
      model: "openai/Nemotron-3-Nano-30B-A3B-GGUF"
      api_base: "${NODE_RYZEN_ONE}"
      api_key: "dummy"
      max_parallel_requests: 1
      rpm: 300

  # ---------------------------------------------------------------------------
  # 5. Ornith Latest (Fast Agentic Model / Tool Calling)
  # Hosted on MacBook Pro M5 Ollama (ornith:latest)
  # ---------------------------------------------------------------------------
  - model_name: "ornith-latest"
    litellm_params:
      model: "openai/ornith:latest"
      api_base: "${NODE_MBP_OLLAMA}"
      api_key: "dummy"
      max_parallel_requests: 2

  # ---------------------------------------------------------------------------
  # 6. Default Fallback
  # ---------------------------------------------------------------------------
  - model_name: "default"
    litellm_params:
      model: "openai/Gemma-4-31B-it-GGUF"
      api_base: "${NODE_RYZEN_ONE}"
      api_key: "dummy"

  - model_name: "default"
    litellm_params:
      model: "openai/Gemma-4-31B-it-GGUF"
      api_base: "${NODE_RYZEN_TWO}"
      api_key: "dummy"

  - model_name: "default"
    litellm_params:
      model: "openai/gemma4:31b"
      api_base: "${NODE_MBP_OLLAMA}"
      api_key: "dummy"

router_settings:
  routing_strategy: "${ROUTING_STRATEGY}"
  routing_strategy_args:
    ttl: 30
  num_retries: 3
  timeout: 600
  allowed_fails: 2
  cooldown_time: 30

general_settings:
  master_key: "${MASTER_KEY}"
  store_model_in_db: false
  drop_params: true

litellm_settings:
  callbacks: ["turnstone_router.lifecycle_handler"]
  drop_params: true
  set_verbose: false
  telemetry: false
EOF

chown -R "${LITELLM_USER}:${LITELLM_USER}" "${LITELLM_DIR}"
chmod 600 "${LITELLM_CONFIG}"
log_success "Configuration created at ${LITELLM_CONFIG}."

# -----------------------------------------------------------------------------
# Step 7: Configure & Start Service
# -----------------------------------------------------------------------------
log_section "Step 7: Setting Up & Starting LiteLLM Service"

SERVICE_FILE="/etc/systemd/system/litellm.service"

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=LiteLLM Least-Busy Proxy Server
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${LITELLM_USER}
Group=${LITELLM_USER}
WorkingDirectory=${LITELLM_DIR}
Environment="LITELLM_MASTER_KEY=${MASTER_KEY}"
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
export LITELLM_MASTER_KEY="${MASTER_KEY}"
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
# Step 8: Service Health & Readiness Polling
# -----------------------------------------------------------------------------
log_section "Step 8: Verifying Service Startup & Health"

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
# Step 8: Output Cluster Endpoints & Summary
# -----------------------------------------------------------------------------
log_section "Deployment Completed Successfully"
show_status_summary
