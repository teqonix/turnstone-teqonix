#!/usr/bin/env bash
# Turnstone SMB Mount Helper (macOS)
mkdir -p "${MOUNT_POINT}" 2>/dev/null || true
if ! mount | grep -Fq "on ${MOUNT_POINT} "; then
    mount_smbfs "//${REMOTE_USERNAME}:${SMB_PASSWORD}@${SERVER_HOSTNAME}/${SHARE_NAME}" "${MOUNT_POINT}" 2>/dev/null || true
fi
