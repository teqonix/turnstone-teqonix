#!/usr/bin/env bash
# =============================================================================
# Turnstone NFS Mount Helper (macOS)
#
# Mounts the shared TrueNAS NFS workspace for the macOS LLM inference node.
# Intended to be invoked via LaunchDaemon (/Library/LaunchDaemons/com.turnstone.nfs-mount.plist)
# or directly by deploy_mlx_node.sh / admin users.
# =============================================================================

set -euo pipefail

NFS_SERVER="${NFS_SERVER:-silo-14.lan}"
NFS_SHARE="${NFS_SHARE:-/mnt/silo-14/ai-playground}"
INFER_USER="${INFER_USER:-turnstone}"
if [ -z "${INFER_USER}" ] || ! id "${INFER_USER}" &>/dev/null; then
    INFER_USER="${SUDO_USER:-$(whoami)}"
fi

USER_HOME="$(dscl . -read "/Users/${INFER_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || echo "/Users/${INFER_USER}")"
[ -z "${USER_HOME}" ] && USER_HOME="/Users/${INFER_USER}"

MOUNT_POINT="${MOUNT_POINT:-${USER_HOME}/silo-14/ai-playground}"

# Check if secret file exists to extract NFS server host if needed
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="${SCRIPT_DIR}/../secrets"
for sec_file in "${SECRETS_DIR}/turnstone_np_nfs.secret" "${SECRETS_DIR}/turnstone_np_smb.secret"; do
    if [ -s "${sec_file}" ]; then
        uri_line=$(grep -v '^[[:space:]]*#' "${sec_file}" | grep -v '^[[:space:]]*$' | tr -d '\r' | head -n 1 || true)
        if [[ "${uri_line}" == *"@"* ]]; then
            hpart="${uri_line#*@}"
            hpart="${hpart%%/*}"
            hpart="${hpart%%:*}"
            [ -n "${hpart}" ] && NFS_SERVER="${hpart}"
        fi
        break
    fi
done

# If an obsolete SMB filesystem is currently mounted at the target point, unmount it
if mount | grep -F "on ${MOUNT_POINT} " | grep -q "smbfs"; then
    echo "[INFO] Unmounting obsolete SMB share from ${MOUNT_POINT}..."
    umount -f "${MOUNT_POINT}" 2>/dev/null || true
fi

# If already mounted with NFS, exit cleanly
if mount | grep -F "on ${MOUNT_POINT} " | grep -q "nfs"; then
    echo "[INFO] NFS share already mounted at ${MOUNT_POINT}."
    exit 0
fi

# Ensure target mount point directory exists
mkdir -p "${MOUNT_POINT}" 2>/dev/null || sudo mkdir -p "${MOUNT_POINT}" 2>/dev/null || true

# In macOS, mounting NFS requires root / sudo. resvport is required for TrueNAS/FreeBSD exports.
MOUNT_CMD=(mount_nfs -o vers=4,noatime,hard,intr,resvport,rsize=1048576,wsize=1048576)
MOUNT_FALLBACK=(mount_nfs -o vers=3,noatime,hard,intr,resvport,rsize=1048576,wsize=1048576)

echo "[INFO] Mounting ${NFS_SERVER}:${NFS_SHARE} at ${MOUNT_POINT}..."
if [ "$EUID" -eq 0 ]; then
    "${MOUNT_CMD[@]}" "${NFS_SERVER}:${NFS_SHARE}" "${MOUNT_POINT}" 2>/dev/null || \
    "${MOUNT_FALLBACK[@]}" "${NFS_SERVER}:${NFS_SHARE}" "${MOUNT_POINT}" 2>/dev/null || {
        echo "[ERROR] Failed to mount NFS share ${NFS_SERVER}:${NFS_SHARE} at ${MOUNT_POINT}."
        exit 1
    }
    chown -R "${INFER_USER}:staff" "${MOUNT_POINT}" 2>/dev/null || true
    chmod 775 "${MOUNT_POINT}" 2>/dev/null || true
else
    sudo "${MOUNT_CMD[@]}" "${NFS_SERVER}:${NFS_SHARE}" "${MOUNT_POINT}" 2>/dev/null || \
    sudo "${MOUNT_FALLBACK[@]}" "${NFS_SERVER}:${NFS_SHARE}" "${MOUNT_POINT}" 2>/dev/null || {
        echo "[ERROR] Failed to mount NFS share ${NFS_SERVER}:${NFS_SHARE} at ${MOUNT_POINT} (sudo required)."
        exit 1
    }
    sudo chown -R "${INFER_USER}:staff" "${MOUNT_POINT}" 2>/dev/null || true
    sudo chmod 775 "${MOUNT_POINT}" 2>/dev/null || true
fi

echo "[SUCCESS] Successfully mounted ${NFS_SERVER}:${NFS_SHARE} at ${MOUNT_POINT}."
