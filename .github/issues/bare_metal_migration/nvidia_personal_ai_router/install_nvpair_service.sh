#!/usr/bin/env bash
# =============================================================================
# NVIDIA Personal AI Router (PAIR) Tmux Daemon Service Installer
#
# Configures and enables nvpair.service to run nvpair-tui in a persistent
# background tmux session under a dedicated service user (teqonix).
# =============================================================================

set -euo pipefail

# Output Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

trap 'log_error "An error occurred on line $LINENO. Installation stopped."; exit 1' ERR

# Determine directory locations
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." 2>/dev/null && pwd || pwd)"

SERVICE_USER="${SERVICE_USER:-teqonix}"
SERVICE_DEST="${SERVICE_DEST:-/etc/systemd/system/nvpair.service}"
TMUX_SESSION="${TMUX_SESSION:-pair}"
TMUX_CMD="${TMUX_CMD:-nvpair-tui}"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Installs and enables nvpair.service (running nvpair-tui inside a tmux session).

Options:
  --user <username>       User account to run the service under [default: teqonix]
  --session <name>        tmux session identifier [default: pair]
  --dest <path>           Destination path for systemd service [default: /etc/systemd/system/nvpair.service]
  -h, --help              Show this help message
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            SERVICE_USER="$2"
            shift 2
            ;;
        --session)
            TMUX_SESSION="$2"
            shift 2
            ;;
        --dest)
            SERVICE_DEST="$2"
            shift 2
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

# Step 1: Root Privileges Check
if [ "$EUID" -ne 0 ]; then
    log_warn "Root privileges required. Re-executing with sudo..."
    exec sudo bash "$0" "$@"
fi

log_info "Configuring nvpair tmux service (User: ${SERVICE_USER}, Session: ${TMUX_SESSION})..."

# Step 2: Ensure Service User Exists
if ! id -u "${SERVICE_USER}" &>/dev/null; then
    log_info "Creating service user '${SERVICE_USER}'..."
    useradd -m -s /bin/bash "${SERVICE_USER}" || true
fi

# Ensure service user has hardware GPU device permissions (render, video)
usermod -aG render,video "${SERVICE_USER}" 2>/dev/null || true
if getent group docker &>/dev/null; then
    usermod -aG docker "${SERVICE_USER}" 2>/dev/null || true
fi

# Step 3: Ensure tmux is Installed
if ! command -v tmux &>/dev/null; then
    log_info "Installing tmux..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tmux
fi

# Step 4: Locate or Fetch nvpair.service Unit File at Runtime
SERVICE_SRC=""
CANDIDATE_SERVICES=(
    "${SCRIPT_DIR}/nvpair.service"
    "${SCRIPT_DIR}/../ryzen_node_custom/nvpair.service"
    "${REPO_ROOT}/.github/issues/bare_metal_migration/nvidia_personal_ai_router/nvpair.service"
    "${REPO_ROOT}/.github/issues/bare_metal_migration/ryzen_node_custom/nvpair.service"
)

for cand_svc in "${CANDIDATE_SERVICES[@]}"; do
    if [ -f "${cand_svc}" ]; then
        SERVICE_SRC="${cand_svc}"
        break
    fi
done

if [ -n "${SERVICE_SRC}" ]; then
    log_info "Found local service unit at ${SERVICE_SRC}."
    cp -f "${SERVICE_SRC}" "${SERVICE_DEST}"
else
    log_info "Fetching nvpair.service from remote repository..."
    REMOTE_URLS=(
        "https://raw.githubusercontent.com/teqonix/turnstone-teqonix/main/.github/issues/bare_metal_migration/nvidia_personal_ai_router/nvpair.service"
        "https://raw.githubusercontent.com/teqonix/turnstone-teqonix/main/.github/issues/bare_metal_migration/ryzen_node_custom/nvpair.service"
    )
    DOWNLOADED=false
    for r_url in "${REMOTE_URLS[@]}"; do
        if curl -sSfL "${r_url}" -o "${SERVICE_DEST}" 2>/dev/null; then
            DOWNLOADED=true
            log_success "Downloaded service unit from: ${r_url}"
            break
        fi
    done

    if [ "${DOWNLOADED}" != true ]; then
        log_error "Failed to locate nvpair.service locally or fetch from remote repository."
        exit 1
    fi
fi

# Step 4b: Inject SERVICE_USER and USER_HOME into installed unit
USER_HOME="$(getent passwd "${SERVICE_USER}" 2>/dev/null | cut -d: -f6 || true)"
if [ -z "${USER_HOME}" ]; then
    USER_HOME="/home/${SERVICE_USER}"
fi

log_info "Injecting service user '${SERVICE_USER}' (home: ${USER_HOME}) into ${SERVICE_DEST}..."
sed -i \
    -e "s|\${SERVICE_USER}|${SERVICE_USER}|g" \
    -e "s|^User=.*|User=${SERVICE_USER}|g" \
    -e "s|^Group=.*|Group=${SERVICE_USER}|g" \
    -e "s|^WorkingDirectory=.*|WorkingDirectory=${USER_HOME}|g" \
    -e "s|^Environment=\"HOME=.*|Environment=\"HOME=${USER_HOME}\"|g" \
    "${SERVICE_DEST}"

chmod 644 "${SERVICE_DEST}"

# Step 5: Start / Restart nvpair Service
if pidof systemd &>/dev/null || [ -d /run/systemd/system ]; then
    log_info "Reloading systemd daemon and enabling nvpair.service..."
    systemctl daemon-reload
    systemctl enable nvpair.service
    if systemctl restart nvpair.service 2>/dev/null; then
        log_success "nvpair.service successfully restarted."
    else
        log_warn "Failed to restart nvpair.service immediately (may require login/reboot)."
    fi
else
    log_warn "Systemd not active in container/host. Starting ${TMUX_CMD} in detached tmux session..."
    sudo -u "${SERVICE_USER}" tmux new-session -d -s "${TMUX_SESSION}" "${TMUX_CMD}" 2>/dev/null || true
fi

log_success "nvpair tmux service setup complete."
