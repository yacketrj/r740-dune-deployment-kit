#!/usr/bin/env bats
load helper

setup() { setup_env; }

@test "init-keys creates a 0600 key, a 0700 dir and a config with the recipient" {
  run bash "$REPO_ROOT/scripts/backup-init-keys.sh"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$BK_CONFIG_DIR/age.key")" = "600" ]
  [ "$(stat -c %a "$BK_CONFIG_DIR")" = "700" ]
  [ "$(stat -c %a "$BK_CONFIG_DIR/backup.env")" = "600" ]
  grep -q '^BK_AGE_RECIPIENT=age1' "$BK_CONFIG_DIR/backup.env"
}

@test "init-keys never prints the private key" {
  run bash "$REPO_ROOT/scripts/backup-init-keys.sh"
  [[ "$output" != *"AGE-SECRET-KEY"* ]]
}

@test "init-keys refuses to overwrite an existing key" {
  bash "$REPO_ROOT/scripts/backup-init-keys.sh" >/dev/null
  before="$(sha256sum "$BK_CONFIG_DIR/age.key")"
  run bash "$REPO_ROOT/scripts/backup-init-keys.sh"
  [ "$status" -eq 1 ]
  [ "$before" = "$(sha256sum "$BK_CONFIG_DIR/age.key")" ]
}
