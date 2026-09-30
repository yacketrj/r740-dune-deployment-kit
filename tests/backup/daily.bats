#!/usr/bin/env bats
# daily.bats -- tests for scripts/backup-daily.sh v2 (DB tier + daily set).
# The stubbed ssh runs the REAL gate script against a fake repo, so the pull
# contract is tested end to end. age, tar and sha256sum are real; rclone is a
# small local-directory fake. Everything lives under BATS_TEST_TMPDIR.
load helper

setup() {
  setup_env
  make_age_key
  SCRIPT="$REPO_ROOT/scripts/backup-daily.sh"
  GATE="$REPO_ROOT/scripts/dune-prod/r740-backup-gate.sh"
  export BK_SMB_MOUNT="$BATS_TEST_TMPDIR/smb"
  REMOTE_ROOT="$BATS_TEST_TMPDIR/remote"
  REPO="$BATS_TEST_TMPDIR/prodrepo"
  DB="$REPO/runtime/backups/db"
  mkdir -p "$BK_SMB_MOUNT" "$REMOTE_ROOT" "$DB" "$REPO/runtime/secrets" "$BATS_TEST_TMPDIR/etc-host"
  echo "funcom-token-value" >"$REPO/runtime/secrets/funcom-token.txt"
  echo "SERVER_IP=1.2.3.4" >"$REPO/.env"
  echo "duneawakening" >"$BATS_TEST_TMPDIR/etc-host/hostname"
  printf 'https://hc.example/ping/DEADMANID\n' >"$BATS_TEST_TMPDIR/deadman"
  printf 'https://discord.com/api/webhooks/1/x\n' >"$BATS_TEST_TMPDIR/hook"
  : >"$BATS_TEST_TMPDIR/known_hosts"
  cat >"$BK_CONFIG_DIR/backup.env" <<EOF
BK_AGE_RECIPIENT=$BK_AGE_RECIPIENT
BK_STAGE_DIR=$BK_STAGE_DIR
BK_STATE_DIR=$BK_STATE_DIR
BK_SMB_MOUNT=$BK_SMB_MOUNT
BK_RCLONE_REMOTE=fake:r740
BK_RCLONE_CHECK_CMD=check
BK_BACKUP_SSH=backup@prod.test
BK_KNOWN_HOSTS=$BATS_TEST_TMPDIR/known_hosts
BK_HOST_PATHS="hostfiles/hostname"
BK_DEADMAN_URL_FILE=$BATS_TEST_TMPDIR/deadman
BK_DISCORD_WEBHOOK_FILE=$BATS_TEST_TMPDIR/hook
BK_MIN_STAGE_GB=0
EOF
  # host config lives under a fake root reachable as "/" is not possible; use a relative fake via a wrapper for tar -C /
  mkdir -p "$BATS_TEST_TMPDIR/hostfiles"
  echo "duneawakening" >"$BATS_TEST_TMPDIR/hostfiles/hostname"
  sed -i "s#^BK_HOST_PATHS=.*#BK_HOST_PATHS=\"${BATS_TEST_TMPDIR#/}/hostfiles/hostname\"#" "$BK_CONFIG_DIR/backup.env"
  mk_dump auto-1.backup automatic 7200
  mk_dump safety-1.backup vehicle-delete 3600
  mk_dump seed-1.backup market-bot-seed 60
  stub_ssh_gate
  stub_rclone
  stub mountpoint 'exit 0'
  stub curl 'cat >>"$BATS_TEST_TMPDIR/curl.stdin"; echo "$*" >>"$BATS_TEST_TMPDIR/curl.args"'
}

# mk_dump NAME ORIGIN AGE_SECONDS [BYTES] [MAGIC]
mk_dump() {
  local name="$1" origin="$2" age="$3" bytes="${4:-400}" magic="${5:-PGDMP}" now
  now="$(date +%s)"
  { printf '%s' "$magic"; head -c "$bytes" /dev/zero | tr '\0' 'x'; } >"$DB/$name"
  printf 'backup_file: %s\nbackup_origin: %s\nformat: pg_dump_custom\n' "$name" "$origin" >"$DB/$name.yaml"
  touch -d "@$((now - age))" "$DB/$name" "$DB/$name.yaml"
}

# ssh stub: log the call, then run the real gate against the fake repo.
stub_ssh_gate() {
  cat >"$BATS_TEST_TMPDIR/bin/ssh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/ssh.calls"
req="\${@: -1}"
SSH_ORIGINAL_COMMAND="\$req" R740_GATE_REPO="$REPO" R740_GATE_SIZE_FLOOR=100 R740_GATE_SETTLE_SECONDS=5 exec bash "$GATE"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/ssh"
}

# rclone stub backed by a local directory: fake:r740/<path> -> $REMOTE_ROOT/<path>
stub_rclone() {
  cat >"$BATS_TEST_TMPDIR/bin/rclone" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/rclone.calls"
root="$REMOTE_ROOT"
map() { case "\$1" in fake:r740/*) printf '%s' "\$root/\${1#fake:r740/}" ;; *) printf '%s' "\$1" ;; esac; }
case "\$1" in
  copyto) dest="\$(map "\$3")"; mkdir -p "\$(dirname "\$dest")"; cp -f -- "\$2" "\$dest" ;;
  check|cryptcheck)
    shift; inc=""; args=()
    while [ \$# -gt 0 ]; do case "\$1" in --one-way) shift ;; --include) inc="\${2#/}"; shift 2 ;; *) args+=("\$1"); shift ;; esac; done
    cmp -s -- "\${args[0]}/\$inc" "\$(map "\${args[1]}")/\$inc" ;;
  lsf) d="\$(map "\${@: -1}")"; [ -d "\$d" ] && ls -1 "\$d" || true ;;
  deletefile) rm -f -- "\$(map "\$2")" ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/rclone"
}

run_daily() { run bash "$SCRIPT" "$@"; }

decrypt_latest() { # prefix -> extracts into $BATS_TEST_TMPDIR/x
  local f
  f="$(ls "$BK_SMB_MOUNT/$1"/"$1"-*.tar.age | tail -n 1)"
  mkdir -p "$BATS_TEST_TMPDIR/x"
  age -d -i "$BK_AGE_IDENTITY" "$f" | tar -xf - -C "$BATS_TEST_TMPDIR/x"
}

@test "daily tier: archives to SMB and the remote, encrypted, with prod tree, host config and a valid manifest" {
  run_daily --tier daily
  [ "$status" -eq 0 ]
  n="$(ls "$BK_SMB_MOUNT"/daily/daily-*.tar.age | wc -l)"
  [ "$n" -eq 1 ]
  [ "$(ls "$REMOTE_ROOT"/daily/daily-*.tar.age | wc -l)" -eq 1 ]
  decrypt_latest daily
  X="$BATS_TEST_TMPDIR/x"
  [ -f "$X/prod/runtime/backups/db/auto-1.backup" ]
  [ -f "$X/prod/runtime/backups/db/safety-1.backup" ]
  [ ! -e "$X/prod/runtime/backups/db/seed-1.backup" ]
  [ -f "$X/prod/runtime/secrets/funcom-token.txt" ]
  [ -f "$X/prod/.env" ]
  [ -n "$(find "$X/host" -type f)" ]
  ( cd "$X" && sha256sum -c MANIFEST.sha256 >/dev/null )
}

@test "daily tier: records state, an audit line with the hash, pings the dead-man, posts a quiet summary" {
  run_daily --tier daily
  [ "$status" -eq 0 ]
  [ -s "$BK_STATE_DIR/last-success-daily" ]
  line="$(tail -n 1 "$BK_STATE_DIR/audit.log")"
  [ "$(printf '%s' "$line" | jq -r .event)" = "run_ok" ]
  f="$(ls "$BK_SMB_MOUNT"/daily/daily-*.tar.age)"
  [ "$(printf '%s' "$line" | jq -r .sha256)" = "$(sha256sum "$f" | cut -d' ' -f1)" ]
  grep -q DEADMANID "$BATS_TEST_TMPDIR/curl.stdin"
  grep -q "daily backup OK" "$BATS_TEST_TMPDIR/curl.args"
}

@test "db tier: only database pairs, no secrets or host config, its own state key, no success chatter" {
  run_daily --tier db
  [ "$status" -eq 0 ]
  decrypt_latest dbtier
  X="$BATS_TEST_TMPDIR/x"
  [ -f "$X/prod/runtime/backups/db/auto-1.backup" ]
  [ ! -e "$X/prod/runtime/secrets" ]
  [ ! -e "$X/prod/.env" ]
  [ -z "$(find "$X/host" -type f)" ]
  [ -s "$BK_STATE_DIR/last-success-dbtier" ]
  [ ! -e "$BK_STATE_DIR/last-success-daily" ]
  run grep -q "backup OK" "$BATS_TEST_TMPDIR/curl.args"
  [ "$status" -ne 0 ]
}

@test "the pull uses the pinned host key, batch mode and the tier's gate request" {
  run_daily --tier daily
  [ "$status" -eq 0 ]
  c="$(cat "$BATS_TEST_TMPDIR/ssh.calls")"
  [[ "$c" == *"StrictHostKeyChecking=yes"* ]]
  [[ "$c" == *"UserKnownHostsFile=$BATS_TEST_TMPDIR/known_hosts"* ]]
  [[ "$c" == *"BatchMode=yes"* ]]
  [[ "$c" == *"backup@prod.test set 30 48"* ]]
}

@test "a stale dump makes the gate refuse: one alert at stage pull, nothing stored, no success" {
  mk_dump auto-1.backup automatic $((60 * 3600))
  run_daily --tier daily
  [ "$status" -eq 1 ]
  [ "$(grep -c "FAILED" "$BATS_TEST_TMPDIR/curl.args")" -eq 1 ]
  grep -q "stage 'pull'" "$BATS_TEST_TMPDIR/curl.args"
  [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
  [ -z "$(find "$REMOTE_ROOT" -type f)" ]
  [ ! -e "$BK_STATE_DIR/last-success-daily" ]
}

@test "a truncated pull is rejected at stage verify" {
  cat >"$BATS_TEST_TMPDIR/bin/ssh" <<EOF
#!/usr/bin/env bash
SSH_ORIGINAL_COMMAND="\${@: -1}" R740_GATE_REPO="$REPO" R740_GATE_SIZE_FLOOR=100 R740_GATE_SETTLE_SECONDS=5 bash "$GATE" | head -c 700
EOF
  run_daily --tier daily
  [ "$status" -eq 1 ]
  grep -q "stage 'verify'" "$BATS_TEST_TMPDIR/curl.args"
  [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
}

# tamper_pull MODE : make the ssh stub return the REAL gate output with one change,
# so that only the daily job's own verification can reject it.
tamper_pull() {
  cat >"$BATS_TEST_TMPDIR/bin/ssh" <<EOF
#!/usr/bin/env bash
req="\${@: -1}"
SSH_ORIGINAL_COMMAND="\$req" R740_GATE_REPO="$REPO" R740_GATE_SIZE_FLOOR=100 R740_GATE_SETTLE_SECONDS=5 bash "$GATE" >"$BATS_TEST_TMPDIR/real.tar" || exit \$?
python3 - "$BATS_TEST_TMPDIR/real.tar" "$1" <<'PY'
import sys, tarfile, io
src, mode = sys.argv[1], sys.argv[2]
tin = tarfile.open(src)
tout = tarfile.open(fileobj=sys.stdout.buffer, mode="w|")
for m in tin.getmembers():
    data = tin.extractfile(m).read() if m.isfile() else None
    if mode == "nosecrets" and m.name.startswith("runtime/secrets"): continue
    if mode == "emptyenv" and m.name == ".env":
        m.size = 0; data = b""
    tout.addfile(m, io.BytesIO(data) if data is not None else None)
if mode == "dotdot":
    i = tarfile.TarInfo("../escape.txt"); i.size = 4; tout.addfile(i, io.BytesIO(b"evil"))
if mode == "absolute":
    i = tarfile.TarInfo("/etc/escape.txt"); i.size = 4; tout.addfile(i, io.BytesIO(b"evil"))
tout.close()
PY
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/ssh"
}

@test "a pulled archive with a parent-relative or absolute member is rejected even when everything else is valid" {
  for mode in dotdot absolute; do
    tamper_pull "$mode"
    run_daily --tier daily
    [ "$status" -eq 1 ]
    grep -q "stage 'verify'" "$BATS_TEST_TMPDIR/curl.args"
    grep -q "parent-relative" "$BATS_TEST_TMPDIR/curl.args"
    [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
    rm -f "$BATS_TEST_TMPDIR/curl.args"
  done
}

@test "a pulled archive missing runtime/secrets, or with an empty .env, fails the daily set at verify" {
  for mode in nosecrets emptyenv; do
    tamper_pull "$mode"
    run_daily --tier daily
    [ "$status" -eq 1 ]
    grep -q "stage 'verify'" "$BATS_TEST_TMPDIR/curl.args"
    [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
    rm -f "$BATS_TEST_TMPDIR/curl.args"
  done
}

@test "a dump without the PGDMP header is rejected at stage verify" {
  mk_dump safety-1.backup vehicle-delete 3600 400 "JUNK!"
  run_daily --tier daily
  [ "$status" -eq 1 ]
  grep -q "stage 'verify'" "$BATS_TEST_TMPDIR/curl.args"
  [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
}

@test "missing secrets fail the daily set" {
  rm -rf "$REPO/runtime/secrets"
  run_daily --tier daily
  [ "$status" -eq 1 ]
  [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
}

@test "an unmounted share stops everything before any pull or write" {
  stub mountpoint 'exit 1'
  run_daily --tier daily
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/ssh.calls" ]
  [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
  [ ! -e "$BK_STATE_DIR/last-success-daily" ]
}

@test "a share that drops mid-run is caught before the write and nothing lands" {
  cat >"$BATS_TEST_TMPDIR/bin/mountpoint" <<EOF
#!/usr/bin/env bash
c="$BATS_TEST_TMPDIR/mp.count"; n=\$(( \$(cat "\$c" 2>/dev/null || echo 0) + 1 )); echo "\$n" >"\$c"
[ "\$n" -le 1 ]
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/mountpoint"
  run_daily --tier daily
  [ "$status" -eq 1 ]
  grep -q "stage 'smb'" "$BATS_TEST_TMPDIR/curl.args"
  [ ! -d "$BK_SMB_MOUNT/daily" ]
  [ ! -e "$REMOTE_ROOT/daily" ]
}

@test "a failed bit-exact SMB verification leaves no partial and no final file" {
  stub cmp 'exit 1'
  run_daily --tier daily
  [ "$status" -eq 1 ]
  grep -q "stage 'smb'" "$BATS_TEST_TMPDIR/curl.args"
  [ -z "$(find "$BK_SMB_MOUNT" -name '*.partial' -o -name '*.tar.age')" ]
  [ ! -e "$BK_STATE_DIR/last-success-daily" ]
}

@test "an upload failure alerts at stage upload, records no success and prunes nothing" {
  mkdir -p "$BK_SMB_MOUNT/daily"
  for d in $(seq 1 35); do : >"$BK_SMB_MOUNT/daily/daily-202608$(printf '%02d' $((d % 28 + 1)))-0400$(printf '%02d' "$d").tar.age"; done
  before="$(ls "$BK_SMB_MOUNT/daily" | wc -l)"
  cat >"$BATS_TEST_TMPDIR/bin/rclone" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/rclone.calls"
[ "\$1" = "copyto" ] && exit 1
exit 0
EOF
  run_daily --tier daily
  [ "$status" -eq 1 ]
  grep -q "stage 'upload'" "$BATS_TEST_TMPDIR/curl.args"
  [ ! -e "$BK_STATE_DIR/last-success-daily" ]
  [ "$(ls "$BK_SMB_MOUNT/daily" | wc -l)" -eq $((before + 1)) ]
}

@test "a transfer that does not verify alerts and prunes nothing" {
  cat >"$BATS_TEST_TMPDIR/bin/rclone" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/rclone.calls"
case "\$1" in check|cryptcheck) exit 1 ;; *) exit 0 ;; esac
EOF
  run_daily --tier daily
  [ "$status" -eq 1 ]
  grep -q "stage 'verify-transfer'" "$BATS_TEST_TMPDIR/curl.args"
  run grep -E '^(deletefile|lsf)' "$BATS_TEST_TMPDIR/rclone.calls"
  [ "$status" -ne 0 ]
  [ ! -e "$BK_STATE_DIR/last-success-daily" ]
}

@test "with no recipient configured it fails closed: no pull, no output anywhere" {
  sed -i 's#^BK_AGE_RECIPIENT=.*#BK_AGE_RECIPIENT=#' "$BK_CONFIG_DIR/backup.env"
  run_daily --tier daily
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/ssh.calls" ]
  [ -z "$(find "$BK_SMB_MOUNT" "$REMOTE_ROOT" -type f)" ]
}

@test "a garbled recipient fails closed at encryption and stores nothing" {
  sed -i 's#^BK_AGE_RECIPIENT=.*#BK_AGE_RECIPIENT=age1notarealkey#' "$BK_CONFIG_DIR/backup.env"
  run_daily --tier daily
  [ "$status" -eq 1 ]
  [ -z "$(find "$BK_SMB_MOUNT" "$REMOTE_ROOT" -type f)" ]
  [ -z "$(ls -A "$BK_STAGE_DIR")" ]
}

@test "an overlapping run of the same tier is refused and writes nothing" {
  ( flock -x 9; sleep 3 ) 9>"$BK_STATE_DIR/backup-daily.lock" &
  holder=$!
  sleep 1
  run_daily --tier daily
  [ "$status" -eq 1 ]
  [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
  wait "$holder"
}

@test "an unexpected error raises exactly one alert" {
  stub mktemp 'exit 1'
  run_daily --tier daily
  [ "$status" -eq 1 ]
  [ "$(grep -c "FAILED" "$BATS_TEST_TMPDIR/curl.args")" -eq 1 ]
  [ ! -e "$BK_STATE_DIR/last-success-daily" ]
}

@test "staging is left empty, and a stale plaintext work dir from an earlier run is swept" {
  mkdir -p "$BK_STAGE_DIR/daily.STALE" "$BK_STAGE_DIR/keepme"
  echo secret >"$BK_STAGE_DIR/daily.STALE/plain"
  run_daily --tier daily
  [ "$status" -eq 0 ]
  [ ! -e "$BK_STAGE_DIR/daily.STALE" ]
  [ -d "$BK_STAGE_DIR/keepme" ]
  [ "$(ls -A "$BK_STAGE_DIR" | wc -l)" -eq 1 ]
}

@test "a host path under /root/.config is refused (it holds key and rclone material)" {
  sed -i 's#^BK_HOST_PATHS=.*#BK_HOST_PATHS="root/.config/rclone/rclone.conf"#' "$BK_CONFIG_DIR/backup.env"
  run_daily --tier daily
  [ "$status" -eq 1 ]
  [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
}

@test "a host-config path that yields no files (an empty directory) fails the daily set" {
  mkdir -p "$BATS_TEST_TMPDIR/emptydir"
  sed -i "s#^BK_HOST_PATHS=.*#BK_HOST_PATHS=\"${BATS_TEST_TMPDIR#/}/emptydir\"#" "$BK_CONFIG_DIR/backup.env"
  run_daily --tier daily
  [ "$status" -eq 1 ]
  grep -q "stage 'host-config'" "$BATS_TEST_TMPDIR/curl.args"
  grep -q "empty" "$BATS_TEST_TMPDIR/curl.args"
  [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
}

@test "a host-config path that does not exist fails the daily set" {
  sed -i 's#^BK_HOST_PATHS=.*#BK_HOST_PATHS="nonexistent/path"#' "$BK_CONFIG_DIR/backup.env"
  run_daily --tier daily
  [ "$status" -eq 1 ]
  [ -z "$(find "$BK_SMB_MOUNT" -type f)" ]
}

@test "a dead-man ping that fails does not fail the backup" {
  stub curl 'cat >/dev/null; exit 22'
  run_daily --tier daily
  [ "$status" -eq 0 ]
  [ -s "$BK_STATE_DIR/last-success-daily" ]
}

@test "after a verified run, retention prunes old daily copies on both the share and the remote" {
  mkdir -p "$BK_SMB_MOUNT/daily" "$REMOTE_ROOT/daily"
  for d in $(seq 1 40); do
    f="daily-20260$(printf '%d' $((1 + d / 30)))$(printf '%02d' $((d % 28 + 1)))-040000.tar.age"
    : >"$BK_SMB_MOUNT/daily/$f"; : >"$REMOTE_ROOT/daily/$f"
  done
  run_daily --tier daily
  [ "$status" -eq 0 ]
  [ "$(ls "$BK_SMB_MOUNT/daily" | wc -l)" -le 42 ]
  latest="$(ls "$BK_SMB_MOUNT/daily" | sort | tail -n 1)"
  [ -f "$REMOTE_ROOT/daily/$latest" ]
}

@test "secrets never appear in the job's output or alerts" {
  run_daily --tier daily
  [ "$status" -eq 0 ]
  [[ "$output" != *"funcom-token-value"* ]]
  run grep -q "funcom-token-value" "$BATS_TEST_TMPDIR/curl.args"
  [ "$status" -ne 0 ]
}

@test "an unknown or missing tier exits 2" {
  run_daily --tier weekly
  [ "$status" -eq 2 ]
  run_daily
  [ "$status" -eq 2 ]
}
