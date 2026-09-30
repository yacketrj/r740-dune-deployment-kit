#!/usr/bin/env bash
# =============================================================================
# backup-daily.sh -- daily tier: game DB backups + secrets + host config,
# age-encrypted, copied to the SMB share and to OneDrive (rclone crypt).
#
# RUN THIS: on the Proxmox host as root, from the r740-backup-daily.timer.
# =============================================================================
set -eEuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
. "$here/backup-common.sh"
bk_load_config

fail() {
  bk_log "FAILED: $*"
  bk_notify "r740 daily backup FAILED: $*"
  exit 1
}

# Fix #1: ERR trap for unexpected failures
alerted=0
trap 'if [ "$alerted" -eq 0 ]; then alerted=1; bk_log "FAILED: unexpected error at line $LINENO"; bk_notify "r740 daily backup FAILED: unexpected error at line $LINENO"; fi; exit 1' ERR

bk_lock daily || exit 1

stamp="$(date -u +%Y%m%d-%H%M%S)"
name="daily-$stamp.tar.age"
work=""

# Fix #3: Sweep stale daily.XXXXXX directories immediately after lock
if [ -n "$BK_STAGE_DIR" ] && [ "$BK_STAGE_DIR" != "/" ] && [ -d "$BK_STAGE_DIR" ]; then
  find "$BK_STAGE_DIR" -maxdepth 1 -type d -name "daily.*" -exec rm -rf {} + 2>/dev/null || true
fi

cleanup() {
  [ -z "$work" ] || rm -rf "$work"
  # Fix #2: Clean up any leftover .partial files on SMB (this run's and any stale ones)
  [ -d "$BK_SMB_MOUNT/daily" ] && find "$BK_SMB_MOUNT/daily" -maxdepth 1 -name "*.partial" -delete 2>/dev/null || true
}
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

# 2. host config (missing optional paths are tolerated, but log any errors)
# shellcheck disable=SC2086
host_stderr="$(mktemp)"
if tar -C / -cf - $BK_HOST_PATHS 2>"$host_stderr" | tar -xf - -C "$work/host" 2>/dev/null; then
  [ -s "$host_stderr" ] && bk_log "host tar warnings: $(cat "$host_stderr")"
else
  bk_log "host tar extraction failed (exit code $?); $(cat "$host_stderr")"
fi
rm -f "$host_stderr"
# Fix #5: fail if host directory is empty (indicates no host paths were captured)
[ -d "$work/host" ] && [ "$(find "$work/host" -type f | wc -l)" -gt 0 ] || fail "no host config files captured"

# 3. bundle + encrypt
tar -C "$work" -cf "$work/bundle.tar" prod host || fail "could not create bundle"
bk_age_encrypt "$work/bundle.tar" "$work/$name" || fail "encryption failed"
rm -f "$work/bundle.tar"

# 4. SMB share
# Fix #4: recheck mount is still mounted (time-of-check/time-of-use issue)
bk_require_mounted "$BK_SMB_MOUNT" || fail "SMB share not mounted at $BK_SMB_MOUNT"
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
