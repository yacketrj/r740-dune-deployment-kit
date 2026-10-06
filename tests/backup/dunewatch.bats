#!/usr/bin/env bats
# dunewatch.bats -- the dune-prod crash/downtime watch (scripts/dune-watch.sh).
load helper

setup() {
  setup_env
  T="$BATS_TEST_TMPDIR"
  SCRIPT="$REPO_ROOT/scripts/dune-watch.sh"
  printf 'https://discord.test/api/webhooks/123/SECRETTOKEN\n' >"$T/hook"; chmod 600 "$T/hook"
  cat >"$BK_CONFIG_DIR/backup.env" <<CFG
BK_DISCORD_WEBHOOK_FILE=$T/hook
BK_WATCH_MENTION='<@111222333>'
BK_WATCH_DOWN_CHECKS=3
CFG
  stub curl 'cat >>"$BATS_TEST_TMPDIR/curl.stdin"; echo "$*" >>"$BATS_TEST_TMPDIR/curl.args"'
  stub ssh 'cat >/dev/null; [ -f "$BATS_TEST_TMPDIR/ssh.fail" ] && exit 255; cat "$BATS_TEST_TMPDIR/ssh.out"'
}

probe() { # STATUS [partition total n24 last]...
  local status="$1"; shift
  { echo "STATUS $status"; [ -n "${CONT_STARTED:-}" ] && echo "CONT ${CONT_NAME:-dune-server-survival-1} $CONT_STARTED"; [ -n "${MODES:-}" ] && printf "%b" "$MODES"; while [ $# -ge 4 ]; do echo "CRASH $1 $2 $3 $4"; shift 4; done; } >"$T/ssh.out"
}
posts() { [ -f "$T/curl.args" ] && grep -c -e "-fsS" "$T/curl.args" || echo 0; }

@test "selftest posts one message with the mention" {
  run bash "$SCRIPT" --selftest
  [ "$status" -eq 0 ]
  [ "$(posts)" = "1" ]
  grep -q '<@111222333>' "$T/curl.args"
  grep -q 'dune-watch test message' "$T/curl.args"
}

@test "the first run only records a baseline; a later crash is posted once with the mention, the partition and the 24h count" {
  probe READY survival-1-38 46 25 2026-10-03_16:35:17
  run bash "$SCRIPT"; [ "$status" -eq 0 ]; [ "$(posts)" = "0" ]
  probe READY survival-1-38 47 26 2026-10-03_17:31:02
  run bash "$SCRIPT"; [ "$status" -eq 0 ]; [ "$(posts)" = "1" ]
  grep -q '<@111222333>' "$T/curl.args"
  grep -q 'CRASH on dune-prod' "$T/curl.args"
  grep -q 'survival-1-38 crashed (+1 new, last at 2026-10-03 17:31:02 UTC); 26 crash' "$T/curl.args"
  run bash "$SCRIPT"; [ "$(posts)" = "1" ]
}

@test "not READY: silent for the first two checks, one alert on the third, no repeat before the reminder, then RECOVERED" {
  probe ISSUE
  bash "$SCRIPT"; bash "$SCRIPT"; [ "$(posts)" = "0" ]
  bash "$SCRIPT"; [ "$(posts)" = "1" ]
  grep -q 'NOT READY: dune-prod has been ISSUE for 3 checks' "$T/curl.args"
  bash "$SCRIPT"; [ "$(posts)" = "1" ]
  probe READY
  bash "$SCRIPT"; [ "$(posts)" = "2" ]
  grep -q 'RECOVERED' "$T/curl.args"
}

@test "a still-not-READY game is reminded after BK_WATCH_REMIND_MIN" {
  echo 'BK_WATCH_REMIND_MIN=1' >>"$BK_CONFIG_DIR/backup.env"
  probe STOPPED
  bash "$SCRIPT"; bash "$SCRIPT"; bash "$SCRIPT"; [ "$(posts)" = "1" ]
  sed -i 's/^down_alert_at=.*/down_alert_at=1/' "$BK_STATE_DIR/dune-watch.state"
  bash "$SCRIPT"; [ "$(posts)" = "2" ]
  grep -q 'STILL NOT READY' "$T/curl.args"
}

@test "an unreachable prod alerts once after the threshold, and says so when it is readable again" {
  touch "$T/ssh.fail"
  bash "$SCRIPT"; bash "$SCRIPT"; [ "$(posts)" = "0" ]
  bash "$SCRIPT"; [ "$(posts)" = "1" ]
  grep -q 'UNREACHABLE' "$T/curl.args"
  bash "$SCRIPT"; [ "$(posts)" = "1" ]
  rm "$T/ssh.fail"; probe READY
  bash "$SCRIPT"; [ "$(posts)" = "2" ]
  grep -q 'readable again' "$T/curl.args"
}

@test "--dry-run prints what it would post, posts nothing and writes no state" {
  probe ISSUE
  printf 'down_checks=2\n' >"$BK_STATE_DIR/dune-watch.state"
  run bash "$SCRIPT" --dry-run
  [[ "$output" == *"WOULD POST: <@111222333> NOT READY"* ]]
  [ "$(posts)" = "0" ]
  [ "$(cat "$BK_STATE_DIR/dune-watch.state")" = "down_checks=2" ]
}

@test "the webhook URL never appears in the output" {
  probe ISSUE
  run bash -c "bash '$SCRIPT'; bash '$SCRIPT'; bash '$SCRIPT'"
  [[ "$output" != *"SECRETTOKEN"* ]]
}

@test "--install-timer writes a 5-minute timer and, with --no-enable, enables nothing" {
  stub systemctl ':'
  run env UNIT_DIR="$T/units" bash "$SCRIPT" --install-timer --no-enable
  [ "$status" -eq 0 ]
  grep -q 'OnUnitActiveSec=5min' "$T/units/r740-dune-watch.timer"
  grep -q "dune-watch.sh" "$T/units/r740-dune-watch.service"
  [ ! -e "$T/systemctl.calls" ]
}

@test "a bad threshold is refused" {
  echo 'BK_WATCH_DOWN_CHECKS=zero' >>"$BK_CONFIG_DIR/backup.env"
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "the script is executable (the timer runs it directly, a plain file fails with status 203)" {
  [ -x "$SCRIPT" ]
}

@test "a restarted game-server container is posted (any route), once, and says whether a crash was recorded" {
  CONT_STARTED=2026-10-03T18:00:00.123Z probe READY
  bash "$SCRIPT"; [ "$(posts)" = "0" ]
  CONT_STARTED=2026-10-03T18:34:00.456Z probe READY
  bash "$SCRIPT"; [ "$(posts)" = "1" ]
  grep -q 'RESTART on dune-prod (no crash was recorded: a normal restart)' "$T/curl.args"
  grep -q 'dune-server-survival-1 started again at 2026-10-03T18:34:00 UTC' "$T/curl.args"
  grep -q '<@111222333>' "$T/curl.args"
  bash "$SCRIPT"; [ "$(posts)" = "1" ]
}

@test "a dynamic map starting (Arrakeen, Deep Desert) is not a restart; an always-on map still is" {
  M='MODE SH_Arrakeen dynamic\nMODE DeepDesert_1 dynamic\nMODE CB_Overland_S_04 overmap-active\nMODE SH_HarkoVillage always-on\n'
  for n in dune-server-sh-arrakeen-41 dune-server-deepdesert-1-8 dune-server-cb-overland-s-04-25 dune-server-sh-harkovillage-4; do
    CONT_NAME=$n MODES=$M CONT_STARTED=2026-10-03T18:00:00.1Z probe READY; bash "$SCRIPT"
    CONT_NAME=$n MODES=$M CONT_STARTED=2026-10-03T18:34:00.2Z probe READY; bash "$SCRIPT"
  done
  [ "$(posts)" = "1" ]
  grep -q 'dune-server-sh-harkovillage-4 started again' "$T/curl.args"
  ! grep -q 'arrakeen\|deepdesert\|overland' "$T/curl.args"
}
