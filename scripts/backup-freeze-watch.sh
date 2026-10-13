#!/usr/bin/env bash
# =============================================================================
# backup-freeze-watch.sh -- keep a guest's filesystem freeze short while a backup runs (#126).
# =============================================================================
#   backup-freeze-watch.sh --vmid ID --target PID [--max-s 30] [--warn-s 10] [--interval 1]
#
# vzdump freezes a VM's filesystems through the guest agent when a snapshot backup starts and
# thaws them again once the snapshot exists. Proxmox allows a freeze to take up to an hour, and a
# frozen game VM serves nobody. This watcher runs next to the job for one VM and:
#   * logs how long each freeze lasted, and alerts when one took longer than --warn-s;
#   * forces a thaw when a freeze lasts longer than --max-s (the snapshot is taken in the first
#     second or two of a freeze, so thawing early costs the image nothing but its consistency);
#   * alerts, and tries one thaw, when the agent stops answering for longer than --max-s while
#     the job is running (a hung freeze looks like that: the agent socket is busy);
#   * thaws and alerts if the job exits while the guest is still frozen.
# It only talks to the one guest it was given, and never to a guest the job is not backing up.
# Limit: a thaw is a normal agent command, so if the freeze command itself is hung inside the
# guest the thaw is queued behind it. The alert is then the guardrail that matters; the
# per-guest kill switch is `qm set ID --agent enabled=1,freeze-fs-on-backup=0` (docs/08).
# =============================================================================
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
. "$here/backup-common.sh"
bk_load_config 2>/dev/null || true

vmid=""
target=""
max_s=30
warn_s=10
interval=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --vmid) vmid="${2:-}"; shift 2 ;;
    --target) target="${2:-}"; shift 2 ;;
    --max-s) max_s="${2:-}"; shift 2 ;;
    --warn-s) warn_s="${2:-}"; shift 2 ;;
    --interval) interval="${2:-}"; shift 2 ;;
    *) echo "usage: $0 --vmid ID --target PID [--max-s N] [--warn-s N] [--interval N]" >&2; exit 2 ;;
  esac
done
bk_valid_vmid "$vmid" || { echo "--vmid must be a valid guest id" >&2; exit 2; }
for v in "$target" "$max_s" "$warn_s" "$interval"; do
  [[ "$v" =~ ^[0-9]+$ ]] || { echo "--target, --max-s, --warn-s and --interval must be integers" >&2; exit 2; }
done
[ "$interval" -ge 1 ] && [ "$max_s" -ge 1 ] || { echo "--interval and --max-s must be >= 1" >&2; exit 2; }

agent_status() { # prints frozen | thawed | (empty when the agent did not answer in time)
  local out
  out="$(timeout 4 qm guest cmd "$vmid" fsfreeze-status 2>/dev/null)" || return 0
  case "$out" in *thawed*) echo thawed ;; *frozen*) echo frozen ;; esac
}

force_thaw() { # why
  bk_log "freeze-watch: VM $vmid: forcing a thaw ($1)"
  timeout 20 qm guest cmd "$vmid" fsfreeze-thaw >/dev/null 2>&1 \
    || bk_log "freeze-watch: VM $vmid: the thaw command did not complete (it may be queued behind a hung freeze)"
}

frozen_since=""
silent_since=""
forced=0
silent_alerted=0
bk_log "freeze-watch: VM $vmid: watching PID $target (forced thaw after ${max_s}s frozen, alert after ${warn_s}s)"
while kill -0 "$target" 2>/dev/null; do
  s="$(agent_status)"
  now=$SECONDS
  case "$s" in
    frozen)
      silent_since=""
      [ -n "$frozen_since" ] || frozen_since=$now
      if [ $((now - frozen_since)) -gt "$max_s" ] && [ "$forced" -eq 0 ]; then
        forced=1
        force_thaw "frozen for more than ${max_s}s"
        bk_notify "r740 weekly alert: VM $vmid was frozen for more than ${max_s}s during its backup; forced a thaw. Check the guest and the image."
      fi
      ;;
    thawed)
      silent_since=""
      silent_alerted=0
      if [ -n "$frozen_since" ]; then
        d=$((now - frozen_since))
        bk_log "freeze-watch: VM $vmid: frozen for about ${d}s"
        if [ "$d" -gt "$warn_s" ] && [ "$forced" -eq 0 ]; then
          bk_notify "r740 weekly warning: VM $vmid was frozen for about ${d}s during its backup (normal is a few seconds)."
        fi
        frozen_since=""
        forced=0
      fi
      ;;
    *)
      [ -n "$silent_since" ] || silent_since=$now
      if [ $((now - silent_since)) -gt "$max_s" ] && [ "$silent_alerted" -eq 0 ]; then
        silent_alerted=1
        force_thaw "the guest agent has not answered for more than ${max_s}s"
        bk_notify "r740 weekly alert: the guest agent in VM $vmid has not answered for more than ${max_s}s during its backup (a hung freeze looks like this). Tried one thaw; check the guest."
      fi
      ;;
  esac
  sleep "$interval" &
  wait "$!"
done

# The job is gone: never leave a guest frozen behind it.
if [ -n "$frozen_since" ] || [ "$(agent_status)" = "frozen" ]; then
  force_thaw "the backup job ended while the guest was still frozen"
  bk_notify "r740 weekly alert: the backup job for VM $vmid ended while the guest was still frozen; thawed it. Check the guest and the image."
fi
exit 0
