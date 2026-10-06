#!/usr/bin/env bash
# =============================================================================
# backup-status.sh -- live, READ-ONLY dashboard: what is the backup doing, and is the game OK?
# =============================================================================
#   backup-status.sh            refresh every 10 seconds until Ctrl-C
#   backup-status.sh --once     print once and exit
#   backup-status.sh --interval N
#
# Shows: the running backup job (guest, elapsed, bytes written, speed, vzdump's percent), the
# host disk and pressure numbers that would show a slowdown, and the game's own status. It only
# READS (files, /proc, iostat) and asks the game for `dune status` over ssh; it changes nothing,
# so it is safe to run while a backup is going and safe to Ctrl-C at any time.
#
# Verdict line: "OK" when nothing suggests the game is affected; "WATCH" when a host number
# crosses a threshold (disk busy > 85%, read/write wait > 25 ms, I/O pressure avg10 > 10%, CPU
# pressure avg10 > 30%, game not READY). WATCH is a prompt to look, not proof of a problem.
# =============================================================================
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
. "$here/backup-common.sh"
bk_load_config 2>/dev/null || true

once=0
interval=10
while [ "$#" -gt 0 ]; do
  case "$1" in
    --once) once=1; shift ;;
    --interval) interval="${2:-10}"; shift 2 ;;
    *) echo "usage: $0 [--once] [--interval N]" >&2; exit 2 ;;
  esac
done
[[ "$interval" =~ ^[0-9]+$ ]] && [ "$interval" -ge 2 ] || { echo "interval must be a number >= 2" >&2; exit 2; }

progress_log="${BK_PROGRESS_LOG:-$BK_STATE_DIR/weekly-progress.log}"
psi_dir="${BK_PSI_DIR:-/proc/pressure}"
disk="${BK_STATUS_DISK:-sda}"
lock="${BK_STATUS_LOCK:-$BK_STATE_DIR/backup-weekly.lock}"
prod_ssh="${BK_STATUS_GAME_SSH:-${BK_BACKUP_SSH:-}}"

hsize() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 B"; }
psi() { # file -> avg10 of the "some" line
  awk '$1 == "some" { for (i = 2; i <= NF; i++) if ($i ~ /^avg10=/) { sub("avg10=", "", $i); print $i } }' "$psi_dir/$1" 2>/dev/null | head -n 1
}
gt() { awk -v a="${1:-0}" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'; }

render() {
  local watch="" running=0 line p sz pw
  echo "=== Backup and game status  $(date '+%Y-%m-%d %H:%M:%S')   (read-only; Ctrl-C to leave) ==="
  echo

  # ---- the backup job ---------------------------------------------------------------------
  if [ -e "$lock" ] && ! flock -n "$lock" true 2>/dev/null; then running=1; fi
  if [ "$running" -eq 1 ]; then
    echo "BACKUP: RUNNING (weekly images)"
    if [ -s "$progress_log" ]; then
      echo "  latest progress:"
      tail -n 4 "$progress_log" | sed 's/^/    /'
    else
      # No progress log (a job started by an older version): read vzdump's own log from the
      # job's working directory instead. Find the job by its exact command (not pgrep -f).
      jp="$(ps -eo pid,cmd | awk '$2 == "bash" && $3 ~ /backup-weekly\.sh$/ { print $1 }' | sort -n | head -n 1)"
      jt=""
      if [ -n "$jp" ]; then
        jtmp="$(tr '\0' '\n' <"/proc/$jp/environ" 2>/dev/null | sed -n 's/^TMPDIR=//p' | head -n 1)"
        jt="$(ls -dt "${jtmp:-/var/tmp}"/backup-weekly.* 2>/dev/null | head -n 1)"
      fi
      if [ -n "$jt" ] && [ -s "$jt/vzdump.err" ]; then
        echo "  vzdump says (started $(ps -o etime= -p "$jp" | tr -d ' ') ago):"
        grep -E 'INFO: +[0-9]+%|Starting Backup|sending archive' "$jt/vzdump.err" | tail -n 2 | sed 's/^/    /'
      else
        echo "  (no progress log: start the job with --progress to get one)"
      fi
    fi
    for p in "${BK_SMB_MOUNT:-/mnt/desktop-backup}"/vm/*.partial; do
      [ -e "$p" ] || continue
      sz="$(stat -c %s -- "$p" 2>/dev/null || echo 0)"
      echo "  writing: $(basename -- "$p")  now $(hsize "$sz")"
    done
  else
    echo "BACKUP: no weekly image job is running"
    if [ -s "$progress_log" ]; then
      echo "  last run ended with:"
      tail -n 2 "$progress_log" | sed 's/^/    /'
    fi
  fi
  echo
  echo "  newest images on the share:"
  for id in ${BK_VMIDS:-101 102 103 104}; do
    line="$(ls -t "${BK_SMB_MOUNT:-/mnt/desktop-backup}"/vm/[vc][mt]"$id"-*.age 2>/dev/null | head -n 1)"
    if [ -n "$line" ]; then
      printf '    %-5s %s  (%s, %s)\n' "$id" "$(basename -- "$line")" "$(hsize "$(stat -c %s -- "$line")")" "$(date -d "@$(stat -c %Y -- "$line")" '+%a %H:%M' 2>/dev/null)"
    else
      printf '    %-5s none yet\n' "$id"
    fi
  done
  echo

  # ---- the host: what would show a slowdown --------------------------------------------------
  local io_p cpu_p mem_p util r_aw w_aw
  io_p="$(psi io)"; cpu_p="$(psi cpu)"; mem_p="$(psi memory)"
  echo "HOST:"
  echo "  pressure (share of the last 10 s that tasks WAITED):  I/O ${io_p:-?}%   CPU ${cpu_p:-?}%   memory ${mem_p:-?}%"
  if command -v iostat >/dev/null 2>&1; then
    line="$(iostat -dxm 1 2 2>/dev/null | awk -v d="$disk" '$1 == d { l = $0 } END { print l }')"
    if [ -n "$line" ]; then
      # columns (sysstat 12): r/s rMB/s ... r_await ... w/s wMB/s ... w_await ... %util
      read -r -a f <<<"$line"
      util="${f[${#f[@]}-1]}"; r_aw="${f[5]:-0}"; w_aw="${f[11]:-0}"
      echo "  disk $disk: ${f[2]:-0} MB/s read, ${f[8]:-0} MB/s write, wait ${r_aw} ms read / ${w_aw} ms write, ${util}% busy"
      gt "$util" 85 && watch="$watch disk busy ${util}%;"
      gt "$r_aw" 25 && watch="$watch read wait ${r_aw} ms;"
      gt "$w_aw" 25 && watch="$watch write wait ${w_aw} ms;"
    fi
  fi
  gt "${io_p:-0}" 10 && watch="$watch I/O pressure ${io_p}%;"
  gt "${cpu_p:-0}" 30 && watch="$watch CPU pressure ${cpu_p}%;"
  echo "  load average: $(uptime | sed 's/.*load average: //')   RAM available: $(free -g | awk 'NR==2 { print $7 }') GB"
  pw="$(lvs --noheadings --units g --nosuffix -o data_percent pve/data 2>/dev/null | awk '{ printf "%.1f", $1 }')"
  [ -z "$pw" ] || echo "  thin pool: ${pw}% used"
  echo

  # ---- the game --------------------------------------------------------------------------------
  echo "GAME:"
  if [ -n "$prod_ssh" ]; then
    local st
    st="$(timeout 12 ssh -o BatchMode=yes -o ConnectTimeout=6 -- "$prod_ssh" 'cd ~/dune-awakening-selfhost-docker && dune status 2>&1 | sed -n 1,8p' 2>/dev/null)" || st=""
    if [ -n "$st" ]; then
      printf '%s\n' "$st" | grep -E 'Overall|Title|Population' | sed 's/^/  /'
      printf '%s\n' "$st" | grep -q 'Overall: *READY' || watch="$watch game not READY;"
    else
      echo "  (could not reach the game host for its status)"
      watch="$watch game status unreachable;"
    fi
  else
    echo "  (no BK_BACKUP_SSH configured)"
  fi
  echo
  if [ -z "$watch" ]; then
    echo "VERDICT: OK - no sign the game is being affected."
  else
    echo "VERDICT: WATCH -$watch"
    echo "         (a prompt to look, not proof; if the game feels slow, stop the backup with Ctrl-C in its terminal:"
    echo "          it stops everything it started and leaves no partial file)"
  fi
}

# Ctrl-C (or Ctrl-Z, kill, hangup) must leave at once, even in the middle of the call to the game
# host: the screen is rendered by a background job that the abort handler can kill, and the main
# shell only ever `wait`s (bash would otherwise hold the signal until the foreground ssh returns).
export BK_ABORT_QUIET=1 BK_KILL_GRACE_S=2   # read by bk_abort in backup-common.sh
buf="$(mktemp "${XDG_RUNTIME_DIR:-/dev/shm}/backup-status.XXXXXX")"
cleanup() { rm -f -- "$buf"; }
trap cleanup EXIT
bk_install_abort_traps

draw() { # clear: 1 = clear the screen first
  render >"$buf" 2>&1 &
  wait "$!"
  if [ "$1" -eq 1 ]; then printf '\033[H\033[2J'; fi
  cat -- "$buf"
}

if [ "$once" -eq 1 ]; then
  draw 0
  exit 0
fi
while true; do
  draw 1
  sleep "$interval" &
  wait "$!"
done
