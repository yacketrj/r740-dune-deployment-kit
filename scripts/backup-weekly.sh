#!/usr/bin/env bash
# =============================================================================
# backup-weekly.sh -- weekly full VM/CT images (design v2, themes T3/T5/T6).
#
# Each guest is streamed  vzdump --stdout | age -r <PUBLIC recipient> | SMB
# so no plaintext image and no staging copy ever exists. The live game shares
# one rotational disk with this job, so the run is confined to a maintenance
# window with a hard stop, throttled (ionice/nice/bwlimit), and preceded by a
# thin-pool headroom check. One guest failing never stops the others, but the
# run only counts as a success (state, dead-man ping) if every guest succeeded.
#
# RUN THIS: on the Proxmox host as root, Sunday 01:00 from r740-backup-weekly.timer.
# Set BK_WEEKLY_FORCE=1 for a manual, watched run outside the window (the
# hard-stop timeout then comes from BK_WEEKLY_FORCE_MINUTES, default 180; tests
# use BK_WEEKLY_FORCE_SECONDS and BK_MIN_REMAINING_S).
#
# Options:  --only "104 103"   image just these guests (each must be in BK_VMIDS); used to
#                              stage a first run. A partial run never records weekly
#                              success and never sends the heartbeat.
# =============================================================================
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
. "$here/backup-common.sh"

only=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --only) only="${2:-}"; [ -n "$only" ] || { echo "usage: $0 [--only \"ID ID\"]" >&2; exit 2; }; shift 2 ;;
    *) echo "usage: $0 [--only \"ID ID\"]" >&2; exit 2 ;;
  esac
done

BK_JOB="backup weekly images"
export BK_JOB
bk_secure_umask
bk_load_config

subset_run=0
if [ -n "$only" ]; then
  for want in $only; do
    [[ "$want" =~ ^[0-9]+$ ]] && [[ " $BK_VMIDS " == *" $want "* ]] || { echo "backup-weekly: --only guest '$want' is not in BK_VMIDS ($BK_VMIDS)" >&2; exit 2; }
  done
  BK_VMIDS="$only"
  subset_run=1
fi

STAGE="preflight"
RERUN="bash $here/backup-weekly.sh${only:+ --only \"$only\"}"
alerted=0
main_pid=$$
partial=""
tmpdir=""

cleanup() {
  [ -z "$partial" ] || rm -f -- "$partial"
  [ -z "$tmpdir" ] || bk_safe_rm_under "${TMPDIR:-/var/tmp}" "$tmpdir" || true
}
trap cleanup EXIT

report_failure() {
  if [ "$alerted" -eq 0 ]; then
    alerted=1
    bk_audit_log run_failed "tier=weekly" "stage=$STAGE" "error=$1"
    bk_alert "$STAGE" "$1" "$RERUN"
    bk_dead_man_ping fail || true
  fi
}
on_err() {
  local line="$1"
  trap - ERR
  if [ "$BASHPID" = "$main_pid" ]; then report_failure "unexpected error at line $line"; fi
  exit 1
}
trap 'on_err $LINENO' ERR
fail() { bk_log "FAILED at $STAGE: $*"; report_failure "$*"; exit 1; }

bk_lock backup-weekly || exit 1

: "${BK_SMB_MOUNT:?}" "${BK_VMIDS:?}"
case "${BK_AGE_RECIPIENT:-}" in age1*) ;; *) fail "no age recipient configured (run backup-key.sh generate)" ;; esac

# --- window and hard stop ---------------------------------------------------------
now="${BK_WEEKLY_NOW_EPOCH:-$(date +%s)}"
if [ "${BK_WEEKLY_FORCE:-0}" = "1" ]; then
  hard_stop=$((now + ${BK_WEEKLY_FORCE_SECONDS:-$((${BK_WEEKLY_FORCE_MINUTES:-180} * 60))}))
else
  today="$(date -d "@$now" +%Y-%m-%d)"
  win_start="$(date -d "$today ${BK_WEEKLY_WINDOW_START:-01:00}" +%s)"
  hard_stop="$(date -d "$today ${BK_WEEKLY_HARD_STOP:-04:15}" +%s)"
  if [ "$now" -lt "$win_start" ] || [ "$now" -ge "$hard_stop" ]; then
    fail "outside the maintenance window (${BK_WEEKLY_WINDOW_START:-01:00}-${BK_WEEKLY_HARD_STOP:-04:15}); use BK_WEEKLY_FORCE=1 for a watched manual run"
  fi
fi

bk_require_mounted "$BK_SMB_MOUNT" || fail "SMB share not mounted at $BK_SMB_MOUNT"

# --- thin-pool headroom (snapshot copy-on-write grows the pool while the game writes) ---
pool="${BK_THIN_POOL:-pve/data}"
if pool_line="$(lvs --noheadings --nosuffix --units g -o lv_size,data_percent "$pool" 2>/dev/null)" && [ -n "$pool_line" ]; then
  read -r pool_size pool_pct <<<"$pool_line"
  pool_free="$(awk -v s="$pool_size" -v p="$pool_pct" 'BEGIN { printf "%d", s * (100 - p) / 100 }')"
  if [ "$pool_free" -lt "${BK_MIN_POOL_FREE_GB:-150}" ]; then
    fail "thin pool $pool has only ${pool_free}GB free (need ${BK_MIN_POOL_FREE_GB:-150}GB)"
  fi
  if awk -v p="$pool_pct" -v m="${BK_MAX_POOL_PCT:-80}" 'BEGIN { exit !(p + 0 > m + 0) }'; then
    fail "thin pool $pool is ${pool_pct}% full (limit ${BK_MAX_POOL_PCT:-80}%)"
  fi
else
  fail "cannot read thin pool usage for $pool"
fi

stamp="$(date -u +%Y%m%d-%H%M%S)"
mkdir -p "$BK_SMB_MOUNT/vm"
# A killed earlier run can leave a huge .partial; we hold the lock, so none is live.
find "$BK_SMB_MOUNT/vm" -maxdepth 1 -type f -name '*.partial' -delete 2>/dev/null || true
tmpdir="$(mktemp -d "${TMPDIR:-/var/tmp}/backup-weekly.XXXXXX")"

# Signal the pipeline's subshell group AND each child's own group: `timeout` moves its
# command into a separate process group, which a plain group kill would miss.
stop_pipeline() { # signal pid
  local sig="$1" pid="$2" c
  for c in $(pgrep -P "$pid" 2>/dev/null || true); do
    kill "-$sig" -- "-$c" 2>/dev/null || true
    kill "-$sig" "$c" 2>/dev/null || true
  done
  kill "-$sig" -- "-$pid" 2>/dev/null || true
}

gate_ssh() { # request
  bk_ssh_opts_init
  timeout "${BK_GATE_TIMEOUT_S:-900}" ssh "${BK_SSH_OPTS[@]}" -- "$BK_BACKUP_SSH" "$1"
}

failures=()
successes=()

backup_one() { # id ; returns 0 ok, 1 failed (already recorded in failures)
  local id="$1" kind ext keep_var keep out final pre_sha post_sha bytes remaining rc
  STAGE="guest-$id"
  if ! bk_valid_vmid "$id"; then failures+=("$id: invalid id"); return 1; fi
  if qm status "$id" >/dev/null 2>&1; then kind="vm"; ext="vma.zst"
  elif pct status "$id" >/dev/null 2>&1; then kind="ct"; ext="tar.zst"
  else failures+=("$id: no such VM or container"); return 1; fi

  keep_var="BK_KEEP_WEEKLY_$id"
  keep="${!keep_var:-${BK_KEEP_WEEKLY_DEFAULT:-3}}"

  if [ "$id" = "${BK_PROD_VMID:-101}" ] && [ -n "${BK_BACKUP_SSH:-}" ]; then
    # A known-good logical dump inside the image (the image alone is only crash-consistent).
    if ! gate_ssh "dump-now" >/dev/null 2>"$tmpdir/dump.err"; then
      bk_notify "r740 weekly warning: could not take a fresh database dump before imaging $id ($(tr '\n' ' ' <"$tmpdir/dump.err" | cut -c1-160)); the image is crash-consistent only"
    fi
  fi
  if [ "$kind" = "vm" ] && ! qm agent "$id" ping >/dev/null 2>&1; then
    bk_notify "r740 weekly warning: guest agent not running in VM $id; its image is crash-consistent (no filesystem freeze)"
  fi

  remaining=$((hard_stop - $(date +%s)))
  if [ "$remaining" -le "${BK_MIN_REMAINING_S:-60}" ]; then failures+=("$id: no time left before the hard stop"); return 1; fi

  out="$BK_SMB_MOUNT/vm/${kind}${id}-${stamp}.${ext}.age"
  partial="$out.partial"
  rm -f -- "$partial" "$tmpdir/sha.pre"
  bk_require_mounted "$BK_SMB_MOUNT" || { failures+=("$id: SMB share dropped"); partial=""; return 1; }

  # A snapshot backup makes guest writes wait on the sink, so a hung share must never be
  # allowed to hold the live guest: the pipeline runs as its own process group and a
  # watchdog aborts it when the output stops growing.
  stalled=0
  set -m
  (
    set -o pipefail
    timeout "$remaining" ionice -c3 nice -n 19 \
      vzdump "$id" --mode snapshot --compress zstd --stdout --bwlimit "${BK_VZDUMP_BWLIMIT_KIB:-51200}" --quiet 1 2>"$tmpdir/vzdump.err" \
      | age -r "$BK_AGE_RECIPIENT" \
      | tee >(sha256sum | cut -d' ' -f1 >"$tmpdir/sha.pre") >"$partial"
  ) &
  pipe_pid=$!
  last_size=-1
  last_change="$(date +%s)"
  while kill -0 "$pipe_pid" 2>/dev/null; do
    for _ in $(seq 1 "${BK_WEEKLY_STALL_POLL_S:-15}"); do
      kill -0 "$pipe_pid" 2>/dev/null || break
      sleep 1
    done
    kill -0 "$pipe_pid" 2>/dev/null || break
    cur_size="$(stat -c %s -- "$partial" 2>/dev/null || echo 0)"
    if [ "$cur_size" != "$last_size" ]; then
      last_size="$cur_size"
      last_change="$(date +%s)"
    elif [ $(( $(date +%s) - last_change )) -ge "${BK_WEEKLY_STALL_S:-300}" ]; then
      stalled=1
      stop_pipeline TERM "$pipe_pid"
      sleep "${BK_WEEKLY_KILL_GRACE_S:-20}"
      stop_pipeline KILL "$pipe_pid"
      break
    fi
  done
  if wait "$pipe_pid" 2>/dev/null; then rc=0; else rc=$?; fi
  set +m
  if [ "$stalled" -eq 1 ]; then
    rm -f -- "$partial"; partial=""
    failures+=("$id: output stalled for ${BK_WEEKLY_STALL_S:-300}s (share or network hung); aborted so the live guest is not held")
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f -- "$partial"; partial=""
    failures+=("$id: vzdump/encrypt/write failed (exit $rc): $(tr '\n' ' ' <"$tmpdir/vzdump.err" | cut -c1-200)")
    return 1
  fi
  # the on-the-fly hash is written by a process substitution; wait for it
  for _ in $(seq 1 60); do [ -s "$tmpdir/sha.pre" ] && break; sleep 0.5; done
  pre_sha="$(cat "$tmpdir/sha.pre" 2>/dev/null || true)"
  bytes="$(stat -c %s -- "$partial")"
  if [ -z "$pre_sha" ] || [ "$bytes" -lt "${BK_MIN_IMAGE_BYTES:-1024}" ]; then
    rm -f -- "$partial"; partial=""
    failures+=("$id: image is empty or unhashed ($bytes bytes)")
    return 1
  fi
  if [ "$(head -c 21 -- "$partial")" != "age-encryption.org/v1" ]; then
    rm -f -- "$partial"; partial=""
    failures+=("$id: output is not an age file")
    return 1
  fi
  if [ "${BK_WEEKLY_READBACK:-1}" = "1" ]; then
    post_sha="$(sha256sum -- "$partial" | cut -d' ' -f1)"
    if [ "$post_sha" != "$pre_sha" ]; then
      rm -f -- "$partial"; partial=""
      failures+=("$id: read-back hash differs from the streamed hash")
      return 1
    fi
  fi
  final="$out"
  mv -f -- "$partial" "$final"
  partial=""
  bk_prune_keep_newest "$BK_SMB_MOUNT/vm" "${kind}${id}" "$keep" || bk_log "prune for $id failed (ignored)"
  bk_audit_log image_ok "guest=$id" "file=$(basename "$final")" "sha256=$pre_sha" "size=$bytes" "kind=$kind"
  successes+=("$id")
  return 0
}

read -r -a guest_list <<<"$BK_VMIDS"
for idx in "${!guest_list[@]}"; do
  backup_one "${guest_list[$idx]}" || true
  # a later guest must never start after the hard stop
  if [ "$(date +%s)" -ge "$hard_stop" ] && [ $((idx + 1)) -lt "${#guest_list[@]}" ]; then
    failures+=("hard stop reached; not started: ${guest_list[*]:$((idx + 1))}")
    break
  fi
done

STAGE="summary"
if [ "${#failures[@]}" -gt 0 ]; then
  fail "guests failed: ${failures[*]}"
fi
if [ "$subset_run" -eq 0 ]; then
  bk_state_touch weekly
  bk_dead_man_ping || true
fi
bk_log "weekly images OK: ${successes[*]}"
bk_notify "r740 weekly backup OK: images for ${successes[*]}"
