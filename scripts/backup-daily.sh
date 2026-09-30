#!/usr/bin/env bash
# =============================================================================
# backup-daily.sh -- daily tier: game DB backups + secrets + host config,
# age-encrypted, copied to the SMB share and to OneDrive (rclone crypt).
#
# RUN THIS: on the Proxmox host as root, from the r740-backup-daily.timer.
# =============================================================================
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
. "$here/backup-common.sh"
bk_load_config

fail() {
  bk_log "FAILED: $*"
  bk_notify "r740 daily backup FAILED: $*"
  exit 1
}

bk_lock daily || exit 1

stamp="$(date -u +%Y%m%d-%H%M%S)"
name="daily-$stamp.tar.age"
work=""
cleanup() { [ -z "$work" ] || rm -rf "$work"; }
trap cleanup EXIT

bk_require_mounted "$BK_SMB_MOUNT" || fail "SMB share not mounted at $BK_SMB_MOUNT"
bk_require_free_gb "$BK_STAGE_DIR" "${BK_MIN_STAGE_GB:-2}" || fail "not enough staging space"
work="$(mktemp -d "$BK_STAGE_DIR/daily.XXXXXX")"
mkdir -p "$work/prod" "$work/host"

# 1. dune-prod: DB backups, secrets, .env (streamed as tar over ssh)
ssh -o BatchMode=yes -o ConnectTimeout=15 \
  -o UserKnownHostsFile="$BK_CONFIG_DIR/known_hosts" -o StrictHostKeyChecking=accept-new \
  "$BK_PROD_SSH" \
  "cd ~/$BK_PROD_REPO && tar -cf - runtime/backups/db runtime/secrets .env" \
  | tar -xf - -C "$work/prod" || fail "could not fetch backups from $BK_PROD_SSH"

# 2. host config (missing optional paths are tolerated)
# shellcheck disable=SC2086
tar -C / -cf - $BK_HOST_PATHS 2>/dev/null | tar -xf - -C "$work/host" || true

# 3. bundle + encrypt
tar -C "$work" -cf "$work/bundle.tar" prod host || fail "could not create bundle"
bk_age_encrypt "$work/bundle.tar" "$work/$name" || fail "encryption failed"
rm -f "$work/bundle.tar"

# 4. SMB share
mkdir -p "$BK_SMB_MOUNT/daily"
cp -f -- "$work/$name" "$BK_SMB_MOUNT/daily/$name.partial" || fail "copy to SMB failed"
mv -f -- "$BK_SMB_MOUNT/daily/$name.partial" "$BK_SMB_MOUNT/daily/$name"

# 5. OneDrive (rclone crypt)
rclone copyto "$work/$name" "$BK_RCLONE_REMOTE/$name" || fail "upload to $BK_RCLONE_REMOTE failed"

# 6. retention
bk_prune_daily_monthly "$BK_SMB_MOUNT/daily" daily 30 12
bk_prune_remote "$BK_RCLONE_REMOTE" daily 30 12

bk_state_touch daily
bk_log "daily backup OK: $name"
bk_notify "r740 daily backup OK: $name"
