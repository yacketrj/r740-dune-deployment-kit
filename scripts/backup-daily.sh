#!/usr/bin/env bash
# =============================================================================
# backup-daily.sh -- database tier and daily set (design v2).
#
#   backup-daily.sh --tier db      every 6h: the newest official database dump
#                                  pairs only (small; RPO 6h)
#   backup-daily.sh --tier daily   05:15: recent dump pairs + runtime/secrets +
#                                  .env + host config
#
# Flow: pull through the restricted gate on dune-prod -> verify everything ->
# tar -> age (PUBLIC recipient only; the private key is never on this host) ->
# SMB share (.partial, verified, renamed) -> OneDrive (rclone) -> verify the
# transfer bit-exactly -> only then prune -> record -> dead-man ping.
# Every failure raises ONE actionable alert naming the stage and never records
# success. See docs/superpowers/specs/2026-09-29-backup-strategy-design.md.
#
# RUN THIS: on the Proxmox host as root, from the r740-backup-* timers.
# =============================================================================
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
. "$here/backup-common.sh"

tier=""
if [ "${1:-}" = "--tier" ]; then tier="${2:-}"; fi
case "$tier" in
  db)
    prefix="dbtier"; gate_verb="newest-db"; gate_max_age="${BK_DB_MAX_AGE_H:-8}"; gate_since="${BK_DB_SINCE_H:-8}"
    keep_daily=28; keep_monthly=1; notify_ok=0
    ;;
  daily)
    prefix="daily"; gate_verb="set"; gate_max_age="${BK_DAILY_MAX_AGE_H:-30}"; gate_since="${BK_DAILY_SINCE_H:-48}"
    keep_daily=30; keep_monthly=12; notify_ok=1
    ;;
  *)
    echo "usage: $0 --tier db|daily" >&2
    exit 2
    ;;
esac

BK_JOB="backup ${tier} tier"
export BK_JOB
bk_secure_umask
bk_load_config

STAGE="preflight"
RERUN="bash $here/backup-daily.sh --tier $tier"
alerted=0
main_pid=$$
work=""
partial=""
result_name=""

cleanup() {
  [ -z "$partial" ] || rm -f -- "$partial"
  [ -z "$work" ] || bk_safe_rm_under "${BK_STAGE_DIR:-/nonexistent}" "$work" || true
}
trap cleanup EXIT

report_failure() { # message
  if [ "$alerted" -eq 0 ]; then
    alerted=1
    bk_audit_log run_failed "tier=$tier" "stage=$STAGE" "error=$1"
    bk_alert "$STAGE" "$1" "$RERUN"
    bk_dead_man_ping fail || true
  fi
}

# One alert only: subshells (command substitutions) inherit this trap under -E,
# but only the main shell reports.
on_err() {
  local line="$1"
  trap - ERR
  if [ "$BASHPID" = "$main_pid" ]; then
    report_failure "unexpected error at line $line"
  fi
  exit 1
}
trap 'on_err $LINENO' ERR

fail() {
  bk_log "FAILED at $STAGE: $*"
  report_failure "$*"
  exit 1
}

bk_lock "backup-$tier" || exit 1

# --- preflight ----------------------------------------------------------------
case "${BK_AGE_RECIPIENT:-}" in age1*) ;; *) fail "no age recipient configured (run backup-key.sh generate)" ;; esac
: "${BK_STAGE_DIR:?}" "${BK_SMB_MOUNT:?}" "${BK_RCLONE_REMOTE:?}" "${BK_BACKUP_SSH:?}"
bk_require_mounted "$BK_SMB_MOUNT" || fail "SMB share not mounted at $BK_SMB_MOUNT"
bk_require_free_gb "$BK_STAGE_DIR" "${BK_MIN_STAGE_GB:-2}" || fail "not enough staging space in $BK_STAGE_DIR"
mkdir -p "$BK_STAGE_DIR"
chmod 700 "$BK_STAGE_DIR"

# Stale plaintext from a killed earlier run: safe to sweep because we hold the lock.
for old in "$BK_STAGE_DIR"/"$prefix".*; do
  [ -d "$old" ] || continue
  bk_safe_rm_under "$BK_STAGE_DIR" "$old" || true
done

stamp="$(date -u +%Y%m%d-%H%M%S)"
name="$prefix-$stamp.tar.age"
work="$(mktemp -d "$BK_STAGE_DIR/$prefix.XXXXXX")"
mkdir -p "$work/bundle/prod" "$work/bundle/host"

# --- pull ---------------------------------------------------------------------
STAGE="pull"
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15 -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes)
[ -z "${BK_BACKUP_SSH_KEY:-}" ] || ssh_opts+=(-i "$BK_BACKUP_SSH_KEY")
[ -z "${BK_KNOWN_HOSTS:-}" ] || ssh_opts+=(-o "UserKnownHostsFile=$BK_KNOWN_HOSTS")
if ! ssh "${ssh_opts[@]}" "$BK_BACKUP_SSH" "$gate_verb $gate_max_age $gate_since" >"$work/pull.tar" 2>"$work/pull.err"; then
  fail "pull from $BK_BACKUP_SSH failed: $(tr '\n' ' ' <"$work/pull.err" | cut -c1-300)"
fi

# --- verify what was pulled (before anything is encrypted or uploaded) --------
STAGE="verify"
tar -tf "$work/pull.tar" >"$work/pull.list" 2>/dev/null || fail "pulled archive is not a readable tar (truncated?)"
if grep -qE '^/|(^|/)\.\.(/|$)' "$work/pull.list"; then
  fail "pulled archive contains an absolute or parent-relative path"
fi
bk_tar_members_safe "$work/pull.tar" || fail "pulled archive contains a link, device or other non-regular member"
tar -xf "$work/pull.tar" -C "$work/bundle/prod" --no-same-owner --no-same-permissions 2>/dev/null || fail "could not unpack the pulled archive"
[ -s "$work/bundle/prod/gate-manifest.txt" ] || fail "pulled archive has no gate manifest"
authoritative="$(awk -F= '$1 == "authoritative" { print $2; exit }' "$work/bundle/prod/gate-manifest.txt")"
[ -n "$authoritative" ] && [ -f "$work/bundle/prod/$authoritative" ] || fail "authoritative dump named in the manifest is missing"
dumps=0
while IFS= read -r -d '' dump; do
  dumps=$((dumps + 1))
  [ -s "$dump" ] || fail "empty dump: $(basename "$dump")"
  [ "$(head -c 5 -- "$dump")" = "PGDMP" ] || fail "not a pg_dump custom archive: $(basename "$dump")"
  [ -f "$dump.yaml" ] || fail "dump has no sidecar: $(basename "$dump")"
done < <(find "$work/bundle/prod/runtime/backups/db" -maxdepth 1 -type f -name '*.backup' -print0)
[ "$dumps" -ge 1 ] || fail "no database dumps in the pulled archive"
if [ "$tier" = "daily" ]; then
  [ -n "$(ls -A "$work/bundle/prod/runtime/secrets" 2>/dev/null)" ] || fail "runtime/secrets is missing or empty in the pulled archive"
  [ -s "$work/bundle/prod/.env" ] || fail ".env is missing in the pulled archive"
fi

# --- host config (daily only) ---------------------------------------------------
if [ "$tier" = "daily" ]; then
  STAGE="host-config"
  for p in ${BK_HOST_PATHS:-}; do
    case "$p" in
      root/.config* | /root/.config*) fail "BK_HOST_PATHS must not include /root/.config (it holds rclone and key material)" ;;
    esac
  done
  # shellcheck disable=SC2086
  if ! tar -C / -cf - ${BK_HOST_PATHS:-} 2>"$work/host.err" | tar -xf - -C "$work/bundle/host"; then
    fail "host config archive failed: $(tr '\n' ' ' <"$work/host.err" | cut -c1-200)"
  fi
  [ -n "$(find "$work/bundle/host" -type f -print -quit)" ] || fail "host config archive is empty (check BK_HOST_PATHS)"
fi

# --- bundle + encrypt -----------------------------------------------------------
STAGE="encrypt"
( cd "$work/bundle" && find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 sha256sum >MANIFEST.sha256 )
tar -C "$work/bundle" -cf "$work/bundle.tar" . || fail "could not create the bundle"
bk_age_encrypt "$work/bundle.tar" "$work/$name" || fail "encryption failed"
bk_safe_rm_under "$work" "$work/bundle.tar"
bk_safe_rm_under "$work" "$work/pull.tar"
sha="$(sha256sum "$work/$name" | cut -d' ' -f1)"
size="$(stat -c %s "$work/$name")"

# --- SMB share --------------------------------------------------------------------
STAGE="smb"
bk_require_mounted "$BK_SMB_MOUNT" || fail "SMB share dropped before the write ($BK_SMB_MOUNT)"
mkdir -p "$BK_SMB_MOUNT/$prefix"
partial="$BK_SMB_MOUNT/$prefix/$name.partial"
cp -f -- "$work/$name" "$partial" || fail "copy to the SMB share failed"
bk_verify_copy "$work/$name" "$partial" || fail "SMB copy did not verify bit-exactly"
mv -f -- "$partial" "$BK_SMB_MOUNT/$prefix/$name"
partial=""

# --- OneDrive ---------------------------------------------------------------------
STAGE="upload"
rclone copyto "$work/$name" "$BK_RCLONE_REMOTE/$prefix/$name" || fail "upload to $BK_RCLONE_REMOTE failed"
STAGE="verify-transfer"
rclone "${BK_RCLONE_CHECK_CMD:-cryptcheck}" --one-way --include "/$name" "$work" "$BK_RCLONE_REMOTE/$prefix" || fail "the uploaded copy does not match (rclone ${BK_RCLONE_CHECK_CMD:-cryptcheck})"

# --- prune: only after BOTH copies are verified ------------------------------------
STAGE="prune"
bk_prune_daily_monthly "$BK_SMB_MOUNT/$prefix" "$prefix" "$keep_daily" "$keep_monthly" || fail "pruning the SMB copies failed"
bk_prune_remote "$BK_RCLONE_REMOTE/$prefix" "$prefix" "$keep_daily" "$keep_monthly" || fail "pruning the remote copies failed"

# --- record ------------------------------------------------------------------------
STAGE="record"
result_name="$name"
if [ -n "${BK_AUDIT_SHIP_DIR:-}" ]; then mkdir -p "$BK_AUDIT_SHIP_DIR" 2>/dev/null || true; fi
bk_audit_log run_ok "tier=$tier" "file=$name" "sha256=$sha" "size=$size" "dumps=$dumps" "authoritative=$authoritative"
bk_state_touch "$prefix"
bk_dead_man_ping || true
bk_log "$tier tier OK: $result_name ($size bytes, sha256 $sha)"
if [ "$notify_ok" -eq 1 ]; then
  bk_notify "r740 daily backup OK: $result_name ($((size / 1024 / 1024)) MB), restore point $authoritative"
fi
