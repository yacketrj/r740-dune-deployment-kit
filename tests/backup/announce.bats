#!/usr/bin/env bats
# announce.bats -- the in-game announcement messages and tool (scripts/backup-announce.sh).
load helper

setup() {
  setup_env
  SCRIPT="$REPO_ROOT/scripts/backup-announce.sh"
  T="$BATS_TEST_TMPDIR"
  printf 'dak_testkey123\n' >"$T/annkey"; chmod 600 "$T/annkey"
  cat >"$BK_CONFIG_DIR/backup.env" <<EOF
BK_ANNOUNCE_URL=http://console.test:8088
BK_ANNOUNCE_KEY_FILE=$T/annkey
EOF
  stub curl 'cat >>"$BATS_TEST_TMPDIR/curl.stdin"; echo "$*" >>"$BATS_TEST_TMPDIR/curl.args"'
}

@test "every message fits the console's limits (title <= 80, body <= 500) and is non-empty" {
  source "$REPO_ROOT/scripts/backup-common.sh"
  for spec in "lead 30" "lead 15" "lead 5" "lead 1" "start 0" "ongoing 30" "ongoing 120" "done 0" "halted 0" "postponed 0" "test 0"; do
    read -r k m <<<"$spec"
    bk_announce_text "$k" "$m"
    [ "${#BK_ANN_TITLE}" -ge 1 ]
    [ "${#BK_ANN_TITLE}" -le 80 ]
    [ "${#BK_ANN_BODY}" -ge 1 ]
    [ "${#BK_ANN_BODY}" -le 500 ]
  done
}

@test "the lead message says minute/minutes correctly and carries the number" {
  source "$REPO_ROOT/scripts/backup-common.sh"
  bk_announce_text lead 1;  [[ "$BK_ANN_BODY" == *"In 1 minute "* ]]
  bk_announce_text lead 15; [[ "$BK_ANN_BODY" == *"In 15 minutes "* ]]
  bk_announce_text ongoing 60; [[ "$BK_ANN_BODY" == *"about 60 minutes so far"* ]]
}

@test "any message can be replaced by configuration, and over-long text is cut to the limits" {
  source "$REPO_ROOT/scripts/backup-common.sh"
  BK_ANNOUNCE_TEXT_START_TITLE="Custom title" BK_ANNOUNCE_TEXT_START_BODY="Custom body"
  bk_announce_text start
  [ "$BK_ANN_TITLE" = "Custom title" ]
  [ "$BK_ANN_BODY" = "Custom body" ]
  BK_ANNOUNCE_TEXT_DONE_TITLE="$(head -c 200 /dev/zero | tr '\0' T)" BK_ANNOUNCE_TEXT_DONE_BODY="$(head -c 900 /dev/zero | tr '\0' B)"
  bk_announce_text done
  [ "${#BK_ANN_TITLE}" -eq 80 ]
  [ "${#BK_ANN_BODY}" -eq 500 ]
}

@test "an unknown message key is refused" {
  source "$REPO_ROOT/scripts/backup-common.sh"
  run bk_announce_text nonsense
  [ "$status" -ne 0 ]
}

@test "print shows every message and sends NOTHING" {
  run bash "$SCRIPT" print
  [ "$status" -eq 0 ]
  [[ "$output" == *"[lead 30]"* && "$output" == *"[lead 15]"* && "$output" == *"[lead 5]"* && "$output" == *"[lead 1]"* ]]
  [[ "$output" == *"[start]"* && "$output" == *"[ongoing 30]"* && "$output" == *"[done]"* && "$output" == *"[halted]"* && "$output" == *"[postponed]"* ]]
  [[ "$output" == *"The Mentats Prepare the Great Record"* ]]
  [ ! -e "$T/curl.args" ]
}

@test "send refuses without --yes, shows what it would show players, and sends nothing" {
  run bash "$SCRIPT" send start
  [ "$status" -eq 2 ]
  [[ "$output" == *"This would show ALL online players"* ]]
  [[ "$output" == *"Add --yes"* ]]
  [ ! -e "$T/curl.args" ]
}

@test "send --yes posts one broadcast with a bearer key on curl's stdin, never in its arguments" {
  run bash "$SCRIPT" send start --yes
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$T/curl.args")" -eq 1 ]
  grep -q '"title":"The Recording of Arrakis Begins"' "$T/curl.args"
  grep -q '"durationSec":40' "$T/curl.args"
  grep -q 'url = "http://console.test:8088/api/admin/broadcast"' "$T/curl.stdin"
  grep -q 'Bearer dak_testkey123' "$T/curl.stdin"
  ! grep -q 'dak_testkey123' "$T/curl.args"
}

@test "send --yes without configuration sends nothing and says so" {
  : >"$BK_CONFIG_DIR/backup.env"
  run bash "$SCRIPT" send start --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"not configured"* ]]
  [ ! -e "$T/curl.args" ]
}

@test "status reports configured / not configured" {
  run bash "$SCRIPT" status
  [[ "$output" == *"configured: URL http://console.test:8088"* ]]
  : >"$BK_CONFIG_DIR/backup.env"
  run bash "$SCRIPT" status
  [[ "$output" == *"NOT configured"* ]]
}

@test "a failing console never fails the caller (bk_announce always returns 0 and records the failure)" {
  source "$REPO_ROOT/scripts/backup-common.sh"
  BK_ANNOUNCE_URL=http://console.test:8088 BK_ANNOUNCE_KEY_FILE="$T/annkey"
  stub curl 'cat >/dev/null; exit 22'
  run bk_announce start
  [ "$status" -eq 0 ]
  bk_announce start
  [ "$BK_ANNOUNCE_LAST_RC" -eq 1 ]
}
