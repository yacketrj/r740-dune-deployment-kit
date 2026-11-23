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

# --- retries and the post-run audit (2026-11-23: the 05:00 game restart made the first warning fail) ---

ann_cfg_env() {
  source "$REPO_ROOT/scripts/backup-common.sh"
  BK_ANNOUNCE_URL=http://console.test:8088 BK_ANNOUNCE_KEY_FILE="$T/annkey"
}

@test "a failed announcement is retried and the log says it took more than one attempt" {
  ann_cfg_env
  BK_ANNOUNCE_RETRY_BUDGET_S=5 BK_ANNOUNCE_RETRY_S=0
  stub curl 'cat >/dev/null; n=$(cat "$BATS_TEST_TMPDIR/n" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" >"$BATS_TEST_TMPDIR/n"; if [ "$n" -lt 3 ]; then echo "curl: (22) The requested URL returned error: 409"; exit 22; fi; exit 0'
  bk_announce lead 30 >"$T/out" 2>&1
  [ "$BK_ANNOUNCE_LAST_RC" -eq 0 ]
  [ "$BK_ANN_SENT" -eq 1 ] && [ "$BK_ANN_FAILED" -eq 0 ]
  grep -q "announce retry: lead (attempt 1 failed: curl: (22) The requested URL returned error: 409)" "$T/out"
  grep -q "announced in game: lead (The Mentats Prepare the Great Record) after 3 attempts" "$T/out"
  ! grep -q "announce FAILED" "$T/out"
}

@test "when every retry fails the log names the attempts and the reason, the counters record it, and the caller still gets 0" {
  ann_cfg_env
  BK_ANNOUNCE_RETRY_BUDGET_S=1 BK_ANNOUNCE_RETRY_S=1
  stub curl 'cat >/dev/null; echo "{\"error\":\"broadcast blocked while the game restarts\"}"; exit 22'
  run bk_announce lead 30
  [ "$status" -eq 0 ]
  bk_announce lead 30 >"$T/out" 2>&1
  [ "$BK_ANNOUNCE_LAST_RC" -eq 1 ]
  [ "$BK_ANN_SENT" -eq 0 ] && [ "$BK_ANN_FAILED" -eq 1 ]
  grep -q "announce FAILED: lead after 2 attempt(s): .*broadcast blocked while the game restarts" "$T/out"
  grep -q "the backup is not affected" "$T/out"
}

@test "a budget of 0 means one try and no retry, as before" {
  ann_cfg_env
  BK_ANNOUNCE_RETRY_BUDGET_S=0
  stub curl 'cat >/dev/null; echo "curl: (22) boom"; exit 22'
  bk_announce start >"$T/out" 2>&1
  grep -q "announce FAILED: start after 1 attempt(s): curl: (22) boom" "$T/out"
  ! grep -q "announce retry" "$T/out"
}

@test "the API key never appears in the announcement log, even when the console echoes an error" {
  ann_cfg_env
  BK_ANNOUNCE_RETRY_BUDGET_S=0
  stub curl 'cat >/dev/null; echo "curl: (22) The requested URL returned error: 401"; exit 22'
  bk_announce start >"$T/out" 2>&1
  ! grep -q "dak_testkey123" "$T/out"
}

audit_history() { # lines... (tab-separated console history), written as the guest agent would return them
  jq -nc --arg d "$(printf '%s\n' "$@")" '{exitcode:0, "out-data":$d}' >"$T/qm.out"
  stub qm 'cat "$BATS_TEST_TMPDIR/qm.out"'
}
hist() { printf '%s\twebb\tall\t%s\trmq:heartbeats/notifications\t%s\t{}' "$1" "$2" "$3" | sed 's/webb/web-broadcast/'; }

@test "audit: matching counts are reported OK, and history from before this run or for other messages is ignored" {
  ann_cfg_env
  BK_ANNOUNCE_AUDIT=1 BK_ANNOUNCE_AUDIT_SETTLE_S=0 BK_RUN_START_ISO="2026-11-24T13:00:00" BK_ANN_SENT=2 BK_ANN_FAILED=0
  audit_history "$(hist 2026-11-17T13:17:00.8Z 'The Mentats Prepare the Great Record' published)" \
    "$(hist 2026-11-24T13:17:00.8Z 'The Mentats Prepare the Great Record' published)" \
    "$(hist 2026-11-24T13:32:10.9Z 'The Recording of Arrakis Begins' published)" \
    "$(hist 2026-11-24T13:40:00.0Z 'Some other broadcast' published)"
  bk_announce_audit >"$T/out" 2>&1
  grep -q "announce audit: script sent 2 ok / 0 failed; console history: 2 published, 0 blocked or other attempt(s): OK" "$T/out"
}

@test "audit: blocked attempts (the failed tries of a retried announcement) are reported but not counted as a mismatch" {
  ann_cfg_env
  BK_ANNOUNCE_AUDIT=1 BK_ANNOUNCE_AUDIT_SETTLE_S=0 BK_RUN_START_ISO="2026-11-24T13:00:00" BK_ANN_SENT=2 BK_ANN_FAILED=0
  audit_history "$(hist 2026-11-24T13:01:59.3Z 'The Mentats Prepare the Great Record' blocked)" \
    "$(hist 2026-11-24T13:02:59.3Z 'The Mentats Prepare the Great Record' blocked)" \
    "$(hist 2026-11-24T13:03:59.3Z 'The Mentats Prepare the Great Record' published)" \
    "$(hist 2026-11-24T13:32:10.9Z 'The Recording of Arrakis Begins' published)"
  bk_announce_audit >"$T/out" 2>&1
  grep -q "console history: 2 published, 2 blocked or other attempt(s): OK" "$T/out"
}

@test "audit: a different published count than the script counted is flagged MISMATCH" {
  ann_cfg_env
  BK_ANNOUNCE_AUDIT=1 BK_ANNOUNCE_AUDIT_SETTLE_S=0 BK_RUN_START_ISO="2026-11-24T13:00:00" BK_ANN_SENT=3 BK_ANN_FAILED=0
  audit_history "$(hist 2026-11-24T13:17:00.8Z 'The Mentats Prepare the Great Record' published)" \
    "$(hist 2026-11-24T13:32:10.9Z 'The Recording of Arrakis Begins' published)"
  bk_announce_audit >"$T/out" 2>&1
  grep -q "MISMATCH (the console published 2, the script counted 3 as sent)" "$T/out"
}

@test "audit: an unreadable console history is logged and ignored, never fatal" {
  ann_cfg_env
  BK_ANNOUNCE_AUDIT=1 BK_ANNOUNCE_AUDIT_SETTLE_S=0 BK_RUN_START_ISO="2026-11-24T13:00:00" BK_ANN_SENT=1 BK_ANN_FAILED=0
  stub qm 'exit 1'
  run bk_announce_audit
  [ "$status" -eq 0 ]
  [[ "$output" == *"announce audit: could not read the console history on guest 101 (ignored)"* ]]
}

@test "audit: nothing announced, or BK_ANNOUNCE_AUDIT=0, means no audit and no guest-agent call" {
  ann_cfg_env
  stub qm 'echo called >>"$BATS_TEST_TMPDIR/qm.called"'
  BK_ANNOUNCE_AUDIT=1 BK_ANN_SENT=0 BK_ANN_FAILED=0
  run bk_announce_audit
  [ "$status" -eq 0 ] && [ -z "$output" ]
  BK_ANNOUNCE_AUDIT=0 BK_ANN_SENT=3
  run bk_announce_audit
  [ "$status" -eq 0 ] && [ -z "$output" ]
  [ ! -e "$T/qm.called" ]
}

@test "the weekly job runs the audit right after its closing announcement" {
  run grep -n -A3 "closing message sent" "$REPO_ROOT/scripts/backup-weekly.sh"
  [[ "$output" == *"bk_announce_audit"* ]]
}
