#!/usr/bin/env bats
# guard.bats -- tests for scripts/backup-guard.sh (stops a backup if the game or host looks stressed).
load helper

setup() {
  setup_env
  SCRIPT="$REPO_ROOT/scripts/backup-guard.sh"
  T="$BATS_TEST_TMPDIR"
  export BK_PSI_DIR="$T/psi"; mkdir -p "$BK_PSI_DIR"
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' >"$BK_PSI_DIR/io"
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' >"$BK_PSI_DIR/memory"
  export BK_GUARD_GAME_SSH="dune@prod.test"
  cat >"$BK_CONFIG_DIR/backup.env" <<EOF
BK_BACKUP_SSH=dune@prod.test
EOF
  stub iostat 'echo "Device r/s rMB/s rrqm/s %rrqm r_await rareq-sz w/s wMB/s wrqm/s %wrqm w_await wareq-sz d/s dMB/s drqm/s %drqm d_await dareq-sz f/s f_await aqu-sz %util"
for i in 1 2; do echo "sda 100.0 50.0 0 0 3.0 128 20.0 2.0 0 0 0.5 100 0 0 0 0 0 0 0 0 0 ${DISK_UTIL:-12.0}"; done'
  stub lvs 'echo "  ${POOL_PCT:-17.7}  ${META_PCT:-0.69}"'
  stub ssh 'if [ -f "$BATS_TEST_TMPDIR/ssh-down" ]; then exit 255; fi
if [ -f "$BATS_TEST_TMPDIR/flap" ]; then c="$BATS_TEST_TMPDIR/flap.n"; n=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 )); echo $n >"$c"; if [ $((n % 2)) -eq 0 ]; then printf "Overall:     DEGRADED\n"; exit 0; fi; fi
printf "Overall:     %s\n" "${GAME_STATE:-READY}"'
}
teardown() { pkill -KILL -fx "sleep 330" 2>/dev/null || true; }

@test "--once: everything healthy prints OK and exits 0" {
  run bash "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "--once: the game not READY is a problem" {
  GAME_STATE=DEGRADED run bash "$SCRIPT" --once
  [ "$status" -eq 1 ]
  [[ "$output" == *"the game is not READY (DEGRADED)"* ]]
}

@test "--once: an unreachable game host is a problem" {
  touch "$T/ssh-down"
  run bash "$SCRIPT" --once
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not answer"* ]]
}

@test "--once: high I/O pressure, a saturated disk and a nearly full pool are each reported" {
  printf 'some avg10=45.00 avg60=0.00 avg300=0.00 total=1\n' >"$BK_PSI_DIR/io"
  DISK_UTIL=99.0 POOL_PCT=91.0 run bash "$SCRIPT" --once
  [ "$status" -eq 1 ]
  [[ "$output" == *"I/O pressure (some) 45.00%"* ]]
  [[ "$output" == *"disk sda 99.0% busy"* ]]
  [[ "$output" == *"thin pool 91.0% full"* ]]
}

@test "--once: high host memory pressure is reported, a quiet host is not, and the limit is configurable" {
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' >"$BK_PSI_DIR/memory"
  run bash "$SCRIPT" --once
  [ "$status" -eq 0 ]
  printf 'some avg10=22.50 avg60=0.00 avg300=0.00 total=1\n' >"$BK_PSI_DIR/memory"
  run bash "$SCRIPT" --once
  [ "$status" -eq 1 ]
  [[ "$output" == *"memory pressure 22.50% (limit 10%)"* ]]
  BK_GUARD_MEM_PRESSURE_MAX=30 run bash "$SCRIPT" --once
  [ "$status" -eq 0 ]
}

@test "--once: I/O pressure can be judged on the 'full' line (every task stalled) instead of 'some'" {
  printf 'some avg10=80.00 avg60=0.00 avg300=0.00 total=1\nfull avg10=5.00 avg60=0.00 avg300=0.00 total=1\n' >"$BK_PSI_DIR/io"
  run bash "$SCRIPT" --once
  [ "$status" -eq 1 ]
  [[ "$output" == *"I/O pressure (some) 80.00%"* ]]
  BK_GUARD_IO_METRIC=full run bash "$SCRIPT" --once
  [ "$status" -eq 0 ]
  printf 'some avg10=80.00 avg60=0.00 avg300=0.00 total=1\nfull avg10=45.00 avg60=0.00 avg300=0.00 total=1\n' >"$BK_PSI_DIR/io"
  BK_GUARD_IO_METRIC=full run bash "$SCRIPT" --once
  [ "$status" -eq 1 ]
  [[ "$output" == *"I/O pressure (full) 45.00%"* ]]
  BK_GUARD_IO_METRIC=most run bash "$SCRIPT" --once
  [ "$status" -eq 2 ]
}

@test "--once: thin pool METADATA over its limit is reported" {
  META_PCT=85.0 run bash "$SCRIPT" --once
  [ "$status" -eq 1 ]
  [[ "$output" == *"thin pool metadata 85.0% full (limit 70%)"* ]]
}

@test "--once: a sampler that cannot read is a problem, never silent (a blind guard protects nothing)" {
  rm -f "$BK_PSI_DIR/io"
  run bash "$SCRIPT" --once
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot read host I/O pressure"* ]]
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' >"$BK_PSI_DIR/io"
  rm -f "$BK_PSI_DIR/memory"
  run bash "$SCRIPT" --once
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot read host memory pressure"* ]]
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' >"$BK_PSI_DIR/memory"
  stub lvs 'exit 1'
  run bash "$SCRIPT" --once
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot read the thin pool usage"* ]]
}

@test "the pressure directory override is honoured under bats only (a stray variable cannot blind the guard)" {
  printf 'some avg10=99.00 avg60=0.00 avg300=0.00 total=1\nfull avg10=99.00 avg60=0.00 avg300=0.00 total=1\n' >"$BK_PSI_DIR/io"
  run bash "$SCRIPT" --once
  [ "$status" -eq 1 ]
  run env -u BATS_TEST_TMPDIR BK_PSI_DIR="$BK_PSI_DIR" bash "$SCRIPT" --once
  [[ "$output" != *"99.00"* ]]
}

@test "--once: thresholds are configurable" {
  printf 'some avg10=45.00 avg60=0.00 avg300=0.00 total=1\n' >"$BK_PSI_DIR/io"
  BK_GUARD_IO_PRESSURE_MAX=60 run bash "$SCRIPT" --once
  [ "$status" -eq 0 ]
}

@test "watch: a sustained problem stops the target with SIGINT and records the reason" {
  sleep 330 &
  victim=$!
  GAME_STATE=DEGRADED run bash "$SCRIPT" --target "$victim" --reason-file "$T/reason" --interval 1 --consecutive 2
  [ "$status" -eq 0 ]
  ! kill -0 "$victim" 2>/dev/null
  grep -q "the game is not READY" "$T/reason"
  [[ "$output" == *"STOPPING the backup"* ]]
}

@test "watch: a flapping problem (bad, good, bad, good) never reaches the consecutive limit" {
  touch "$T/flap"
  sleep 330 &
  victim=$!
  ( sleep 7; kill "$victim" 2>/dev/null ) &
  run bash "$SCRIPT" --target "$victim" --reason-file "$T/reason" --interval 1 --consecutive 2
  [ "$status" -eq 0 ]
  [ ! -s "$T/reason" ]
  [[ "$output" != *"STOPPING"* ]]
}

@test "watch: it exits quietly when the target ends by itself" {
  sleep 2 &
  victim=$!
  run bash "$SCRIPT" --target "$victim" --reason-file "$T/reason" --interval 1 --consecutive 2
  [ "$status" -eq 0 ]
  [ ! -s "$T/reason" ]
}

@test "usage errors: no target, a bad PID, a bad interval" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --target abc
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --target 1 --interval 0
  [ "$status" -eq 2 ]
}

@test "it only reads: it never writes outside the reason file it was given" {
  before="$(find "$BK_STATE_DIR" "$T" -maxdepth 1 -type f -printf '%f\n' | grep -v '\.calls$' | sort)"
  run bash "$SCRIPT" --once
  after="$(find "$BK_STATE_DIR" "$T" -maxdepth 1 -type f -printf '%f\n' | grep -v '\.calls$' | sort)"
  [ "$before" = "$after" ]
}
