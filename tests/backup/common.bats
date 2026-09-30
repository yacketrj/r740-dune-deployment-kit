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
