#!/usr/bin/env bash
# =============================================================================
# Turnstone LLM Inference Node Deployment (AMD Ryzen AI Halo - Linux)
#
# This node acts ONLY as an LLM inference server. It provisions the ryzenadj
# power-management utility (TDP control) and verifies the local Lemonade model
# server is reachable.
#
# The Turnstone node role has been moved to a dedicated Debian 12 container
# (see deploy_turnstone_debian12.sh). This script no longer installs the
# `turnstone` package, no longer writes /etc/turnstone/config.toml, and no
# longer manages a turnstone-server systemd unit.
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

# Inference endpoint served by the local Lemonade model server.
LEMONADE_URL="${LEMONADE_URL:-http://127.0.0.1:8000/v1}"
SKIP_RYZENADJ="${SKIP_RYZENADJ:-false}"
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
    echo "LLM inference node only (no Turnstone node is installed by this script)."
    echo ""
    echo "Options:"
    echo "      --lemonade-url <url>       Local Lemonade API base URL [default: ${LEMONADE_URL}]"
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
        --lemonade-url)
            LEMONADE_URL="$2"
            shift 2
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
echo -e "${BLUE}  LLM Inference Node Deployment (AMD Ryzen AI Halo - Lemonade)  ${NC}"
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

# Step 3: Verify Local Lemonade Inference Server
log_info "Step 3: Verifying local Lemonade inference server at ${LEMONADE_URL}..."
LEMONADE_READY=false
for _attempt in {1..30}; do
    if curl -sf "${LEMONADE_URL}/models" &>/dev/null 2>&1; then
        LEMONADE_READY=true
        break
    fi
    sleep 1
done

if [ "${LEMONADE_READY}" = true ]; then
    log_success "Lemonade inference server is healthy at ${LEMONADE_URL}."
else
    log_warn "Lemonade server not yet responding at ${LEMONADE_URL}."
    log_warn "This is expected if the model server has not been started yet."
    log_warn "The Turnstone node (Debian 12 container) will reach this node at this URL."
fi

# Step 4: Configure NFS Shared Storage for AI Workspace
if [ "${SKIP_NFS}" != "true" ]; then
    log_info "Step 4: Configuring NFS shared storage (${NFS_SERVER}:${NFS_SHARE} -> ${MOUNT_POINT})..."

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
        fi
    else
        log_warn "NFS share could not be mounted at ${MOUNT_POINT} during deployment. It will mount automatically at boot via /etc/fstab."
    fi
else
    log_info "Step 4: Skipping NFS mount setup (--skip-nfs specified)."
fi

LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || hostname -i 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")"
[ -z "${LAN_IP}" ] && LAN_IP="127.0.0.1"

echo -e "${GREEN}=================================================================${NC}"
echo -e "${GREEN}  LLM Inference Node (AMD Ryzen AI Halo) Provisioned!          ${NC}"
echo -e "${GREEN}=================================================================${NC}"
echo -e "Node role: LLM inference server (no Turnstone node installed here)"
echo -e "Lemonade backend: ${LEMONADE_URL}"
echo -e "LAN IP: ${LAN_IP}"
echo -e "Power management: ryzenadj (TDP)"
if [ "${SKIP_NFS}" != "true" ]; then
    echo -e "Shared storage (NFS): ${NFS_SERVER}:${NFS_SHARE} mounted at ${MOUNT_POINT}"
fi
echo -e ""
echo -e "The Turnstone node now runs in a dedicated Debian 12 container."
echo -e "Run deploy_turnstone_debian12.sh to provision it."
