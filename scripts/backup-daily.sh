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
  trap - ERR   # cleanup's own exit status (e.g. 130 after an abort) must not fire the error handler
  # whatever way the script ends (error, exit, signal), nothing it started may keep running
  bk_kill_children TERM
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

# Ctrl-C / Ctrl-Z / kill / hangup: stop whatever the job started (ssh pull, cp, rclone), remove
# partial files, exit. A deliberate Ctrl-C or Ctrl-Z by you is not an alert; a kill or timeout is.
abort_hook() {
  case "$1" in INT | TSTP) ;; *) report_failure "aborted by SIG$1 (timeout, shutdown or kill) at stage $STAGE" ;; esac
}
# shellcheck disable=SC2034  # read by bk_abort in backup-common.sh
BK_ABORT_HOOK=abort_hook
bk_install_abort_traps

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
: "${BK_STAGE_DIR:?}" "${BK_SMB_MOUNT:?}" "${BK_BACKUP_SSH:?}"
# OneDrive (rclone) is optional: with BK_RCLONE_REMOTE unset the share is the only target.
remote_on=0
[ -z "${BK_RCLONE_REMOTE:-}" ] || remote_on=1
# The desktop being asleep must not cost us the backup: SMB trouble is a degraded run (loud
# alert at the end). The encrypted archive is kept on this host (BK_LOCAL_KEEP_DIR, newest
# BK_LOCAL_KEEP_COUNT) and uploaded to the share by the next run that can reach it; OneDrive
# is still served. Set BK_LOCAL_KEEP_DIR= (empty) to turn the local copy off.
smb_err=""
smb_ok=0
keep_dir="${BK_LOCAL_KEEP_DIR-$BK_STATE_DIR/local-keep}"
keep_count="${BK_LOCAL_KEEP_COUNT:-7}"
[[ "$keep_count" =~ ^[0-9]+$ ]] && [ "$keep_count" -ge 1 ] || fail "BK_LOCAL_KEEP_COUNT must be a positive number"
kept=""
bk_require_mounted "$BK_SMB_MOUNT" || smb_err="SMB share not mounted at $BK_SMB_MOUNT"
if [ -n "$smb_err" ] && [ "$remote_on" -eq 0 ] && [ -z "$keep_dir" ]; then
  STAGE="smb"
  fail "$smb_err, and no other target or local copy is configured: nothing would be written"
fi
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
bk_ssh_opts_init
if ! bk_run_bg ssh "${BK_SSH_OPTS[@]}" -- "$BK_BACKUP_SSH" "$gate_verb $gate_max_age $gate_since" >"$work/pull.tar" 2>"$work/pull.err"; then
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
  # Normalise every path (no glob expansion) before judging it: "root", "/root",
  # "root/./.config" and "//root/.config" must not slip past a string match.
  host_paths=()
  read -r -a raw_paths <<<"${BK_HOST_PATHS:-}"
  for p in "${raw_paths[@]}"; do
    norm="$(realpath -m -- "/$p")"
    case "$norm" in
      / | /root | /root/.config | /root/.config/* | /root/.ssh | /root/.ssh/*)
        fail "BK_HOST_PATHS entry '$p' resolves to $norm; it would archive rclone/key/ssh material or the whole disk"
        ;;
    esac
    host_paths+=("${norm#/}")
  done
  if ! tar -C / -cf - -- "${host_paths[@]}" 2>"$work/host.err" | tar -xf - -C "$work/bundle/host"; then
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
smb_timeout="${BK_SMB_TIMEOUT_S:-3600}"
if [ -z "$smb_err" ]; then
  if ! bk_require_mounted "$BK_SMB_MOUNT"; then
    smb_err="SMB share dropped before the write ($BK_SMB_MOUNT)"
  elif ! timeout 30 mkdir -p "$BK_SMB_MOUNT/$prefix"; then
    smb_err="cannot create $BK_SMB_MOUNT/$prefix"
  else
    # a killed earlier run can leave a partial; we hold the lock, so none is live
    timeout 60 find "$BK_SMB_MOUNT/$prefix" -maxdepth 1 -type f -name '*.partial' -delete 2>/dev/null || true
    partial="$BK_SMB_MOUNT/$prefix/$name.partial"
    if ! bk_run_bg timeout "$smb_timeout" cp -f -- "$work/$name" "$partial"; then
      smb_err="copy to the SMB share failed"
    elif ! bk_run_bg timeout "$smb_timeout" bash -c '. "$1"; bk_verify_copy "$2" "$3"' _ "$here/backup-common.sh" "$work/$name" "$partial"; then
      smb_err="SMB copy did not verify bit-exactly"
    elif ! mv -f -- "$partial" "$BK_SMB_MOUNT/$prefix/$name"; then
      smb_err="could not finalise the SMB copy"
    else
      smb_ok=1
    fi
    [ -z "$partial" ] || rm -f -- "$partial" 2>/dev/null || true
    partial=""
  fi
fi
if [ -n "$smb_err" ]; then
  if [ -n "$keep_dir" ]; then
    STAGE="local-keep"
    # Only a bit-exact copy counts. Files here are age-encrypted, so keeping them is safe at rest.
    mkdir -p "$keep_dir" && chmod 700 "$keep_dir" || fail "$smb_err, and the local keep directory $keep_dir cannot be created"
    if cp -f -- "$work/$name" "$keep_dir/$name.partial" && cmp -s -- "$work/$name" "$keep_dir/$name.partial" && mv -f -- "$keep_dir/$name.partial" "$keep_dir/$name"; then
      kept="$keep_dir/$name"
      bk_prune_keep_newest "$keep_dir" "$prefix" "$keep_count" || bk_log "prune of the local keep directory failed (ignored)"
    else
      rm -f -- "$keep_dir/$name.partial" 2>/dev/null || true
      [ "$remote_on" -eq 1 ] || fail "$smb_err, and the local copy could not be written to $keep_dir: no backup was saved anywhere"
      bk_log "local copy to $keep_dir failed (continuing to OneDrive)"
    fi
    STAGE="smb"
  elif [ "$remote_on" -eq 0 ]; then
    fail "$smb_err (and no other target is configured, so no backup was written)"
  fi
  bk_log "SMB copy failed: $smb_err"
fi

# The share is reachable again: send up what earlier runs had to keep here (name not on the share yet).
if [ "$smb_ok" -eq 1 ] && [ -n "$keep_dir" ] && [ -d "$keep_dir" ]; then
  for old in "$keep_dir/$prefix"-*.tar.age; do
    [ -f "$old" ] || continue
    [ ! -e "$BK_SMB_MOUNT/$prefix/$(basename "$old")" ] || { rm -f -- "$old"; continue; }
    p2="$BK_SMB_MOUNT/$prefix/$(basename "$old").partial"
    if timeout "$smb_timeout" cp -f -- "$old" "$p2" && cmp -s -- "$old" "$p2" && mv -f -- "$p2" "$BK_SMB_MOUNT/$prefix/$(basename "$old")"; then
      rm -f -- "$old"
      bk_log "uploaded the kept local copy $(basename "$old") to the share"
    else
      rm -f -- "$p2" 2>/dev/null || true
      bk_log "could not upload the kept local copy $(basename "$old") yet; it stays here and is retried next run"
    fi
  done
fi

if [ "$remote_on" -eq 1 ]; then
  # --- OneDrive ---------------------------------------------------------------------
  STAGE="upload"
  rclone_timeout="${BK_RCLONE_TIMEOUT_S:-5400}"
  bk_run_bg timeout "$rclone_timeout" rclone copyto "$work/$name" "$BK_RCLONE_REMOTE/$prefix/$name" --transfers 2 --timeout 120s --contimeout 30s --bwlimit "${BK_RCLONE_BWLIMIT:-8M}" || fail "upload to $BK_RCLONE_REMOTE failed"
  STAGE="verify-transfer"
  bk_run_bg timeout "$rclone_timeout" rclone "${BK_RCLONE_CHECK_CMD:-cryptcheck}" --one-way --include "/$name" "$work" "$BK_RCLONE_REMOTE/$prefix" || fail "the uploaded copy does not match (rclone ${BK_RCLONE_CHECK_CMD:-cryptcheck})"
fi

# --- prune: each target only after ITS OWN new copy is verified ----------------------
STAGE="prune"
if [ "$smb_ok" -eq 1 ]; then
  bk_prune_daily_monthly "$BK_SMB_MOUNT/$prefix" "$prefix" "$keep_daily" "$keep_monthly" || fail "pruning the SMB copies failed"
fi
if [ "$remote_on" -eq 1 ]; then
  bk_prune_remote "$BK_RCLONE_REMOTE/$prefix" "$prefix" "$keep_daily" "$keep_monthly" || fail "pruning the remote copies failed"
fi

# --- record ------------------------------------------------------------------------
STAGE="record"
result_name="$name"
if [ -n "${BK_AUDIT_SHIP_DIR:-}" ]; then mkdir -p "$BK_AUDIT_SHIP_DIR" 2>/dev/null || true; fi
if [ -n "$smb_err" ]; then
  bk_audit_log run_degraded "tier=$tier" "file=$name" "sha256=$sha" "size=$size" "smb_error=$smb_err" "local_copy=${kept:-none}" "onedrive=$remote_on"
  STAGE="smb"
  where=""
  [ -z "$kept" ] || where="kept on this host at $kept (uploaded to the desktop automatically on the next run that can reach it)"
  [ "$remote_on" -eq 0 ] || where="${where:+$where; }the OneDrive copy is verified"
  fail "OFF-SITE SAVE TO THE DESKTOP FAILED for $name: $smb_err. $where"
fi
bk_audit_log run_ok "tier=$tier" "file=$name" "sha256=$sha" "size=$size" "dumps=$dumps" "authoritative=$authoritative"
bk_state_touch "$prefix"
bk_dead_man_ping || true
bk_log "$tier tier OK: $result_name ($size bytes, sha256 $sha)"
if [ "$notify_ok" -eq 1 ]; then
  bk_notify "r740 daily backup OK: $result_name ($((size / 1024 / 1024)) MB), restore point $authoritative"
fi
