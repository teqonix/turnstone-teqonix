#!/usr/bin/env bash
# =============================================================================
# LiteLLM Proxy Deployment Script (Dedicated Load Balancer VM)
#
# Idempotent deployment of LiteLLM Proxy configured for least-busy
# load balancing across Ryzen AI Halo nodes and Apple Silicon MLX nodes.
# =============================================================================

set -euo pipefail

# Color Codes for Output Formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

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

# Node Endpoints (Defaults match Turnstone cluster hostnames & ports)
NODE_RYZEN_ONE="${NODE_RYZEN_ONE:-http://amd-ai-core-one.lan:8000/v1}"
NODE_RYZEN_TWO="${NODE_RYZEN_TWO:-http://amd-ai-core-two.lan:8000/v1}"
NODE_MBP="${NODE_MBP:-http://mbp-ai-core.lan:8000/v1}"

MASTER_KEY="${LITELLM_MASTER_KEY:-${MASTER_KEY:-}}"
MAX_PARALLEL_PER_NODE="${MAX_PARALLEL_PER_NODE:-3}" # 128GB unified RAM supports ~3 concurrent 30B models per node
ROUTING_STRATEGY="${ROUTING_STRATEGY:-least-busy}"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -p, --port <port>              LiteLLM Proxy listening port (default: 4000)"
    echo "  -k, --master-key <key>         LiteLLM Master API Key (auto-generated if empty)"
    echo "  --node-ryzen-1 <url>           URL for Ryzen AI Halo Node 1 (default: http://amd-ai-core-one.lan:8000/v1)"
    echo "  --node-ryzen-2 <url>           URL for Ryzen AI Halo Node 2 (default: http://amd-ai-core-two.lan:8000/v1)"
    echo "  --node-mbp <url>               URL for M5 Max MacBook Pro Node (default: http://mbp-ai-core.lan:8000/v1)"
    echo "  --max-parallel <num>           Max parallel requests per model per node (default: 3)"
    echo "  --strategy <strategy>          Routing strategy (default: least-busy, lowest-latency, etc.)"
    echo "  --restart                      Force restart the LiteLLM service"
    echo "  -h, --help                     Display this help message and exit"
    echo ""
    echo "Environment Variables Respected:"
    echo "  LITELLM_PORT, LITELLM_MASTER_KEY, NODE_RYZEN_ONE, NODE_RYZEN_TWO, NODE_MBP, ROUTING_STRATEGY"
    exit 0
}

FORCE_RESTART=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--port)
            LITELLM_PORT="$2"
            shift 2
            ;;
        -k|--master-key)
            MASTER_KEY="$2"
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
        --node-mbp)
            NODE_MBP="$2"
            shift 2
            ;;
        --max-parallel)
            MAX_PARALLEL_PER_NODE="$2"
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

log_section "Turnstone LiteLLM Least-Busy Proxy Setup"

# -----------------------------------------------------------------------------
# Step 1: Root / Sudo Check
# -----------------------------------------------------------------------------
log_info "Step 1: Verifying root permissions..."
if [ "$EUID" -ne 0 ]; then
    log_warn "This script requires root privileges to install packages and systemd services. Re-executing with sudo..."
    exec sudo bash "$0" "$@"
fi
log_success "Root permissions confirmed."

# -----------------------------------------------------------------------------
# Step 2: Ensure System Dependencies & Python UV
# -----------------------------------------------------------------------------
log_section "Step 2: Installing Dependencies & UV Package Manager"

if command -v apt-get &>/dev/null; then
    log_info "Updating apt cache and installing essential packages..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl ca-certificates python3 python3-venv python3-pip jq openssl
elif command -v dnf &>/dev/null; then
    dnf install -y -q curl ca-certificates python3 python3-pip jq openssl
elif command -v pacman &>/dev/null; then
    pacman -Sy --noconfirm curl ca-certificates python python-pip jq openssl
fi

if ! command -v uv &>/dev/null; then
    log_info "Installing Astral uv package manager..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi
log_success "Dependencies and uv are ready."

# -----------------------------------------------------------------------------
# Step 3: Create Dedicated System User
# -----------------------------------------------------------------------------
log_section "Step 3: Creating System User '${LITELLM_USER}'"

if ! id "${LITELLM_USER}" &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "${LITELLM_USER}"
    log_success "Created system user '${LITELLM_USER}'."
else
    log_info "System user '${LITELLM_USER}' already exists."
fi

# -----------------------------------------------------------------------------
# Step 4: Setup Virtual Environment & Install LiteLLM Proxy
# -----------------------------------------------------------------------------
log_section "Step 4: Setting up Python Virtual Environment"

SYSTEM_PYTHON=$(command -v python3 || echo "/usr/bin/python3")

if [ ! -d "${VENV_DIR}" ] || [ ! -f "${VENV_DIR}/bin/litellm" ]; then
    log_info "Creating virtual environment at ${VENV_DIR}..."
    mkdir -p /opt
    rm -rf "${VENV_DIR}"
    uv venv "${VENV_DIR}" --python "${SYSTEM_PYTHON}"
    
    log_info "Installing 'litellm[proxy]', pinned fastapi, and async server dependencies..."
    uv pip install --python "${VENV_DIR}" "fastapi>=0.112.0,<0.116.0" "litellm[proxy]" uvicorn gunicorn backoff
    log_success "LiteLLM Proxy installed into ${VENV_DIR}."
else
    log_info "Virtual environment already exists at ${VENV_DIR}."
    # Ensure package and FastAPI compatibility are up to date
    uv pip install --python "${VENV_DIR}" "fastapi>=0.112.0,<0.116.0" --upgrade >/dev/null 2>&1 || true
    uv pip install --python "${VENV_DIR}" --upgrade "litellm[proxy]" >/dev/null 2>&1 || true
fi

# Fix virtualenv permissions
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
# Step 5: Configure LiteLLM Routing & Model Groups
# -----------------------------------------------------------------------------
log_section "Step 5: Writing Configuration to ${LITELLM_CONFIG}"

mkdir -p "${LITELLM_DIR}"

# Generate master key if not provided or present
KEY_FILE="${LITELLM_DIR}/master_key.secret"
if [ -z "${MASTER_KEY}" ]; then
    if [ -f "${KEY_FILE}" ]; then
        MASTER_KEY="$(cat "${KEY_FILE}")"
        log_info "Using existing Master API Key from ${KEY_FILE}"
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

cat > "${LITELLM_CONFIG}" <<EOF
# =============================================================================
# LiteLLM Proxy Configuration
# Load Balancing: Least-Busy across Ryzen AI Halo and Apple Silicon MLX nodes
# =============================================================================

model_list:
  # ---------------------------------------------------------------------------
  # General Purpose / Coding Model (Qwen 2.5 Coder 32B)
  # Distributed across all 3 nodes (2x Ryzen Halo + 1x Apple Silicon M5 Max)
  # ---------------------------------------------------------------------------
  - model_name: "qwen2.5-coder-32b"
    litellm_params:
      model: "openai/mlx-community/Qwen2.5-Coder-32B-Instruct-4bit"
      api_base: "${NODE_MBP}"
      api_key: "dummy"
      max_parallel_requests: ${MAX_PARALLEL_PER_NODE}
      rpm: 600

  - model_name: "qwen2.5-coder-32b"
    litellm_params:
      model: "openai/Qwen/Qwen2.5-Coder-32B-Instruct"
      api_base: "${NODE_RYZEN_ONE}"
      api_key: "dummy"
      max_parallel_requests: ${MAX_PARALLEL_PER_NODE}
      rpm: 600

  - model_name: "qwen2.5-coder-32b"
    litellm_params:
      model: "openai/Qwen/Qwen2.5-Coder-32B-Instruct"
      api_base: "${NODE_RYZEN_TWO}"
      api_key: "dummy"
      max_parallel_requests: ${MAX_PARALLEL_PER_NODE}
      rpm: 600

  # ---------------------------------------------------------------------------
  # Large Memory Heavyweight Model (qwen3-coder-next)
  # Routed to M5 Max MBP (or any node capable of hosting heavy KV cache)
  # ---------------------------------------------------------------------------
  - model_name: "qwen3-coder-next"
    litellm_params:
      model: "openai/qwen3-coder-next"
      api_base: "${NODE_MBP}"
      api_key: "dummy"
      max_parallel_requests: 1 # Concurrency 1 for heavy memory models
      rpm: 120

  - model_name: "qwen3-coder-next"
    litellm_params:
      model: "openai/qwen3-coder-next"
      api_base: "${NODE_RYZEN_ONE}"
      api_key: "dummy"
      max_parallel_requests: 1
      rpm: 120

  # ---------------------------------------------------------------------------
  # Gemma 4 31B / Orchestrator Model
  # ---------------------------------------------------------------------------
  - model_name: "gemma-4-31b"
    litellm_params:
      model: "openai/google/gemma-4-31b-it"
      api_base: "${NODE_RYZEN_ONE}"
      api_key: "dummy"
      max_parallel_requests: ${MAX_PARALLEL_PER_NODE}

  - model_name: "gemma-4-31b"
    litellm_params:
      model: "openai/google/gemma-4-31b-it"
      api_base: "${NODE_RYZEN_TWO}"
      api_key: "dummy"
      max_parallel_requests: ${MAX_PARALLEL_PER_NODE}

  - model_name: "gemma-4-31b"
    litellm_params:
      model: "openai/mlx-community/gemma-4-31b-it-4bit"
      api_base: "${NODE_MBP}"
      api_key: "dummy"
      max_parallel_requests: ${MAX_PARALLEL_PER_NODE}

  # ---------------------------------------------------------------------------
  # Nemotron 3 Nano / Judge Model
  # ---------------------------------------------------------------------------
  - model_name: "nemotron-3-nano"
    litellm_params:
      model: "openai/nvidia/nemotron-3-nano"
      api_base: "${NODE_RYZEN_TWO}"
      api_key: "dummy"
      max_parallel_requests: ${MAX_PARALLEL_PER_NODE}

  - model_name: "nemotron-3-nano"
    litellm_params:
      model: "openai/nvidia/nemotron-3-nano"
      api_base: "${NODE_RYZEN_ONE}"
      api_key: "dummy"
      max_parallel_requests: ${MAX_PARALLEL_PER_NODE}

  # ---------------------------------------------------------------------------
  # Wildcard / Default Pass-Through Group
  # ---------------------------------------------------------------------------
  - model_name: "default"
    litellm_params:
      model: "openai/default"
      api_base: "${NODE_MBP}"
      api_key: "dummy"

  - model_name: "default"
    litellm_params:
      model: "openai/default"
      api_base: "${NODE_RYZEN_ONE}"
      api_key: "dummy"

  - model_name: "default"
    litellm_params:
      model: "openai/default"
      api_base: "${NODE_RYZEN_TWO}"
      api_key: "dummy"

router_settings:
  routing_strategy: "${ROUTING_STRATEGY}"  # 'least-busy' routes to deployment with lowest active in-flight requests
  routing_strategy_args:
    ttl: 30
  num_retries: 3
  timeout: 600
  allowed_fails: 2
  cooldown_time: 30

general_settings:
  master_key: "${MASTER_KEY}"
  store_model_in_db: false
  alerting: []
  drop_params: true

litellm_settings:
  drop_params: true
  set_verbose: false
  telemetry: false
EOF

chown -R "${LITELLM_USER}:${LITELLM_USER}" "${LITELLM_DIR}"
chmod 600 "${LITELLM_CONFIG}"
log_success "Configuration created with '${ROUTING_STRATEGY}' routing strategy."

# -----------------------------------------------------------------------------
# Step 6: Install Systemd Service Unit
# -----------------------------------------------------------------------------
log_section "Step 6: Configuring Systemd Service Unit"

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
Environment="PATH=${VENV_DIR}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=${VENV_DIR}/bin/python3 -m litellm.proxy.proxy_cli --config ${LITELLM_CONFIG} --host ${LITELLM_HOST} --port ${LITELLM_PORT}
Restart=always
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable litellm.service

if [ "${FORCE_RESTART}" = true ] || ! systemctl is-active --quiet litellm.service; then
    log_info "Starting litellm.service..."
    systemctl restart litellm.service
else
    log_info "Reloading / restarting litellm.service with updated configuration..."
    systemctl restart litellm.service
fi

# -----------------------------------------------------------------------------
# Step 7: Service Health Verification
# -----------------------------------------------------------------------------
log_section "Step 7: Verification & Health Check"

log_info "Waiting for LiteLLM to become healthy on port ${LITELLM_PORT}..."
SERVICE_HEALTHY=false
for i in $(seq 1 15); do
    if ! systemctl is-active --quiet litellm.service; then
        log_warn "litellm.service is not active yet (attempt ${i}/15)..."
        sleep 1
        continue
    fi

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://127.0.0.1:${LITELLM_PORT}/health/readiness" -H "Authorization: Bearer ${MASTER_KEY}" || true)
    if [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "401" ] || [ "${HTTP_CODE}" = "403" ]; then
        SERVICE_HEALTHY=true
        log_success "LiteLLM Proxy is responsive (HTTP ${HTTP_CODE})!"
        break
    fi
    sleep 1
done

if [ "${SERVICE_HEALTHY}" = true ]; then
    log_success "LiteLLM Proxy is running successfully on port ${LITELLM_PORT}!"
else
    log_error "LiteLLM Proxy failed to become ready within 15 seconds."
    echo -e "\n${YELLOW}--- Systemd Service Status ---${NC}"
    systemctl status litellm.service --no-pager || true
    echo -e "\n${YELLOW}--- Recent Journal Logs (litellm.service) ---${NC}"
    journalctl -u litellm.service -n 35 --no-pager || true
    exit 1
fi

echo -e "\n${GREEN}=================================================================${NC}"
echo -e "${GREEN}       LiteLLM Proxy Deployment Completed Successfully!          ${NC}"
echo -e "${GREEN}=================================================================${NC}"
echo -e "${BOLD}Proxy Endpoint:${NC}      http://${HOST_IP}:${LITELLM_PORT}/v1"
echo -e "${BOLD}Routing Strategy:${NC}    ${ROUTING_STRATEGY} (Active In-Flight Request Balancing)"
echo -e "${BOLD}Master API Key:${NC}      ${MASTER_KEY}"
echo -e "${BOLD}Key File Location:${NC}   ${KEY_FILE}"
echo -e "${BOLD}Config File:${NC}         ${LITELLM_CONFIG}"
echo -e "${BOLD}Systemd Service:${NC}     litellm.service"
echo ""
echo -e "${CYAN}Connected LLM Backend Nodes:${NC}"
echo -e "  - Node 1 (M5 Max MBP):   ${NODE_MBP}"
echo -e "  - Node 2 (Ryzen Halo 1): ${NODE_RYZEN_ONE}"
echo -e "  - Node 3 (Ryzen Halo 2): ${NODE_RYZEN_TWO}"
echo ""
echo -e "${CYAN}Quick Health & Test Commands:${NC}"
echo "  curl -X GET 'http://localhost:${LITELLM_PORT}/health' -H 'Authorization: Bearer ${MASTER_KEY}'"
echo "  curl -X GET 'http://localhost:${LITELLM_PORT}/v1/models' -H 'Authorization: Bearer ${MASTER_KEY}'"
echo ""
echo "  curl -X POST 'http://localhost:${LITELLM_PORT}/v1/chat/completions' \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -H 'Authorization: Bearer ${MASTER_KEY}' \\"
echo "    -d '{\"model\": \"qwen2.5-coder-32b\", \"messages\": [{\"role\": \"user\", \"content\": \"ping\"}]}'"
echo "================================================================="
