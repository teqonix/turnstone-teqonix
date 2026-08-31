#!/usr/bin/env bash
# =============================================================================
# Turnstone Node Deployment (Debian 12 - Container)
#
# Installs a full Turnstone node on a fresh or existing Debian 12 container.
# This is the dedicated node that:
#   * registers with the TrueNAS Coordinator VM,
#   * proxies LLM inference to the hardware nodes (Ryzen / MLX) via the
#     OpenAI-compatible endpoints they expose,
#   * connects to the shared PostgreSQL backend,
#   * uses host-mounted storage at /workspace (from TrueNAS host),
#   * provides OpenSSH server configured for remote root login,
#   * provides Homebrew, Podman, and Podman Compose container tooling.
#
# Container-friendly notes:
#   * No systemd is required (containers typically have no PID-1 init). The
#     turnstone-server process is started as a foreground process via an
#     entrypoint wrapper and, when systemd IS present, a unit is also installed.
#   * OpenSSH daemon is started both via init system and container entrypoint.
#   * Idempotent and safe to re-run: `set -euo pipefail`.
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
DEFAULT_SECRET_FILE="${SCRIPT_DIR}/secrets/turnstone_np_postgres.secret"
[ -f "${DEFAULT_SECRET_FILE}" ] || DEFAULT_SECRET_FILE="${SCRIPT_DIR}/secrets/turnstone_np.secret"

SECRET_FILE="${SECRET_FILE:-}"
POSTGRES_USER="${POSTGRES_USER:-}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
POSTGRES_HOST="${POSTGRES_HOST:-}"
POSTGRES_PORT="${POSTGRES_PORT:-}"
POSTGRES_DB="${POSTGRES_DB:-}"
NODE_ID="${NODE_ID:-}"
COORDINATOR_IP="${COORDINATOR_IP:-turnstone-coordinator-nerd-projects.lan}"
JWT_SECRET="${JWT_SECRET:-}"
# OpenAI-compatible LLM endpoint(s) served by the hardware inference nodes.
LLM_BASE_URL="${LLM_BASE_URL:-http://127.0.0.1:8000/v1}"
TURNSTONE_USER="${TURNSTONE_USER:-turnstone}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
DATA_DIR="${DATA_DIR:-/data}"
NFS_SERVER="${NFS_SERVER:-silo-14.lan}"
NFS_SHARE="${NFS_SHARE:-/mnt/silo-14/ai-playground}"
SKIP_NFS="${SKIP_NFS:-false}"

# Skip the optional hardware-monitor / Rust tooling to keep the container lean.
SKIP_TOOLS="${SKIP_TOOLS:-false}"
# Run the server in the foreground at the end of the script (container mode).
RUN_FOREGROUND="${RUN_FOREGROUND:-true}"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Installs a Turnstone node on a fresh or existing Debian 12 container."
    echo ""
    echo "Options:"
    echo "  -u, --user, --postgres-user <user> PostgreSQL username (e.g. turnstone-np, postgres)"
    echo "  -s, --secret-file <path>           Path to secret file containing DB connection string or env vars"
    echo "  -n, --node-id, --node_id <id>      Node ID (e.g. turnstone-worker-one, turnstone-worker-two)"
    echo "  -c, --coordinator <ip>             Coordinator VM IP address or hostname"
    echo "      --llm-url <url>                OpenAI-compatible LLM endpoint [default: ${LLM_BASE_URL}]"
    echo "      --turnstone-user <user>        Local system user [default: turnstone]"
    echo "      --workspace-dir <path>         Workspace storage directory [default: /workspace]"
    echo "      --nfs-server <host>            NFS server hostname [default: ${NFS_SERVER}]"
    echo "      --nfs-share <path>             NFS share export path [default: ${NFS_SHARE}]"
    echo "      --skip-nfs                     Skip NFS utilities and share mounting"
    echo "      --skip-tools                   Skip optional extra tooling (all-smi, Rust/Cargo, Jujutsu)"
    echo "      --no-foreground                Do not exec the server in the foreground at the end"
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
        -n|--node-id|--node_id)
            NODE_ID="$2"
            shift 2
            ;;
        -c|--coordinator)
            COORDINATOR_IP="$2"
            shift 2
            ;;
        --llm-url)
            LLM_BASE_URL="$2"
            shift 2
            ;;
        --turnstone-user)
            TURNSTONE_USER="$2"
            shift 2
            ;;
        --workspace-dir)
            WORKSPACE_DIR="$2"
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
        --skip-nfs)
            SKIP_NFS="true"
            shift
            ;;
        --skip-tools)
            SKIP_TOOLS="true"
            shift
            ;;
        --no-foreground)
            RUN_FOREGROUND="false"
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
    local calling_user="${SUDO_USER:-$(whoami)}"
    local calling_user_home
    calling_user_home="$(getent passwd "${calling_user}" 2>/dev/null | cut -d: -f6 || echo "${HOME}")"

    local search_dirs=(
        "${SCRIPT_DIR}/secrets"
        "${REPO_ROOT}/secrets"
        "${REPO_ROOT}/.github/issues/bare_metal_migration/secrets"
        "${SCRIPT_DIR}"
        "${calling_user_home}/nerd_projects/turnstone-teqonix/.github/issues/bare_metal_migration/secrets"
        "${calling_user_home}/nerd_projects/turnstone-teqonix/secrets"
        "${HOME}/nerd_projects/turnstone-teqonix/.github/issues/bare_metal_migration/secrets"
        "${HOME}/nerd_projects/turnstone-teqonix/secrets"
        "/etc/turnstone"
    )

    # 1. PostgreSQL Secret Discovery & Parsing
    if [ -z "${POSTGRES_PASSWORD:-}" ]; then
        local pg_candidates=(
            "turnstone_np_postgres.secret"
            "turnstone_postgres.secret"
            "postgres_turnstone_np.secret"
            "turnstone_np.secret"
            "turnstone.secret"
            "postgres_admin.secret"
            "postgres.secret"
        )
        if [ -n "${POSTGRES_USER:-}" ]; then
            local sanitized_user
            sanitized_user=$(echo "${POSTGRES_USER}" | tr '-' '_')
            pg_candidates=("postgres_${sanitized_user}.secret" "postgres_${POSTGRES_USER}.secret" "${POSTGRES_USER}.secret" "${pg_candidates[@]}")
        fi

        local matched_pg=""
        if [ -n "${SECRET_FILE:-}" ] && [ -s "${SECRET_FILE}" ]; then
            matched_pg="${SECRET_FILE}"
        fi

        if [ -z "${matched_pg}" ]; then
            for sdir in "${search_dirs[@]}"; do
                [ -d "$sdir" ] || continue
                for cand in "${pg_candidates[@]}"; do
                    if [ -s "${sdir}/${cand}" ]; then
                        matched_pg="${sdir}/${cand}"
                        break 2
                    fi
                done
                for f in "${sdir}"/*postgres*.secret "${sdir}"/*postgres*.env; do
                    if [ -s "$f" ]; then
                        matched_pg="$f"
                        break 2
                    fi
                done
            done
        fi

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
                POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-${POSTGRES_ADMIN_PASSWORD:-}}"
                [ -n "${PGHOST:-}" ] && POSTGRES_HOST="${PGHOST}"
                [ -n "${PGPORT:-}" ] && POSTGRES_PORT="${PGPORT}"
                [ -n "${PGDATABASE:-}" ] && POSTGRES_DB="${PGDATABASE}"
            elif [ -n "${first_line}" ]; then
                POSTGRES_PASSWORD="${first_line}"
            fi
        fi
    fi

    # Normalize PostgreSQL parameters for the node
    if [ -z "${POSTGRES_HOST:-}" ] || [ "${POSTGRES_HOST}" = "localhost" ] || [ "${POSTGRES_HOST}" = "127.0.0.1" ]; then
        POSTGRES_HOST="turnstone-postgres.lan"
    fi
    POSTGRES_USER="${POSTGRES_USER:-turnstone-np}"
    POSTGRES_PORT="${POSTGRES_PORT:-5432}"
    POSTGRES_DB="${POSTGRES_DB:-turnstone}"

    # 2. JWT Secret Discovery & Parsing
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
                if [ -s "${sdir}/${cand}" ]; then
                    matched_jwt="${sdir}/${cand}"
                    break 2
                fi
            done
            for f in "${sdir}"/*jwt*.secret "${sdir}"/*jwt*.env; do
                if [ -s "$f" ]; then
                    matched_jwt="$f"
                    break 2
                fi
            done
        done

        if [ -n "${matched_jwt}" ] && [ -f "${matched_jwt}" ]; then
            log_info "Auto-discovered JWT secret file: '${matched_jwt}'"
            local jwt_line
            jwt_line=$(grep -v '^[[:space:]]*#' "${matched_jwt}" | grep -v '^[[:space:]]*$' | tr -d '\r' | head -n 1 || true)
            if [[ "${jwt_line}" == *"="* ]]; then
                JWT_SECRET="${jwt_line#*=}"
                JWT_SECRET="${JWT_SECRET%\r}"
            else
                JWT_SECRET="${jwt_line}"
            fi
        fi
    fi

    # 3. Coordinator Host
    COORDINATOR_IP="${COORDINATOR_IP:-turnstone-coordinator-nerd-projects.lan}"

    # 4. NFS Server Discovery
    local nfs_candidates=(
        "turnstone_np_nfs.secret"
        "turnstone_np_smb.secret"
        "turnstone_np.secret"
    )
    for sdir in "${search_dirs[@]}"; do
        [ -d "$sdir" ] || continue
        for cand in "${nfs_candidates[@]}"; do
            if [ -s "${sdir}/${cand}" ]; then
                local first_nfs
                first_nfs=$(grep -v '^[[:space:]]*#' "${sdir}/${cand}" | grep -v '^[[:space:]]*$' | tr -d '\r' | head -n 1 || true)
                if [[ "${first_nfs}" == *"@"* ]]; then
                    local hpart="${first_nfs#*@}"
                    hpart="${hpart%%/*}"
                    hpart="${hpart%%:*}"
                    [ -n "${hpart}" ] && NFS_SERVER="${hpart}"
                fi
                break 2
            fi
        done
    done
}

echo -e "${BLUE}=================================================================${NC}"
echo -e "${BLUE}     Turnstone Node Deployment (Debian 12 Container)          ${NC}"
echo -e "${BLUE}=================================================================${NC}"

# Step 1: Root / Debian-12 Check
log_info "Step 1: Checking permissions and OS..."
if [ "$EUID" -ne 0 ]; then
    log_warn "This script must be run with sudo or as root."
    exec sudo bash "$0" "$@"
fi
log_success "Permissions verified."

if [ -f /etc/os-release ]; then
    . /etc/os-release
    log_info "Detected OS: ${PRETTY_NAME:-unknown}"
    if [ "${ID:-}" != "debian" ] || [ "${VERSION_ID:-}" != "12" ]; then
        log_warn "This script targets Debian 12. Continuing anyway."
    fi
else
    log_warn "/etc/os-release not found; assuming Debian 12 container."
fi

# Step 2: Auto-Load Secrets & Prompt for Missing Inputs
auto_load_all_secrets

if [ -z "${POSTGRES_PASSWORD}" ]; then
    read -r -s -p "Enter PostgreSQL Password for user '${POSTGRES_USER}'@'${POSTGRES_HOST}': " POSTGRES_PASSWORD
    echo ""
fi

if [ -z "${JWT_SECRET}" ]; then
    read -rp "Enter TURNSTONE_JWT_SECRET from Coordinator setup: " JWT_SECRET
fi

if [ -z "${NODE_ID}" ]; then
    DEFAULT_NODE_ID="$(hostname -s 2>/dev/null || echo "turnstone-worker-one")"
    if [ "${DEFAULT_NODE_ID}" = "localhost" ] || [ -z "${DEFAULT_NODE_ID}" ]; then
        DEFAULT_NODE_ID="turnstone-worker-one"
    fi
    read -rp "Enter Node ID (e.g. turnstone-worker-one, turnstone-worker-two) [default: ${DEFAULT_NODE_ID}]: " INPUT_NODE_ID
    NODE_ID="${INPUT_NODE_ID:-${DEFAULT_NODE_ID}}"
fi
log_info "Deploying with Node ID: '${NODE_ID}'"

LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || hostname -i 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")"
[ -z "${LAN_IP}" ] && LAN_IP="127.0.0.1"

log_success "Configured credentials for PostgreSQL (${POSTGRES_USER}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB})."

# Step 3: Base Packages, OpenSSH, Podman & Podman Compose
log_info "Step 3: Installing base packages, OpenSSH server, Podman, and Podman Compose..."
if command -v apt-get &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        python3 python3-venv python3-pip ruby ruby-dev git curl wget build-essential \
        procps file sudo ca-certificates openssh-server podman podman-compose nfs-common \
        || {
            # Fallback if podman-compose is packaged separately or in pip
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                python3 python3-venv python3-pip ruby ruby-dev git curl wget build-essential \
                procps file sudo ca-certificates openssh-server podman nfs-common
        }
fi

# Ensure podman-compose command is available
if ! command -v podman-compose &>/dev/null; then
    log_info "Installing podman-compose via pip..."
    pip3 install --break-system-packages --quiet podman-compose 2>/dev/null || true
fi

# Ensure uv package manager is available
if ! command -v uv &> /dev/null; then
    log_info "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi

# Step 4: Configure OpenSSH Server for Remote Access (Root & Turnstone)
log_info "Step 4: Configuring OpenSSH Server (sshd) for remote access (root & ${TURNSTONE_USER})..."
mkdir -p /run/sshd /var/run/sshd /root/.ssh
chmod 700 /root/.ssh

# Generate host keys if missing
if [ ! -f /etc/ssh/ssh_host_rsa_key ] && [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    log_info "Generating SSH host keys..."
    ssh-keygen -A || true
fi

# Configure sshd to permit root and turnstone login
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/01-turnstone-access.conf <<EOF
# Permitting remote root and turnstone login for Turnstone container management
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
EOF
chmod 644 /etc/ssh/sshd_config.d/01-turnstone-access.conf

if [ -f /etc/ssh/sshd_config ]; then
    sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
    sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
fi

# Start or restart sshd service
if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
    systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    log_success "OpenSSH service enabled and restarted via systemd."
else
    # Container / non-systemd environment
    service ssh restart 2>/dev/null || service ssh start 2>/dev/null || {
        if ! pgrep -x sshd >/dev/null 2>&1; then
            /usr/sbin/sshd 2>/dev/null || true
        fi
    }
    log_success "OpenSSH daemon configured and started (container mode)."
fi

# Step 5: Create Dedicated System User, Sudoers & Prepare Workspace
log_info "Step 5: Setting up '${TURNSTONE_USER}' system user, passwordless sudo, and workspace..."
if ! id "${TURNSTONE_USER}" &>/dev/null; then
    useradd --system --create-home --shell /bin/bash "${TURNSTONE_USER}" || useradd --system --no-create-home --shell /bin/bash "${TURNSTONE_USER}"
    log_success "Created system user '${TURNSTONE_USER}'."
else
    usermod -s /bin/bash "${TURNSTONE_USER}" 2>/dev/null || true
    log_success "System user '${TURNSTONE_USER}' already exists."
fi

# Configure passwordless sudo for turnstone
usermod -aG sudo "${TURNSTONE_USER}" 2>/dev/null || true
mkdir -p /etc/sudoers.d
cat > "/etc/sudoers.d/${TURNSTONE_USER}" <<EOF
# Allow turnstone user full passwordless sudo access
${TURNSTONE_USER} ALL=(ALL:ALL) NOPASSWD:ALL
EOF
chmod 0440 "/etc/sudoers.d/${TURNSTONE_USER}"

# Ensure subuid / subgid ranges for Podman
if [ -f /etc/subuid ] && ! grep -q "^${TURNSTONE_USER}:" /etc/subuid 2>/dev/null; then
    echo "${TURNSTONE_USER}:100000:65536" >> /etc/subuid 2>/dev/null || true
fi
if [ -f /etc/subgid ] && ! grep -q "^${TURNSTONE_USER}:" /etc/subgid 2>/dev/null; then
    echo "${TURNSTONE_USER}:100000:65536" >> /etc/subgid 2>/dev/null || true
fi

USER_HOME="$(getent passwd "${TURNSTONE_USER}" | cut -d: -f6 || echo "/home/${TURNSTONE_USER}")"
mkdir -p "${USER_HOME}" "${USER_HOME}/.ssh" "${WORKSPACE_DIR}" "${DATA_DIR}"
chmod 700 "${USER_HOME}/.ssh"

# Mirror authorized_keys to turnstone user if present in root
if [ -f /root/.ssh/authorized_keys ] && [ ! -f "${USER_HOME}/.ssh/authorized_keys" ]; then
    cp /root/.ssh/authorized_keys "${USER_HOME}/.ssh/authorized_keys"
    chmod 600 "${USER_HOME}/.ssh/authorized_keys"
fi

# Configure NFS shared storage mount if requested
if [ "${SKIP_NFS}" != "true" ]; then
    log_info "Configuring NFS shared storage for Turnstone (${NFS_SERVER}:${NFS_SHARE} -> ${WORKSPACE_DIR})..."

    # Ensure /etc/fstab exists
    [ -f /etc/fstab ] || touch /etc/fstab

    # Normalize paths (remove trailing slash except for root)
    [ "${WORKSPACE_DIR}" != "/" ] && WORKSPACE_DIR="${WORKSPACE_DIR%/}"
    [ "${NFS_SHARE}" != "/" ] && NFS_SHARE="${NFS_SHARE%/}"

    FSTAB_LINE="${NFS_SERVER}:${NFS_SHARE}  ${WORKSPACE_DIR}  nfs  nfsvers=4,noatime,hard,intr,rsize=1048576,wsize=1048576  0  0"

    # 1. Comment out any legacy SMB/CIFS entries for the target mount point
    if grep -qE "^[[:space:]]*[^#]*[[:space:]]+${WORKSPACE_DIR}[[:space:]]+(cifs|smbfs)" /etc/fstab 2>/dev/null; then
        log_info "Commenting out obsolete SMB/CIFS entry for ${WORKSPACE_DIR} in /etc/fstab..."
        sed -i.bak -E "\#^[[:space:]]*[^#]*[[:space:]]+${WORKSPACE_DIR}[[:space:]]+(cifs|smbfs)#s/^/# Obsolete SMB: /" /etc/fstab
    fi

    # 2. Check for obsolete mount points in /etc/fstab for this NFS share (e.g. previous /workspace/turnstone-teqonix)
    OLD_NFS_MOUNTS=$(awk -v share="${NFS_SERVER}:${NFS_SHARE}" '$1 == share && $0 !~ /^[[:space:]]*#/ {print $2}' /etc/fstab 2>/dev/null || true)
    for old_mp in ${OLD_NFS_MOUNTS}; do
        if [ "${old_mp}" != "${WORKSPACE_DIR}" ]; then
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
    OLD_NFS_SOURCES=$(awk -v mp="${WORKSPACE_DIR}" '$2 == mp && ($3 == "nfs" || $3 == "nfs4") && $0 !~ /^[[:space:]]*#/ {print $1}' /etc/fstab 2>/dev/null || true)
    for old_src in ${OLD_NFS_SOURCES}; do
        if [ "${old_src}" != "${NFS_SERVER}:${NFS_SHARE}" ]; then
            log_info "Found obsolete NFS source '${old_src}' for '${WORKSPACE_DIR}' in /etc/fstab."
            if mountpoint -q "${WORKSPACE_DIR}" 2>/dev/null; then
                log_info "Unmounting previous NFS share from '${WORKSPACE_DIR}'..."
                umount "${WORKSPACE_DIR}" 2>/dev/null || umount -l "${WORKSPACE_DIR}" 2>/dev/null || true
            fi
            log_info "Commenting out obsolete NFS source '${old_src}' in /etc/fstab..."
            sed -i.bak -E "\#^[[:space:]]*[^#]*[[:space:]]*${old_src}[[:space:]]+${WORKSPACE_DIR}([[:space:]]|$)#s/^/# Obsolete NFS source: /" /etc/fstab 2>/dev/null || true
        fi
    done

    # 4. Unmount any stale active mounts of this share elsewhere (e.g. from previous runs)
    ACTIVE_STALE_MOUNTS=$(awk -v share="${NFS_SERVER}:${NFS_SHARE}" -v target="${WORKSPACE_DIR}" '$1 == share && $2 != target {print $2}' /proc/mounts 2>/dev/null || true)
    for stale_mp in ${ACTIVE_STALE_MOUNTS}; do
        log_info "Unmounting stale active mount at '${stale_mp}'..."
        umount "${stale_mp}" 2>/dev/null || umount -l "${stale_mp}" 2>/dev/null || true
    done

    # 5. Add or update NFS mount in /etc/fstab
    if grep -qE "^[[:space:]]*[^#]*[[:space:]]*${NFS_SERVER}:${NFS_SHARE}[[:space:]]+${WORKSPACE_DIR}[[:space:]]+(nfs|nfs4)" /etc/fstab 2>/dev/null; then
        log_info "Updating existing NFS entry for ${WORKSPACE_DIR} in /etc/fstab..."
        sed -i.bak -E "s#^[[:space:]]*[^#]*[[:space:]]*${NFS_SERVER}:${NFS_SHARE}[[:space:]]+${WORKSPACE_DIR}[[:space:]]+(nfs|nfs4).*#${FSTAB_LINE}#" /etc/fstab
        log_success "NFS entry in /etc/fstab updated."
    else
        log_info "Adding NFS mount to /etc/fstab..."
        echo "" >> /etc/fstab
        echo "# Turnstone shared NFS storage for AI playground" >> /etc/fstab
        echo "${FSTAB_LINE}" >> /etc/fstab
        log_success "Added NFS entry to /etc/fstab."
    fi

    # 6. Ensure target mount point directory exists
    mkdir -p "${WORKSPACE_DIR}"

    # Check if WORKSPACE_DIR is mounted to an unexpected remote NFS share
    if mountpoint -q "${WORKSPACE_DIR}" 2>/dev/null; then
        CURRENT_MOUNT_SRC="$(awk -v mp="${WORKSPACE_DIR}" '$2 == mp {print $1}' /proc/mounts 2>/dev/null | head -n 1 || true)"
        if [ -n "${CURRENT_MOUNT_SRC}" ] && [ "${CURRENT_MOUNT_SRC}" != "${NFS_SERVER}:${NFS_SHARE}" ] && [[ "${CURRENT_MOUNT_SRC}" == *":"* ]]; then
            log_info "Mount at '${WORKSPACE_DIR}' points to unexpected source '${CURRENT_MOUNT_SRC}'. Remounting..."
            umount "${WORKSPACE_DIR}" 2>/dev/null || umount -l "${WORKSPACE_DIR}" 2>/dev/null || true
        fi
    fi

    # 7. Attempt to mount NFS share if not already mounted
    if ! mountpoint -q "${WORKSPACE_DIR}" 2>/dev/null; then
        log_info "Attempting to mount NFS share at ${WORKSPACE_DIR}..."
        if mount "${WORKSPACE_DIR}" 2>/dev/null || mount -t nfs -o nfsvers=4,noatime,hard,intr,rsize=1048576,wsize=1048576 "${NFS_SERVER}:${NFS_SHARE}" "${WORKSPACE_DIR}" 2>/dev/null || mount -a 2>/dev/null; then
            log_success "NFS storage successfully mounted at ${WORKSPACE_DIR}."
        else
            log_warn "Direct NFS mounting returned non-zero. (In unprivileged containers, host-mounted storage is expected)."
            log_warn "Ensure the container host has mounted '${NFS_SERVER}:${NFS_SHARE}' into '${WORKSPACE_DIR}'."
        fi
    else
        log_success "NFS storage already mounted at ${WORKSPACE_DIR}."
    fi
fi

# Ensure /data exists as a directory or link to /workspace
if [ ! -e "${DATA_DIR}" ]; then
    mkdir -p "${DATA_DIR}"
fi

chown -R "${TURNSTONE_USER}:${TURNSTONE_USER}" "${USER_HOME}" "${WORKSPACE_DIR}" "${DATA_DIR}" 2>/dev/null || true
chmod 775 "${WORKSPACE_DIR}" "${DATA_DIR}" 2>/dev/null || true
log_success "User '${TURNSTONE_USER}' configured with passwordless sudo; storage ready at '${WORKSPACE_DIR}'."

# Step 6: Install Homebrew (Linuxbrew) & Set Directory Permissions
log_info "Step 6: Installing and configuring Homebrew..."
BREW_PREFIX="/home/linuxbrew/.linuxbrew"
if [ ! -d "${BREW_PREFIX}" ] && [ -d "${USER_HOME}/.linuxbrew" ]; then
    BREW_PREFIX="${USER_HOME}/.linuxbrew"
fi

# Ensure all system directories needed by Homebrew (locks, cache, share, var) exist and are owned by turnstone
mkdir -p /home/linuxbrew \
         "${BREW_PREFIX}" \
         /usr/local/var/homebrew/locks \
         /usr/local/etc/homebrew \
         /usr/local/share/doc/homebrew \
         /usr/local/share/man/man1 \
         /var/homebrew/locks \
         "${USER_HOME}/.cache" \
         "${USER_HOME}/.local"

chown -R "${TURNSTONE_USER}:${TURNSTONE_USER}" \
    /home/linuxbrew \
    /usr/local/var \
    /usr/local/etc \
    /usr/local/share \
    /var/homebrew \
    "${USER_HOME}/.cache" \
    "${USER_HOME}/.local" 2>/dev/null || true

if [ ! -x "${BREW_PREFIX}/bin/brew" ] && ! command -v brew &>/dev/null; then
    log_info "Installing Homebrew into ${BREW_PREFIX}..."
    sudo -u "${TURNSTONE_USER}" git clone --depth=1 https://github.com/Homebrew/brew "${BREW_PREFIX}" \
        || git clone --depth=1 https://github.com/Homebrew/brew "${BREW_PREFIX}"
fi

if [ -d "${BREW_PREFIX}" ]; then
    chown -R "${TURNSTONE_USER}:${TURNSTONE_USER}" "${BREW_PREFIX}" 2>/dev/null || true
    mkdir -p /usr/local/bin
    if [ -x "${BREW_PREFIX}/bin/brew" ]; then
        ln -sfn "${BREW_PREFIX}/bin/brew" /usr/local/bin/brew
    fi
fi

# Export Homebrew shellenv to profile.d and user rc files
cat > /etc/profile.d/homebrew.sh <<EOF
if [ -x "${BREW_PREFIX}/bin/brew" ]; then
    eval "\$(${BREW_PREFIX}/bin/brew shellenv)"
elif command -v brew >/dev/null 2>&1; then
    eval "\$(brew shellenv)"
fi
EOF
chmod 644 /etc/profile.d/homebrew.sh

for target_home in "/root" "${USER_HOME}"; do
    for rc_file in "${target_home}/.bashrc" "${target_home}/.profile"; do
        if [ ! -f "${rc_file}" ]; then
            touch "${rc_file}"
        fi
        if ! grep -qF "brew shellenv" "${rc_file}" 2>/dev/null; then
            echo "" >> "${rc_file}"
            echo "# Homebrew environment" >> "${rc_file}"
            echo "if [ -x \"${BREW_PREFIX}/bin/brew\" ]; then eval \"\$(${BREW_PREFIX}/bin/brew shellenv)\"; fi" >> "${rc_file}"
        fi
    done
done

# Step 7: Python Virtualenv + Turnstone Package
log_info "Step 7: Setting up Python virtual environment and installing turnstone..."
VENV_DIR="/opt/turnstone-venv"
SYSTEM_PYTHON="$(command -v python3 || echo /usr/bin/python3)"

if [ ! -d "${VENV_DIR}" ]; then
    log_info "Creating virtual environment at ${VENV_DIR} using system ${SYSTEM_PYTHON}..."
    uv venv "${VENV_DIR}" --python "${SYSTEM_PYTHON}"
fi

log_info "Installing/updating turnstone package in virtualenv..."
if [ -f "${REPO_ROOT}/pyproject.toml" ]; then
    uv pip install --python "${VENV_DIR}" --reinstall "${REPO_ROOT}"
else
    uv pip install --python "${VENV_DIR}" turnstone
fi

chown -R "${TURNSTONE_USER}:${TURNSTONE_USER}" "${VENV_DIR}" 2>/dev/null || true
chmod -R a+rX "${VENV_DIR}"
chmod +x "${VENV_DIR}/bin"/* 2>/dev/null || true
log_success "Virtualenv verified at ${VENV_DIR}."

# Step 8: Optional extra tooling (all-smi, Rust/Cargo, Jujutsu)
CARGO_DIR="${USER_HOME}/.cargo"
ALL_SMI_BIN="${BREW_PREFIX}/bin/all-smi"
JJ_BIN="${CARGO_DIR}/bin/jj"

if [ "${SKIP_TOOLS}" != "true" ]; then
    log_info "Step 8: Installing optional tooling (all-smi, Rust/Cargo, Jujutsu)..."

    # 8a. all-smi via Homebrew
    if [ -x "${BREW_PREFIX}/bin/brew" ] || command -v brew &>/dev/null; then
        log_info "Installing all-smi utility via Homebrew..."
        # Re-ensure lock & var permissions prior to brew operations
        mkdir -p /usr/local/var/homebrew/locks /var/homebrew/locks "${USER_HOME}/.cache"
        chown -R "${TURNSTONE_USER}:${TURNSTONE_USER}" /usr/local/var /var/homebrew "${USER_HOME}/.cache" 2>/dev/null || true
        sudo -u "${TURNSTONE_USER}" -H bash -c "
            export HOME=\"${USER_HOME}\"
            eval \"\$(${BREW_PREFIX}/bin/brew shellenv)\" 2>/dev/null || eval \"\$(brew shellenv)\" 2>/dev/null || true
            export HOMEBREW_NO_AUTO_UPDATE=1
            export NONINTERACTIVE=1
            brew tap lablup/tap --quiet 2>/dev/null || true
            brew install lablup/tap/all-smi || brew install all-smi
        " || log_warn "all-smi install failed (non-fatal)."

        if [ -x "${ALL_SMI_BIN}" ]; then
            mkdir -p /usr/local/bin
            ln -sfn "${ALL_SMI_BIN}" /usr/local/bin/all-smi
            log_success "all-smi utility installed at ${ALL_SMI_BIN}."
        fi
    fi

    # 8b. Rust / Cargo + Jujutsu
    if [ ! -x "${CARGO_DIR}/bin/cargo" ] && ! command -v cargo &>/dev/null; then
        log_info "Installing Rust and Cargo toolchain via rustup..."
        sudo -u "${TURNSTONE_USER}" -H bash -c "
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile default --no-modify-path
        " || log_warn "Rust install failed (non-fatal)."
    fi

    for rc_file in "${USER_HOME}/.bashrc" "${USER_HOME}/.profile"; do
        if ! grep -qF ".cargo/bin" "${rc_file}" 2>/dev/null; then
            echo "" >> "${rc_file}"
            echo "# Rust / Cargo environment" >> "${rc_file}"
            echo "export PATH=\"\${HOME}/.cargo/bin:\$PATH\"" >> "${rc_file}"
            echo "[ -f \"\${HOME}/.cargo/env\" ] && source \"\${HOME}/.cargo/env\"" >> "${rc_file}"
        fi
    done

    if [ ! -x "${JJ_BIN}" ] && ! command -v jj &>/dev/null; then
        log_info "Installing Jujutsu (jj-cli) via cargo..."
        sudo -u "${TURNSTONE_USER}" -H bash -c "
            export PATH=\"\${HOME}/.cargo/bin:\$PATH\"
            cargo install --locked jj-cli
        " || log_warn "Jujutsu install failed (non-fatal)."
    fi

    chown -R "${TURNSTONE_USER}:${TURNSTONE_USER}" "${CARGO_DIR}" "${USER_HOME}/.rustup" 2>/dev/null || true
    mkdir -p /usr/local/bin
    for bin_tool in cargo rustc rustup jj; do
        if [ -x "${CARGO_DIR}/bin/${bin_tool}" ]; then
            ln -sfn "${CARGO_DIR}/bin/${bin_tool}" "/usr/local/bin/${bin_tool}"
        fi
    done
    log_success "Optional tooling setup complete."
else
    log_info "Step 8: Skipping optional extra tooling (--skip-tools)."
fi

# Step 9: Configure /etc/turnstone/config.toml Secrets
log_info "Step 9: Writing secrets configuration to /etc/turnstone/config.toml..."
mkdir -p /etc/turnstone

cat > /etc/turnstone/config.toml <<EOF
[auth]
jwt_secret = "${JWT_SECRET}"

[database]
backend = "postgresql"
url = "postgresql+psycopg://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"

[api]
base_url = "${LLM_BASE_URL}"
api_key = "dummy"
EOF

chown -R "${TURNSTONE_USER}:${TURNSTONE_USER}" /etc/turnstone 2>/dev/null || true
chmod 600 /etc/turnstone/config.toml
log_success "Configuration written and permissions secured (0600 ${TURNSTONE_USER})."

# Step 10: Podman Engine Verification
log_info "Step 10: Verifying Podman and Podman Compose engine..."
if command -v podman &>/dev/null; then
    log_success "Podman $(podman --version) is available."
    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        systemctl enable --now podman.socket 2>/dev/null || true
    fi
else
    log_warn "Podman command not found in PATH."
fi

if command -v podman-compose &>/dev/null; then
    log_success "Podman Compose $(podman-compose --version 2>/dev/null || echo 'installed') is available."
fi

# Step 11: Install Entrypoint Wrapper + (Optional) Systemd Unit
log_info "Step 11: Installing entrypoint wrapper..."

ENTRYPOINT="/usr/local/bin/turnstone-node-entrypoint"
cat > "${ENTRYPOINT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

# Ensure SSH daemon is active in container mode (requires root)
if [ "\$(id -u)" -eq 0 ]; then
    mkdir -p /run/sshd /var/run/sshd
    if ! pgrep -x sshd >/dev/null 2>&1; then
        /usr/sbin/sshd 2>/dev/null || service ssh start 2>/dev/null || true
    fi
fi

# Environment paths
export PATH=/opt/turnstone-venv/bin:${BREW_PREFIX}/bin:${CARGO_DIR}/bin:/usr/local/bin:/usr/bin:/bin
if [ -x "${BREW_PREFIX}/bin/brew" ]; then
    eval "\$(${BREW_PREFIX}/bin/brew shellenv)" 2>/dev/null || true
fi

export TURNSTONE_NODE_ID="${NODE_ID}"
export TURNSTONE_ADVERTISE_URL="http://${LAN_IP}:8080"
export TURNSTONE_CONSOLE_URL="http://${COORDINATOR_IP}:8090"
export TURNSTONE_SEARXNG_URL="http://${COORDINATOR_IP}:8081"
export TURNSTONE_CONFIG="/etc/turnstone/config.toml"
export TURNSTONE_DB_BACKEND="postgresql"
export TURNSTONE_DB_URL="postgresql+psycopg://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
export TURNSTONE_STORAGE_DIR="${WORKSPACE_DIR}"
export TURNSTONE_WORKSPACE="${WORKSPACE_DIR}"
export TURNSTONE_DATA_DIR="${DATA_DIR}"

# Run turnstone-server as dedicated turnstone user
if [ "\$(id -u)" -eq 0 ]; then
    exec sudo -u "${TURNSTONE_USER}" -H \
        --preserve-env=PATH,TURNSTONE_NODE_ID,TURNSTONE_ADVERTISE_URL,TURNSTONE_CONSOLE_URL,TURNSTONE_SEARXNG_URL,TURNSTONE_CONFIG,TURNSTONE_DB_BACKEND,TURNSTONE_DB_URL,TURNSTONE_STORAGE_DIR,TURNSTONE_WORKSPACE,TURNSTONE_DATA_DIR \
        /opt/turnstone-venv/bin/turnstone-server --host 0.0.0.0 --port 8080 --config /etc/turnstone/config.toml
else
    exec /opt/turnstone-venv/bin/turnstone-server --host 0.0.0.0 --port 8080 --config /etc/turnstone/config.toml
fi
EOF
chmod +x "${ENTRYPOINT}"
chown root:root "${ENTRYPOINT}"
log_success "Entrypoint wrapper installed at ${ENTRYPOINT}."

# If systemd is present, also install a unit (host-style / systemd container deployment)
if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
    log_info "systemd detected - installing turnstone-server.service..."
    cat > /etc/systemd/system/turnstone-server.service <<EOF
[Unit]
Description=Turnstone Server Node (Debian 12)
After=network.target network-online.target ssh.service
Wants=network-online.target ssh.service

[Service]
Type=simple
User=${TURNSTONE_USER}
Group=${TURNSTONE_USER}
WorkingDirectory=${WORKSPACE_DIR}
ExecStart=/usr/local/bin/turnstone-node-entrypoint
Restart=always
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable turnstone-server.service
    systemctl restart turnstone-server.service
    sleep 2
    if systemctl is-active --quiet turnstone-server.service; then
        log_success "turnstone-server.service is ACTIVE."
    else
        log_warn "turnstone-server.service is not active! Recent logs:"
        journalctl -u turnstone-server.service -n 25 --no-pager || true
    fi
    RUN_FOREGROUND="false"
else
    log_info "No systemd PID-1 detected - will run the server in the foreground (container mode)."
fi

# Step 12: Health check (best-effort)
log_info "Step 12: Verifying turnstone-server health at http://${LAN_IP}:8080..."
TS_READY=false
for _attempt in {1..15}; do
    if curl -s "http://127.0.0.1:8080" &>/dev/null || curl -s "http://${LAN_IP}:8080" &>/dev/null; then
        TS_READY=true
        break
    fi
    sleep 1
done
if [ "${TS_READY}" = true ]; then
    log_success "Turnstone Server is healthy and listening on http://${LAN_IP}:8080."
else
    log_warn "Turnstone Server not yet responding on port 8080 (it may be starting in the foreground)."
fi

echo -e "${GREEN}=================================================================${NC}"
echo -e "${GREEN}  Turnstone Node (Debian 12 Container) Deployed Successfully!  ${NC}"
echo -e "${GREEN}=================================================================${NC}"
echo -e "Node ID: ${NODE_ID}"
echo -e "Advertise URL: http://${LAN_IP}:8080"
echo -e "PostgreSQL Backend: ${POSTGRES_USER}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
echo -e "LLM Backend (inference nodes): ${LLM_BASE_URL}"
echo -e "Coordinator: http://${COORDINATOR_IP}:8090"
echo -e "Workspace Directory: ${WORKSPACE_DIR}"
if [ "${SKIP_NFS}" != "true" ]; then
    echo -e "NFS Storage: ${NFS_SERVER}:${NFS_SHARE} mounted at ${WORKSPACE_DIR}"
fi
echo -e "OpenSSH Server: Configured (Root login enabled)"
echo -e "Podman: $(command -v podman 2>/dev/null || echo 'not found')"
echo -e "Podman Compose: $(command -v podman-compose 2>/dev/null || echo 'not found')"
echo -e "Homebrew Prefix: ${BREW_PREFIX}"
echo -e "Entrypoint: ${ENTRYPOINT}"

# Step 13: Foreground execution (container mode)
if [ "${RUN_FOREGROUND}" = "true" ]; then
    log_info "Starting turnstone-server in the foreground (container entrypoint)..."
    exec "${ENTRYPOINT}"
fi
