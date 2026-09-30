#!/usr/bin/env bats
# status.bats -- tests for scripts/backup-status.sh (the read-only live dashboard).
load helper

setup() {
  setup_env
  SCRIPT="$REPO_ROOT/scripts/backup-status.sh"
  T="$BATS_TEST_TMPDIR"
  export BK_SMB_MOUNT="$T/smb"; mkdir -p "$BK_SMB_MOUNT/vm" "$BK_STATE_DIR"
  export BK_PSI_DIR="$T/psi"; mkdir -p "$BK_PSI_DIR"
  psi 0.00 0.00 0.00
  export BK_STATUS_LOCK="$T/weekly.lock"
  export BK_PROGRESS_LOG="$T/progress.log"
  export BK_STATUS_GAME_SSH="dune@prod.test"
  export BK_VMIDS="101 103"
  cat >"$BK_CONFIG_DIR/backup.env" <<EOF
BK_SMB_MOUNT=$BK_SMB_MOUNT
BK_VMIDS="101 103"
EOF
  # iostat: two report blocks, sda line in sysstat-12 layout (see the script's column map)
  stub iostat 'echo "Device r/s rMB/s rrqm/s %rrqm r_await rareq-sz w/s wMB/s wrqm/s %wrqm w_await wareq-sz d/s dMB/s drqm/s %drqm d_await dareq-sz f/s f_await aqu-sz %util"
for i in 1 2; do echo "sda 100.0 ${DISK_R:-50.0} 0 0 ${DISK_RAW:-3.0} 128 20.0 2.0 0 0 ${DISK_WAW:-0.5} 100 0 0 0 0 0 0 0 0 0 ${DISK_UTIL:-12.0}"; done'
  stub lvs 'echo "  17.7"'
  stub ssh 'if [ -f "$BATS_TEST_TMPDIR/ssh-down" ]; then exit 255; fi
printf "=== Dune status ===\nOverall:     %s\nTitle:       Chronicles of Kanly\nPopulation:  3/120\n" "${GAME_STATE:-READY}"'
}

psi() { # io cpu memory (avg10 values)
  printf 'some avg10=%s avg60=0.00 avg300=0.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' "$1" >"$BK_PSI_DIR/io"
  printf 'some avg10=%s avg60=0.00 avg300=0.00 total=1\n' "$2" >"$BK_PSI_DIR/cpu"
  printf 'some avg10=%s avg60=0.00 avg300=0.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' "$3" >"$BK_PSI_DIR/memory"
}
status() { run env BK_STATE_DIR="$BK_STATE_DIR" bash "$SCRIPT" --once; }

@test "idle: says no job is running and reports OK with the game READY" {
  status
  [ "$status" -eq 0 ]
  [[ "$output" == *"no weekly image job is running"* ]]
  [[ "$output" == *"Overall:     READY"* ]]
  [[ "$output" == *"Population:  3/120"* ]]
  [[ "$output" == *"VERDICT: OK"* ]]
}

@test "running: shows RUNNING and the latest progress lines" {
  printf '%s\n' "guest 102: 00:05:00 elapsed, 12GB written, 52MB/s, vzdump 9% (27.0 GiB of 300.0 GiB)" >"$BK_PROGRESS_LOG"
  flock "$BK_STATUS_LOCK" sleep 25 &
  lockpid=$!
  sleep 1
  status
  kill "$lockpid" 2>/dev/null || true
  [[ "$output" == *"BACKUP: RUNNING"* ]]
  [[ "$output" == *"12GB written, 52MB/s, vzdump 9%"* ]]
}

@test "the partial image being written is listed with its size" {
  head -c 3000000 /dev/zero >"$BK_SMB_MOUNT/vm/vm101-20260930-100000.vma.zst.age.partial"
  flock "$BK_STATUS_LOCK" sleep 25 &
  lockpid=$!
  sleep 1
  status
  kill "$lockpid" 2>/dev/null || true
  [[ "$output" == *"writing: vm101-20260930-100000.vma.zst.age.partial"* ]]
}

@test "lists the newest image per guest, and 'none yet' for a guest without one" {
  : >"$BK_SMB_MOUNT/vm/vm101-20260930-010000.vma.zst.age"
  status
  [[ "$output" == *"101"*"vm101-20260930-010000.vma.zst.age"* ]]
  [[ "$output" == *"103   none yet"* ]]
}

@test "WATCH when I/O pressure is high" {
  psi 40.00 0.00 0.00
  status
  [[ "$output" == *"VERDICT: WATCH"* ]]
  [[ "$output" == *"I/O pressure 40.00%"* ]]
}

@test "WATCH when the disk is saturated or slow" {
  DISK_UTIL=97.0 DISK_RAW=60.0 status
  [[ "$output" == *"VERDICT: WATCH"* ]]
  [[ "$output" == *"disk busy 97.0%"* ]]
  [[ "$output" == *"read wait 60.0 ms"* ]]
}

@test "WATCH when the game is not READY" {
  GAME_STATE=DEGRADED status
  [[ "$output" == *"VERDICT: WATCH"* ]]
  [[ "$output" == *"game not READY"* ]]
}

@test "WATCH when the game host cannot be reached" {
  touch "$T/ssh-down"
  status
  [[ "$output" == *"VERDICT: WATCH"* ]]
  [[ "$output" == *"unreachable"* ]]
}

@test "it is read-only: nothing is created or changed in the state dir or on the share" {
  : >"$BK_SMB_MOUNT/vm/vm101-20260930-010000.vma.zst.age"
  before="$(find "$BK_STATE_DIR" "$BK_SMB_MOUNT" -type f -printf '%p %s %T@\n' | sort)"
  status
  after="$(find "$BK_STATE_DIR" "$BK_SMB_MOUNT" -type f -printf '%p %s %T@\n' | sort)"
  [ "$before" = "$after" ]
}

@test "a bad interval is refused" {
  run bash "$SCRIPT" --interval 0
  [ "$status" -eq 2 ]
}
