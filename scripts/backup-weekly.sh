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
# RUN THIS: on the Proxmox host as root, Tuesday 05:00 from r740-backup-weekly.timer.
# Set BK_WEEKLY_FORCE=1 for a manual, watched run outside the window (the
# hard-stop timeout then comes from BK_WEEKLY_FORCE_MINUTES, default 180; tests
# use BK_WEEKLY_FORCE_SECONDS and BK_MIN_REMAINING_S).
#
# Speed: vzdump's --bwlimit caps the rate it READS the source disk (uncompressed), not the output.
# Measured on this host (2026-09-30): 50 MiB/s of reads gave only ~12 MB/s of compressed output
# (about 4:1), i.e. ~1.7 h per 300 GB disk; uncapped it reaches ~250 MB/s of reads / 66 MB/s of
# output, where zstd and the share's write speed become the limits. Default: 150 MiB/s
# (BK_VZDUMP_BWLIMIT_KIB=153600); lower it if game latency suffers during a watched run.
#
# Safety guard (--guard, or BK_WEEKLY_GUARD=1 in the config): for UNATTENDED runs. It refuses to
# start unless the game is READY and the host is calm, and while the job runs it stops it cleanly
# (the same abort as Ctrl-C) if the game or the host looks stressed for several samples in a row.
# See scripts/backup-guard.sh.
#
# Announcements (--announce, or BK_WEEKLY_ANNOUNCE=1): for runs that include a guest listed in
# BK_ANNOUNCE_GUESTS (default 101, the game VM). In-game Server Broadcast banners: a warning 30, 15, 5
# and 1 minute before the start (the job waits that long first), a notice when it starts and every
# 30 minutes while it runs, and a closing message (sealed / halted / postponed). Best-effort: never
# fails the backup. Needs the console API key; see scripts/backup-announce.sh.
#
# Options:  --announce         in-game warnings and notices (see above)
#           --guard            enable the safety guard (see above)
#           --progress (-p)    print a status line every BK_WEEKLY_PROGRESS_S (default 10)
#                              seconds: bytes written, rate, elapsed, vzdump's own percent
#           --verbose (-v)     also show vzdump's log lines and each stage (read-back etc.)
#                              (use both together for the full picture)
#           --only "104 103"   image just these guests (each must be in BK_VMIDS); used to
#                              stage a first run. A partial run never records weekly
#                              success and never sends the heartbeat.
# =============================================================================
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
. "$here/backup-common.sh"

orig_args="$*"
only=""
progress=0
verbose=0
guard=0
announce=0
usage() { echo "usage: $0 [--announce] [--guard] [--progress] [--verbose] [--only \"ID ID\"]" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --only) only="${2:-}"; [ -n "$only" ] || usage; shift 2 ;;
    --announce) announce=1; shift ;;
    --guard) guard=1; shift ;;
    --progress | -p) progress=1; shift ;;
    --verbose | -v) verbose=1; shift ;;
    *) usage ;;
  esac
done

BK_JOB="backup weekly images"
export BK_JOB
bk_secure_umask
bk_load_config

[ "${BK_WEEKLY_GUARD:-0}" != "1" ] || guard=1
[ "${BK_WEEKLY_ANNOUNCE:-0}" != "1" ] || announce=1
subset_run=0
if [ -n "$only" ]; then
  for want in $only; do
    [[ "$want" =~ ^[0-9]+$ ]] && [[ " $BK_VMIDS " == *" $want "* ]] || { echo "backup-weekly: --only guest '$want' is not in BK_VMIDS ($BK_VMIDS)" >&2; exit 2; }
  done
  BK_VMIDS="$only"
  subset_run=1
fi

STAGE="preflight"
RERUN="bash $here/backup-weekly.sh --progress${only:+ --only \"$only\"}"
alerted=0
main_pid=$$
partial=""
tmpdir=""

cleanup() {
  trap - ERR   # cleanup's own exit status (e.g. 130 after an abort) must not fire the error handler
  # whatever way the script ends (error, exit, signal), nothing it started may keep running
  bk_kill_children TERM
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
fail() { plog "FAILED at $STAGE: $*"; report_failure "$*"; announce_close halted; exit 1; }

# Ctrl-C / Ctrl-Z / kill / hangup: stop the whole pipeline (releasing the guest backup), remove
# the partial file, exit. A deliberate Ctrl-C or Ctrl-Z by you is not an alert; a kill or a
# timeout from outside is.
# --- in-game announcements: state and the closing message --------------------------------------------
announce_on=0        # this run announces (flag set and a guest in BK_ANNOUNCE_GUESTS is being imaged)
announce_open=0      # players have been told something that still needs a closing message
announce_started=0   # the backup itself has begun
ann_pid=""
announce_close() { # done|halted
  [ "$announce_on" -eq 1 ] && [ "$announce_open" -eq 1 ] || return 0
  announce_open=0
  [ -z "$ann_pid" ] || kill "$ann_pid" 2>/dev/null || true
  if [ "$1" = "done" ]; then bk_announce "done"
  elif [ "$announce_started" -eq 1 ]; then bk_announce halted
  else bk_announce postponed
  fi
  plog "announce: closing message sent (${1}${announce_started:+, started=$announce_started})" >/dev/null
}
wait_until() { # epoch: sleep (interruptibly) until then
  local target="$1" now left chunk
  while now="$(date +%s)"; [ "$now" -lt "$target" ]; do
    left=$((target - now))
    chunk="${BK_ANNOUNCE_WAIT_CHUNK_S:-5}"
    sleep "$((left > chunk ? chunk : left))" &
    wait "$!"
  done
}

guard_reason="$BK_STATE_DIR/weekly-guard.reason"
abort_hook() {
  announce_close halted
  printf '%s aborted by SIG%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"$progress_log" 2>/dev/null || true
  if [ -s "$guard_reason" ]; then
    plog "STOPPED by the safety guard to protect the game: $(cat "$guard_reason")" >/dev/null
    report_failure "stopped by the safety guard to protect the game: $(cat "$guard_reason")"
    return 0
  fi
  case "$1" in INT | TSTP) ;; *) report_failure "aborted by SIG$1 (timeout, shutdown or kill) while imaging $STAGE" ;; esac
}
# shellcheck disable=SC2034  # read by bk_abort in backup-common.sh
BK_ABORT_HOOK=abort_hook
bk_install_abort_traps

bk_lock backup-weekly || exit 1

# Every progress line is also appended to a log file that anyone can follow with
#   tail -f /var/lib/r740-backup/weekly-progress.log
# (and that backup-status.sh shows). Truncated at the start of each run, by the lock holder only.
progress_log="$BK_STATE_DIR/weekly-progress.log"
mkdir -p "$BK_STATE_DIR" 2>/dev/null || true
printf '# weekly image run started %s, arguments: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$orig_args" >"$progress_log" 2>/dev/null || true
plog() { # message: print like bk_log AND append to the progress log
  local l
  l="$(bk_log "$*")"
  printf '%s\n' "$l"
  printf '%s\n' "$l" >>"$progress_log" 2>/dev/null || true
}

: "${BK_SMB_MOUNT:?}" "${BK_VMIDS:?}"
case "${BK_AGE_RECIPIENT:-}" in age1*) ;; *) fail "no age recipient configured (run backup-key.sh generate)" ;; esac

# --- window and hard stop ---------------------------------------------------------
now="${BK_WEEKLY_NOW_EPOCH:-$(date +%s)}"
if [ "${BK_WEEKLY_FORCE:-0}" = "1" ]; then
  hard_stop=$((now + ${BK_WEEKLY_FORCE_SECONDS:-$((${BK_WEEKLY_FORCE_MINUTES:-180} * 60))}))
else
  today="$(date -d "@$now" +%Y-%m-%d)"
  win_start="$(date -d "$today ${BK_WEEKLY_WINDOW_START:-05:00}" +%s)"
  hard_stop="$(date -d "$today ${BK_WEEKLY_HARD_STOP:-07:30}" +%s)"
  if [ "$now" -lt "$win_start" ] || [ "$now" -ge "$hard_stop" ]; then
    fail "outside the maintenance window (${BK_WEEKLY_WINDOW_START:-05:00}-${BK_WEEKLY_HARD_STOP:-07:30}); use BK_WEEKLY_FORCE=1 for a watched manual run"
  fi
fi

bk_require_mounted "$BK_SMB_MOUNT" || fail "DESKTOP COPY FAILED: the desktop share is not mounted at $BK_SMB_MOUNT (is the desktop asleep?). No weekly image was taken and none is kept locally (they are too large); the previous weekly images on the share are untouched. Re-run once the desktop is back."

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

hsize() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 B"; }
hms() { printf '%02d:%02d:%02d' $(($1 / 3600)) $(($1 % 3600 / 60)) $(($1 % 60)); }
progress_s="${BK_WEEKLY_PROGRESS_S:-10}"

# sha256 of a file just written, printing progress while it reads (a 100 GB read-back is silent
# for a long time otherwise). Reads /proc/<pid>/io for bytes read so far.
readback_sha() { # file total_bytes
  local f="$1" total="$2" me="$BASHPID" pid t0 n r ddp
  # Read in 4 MB blocks (measured 2026-09-30 on a 3.5 GB image: 71.5 MB/s vs 41.7 MB/s for plain
  # sha256sum, identical hash) as a background job + wait, so an abort during the (long) read-back
  # is immediate.
  bk_prepare_honest_read "$f"   # flush + evict (verified) so this reads the desktop's copy
  dd if="$f" bs=4M "${BK_HONEST_READ[@]}" status=none 2>/dev/null | sha256sum >"$tmpdir/post.sha" &
  pid=$!
  if [ "$progress" -eq 0 ]; then
    wait "$pid" || true
    cut -d' ' -f1 <"$tmpdir/post.sha"
    return
  fi
  t0="$(date +%s)"
  while kill -0 "$pid" 2>/dev/null; do
    for _ in $(seq 1 "$progress_s"); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -0 "$pid" 2>/dev/null || break
    ddp="$(pgrep -P "$me" -x dd 2>/dev/null | head -n 1 || true)"
    r="$(awk '/^rchar:/ { print $2 }' "/proc/${ddp:-0}/io" 2>/dev/null || true)"
    n=$(($(date +%s) - t0))
    plog "guest $id: read-back $(hms "$n") elapsed, $(hsize "${r:-0}") of $(hsize "$total") ($((${r:-0} * 100 / (total > 0 ? total : 1)))%)" >&2
  done
  wait "$pid" || true
  cut -d' ' -f1 <"$tmpdir/post.sha"
}

gate_ssh() { # request
  bk_ssh_opts_init
  bk_run_bg timeout "${BK_GATE_TIMEOUT_S:-900}" ssh "${BK_SSH_OPTS[@]}" -- "$BK_BACKUP_SSH" "$1"
}

failures=()
successes=()
pipe_pid=""

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
  g_start="$(date +%s)"
  plog "guest $id ($kind): starting -> $(basename "$out")"
  [ "$progress" -eq 0 ] || plog "guest $id: progress lines every ${progress_s}s (the first appears after that long)"
  [ "$verbose" -eq 0 ] || plog "guest $id: keeping $keep images; window ends in $(hms "$remaining"); a snapshot backup runs while the guest stays up"
  rm -f -- "$partial" "$tmpdir/sha.pre"
  bk_require_mounted "$BK_SMB_MOUNT" || { failures+=("$id: DESKTOP COPY FAILED, the desktop share dropped before the image started (is the desktop asleep?); no local copy is kept for weekly images"); partial=""; return 1; }

  # A snapshot backup makes guest writes wait on the sink, so a hung share must never be
  # allowed to hold the live guest: the pipeline runs as its own process group and a
  # watchdog aborts it when the output stops growing.
  stalled=0
  # Write in 4 MB blocks through dd. Measured 2026-09-30: tee's small writes gave 25.8 MB/s on a
  # cache=none mount; on the default cache=strict mount dd 4 MB writes with oflag=nocache reach
  # ~115 MB/s (the 1 Gb line rate) while keeping dirty memory at ~3 MiB (without nocache a 4 GiB
  # write left 4 GiB dirty and stalled at the final flush). conv=fdatasync flushes at the end.
  # Do NOT add oflag=direct: it fails on the last (unaligned) block with EINVAL.
  # vzdump always logs (to $tmpdir/vzdump.err, one line per 1%): the stall watchdog below needs it
  # as a sign of life, because a long stretch of EMPTY disk produces no output at all (measured
  # 2026-09-30 on a 300 GB guest: `write: 195 B/s` while reading at 150 MiB/s).
  qopt=()
  log_off=0
  # vzdump alone runs with umask 022: under this script's umask 077 it creates a 0700 temp
  # directory that a container backup's unprivileged tar (lxc-usernsexec) cannot open
  # ("tar: ...vzdump-lxc-N.tmp: Cannot open: Permission denied", exit 255). Everything this
  # script writes itself (the encrypted image) stays 0600.
  set -m
  (
    set -o pipefail
    timeout "$remaining" ionice -c3 nice -n 19 \
      bash -c 'umask 022; exec vzdump "$@"' vzdump "$id" --mode snapshot --compress zstd --stdout --bwlimit "${BK_VZDUMP_BWLIMIT_KIB:-153600}" "${qopt[@]}" 2>"$tmpdir/vzdump.err" \
      | age -r "$BK_AGE_RECIPIENT" \
      | tee >(sha256sum | cut -d' ' -f1 >"$tmpdir/sha.pre") \
      | dd of="$partial" bs=4M iflag=fullblock oflag=nocache conv=fdatasync status=none
  ) &
  pipe_pid=$!
  last_size=-1
  last_change="$(date +%s)"
  tick=0
  prev_size=0
  poll="${BK_WEEKLY_STALL_POLL_S:-15}"
  while kill -0 "$pipe_pid" 2>/dev/null; do
    for _ in $(seq 1 "$poll"); do
      kill -0 "$pipe_pid" 2>/dev/null || break
      sleep 1
      tick=$((tick + 1))
      if [ "$progress" -eq 1 ] && [ $((tick % progress_s)) -eq 0 ]; then
        now_s="$(date +%s)"
        sz="$(stat -c %s -- "$partial" 2>/dev/null || echo 0)"
        rate=$(((sz - prev_size) / progress_s)); prev_size="$sz"
        pct="$(grep -oE 'INFO: +[0-9]+% \([^)]*\)' "$tmpdir/vzdump.err" 2>/dev/null | tail -n 1 | sed -E 's/^INFO: +//' || true)"
        plog "guest $id: $(hms $((now_s - g_start))) elapsed, $(hsize "$sz") written, $(hsize "$rate")/s${pct:+, vzdump $pct}"
      fi
      if [ "$verbose" -eq 1 ] && [ $((tick % progress_s)) -eq 0 ] && [ -s "$tmpdir/vzdump.err" ]; then
        tail -c +$((log_off + 1)) "$tmpdir/vzdump.err" 2>/dev/null | sed 's/^/    vzdump: /' | bk_redact || true
        log_off="$(stat -c %s -- "$tmpdir/vzdump.err" 2>/dev/null || echo "$log_off")"
      fi
    done
    kill -0 "$pipe_pid" 2>/dev/null || break
    # Alive = the output file grew OR vzdump logged something. A genuinely hung share stops both
    # (vzdump blocks on its write), a long empty stretch of disk stops only the first.
    cur_size="$(stat -c %s -- "$partial" 2>/dev/null || echo 0):$(stat -c %s -- "$tmpdir/vzdump.err" 2>/dev/null || echo 0)"
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
  pipe_pid=""
  set +m
  if [ "$stalled" -eq 1 ]; then
    rm -f -- "$partial"; partial=""
    failures+=("$id: output stalled for ${BK_WEEKLY_STALL_S:-300}s (share or network hung); aborted so the live guest is not held")
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f -- "$partial"; partial=""
    failures+=("$id: vzdump/encrypt/write failed (exit $rc). Last lines of vzdump's log: $(tail -n 6 "$tmpdir/vzdump.err" | tr '\n' '|' | cut -c1-500)")
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
    [ "$verbose" -eq 0 ] && [ "$progress" -eq 0 ] || plog "guest $id: verifying the written file by reading it back ($(hsize "$bytes")); this takes about as long as the write"
    post_sha="$(readback_sha "$partial" "$bytes")"
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
  g_secs=$(($(date +%s) - g_start))
  plog "guest $id: OK, $(hsize "$bytes") in $(hms "$g_secs") ($(hsize $((bytes / (g_secs > 0 ? g_secs : 1))))/s average)"
  return 0
}

read -r -a guest_list <<<"$BK_VMIDS"
if [ "$announce" -eq 1 ]; then
  for g in "${guest_list[@]}"; do
    case " ${BK_ANNOUNCE_GUESTS:-101} " in *" $g "*) announce_on=1 ;; esac
  done
fi

rm -f -- "$guard_reason" 2>/dev/null || true

# Countdown: warnings 30/15/5/1 minute before the start. The job waits for the whole lead time first
# (BK_ANNOUNCE_SECS_PER_MIN is a test hook), so it can be started at T-30 minutes by a timer.
if [ "$announce_on" -eq 1 ]; then
  STAGE="announce-countdown"
  spm="${BK_ANNOUNCE_SECS_PER_MIN:-60}"
  read -r -a lead <<<"${BK_ANNOUNCE_LEAD_MINUTES:-30 15 5 1}"
  bk_announce_configured || plog "announce: not configured; the countdown still runs, silently"
  t0=$(($(date +%s) + lead[0] * spm))
  announce_open=1
  for m in "${lead[@]}"; do
    wait_until "$((t0 - m * spm))"
    plog "announce: warning, $m minute(s) before the start"
    bk_announce lead "$m"
  done
  wait_until "$t0"
  hard_stop=$((hard_stop + lead[0] * spm))
fi

if [ "$guard" -eq 1 ]; then
  STAGE="guard-precheck"
  if ! pre="$(bash "$here/backup-guard.sh" --once)"; then
    fail "not starting: the safety guard sees a problem right now: $pre"
  fi
  plog "guard: pre-check OK; watching the game and the host while the job runs"
  bash "$here/backup-guard.sh" --target "$$" --reason-file "$guard_reason" \
    --interval "${BK_GUARD_INTERVAL_S:-10}" --consecutive "${BK_GUARD_CONSECUTIVE:-3}" >>"$progress_log" 2>&1 &
fi

if [ "$announce_on" -eq 1 ]; then
  announce_started=1
  announce_open=1
  plog "announce: the backup starts now"
  bk_announce start
  (
    n=0
    while true; do
      sleep "$(( ${BK_ANNOUNCE_EVERY_MIN:-30} * ${BK_ANNOUNCE_SECS_PER_MIN:-60} ))" &
      wait "$!"
      n=$((n + 1))
      bk_announce ongoing "$((n * ${BK_ANNOUNCE_EVERY_MIN:-30}))"
    done
  ) &
  ann_pid=$!
fi
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
announce_close "done"
if [ "$subset_run" -eq 0 ]; then
  bk_state_touch weekly
  bk_dead_man_ping || true
fi
plog "weekly images OK: ${successes[*]}"
bk_notify "r740 weekly backup OK: images for ${successes[*]}"
