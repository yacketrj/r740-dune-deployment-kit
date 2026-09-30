#!/usr/bin/env bats
load helper

setup() {
  setup_env
  make_age_key
  export BK_SMB_MOUNT="$BATS_TEST_TMPDIR/smb"
  mkdir -p "$BK_SMB_MOUNT"
  cat >"$BK_CONFIG_DIR/backup.env" <<EOF
BK_AGE_RECIPIENT=$BK_AGE_RECIPIENT
BK_AGE_IDENTITY=$BK_AGE_IDENTITY
BK_STAGE_DIR=$BK_STAGE_DIR
BK_STATE_DIR=$BK_STATE_DIR
BK_SMB_MOUNT=$BK_SMB_MOUNT
BK_RCLONE_REMOTE=fake:r740
BK_PROD_SSH=dune@prod.test
BK_PROD_REPO=repo
BK_HOST_PATHS="etc/hostname"
BK_DISCORD_WEBHOOK_FILE=$BATS_TEST_TMPDIR/webhook
BK_MIN_STAGE_GB=0
EOF
  echo "https://discord.com/api/webhooks/1/x" >"$BATS_TEST_TMPDIR/webhook"
  # ssh stub: emit a small tar stream like the real remote `tar -cf -` (includes .env)
  mkdir -p "$BATS_TEST_TMPDIR/remote/runtime/backups/db" "$BATS_TEST_TMPDIR/remote/runtime/secrets"
  echo dump >"$BATS_TEST_TMPDIR/remote/runtime/backups/db/x.backup"
  echo s3cret >"$BATS_TEST_TMPDIR/remote/runtime/secrets/funcom-token.txt"
  echo "token123" >"$BATS_TEST_TMPDIR/remote/.env"
  stub ssh "tar -C '$BATS_TEST_TMPDIR/remote' -cf - runtime/backups/db runtime/secrets .env"
  stub rclone 'case "$1" in lsf) : ;; esac'
  stub mountpoint 'exit 0'
  stub curl 'case "$*" in *FAILED*) ;; esac'
}

@test "daily writes an encrypted archive to the SMB share and uploads it" {
  run bash "$REPO_ROOT/scripts/backup-daily.sh"
  [ "$status" -eq 0 ]
  f="$(ls "$BK_SMB_MOUNT"/daily/daily-*.tar.age)"
  [ -n "$f" ]
  grep -q "copyto" "$BATS_TEST_TMPDIR/rclone.calls"
  # decrypts and contains prod + host trees
  run bash -c "age -d -i '$BK_AGE_IDENTITY' '$f' | tar -tf -"
  [[ "$output" == *"prod/runtime/backups/db/x.backup"* ]]
  [[ "$output" == *"prod/runtime/secrets/funcom-token.txt"* ]]
  [[ "$output" == *"host/etc/hostname"* ]]
}

@test "daily leaves no plaintext or partial files in staging" {
  bash "$REPO_ROOT/scripts/backup-daily.sh"
  run bash -c "ls -A '$BK_STAGE_DIR' | wc -l"
  [ "$output" = "0" ]
}

@test "daily records success only after everything worked" {
  bash "$REPO_ROOT/scripts/backup-daily.sh"
  [ -s "$BK_STATE_DIR/last-success-daily" ]
}

@test "daily aborts and records nothing when the SMB share is not mounted" {
  stub mountpoint 'exit 1'
  run bash "$REPO_ROOT/scripts/backup-daily.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$BK_STATE_DIR/last-success-daily" ]
  [ ! -d "$BK_SMB_MOUNT/daily" ]
}

@test "daily fails closed with no recipient and writes nothing" {
  sed -i 's#^BK_AGE_RECIPIENT=.*#BK_AGE_RECIPIENT=#' "$BK_CONFIG_DIR/backup.env"
  run bash "$REPO_ROOT/scripts/backup-daily.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$BK_STATE_DIR/last-success-daily" ]
  run bash -c "ls '$BK_SMB_MOUNT'/daily 2>/dev/null | wc -l"
  [ "$output" = "0" ]
}

@test "daily fails and records nothing when the prod ssh fetch fails" {
  stub ssh 'exit 255'
  run bash "$REPO_ROOT/scripts/backup-daily.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$BK_STATE_DIR/last-success-daily" ]
  # gap (a): also assert nothing written to SMB
  [ ! -d "$BK_SMB_MOUNT/daily" ]
}

@test "daily fails and records nothing when the upload fails" {
  stub rclone 'case "$1" in copyto) exit 1 ;; esac'
  run bash "$REPO_ROOT/scripts/backup-daily.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$BK_STATE_DIR/last-success-daily" ]
}

@test "daily output never contains the secret file contents" {
  run bash "$REPO_ROOT/scripts/backup-daily.sh"
  [ "$status" -eq 0 ]  # gap (b): assert success first
  [[ "$output" != *"s3cret"* ]]
}

@test "daily ssh command includes all required paths" {
  run bash "$REPO_ROOT/scripts/backup-daily.sh"
  [ "$status" -eq 0 ]
  # gap (c): assert ssh args contain the three required paths
  grep -q "runtime/backups/db" "$BATS_TEST_TMPDIR/ssh.calls"
  grep -q "runtime/secrets" "$BATS_TEST_TMPDIR/ssh.calls"
  grep -q ".env" "$BATS_TEST_TMPDIR/ssh.calls"
}

@test "daily rclone copyto uses correct remote path" {
  run bash "$REPO_ROOT/scripts/backup-daily.sh"
  [ "$status" -eq 0 ]
  # gap (d): assert rclone copyto called with fake:r740/daily-....tar.age
  grep -q "copyto.*fake:r740/daily-" "$BATS_TEST_TMPDIR/rclone.calls"
}

@test "daily rejects overlapping run (lock contention)" {
  # gap (e): lock the script's lock file from another shell
  local lock_fd=9
  exec {lock_fd}>"$BK_STATE_DIR/daily.lock"
  flock -n "$lock_fd" || true  # get the lock
  # now the script should fail
  run bash "$REPO_ROOT/scripts/backup-daily.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$BK_STATE_DIR/last-success-daily" ]
  exec {lock_fd}>&-  # release the lock
}

@test "daily fails when not enough free space" {
  # gap (f): set a very high free space requirement
  sed -i 's#^BK_MIN_STAGE_GB=.*#BK_MIN_STAGE_GB=99999999#' "$BK_CONFIG_DIR/backup.env"
  run bash "$REPO_ROOT/scripts/backup-daily.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$BK_STATE_DIR/last-success-daily" ]
}

@test "daily alerts via Discord on unexpected errors (ERR trap)" {
  # Fix #1: make a step outside fail() fail (e.g. mv)
  stub mv 'if [[ "$*" == *".partial"* ]]; then exit 1; fi; /bin/mv "$@"'
  run bash "$REPO_ROOT/scripts/backup-daily.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$BK_STATE_DIR/last-success-daily" ]
  # assert curl was called with FAILED message
  grep -q "FAILED" "$BATS_TEST_TMPDIR/curl.calls"
}

@test "daily cleans up .partial files after failed copy" {
  # Fix #2: test that leftover .partial files are cleaned on exit
  # Pre-create a stale .partial file that should be cleaned
  mkdir -p "$BK_SMB_MOUNT/daily"
  touch "$BK_SMB_MOUNT/daily/daily-stale.tar.age.partial"
  bash "$REPO_ROOT/scripts/backup-daily.sh"
  # Any .partial files should be gone (even the one we created)
  [ "$(ls -1 "$BK_SMB_MOUNT/daily/"*.partial 2>/dev/null | wc -l)" -eq 0 ]
}

@test "daily sweeps stale daily.XXXXXX directories from staging" {
  # Fix #3: pre-create a stale directory
  mkdir -p "$BK_STAGE_DIR/daily.STALE/secret"
  echo "secret" >"$BK_STAGE_DIR/daily.STALE/secret/data"
  touch "$BK_STAGE_DIR/keepme"
  # run the script
  bash "$REPO_ROOT/scripts/backup-daily.sh"
  # stale dir should be gone, keepme should remain
  [ ! -d "$BK_STAGE_DIR/daily.STALE" ]
  [ -f "$BK_STAGE_DIR/keepme" ]
}

@test "daily rechecks mount before writing to SMB" {
  # Fix #4: make mountpoint succeed first, then fail
  local counter=0
  stub mountpoint "counter=\$(cat $BATS_TEST_TMPDIR/mp-counter 2>/dev/null || echo 0); counter=\$((counter + 1)); echo \$counter >$BATS_TEST_TMPDIR/mp-counter; [ \$counter -lt 2 ] || exit 1"
  run bash "$REPO_ROOT/scripts/backup-daily.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$BK_STATE_DIR/last-success-daily" ]
  [ ! -d "$BK_SMB_MOUNT/daily" ]
}

@test "daily fails when host config is missing or empty" {
  # Fix #5: set host path to nonexistent file
  sed -i 's#^BK_HOST_PATHS=.*#BK_HOST_PATHS="/nonexistent/path"#' "$BK_CONFIG_DIR/backup.env"
  run bash "$REPO_ROOT/scripts/backup-daily.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$BK_STATE_DIR/last-success-daily" ]
}
