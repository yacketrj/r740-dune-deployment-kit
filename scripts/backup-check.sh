#!/usr/bin/env bash
# =============================================================================
# backup-check.sh -- the backup alarm (design v2, themes T4/T10).
#
# It VERIFIES THE ARTIFACTS, not local state: the newest archive of each tier
# must exist on the SMB share and on OneDrive, be fresh, and be above a size
# floor; every guest must have a recent image; OneDrive must answer; and the
# escrow / restore drills must not be overdue. A local "last success" file is
# never trusted (a dead alarm or a faked file must not look healthy).
#
# Exit codes: 0 healthy; 1 problems (alert sent or throttled); 2 config error;
# 5 problems AND the alert could not be delivered (dead webhook). On any problem
# the external dead-man's-switch gets a fail ping, so a dead Discord webhook or
# a dead host still raises the alarm somewhere else.
#
# RUN THIS: on the Proxmox host as root, hourly from r740-backup-check.timer.
# =============================================================================
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
. "$here/backup-common.sh"

BK_JOB="backup alarm"
export BK_JOB
bk_secure_umask
bk_load_config

: "${BK_SMB_MOUNT:?}" "${BK_VMIDS:?}"
remote_on=0
[ -z "${BK_RCLONE_REMOTE:-}" ] || remote_on=1
now="${BK_CHECK_NOW_EPOCH:-$(date +%s)}"
findings=()
add() { findings+=("$1"); }

age_h() { awk -v s="$1" 'BEGIN { printf "%.1f", s / 3600 }'; }

# An unexpected failure of the alarm itself must not be silent: one alert, one
# external fail ping (the dead-man's-switch).
alerted=0
main_pid=$$
on_err() {
  local line="$1"
  trap - ERR
  if [ "$BASHPID" = "$main_pid" ] && [ "$alerted" -eq 0 ]; then
    alerted=1
    bk_alert "check" "the alarm itself failed unexpectedly at line $line" "bash $here/backup-check.sh"
    BK_DEADMAN_URL_FILE="${BK_CHECK_DEADMAN_URL_FILE:-}" bk_dead_man_ping fail || true
  fi
  exit 1
}
trap 'on_err $LINENO' ERR

# --- SMB share -------------------------------------------------------------------
timeout 20 ls "$BK_SMB_MOUNT" >/dev/null 2>&1 || true   # triggers a systemd automount
smb_ok=1
if ! timeout 20 mountpoint -q "$BK_SMB_MOUNT"; then
  add "SMB share is not mounted at $BK_SMB_MOUNT"
  smb_ok=0
fi

# check_smb_newest DIR GLOB MAX_AGE_S FLOOR LABEL
check_smb_newest() {
  local dir="$1" glob="$2" max_age="$3" floor="$4" label="$5" newest mt size
  newest="$(find "$dir" -maxdepth 1 -type f -name "$glob" -printf '%T@ %p\n' 2>/dev/null | sort -rn | sed -n 1p | cut -d' ' -f2- || true)"
  if [ -z "$newest" ]; then
    add "$label: no archive on the SMB share"
    return 0
  fi
  mt="$(stat -c %Y -- "$newest")"
  size="$(stat -c %s -- "$newest")"
  if [ $((now - mt)) -gt "$max_age" ]; then
    add "$label: newest SMB archive is $(age_h $((now - mt)))h old (limit $(age_h "$max_age")h)"
  fi
  if [ "$size" -lt "$floor" ]; then
    add "$label: newest SMB archive is only $size bytes (floor $floor)"
  fi
}

# check_remote_newest TIER MAX_AGE_S FLOOR
check_remote_newest() {
  local tier="$1" max_age="$2" floor="$3" out t sz best_e=0 best_sz=0 e
  if ! out="$(timeout 60 rclone lsf --format tsp --separator ';' "$BK_RCLONE_REMOTE/$tier" 2>/dev/null)"; then
    add "$tier: could not list OneDrive ($BK_RCLONE_REMOTE/$tier)"
    return 0
  fi
  while IFS=';' read -r t sz _; do
    [ -n "$t" ] || continue
    e="$(date -d "$t" +%s 2>/dev/null || echo 0)"
    if [ "$e" -gt "$best_e" ]; then best_e="$e"; best_sz="$sz"; fi
  done <<<"$out"
  if [ "$best_e" -eq 0 ]; then
    add "$tier: no archive on OneDrive"
    return 0
  fi
  if [ $((now - best_e)) -gt "$max_age" ]; then
    add "$tier: newest OneDrive object is $(age_h $((now - best_e)))h old (limit $(age_h "$max_age")h)"
  fi
  if [ "$best_sz" -lt "$floor" ]; then
    add "$tier: newest OneDrive object is only $best_sz bytes (floor $floor)"
  fi
}

daily_max=$((${BK_DAILY_ALARM_AGE_H:-26} * 3600))
db_max=$((${BK_DBTIER_MAX_AGE_H:-8} * 3600))
weekly_max=$((${BK_WEEKLY_MAX_AGE_D:-8} * 86400))
floor_set="${BK_MIN_SET_BYTES:-500000}"
floor_image="${BK_MIN_IMAGE_ALARM_BYTES:-10000000}"

if [ "$smb_ok" -eq 1 ]; then
  check_smb_newest "$BK_SMB_MOUNT/daily" 'daily-*.tar.age' "$daily_max" "$floor_set" "daily set"
  if [ "${BK_DBTIER_ENABLED:-1}" = "1" ]; then check_smb_newest "$BK_SMB_MOUNT/dbtier" 'dbtier-*.tar.age' "$db_max" "$floor_set" "db tier"; fi
  for id in $BK_VMIDS; do
    bk_valid_vmid "$id" || { add "invalid guest id in BK_VMIDS: $id"; continue; }
    check_smb_newest "$BK_SMB_MOUNT/vm" "[vc][mt]${id}-*.age" "$weekly_max" "$floor_image" "image $id"
  done
fi

# --- OneDrive (only when configured) -----------------------------------------------------
if [ "$remote_on" -eq 1 ]; then
  if timeout 60 rclone lsd "$BK_RCLONE_REMOTE" >/dev/null 2>&1; then
    check_remote_newest daily "$daily_max" "$floor_set"
    if [ "${BK_DBTIER_ENABLED:-1}" = "1" ]; then check_remote_newest dbtier "$db_max" "$floor_set"; fi
  else
    add "OneDrive probe failed (token expired or revoked, network, or account problem)"
  fi
fi

# --- escrow and restore drills (evidence log) ------------------------------------------
if [ "${BK_CHECK_REQUIRE_DRILLS:-1}" = "1" ]; then
  evlog="$BK_STATE_DIR/evidence.log"
  # last_pass KIND : epoch of the newest PASS record, or 0
  last_pass() {
    local ts
    ts="$(awk -F'\t' -v k="$1" '$2 == k && $3 == "PASS" { t = $1 } END { print t }' "$evlog" 2>/dev/null || true)"
    if [ -n "$ts" ]; then date -d "$ts" +%s 2>/dev/null || echo 0; else echo 0; fi
  }
  check_evidence() { # kind max_days label
    local e
    e="$(last_pass "$1")"
    if [ "$e" -eq 0 ]; then
      add "$3: never recorded"
    elif [ $((now - e)) -gt $(($2 * 86400)) ]; then
      add "$3: last passed $(((now - e) / 86400)) days ago (limit $2)"
    fi
  }
  check_evidence escrow "${BK_ESCROW_MAX_AGE_D:-100}" "key escrow verification"
  check_evidence drill-db "${BK_DRILL_DB_MAX_AGE_D:-35}" "database restore drill"
  check_evidence drill-vm "${BK_DRILL_VM_MAX_AGE_D:-100}" "VM restore drill"
fi

# --- the hand-made off-premises USB copy (the alarm cannot see the key; you record each copy) ----------------
# `backup-usb-done.sh` records "usb-copy" PASS in the evidence log after you copy the share to a key.
# BK_USB_MAX_AGE_D=0 turns this off. Never recorded: the clock starts at the first check (no instant alarm).
usb_max="${BK_USB_MAX_AGE_D:-14}"
if [[ "$usb_max" =~ ^[0-9]+$ ]] && [ "$usb_max" -gt 0 ]; then
  usb_last="$(awk -F'\t' '$2 == "usb-copy" && $3 == "PASS" { t = $1 } END { print t }' "$BK_STATE_DIR/evidence.log" 2>/dev/null || true)"
  usb_e=0
  [ -z "$usb_last" ] || usb_e="$(date -d "$usb_last" +%s 2>/dev/null || echo 0)"
  if [ "$usb_e" -gt 0 ]; then
    if [ $((now - usb_e)) -gt $((usb_max * 86400)) ]; then
      add "off-premises USB copy: last recorded $(((now - usb_e) / 86400)) days ago (limit $usb_max); copy the share to the USB key and run backup-usb-done.sh"
    fi
  else
    mkdir -p "$BK_STATE_DIR"
    [ -s "$BK_STATE_DIR/usb-clock-start" ] || printf '%s\n' "$now" >"$BK_STATE_DIR/usb-clock-start"
    usb_start="$(cat "$BK_STATE_DIR/usb-clock-start" 2>/dev/null || echo "$now")"
    [[ "$usb_start" =~ ^[0-9]+$ ]] || usb_start="$now"
    if [ $((now - usb_start)) -gt $((usb_max * 86400)) ]; then
      add "off-premises USB copy: none recorded in $(((now - usb_start) / 86400)) days (limit $usb_max); copy the share to the USB key and run backup-usb-done.sh"
    fi
  fi
fi

# --- outcome ---------------------------------------------------------------------------
check_ping() { # ok|fail : external heartbeat for the alarm itself
  local saved="${BK_DEADMAN_URL_FILE:-}"
  BK_DEADMAN_URL_FILE="${BK_CHECK_DEADMAN_URL_FILE:-}"
  if [ "$1" = "fail" ]; then bk_dead_man_ping fail || true; else bk_dead_man_ping || true; fi
  BK_DEADMAN_URL_FILE="$saved"
}

mkdir -p "$BK_STATE_DIR"
active="$BK_STATE_DIR/alarm.active"

if [ "${#findings[@]}" -eq 0 ]; then
  if [ -f "$active" ]; then
    bk_notify "r740 backup alarm RECOVERED: all backup tiers are fresh and verified again"
    rm -f -- "$active"
  fi
  check_ping ok
  bk_audit_log check_ok
  bk_log "backup check OK"
  exit 0
fi

summary="$(printf '%s; ' "${findings[@]}")"
summary="${summary%; }"
# The signature ignores digits, so a problem that merely gets older ("27.3h" -> "28.3h")
# is the SAME problem and is not re-announced every hour.
sig="$(printf '%s' "$summary" | tr -d '0-9' | sha256sum | cut -d' ' -f1)"
repeat="${BK_ALARM_REPEAT_S:-21600}"
send=1
if [ -f "$active" ]; then
  read -r last_sig last_at <"$active" || true
  if [ "${last_sig:-}" = "$sig" ] && [ $((now - ${last_at:-0})) -lt "$repeat" ]; then send=0; fi
fi

bk_log "PROBLEMS: $summary"
bk_audit_log check_failed "problems=${#findings[@]}" "summary=$summary"
check_ping fail
if [ "$send" -eq 1 ]; then
  bk_alert "check" "$summary" "bash $here/backup-check.sh"
  if [ "$BK_NOTIFY_LAST_RC" -ne 0 ]; then
    # Not recorded as announced: the next run retries instead of staying quiet for the window.
    bk_log "ALERT NOT DELIVERED (webhook status $BK_NOTIFY_LAST_RC); the external dead-man's-switch has been pinged"
    exit 5
  fi
  printf '%s %s\n' "$sig" "$now" >"$active"
fi
exit 1
