#!/usr/bin/env bash
# =============================================================================
# backup-install-timers.sh -- write (and optionally enable) the r740-backup
# systemd units. The schedule follows design v2:
#   dbtier   04:45 10:45 16:45 22:45  (15 min after each game DB dump)  RPO 6h
#   daily    05:15                    (after the 04:30 dump and 04:45 tier)
#   weekly   Sunday 01:00             (window 01:00-04:15, hard stop enforced by the job)
#   check    hourly                   (the alarm)
#   pipeline monthly, 2nd Saturday 03:00 (automated pipeline drill, no real key)
#
# Enabling only schedules the timers; it never runs a job. Do it LAST, after
# `backup-doctor.sh` is green and the rollout gates have passed.
#
# USAGE: backup-install-timers.sh [--no-enable]
# RUN THIS: on the Proxmox host as root.
# =============================================================================
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unit_dir="${UNIT_DIR:-/etc/systemd/system}"
enable=1
[ "${1:-}" = "--no-enable" ] && enable=0

# name | command | OnCalendar | description | TimeoutStartSec | idle-io (1/0)
jobs=(
  "dbtier|$here/backup-daily.sh --tier db|*-*-* 04,10,16,22:45:00|database tier (RPO 6h)|1h|1"
  "daily|$here/backup-daily.sh --tier daily|*-*-* 05:15:00|daily set (dumps, secrets, host config)|2h|1"
  "weekly|$here/backup-weekly.sh|Sun *-*-* 01:00:00|weekly VM and container images|4h|1"
  "check|$here/backup-check.sh|hourly|backup alarm|10min|0"
  "pipeline|$here/backup-drill.sh pipeline|Sat *-*-08..14 03:00:00|automated pipeline restore drill|1h|1"
)

mkdir -p "$unit_dir"
for j in "${jobs[@]}"; do
  IFS='|' read -r name exec_line calendar desc timeout idle <<<"$j"
  {
    cat <<UNIT
[Unit]
Description=R740 backup: $desc
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$exec_line
TimeoutStartSec=$timeout
Nice=10
NoNewPrivileges=yes
PrivateTmp=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
UNIT
    [ "$idle" = "1" ] && echo "IOSchedulingClass=idle"
    true
  } >"$unit_dir/r740-backup-$name.service"
  cat >"$unit_dir/r740-backup-$name.timer" <<UNIT
[Unit]
Description=Schedule: R740 backup $desc

[Timer]
OnCalendar=$calendar
Persistent=true
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
UNIT
done

if [ "$enable" -eq 1 ]; then
  systemctl daemon-reload
  for j in "${jobs[@]}"; do
    IFS='|' read -r name _ <<<"$j"
    systemctl enable --now "r740-backup-$name.timer"
  done
fi
echo "installed r740-backup units in $unit_dir (enable=$enable)"
