#!/usr/bin/env bats
# key.bats -- tests for scripts/backup-key.sh (design v2, theme T1).
# Every path lives under BATS_TEST_TMPDIR; the RAM directory is redirected there.
load helper

setup() {
  setup_env
  export BK_RAM_DIR="$BATS_TEST_TMPDIR/ram"
  mkdir -p "$BK_RAM_DIR" "$BATS_TEST_TMPDIR/handoff"
  KEY="$REPO_ROOT/scripts/backup-key.sh"
  HANDOFF="$BATS_TEST_TMPDIR/handoff"
}

gen() { run bash "$KEY" generate --handoff-dir "$HANDOFF"; }

@test "generate writes only the recipient to the config and the key to the hand-off dir" {
  gen
  [ "$status" -eq 0 ]
  grep -q '^BK_AGE_RECIPIENT=age1' "$BK_CONFIG_DIR/backup.env"
  run grep -c 'AGE-SECRET-KEY' "$BK_CONFIG_DIR/backup.env"
  [ "$output" = "0" ]
  run grep -q 'BK_AGE_IDENTITY' "$BK_CONFIG_DIR/backup.env"
  [ "$status" -ne 0 ]
  n="$(find "$HANDOFF" -type f | wc -l)"
  [ "$n" -eq 1 ]
  f="$(find "$HANDOFF" -type f)"
  [ "$(stat -c %a "$f")" = "600" ]
  [ "$(age-keygen -y "$f")" = "$(awk -F= '$1=="BK_AGE_RECIPIENT"{print $2}' "$BK_CONFIG_DIR/backup.env")" ]
}

@test "generate never prints the private key" {
  gen
  [ "$status" -eq 0 ]
  [[ "$output" != *"AGE-SECRET-KEY"* ]]
  [[ "$output" == *"recipient: age1"* ]]
}

@test "generate leaves the private key nowhere on the host except the hand-off file" {
  gen
  [ "$status" -eq 0 ]
  hits="$(grep -rl 'AGE-SECRET-KEY' "$BATS_TEST_TMPDIR" 2>/dev/null | sort)"
  [ "$hits" = "$(find "$HANDOFF" -type f)" ]
  [ -z "$(ls -A "$BK_RAM_DIR")" ]
}

@test "generate sets the config and directory permissions" {
  gen
  [ "$(stat -c %a "$BK_CONFIG_DIR")" = "700" ]
  [ "$(stat -c %a "$BK_CONFIG_DIR/backup.env")" = "600" ]
}

@test "generate refuses to overwrite an existing recipient and changes nothing" {
  gen
  before="$(sha256sum "$BK_CONFIG_DIR/backup.env")"
  run bash "$KEY" generate --handoff-dir "$HANDOFF"
  [ "$status" -eq 1 ]
  [ "$before" = "$(sha256sum "$BK_CONFIG_DIR/backup.env")" ]
  [ "$(find "$HANDOFF" -type f | wc -l)" -eq 1 ]
}

@test "generate refuses a missing hand-off dir, and one inside the host config dir" {
  run bash "$KEY" generate --handoff-dir "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 1 ]
  mkdir -p "$BK_CONFIG_DIR/inner"
  run bash "$KEY" generate --handoff-dir "$BK_CONFIG_DIR/inner"
  [ "$status" -eq 1 ]
  [ -z "$(find "$BK_CONFIG_DIR/inner" -type f)" ]
}

@test "generate aborts without configuring anything if the hand-off copy does not verify" {
  stub cmp 'exit 1'
  gen
  [ "$status" -eq 1 ]
  run grep -E '^BK_AGE_RECIPIENT=age1' "$BK_CONFIG_DIR/backup.env"
  [ "$status" -ne 0 ]
  [ -z "$(find "$HANDOFF" -type f)" ]
  [ -z "$(ls -A "$BK_RAM_DIR")" ]
}

@test "generate needs a RAM directory and fails cleanly without one" {
  BK_RAM_DIR="$BATS_TEST_TMPDIR/no-ram" run bash "$KEY" generate --handoff-dir "$HANDOFF"
  [ "$status" -eq 1 ]
}

@test "verify passes with the right key and logs escrow verified" {
  gen
  f="$(find "$HANDOFF" -type f)"
  run bash "$KEY" verify --identity "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"escrow verified"* ]]
  grep -q $'\tescrow\tPASS\t' "$BK_STATE_DIR/evidence.log"
}

@test "verify fails with a different key and logs the failure" {
  gen
  age-keygen -o "$BATS_TEST_TMPDIR/other.key" 2>/dev/null
  run bash "$KEY" verify --identity "$BATS_TEST_TMPDIR/other.key"
  [ "$status" -eq 1 ]
  grep -q $'\tescrow\tFAIL\t' "$BK_STATE_DIR/evidence.log"
  run grep -q $'\tescrow\tPASS\t' "$BK_STATE_DIR/evidence.log"
  [ "$status" -ne 0 ]
}

@test "verify fails for a missing, unreadable or garbage identity" {
  gen
  run bash "$KEY" verify --identity "$BATS_TEST_TMPDIR/none"
  [ "$status" -eq 1 ]
  echo "not a key" >"$BATS_TEST_TMPDIR/garbage"
  run bash "$KEY" verify --identity "$BATS_TEST_TMPDIR/garbage"
  [ "$status" -eq 1 ]
}

@test "verify never stores the identity or leaves canary material behind" {
  gen
  f="$(find "$HANDOFF" -type f)"
  bash "$KEY" verify --identity "$f" >/dev/null
  hits="$(grep -rl 'AGE-SECRET-KEY' "$BATS_TEST_TMPDIR" 2>/dev/null | sort)"
  [ "$hits" = "$f" ]
  [ -z "$(ls -A "$BK_RAM_DIR")" ]
}

@test "verify without a configured recipient fails" {
  mkdir -p "$BK_CONFIG_DIR"; cp "$REPO_ROOT/backup.env.example" "$BK_CONFIG_DIR/backup.env"
  age-keygen -o "$BATS_TEST_TMPDIR/k" 2>/dev/null
  run bash "$KEY" verify --identity "$BATS_TEST_TMPDIR/k"
  [ "$status" -eq 1 ]
}

@test "fingerprint shows the recipient, creation date and last verified time" {
  gen
  run bash "$KEY" fingerprint
  [[ "$output" == *"recipient=age1"* ]]
  [[ "$output" == *"created=$(date -u +%Y-%m-%d)"* ]]
  [[ "$output" == *"last_verified=never"* ]]
  bash "$KEY" verify --identity "$(find "$HANDOFF" -type f)" >/dev/null
  run bash "$KEY" fingerprint
  [[ "$output" != *"last_verified=never"* ]]
}

@test "unknown subcommands and missing arguments exit 2" {
  run bash "$KEY" bogus
  [ "$status" -eq 2 ]
  run bash "$KEY" generate
  [ "$status" -eq 2 ]
  run bash "$KEY" verify
  [ "$status" -eq 2 ]
}
