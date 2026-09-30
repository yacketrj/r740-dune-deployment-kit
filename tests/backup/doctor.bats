#!/usr/bin/env bats
# doctor.bats -- tests for scripts/backup-doctor.sh (readiness report, design v2 T10).
# A happy-path fixture is fully green; every test then breaks exactly one thing and
# asserts the specific line goes [FAIL] or [WARN] and the exit code follows.
load helper

setup() {
  setup_env
  make_age_key
  T="$BATS_TEST_TMPDIR"
  SCRIPT="$REPO_ROOT/scripts/backup-doctor.sh"
  export BK_SMB_MOUNT="$T/smb" BK_RAM_DIR="$T/ram" RCLONE_CONFIG="$T/rclone.conf"
  mkdir -p "$BK_SMB_MOUNT" "$BK_RAM_DIR" "$BK_STAGE_DIR"
  chmod 700 "$BK_CONFIG_DIR" "$BK_STAGE_DIR"
  for f in hook deadman deadman-check sshkey known_hosts rclone.conf; do : >"$T/$f"; chmod 600 "$T/$f"; done
  cat >"$BK_CONFIG_DIR/backup.env" <<EOC
BK_AGE_RECIPIENT=$BK_AGE_RECIPIENT
BK_STATE_DIR=$BK_STATE_DIR
BK_STAGE_DIR=$BK_STAGE_DIR
BK_SMB_MOUNT=$BK_SMB_MOUNT
BK_RCLONE_REMOTE=fake:r740
BK_VMIDS="101 104"
BK_BACKUP_SSH=backup@prod.test
BK_BACKUP_SSH_KEY=$T/sshkey
BK_KNOWN_HOSTS=$T/known_hosts
BK_DISCORD_WEBHOOK_FILE=$T/hook
BK_DEADMAN_URL_FILE=$T/deadman
BK_CHECK_DEADMAN_URL_FILE=$T/deadman-check
BK_DRILL_SSH=dune@dev.test
BK_DRILL_KNOWN_HOSTS=$T/known_hosts
BK_DRILL_PG_IMAGE=postgres:17
BK_DRILL_ROW_CHECKS="dune.x:1"
BK_DRILL_MIN_TABLES=3
BK_DRILL_VM_CHECK_101=true
BK_DRILL_VM_CHECK_104=true
EOC
  chmod 600 "$BK_CONFIG_DIR/backup.env"
  mkdir -p "$BK_STATE_DIR"
  now="$(date +%s)"
  printf '%s\tescrow\tPASS\tx\n%s\tdrill-db\tPASS\tx\n' "$(date -u -d "@$((now - 86400))" +%Y-%m-%dT%H:%M:%SZ)" "$(date -u -d "@$((now - 86400))" +%Y-%m-%dT%H:%M:%SZ)" >"$BK_STATE_DIR/evidence.log"
  stub mountpoint 'exit 0'
  stub curl 'case "$*" in *"-K -"*) cat >/dev/null ;; esac'
  stub dpkg 'exit 0'
  stub lvs 'echo "  1634.87 20.00"'
  stub rclone 'exit 0'
  stub vzdump 'exit 0'
  stub pct '[ "$1" = "status" ] && [ "$2" = "104" ]'
  stub qm 'case "$1" in status) [ "$2" = "101" ] ;; agent) [ ! -f "$BATS_TEST_TMPDIR/noagent" ] ;; esac'
  stub systemctl 'exit 0'
  stub findmnt 'echo "rw,vers=3.1.1,seal,cache=none"'
  cat >"$T/bin/ssh" <<EOS
#!/usr/bin/env bash
echo "\$*" >>"$T/ssh.calls"
[ -f "$T/gate-down" ] && exit 255
echo "repo_present=1"; echo "newest_automatic_epoch=\$(( \$(date +%s) - ${GATE_AGE_S:-7200} ))"
EOS
  chmod +x "$T/bin/ssh"
  rm -f "$T/rclone.calls"
}

doctor() { run bash "$SCRIPT" "$@"; }
line() { printf '%s\n' "$output" | grep -F "$1"; }

@test "happy path: everything is OK and the exit code is 0" {
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 FAIL, 0 WARN"* ]]
  [[ "$output" != *"[FAIL]"* ]]
}

@test "a config directory that is not 0700 fails" {
  chmod 755 "$BK_CONFIG_DIR"
  doctor
  [ "$status" -eq 1 ]
  line "[FAIL] config directory"
}

@test "a config file, webhook file, or SSH key readable by others fails" {
  chmod 644 "$BK_CONFIG_DIR/backup.env" "$T/hook" "$T/sshkey"
  doctor
  [ "$status" -eq 1 ]
  line "[FAIL] config file"
  line "[FAIL] Discord webhook file"
  line "[FAIL] backup SSH key"
}

@test "a missing webhook file fails and says it does not exist" {
  rm -f "$T/hook"
  doctor
  [ "$status" -eq 1 ]
  line "[FAIL] Discord webhook file: $T/hook does not exist"
}

@test "no recipient configured fails" {
  sed -i 's#^BK_AGE_RECIPIENT=.*#BK_AGE_RECIPIENT=#' "$BK_CONFIG_DIR/backup.env"
  doctor
  [ "$status" -eq 1 ]
  line "[FAIL] age recipient"
}

@test "an age PRIVATE key anywhere in the config, state or staging directories fails" {
  for d in "$BK_CONFIG_DIR" "$BK_STATE_DIR" "$BK_STAGE_DIR"; do
    cp "$BK_AGE_IDENTITY" "$d/oops.txt"
    doctor
    [ "$status" -eq 1 ]
    line "[FAIL] an age PRIVATE key is on this host"
    rm -f "$d/oops.txt"
  done
}

@test "escrow never verified, or too old, fails" {
  : >"$BK_STATE_DIR/evidence.log"
  doctor
  [ "$status" -eq 1 ]
  line "[FAIL] key escrow: never verified"
  printf '%s\tescrow\tPASS\tx\n' "$(date -u -d "@$((now - 200 * 86400))" +%Y-%m-%dT%H:%M:%SZ)" >"$BK_STATE_DIR/evidence.log"
  doctor
  [ "$status" -eq 1 ]
  line "[FAIL] key escrow: last verified 200 days ago"
}

@test "a missing tool fails and names it" {
  BK_DOCTOR_TOOLS="age nonexistent-tool-xyz another-missing-tool" doctor
  [ "$status" -eq 1 ]
  line "[FAIL] tools missing: nonexistent-tool-xyz another-missing-tool"
}

@test "modified core system binaries fail (INC-2026-09-29)" {
  stub dpkg 'echo "??5??????   /usr/bin/mkdir"'
  doctor
  [ "$status" -eq 1 ]
  line "[FAIL] core system binaries differ"
}

@test "staging directory with the wrong mode, or missing, fails" {
  chmod 755 "$BK_STAGE_DIR"
  doctor
  [ "$status" -eq 1 ]
  line "[FAIL] staging directory"
  rmdir "$BK_STAGE_DIR"
  doctor
  [ "$status" -eq 1 ]
  line "[FAIL] staging directory"
}

@test "an unmounted SMB share fails" {
  stub mountpoint 'exit 1'
  doctor
  [ "$status" -eq 1 ]
  line "[FAIL] SMB share is not mounted"
}

@test "a mounted but unwritable SMB share fails, and the probe file is not left behind" {
  rmdir "$BK_SMB_MOUNT"
  doctor
  [ "$status" -eq 1 ]
  line "[FAIL] SMB share mounted but NOT writable"
  mkdir -p "$BK_SMB_MOUNT"
  doctor
  [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
}

@test "a thin pool with too little free space fails; unreadable stats fail" {
  stub lvs 'echo "  100.00 20.00"'
  doctor
  [ "$status" -eq 1 ]
  line "[FAIL] thin pool"
  stub lvs 'exit 1'
  doctor
  [ "$status" -eq 1 ]
  line "[FAIL] cannot read thin pool usage"
}

@test "an unreachable OneDrive fails" {
  stub rclone '[ "$1" != "lsd" ]'
  doctor
  [ "$status" -eq 1 ]
  line "[FAIL] OneDrive not reachable"
}

@test "an unreachable pull gate fails" {
  touch "$T/gate-down"
  doctor
  [ "$status" -eq 1 ]
  line "[FAIL] pull gate not reachable"
}

@test "a reachable gate with a stale dump fails" {
  sed -i 's/7200/200000/' "$T/bin/ssh"
  doctor
  [ "$status" -eq 1 ]
  line "[FAIL] pull gate reachable but there is no fresh automatic dump"
}

@test "a guest agent that is not running is only a WARNING and does not fail the run" {
  touch "$T/noagent"
  doctor
  [ "$status" -eq 0 ]
  line "[WARN] guest agent NOT running in VM 101"
}

@test "a guest that does not exist, or an invalid id, fails" {
  sed -i 's#^BK_VMIDS=.*#BK_VMIDS="101 555 1;rm"#' "$BK_CONFIG_DIR/backup.env"
  doctor
  [ "$status" -eq 1 ]
  line "[FAIL] guest 555 does not exist"
  line "[FAIL] invalid guest id"
}

@test "an unconfigured database drill fails; missing in-guest checks and no drill yet only warn" {
  sed -i '/BK_DRILL_PG_IMAGE/d' "$BK_CONFIG_DIR/backup.env"
  doctor
  [ "$status" -eq 1 ]
  line "[FAIL] database drill not fully configured"
  sed -i '/BK_DRILL_VM_CHECK_104/d' "$BK_CONFIG_DIR/backup.env"
  echo 'BK_DRILL_PG_IMAGE=postgres:17' >>"$BK_CONFIG_DIR/backup.env"
  : >"$BK_STATE_DIR/evidence.log"; printf '%s\tescrow\tPASS\tx\n' "$(date -u -d "@$((now - 86400))" +%Y-%m-%dT%H:%M:%SZ)" >"$BK_STATE_DIR/evidence.log"
  doctor
  [ "$status" -eq 0 ]
  line "[WARN] no in-guest drill check configured for: 104"
  line "[WARN] no database restore drill recorded yet"
}

@test "no dead-man's-switch configured fails, for the jobs and for the alarm" {
  sed -i '/^BK_DEADMAN_URL_FILE=/d;/^BK_CHECK_DEADMAN_URL_FILE=/d' "$BK_CONFIG_DIR/backup.env"
  doctor
  [ "$status" -eq 1 ]
  line "[FAIL] dead-man's-switch URL file (backup jobs): not configured"
  line "[FAIL] dead-man's-switch URL file (alarm): not configured"
}

@test "timers that are not active only warn" {
  stub systemctl 'exit 3'
  doctor
  [ "$status" -eq 0 ]
  line "[WARN] timers not active"
}

@test "--live checks egress and delivers a test message; failures fail the run" {
  doctor --live
  [ "$status" -eq 0 ]
  line "[ OK ] egress to login.microsoftonline.com"
  stub curl 'case "$*" in *"-K -"*) cat >/dev/null ;; esac; exit 6'
  doctor --live
  [ "$status" -eq 1 ]
  line "[FAIL] cannot reach login.microsoftonline.com"
  line "[FAIL] Discord webhook could not deliver"
}

@test "the doctor changes nothing: config, evidence and backups are identical afterwards" {
  before="$(find "$BK_CONFIG_DIR" "$BK_STATE_DIR" "$BK_SMB_MOUNT" -type f -exec sha256sum {} + | sort)"
  doctor
  after="$(find "$BK_CONFIG_DIR" "$BK_STATE_DIR" "$BK_SMB_MOUNT" -type f -exec sha256sum {} + | sort)"
  [ "$before" = "$after" ]
}

@test "the report never prints secrets" {
  printf 'https://discord.com/api/webhooks/1/TOPSECRET\n' >"$T/hook"
  doctor
  [[ "$output" != *"TOPSECRET"* ]]
}

@test "a broken audit-log hash chain fails and names the line" {
  export BK_STATE_DIR="$BK_STATE_DIR"
  for i in 1 2 3; do (source "$REPO_ROOT/scripts/backup-common.sh"; bk_audit_log run_ok "n=$i"); done
  sed -i '2s/"n":"2"/"n":"7"/' "$BK_STATE_DIR/audit.log"
  doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"audit log hash chain BROKEN at line 3"* ]]
}

@test "an SMB mount without seal or cache=none warns (does not fail)" {
  stub findmnt 'echo "rw,vers=3.0"'
  doctor
  [[ "$output" == *"missing option(s): vers=3.1.1 seal cache=none"* ]]
  [ "$status" -eq 0 ]
}

@test "with BK_HEARTBEAT_REQUIRED=0 a missing dead-man's-switch is a warning, not a failure" {
  sed -i '/BK_DEADMAN_URL_FILE/d;/BK_CHECK_DEADMAN_URL_FILE/d' "$BK_CONFIG_DIR/backup.env"
  echo 'BK_HEARTBEAT_REQUIRED=0' >>"$BK_CONFIG_DIR/backup.env"
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"no external dead-man's-switch configured"* ]]
}

@test "with no OneDrive configured the doctor passes and does not need rclone" {
  sed -i '/^BK_RCLONE_REMOTE=/d' "$BK_CONFIG_DIR/backup.env"
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"OneDrive not used"* ]]
}

@test "optional heartbeat: a configured-but-missing file is a warning, not a failure" {
  echo 'BK_HEARTBEAT_REQUIRED=0' >>"$BK_CONFIG_DIR/backup.env"
  rm -f "$T/deadman" "$T/deadman-check"
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"no external dead-man's-switch configured"* ]]
  [[ "$output" != *"[FAIL] dead-man"* ]]
}
