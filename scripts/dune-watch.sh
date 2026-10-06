#!/usr/bin/env bash
# =============================================================================
# dune-watch.sh -- watch dune-prod for game-server crashes and downtime and post to Discord.
# =============================================================================
#   dune-watch.sh                run one check (what the timer does); posts only when something changed
#   dune-watch.sh --dry-run      run one check, print the messages instead of posting them
#   dune-watch.sh --selftest     post ONE test message (proves the webhook and the mention work)
#   dune-watch.sh --install-timer [--no-enable]   write and enable a 5-minute systemd timer (run as root)
#
# It only READS prod (one ssh, `dune status` plus the crash journals); it never restarts or changes anything.
# What it posts, each with the mention:
#   RESTART    a game-server container that WAS RUNNING at the previous check started again (any route: console,
#              command line, Discord, a crash). A container that was stopped or absent and is now up is a dynamic
#              instance (Arrakeen, Deep Desert, ...) coming online on demand, and is not reported.
#   CRASH      a game server's crash journal grew (which partition, when, and how many in the last 24 h)
#   NOT READY  the game has not been READY for BK_WATCH_DOWN_CHECKS checks in a row (default 3 = 15 minutes);
#              repeated every BK_WATCH_REMIND_MIN minutes (default 60) while it lasts
#   RECOVERED  READY again after a NOT READY alert
#   UNREACHABLE  prod could not be reached over ssh for BK_WATCH_DOWN_CHECKS checks in a row
# Configuration (backup.env): BK_DISCORD_WEBHOOK_FILE (the webhook, by path), BK_WATCH_MENTION='<@id>' (falls
# back to BK_ALERT_MENTION), BK_WATCH_SSH (default dune@192.168.20.10), BK_WATCH_SSH_OPTS.
# =============================================================================
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
. "$here/backup-common.sh"
bk_load_config 2>/dev/null || true
BK_JOB=dune-watch
export BK_JOB

dry=0
mode=check
enable=1
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry=1 ;;
    --selftest) mode=selftest ;;
    --install-timer) mode=install ;;
    --no-enable) enable=0 ;;
    *) echo "usage: $0 [--dry-run | --selftest | --install-timer [--no-enable]]" >&2; exit 2 ;;
  esac
done

mention="${BK_WATCH_MENTION:-${BK_ALERT_MENTION:-}}"
target="${BK_WATCH_SSH:-dune@192.168.20.10}"
down_need="${BK_WATCH_DOWN_CHECKS:-3}"
remind_s=$((${BK_WATCH_REMIND_MIN:-60} * 60))
[[ "$down_need" =~ ^[0-9]+$ ]] && [ "$down_need" -ge 1 ] || { echo "BK_WATCH_DOWN_CHECKS must be a positive number" >&2; exit 2; }
[[ "$remind_s" =~ ^[0-9]+$ ]] || { echo "BK_WATCH_REMIND_MIN must be a number" >&2; exit 2; }

post() {
  if [ "$dry" -eq 1 ]; then printf 'WOULD POST: %s %s\n' "$mention" "$1"; else bk_notify "$mention $1"; fi
}

if [ "$mode" = "install" ]; then
  unit_dir="${UNIT_DIR:-/etc/systemd/system}"
  mkdir -p "$unit_dir"
  cat >"$unit_dir/r740-dune-watch.service" <<UNIT
[Unit]
Description=Watch dune-prod for crashes and downtime (Discord alert)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$here/dune-watch.sh
TimeoutStartSec=2min
Nice=10
NoNewPrivileges=yes
PrivateTmp=yes
UNIT
  cat >"$unit_dir/r740-dune-watch.timer" <<UNIT
[Unit]
Description=Schedule: watch dune-prod every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
UNIT
  if [ "$enable" -eq 1 ]; then
    systemctl daemon-reload
    systemctl enable --now r740-dune-watch.timer
  fi
  echo "installed r740-dune-watch units in $unit_dir (enable=$enable)"
  exit 0
fi

if [ "$mode" = "selftest" ]; then
  post "dune-watch test message from $(hostname): the webhook and the mention work. It will post here when a game server crashes or prod is not READY."
  exit 0
fi

bk_lock dune-watch || exit 0
state="$BK_STATE_DIR/dune-watch.state"
declare -A st=()
if [ -r "$state" ]; then
  while IFS='=' read -r k v; do
    [[ "$k" =~ ^[A-Za-z0-9_.-]+$ ]] && st["$k"]="$v"
  done <"$state"
fi
now="$(date +%s)"

# One read-only ssh: game status and every partition's crash journal.
remote='cd ~/dune-awakening-selfhost-docker 2>/dev/null || exit 3
dune status 2>&1 | awk "/^Overall:/ { print \"STATUS \" \$2; exit }"
thr="$(date -u -d "24 hours ago" "+%Y-%m-%d %H:%M:%S")"
docker ps -a --filter "name=^dune-server-" --format "{{.Names}}" 2>/dev/null | while read -r c; do
  echo "CONT $c $(docker inspect --format "{{.State.Status}} {{.State.StartedAt}}" "$c" 2>/dev/null)"
done
for f in runtime/game/*/Saved/Crashes/CrashReportsJournal.txt; do
  [ -f "$f" ] || continue
  d="${f#runtime/game/}"; d="${d%%/*}"
  dates="$(grep -o "\"crash_date\":\"[^\"]*\"" "$f" | cut -d\" -f4)"
  n="$(printf "%s\n" "$dates" | grep -c .)"
  l="$(printf "%s\n" "$dates" | tail -1)"
  n24="$(printf "%s\n" "$dates" | awk -v t="$thr" "\$0 >= t" | grep -c .)"
  echo "CRASH $d $n ${n24} ${l// /_}"
done'
# shellcheck disable=SC2086  # BK_WATCH_SSH_OPTS is a list of ssh options
out="$(printf '%s\n' "$remote" | ssh ${BK_WATCH_SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=10} "$target" bash -s 2>/dev/null)" || out=""

msgs=()
if ! printf '%s\n' "$out" | grep -q '^STATUS '; then
  st[ssh_fail]=$(( ${st[ssh_fail]:-0} + 1 ))
  if [ "${st[ssh_fail]}" -eq "$down_need" ]; then
    msgs+=("UNREACHABLE: could not read dune-prod over ssh for ${st[ssh_fail]} checks in a row. The watch cannot see crashes or downtime until this is fixed.")
    st[ssh_alerted]=1
  fi
else
  if [ "${st[ssh_alerted]:-0}" = "1" ]; then msgs+=("dune-prod is readable again; the watch is working."); fi
  st[ssh_fail]=0; st[ssh_alerted]=0

  status="$(printf '%s\n' "$out" | awk '/^STATUS / { print $2; exit }')"
  if [ "$status" = "READY" ]; then
    if [ "${st[down_alerted]:-0}" = "1" ]; then msgs+=("RECOVERED: dune-prod is READY again.") ; fi
    st[down_checks]=0; st[down_alerted]=0
  else
    st[down_checks]=$(( ${st[down_checks]:-0} + 1 ))
    if [ "${st[down_checks]}" -ge "$down_need" ]; then
      since_alert=$((now - ${st[down_alert_at]:-0}))
      if [ "${st[down_alerted]:-0}" != "1" ]; then
        msgs+=("NOT READY: dune-prod has been $status for ${st[down_checks]} checks in a row (about $((st[down_checks] * 5)) minutes).")
        st[down_alerted]=1; st[down_alert_at]="$now"
      elif [ "$remind_s" -gt 0 ] && [ "$since_alert" -ge "$remind_s" ]; then
        msgs+=("STILL NOT READY: dune-prod is $status after ${st[down_checks]} checks in a row (about $((st[down_checks] * 5)) minutes).")
        st[down_alert_at]="$now"
      fi
    fi
  fi

  crashed=""
  while read -r tag part total n24 last; do
    [ "$tag" = "CRASH" ] || continue
    [[ "$part" =~ ^[A-Za-z0-9_.-]+$ && "$total" =~ ^[0-9]+$ && "$n24" =~ ^[0-9]+$ ]] || continue
    key="crash.${part//./_}"
    if [ -n "${st[$key]:-}" ] && [ "$total" -gt "${st[$key]}" ]; then
      crashed="$crashed
- $part crashed (+$((total - st[$key])) new, last at ${last//_/ } UTC); $n24 crash(es) in the last 24 h"
    fi
    st[$key]="$total"
  done <<<"$out"
  if [ -n "$crashed" ]; then msgs+=("CRASH on dune-prod:$crashed"); fi

  # A game-server container that was running at the last check and has a new start time was restarted (console,
  # command line, Discord or a crash). One that was stopped or absent and is now up is an on-demand instance
  # (Arrakeen, Deep Desert, ...) coming online, not a restart. Crashes are reported by the crash journal above.
  restarted=""
  while read -r tag cname run started; do
    [ "$tag" = "CONT" ] || continue
    [[ "$cname" =~ ^[A-Za-z0-9_.-]+$ && -n "$started" ]] || continue
    key="cont.${cname//./_}"
    rkey="contrun.${cname//./_}"
    if [ -n "${st[$key]:-}" ] && [ "${st[$key]}" != "$started" ] && [ "${st[$rkey]:-0}" = "1" ]; then
      restarted="$restarted
- $cname started again at ${started%%.*} UTC"
    fi
    st[$key]="$started"
    if [ "$run" = "running" ]; then st[$rkey]=1; else st[$rkey]=0; fi
  done <<<"$out"
  if [ -n "$restarted" ]; then
    if [ -n "$crashed" ]; then note="(some of these are the crash restarts above)"; else note="(no crash was recorded: a normal restart)"; fi
    msgs+=("RESTART on dune-prod $note:$restarted")
  fi
fi

for m in "${msgs[@]}"; do post "$m"; done

if [ "$dry" -eq 0 ]; then
  tmp="$state.tmp.$$"
  : >"$tmp"
  for k in "${!st[@]}"; do printf '%s=%s\n' "$k" "${st[$k]}" >>"$tmp"; done
  mv "$tmp" "$state"
fi
exit 0
