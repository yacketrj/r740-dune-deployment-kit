#!/usr/bin/env bats
# install-timers.bats -- tests for scripts/backup-install-timers.sh (design v2 schedule).
load helper

setup() {
  setup_env
  export UNIT_DIR="$BATS_TEST_TMPDIR/units"
  mkdir -p "$UNIT_DIR"
  stub systemctl 'exit 0'
  INSTALL="$REPO_ROOT/scripts/backup-install-timers.sh"
}

@test "writes a service and a timer for every job with absolute ExecStart paths" {
  run bash "$INSTALL" --no-enable
  [ "$status" -eq 0 ]
  for j in dbtier daily weekly check pipeline; do
    [ -f "$UNIT_DIR/r740-backup-$j.service" ]
    [ -f "$UNIT_DIR/r740-backup-$j.timer" ]
  done
  grep -q "^ExecStart=$REPO_ROOT/scripts/backup-daily.sh --tier db$" "$UNIT_DIR/r740-backup-dbtier.service"
  grep -q "^ExecStart=$REPO_ROOT/scripts/backup-daily.sh --tier daily$" "$UNIT_DIR/r740-backup-daily.service"
  grep -q "^ExecStart=$REPO_ROOT/scripts/backup-weekly.sh$" "$UNIT_DIR/r740-backup-weekly.service"
  grep -q "^ExecStart=$REPO_ROOT/scripts/backup-check.sh$" "$UNIT_DIR/r740-backup-check.service"
  grep -q "^ExecStart=$REPO_ROOT/scripts/backup-drill.sh pipeline$" "$UNIT_DIR/r740-backup-pipeline.service"
}

@test "schedule matches the design: db tier every 6h after the game dump, daily 05:15, weekly Tuesday 05:00, alarm hourly" {
  bash "$INSTALL" --no-enable
  grep -q '^OnCalendar=\*-\*-\* 04,10,16,22:45:00$' "$UNIT_DIR/r740-backup-dbtier.timer"
  grep -q '^OnCalendar=\*-\*-\* 05:15:00$' "$UNIT_DIR/r740-backup-daily.timer"
  grep -q '^OnCalendar=Tue \*-\*-\* 05:00:00$' "$UNIT_DIR/r740-backup-weekly.timer"
  grep -q '^OnCalendar=hourly$' "$UNIT_DIR/r740-backup-check.timer"
  grep -q '^OnCalendar=Sat \*-\*-08..14 03:00:00$' "$UNIT_DIR/r740-backup-pipeline.timer"
}

@test "the daily set is after the 04:30 game dump and the 04:45 tier run" {
  bash "$INSTALL" --no-enable
  t="$(awk -F'[ :]' '/^OnCalendar=/{print $2*60+$3}' "$UNIT_DIR/r740-backup-daily.timer")"
  [ "$t" -gt $((4 * 60 + 45)) ]
}

@test "every timer is Persistent and randomised" {
  bash "$INSTALL" --no-enable
  for t in "$UNIT_DIR"/r740-backup-*.timer; do
    grep -q '^Persistent=true$' "$t"
    grep -q '^RandomizedDelaySec=120$' "$t"
  done
}

@test "services are oneshot, low priority, time-limited; heavy jobs use idle IO, the alarm does not" {
  bash "$INSTALL" --no-enable
  for j in dbtier daily weekly check pipeline; do
    grep -q '^Type=oneshot$' "$UNIT_DIR/r740-backup-$j.service"
    grep -q '^Nice=10$' "$UNIT_DIR/r740-backup-$j.service"
    grep -q '^TimeoutStartSec=' "$UNIT_DIR/r740-backup-$j.service"
    grep -q '^NoNewPrivileges=yes$' "$UNIT_DIR/r740-backup-$j.service"
    grep -q '^PrivateTmp=yes$' "$UNIT_DIR/r740-backup-$j.service"
  done
  for j in dbtier daily weekly pipeline; do grep -q '^IOSchedulingClass=idle$' "$UNIT_DIR/r740-backup-$j.service"; done
  run grep -q 'IOSchedulingClass' "$UNIT_DIR/r740-backup-check.service"
  [ "$status" -ne 0 ]
  grep -q '^TimeoutStartSec=4h$' "$UNIT_DIR/r740-backup-weekly.service"
}

@test "--no-enable never touches systemd" {
  bash "$INSTALL" --no-enable
  [ ! -e "$BATS_TEST_TMPDIR/systemctl.calls" ]
}

@test "enabling reloads systemd and enables exactly the five timers, never a service" {
  run bash "$INSTALL"
  [ "$status" -eq 0 ]
  grep -q '^daemon-reload$' "$BATS_TEST_TMPDIR/systemctl.calls"
  [ "$(grep -c '^enable --now r740-backup-.*\.timer$' "$BATS_TEST_TMPDIR/systemctl.calls")" -eq 5 ]
  run grep -E 'start|\.service' "$BATS_TEST_TMPDIR/systemctl.calls"
  [ "$status" -ne 0 ]
}

@test "generated units pass systemd-analyze verify" {
  command -v systemd-analyze >/dev/null || skip "systemd-analyze not installed"
  bash "$INSTALL" --no-enable
  run systemd-analyze verify "$UNIT_DIR"/r740-backup-*.timer
  [ "$status" -eq 0 ]
}

@test "re-running is idempotent" {
  bash "$INSTALL" --no-enable
  before="$(cat "$UNIT_DIR"/*.timer "$UNIT_DIR"/*.service | sha256sum)"
  bash "$INSTALL" --no-enable
  [ "$before" = "$(cat "$UNIT_DIR"/*.timer "$UNIT_DIR"/*.service | sha256sum)" ]
}

@test "--no-dbtier installs daily, weekly, check and pipeline only" {
  bash "$INSTALL" --no-enable --no-dbtier
  [ ! -e "$UNIT_DIR/r740-backup-dbtier.timer" ]
  [ ! -e "$UNIT_DIR/r740-backup-dbtier.service" ]
  for j in daily weekly check pipeline; do [ -f "$UNIT_DIR/r740-backup-$j.timer" ]; done
}

@test "an unknown option is refused" {
  run bash "$INSTALL" --bogus
  [ "$status" -eq 2 ]
}
