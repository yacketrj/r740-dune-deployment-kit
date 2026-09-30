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
BK_DISCORD_WEBHOOK_FILE=
BK_MIN_STAGE_GB=0
EOF
  # ssh stub: emit a small tar stream like the real remote `tar -cf -`
  mkdir -p "$BATS_TEST_TMPDIR/remote/runtime/backups/db" "$BATS_TEST_TMPDIR/remote/runtime/secrets"
  echo dump >"$BATS_TEST_TMPDIR/remote/runtime/backups/db/x.backup"
  echo s3cret >"$BATS_TEST_TMPDIR/remote/runtime/secrets/funcom-token.txt"
  stub ssh "tar -C '$BATS_TEST_TMPDIR/remote' -cf - runtime/backups/db runtime/secrets"
  stub rclone 'case "$1" in lsf) : ;; esac'
  stub mountpoint 'exit 0'
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
}

@test "daily fails and records nothing when the upload fails" {
  stub rclone 'case "$1" in copyto) exit 1 ;; esac'
  run bash "$REPO_ROOT/scripts/backup-daily.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$BK_STATE_DIR/last-success-daily" ]
}

@test "daily output never contains the secret file contents" {
  run bash "$REPO_ROOT/scripts/backup-daily.sh"
  [[ "$output" != *"s3cret"* ]]
}
