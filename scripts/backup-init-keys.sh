#!/usr/bin/env bash
# =============================================================================
# backup-init-keys.sh -- ONE-TIME setup: create the age keypair and a config
# skeleton under /root/.config/r740-backup/ (never inside a repo).
#
# RUN THIS: on the Proxmox host as root.
# AFTER:    copy the private key (age.key) to a SECOND place you control (a
#           password manager). If both copies are lost, every backup is
#           unrecoverable.
# =============================================================================
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
. "$here/backup-common.sh"

umask 077
mkdir -p "$BK_CONFIG_DIR"
chmod 700 "$BK_CONFIG_DIR"

key="$BK_CONFIG_DIR/age.key"
if [ -e "$key" ]; then
  bk_log "refusing to overwrite existing key: $key"
  exit 1
fi

age-keygen -o "$key" 2>/dev/null
chmod 600 "$key"
recipient="$(age-keygen -y "$key")"

cfg="$BK_CONFIG_DIR/backup.env"
if [ ! -e "$cfg" ]; then
  cp "$here/../backup.env.example" "$cfg"
  chmod 600 "$cfg"
fi
sed -i -E "s#^BK_AGE_RECIPIENT=.*#BK_AGE_RECIPIENT=$recipient#; s#^BK_AGE_IDENTITY=.*#BK_AGE_IDENTITY=$key#" "$cfg"

bk_log "created $key (mode 600) and $cfg"
bk_log "public recipient: $recipient"
bk_log "NEXT: copy $key to a second location you control. Losing every copy makes all backups unrecoverable."
