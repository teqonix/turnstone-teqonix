#!/usr/bin/env bash
# =============================================================================
# Turnstone SMB Mount Helper (DEPRECATED - Migrated to NFS)
#
# This script is retained for backwards compatibility and forwards execution
# to mount_nfs.sh.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "[WARNING] mount_smb.sh is deprecated. Switching to NFS mount via mount_nfs.sh..."
exec bash "${SCRIPT_DIR}/mount_nfs.sh" "$@"
