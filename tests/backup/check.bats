#!/usr/bin/env bats
# check.bats -- tests for scripts/backup-check.sh (the alarm, design v2 T4/T10).
# The alarm must verify ARTIFACTS on the share and on OneDrive, never trust local
# state, throttle repeats, recover once, and reveal a dead webhook.
load helper

setup() {
  setup_env
  SCRIPT="$REPO_ROOT/scripts/backup-check.sh"
  T="$BATS_TEST_TMPDIR"
  export BK_SMB_MOUNT="$T/smb"
  REMOTE_ROOT="$T/remote"
  mkdir -p "$BK_SMB_MOUNT/daily" "$BK_SMB_MOUNT/dbtier" "$BK_SMB_MOUNT/vm" "$REMOTE_ROOT/daily" "$REMOTE_ROOT/dbtier"
  printf 'https://discord.com/api/webhooks/1/x\n' >"$T/hook"
  printf 'https://hc.example/ping/CHECKID\n' >"$T/deadman-check"
  cat >"$BK_CONFIG_DIR/backup.env" <<EOF
BK_STATE_DIR=$BK_STATE_DIR
BK_SMB_MOUNT=$BK_SMB_MOUNT
BK_RCLONE_REMOTE=fake:r740
BK_VMIDS="101 104"
BK_DISCORD_WEBHOOK_FILE=$T/hook
BK_CHECK_DEADMAN_URL_FILE=$T/deadman-check
BK_MIN_SET_BYTES=100
BK_MIN_IMAGE_ALARM_BYTES=100
EOF
  NOW="$(date +%s)"
  fresh_all
  ok_evidence
  cat >"$T/bin/rclone" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/rclone.calls"
map() { case "\$1" in fake:r740/*) printf '%s' "$REMOTE_ROOT/\${1#fake:r740/}" ;; fake:r740) printf '%s' "$REMOTE_ROOT" ;; *) printf '%s' "\$1" ;; esac; }
case "\$1" in
  lsd) [ -f "$T/probe-fail" ] && exit 1; exit 0 ;;
  lsf) [ -f "$T/list-fail" ] && exit 1
       d="\$(map "\${@: -1}")"; [ -d "\$d" ] || exit 0
       for f in "\$d"/*; do [ -f "\$f" ] || continue; printf '%s;%s;%s\n' "\$(date -d "@\$(stat -c %Y "\$f")" '+%Y-%m-%d %H:%M:%S')" "\$(stat -c %s "\$f")" "\$(basename "\$f")"; done ;;
esac
EOF
  chmod +x "$T/bin/rclone"
  stub mountpoint '[ ! -f "$BATS_TEST_TMPDIR/unmounted" ]'
  stub curl 'cat >>"$BATS_TEST_TMPDIR/curl.stdin"; echo "$*" >>"$BATS_TEST_TMPDIR/curl.args"'
}

# mkfile PATH AGE_SECONDS [BYTES]
mkfile() { head -c "${3:-1000}" /dev/zero >"$1"; touch -d "@$((NOW - $2))" "$1"; }

fresh_all() {
  mkfile "$BK_SMB_MOUNT/daily/daily-20260930-051500.tar.age" 3600
  mkfile "$BK_SMB_MOUNT/dbtier/dbtier-20260930-064500.tar.age" 1800
  mkfile "$BK_SMB_MOUNT/vm/vm101-20260927-020000.vma.zst.age" $((2 * 86400))
  mkfile "$BK_SMB_MOUNT/vm/ct104-20260927-020000.tar.zst.age" $((2 * 86400))
  mkfile "$REMOTE_ROOT/daily/daily-20260930-051500.tar.age" 3600
  mkfile "$REMOTE_ROOT/dbtier/dbtier-20260930-064500.tar.age" 1800
}

ok_evidence() {
  mkdir -p "$BK_STATE_DIR"
  : >"$BK_STATE_DIR/evidence.log"
  for k in escrow drill-db drill-vm; do
    printf '%s\t%s\tPASS\tx\n' "$(date -u -d "@$((NOW - 86400))" +%Y-%m-%dT%H:%M:%SZ)" "$k" >>"$BK_STATE_DIR/evidence.log"
  done
}

run_check() { run env BK_CHECK_NOW_EPOCH="$NOW" bash "$SCRIPT"; }
alerts() { { grep -c "FAILED" "$T/curl.args" 2>/dev/null; } || true; }

@test "healthy: exit 0, no alert, and the alarm's own heartbeat is pinged" {
  run_check
  [ "$status" -eq 0 ]
  [ "$(alerts)" = "0" ]
  grep -q CHECKID "$T/curl.stdin"
}

@test "an archive missing from the SMB share alarms, even though local state says success" {
  date +%s >"$BK_STATE_DIR/last-success-daily"
  rm -f "$BK_SMB_MOUNT"/daily/*
  run_check
  [ "$status" -eq 1 ]
  grep -q "daily set: no archive on the SMB share" "$T/curl.args"
}

@test "an object missing from OneDrive alarms even though the share is fresh" {
  date +%s >"$BK_STATE_DIR/last-success-daily"
  rm -f "$REMOTE_ROOT"/daily/*
  run_check
  [ "$status" -eq 1 ]
  grep -q "daily: no archive on OneDrive" "$T/curl.args"
}

@test "a stale daily archive on the share alarms with its age and limit" {
  mkfile "$BK_SMB_MOUNT/daily/daily-20260930-051500.tar.age" $((40 * 3600))
  run_check
  [ "$status" -eq 1 ]
  grep -q "daily set: newest SMB archive is 40.0h old (limit 26.0h)" "$T/curl.args"
}

@test "a stale db tier on OneDrive alarms (8h limit)" {
  mkfile "$REMOTE_ROOT/dbtier/dbtier-20260930-064500.tar.age" $((10 * 3600))
  run_check
  [ "$status" -eq 1 ]
  grep -q "dbtier: newest OneDrive object is 10.0h old" "$T/curl.args"
}

@test "an SMB archive below the size floor alarms (OneDrive copy is fine)" {
  mkfile "$BK_SMB_MOUNT/daily/daily-20260930-051500.tar.age" 3600 10
  run_check
  [ "$status" -eq 1 ]
  grep -q "newest SMB archive is only 10 bytes" "$T/curl.args"
  run grep -q "OneDrive object is only" "$T/curl.args"
  [ "$status" -ne 0 ]
}

@test "an OneDrive object below the size floor alarms (SMB copy is fine)" {
  mkfile "$REMOTE_ROOT/daily/daily-20260930-051500.tar.age" 3600 10
  run_check
  [ "$status" -eq 1 ]
  grep -q "newest OneDrive object is only 10 bytes" "$T/curl.args"
  run grep -q "SMB archive is only" "$T/curl.args"
  [ "$status" -ne 0 ]
}

@test "a missing or stale guest image alarms" {
  rm -f "$BK_SMB_MOUNT"/vm/ct104-*
  mkfile "$BK_SMB_MOUNT/vm/vm101-20260927-020000.vma.zst.age" $((12 * 86400))
  run_check
  [ "$status" -eq 1 ]
  grep -q "image 104: no archive on the SMB share" "$T/curl.args"
  grep -q "image 101: newest SMB archive is 288.0h old" "$T/curl.args"
}

@test "an OneDrive probe failure (dead token) alarms" {
  touch "$T/probe-fail"
  run_check
  [ "$status" -eq 1 ]
  grep -q "OneDrive probe failed" "$T/curl.args"
}

@test "an unmounted share alarms" {
  touch "$T/unmounted"
  run_check
  [ "$status" -eq 1 ]
  grep -q "SMB share is not mounted" "$T/curl.args"
}

@test "an overdue escrow check, database drill or VM drill alarms; never-recorded counts as overdue" {
  : >"$BK_STATE_DIR/evidence.log"
  run_check
  [ "$status" -eq 1 ]
  grep -q "key escrow verification: never recorded" "$T/curl.args"
  grep -q "database restore drill: never recorded" "$T/curl.args"
  rm -f "$T/curl.args"
  ok_evidence
  printf '%s\tdrill-db\tPASS\tx\n' "$(date -u -d "@$((NOW - 40 * 86400))" +%Y-%m-%dT%H:%M:%SZ)" >"$BK_STATE_DIR/evidence.log"
  printf '%s\tescrow\tPASS\tx\n%s\tdrill-vm\tPASS\tx\n' "$(date -u -d "@$((NOW - 86400))" +%Y-%m-%dT%H:%M:%SZ)" "$(date -u -d "@$((NOW - 86400))" +%Y-%m-%dT%H:%M:%SZ)" >>"$BK_STATE_DIR/evidence.log"
  run_check
  [ "$status" -eq 1 ]
  grep -q "database restore drill: last passed 40 days ago" "$T/curl.args"
}

@test "a FAIL record does not count as a pass" {
  ok_evidence
  printf '%s\tdrill-db\tFAIL\tx\n' "$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)" >>"$BK_STATE_DIR/evidence.log"
  grep -v $'\tdrill-db\tPASS' "$BK_STATE_DIR/evidence.log" >"$BK_STATE_DIR/e2" && mv "$BK_STATE_DIR/e2" "$BK_STATE_DIR/evidence.log"
  run_check
  [ "$status" -eq 1 ]
  grep -q "database restore drill: never recorded" "$T/curl.args"
}

@test "drill checks can be disabled during the initial rollout" {
  : >"$BK_STATE_DIR/evidence.log"
  echo 'BK_CHECK_REQUIRE_DRILLS=0' >>"$BK_CONFIG_DIR/backup.env"
  run_check
  [ "$status" -eq 0 ]
}

@test "the alarm reports a problem once per window, again when it changes, and again after the repeat interval" {
  rm -f "$BK_SMB_MOUNT"/daily/*
  run_check; [ "$status" -eq 1 ]
  [ "$(alerts)" = "1" ]
  run_check; [ "$status" -eq 1 ]
  [ "$(alerts)" = "1" ]
  rm -f "$BK_SMB_MOUNT"/dbtier/*
  run_check; [ "$status" -eq 1 ]
  [ "$(alerts)" = "2" ]
  echo 'BK_ALARM_REPEAT_S=0' >>"$BK_CONFIG_DIR/backup.env"
  run_check; [ "$status" -eq 1 ]
  [ "$(alerts)" = "3" ]
}

@test "recovery is announced once, then quiet" {
  rm -f "$BK_SMB_MOUNT"/daily/*
  run_check; [ "$status" -eq 1 ]
  fresh_all
  run_check; [ "$status" -eq 0 ]
  grep -q "RECOVERED" "$T/curl.args"
  before="$(grep -c RECOVERED "$T/curl.args")"
  run_check; [ "$status" -eq 0 ]
  [ "$(grep -c RECOVERED "$T/curl.args")" = "$before" ]
}

@test "a problem pings the external dead-man's-switch fail endpoint" {
  rm -f "$BK_SMB_MOUNT"/daily/*
  run_check
  grep -q "CHECKID/fail" "$T/curl.stdin"
}

@test "a dead webhook is detected: distinct exit code 5 and the external fail ping still goes out" {
  rm -f "$BK_SMB_MOUNT"/daily/*
  stub curl 'cat >>"$BATS_TEST_TMPDIR/curl.stdin"; case "$*" in *discord*|*Content-Type*) exit 22 ;; esac; exit 0'
  run_check
  [ "$status" -eq 5 ]
  grep -q "CHECKID/fail" "$T/curl.stdin"
}

@test "no webhook configured is also reported as undeliverable (exit 5)" {
  rm -f "$BK_SMB_MOUNT"/daily/*
  sed -i '/BK_DISCORD_WEBHOOK_FILE/d' "$BK_CONFIG_DIR/backup.env"
  run_check
  [ "$status" -eq 5 ]
}

@test "an invalid guest id in the config is reported, not executed" {
  sed -i 's#^BK_VMIDS=.*#BK_VMIDS="101 1;rm"#' "$BK_CONFIG_DIR/backup.env"
  run_check
  [ "$status" -eq 1 ]
  grep -q "invalid guest id" "$T/curl.args"
}

@test "the alarm never modifies the backups it inspects" {
  before="$(find "$BK_SMB_MOUNT" "$REMOTE_ROOT" -type f -exec sha256sum {} + | sort)"
  run_check
  after="$(find "$BK_SMB_MOUNT" "$REMOTE_ROOT" -type f -exec sha256sum {} + | sort)"
  [ "$before" = "$after" ]
}

@test "an unexpected failure of the alarm itself raises exactly one alert saying so" {
  stub stat 'exit 1'
  run_check
  [ "$status" -eq 1 ]
  [ "$(alerts)" = "1" ]
  grep -q "the alarm itself failed unexpectedly" "$T/curl.args"
  grep -q "CHECKID/fail" "$T/curl.stdin"
}

@test "a problem that only gets older is announced once, not every hour" {
  rm -f "$BK_SMB_MOUNT"/daily/*
  mkfile "$BK_SMB_MOUNT/daily/daily-20260929-051500.tar.age" $((28 * 3600))
  mkfile "$REMOTE_ROOT/daily/daily-20260929-051500.tar.age" $((28 * 3600))
  run_check; [ "$status" -eq 1 ]
  [ "$(alerts)" = "1" ]
  NOW=$((NOW + 3600))
  touch -d "@$((NOW - 29 * 3600))" "$BK_SMB_MOUNT/daily/daily-20260929-051500.tar.age" "$REMOTE_ROOT/daily/daily-20260929-051500.tar.age"
  run_check; [ "$status" -eq 1 ]
  [ "$(alerts)" = "1" ]
}

@test "an alert that could not be delivered is retried on the next run, not silenced for the window" {
  rm -f "$BK_SMB_MOUNT"/daily/*
  stub curl 'cat >>"$BATS_TEST_TMPDIR/curl.stdin"; echo "$*" >>"$BATS_TEST_TMPDIR/curl.args"; case "$*" in *Content-Type*) [ -f "$BATS_TEST_TMPDIR/hook-down" ] && exit 22 ;; esac; exit 0'
  touch "$T/hook-down"
  run_check; [ "$status" -eq 5 ]
  rm -f "$T/hook-down"
  run_check; [ "$status" -eq 1 ]
  [ -f "$BK_STATE_DIR/alarm.active" ]
  run_check; [ "$status" -eq 1 ]
  [ "$(grep -c 'Content-Type' "$T/curl.args")" -eq 2 ]
}

@test "the alarm's daily age limit is its own setting, independent of the daily job's dump-freshness gate" {
  rm -f "$BK_SMB_MOUNT"/daily/* "$REMOTE_ROOT"/daily/*
  mkfile "$BK_SMB_MOUNT/daily/daily-20260930-051500.tar.age" $((20 * 3600))
  mkfile "$REMOTE_ROOT/daily/daily-20260930-051500.tar.age" $((20 * 3600))
  echo 'BK_DAILY_MAX_AGE_H=12' >>"$BK_CONFIG_DIR/backup.env"
  run_check; [ "$status" -eq 0 ]
  echo 'BK_DAILY_ALARM_AGE_H=12' >>"$BK_CONFIG_DIR/backup.env"
  run_check; [ "$status" -eq 1 ]
}
