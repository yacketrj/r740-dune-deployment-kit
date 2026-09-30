#!/usr/bin/env bats
load helper

setup() {
  setup_env
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/backup-common.sh"
}

@test "bk_redact removes webhook urls, age secret keys and password values" {
  run bash -c 'source "$REPO_ROOT/scripts/backup-common.sh"; printf "%s\n" \
    "hook https://discord.com/api/webhooks/123/abcSECRET" \
    "key AGE-SECRET-KEY-1QQQQQQQQQQQ" \
    "password=hunter2" | bk_redact'
  [ "$status" -eq 0 ]
  [[ "$output" != *"abcSECRET"* ]]
  [[ "$output" != *"1QQQQQQQQQQQ"* ]]
  [[ "$output" != *"hunter2"* ]]
  [[ "$output" == *"[REDACTED]"* ]]
}

@test "bk_load_config fails when the config file is missing" {
  BK_CONFIG_FILE="$BATS_TEST_TMPDIR/nope.env" run bk_load_config
  [ "$status" -eq 1 ]
}

@test "bk_notify returns 0 and does not fail the caller when the webhook is down" {
  stub curl 'exit 22'
  printf 'https://discord.com/api/webhooks/1/x\n' >"$BK_CONFIG_DIR/hook"
  BK_DISCORD_WEBHOOK_FILE="$BK_CONFIG_DIR/hook" run bk_notify "hello"
  [ "$status" -eq 0 ]
}

@test "bk_notify never prints the webhook url" {
  stub curl 'exit 0'
  printf 'https://discord.com/api/webhooks/1/TOPSECRET\n' >"$BK_CONFIG_DIR/hook"
  BK_DISCORD_WEBHOOK_FILE="$BK_CONFIG_DIR/hook" run bk_notify "hello"
  [[ "$output" != *"TOPSECRET"* ]]
}

@test "bk_lock: a second holder is refused" {
  run bash -c '
    source "$REPO_ROOT/scripts/backup-common.sh"
    bk_lock t1 || exit 10
    ( bk_lock t1 ) && exit 11
    exit 0'
  [ "$status" -eq 0 ]
}

@test "bk_require_mounted fails for a plain directory" {
  run bk_require_mounted "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
}

@test "bk_require_free_gb fails when more space is asked than exists" {
  run bk_require_free_gb "$BATS_TEST_TMPDIR" 99999999
  [ "$status" -eq 1 ]
}

@test "bk_require_free_gb passes for a trivial requirement" {
  run bk_require_free_gb "$BATS_TEST_TMPDIR" 0
  [ "$status" -eq 0 ]
}

@test "bk_age_encrypt round-trips" {
  make_age_key
  printf 'payload' >"$BATS_TEST_TMPDIR/in"
  run bk_age_encrypt "$BATS_TEST_TMPDIR/in" "$BATS_TEST_TMPDIR/out.age"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/out.age" ]
  [ ! -e "$BATS_TEST_TMPDIR/out.age.partial" ]
  run age -d -i "$BK_AGE_IDENTITY" "$BATS_TEST_TMPDIR/out.age"
  [ "$output" = "payload" ]
}

@test "bk_age_encrypt refuses an empty or malformed recipient and writes nothing" {
  printf 'payload' >"$BATS_TEST_TMPDIR/in"
  BK_AGE_RECIPIENT="" run bk_age_encrypt "$BATS_TEST_TMPDIR/in" "$BATS_TEST_TMPDIR/out.age"
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/out.age" ]
  BK_AGE_RECIPIENT="not-a-key" run bk_age_encrypt "$BATS_TEST_TMPDIR/in" "$BATS_TEST_TMPDIR/out.age"
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/out.age" ]
  [ ! -e "$BATS_TEST_TMPDIR/out.age.partial" ]
}

mk() { : >"$1/$2"; }

@test "prune_daily_monthly keeps newest N daily plus the newest of each of M months" {
  d="$BATS_TEST_TMPDIR/p"; mkdir -p "$d"
  for f in daily-20260701-040000 daily-20260702-040000 daily-20260801-040000 \
           daily-20260815-040000 daily-20260920-040000 daily-20260921-040000 \
           daily-20260922-040000; do mk "$d" "$f.tar.age"; done
  bk_prune_daily_monthly "$d" daily 2 2
  run ls "$d"
  # newest 2 daily (0921, 0922) + newest of the 2 newest months (Sep=0922 already kept, Aug=0815)
  [[ "$output" == *"daily-20260922-040000.tar.age"* ]]
  [[ "$output" == *"daily-20260921-040000.tar.age"* ]]
  [[ "$output" == *"daily-20260815-040000.tar.age"* ]]
  [[ "$output" != *"daily-20260701-040000.tar.age"* ]]
  [[ "$output" != *"daily-20260702-040000.tar.age"* ]]
  [[ "$output" != *"daily-20260801-040000.tar.age"* ]]
  [[ "$output" != *"daily-20260920-040000.tar.age"* ]]
}

@test "prune_daily_monthly deletes nothing on an empty directory" {
  d="$BATS_TEST_TMPDIR/e"; mkdir -p "$d"
  run bk_prune_daily_monthly "$d" daily 30 12
  [ "$status" -eq 0 ]
}

@test "prune_daily_monthly never touches non-matching files and keeps everything when under the limit" {
  d="$BATS_TEST_TMPDIR/n"; mkdir -p "$d"
  mk "$d" notes.txt; mk "$d" daily-20260901-040000.tar.age.partial
  mk "$d" daily-20260901-040000.tar.age
  bk_prune_daily_monthly "$d" daily 30 12
  [ -e "$d/notes.txt" ]
  [ -e "$d/daily-20260901-040000.tar.age.partial" ]
  [ -e "$d/daily-20260901-040000.tar.age" ]
}

@test "prune_keep_newest keeps the newest N per prefix and ignores other prefixes" {
  d="$BATS_TEST_TMPDIR/w"; mkdir -p "$d"
  for f in vm101-20260901-020000 vm101-20260908-020000 vm101-20260915-020000 vm101-20260922-020000 vm102-20260901-020000; do
    mk "$d" "$f.vma.zst.age"; done
  bk_prune_keep_newest "$d" vm101 3
  [ ! -e "$d/vm101-20260901-020000.vma.zst.age" ]
  [ -e "$d/vm101-20260922-020000.vma.zst.age" ]
  [ -e "$d/vm101-20260915-020000.vma.zst.age" ]
  [ -e "$d/vm101-20260908-020000.vma.zst.age" ]
  [ -e "$d/vm102-20260901-020000.vma.zst.age" ]
}

@test "prune_remote deletes exactly the names local pruning would drop" {
  stub rclone '
    case "$1" in
      lsf) printf "daily-20260701-040000.tar.age\ndaily-20260921-040000.tar.age\ndaily-20260922-040000.tar.age\n" ;;
      deletefile) : ;;
    esac'
  run bk_prune_remote "onedrive-crypt:r740" daily 2 1
  [ "$status" -eq 0 ]
  grep -q "deletefile onedrive-crypt:r740/daily-20260701-040000.tar.age" "$BATS_TEST_TMPDIR/rclone.calls"
  run grep "deletefile onedrive-crypt:r740/daily-2026092" "$BATS_TEST_TMPDIR/rclone.calls"
  [ "$status" -ne 0 ]
}

@test "state_touch then state_age_seconds is small; a missing tier is huge" {
  bk_state_touch daily
  age="$(bk_state_age_seconds daily)"
  [ "$age" -lt 5 ]
  age="$(bk_state_age_seconds weekly)"
  [ "$age" -gt 100000000 ]
}

# Finding 1: Prune functions validate retention counts
@test "bk_prune_daily_monthly rejects empty keep_daily and keeps all files" {
  d="$BATS_TEST_TMPDIR/p1"; mkdir -p "$d"
  mk "$d" daily-20260901-040000.tar.age
  mk "$d" daily-20260902-040000.tar.age
  run bk_prune_daily_monthly "$d" daily "" 2
  [ "$status" -eq 1 ]
  [ -e "$d/daily-20260901-040000.tar.age" ]
  [ -e "$d/daily-20260902-040000.tar.age" ]
}

@test "bk_prune_daily_monthly rejects non-numeric keep_daily and keeps all files" {
  d="$BATS_TEST_TMPDIR/p2"; mkdir -p "$d"
  mk "$d" daily-20260901-040000.tar.age
  mk "$d" daily-20260902-040000.tar.age
  run bk_prune_daily_monthly "$d" daily "abc" 2
  [ "$status" -eq 1 ]
  [ -e "$d/daily-20260901-040000.tar.age" ]
  [ -e "$d/daily-20260902-040000.tar.age" ]
}

@test "bk_prune_daily_monthly rejects zero keep_daily and keeps all files" {
  d="$BATS_TEST_TMPDIR/p3"; mkdir -p "$d"
  mk "$d" daily-20260901-040000.tar.age
  mk "$d" daily-20260902-040000.tar.age
  run bk_prune_daily_monthly "$d" daily 0 2
  [ "$status" -eq 1 ]
  [ -e "$d/daily-20260901-040000.tar.age" ]
  [ -e "$d/daily-20260902-040000.tar.age" ]
}

@test "bk_prune_daily_monthly strengthened: low retention with mixed files" {
  d="$BATS_TEST_TMPDIR/p4"; mkdir -p "$d"
  mk "$d" notes.txt
  mk "$d" daily-20260901-040000.tar.age.partial
  mk "$d" daily-20260901-040000.tar.age
  mk "$d" daily-20260902-040000.tar.age
  mk "$d" daily-20260903-040000.tar.age
  bk_prune_daily_monthly "$d" daily 1 1
  [ -e "$d/notes.txt" ]
  [ -e "$d/daily-20260901-040000.tar.age.partial" ]
  [ -e "$d/daily-20260903-040000.tar.age" ]
  [ ! -e "$d/daily-20260901-040000.tar.age" ]
  [ ! -e "$d/daily-20260902-040000.tar.age" ]
}

@test "bk_prune_keep_newest rejects empty keep and keeps all files" {
  d="$BATS_TEST_TMPDIR/w1"; mkdir -p "$d"
  mk "$d" vm101-20260901-020000.vma.zst.age
  mk "$d" vm101-20260908-020000.vma.zst.age
  run bk_prune_keep_newest "$d" vm101 ""
  [ "$status" -eq 1 ]
  [ -e "$d/vm101-20260901-020000.vma.zst.age" ]
  [ -e "$d/vm101-20260908-020000.vma.zst.age" ]
}

@test "bk_prune_keep_newest rejects non-numeric keep and keeps all files" {
  d="$BATS_TEST_TMPDIR/w2"; mkdir -p "$d"
  mk "$d" vm101-20260901-020000.vma.zst.age
  mk "$d" vm101-20260908-020000.vma.zst.age
  run bk_prune_keep_newest "$d" vm101 "xyz"
  [ "$status" -eq 1 ]
  [ -e "$d/vm101-20260901-020000.vma.zst.age" ]
  [ -e "$d/vm101-20260908-020000.vma.zst.age" ]
}

# Finding 2: bk_require_free_gb validates need parameter
@test "bk_require_free_gb rejects empty need parameter" {
  run bk_require_free_gb "$BATS_TEST_TMPDIR" ""
  [ "$status" -eq 1 ]
}

@test "bk_require_free_gb rejects non-numeric need parameter" {
  run bk_require_free_gb "$BATS_TEST_TMPDIR" "abc"
  [ "$status" -eq 1 ]
}

# Finding 3: bk_notify survives under set -e when jq fails
@test "bk_notify survives under set -e when jq fails" {
  stub curl 'cat >/dev/null; exit 0'
  stub jq 'exit 1'
  printf 'https://discord.com/api/webhooks/1/x\n' >"$BK_CONFIG_DIR/hook"
  BK_DISCORD_WEBHOOK_FILE="$BK_CONFIG_DIR/hook" run bash -c 'set -e; source "$REPO_ROOT/scripts/backup-common.sh"; bk_notify hi; echo survived'
  [ "$status" -eq 0 ]
  [[ "$output" == *"survived"* ]]
}

# Finding 4: bk_notify does not expose webhook URL on command line
@test "bk_notify does not pass webhook URL as curl argument" {
  stub curl 'cat >/dev/null; echo "$*" >>"$BATS_TEST_TMPDIR/curl.args"'
  printf 'https://discord.com/api/webhooks/1/TOPSECRET99\n' >"$BK_CONFIG_DIR/hook"
  BK_DISCORD_WEBHOOK_FILE="$BK_CONFIG_DIR/hook" bk_notify "hello"
  [[ ! "$(<"$BATS_TEST_TMPDIR/curl.args")" == *"TOPSECRET99"* ]]
}

# Finding 5: bk_notify redacts the message
@test "bk_notify redacts secrets in the message" {
  stub curl 'cat >/dev/null; echo "$*" >>"$BATS_TEST_TMPDIR/curl.args"'
  stub jq 'printf "{\"content\":\"%s\"}" "$4"'
  printf 'https://discord.com/api/webhooks/1/x\n' >"$BK_CONFIG_DIR/hook"
  BK_DISCORD_WEBHOOK_FILE="$BK_CONFIG_DIR/hook" bk_notify "password=hunter2 and token=secret123"
  args="$(<"$BATS_TEST_TMPDIR/curl.args")"
  [[ "$args" != *"hunter2"* ]]
  [[ "$args" != *"secret123"* ]]
  [[ "$args" == *"[REDACTED]"* ]]
}

# Finding 6: bk_redact handles additional secret shapes
@test "bk_redact handles spaces around = in password/token/secret" {
  run bash -c 'source "$REPO_ROOT/scripts/backup-common.sh"; printf "%s\n" \
    "password = mypass" \
    "token = mytoken" \
    "secret = mysecret" \
    "pass = mypass2" | bk_redact'
  [ "$status" -eq 0 ]
  [[ "$output" != *"mypass"* ]]
  [[ "$output" != *"mytoken"* ]]
  [[ "$output" != *"mysecret"* ]]
  [[ "$output" != *"mypass2"* ]]
  [[ "$output" == *"[REDACTED]"* ]]
}

@test "bk_redact handles JSON-style secrets with closing quote before colon" {
  run bash -c 'source "$REPO_ROOT/scripts/backup-common.sh"; printf "%s\n" \
    "\"token\":\"abc123\"" \
    "\"password\": \"secret\"" | bk_redact'
  [ "$status" -eq 0 ]
  [[ "$output" != *"abc123"* ]]
  [[ "$output" != *"secret"* ]]
  [[ "$output" == *"[REDACTED]"* ]]
}

@test "bk_redact handles Authorization Bearer headers" {
  run bash -c 'source "$REPO_ROOT/scripts/backup-common.sh"; printf "%s\n" \
    "Authorization: Bearer mytoken123" \
    "Bearer mytoken456" | bk_redact'
  [ "$status" -eq 0 ]
  [[ "$output" != *"mytoken123"* ]]
  [[ "$output" != *"mytoken456"* ]]
  [[ "$output" == *"Bearer"* ]]
  [[ "$output" == *"[REDACTED]"* ]]
}

@test "bk_redact handles additional Discord webhook hosts" {
  run bash -c 'source "$REPO_ROOT/scripts/backup-common.sh"; printf "%s\n" \
    "hook https://ptb.discord.com/api/webhooks/1/secret1" \
    "hook https://canary.discord.com/api/webhooks/2/secret2" | bk_redact'
  [ "$status" -eq 0 ]
  [[ "$output" != *"secret1"* ]]
  [[ "$output" != *"secret2"* ]]
  [[ "$output" == *"[REDACTED]"* ]]
}

# ---------------------------------------------------------------------------
# v2 additions
# ---------------------------------------------------------------------------

@test "isolation: refuses a state dir outside the test temp dir" {
  BK_STATE_DIR="${BATS_TEST_TMPDIR}-outside/state" run bk_require_test_isolation
  [ "$status" -eq 1 ]
}

@test "isolation: accepts a state dir under the test temp dir" {
  BK_STATE_DIR="$BATS_TEST_TMPDIR/state" run bk_require_test_isolation
  [ "$status" -eq 0 ]
}

@test "isolation: state-writing functions refuse and create nothing outside the test dir" {
  BK_STATE_DIR="${BATS_TEST_TMPDIR}-outside/state" run bk_lock t1
  [ "$status" -eq 1 ]
  BK_STATE_DIR="${BATS_TEST_TMPDIR}-outside/state" run bk_state_touch daily
  [ "$status" -eq 1 ]
  [ ! -e "${BATS_TEST_TMPDIR}-outside" ]
}

@test "valid vmid accepts real ids and rejects everything else" {
  for ok in 100 101 102 103 104 999999; do bk_valid_vmid "$ok"; done
  for bad in "" 0 99 010 abc "101;rm" "1 2" "-1" '$(id)' "10.1"; do
    run bk_valid_vmid "$bad"
    [ "$status" -eq 1 ]
  done
}

@test "safe_rm removes a path inside the root" {
  mkdir -p "$BATS_TEST_TMPDIR/root/a/b"; : >"$BATS_TEST_TMPDIR/root/a/b/f"
  run bk_safe_rm_under "$BATS_TEST_TMPDIR/root" "$BATS_TEST_TMPDIR/root/a"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/root/a" ]
}

@test "safe_rm refuses empty arguments, the root itself, / and outside paths, deleting nothing" {
  mkdir -p "$BATS_TEST_TMPDIR/root" "$BATS_TEST_TMPDIR/other"; : >"$BATS_TEST_TMPDIR/other/keep"
  run bk_safe_rm_under "" "$BATS_TEST_TMPDIR/other";                 [ "$status" -eq 1 ]
  run bk_safe_rm_under "$BATS_TEST_TMPDIR/root" "";                   [ "$status" -eq 1 ]
  run bk_safe_rm_under "$BATS_TEST_TMPDIR/root" "$BATS_TEST_TMPDIR/root"; [ "$status" -eq 1 ]
  run bk_safe_rm_under "/" "/usr";                                    [ "$status" -eq 1 ]
  run bk_safe_rm_under "$BATS_TEST_TMPDIR/root" "$BATS_TEST_TMPDIR/other"; [ "$status" -eq 1 ]
  [ -d "$BATS_TEST_TMPDIR/root" ]
  [ -e "$BATS_TEST_TMPDIR/other/keep" ]
}

@test "safe_rm refuses .. traversal and symlink escapes" {
  mkdir -p "$BATS_TEST_TMPDIR/root" "$BATS_TEST_TMPDIR/outside"; : >"$BATS_TEST_TMPDIR/outside/keep"
  run bk_safe_rm_under "$BATS_TEST_TMPDIR/root" "$BATS_TEST_TMPDIR/root/../outside"
  [ "$status" -eq 1 ]
  ln -s "$BATS_TEST_TMPDIR/outside" "$BATS_TEST_TMPDIR/root/link"
  run bk_safe_rm_under "$BATS_TEST_TMPDIR/root" "$BATS_TEST_TMPDIR/root/link"
  [ "$status" -eq 1 ]
  [ -e "$BATS_TEST_TMPDIR/outside/keep" ]
}

@test "manifest records sha256, size and name" {
  printf 'abc' >"$BATS_TEST_TMPDIR/f.bin"
  run bk_manifest_add "$BATS_TEST_TMPDIR/m.txt" "$BATS_TEST_TMPDIR/f.bin"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/m.txt")" = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  3  f.bin" ]
}

@test "manifest refuses a missing file and writes nothing" {
  run bk_manifest_add "$BATS_TEST_TMPDIR/m.txt" "$BATS_TEST_TMPDIR/none"
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/m.txt" ]
}

@test "verify_copy passes for identical files and fails for a differing or missing one" {
  printf 'same' >"$BATS_TEST_TMPDIR/a"; printf 'same' >"$BATS_TEST_TMPDIR/b"; printf 'diff' >"$BATS_TEST_TMPDIR/c"
  run bk_verify_copy "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"; [ "$status" -eq 0 ]
  run bk_verify_copy "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/c"; [ "$status" -eq 1 ]
  run bk_verify_copy "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/none"; [ "$status" -eq 1 ]
}

@test "dead_man: not configured returns 3 without failing the caller" {
  BK_DEADMAN_URL_FILE="" run bk_dead_man_ping
  [ "$status" -eq 3 ]
  BK_DEADMAN_URL_FILE="$BATS_TEST_TMPDIR/none" run bk_dead_man_ping
  [ "$status" -eq 3 ]
}

@test "dead_man: an unreachable service returns 4" {
  stub curl 'cat >/dev/null; exit 22'
  printf 'https://hc.example/ping/abc\n' >"$BATS_TEST_TMPDIR/dm"
  BK_DEADMAN_URL_FILE="$BATS_TEST_TMPDIR/dm" run bk_dead_man_ping
  [ "$status" -eq 4 ]
}

@test "dead_man: success returns 0 and the URL is on stdin, never in argv" {
  stub curl 'cat >"$BATS_TEST_TMPDIR/curl.stdin"'
  printf 'https://hc.example/ping/TOPSECRETID\n' >"$BATS_TEST_TMPDIR/dm"
  BK_DEADMAN_URL_FILE="$BATS_TEST_TMPDIR/dm" run bk_dead_man_ping
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/curl.calls" ]
  run grep -q TOPSECRETID "$BATS_TEST_TMPDIR/curl.calls"
  [ "$status" -ne 0 ]
  grep -q "TOPSECRETID" "$BATS_TEST_TMPDIR/curl.stdin"
}

@test "dead_man: 'fail' pings the failure endpoint" {
  stub curl 'cat >"$BATS_TEST_TMPDIR/curl.stdin"'
  printf 'https://hc.example/ping/abc/\n' >"$BATS_TEST_TMPDIR/dm"
  BK_DEADMAN_URL_FILE="$BATS_TEST_TMPDIR/dm" run bk_dead_man_ping fail
  [ "$status" -eq 0 ]
  grep -q 'ping/abc/fail' "$BATS_TEST_TMPDIR/curl.stdin"
}

@test "alert: names the job, stage, error, re-run command and runbook" {
  stub curl 'cat >/dev/null; echo "$*" >>"$BATS_TEST_TMPDIR/curl.args"'
  printf 'https://discord.com/api/webhooks/1/x\n' >"$BK_CONFIG_DIR/hook"
  BK_DISCORD_WEBHOOK_FILE="$BK_CONFIG_DIR/hook" BK_JOB="daily set" BK_RUNBOOK_URL="docs/08.md" \
    run bk_alert upload "connection reset" "bash scripts/backup-daily.sh --tier daily"
  [ "$status" -eq 0 ]
  grep -q "daily set" "$BATS_TEST_TMPDIR/curl.args"
  grep -q "stage 'upload'" "$BATS_TEST_TMPDIR/curl.args"
  grep -q "connection reset" "$BATS_TEST_TMPDIR/curl.args"
  grep -q "backup-daily.sh --tier daily" "$BATS_TEST_TMPDIR/curl.args"
  grep -q "docs/08.md" "$BATS_TEST_TMPDIR/curl.args"
}

@test "alert: redacts secrets in the error and survives a dead webhook" {
  stub curl 'cat >/dev/null; echo "$*" >>"$BATS_TEST_TMPDIR/curl.args"; exit 22'
  printf 'https://discord.com/api/webhooks/1/x\n' >"$BK_CONFIG_DIR/hook"
  BK_DISCORD_WEBHOOK_FILE="$BK_CONFIG_DIR/hook" run bk_alert upload "token=hunter2 failed" "rerun"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/curl.args" ]
  run grep -q hunter2 "$BATS_TEST_TMPDIR/curl.args"
  [ "$status" -ne 0 ]
}

@test "audit: appends a JSON line with the fields and redacts values" {
  run bk_audit_log run_ok tier=daily file=daily-1.tar.age note="password=hunter2"
  [ "$status" -eq 0 ]
  line="$(tail -n 1 "$BK_STATE_DIR/audit.log")"
  [ "$(printf '%s' "$line" | jq -r .event)" = "run_ok" ]
  [ "$(printf '%s' "$line" | jq -r .tier)" = "daily" ]
  [ "$(printf '%s' "$line" | jq -r .file)" = "daily-1.tar.age" ]
  [[ "$line" != *hunter2* ]]
}

@test "audit: ignores reserved and invalid keys instead of failing" {
  run bk_audit_log e time=evil "bad key=x" 'ok_key=fine'
  [ "$status" -eq 0 ]
  line="$(tail -n 1 "$BK_STATE_DIR/audit.log")"
  [ "$(printf '%s' "$line" | jq -r .ok_key)" = "fine" ]
  [ "$(printf '%s' "$line" | jq -r .time)" != "evil" ]
}

@test "audit: mirrors to the ship directory when it exists, and tolerates it missing" {
  mkdir -p "$BATS_TEST_TMPDIR/ship"
  BK_AUDIT_SHIP_DIR="$BATS_TEST_TMPDIR/ship" run bk_audit_log shipped
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$BATS_TEST_TMPDIR/ship/audit.log" | jq -r .event)" = "shipped" ]
  BK_AUDIT_SHIP_DIR="$BATS_TEST_TMPDIR/absent" run bk_audit_log unshipped
  [ "$status" -eq 0 ]
}

@test "audit: writes nothing outside the test temp dir" {
  BK_STATE_DIR="${BATS_TEST_TMPDIR}-outside/state" run bk_audit_log x
  [ "$status" -eq 0 ]
  [ ! -e "${BATS_TEST_TMPDIR}-outside" ]
}

@test "secure_umask sets 077" {
  bk_secure_umask
  [ "$(umask)" = "0077" ]
}

@test "notify records delivery: 0 delivered, 1 failed, 2 skipped, and never fails the caller" {
  BK_DISCORD_WEBHOOK_FILE="" bk_notify hi
  [ "$BK_NOTIFY_LAST_RC" -eq 2 ]
  printf 'https://discord.com/api/webhooks/1/x\n' >"$BK_CONFIG_DIR/hook"
  stub curl 'cat >/dev/null; exit 22'
  BK_DISCORD_WEBHOOK_FILE="$BK_CONFIG_DIR/hook" bk_notify hi
  [ "$BK_NOTIFY_LAST_RC" -eq 1 ]
  stub curl 'cat >/dev/null'
  BK_DISCORD_WEBHOOK_FILE="$BK_CONFIG_DIR/hook" bk_notify hi
  [ "$BK_NOTIFY_LAST_RC" -eq 0 ]
}

@test "evidence appends a tab-separated record" {
  bk_evidence drill-db PASS "archive=x rows=5"
  [ "$(tail -n 1 "$BK_STATE_DIR/evidence.log" | cut -f2-4)" = "$(printf 'drill-db\tPASS\tarchive=x rows=5')" ]
}

@test "evidence writes nothing outside the test temp dir" {
  BK_STATE_DIR="${BATS_TEST_TMPDIR}-outside/state" run bk_evidence a PASS b
  [ "$status" -eq 0 ]
  [ ! -e "${BATS_TEST_TMPDIR}-outside" ]
}

@test "ram dir is private and wipe removes it and its contents" {
  export BK_RAM_DIR="$BATS_TEST_TMPDIR/ram"; mkdir -p "$BK_RAM_DIR"
  d="$(bk_make_ram_dir)"
  [ "$(stat -c %a "$d")" = "700" ]
  echo secret >"$d/f"
  run bk_wipe_dir "$d"
  [ "$status" -eq 0 ]
  [ ! -e "$d" ]
}

@test "wipe refuses anything that is not a bk-work dir under the RAM base" {
  export BK_RAM_DIR="$BATS_TEST_TMPDIR/ram"; mkdir -p "$BK_RAM_DIR/other" "$BATS_TEST_TMPDIR/elsewhere/bk-work.x"
  echo keep >"$BK_RAM_DIR/other/f"
  run bk_wipe_dir "$BK_RAM_DIR/other"; [ "$status" -eq 1 ]
  run bk_wipe_dir "$BATS_TEST_TMPDIR/elsewhere/bk-work.x"; [ "$status" -eq 1 ]
  run bk_wipe_dir "/"; [ "$status" -eq 1 ]
  [ -e "$BK_RAM_DIR/other/f" ]
  run bk_wipe_dir ""; [ "$status" -eq 0 ]
}

@test "ram dir fails cleanly when the RAM base is missing" {
  BK_RAM_DIR="$BATS_TEST_TMPDIR/nope" run bk_make_ram_dir
  [ "$status" -eq 1 ]
}

@test "bk_tar_members_safe accepts regular files and directories only" {
  d="$BATS_TEST_TMPDIR/tsafe"; mkdir -p "$d/dir"; echo a >"$d/dir/f"
  tar -C "$d" -cf "$BATS_TEST_TMPDIR/ok.tar" dir
  run bk_tar_members_safe "$BATS_TEST_TMPDIR/ok.tar"; [ "$status" -eq 0 ]
  ln -s /etc "$d/dir/sym"
  tar -C "$d" -cf "$BATS_TEST_TMPDIR/sym.tar" dir
  run bk_tar_members_safe "$BATS_TEST_TMPDIR/sym.tar"; [ "$status" -ne 0 ]
  rm "$d/dir/sym"; ln "$d/dir/f" "$d/dir/hard"
  tar -C "$d" -cf "$BATS_TEST_TMPDIR/hard.tar" dir
  run bk_tar_members_safe "$BATS_TEST_TMPDIR/hard.tar"; [ "$status" -ne 0 ]
  run bk_tar_members_safe "$BATS_TEST_TMPDIR/missing.tar"; [ "$status" -ne 0 ]
  : >"$BATS_TEST_TMPDIR/empty.tar"
  run bk_tar_members_safe "$BATS_TEST_TMPDIR/empty.tar"; [ "$status" -ne 0 ]
}

@test "pruning ignores a planted future-dated name instead of keeping it over real backups" {
  d="$BATS_TEST_TMPDIR/pl"; mkdir -p "$d"
  for n in 20260101-010000 20260102-010000 20260103-010000; do : >"$d/daily-$n.tar.age"; done
  : >"$d/daily-99991231-235959.tar.age"
  bk_prune_daily_monthly "$d" daily 1 1
  [ -e "$d/daily-99991231-235959.tar.age" ]        # left alone, not counted
  [ -e "$d/daily-20260103-010000.tar.age" ]        # the real newest survives
  [ ! -e "$d/daily-20260101-010000.tar.age" ]
  mkdir -p "$d/w"
  : >"$d/w/vm102-20260101-010000.vma.zst.age"
  : >"$d/w/vm102-20260108-010000.vma.zst.age"
  : >"$d/w/vm102-99991231-235959.vma.zst.age"
  bk_prune_keep_newest "$d/w" vm102 1
  [ -e "$d/w/vm102-20260108-010000.vma.zst.age" ]  # real newest kept
  [ ! -e "$d/w/vm102-20260101-010000.vma.zst.age" ]
  [ -e "$d/w/vm102-99991231-235959.vma.zst.age" ]
}

@test "bk_notify counts an HTTP error from the webhook as a failure (real curl, local server)" {
  srv="$BATS_TEST_TMPDIR/srv.py"
  cat >"$srv" <<'PY'
import http.server, sys
code = int(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(code); self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.handle_request()
PY
  for code in 404 204; do
    python3 "$srv" "$code" >"$BATS_TEST_TMPDIR/port" &
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$BATS_TEST_TMPDIR/port" ] && break; sleep 0.2; done
    printf 'http://127.0.0.1:%s/hook\n' "$(cat "$BATS_TEST_TMPDIR/port")" >"$BK_CONFIG_DIR/hook"
    BK_DISCORD_WEBHOOK_FILE="$BK_CONFIG_DIR/hook"
    bk_notify "hi"
    if [ "$code" = 404 ]; then [ "$BK_NOTIFY_LAST_RC" -eq 1 ]; else [ "$BK_NOTIFY_LAST_RC" -eq 0 ]; fi
    wait
    rm -f "$BATS_TEST_TMPDIR/port"
  done
}

@test "bk_redact covers quoted secret keys, url userinfo and basic auth" {
  run bash -c 'source "$REPO_ROOT/scripts/backup-common.sh"; printf "%s\n" \
    "{\"client_secret\":\"s3cret1\",\"access_token\":\"tok2\"}" \
    "postgres://u:hunter3@host/db" \
    "Authorization: Basic dXNlcjpwdw==" | bk_redact'
  [[ "$output" != *"s3cret1"* && "$output" != *"tok2"* && "$output" != *"hunter3"* && "$output" != *"dXNlcjpwdw"* ]]
}

@test "bk_notify truncates a message longer than Discord's limit" {
  stub curl 'cat >/dev/null; for a in "$@"; do printf "%s\n" "$a"; done >"$BATS_TEST_TMPDIR/curl.args"'
  printf 'https://discord.com/api/webhooks/1/x\n' >"$BK_CONFIG_DIR/hook"
  BK_DISCORD_WEBHOOK_FILE="$BK_CONFIG_DIR/hook" bk_notify "$(head -c 5000 /dev/zero | tr '\0' 'a')"
  [ "$(wc -c <"$BATS_TEST_TMPDIR/curl.args")" -lt 2300 ]
}
