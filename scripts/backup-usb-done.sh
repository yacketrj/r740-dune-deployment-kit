#!/usr/bin/env bash
# =============================================================================
# backup-usb-done.sh -- record that you copied the backup share to the off-premises USB key.
#
#   backup-usb-done.sh [NOTE]     e.g. backup-usb-done.sh "key B, daily + newest vm images"
#
# The hourly alarm cannot see the key, so this is how it learns of a copy: it adds a "usb-copy" PASS
# to the evidence log (and the hash-chained audit log). Only if BK_USB_MAX_AGE_D is set (days; default 0 = off) the alarm
# warns when the last one is older than that. Run it AFTER you have checked the newest daily file
# on the key (runbook 9b). RUN THIS: on the Proxmox host as root.
# =============================================================================
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
. "$here/backup-common.sh"
bk_secure_umask
bk_load_config
note="${1:-}"
[ "${#note}" -le 200 ] || { echo "backup-usb-done: note is too long (max 200 characters)" >&2; exit 2; }
bk_evidence usb-copy PASS "note=${note:-none}"
echo "recorded: off-premises USB copy at $(date -u +%Y-%m-%dT%H:%M:%SZ). "
