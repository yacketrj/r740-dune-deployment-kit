#!/usr/bin/env bats
# weekly.bats -- tests for scripts/backup-weekly.sh (design v2: streamed, windowed, throttled images).
# vzdump/qm/pct/lvs/ssh are stubs; age, tar, sha256sum, timeout, nice, ionice are real.
load helper

setup() {
  setup_env
  make_age_key
  SCRIPT="$REPO_ROOT/scripts/backup-weekly.sh"
  export BK_SMB_MOUNT="$BATS_TEST_TMPDIR/smb"
  mkdir -p "$BK_SMB_MOUNT"
  printf 'https://hc.example/ping/DEADMANID\n' >"$BATS_TEST_TMPDIR/deadman"
  printf 'https://discord.com/api/webhooks/1/x\n' >"$BATS_TEST_TMPDIR/hook"
  : >"$BATS_TEST_TMPDIR/known_hosts"
  cat >"$BK_CONFIG_DIR/backup.env" <<EOF
BK_AGE_RECIPIENT=$BK_AGE_RECIPIENT
BK_STATE_DIR=$BK_STATE_DIR
BK_SMB_MOUNT=$BK_SMB_MOUNT
BK_VMIDS="101 102 103 104"
BK_KEEP_WEEKLY_DEFAULT=3
BK_KEEP_WEEKLY_102=1
BK_BACKUP_SSH=backup@prod.test
BK_KNOWN_HOSTS=$BATS_TEST_TMPDIR/known_hosts
BK_DEADMAN_URL_FILE=$BATS_TEST_TMPDIR/deadman
BK_DISCORD_WEBHOOK_FILE=$BATS_TEST_TMPDIR/hook
BK_WEEKLY_FORCE=1
BK_MIN_IMAGE_BYTES=10
EOF
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  T="$BATS_TEST_TMPDIR"
  cat >"$T/bin/vzdump" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/vzdump.calls"
id="\$1"
if [ -f "$T/fail-\$id" ]; then echo "boom \$id" >&2; exit 1; fi
if [ -f "$T/slow" ]; then sleep 30; fi
echo "PLAINIMAGEMARKER image of \$id"
head -c 2000 /dev/zero | tr '\\0' 'x'
EOF
  cat >"$T/bin/qm" <<EOF
#!/usr/bin/env bash
case "\$1" in
  status) case "\$2" in 101|102|103) exit 0 ;; *) exit 1 ;; esac ;;
  agent) [ -f "$T/noagent-\$2" ] && exit 1; exit 0 ;;
esac
EOF
  cat >"$T/bin/pct" <<EOF
#!/usr/bin/env bash
[ "\$1" = "status" ] && [ "\$2" = "104" ]
EOF
  cat >"$T/bin/lvs" <<EOF
#!/usr/bin/env bash
if [ -f "$T/lvs-fail" ]; then exit 1; fi
if [ -f "$T/poolvals" ]; then cat "$T/poolvals"; else echo "  1634.87 20.00"; fi
EOF
  cat >"$T/bin/ssh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/ssh.calls"
[ -f "$T/dump-fail" ] && { echo "gate refused" >&2; exit 3; }
exit 0
EOF
  chmod +x "$T"/bin/vzdump "$T"/bin/qm "$T"/bin/pct "$T"/bin/lvs "$T"/bin/ssh
  stub mountpoint 'exit 0'
  stub curl 'cat >>"$BATS_TEST_TMPDIR/curl.stdin"; echo "$*" >>"$BATS_TEST_TMPDIR/curl.args"'
}

teardown() { pkill -KILL -fx "sleep 317" 2>/dev/null || true; }

run_weekly() { run bash "$SCRIPT" "$@"; }
imgs() { ls "$BK_SMB_MOUNT"/vm/ 2>/dev/null; }

@test "success: one encrypted image per guest, VM/CT extensions, round-trips, state and dead-man recorded" {
  run_weekly
  [ "$status" -eq 0 ]
  ls "$BK_SMB_MOUNT"/vm/vm101-*.vma.zst.age "$BK_SMB_MOUNT"/vm/vm102-*.vma.zst.age "$BK_SMB_MOUNT"/vm/vm103-*.vma.zst.age
  ls "$BK_SMB_MOUNT"/vm/ct104-*.tar.zst.age
  f="$(ls "$BK_SMB_MOUNT"/vm/vm101-*.age)"
  [ "$(age -d -i "$BK_AGE_IDENTITY" "$f" | head -c 41)" = "PLAINIMAGEMARKER image of 101" ] || age -d -i "$BK_AGE_IDENTITY" "$f" | head -1 | grep -q "PLAINIMAGEMARKER image of 101"
  [ -s "$BK_STATE_DIR/last-success-weekly" ]
  grep -q DEADMANID "$BATS_TEST_TMPDIR/curl.stdin"
  grep -q "weekly backup OK" "$BATS_TEST_TMPDIR/curl.args"
}

@test "no plaintext image is ever written anywhere" {
  run_weekly
  [ "$status" -eq 0 ]
  run grep -rl "PLAINIMAGEMARKER" "$BATS_TEST_TMPDIR" --include='*' --exclude-dir=bin
  [ "$status" -ne 0 ]
  [ -z "$(find "$BK_SMB_MOUNT" -type f ! -name '*.age')" ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "images are encrypted to the public recipient only (a different key cannot decrypt)" {
  run_weekly
  [ "$status" -eq 0 ]
  age-keygen -o "$BATS_TEST_TMPDIR/other.key" 2>/dev/null
  f="$(ls "$BK_SMB_MOUNT"/vm/vm103-*.age)"
  run age -d -i "$BATS_TEST_TMPDIR/other.key" "$f"
  [ "$status" -ne 0 ]
}

@test "vzdump is throttled and streamed: snapshot, zstd, --stdout, bwlimit" {
  run_weekly
  c="$(cat "$BATS_TEST_TMPDIR/vzdump.calls" | head -1)"
  [[ "$c" == *"--stdout"* ]]
  [[ "$c" == *"--compress zstd"* ]]
  [[ "$c" == *"--mode snapshot"* ]]
  [[ "$c" == *"--bwlimit 153600"* ]]
}

@test "outside the maintenance window nothing runs and one alert is raised" {
  echo 'BK_WEEKLY_FORCE=0' >>"$BK_CONFIG_DIR/backup.env"
  noon="$(date -d "today 12:00" +%s)"
  BK_WEEKLY_NOW_EPOCH="$noon" run_weekly
  [ "$status" -eq 1 ]
  grep -q "maintenance window" "$BATS_TEST_TMPDIR/curl.args"
  [ "$(grep -c FAILED "$BATS_TEST_TMPDIR/curl.args")" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/vzdump.calls" ]
  [ -z "$(imgs)" ]
  [ ! -e "$BK_STATE_DIR/last-success-weekly" ]
}

@test "inside the window the run proceeds (whole-day window)" {
  [ "$(date +%H%M)" -lt 2350 ] || skip "too close to midnight"
  { echo 'BK_WEEKLY_FORCE=0'; echo 'BK_WEEKLY_WINDOW_START=00:00'; echo 'BK_WEEKLY_HARD_STOP=23:59'; } >>"$BK_CONFIG_DIR/backup.env"
  run_weekly
  [ "$status" -eq 0 ]
}

@test "the hard stop kills a slow vzdump, leaves no partial file, and never records success" {
  touch "$BATS_TEST_TMPDIR/slow"
  { echo 'BK_WEEKLY_FORCE_SECONDS=4'; echo 'BK_MIN_REMAINING_S=1'; echo 'BK_VMIDS="101"'; } >>"$BK_CONFIG_DIR/backup.env"
  run_weekly
  [ "$status" -eq 1 ]
  [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
  [ ! -e "$BK_STATE_DIR/last-success-weekly" ]
  grep -q "FAILED" "$BATS_TEST_TMPDIR/curl.args"
}

@test "one failing guest does not stop the others, raises one alert naming it, and records no success" {
  touch "$BATS_TEST_TMPDIR/fail-102"
  run_weekly
  [ "$status" -eq 1 ]
  ls "$BK_SMB_MOUNT"/vm/vm101-*.age "$BK_SMB_MOUNT"/vm/vm103-*.age "$BK_SMB_MOUNT"/vm/ct104-*.age
  [ -z "$(ls "$BK_SMB_MOUNT"/vm/vm102-* 2>/dev/null)" ]
  [ "$(grep -c FAILED "$BATS_TEST_TMPDIR/curl.args")" -eq 1 ]
  grep -q "102" "$BATS_TEST_TMPDIR/curl.args"
  [ ! -e "$BK_STATE_DIR/last-success-weekly" ]
}

@test "an invalid or unknown guest id is refused without executing anything" {
  sed -i 's#^BK_VMIDS=.*#BK_VMIDS="101 abc 999"#' "$BK_CONFIG_DIR/backup.env"
  run_weekly
  [ "$status" -eq 1 ]
  ls "$BK_SMB_MOUNT"/vm/vm101-*.age
  run grep -E "abc|999" "$BATS_TEST_TMPDIR/vzdump.calls"
  [ "$status" -ne 0 ]
}

@test "the prod image is preceded by a fresh database dump through the gate, other guests are not" {
  run_weekly
  [ "$status" -eq 0 ]
  [ "$(grep -c 'dump-now' "$BATS_TEST_TMPDIR/ssh.calls")" -eq 1 ]
}

@test "a failed pre-image dump only warns; the image is still taken" {
  touch "$BATS_TEST_TMPDIR/dump-fail"
  run_weekly
  [ "$status" -eq 0 ]
  ls "$BK_SMB_MOUNT"/vm/vm101-*.age
  grep -q "crash-consistent" "$BATS_TEST_TMPDIR/curl.args"
}

@test "a guest agent that is not running triggers a crash-consistent warning but not a failure" {
  touch "$BATS_TEST_TMPDIR/noagent-103"
  run_weekly
  [ "$status" -eq 0 ]
  grep -q "guest agent not running in VM 103" "$BATS_TEST_TMPDIR/curl.args"
}

@test "a low thin pool, a nearly full pool, or unreadable pool stats stop the run before any vzdump" {
  echo "  1634.87 95.00" >"$BATS_TEST_TMPDIR/poolvals"
  run_weekly; [ "$status" -eq 1 ]
  echo "  100.00 20.00" >"$BATS_TEST_TMPDIR/poolvals"
  run_weekly; [ "$status" -eq 1 ]
  rm -f "$BATS_TEST_TMPDIR/poolvals"; touch "$BATS_TEST_TMPDIR/lvs-fail"
  run_weekly; [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/vzdump.calls" ]
  [ -z "$(imgs)" ]
}

@test "a pool with plenty of absolute space but over the percentage limit still stops the run" {
  echo "  10000.00 85.00" >"$BATS_TEST_TMPDIR/poolvals"
  run_weekly
  [ "$status" -eq 1 ]
  grep -q "85" "$BATS_TEST_TMPDIR/curl.args"
  [ ! -e "$BATS_TEST_TMPDIR/vzdump.calls" ]
}

@test "an unmounted share stops the run before any vzdump" {
  stub mountpoint 'exit 1'
  run_weekly
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/vzdump.calls" ]
  [ ! -d "$BK_SMB_MOUNT/vm" ]
}

@test "a share that drops after the initial check is caught per guest before any vzdump" {
  cat >"$BATS_TEST_TMPDIR/bin/mountpoint" <<EOF
#!/usr/bin/env bash
c="$BATS_TEST_TMPDIR/mp.count"; n=\$(( \$(cat "\$c" 2>/dev/null || echo 0) + 1 )); echo "\$n" >"\$c"
[ "\$n" -le 1 ]
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/mountpoint"
  run_weekly
  [ "$status" -eq 1 ]
  grep -q "SMB share dropped" "$BATS_TEST_TMPDIR/curl.args"
  [ ! -e "$BATS_TEST_TMPDIR/vzdump.calls" ]
  [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
}

@test "a read-back hash that differs from the streamed hash discards the image" {
  cat >"$BATS_TEST_TMPDIR/bin/sha256sum" <<EOF
#!/usr/bin/env bash
c="$BATS_TEST_TMPDIR/sha.count"; n=\$(( \$(cat "\$c" 2>/dev/null || echo 0) + 1 )); echo "\$n" >"\$c"
[ \$# -eq 0 ] && cat >/dev/null
printf '%064d  -\n' "\$n"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/sha256sum"
  sed -i 's#^BK_VMIDS=.*#BK_VMIDS="103"#' "$BK_CONFIG_DIR/backup.env"
  run_weekly
  [ "$status" -eq 1 ]
  grep -q "read-back hash differs" "$BATS_TEST_TMPDIR/curl.args"
  [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
}

@test "output that is not an age file is refused and removed" {
  printf '#!/usr/bin/env bash\ncat >/dev/null; echo not-encrypted-at-all\n' >"$BATS_TEST_TMPDIR/bin/age"; chmod +x "$BATS_TEST_TMPDIR/bin/age"
  sed -i 's#^BK_VMIDS=.*#BK_VMIDS="103"#' "$BK_CONFIG_DIR/backup.env"
  echo 'BK_MIN_IMAGE_BYTES=5' >>"$BK_CONFIG_DIR/backup.env"
  run_weekly
  [ "$status" -eq 1 ]
  grep -q "not an age file" "$BATS_TEST_TMPDIR/curl.args"
  [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
}

@test "an empty or tiny image is refused and removed" {
  echo 'BK_MIN_IMAGE_BYTES=99999999' >>"$BK_CONFIG_DIR/backup.env"
  sed -i 's#^BK_VMIDS=.*#BK_VMIDS="103"#' "$BK_CONFIG_DIR/backup.env"
  run_weekly
  [ "$status" -eq 1 ]
  [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
}

@test "a failed encryption leaves no partial file on the share" {
  printf '#!/usr/bin/env bash\ncat >/dev/null; exit 1\n' >"$BATS_TEST_TMPDIR/bin/age"; chmod +x "$BATS_TEST_TMPDIR/bin/age"
  run_weekly
  [ "$status" -eq 1 ]
  [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
}

@test "retention keeps 3 images per guest and 1 for VM 102, newest first" {
  mkdir -p "$BK_SMB_MOUNT/vm"
  for d in 20260801 20260808 20260815 20260822; do
    : >"$BK_SMB_MOUNT/vm/vm101-$d-020000.vma.zst.age"
    : >"$BK_SMB_MOUNT/vm/vm102-$d-020000.vma.zst.age"
  done
  run_weekly
  [ "$status" -eq 0 ]
  [ "$(ls "$BK_SMB_MOUNT"/vm/vm101-*.age | wc -l)" -eq 3 ]
  [ "$(ls "$BK_SMB_MOUNT"/vm/vm102-*.age | wc -l)" -eq 1 ]
  [ ! -e "$BK_SMB_MOUNT/vm/vm101-20260801-020000.vma.zst.age" ]
}

@test "no recipient configured: fail closed, nothing runs" {
  sed -i 's#^BK_AGE_RECIPIENT=.*#BK_AGE_RECIPIENT=#' "$BK_CONFIG_DIR/backup.env"
  run_weekly
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/vzdump.calls" ]
  [ -z "$(imgs)" ]
}

@test "an overlapping weekly run is refused" {
  ( flock -x 9; sleep 3 ) 9>"$BK_STATE_DIR/backup-weekly.lock" &
  holder=$!
  sleep 1
  run_weekly
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/vzdump.calls" ]
  wait "$holder"
}

@test "an unexpected error raises exactly one alert" {
  stub mktemp 'exit 1'
  run_weekly
  [ "$status" -eq 1 ]
  [ "$(grep -c FAILED "$BATS_TEST_TMPDIR/curl.args")" -eq 1 ]
}

@test "a failing dead-man ping does not fail the run" {
  stub curl 'cat >/dev/null; exit 22'
  run_weekly
  [ "$status" -eq 0 ]
  [ -s "$BK_STATE_DIR/last-success-weekly" ]
}

@test "the audit log records each image with its sha256 and size" {
  run_weekly
  [ "$status" -eq 0 ]
  f="$(ls "$BK_SMB_MOUNT"/vm/vm103-*.age)"
  line="$(grep '"guest":"103"' "$BK_STATE_DIR/audit.log" | tail -n 1)"
  [ "$(printf '%s' "$line" | jq -r .sha256)" = "$(sha256sum "$f" | cut -d' ' -f1)" ]
  [ "$(printf '%s' "$line" | jq -r .size)" = "$(stat -c %s "$f")" ]
}

seed_old_images() {
  mkdir -p "$BK_SMB_MOUNT/vm"
  for st in 20260901-010000 20260908-010000 20260915-010000; do : >"$BK_SMB_MOUNT/vm/vm101-$st.vma.zst.age"; done
  : >"$BK_SMB_MOUNT/vm/vm102-20260915-010000.vma.zst.age"
}

@test "failed images never cost an existing image: every older copy survives" {
  seed_old_images
  touch "$BATS_TEST_TMPDIR/fail-101" "$BATS_TEST_TMPDIR/fail-102"
  run_weekly
  [ "$status" -eq 1 ]
  [ "$(ls "$BK_SMB_MOUNT"/vm/vm101-*.age | wc -l)" -eq 3 ]
  [ "$(ls "$BK_SMB_MOUNT"/vm/vm102-*.age | wc -l)" -eq 1 ]
}

@test "a read-back mismatch also leaves every older image in place" {
  seed_old_images
  cat >"$BATS_TEST_TMPDIR/bin/sha256sum" <<EOF
#!/usr/bin/env bash
if [ "\$#" -ge 1 ] && [ -f "\${@: -1}" ]; then echo "deadbeef  \${@: -1}"; exit 0; fi
exec /usr/bin/sha256sum "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/sha256sum"
  run_weekly
  [ "$status" -eq 1 ]
  [ "$(ls "$BK_SMB_MOUNT"/vm/vm101-*.age | wc -l)" -eq 3 ]
  [ "$(ls "$BK_SMB_MOUNT"/vm/vm102-*.age | wc -l)" -eq 1 ]
}

@test "a hung share is detected by the stall watchdog: the pipeline is killed, no partial remains, the run fails" {
  cat >"$BATS_TEST_TMPDIR/bin/vzdump" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$BATS_TEST_TMPDIR/vzdump.calls"
echo first-bytes
exec sleep 120
EOF
  { echo 'BK_VMIDS="101"'; echo 'BK_WEEKLY_STALL_S=3'; echo 'BK_WEEKLY_STALL_POLL_S=1'; echo 'BK_WEEKLY_KILL_GRACE_S=1'; } >>"$BK_CONFIG_DIR/backup.env"
  start=$SECONDS
  run_weekly
  [ "$status" -eq 1 ]
  [ $((SECONDS - start)) -lt 60 ]
  [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
  grep -q "stalled" "$BATS_TEST_TMPDIR/curl.args"
  ! pgrep -f "sleep 120" >/dev/null
}

@test "a leftover .partial from a killed earlier run is swept" {
  mkdir -p "$BK_SMB_MOUNT/vm"
  : >"$BK_SMB_MOUNT/vm/vm101-20260901-010000.vma.zst.age.partial"
  run_weekly
  [ "$status" -eq 0 ]
  [ -z "$(find "$BK_SMB_MOUNT" -name '*.partial')" ]
}

@test "--only images just the named guests and never records weekly success or pings the heartbeat" {
  run_weekly --only "104 103"
  [ "$status" -eq 0 ]
  ls "$BK_SMB_MOUNT"/vm/ct104-*.age "$BK_SMB_MOUNT"/vm/vm103-*.age
  [ -z "$(ls "$BK_SMB_MOUNT"/vm/vm101-* "$BK_SMB_MOUNT"/vm/vm102-* 2>/dev/null)" ]
  [ ! -e "$BK_STATE_DIR/last-success-weekly" ]
  ! grep -q DEADMANID "$BATS_TEST_TMPDIR/curl.stdin" 2>/dev/null
}

@test "--only refuses a guest that is not configured, before doing anything" {
  run_weekly --only "999"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not in BK_VMIDS"* ]]
  [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
  [ ! -e "$BATS_TEST_TMPDIR/vzdump.calls" ]
}

@test "an unknown option is refused" {
  run_weekly --bogus
  [ "$status" -eq 2 ]
}

@test "a full run still records success (partial handling does not leak)" {
  run_weekly
  [ "$status" -eq 0 ]
  [ -e "$BK_STATE_DIR/last-success-weekly" ]
}

# ---- abort handling: Ctrl-C, Ctrl-Z, kill, hangup must stop everything the job started ----

# sigtest SIGNAL : run the weekly job with a vzdump that hangs, send SIGNAL to the script,
# and print "rc=<exit code> leftover=<processes still running>".
sigtest() {
  cat >"$BATS_TEST_TMPDIR/bin/vzdump" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$BATS_TEST_TMPDIR/vzdump.calls"
echo first-bytes
exec sleep 317
EOF
  { echo 'BK_VMIDS="101"'; echo 'BK_KILL_GRACE_S=3'; echo 'BK_WEEKLY_STALL_S=600'; } >>"$BK_CONFIG_DIR/backup.env"
  python3 - "$SCRIPT" "$1" "$BATS_TEST_TMPDIR/sig.out" <<'PY'
import os, signal, subprocess, sys, time
script, name, outfile = sys.argv[1], sys.argv[2], sys.argv[3]
sig = getattr(signal, "SIG" + name)
def left():
    return subprocess.run(["pgrep", "-fx", "sleep 317"], capture_output=True, text=True).stdout.split()
def reap():
    subprocess.run(["pkill", "-KILL", "-fx", "sleep 317"], capture_output=True)
# output goes to a FILE: a surviving child holding a pipe open must never be able to hang the test
with open(outfile, "w") as out:
    p = subprocess.Popen(["bash", script], stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
    for _ in range(200):
        if left(): break
        time.sleep(0.1)
    else:
        p.kill(); reap(); print("never started"); sys.exit(1)
    time.sleep(1)
    os.kill(p.pid, sig)
    try:
        rc = p.wait(timeout=30)
    except subprocess.TimeoutExpired:
        p.kill(); reap(); print("script did not exit"); sys.exit(1)
time.sleep(0.5)
n = len(left())
reap()
print("rc=%d leftover=%d" % (rc, n))
print(open(outfile).read())
PY
}

@test "Ctrl-C stops the whole pipeline, removes the partial, exits 130 and raises no alert" {
  run sigtest INT
  [[ "$output" == *"rc=130 leftover=0"* ]]
  [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
  [ ! -e "$BATS_TEST_TMPDIR/curl.args" ] || ! grep -q "FAILED" "$BATS_TEST_TMPDIR/curl.args"
}

@test "Ctrl-Z does not suspend the job holding a snapshot: it aborts like Ctrl-C" {
  run sigtest TSTP
  [[ "$output" == *"rc=148 leftover=0"* ]]
  [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
}

@test "kill (SIGTERM) stops everything and raises an alert" {
  run sigtest TERM
  [[ "$output" == *"rc=143 leftover=0"* ]]
  [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
  grep -q "aborted by SIGTERM" "$BATS_TEST_TMPDIR/curl.args"
}

@test "hangup (closing the terminal) also stops everything" {
  run sigtest HUP
  [[ "$output" == *"rc=129 leftover=0"* ]]
  [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
}

# ---- progress output ---------------------------------------------------------------------------

slow_vzdump() {
  cat >"$BATS_TEST_TMPDIR/bin/vzdump" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$BATS_TEST_TMPDIR/vzdump.calls"
echo "INFO: 35% (7.0 GiB of 20.0 GiB) in 3s, read: 100 MiB/s" >&2
head -c 4000 /dev/zero | tr '\\0' x
sleep 3
head -c 4000 /dev/zero | tr '\\0' x
EOF
  { echo 'BK_VMIDS="101"'; echo 'BK_WEEKLY_PROGRESS_S=1'; } >>"$BK_CONFIG_DIR/backup.env"
}

@test "--progress prints periodic status lines with bytes written, rate and vzdump's percent" {
  slow_vzdump
  run_weekly --progress
  [ "$status" -eq 0 ]
  [[ "$output" == *"progress lines every 1s"* ]]
  [[ "$output" == *"elapsed"*"written"*"/s"* ]]
  [[ "$output" == *"35% (7.0 GiB of 20.0 GiB)"* ]]
  [[ "$output" == *"reading it back"* ]]
  [[ "$output" == *"guest 101: OK"* ]]
  ! grep -q -- '--quiet' "$BATS_TEST_TMPDIR/vzdump.calls"
}

@test "--verbose shows each stage and vzdump's own log lines" {
  slow_vzdump
  run_weekly --verbose
  [ "$status" -eq 0 ]
  [[ "$output" == *"keeping 3 images"* ]]
  [[ "$output" == *"vzdump: INFO: 35%"* ]]
  [[ "$output" == *"verifying the written file by reading it back"* ]]
}

@test "without either flag the output is brief (start and OK lines only) and vzdump stays quiet" {
  slow_vzdump
  run_weekly
  [ "$status" -eq 0 ]
  [[ "$output" == *"guest 101 (vm): starting"* ]]
  [[ "$output" == *"guest 101: OK"* ]]
  [[ "$output" != *"written"* ]]
  grep -q -- '--quiet 1' "$BATS_TEST_TMPDIR/vzdump.calls"
}

@test "-p and -v are accepted as short forms" {
  slow_vzdump
  run_weekly -p -v
  [ "$status" -eq 0 ]
  [[ "$output" == *"elapsed"* ]]
}


@test "the read-rate cap is configurable and defaults to 150 MiB/s" {
  run_weekly --only 101
  [ "$status" -eq 0 ]
  grep -q -- '--bwlimit 153600' "$BATS_TEST_TMPDIR/vzdump.calls"
  rm -f "$BATS_TEST_TMPDIR/vzdump.calls"
  echo 'BK_VZDUMP_BWLIMIT_KIB=40960' >>"$BK_CONFIG_DIR/backup.env"
  run_weekly --only 101
  [ "$status" -eq 0 ]
  grep -q -- '--bwlimit 40960' "$BATS_TEST_TMPDIR/vzdump.calls"
}
