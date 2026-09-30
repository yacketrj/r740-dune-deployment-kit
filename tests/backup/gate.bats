#!/usr/bin/env bats
# gate.bats -- tests for scripts/dune-prod/r740-backup-gate.sh (design v2, theme T7).
# The gate runs on dune-prod; here it runs against a fake repo under BATS_TEST_TMPDIR.
load helper

setup() {
  setup_env
  GATE="$REPO_ROOT/scripts/dune-prod/r740-backup-gate.sh"
  export R740_GATE_TEST_MODE=1
  export R740_GATE_REPO="$BATS_TEST_TMPDIR/repo"
  export R740_GATE_SIZE_FLOOR=100
  export R740_GATE_SETTLE_SECONDS=30
  export R740_GATE_NOW=1800000000
  DB="$R740_GATE_REPO/runtime/backups/db"
  mkdir -p "$DB" "$R740_GATE_REPO/runtime/secrets" "$R740_GATE_REPO/runtime/generated"
  echo "funcom-token-value" >"$R740_GATE_REPO/runtime/secrets/funcom-token.txt"
  echo "SERVER_IP=1.2.3.4" >"$R740_GATE_REPO/.env"
}

# mk_dump NAME ORIGIN AGE_SECONDS [BYTES] [MAGIC]
mk_dump() {
  local name="$1" origin="$2" age="$3" bytes="${4:-400}" magic="${5:-PGDMP}"
  { printf '%s' "$magic"; head -c "$bytes" /dev/zero | tr '\0' 'x'; } >"$DB/$name"
  printf 'backup_file: %s\nbackup_origin: %s\nformat: pg_dump_custom\n' "$name" "$origin" >"$DB/$name.yaml"
  touch -d "@$((R740_GATE_NOW - age))" "$DB/$name" "$DB/$name.yaml"
}

gate() { run env SSH_ORIGINAL_COMMAND="$*" bash "$GATE"; }

# gate_out REQUEST : run the gate capturing ONLY stdout (bats `run` merges stderr).
# Sets GATE_STATUS and GATE_STDOUT.
gate_out() {
  GATE_STATUS=0
  GATE_STDOUT="$(env SSH_ORIGINAL_COMMAND="$*" bash "$GATE" 2>/dev/null)" || GATE_STATUS=$?
}

@test "status reports the newest automatic dump and excludes seed dumps from the count" {
  mk_dump auto-1.backup automatic 7200
  mk_dump seed-1.backup market-bot-seed 60
  mk_dump manual-1.backup manual 3600
  gate status
  [ "$status" -eq 0 ]
  [[ "$output" == *"newest_automatic_name=auto-1.backup"* ]]
  [[ "$output" == *"pairs_non_seed=2"* ]]
}

@test "status works with no dumps at all" {
  gate status
  [ "$status" -eq 0 ]
  [[ "$output" == *"newest_automatic_epoch=0"* ]]
}

@test "set returns dump pairs, secrets, .env and a manifest, and excludes seed dumps" {
  mk_dump auto-1.backup automatic 7200
  mk_dump safety-1.backup vehicle-delete 3600
  mk_dump seed-1.backup market-bot-seed 60
  env SSH_ORIGINAL_COMMAND="set 30 48" bash "$GATE" >"$BATS_TEST_TMPDIR/out.tar"
  names="$(tar -tf "$BATS_TEST_TMPDIR/out.tar")"
  [[ "$names" == *"gate-manifest.txt"* ]]
  [[ "$names" == *"runtime/backups/db/auto-1.backup"* ]]
  [[ "$names" == *"runtime/backups/db/auto-1.backup.yaml"* ]]
  [[ "$names" == *"runtime/backups/db/safety-1.backup"* ]]
  [[ "$names" == *"runtime/secrets/funcom-token.txt"* ]]
  [[ "$names" == *".env"* ]]
  [[ "$names" != *"seed-1"* ]]
  tar -xOf "$BATS_TEST_TMPDIR/out.tar" gate-manifest.txt | grep -q '^authoritative=runtime/backups/db/auto-1.backup$'
}

@test "set includes the newest automatic dump even when it is older than the since window" {
  mk_dump auto-1.backup automatic 86400
  mk_dump manual-old.backup manual 7 
  touch -d "@$((R740_GATE_NOW - 500000))" "$DB/manual-old.backup" "$DB/manual-old.backup.yaml"
  env SSH_ORIGINAL_COMMAND="set 30 2" bash "$GATE" >"$BATS_TEST_TMPDIR/out.tar"
  names="$(tar -tf "$BATS_TEST_TMPDIR/out.tar")"
  [[ "$names" == *"auto-1.backup"* ]]
  [[ "$names" != *"manual-old"* ]]
}

@test "newest-db returns only database pairs and no secrets" {
  mk_dump auto-1.backup automatic 7200
  env SSH_ORIGINAL_COMMAND="newest-db 30 8" bash "$GATE" >"$BATS_TEST_TMPDIR/out.tar"
  names="$(tar -tf "$BATS_TEST_TMPDIR/out.tar")"
  [[ "$names" == *"auto-1.backup"* ]]
  [[ "$names" != *"secrets"* ]]
  [[ "$names" != *".env"* ]]
}

@test "gate refuses (exit 3) with nothing on stdout when the newest automatic dump is stale" {
  mk_dump auto-1.backup automatic $((40 * 3600))
  gate_out set 30 48
  [ "$GATE_STATUS" -eq 3 ]
  [ -z "$GATE_STDOUT" ]
}

@test "gate refuses when the dump is below the size floor, has no PGDMP header, or is still being written" {
  mk_dump auto-1.backup automatic 7200 10
  gate_out set 30 48
  [ "$GATE_STATUS" -eq 3 ]; [ -z "$GATE_STDOUT" ]
  mk_dump auto-1.backup automatic 7200 400 "JUNK!"
  gate_out set 30 48
  [ "$GATE_STATUS" -eq 3 ]; [ -z "$GATE_STDOUT" ]
  mk_dump auto-1.backup automatic 5
  gate_out set 30 48
  [ "$GATE_STATUS" -eq 3 ]; [ -z "$GATE_STDOUT" ]
}

@test "gate refuses when there is no automatic dump, or secrets are missing for set" {
  mk_dump manual-1.backup manual 7200
  gate_out set 30 48
  [ "$GATE_STATUS" -eq 3 ]; [ -z "$GATE_STDOUT" ]
  mk_dump auto-1.backup automatic 7200
  rm -rf "$R740_GATE_REPO/runtime/secrets"
  gate_out set 30 48
  [ "$GATE_STATUS" -eq 3 ]; [ -z "$GATE_STDOUT" ]
}

@test "requests are refused (exit 2) and nothing is executed for unknown verbs, injection and bad arguments" {
  mk_dump auto-1.backup automatic 7200
  canary="$BATS_TEST_TMPDIR/canary"
  for req in "rm -rf x" "status; touch $canary" 'status $(touch '"$canary"')' 'status `touch '"$canary"'`' "status && touch $canary" "status | cat" "set 30" "set 30 48 extra" "set abc 48" "set 0 48" "set 999 48" "set 30 99999" "set -1 5" "dump-now now" "status extra" "" "tar cf - /etc"; do
    run env SSH_ORIGINAL_COMMAND="$req" bash "$GATE"
    [ "$status" -eq 2 ]
  done
  [ ! -e "$canary" ]
}

@test "a request with an embedded newline is refused" {
  run env SSH_ORIGINAL_COMMAND=$'status\ntouch /tmp/x' bash "$GATE"
  [ "$status" -eq 2 ]
}

@test "dump-now runs the dune command once and reports done" {
  cat >"$BATS_TEST_TMPDIR/fake-dune" <<'EOS'
#!/usr/bin/env bash
echo "$*" >>"$BATS_TEST_TMPDIR/dune.calls"
EOS
  chmod +x "$BATS_TEST_TMPDIR/fake-dune"
  export BATS_TEST_TMPDIR
  R740_GATE_DUNE="$BATS_TEST_TMPDIR/fake-dune" gate dump-now
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/dune.calls")" = "db backup" ]
}

@test "dump-now refuses while another dump holds the lock" {
  cat >"$BATS_TEST_TMPDIR/fake-dune" <<'EOS'
#!/usr/bin/env bash
echo ran >>"$BATS_TEST_TMPDIR/dune.calls"
EOS
  chmod +x "$BATS_TEST_TMPDIR/fake-dune"
  ( flock -x 8; sleep 3 ) 8>"$R740_GATE_REPO/runtime/generated/.r740-backup-gate.lock" &
  holder=$!
  sleep 1
  R740_GATE_DUNE="$BATS_TEST_TMPDIR/fake-dune" gate dump-now
  [ "$status" -eq 3 ]
  [ ! -e "$BATS_TEST_TMPDIR/dune.calls" ]
  wait "$holder"
}

@test "the gate never deletes or modifies anything in the repo" {
  mk_dump auto-1.backup automatic 7200
  before="$(find "$R740_GATE_REPO" -type f -exec sha256sum {} + | sort)"
  env SSH_ORIGINAL_COMMAND="set 30 48" bash "$GATE" >/dev/null
  after="$(find "$R740_GATE_REPO" -type f -exec sha256sum {} + | sort)"
  [ "$before" = "$after" ]
}

@test "outside test mode the R740_GATE_* overrides are ignored (production cannot be steered by environment)" {
  cat >"$BATS_TEST_TMPDIR/fake-dune" <<'EOF'
#!/usr/bin/env bash
echo ran >"$BATS_TEST_TMPDIR/fake-dune.ran"
EOF
  chmod +x "$BATS_TEST_TMPDIR/fake-dune"
  unset R740_GATE_TEST_MODE
  HOME="$BATS_TEST_TMPDIR/nohome" R740_GATE_DUNE="$BATS_TEST_TMPDIR/fake-dune" R740_GATE_SIZE_FLOOR=1 gate dump-now || true
  [ ! -e "$BATS_TEST_TMPDIR/fake-dune.ran" ]
  # the repo override is ignored too: nothing under the fake repo is read
  run env -u R740_GATE_TEST_MODE HOME="$BATS_TEST_TMPDIR/nohome" R740_GATE_REPO="$R740_GATE_REPO" SSH_ORIGINAL_COMMAND="status" bash "$GATE"
  [[ "$output" != *"auto-1"* ]]
}
