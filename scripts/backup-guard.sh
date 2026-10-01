#!/usr/bin/env bash
# =============================================================================
# backup-guard.sh -- stop a backup job if the game or the host looks stressed. READ-ONLY watcher.
# =============================================================================
#   backup-guard.sh --once                 one check: print "OK" (exit 0) or the reason (exit 1)
#   backup-guard.sh --target PID [--reason-file F] [--interval N] [--consecutive N]
#                                          watch while PID lives; if the checks fail N times in
#                                          a row, write the reason to F and send PID a SIGINT
#                                          (the same clean abort as Ctrl-C: it stops everything
#                                          the job started and removes its partial file)
#
# Checks (any one failing counts as a bad sample):
#   * the game does not answer `dune status` over ssh, or its Overall state is not READY
#   * host I/O pressure (share of the last 10 s that tasks waited on the disk) above 30%
#   * host memory pressure (share of the last 10 s that tasks stalled waiting for memory) above 10%
#   * the disk is more than 95% busy
#   * the thin pool is more than 85% full
# Several consecutive bad samples are required (default 3 x 10 s) so one slow ssh or a short blip
# never aborts a run, but a sustained problem does within about 30 seconds.
#
# It only READS (ssh `dune status`, /proc/pressure, iostat, lvs) and signals the one PID it was
# given; it never touches the game or the backup's files.
# Thresholds: BK_GUARD_IO_PRESSURE_MAX, BK_GUARD_MEM_PRESSURE_MAX, BK_GUARD_DISK_BUSY_MAX, BK_GUARD_POOL_MAX; the game host:
# BK_GUARD_GAME_SSH (default BK_BACKUP_SSH).
# =============================================================================
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
. "$here/backup-common.sh"
bk_load_config 2>/dev/null || true

once=0
target=""
reason_file=""
interval=10
consecutive=3
while [ "$#" -gt 0 ]; do
  case "$1" in
    --once) once=1; shift ;;
    --target) target="${2:-}"; shift 2 ;;
    --reason-file) reason_file="${2:-}"; shift 2 ;;
    --interval) interval="${2:-10}"; shift 2 ;;
    --consecutive) consecutive="${2:-3}"; shift 2 ;;
    *) echo "usage: $0 --once | --target PID [--reason-file F] [--interval N] [--consecutive N]" >&2; exit 2 ;;
  esac
done
[[ "$interval" =~ ^[0-9]+$ ]] && [ "$interval" -ge 1 ] || { echo "interval must be >= 1" >&2; exit 2; }
[[ "$consecutive" =~ ^[0-9]+$ ]] && [ "$consecutive" -ge 1 ] || { echo "consecutive must be >= 1" >&2; exit 2; }
if [ "$once" -eq 0 ]; then
  [[ "$target" =~ ^[0-9]+$ ]] || { echo "--target PID is required" >&2; exit 2; }
fi

psi_dir="${BK_PSI_DIR:-/proc/pressure}"
disk="${BK_STATUS_DISK:-sda}"
game_ssh="${BK_GUARD_GAME_SSH:-${BK_BACKUP_SSH:-}}"
io_max="${BK_GUARD_IO_PRESSURE_MAX:-30}"
busy_max="${BK_GUARD_DISK_BUSY_MAX:-95}"
mem_max="${BK_GUARD_MEM_PRESSURE_MAX:-10}"
pool_max="${BK_GUARD_POOL_MAX:-85}"

gt() { awk -v a="${1:-0}" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'; }

# Print the reason(s) the system looks unhealthy, or nothing when it looks fine.
sample() {
  local reasons="" st io mem util line pool
  if [ -n "$game_ssh" ]; then
    st="$(timeout 12 ssh -o BatchMode=yes -o ConnectTimeout=6 -- "$game_ssh" 'cd ~/dune-awakening-selfhost-docker && dune status 2>&1 | sed -n 1,8p' 2>/dev/null)" || st=""
    if [ -z "$st" ]; then
      reasons="$reasons the game host did not answer;"
    elif ! printf '%s\n' "$st" | grep -q 'Overall: *READY'; then
      reasons="$reasons the game is not READY ($(printf '%s\n' "$st" | sed -n 's/^Overall: *//p' | head -n 1));"
    fi
  fi
  io="$(awk '$1 == "some" { for (i = 2; i <= NF; i++) if ($i ~ /^avg10=/) { sub("avg10=", "", $i); print $i } }' "$psi_dir/io" 2>/dev/null | head -n 1)"
  if gt "${io:-0}" "$io_max"; then reasons="$reasons host I/O pressure ${io}% (limit ${io_max}%);"; fi
  mem="$(awk '$1 == "some" { for (i = 2; i <= NF; i++) if ($i ~ /^avg10=/) { sub("avg10=", "", $i); print $i } }' "$psi_dir/memory" 2>/dev/null | head -n 1)"
  if gt "${mem:-0}" "$mem_max"; then reasons="$reasons host memory pressure ${mem}% (limit ${mem_max}%);"; fi
  if command -v iostat >/dev/null 2>&1; then
    line="$(iostat -dxm 1 2 2>/dev/null | awk -v d="$disk" '$1 == d { l = $0 } END { print l }')"
    if [ -n "$line" ]; then
      util="$(awk '{ print $NF }' <<<"$line")"
      if gt "${util:-0}" "$busy_max"; then reasons="$reasons disk ${disk} ${util}% busy (limit ${busy_max}%);"; fi
    fi
  fi
  pool="$(lvs --noheadings --units g --nosuffix -o data_percent pve/data 2>/dev/null | awk '{ printf "%.1f", $1 }')"
  if [ -n "$pool" ] && gt "$pool" "$pool_max"; then reasons="$reasons thin pool ${pool}% full (limit ${pool_max}%);"; fi
  printf '%s' "${reasons# }"
}

if [ "$once" -eq 1 ]; then
  r="$(sample)"
  if [ -z "$r" ]; then echo "OK"; exit 0; fi
  echo "$r"
  exit 1
fi

bad=0
bk_log "guard: watching PID $target every ${interval}s; will stop it after $consecutive bad samples in a row (I/O pressure > ${io_max}%, memory pressure > ${mem_max}%, disk > ${busy_max}% busy, pool > ${pool_max}% full, game not READY)"
while kill -0 "$target" 2>/dev/null; do
  r="$(sample)"
  if [ -z "$r" ]; then
    bad=0
  else
    bad=$((bad + 1))
    bk_log "guard: bad sample $bad of $consecutive: $r"
    if [ "$bad" -ge "$consecutive" ]; then
      bk_log "guard: STOPPING the backup (PID $target) to protect the game: $r"
      if [ -n "$reason_file" ]; then printf '%s\n' "$r" >"$reason_file" 2>/dev/null || true; fi
      kill -INT "$target" 2>/dev/null || true
      exit 0
    fi
  fi
  sleep "$interval" &
  wait "$!"
done
exit 0
