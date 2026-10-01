#!/usr/bin/env bats
# drill.bats -- tests for scripts/backup-drill.sh (design v2: pipeline, db and vm restore drills).
# age, zstd, tar and sha256sum are real; docker, qm, pct, qmrestore, ip, ssh and rclone are stubs.
# The key safety properties: cleanup on EVERY failure path, nothing but its own
# throwaway resources is ever touched, decrypted material never leaves the RAM dir,
# and the scratch VM is capped and isolated before it can boot.
load helper

setup() {
  setup_env
  make_age_key
  T="$BATS_TEST_TMPDIR"
  SCRIPT="$REPO_ROOT/scripts/backup-drill.sh"
  export BK_SMB_MOUNT="$T/smb"
  export BK_RAM_DIR="$T/ram"
  REMOTE_ROOT="$T/remote"
  mkdir -p "$BK_SMB_MOUNT/daily" "$BK_SMB_MOUNT/vm" "$BK_RAM_DIR" "$REMOTE_ROOT" "$T/docker"
  printf 'https://discord.com/api/webhooks/1/x\n' >"$T/hook"
  printf 'https://hc.example/ping/DEADMANID\n' >"$T/deadman"
  cat >"$BK_CONFIG_DIR/backup.env" <<EOF
BK_AGE_RECIPIENT=$BK_AGE_RECIPIENT
BK_STATE_DIR=$BK_STATE_DIR
BK_SMB_MOUNT=$BK_SMB_MOUNT
BK_RCLONE_REMOTE=fake:r740
BK_VMIDS="101 102 103 104"
BK_DRILL_SSH=dune@dev.test
BK_DRILL_KNOWN_HOSTS=$T/known_hosts
BK_DRILL_NET_SYSFS=$T/sysfs
BK_DRILL_PG_IMAGE=postgres:17
BK_DRILL_MIN_TABLES=3
BK_DRILL_ROW_CHECKS="dune.world_partition:2 dune.players:1"
BK_DRILL_VM_CHECK_102="docker exec dune-postgres pg_isready"
BK_DRILL_VM_CHECK_104="systemctl is-active something"
BK_DRILL_BOOT_TRIES=3
BK_DRILL_BOOT_SLEEP=0
BK_DRILL_VM_MEMORY_MB=4096
BK_DISCORD_WEBHOOK_FILE=$T/hook
BK_DEADMAN_URL_FILE=$T/deadman
BK_DRILL_GUARD=0
BK_DRILL_MEMINFO=$T/meminfo
BK_DRILL_NODE_SYSFS=$T/node
EOF
  export BK_DRILL_NOW_MIN=720
  printf 'MemTotal: 263700000 kB\nMemAvailable: 141000000 kB\n' >"$T/meminfo"
  mkdir -p "$T/node/node1"; printf 'Node 1 MemTotal: 132000000 kB\nNode 1 MemFree: 66000000 kB\n' >"$T/node/node1/meminfo"
  stub mountpoint 'exit 0'
  stub curl 'cat >>"$BATS_TEST_TMPDIR/curl.stdin"; echo "$*" >>"$BATS_TEST_TMPDIR/curl.args"'
  make_rclone
  make_docker_and_ssh
  make_proxmox_stubs
}

# ---------- stubs --------------------------------------------------------------------
make_rclone() {
  cat >"$T/bin/rclone" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/rclone.calls"
map() { case "\$1" in fake:r740/*) printf '%s' "$REMOTE_ROOT/\${1#fake:r740/}" ;; *) printf '%s' "\$1" ;; esac; }
case "\$1" in
  copyto) [ -f "$T/upload-fail" ] && [ "\${2#fake:}" = "\$2" ] && exit 1
          src="\$(map "\$2")"; dest="\$(map "\$3")"; mkdir -p "\$(dirname "\$dest")"; cp -f -- "\$src" "\$dest"
          if [ -f "$T/corrupt-download" ] && [ "\${2#fake:}" != "\$2" ]; then printf 'X' >>"\$dest"; fi ;;
  deletefile) rm -f -- "\$(map "\$2")" ;;
esac
EOF
  chmod +x "$T/bin/rclone"
}

make_docker_and_ssh() {
  cat >"$T/bin/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/docker.calls"
S="$T/docker"
case "\$1" in
  run) [ -f "\$S/run-fail" ] && exit 1
       name=""; while [ \$# -gt 0 ]; do [ "\$1" = "--name" ] && name="\$2"; shift; done; : >"\$S/container-\$name" ;;
  rm) name="\${@: -1}"; rm -f "\$S/container-\$name" ;;
  logs) echo "database system is ready to accept connections"; [ -f "\$S/half-ready" ] || echo "database system is ready to accept connections" ;;
  exec)
    shift; [ "\$1" = "-i" ] && { inp=1; shift; }; name="\$1"; shift
    case "\$1" in
      pg_isready) [ -f "\$S/not-ready" ] && exit 1; exit 0 ;;
      sh) cat >"\$S/dump-\$name" ;;
      pg_restore) [ -f "\$S/restore-fail" ] && { echo "pg_restore: error: boom" >&2; exit 1; }
                  [ "\$(head -c 5 "\$S/dump-\$name")" = "PGDMP" ] || exit 1 ;;
      psql) sql="\${@: -1}"
            case "\$sql" in
              *information_schema*) cat "\$S/tables" 2>/dev/null || echo 12 ;;
              *dune.world_partition*) cat "\$S/rows-world" 2>/dev/null || echo 37 ;;
              *dune.players*) cat "\$S/rows-players" 2>/dev/null || echo 5 ;;
              *) echo 0 ;;
            esac ;;
    esac ;;
esac
EOF
  cat >"$T/bin/ssh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/ssh.calls"
exec bash -c "\${@: -1}"
EOF
  chmod +x "$T/bin/docker" "$T/bin/ssh"
}

make_proxmox_stubs() {
  cat >"$T/bin/qm" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/qm.calls"
F="$T/vmstate"; mkdir -p "\$F"
case "\$1" in
  status) if [ -f "\$F/scratch-exists" ]; then if [ -f "\$F/started" ]; then echo "status: running"; [ "\$3" = "--verbose" ] && { if [ -f "$T/low-read" ]; then echo "diskread: 4096"; else echo "diskread: 524288000"; fi; }; else echo "status: stopped"; fi; exit 0; fi; exit 2 ;;
  config) if [ -f "\$F/set-done" ]; then echo "net0: e1000e=AA:BB:CC:DD:EE:FF,bridge=vmbrdrill"; [ -f "$T/keep-extra" ] && cat "$T/vm.extra"
            [ -f "$T/nopin" ] || echo "numa0: cpus=0-3,hostnodes=1,memory=4096,policy=bind"
            [ -f "$T/noaff" ] || echo "affinity: 1,3,5,7"
            [ -f "$T/nounits" ] || echo "cpuunits: 10"
            [ -f "$T/nomem" ] || echo "memory: 4096"
          else echo "net0: e1000e=AA:BB:CC:DD:EE:FF,bridge=vmbr0,tag=20"; echo "numa0: cpus=0-39,hostnodes=0,memory=114688,policy=bind"; echo "affinity: 0-78"; [ -f "$T/vm.extra" ] && cat "$T/vm.extra"; fi; exit 0 ;;
  set) [ -f "$T/set-fail" ] && exit 1; : >"\$F/set-done"; exit 0 ;;
  start) [ -f "$T/start-fail" ] && exit 1; : >"\$F/started"
         if [ ! -f "$T/tap-silent" ]; then mkdir -p "$T/sysfs/tap990i0/statistics"; echo 40 >"$T/sysfs/tap990i0/statistics/rx_packets"; fi
         if [ -f "$T/stops-after-start" ]; then rm -f "\$F/started"; fi ;;
  agent) [ -f "\$F/started" ] && [ ! -f "$T/noagent" ] ;;
  guest) if [ -f "$T/check-fail" ]; then echo '{"exitcode":1}'; else echo '{"exitcode":0,"out-data":"ok"}'; fi ;;
  stop) rm -f "\$F/started" ;;
  destroy) rm -f "\$F/scratch-exists" "\$F/started"; echo destroyed >>"$T/destroyed" ;;
esac
EOF
  cat >"$T/bin/qmrestore" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/qmrestore.calls"
cat >"$T/restored.bin"
mkdir -p "$T/vmstate"; : >"$T/vmstate/scratch-exists"
EOF
  cat >"$T/bin/pct" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/pct.calls"
F="$T/vmstate"; mkdir -p "\$F"
case "\$1" in
  status) if [ -f "\$F/ct-exists" ]; then echo "status: running"; exit 0; fi; exit 1 ;;
  restore) cat >"$T/restored.bin"; : >"\$F/ct-exists" ;;
  config) if [ -f "\$F/set-done" ]; then echo "net0: name=eth0,bridge=vmbrdrill,ip=manual"; [ -f "$T/keep-extra" ] && cat "$T/vm.extra"
          else echo "net0: name=eth0,bridge=vmbr0"; [ -f "$T/vm.extra" ] && cat "$T/vm.extra"; fi; exit 0 ;;
  set) : >"\$F/set-done"; exit 0 ;;
  start|stop) exit 0 ;;
  exec) [ -f "$T/check-fail" ] && exit 1; exit 0 ;;
  destroy) rm -f "\$F/ct-exists"; echo destroyed >>"$T/destroyed" ;;
esac
EOF
  cat >"$T/bin/ip" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/ip.calls"
B="$T/vmstate/bridge"
case "\$1 \$2" in
  "link show") [ -f "\$B" ] ;;
  "link add") : >"\$B" ;;
  "link set") exit 0 ;;
  "link del") rm -f "\$B" ;;
esac
EOF
  cat >"$T/bin/lvs" <<EOF
#!/usr/bin/env bash
if [ -f "$T/poolvals" ]; then cat "$T/poolvals"; else echo "  1634.87 20.00"; fi
EOF
  chmod +x "$T/bin/qm" "$T/bin/qmrestore" "$T/bin/pct" "$T/bin/ip" "$T/bin/lvs"
}

# ---------- fixtures -----------------------------------------------------------------
# make_set [dumpmagic] [manifest_ok=1] [with_bgid=1]: a real daily set encrypted to the test recipient.
make_set() {
  local magic="${1:-PGDMP}" mok="${2:-1}" bgid="${3:-1}" b="$T/setbuild"
  rm -rf "$b"; mkdir -p "$b/prod/runtime/backups/db" "$b/host/etc/pve"
  # the real host config holds symlinks (Proxmox /etc/pve) and regular files
  ln -s nodes/local "$b/host/etc/pve/local"; echo hostconf >"$b/host/etc/hostname"
  { printf '%s' "$magic"; head -c 800 /dev/zero | tr '\0' 'x'; } >"$b/prod/runtime/backups/db/dump-1.backup"
  { [ "$bgid" = "1" ] && echo "battlegroup_id: sh-test"; echo "format: pg_dump_custom"; echo "backup_origin: automatic"; } >"$b/prod/runtime/backups/db/dump-1.backup.yaml"
  printf 'authoritative=runtime/backups/db/dump-1.backup\n' >"$b/prod/gate-manifest.txt"
  ( cd "$b" && find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 sha256sum >MANIFEST.sha256 )
  if [ "$mok" = "0" ]; then echo "$(printf 'f%.0s' {1..64})  ./prod/gate-manifest.txt" >"$b/MANIFEST.sha256"; fi
  tar -C "$b" -cf "$T/set.tar" .
  age -r "$BK_AGE_RECIPIENT" -o "$BK_SMB_MOUNT/daily/daily-20260930-051500.tar.age" "$T/set.tar"
}

make_image() { # name payload
  printf '%s' "${2:-FAKEDISKDATA}" | zstd -q | age -r "$BK_AGE_RECIPIENT" -o "$BK_SMB_MOUNT/vm/$1"
}

drill() { run bash "$SCRIPT" "$@"; }
alerts() { { grep -c "P1" "$T/curl.args" 2>/dev/null; } || true; }
ev() { grep -c "$1" "$BK_STATE_DIR/evidence.log" 2>/dev/null || true; }
ram_empty() { [ -z "$(ls -A "$BK_RAM_DIR")" ]; }

# =====================================================================================
# pipeline drill
# =====================================================================================

@test "pipeline: passes, leaves nothing on the share, OneDrive or in RAM, and records PASS" {
  drill pipeline
  [ "$status" -eq 0 ]
  [ "$(ev 'drill-pipeline.PASS')" = "1" ]
  [ -z "$(find "$BK_SMB_MOUNT/drill" -type f 2>/dev/null)" ]
  [ -z "$(find "$REMOTE_ROOT" -type f)" ]
  ram_empty
  grep -q DEADMANID "$T/curl.stdin"
}

@test "pipeline: needs no real key (the configured recipient is never used)" {
  sed -i 's#^BK_AGE_RECIPIENT=.*#BK_AGE_RECIPIENT=#' "$BK_CONFIG_DIR/backup.env"
  drill pipeline
  [ "$status" -eq 0 ]
}

@test "pipeline: an unmounted share fails with one P1 alert and records FAIL" {
  stub mountpoint 'exit 1'
  drill pipeline
  [ "$status" -eq 1 ]
  [ "$(alerts)" = "1" ]
  [ "$(ev 'drill-pipeline.FAIL')" = "1" ]
  ram_empty
}

@test "pipeline: an upload failure fails, alerts once, and cleans up" {
  touch "$T/upload-fail"
  cat >"$T/bin/rclone" <<EOF
#!/usr/bin/env bash
[ "\$1" = "copyto" ] && exit 1
exit 0
EOF
  drill pipeline
  [ "$status" -eq 1 ]
  [ "$(alerts)" = "1" ]
  grep -q "upload to OneDrive failed" "$T/curl.args"
  ram_empty
}

@test "pipeline: a corrupted OneDrive download is caught" {
  touch "$T/corrupt-download"
  drill pipeline
  [ "$status" -eq 1 ]
  grep -q "did not verify bit-exactly" "$T/curl.args"
}

@test "pipeline: fails if a truncated archive would be accepted" {
  cat >"$T/bin/age" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-d" ]; then
  set -- "\$@"; args=("\$@"); out=""; in=""; i=0
  while [ \$i -lt \${#args[@]} ]; do case "\${args[\$i]}" in -o) out="\${args[\$((i+1))]}"; i=\$((i+2)) ;; -i) i=\$((i+2)) ;; -d) i=\$((i+1)) ;; *) in="\${args[\$i]}"; i=\$((i+1)) ;; esac; done
  case "\$in" in *trunc.age) cp "$T/valid.tar" "\$out"; exit 0 ;; esac
fi
exec /usr/bin/age "\$@"
EOF
  chmod +x "$T/bin/age"
  mkdir -p "$T/v"; echo x >"$T/v/f"; tar -C "$T/v" -cf "$T/valid.tar" f
  drill pipeline
  [ "$status" -eq 1 ]
  grep -q "TRUNCATED archive was accepted" "$T/curl.args"
}

@test "pipeline: fails if a tampered archive would be accepted" {
  cat >"$T/bin/age" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-d" ]; then
  args=("\$@"); out=""; in=""; i=0
  while [ \$i -lt \${#args[@]} ]; do case "\${args[\$i]}" in -o) out="\${args[\$((i+1))]}"; i=\$((i+2)) ;; -i) i=\$((i+2)) ;; -d) i=\$((i+1)) ;; *) in="\${args[\$i]}"; i=\$((i+1)) ;; esac; done
  case "\$in" in *tamper.age) cp "$T/valid.tar" "\$out"; exit 0 ;; esac
fi
exec /usr/bin/age "\$@"
EOF
  chmod +x "$T/bin/age"
  mkdir -p "$T/v"; echo x >"$T/v/f"; tar -C "$T/v" -cf "$T/valid.tar" f
  drill pipeline
  [ "$status" -eq 1 ]
  grep -q "TAMPERED archive was accepted" "$T/curl.args"
}

@test "pipeline: fails if a wrong key would decrypt" {
  cat >"$T/bin/age" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-d" ]; then
  args=("\$@"); out=""; key=""; i=0
  while [ \$i -lt \${#args[@]} ]; do case "\${args[\$i]}" in -o) out="\${args[\$((i+1))]}"; i=\$((i+2)) ;; -i) key="\${args[\$((i+1))]}"; i=\$((i+2)) ;; *) i=\$((i+1)) ;; esac; done
  case "\$key" in *wrong.key) cp "$T/valid.tar" "\$out"; exit 0 ;; esac
fi
exec /usr/bin/age "\$@"
EOF
  chmod +x "$T/bin/age"
  mkdir -p "$T/v"; echo x >"$T/v/f"; tar -C "$T/v" -cf "$T/valid.tar" f
  drill pipeline
  [ "$status" -eq 1 ]
  grep -q "WRONG key decrypted" "$T/curl.args"
}

# =====================================================================================
# database drill
# =====================================================================================

@test "db: restores into a throwaway container, asserts counts, records PASS, removes the container and all decrypted material" {
  make_set
  drill db --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ]
  [ "$(ev 'drill-db.PASS')" = "1" ]
  [ -z "$(ls "$T/docker" | grep '^container-')" ]
  ram_empty
  grep -q "^rm -f bk-drill-" "$T/docker.calls"
  runline=$(grep '^run ' "$T/docker.calls")
  [[ "$runline" == *"--network none"* ]]
  [[ "$runline" == *"--tmpfs /var/lib/postgresql/data"* ]]
  [[ "$runline" == *"--memory 4g"* ]]
  [[ "$runline" == *"--label r740-backup-drill=1"* ]]
  [[ "$runline" == *"postgres:17"* ]]
  dumpfile="$(ls "$T"/docker/dump-bk-drill-*)"
  [ "$(head -c 5 "$dumpfile")" = "PGDMP" ]
}

@test "db: restore mirrors production: dune role and database first, then a plain pg_restore into dune" {
  make_set
  drill db --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ]
  c=$(grep -n 'create role dune' "$T/docker.calls" | head -1 | cut -d: -f1)
  r=$(grep -n 'pg_restore' "$T/docker.calls" | head -1 | cut -d: -f1)
  [ -n "$c" ]
  [ -n "$r" ]
  [ "$c" -lt "$r" ]
  grep -q 'create database dune owner dune' "$T/docker.calls"
  line=$(grep 'pg_restore' "$T/docker.calls" | head -1)
  [[ "$line" == *"-d dune"* ]]
  [[ "$line" != *"--create"* && "$line" != *"--exit-on-error"* ]]
}

@test "db: waits for the second ready message, so the init-server restart cannot break the restore" {
  make_set
  touch "$T/docker/half-ready"
  BK_DRILL_READY_TRIES=2 BK_DRILL_READY_SLEEP=0 drill db --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "did not become ready" "$T/curl.args"
  ! grep -q 'pg_restore' "$T/docker.calls"
}

@test "db: the throwaway container's tmpfs is size-bounded" {
  make_set
  BK_DRILL_TMPFS_SIZE=1g drill db --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ]
  [[ "$(grep '^run ' "$T/docker.calls")" == *"--tmpfs /var/lib/postgresql/data:rw,size=1g"* ]]
}

@test "db: restore errors are tolerated only up to BK_DRILL_MAX_RESTORE_ERRORS" {
  make_set
  touch "$T/docker/restore-fail"
  BK_DRILL_MAX_RESTORE_ERRORS=1 drill db --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ]
  rm -f "$T/curl.args"
  BK_DRILL_MAX_RESTORE_ERRORS=0 drill db --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "pg_restore FAILED with 1 error" "$T/curl.args"
}

@test "db: only ever removes containers it created (bk-drill-<epoch>-<n>)" {
  make_set
  drill db --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ]
  while read -r line; do
    case "$line" in "rm -f "*) [[ "${line#rm -f }" =~ ^bk-drill-[0-9]+-[0-9]+$ ]] ;; esac
  done <"$T/docker.calls"
}

@test "db: a wrong key fails before anything starts: P1 alert, FAIL evidence, no container, RAM clean" {
  make_set
  age-keygen -o "$T/other.key" 2>/dev/null
  drill db --identity "$T/other.key"
  [ "$status" -eq 1 ]
  [ "$(alerts)" = "1" ]
  [ "$(ev 'drill-db.FAIL')" = "1" ]
  [ ! -e "$T/docker.calls" ]
  ram_empty
}

@test "db: a damaged archive fails decryption" {
  make_set
  f="$BK_SMB_MOUNT/daily/daily-20260930-051500.tar.age"
  size="$(stat -c %s "$f")"
  printf '\xff' | dd of="$f" bs=1 seek=$((size - 20)) conv=notrunc 2>/dev/null
  drill db --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  [ ! -e "$T/docker.calls" ]
}

@test "db: a manifest that does not verify fails at integrity, before any container" {
  make_set PGDMP 0
  drill db --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "MANIFEST.sha256 does not verify" "$T/curl.args"
  [ ! -e "$T/docker.calls" ]
}

@test "db: a dump without a PGDMP header or without a battlegroup_id fails" {
  make_set JUNK!
  drill db --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "PGDMP" "$T/curl.args"
  rm -f "$T/curl.args"
  make_set PGDMP 1 0
  drill db --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "battlegroup_id" "$T/curl.args"
}

@test "db: pg_restore failure fails, alerts once, and STILL removes the container" {
  make_set
  touch "$T/docker/restore-fail"
  drill db --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  [ "$(alerts)" = "1" ]
  grep -q "pg_restore FAILED" "$T/curl.args"
  [ -z "$(ls "$T/docker" | grep '^container-')" ]
  ram_empty
}

@test "db: a container that cannot start fails cleanly" {
  make_set
  touch "$T/docker/run-fail"
  drill db --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  ram_empty
}

@test "db: a database that never becomes ready fails and the container is removed" {
  make_set
  touch "$T/docker/not-ready"
  { echo 'BK_DRILL_READY_TRIES=2'; echo 'BK_DRILL_READY_SLEEP=0'; } >>"$BK_CONFIG_DIR/backup.env"
  drill db --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "did not become ready" "$T/curl.args"
  [ -z "$(ls "$T/docker" | grep '^container-')" ]
  ram_empty
}

@test "db: too few tables fails the assertion" {
  make_set
  echo 1 >"$T/docker/tables"
  drill db --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "only 1 tables restored" "$T/curl.args"
  [ -z "$(ls "$T/docker" | grep '^container-')" ]
}

@test "db: a table below its row minimum fails, naming the table" {
  make_set
  echo 1 >"$T/docker/rows-world"
  drill db --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "dune.world_partition has 1 rows (expected at least 2)" "$T/curl.args"
}

@test "db: a non-numeric count fails instead of passing" {
  make_set
  echo "ERROR" >"$T/docker/tables"
  drill db --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
}

@test "db: with no row-count assertions configured the drill refuses (it would prove nothing)" {
  make_set
  sed -i '/BK_DRILL_ROW_CHECKS/d' "$BK_CONFIG_DIR/backup.env"
  drill db --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "asserts nothing" "$T/curl.args"
  [ ! -e "$T/docker.calls" ]
}

@test "db: an invalid table name in the row checks is rejected, never sent to the remote shell" {
  make_set
  sed -i 's#^BK_DRILL_ROW_CHECKS=.*#BK_DRILL_ROW_CHECKS="dune.x;touch:1"#' "$BK_CONFIG_DIR/backup.env"
  drill db --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "invalid table" "$T/curl.args"
}

@test "db: a missing image setting fails clearly" {
  make_set
  sed -i '/BK_DRILL_PG_IMAGE/d' "$BK_CONFIG_DIR/backup.env"
  drill db --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "BK_DRILL_PG_IMAGE" "$T/curl.args"
}

@test "db: --dry-run verifies the archive in RAM, prints the plan, starts nothing, records nothing" {
  make_set
  drill db --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN OK"* ]]
  [ ! -e "$T/docker.calls" ]
  [ ! -e "$BK_STATE_DIR/evidence.log" ]
  ram_empty
}

@test "db: without --identity the drill refuses" {
  make_set
  drill db
  [ "$status" -eq 1 ]
  [ ! -e "$T/docker.calls" ]
}

@test "db: an --archive with path components is rejected" {
  make_set
  drill db --identity "$BK_AGE_IDENTITY" --archive "../../etc/passwd"
  [ "$status" -eq 1 ]
  [ ! -e "$T/docker.calls" ]
}

@test "db: the private key is used but never stored anywhere but where it was" {
  make_set
  drill db --identity "$BK_AGE_IDENTITY"
  hits="$(grep -rl 'AGE-SECRET-KEY' "$T" 2>/dev/null | sort)"
  [ "$hits" = "$BK_AGE_IDENTITY" ]
}

@test "db: an overlapping db drill is refused" {
  make_set
  ( flock -x 9; sleep 3 ) 9>"$BK_STATE_DIR/drill-db.lock" &
  holder=$!
  sleep 1
  drill db --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  [ ! -e "$T/docker.calls" ]
  wait "$holder"
}

# =====================================================================================
# VM / CT drill
# =====================================================================================

@test "vm: a nearly full thin pool stops the drill before anything is restored or created" {
  make_image vm102-20260930-020000.vma.zst.age FAKEDISKDATA
  echo "  1634.87 91.00" >"$T/poolvals"
  drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "nearly full thin pool" "$T/curl.args"
  [ ! -e "$T/qmrestore.calls" ]
  [ ! -e "$T/vmstate/bridge" ]
}

@test "vm: every extra NIC is deleted and the drill refuses to boot if any NIC is still off the drill bridge" {
  make_image vm102-20260930-020000.vma.zst.age FAKEDISKDATA
  printf 'net1: virtio=11:22:33:44:55:66,bridge=vmbr1\nnet2: virtio=11:22:33:44:55:77,bridge=vmbr2\n' >"$T/vm.extra"
  drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ]
  [[ "$(grep '^set 990' "$T/qm.calls")" == *"--delete numa1,net1,net2"* ]]
  rm -f "$T/qm.calls" "$T/curl.args" "$T/vmstate/set-done"
  touch "$T/keep-extra"
  drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "outside vmbrdrill" "$T/curl.args"
  ! grep -q '^start 990' "$T/qm.calls"
  [ ! -e "$T/vmstate/scratch-exists" ]
}

@test "vm: a restored config with host-bound devices is refused before boot" {
  make_image vm102-20260930-020000.vma.zst.age FAKEDISKDATA
  printf 'hostpci0: 0000:01:00.0\n' >"$T/vm.extra"
  drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "host-bound devices" "$T/curl.args"
  ! grep -q '^start 990' "$T/qm.calls"
  [ ! -e "$T/vmstate/scratch-exists" ]
}

@test "vm: restores to the scratch id, caps and isolates BEFORE boot, checks in-guest, records PASS, destroys everything" {
  make_image vm102-20260930-020000.vma.zst.age FAKEDISKDATA
  drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ]
  [ "$(cat "$T/restored.bin")" = "FAKEDISKDATA" ]
  grep -q "^- 990 --storage local-lvm --unique 1 --bwlimit 40960" "$T/qmrestore.calls"
  setline="$(grep '^set 990' "$T/qm.calls")"
  [[ "$setline" == *"--onboot 0"* ]]
  [[ "$setline" == *"--memory 4096"* ]]
  [[ "$setline" == *"--balloon 0"* ]]
  [[ "$setline" == *"--cores 4"* ]]
  [[ "$setline" == *"--sockets 1 --numa 1 --numa0 cpus=0-3,hostnodes=1,memory=4096,policy=bind"* ]]
  [[ "$setline" == *"--affinity 1,3,5,7 --cpuunits 10"* ]]
  [[ "$setline" == *"--delete numa1"* ]]
  [[ "$setline" == *"--net0 e1000e,bridge=vmbrdrill"* ]]
  # the cap/isolate call happens before the first start
  setn="$(grep -n '^set 990' "$T/qm.calls" | head -1 | cut -d: -f1)"
  startn="$(grep -n '^start 990' "$T/qm.calls" | head -1 | cut -d: -f1)"
  [ "$setn" -lt "$startn" ]
  [ "$(ev 'drill-vm.PASS')" = "1" ]
  [ ! -e "$T/vmstate/scratch-exists" ]
  [ ! -e "$T/vmstate/bridge" ]
  grep -q "link del vmbrdrill" "$T/ip.calls"
  ram_empty
}

@test "vm: the transient bridge has no ports (created bare, nothing attached)" {
  make_image vm102-20260930-020000.vma.zst.age
  drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ]
  grep -q "link add name vmbrdrill type bridge" "$T/ip.calls"
  run grep -E "master|vmbr0|enp|eno" "$T/ip.calls"
  [ "$status" -ne 0 ]
}

@test "vm: a wrong key fails at restore and STILL destroys the scratch guest and the bridge" {
  make_image vm102-20260930-020000.vma.zst.age
  age-keygen -o "$T/other.key" 2>/dev/null
  drill vm --guest 102 --identity "$T/other.key"
  [ "$status" -eq 1 ]
  [ "$(alerts)" = "1" ]
  [ ! -e "$T/vmstate/scratch-exists" ]
  [ ! -e "$T/vmstate/bridge" ]
  ram_empty
}

@test "vm: a guest that never comes up fails and is destroyed" {
  make_image vm102-20260930-020000.vma.zst.age
  touch "$T/noagent"
  drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "did not come up" "$T/curl.args"
  [ ! -e "$T/vmstate/scratch-exists" ]
  [ ! -e "$T/vmstate/bridge" ]
}

@test "vm: a failing in-guest check fails the drill and destroys the guest" {
  make_image vm102-20260930-020000.vma.zst.age
  touch "$T/check-fail"
  drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "in-guest check FAILED" "$T/curl.args"
  [ ! -e "$T/vmstate/scratch-exists" ]
  [ "$(ev 'drill-vm.FAIL')" = "1" ]
}

@test "vm: if isolation cannot be applied the guest is never started, and is destroyed" {
  make_image vm102-20260930-020000.vma.zst.age
  touch "$T/set-fail"
  drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  run grep '^start' "$T/qm.calls"
  [ "$status" -ne 0 ]
  [ ! -e "$T/vmstate/scratch-exists" ]
}

@test "vm: refuses when the scratch id already exists, touching nothing" {
  make_image vm102-20260930-020000.vma.zst.age
  mkdir -p "$T/vmstate"; : >"$T/vmstate/scratch-exists"
  drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "already exists" "$T/curl.args"
  [ ! -e "$T/qmrestore.calls" ]
  [ ! -e "$T/destroyed" ]
  [ -e "$T/vmstate/scratch-exists" ]
}

@test "vm: refuses a scratch id that is a production id or out of range" {
  make_image vm102-20260930-020000.vma.zst.age
  echo 'BK_SCRATCH_VMID=102' >>"$BK_CONFIG_DIR/backup.env"
  drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  [ ! -e "$T/qmrestore.calls" ]
  echo 'BK_SCRATCH_VMID=200' >>"$BK_CONFIG_DIR/backup.env"
  drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  [ ! -e "$T/qmrestore.calls" ]
}

@test "vm: refuses an existing bridge and does NOT delete it" {
  make_image vm102-20260930-020000.vma.zst.age
  mkdir -p "$T/vmstate"; : >"$T/vmstate/bridge"
  drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  [ -e "$T/vmstate/bridge" ]
  run grep "link del" "$T/ip.calls"
  [ "$status" -ne 0 ]
  [ ! -e "$T/qmrestore.calls" ]
}

@test "vm: refuses guests not in BK_VMIDS, invalid ids, and guests with no in-guest check configured" {
  make_image vm102-20260930-020000.vma.zst.age
  make_image vm103-20260930-020000.vma.zst.age
  drill vm --guest 999 --identity "$BK_AGE_IDENTITY"; [ "$status" -eq 1 ]
  drill vm --guest "102;id" --identity "$BK_AGE_IDENTITY"; [ "$status" -eq 1 ]
  drill vm --guest 103 --identity "$BK_AGE_IDENTITY"; [ "$status" -eq 1 ]
  grep -q "no in-guest check configured" "$T/curl.args"
  [ ! -e "$T/qmrestore.calls" ]
}

@test "vm: without an image or without --identity it refuses" {
  drill vm --guest 102 --identity "$BK_AGE_IDENTITY"; [ "$status" -eq 1 ]
  make_image vm102-20260930-020000.vma.zst.age
  drill vm --guest 102; [ "$status" -eq 1 ]
  [ ! -e "$T/qmrestore.calls" ]
}

@test "vm: --dry-run prints the plan and starts nothing" {
  make_image vm102-20260930-020000.vma.zst.age
  drill vm --guest 102 --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN OK"* ]]
  [ ! -e "$T/qmrestore.calls" ]
  [ ! -e "$T/ip.calls" ]
  [ ! -e "$BK_STATE_DIR/evidence.log" ]
}

@test "vm: a container image is restored with pct, isolated with no address, and destroyed" {
  make_image ct104-20260930-020000.tar.zst.age CTDATA
  drill vm --guest 104 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ]
  grep -q "^restore 990 - --storage local-lvm --unique 1" "$T/pct.calls"
  grep -q "^set 990 --onboot 0 --memory 4096 --cores 4 --net0 name=eth0,bridge=vmbrdrill,ip=manual" "$T/pct.calls"
  [ ! -e "$T/vmstate/ct-exists" ]
  [ ! -e "$T/vmstate/bridge" ]
}

@test "vm: the private key is used but never stored elsewhere" {
  make_image vm102-20260930-020000.vma.zst.age
  drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
  hits="$(grep -rl 'AGE-SECRET-KEY' "$T" 2>/dev/null | sort)"
  [ "$hits" = "$BK_AGE_IDENTITY" ]
}

@test "unknown subcommands and missing arguments exit 2" {
  drill bogus; [ "$status" -eq 2 ]
  drill; [ "$status" -eq 2 ]
  drill db --nonsense; [ "$status" -eq 2 ]
}

# ---- tests that isolate one safeguard each (found by mutation testing) ----------------

@test "vm: a scratch id that is in the production list is refused even inside the scratch range" {
  make_image vm102-20260930-020000.vma.zst.age
  sed -i 's#^BK_VMIDS=.*#BK_VMIDS="101 102 103 104 950"#' "$BK_CONFIG_DIR/backup.env"
  echo 'BK_SCRATCH_VMID=950' >>"$BK_CONFIG_DIR/backup.env"
  drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "is a production id" "$T/curl.args"
  [ ! -e "$T/qmrestore.calls" ]
}

@test "db: an --archive that escapes the daily directory is refused even if the file exists" {
  make_set
  cp "$BK_SMB_MOUNT/daily/daily-20260930-051500.tar.age" "$BK_SMB_MOUNT/evil.tar.age"
  drill db --identity "$BK_AGE_IDENTITY" --archive "../evil.tar.age"
  [ "$status" -eq 1 ]
  grep -q "no valid daily archive selected" "$T/curl.args"
  [ ! -e "$T/docker.calls" ]
}

@test "vm: a guest that has an image and a check but is not in BK_VMIDS is refused" {
  make_image vm105-20260930-020000.vma.zst.age
  echo 'BK_DRILL_VM_CHECK_105="true"' >>"$BK_CONFIG_DIR/backup.env"
  drill vm --guest 105 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "is not in BK_VMIDS" "$T/curl.args"
  [ ! -e "$T/qmrestore.calls" ]
}

@test "pipeline: with no OneDrive it round-trips through the share alone, never calls rclone, and cleans up" {
  sed -i '/^BK_RCLONE_REMOTE=/d' "$BK_CONFIG_DIR/backup.env"
  drill pipeline
  [ "$status" -eq 0 ]
  [ "$(ev 'drill-pipeline.PASS')" = "1" ]
  [ ! -e "$T/rclone.calls" ]
  [ -z "$(find "$BK_SMB_MOUNT/drill" -type f 2>/dev/null)" ]
  ram_empty
}


@test "db: a host-config symlink in the set is fine (only prod/ is extracted), a link inside prod/ is refused" {
  make_set
  drill db --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 0 ]
  b="$T/setbuild"; ln -s /etc "$b/prod/evil-link"
  tar -C "$b" -cf "$T/set.tar" .
  age -r "$BK_AGE_RECIPIENT" -o "$BK_SMB_MOUNT/daily/daily-20260930-051500.tar.age" "$T/set.tar"
  rm -f "$T/curl.args"
  drill db --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 1 ]
  grep -q "non-regular member" "$T/curl.args"
}


# ---- abort handling ------------------------------------------------------------------------------

hang_container_start() {
  cat >"$T/bin/ssh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/ssh.calls"
case "\${@: -1}" in *"docker run"*) exec sleep 319 ;; esac
exec bash -c "\${@: -1}"
EOF
  chmod +x "$T/bin/ssh"
}
teardown() { pkill -KILL -fx "sleep 319" 2>/dev/null || true; }

@test "abort while the throwaway container is starting: children stopped, container removed, RAM wiped" {
  make_set
  hang_container_start
  run run_with_signal INT 319 "$SCRIPT" db --identity "$BK_AGE_IDENTITY"
  [[ "$output" == *"rc=130 leftover=0"* ]] || { printf '%s\n' "$output" >&3; false; }
  grep -q "^rm -f bk-drill-" "$T/docker.calls"
  [ -z "$(ls "$T/docker" | grep '^container-')" ]
  ram_empty
}

@test "kill (SIGTERM) during the same stage cleans up the same way" {
  make_set
  hang_container_start
  run run_with_signal TERM 319 "$SCRIPT" db --identity "$BK_AGE_IDENTITY"
  [[ "$output" == *"rc=143 leftover=0"* ]] || { printf '%s\n' "$output" >&3; false; }
  grep -q "^rm -f bk-drill-" "$T/docker.calls"
  ram_empty
}


# ---- boot-only mode (guests with no guest agent) ----------------------------------------------------

boot_only_cfg() { echo 'BK_DRILL_VM_CHECK_102=boot-only' >>"$BK_CONFIG_DIR/backup.env"; touch "$T/noagent"; }

@test "vm boot-only: a guest with no agent passes when it runs and sends packets; evidence says boot-only; no in-guest command runs" {
  make_image vm102-20260930-020000.vma.zst.age FAKEDISKDATA
  boot_only_cfg
  drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ]
  [ "$(ev 'drill-vm.PASS')" = "1" ]
  grep -q 'mode=boot-only' "$BK_STATE_DIR/evidence.log"
  [[ "$output" == *"boot-only check"* ]]
  ! grep -q '^guest ' "$T/qm.calls"
  [ ! -e "$T/vmstate/scratch-exists" ]
  [ ! -e "$T/vmstate/bridge" ]
}

@test "vm boot-only: a silent image (no packets) fails, alerts once, and everything is destroyed" {
  make_image vm102-20260930-020000.vma.zst.age FAKEDISKDATA
  boot_only_cfg
  touch "$T/tap-silent"
  BK_DRILL_BOOT_TRIES=3 BK_DRILL_BOOT_SLEEP=0 drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  [ "$(alerts)" = "1" ]
  grep -q "did not show signs of life" "$T/curl.args"
  [ "$(ev 'drill-vm.FAIL')" = "1" ]
  [ ! -e "$T/vmstate/scratch-exists" ]
  [ ! -e "$T/vmstate/bridge" ]
}

@test "vm boot-only: packets alone are not enough, the VM must still be running" {
  make_image vm102-20260930-020000.vma.zst.age FAKEDISKDATA
  boot_only_cfg
  touch "$T/stops-after-start"
  BK_DRILL_BOOT_TRIES=3 BK_DRILL_BOOT_SLEEP=0 drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "did not show signs of life" "$T/curl.args"
}

@test "vm boot-only: the packet threshold is configurable" {
  make_image vm102-20260930-020000.vma.zst.age FAKEDISKDATA
  boot_only_cfg
  BK_DRILL_MIN_PACKETS=1000 BK_DRILL_BOOT_TRIES=2 BK_DRILL_BOOT_SLEEP=0 drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
}

@test "vm: an unset check is still refused, and the message names boot-only" {
  make_image vm102-20260930-020000.vma.zst.age FAKEDISKDATA
  sed -i '/^BK_DRILL_VM_CHECK_102=/d' "$BK_CONFIG_DIR/backup.env"
  drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "boot-only" "$T/curl.args"
}


@test "vm: virtual devices (serial0: socket, usb0: spice) are fine, host passthrough (a /dev serial port, a host USB device) is refused" {
  make_image vm102-20260930-020000.vma.zst.age FAKEDISKDATA
  boot_only_cfg
  printf 'serial0: socket\nusb0: spice\nvga: serial0\n' >"$T/vm.extra"
  drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ]
  for bad in 'serial0: /dev/ttyS0' 'usb0: host=1234:5678' 'usb1: mapping=mydevice' 'parallel0: /dev/parport0' 'hostpci0: 0000:01:00.0'; do
    rm -f "$T/curl.args" "$T/qm.calls" "$T/vmstate/set-done"
    printf '%s\n' "$bad" >"$T/vm.extra"
    drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
    [ "$status" -eq 1 ]
    grep -q "host-bound devices" "$T/curl.args"
    ! grep -q '^start 990' "$T/qm.calls"
  done
}


@test "vm boot-only: packets without real disk reads (a failed disk boot falling back to network boot) is NOT a pass" {
  make_image vm102-20260930-020000.vma.zst.age FAKEDISKDATA
  boot_only_cfg
  touch "$T/low-read"
  BK_DRILL_BOOT_TRIES=3 BK_DRILL_BOOT_SLEEP=0 drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "read 0 MiB from its disk" "$T/curl.args"
  [ "$(ev 'drill-vm.FAIL')" = "1" ]
  [ ! -e "$T/vmstate/scratch-exists" ]
}

@test "vm boot-only: a successful boot reports both the packets and the disk read in its log" {
  make_image vm102-20260930-020000.vma.zst.age FAKEDISKDATA
  boot_only_cfg
  drill vm --guest 102 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sent 40 packets"*"read 500 MiB from its disk"* ]]
}

# =====================================================================================
# VM drill guardrails: the drill must not hurt the live host or dune-prod
# =====================================================================================

vm_ok_image() { make_image vm101-20261001-120000.vma.zst.age FAKEDISKDATA; echo 'BK_DRILL_VM_CHECK_101=boot-only' >>"$BK_CONFIG_DIR/backup.env"; }
no_scratch_made() { [ ! -e "$T/qmrestore.calls" ] && [ ! -e "$T/vmstate/bridge" ] && [ ! -e "$T/vmstate/scratch-exists" ]; }

guard_on_stubs() {
  export BK_PSI_DIR="$T/psi"; mkdir -p "$BK_PSI_DIR"
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' >"$BK_PSI_DIR/io"
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' >"$BK_PSI_DIR/memory"
  stub iostat 'echo "Device r/s rMB/s rrqm/s %rrqm r_await rareq-sz w/s wMB/s wrqm/s %wrqm w_await wareq-sz d/s dMB/s drqm/s %drqm d_await dareq-sz f/s f_await aqu-sz %util"
for i in 1 2; do echo "sda 100.0 50.0 0 0 3.0 128 20.0 2.0 0 0 0.5 100 0 0 0 0 0 0 0 0 0 12.0"; done'
  stub lvs 'case "$*" in *lv_size*) echo "  1634.87 20.00" ;; *) echo "  17.7" ;; esac'
  cat >"$T/bin/ssh" <<EOS
#!/usr/bin/env bash
echo "\$*" >>"$T/ssh.calls"
case "\${@: -1}" in
  *"dune status"*)
    n=\$(( \$(cat "$T/status.n" 2>/dev/null || echo 0) + 1 )); echo "\$n" >"$T/status.n"
    lim="\$(cat "$T/degrade-after" 2>/dev/null || echo 99999)"
    if [ "\$n" -gt "\$lim" ]; then echo "Overall:     DEGRADED"; else echo "Overall:     READY"; fi ;;
  *) exit 0 ;;
esac
EOS
  chmod +x "$T/bin/ssh"
  sed -i 's/^BK_DRILL_GUARD=0/BK_DRILL_GUARD=1/' "$BK_CONFIG_DIR/backup.env"
  { echo 'BK_BACKUP_SSH=dune@prod.test'; echo 'BK_GUARD_INTERVAL_S=1'; echo 'BK_GUARD_CONSECUTIVE=2'; echo 'BK_KILL_GRACE_S=2'; } >>"$BK_CONFIG_DIR/backup.env"
}

@test "vm guardrail: inside the blackout (the 04:30 dump and 05:00 restart) the drill refuses and creates nothing" {
  vm_ok_image
  BK_DRILL_NOW_MIN=290 drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "blackout 04:20-05:20" "$T/curl.args"
  no_scratch_made
}

@test "vm guardrail: the blackout edges, and a custom blackout that wraps midnight" {
  vm_ok_image
  BK_DRILL_NOW_MIN=259 drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 0 ]
  BK_DRILL_NOW_MIN=260 drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 1 ]
  BK_DRILL_NOW_MIN=320 drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 0 ]
  BK_DRILL_BLACKOUT=23:00-02:00 BK_DRILL_NOW_MIN=60 drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 1 ]
  BK_DRILL_BLACKOUT=nonsense drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 1 ]
  grep -q "BK_DRILL_BLACKOUT must look like" "$T/curl.args"
}

@test "vm guardrail: a running weekly or daily backup stops the drill from competing with it" {
  vm_ok_image
  mkdir -p "$BK_STATE_DIR"
  ( exec 7>"$BK_STATE_DIR/backup-weekly.lock"; flock -n 7; sleep 30 ) &
  holder=$!
  sleep 1
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  kill "$holder" 2>/dev/null || true
  [ "$status" -eq 1 ]
  grep -q "backup-weekly backup is running" "$T/curl.args"
  no_scratch_made
}

@test "vm guardrail: too little host memory, or too little on the pinned NUMA node, refuses before anything is created" {
  vm_ok_image
  printf 'MemAvailable: 20000000 kB\n' >"$T/meminfo"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "of host memory is available" "$T/curl.args"
  no_scratch_made
  printf 'MemAvailable: 141000000 kB\n' >"$T/meminfo"
  printf 'Node 1 MemFree: 9000000 kB\n' >"$T/node/node1/meminfo"
  rm -f "$T/curl.args"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "NUMA node 1 has only" "$T/curl.args"
  no_scratch_made
}

@test "vm guardrail: an unlimited or absurd restore rate, a bad affinity or weight, a bad timeout are refused" {
  vm_ok_image
  for v in "BK_DRILL_BWLIMIT_KIB=0" "BK_DRILL_BWLIMIT_KIB=fast" "BK_DRILL_AFFINITY=1;reboot" "BK_DRILL_CPUUNITS=0" "BK_DRILL_NUMA_NODE=x" "BK_DRILL_RESTORE_TIMEOUT_MIN=abc"; do
    rm -f "$T/curl.args"
    env "$v" bash "$SCRIPT" vm --guest 101 --identity "$BK_AGE_IDENTITY" >/dev/null 2>&1 && return 1
    grep -q "P1" "$T/curl.args"
    no_scratch_made || { echo "created something for $v" >&3; return 1; }
  done
}

@test "vm guardrail: the pin, affinity, weight and memory cap must really be in the config or the guest is never started" {
  vm_ok_image
  for f in nopin noaff nounits nomem; do
    rm -f "$T/qm.calls" "$T/curl.args" "$T/vmstate/set-done" "$T/nopin" "$T/noaff" "$T/nounits" "$T/nomem"
    : >"$T/$f"
    drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
    [ "$status" -eq 1 ] || { echo "$f: status $status" >&3; return 1; }
    grep -q "refusing to boot" "$T/curl.args" || { echo "$f: no refusal" >&3; return 1; }
    ! grep -q '^start 990' "$T/qm.calls"
    [ ! -e "$T/vmstate/scratch-exists" ]
    [ ! -e "$T/vmstate/bridge" ]
  done
}

@test "vm guardrail: the restore is rate-limited, time-limited, and the guest is pinned (memory to one node, CPUs to few threads, lowest weight)" {
  vm_ok_image
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ]
  grep -q -- "--bwlimit 40960" "$T/qmrestore.calls"
  setline="$(grep '^set 990' "$T/qm.calls")"
  [[ "$setline" == *"--numa0 cpus=0-3,hostnodes=1,memory=4096,policy=bind"* ]]
  [[ "$setline" == *"--affinity 1,3,5,7"* ]]
  [[ "$setline" == *"--cpuunits 10"* ]]
}

@test "vm guardrail: the drill only ever touches its scratch id, never the guest it copies or any other production guest" {
  vm_ok_image
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ]
  ! grep -Eq '^(set|start|stop|shutdown|reset|destroy|migrate|snapshot|rollback|resize|move|clone|template|suspend|resume) +(10[0-9]|1[0-9]{2}) ' "$T/qm.calls"
  ! grep -Eq '^(set|start|stop|destroy) +(10[0-9]) ' "$T/pct.calls" 2>/dev/null
  ! grep -Eq '^(101|102|103|104) ' "$T/qmrestore.calls"
  grep -Eq '^- 990 ' "$T/qmrestore.calls"
}

@test "vm guardrail: --dry-run runs the preflight, prints a forecast, and creates nothing" {
  vm_ok_image
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"PREFLIGHT OK"* ]]
  [[ "$output" == *"writes capped at 40960KiB/s"* ]]
  [[ "$output" == *"NUMA node 1"* ]]
  [[ "$output" == *"CPU affinity 1,3,5,7"* ]]
  [[ "$output" == *"Nothing is ever written to guest 101"* ]]
  no_scratch_made
}

@test "vm guard: a game that is not READY stops the drill at the pre-check, before anything is created" {
  vm_ok_image
  guard_on_stubs
  echo 0 >"$T/degrade-after"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "the safety guard sees a problem" "$T/curl.args"
  grep -q "not READY" "$T/curl.args"
  no_scratch_made
}

@test "vm guard: high host memory pressure stops the drill at the pre-check" {
  vm_ok_image
  guard_on_stubs
  printf 'some avg10=40.00 avg60=0.00 avg300=0.00 total=1\n' >"$BK_PSI_DIR/memory"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "memory pressure" "$T/curl.args"
  no_scratch_made
}

@test "vm guard: a healthy host lets the drill finish with the guard watching the whole run" {
  vm_ok_image
  guard_on_stubs
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ] || { echo "$output" >&3; false; }
  [[ "$output" == *"guard: watching PID"* ]]
  [ ! -e "$T/vmstate/scratch-exists" ]
  [ ! -e "$T/vmstate/bridge" ]
}

@test "vm guard: a problem that appears DURING the restore stops it, destroys the scratch guest and the bridge, and says why" {
  vm_ok_image
  guard_on_stubs
  echo 1 >"$T/degrade-after"      # the pre-check (call 1) passes; every later sample fails
  cat >"$T/bin/qmrestore" <<EOS
#!/usr/bin/env bash
echo "\$*" >>"$T/qmrestore.calls"
cat >"$T/restored.bin"
mkdir -p "$T/vmstate"; : >"$T/vmstate/scratch-exists"
exec sleep 331
EOS
  chmod +x "$T/bin/qmrestore"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -ne 0 ]
  ! pgrep -fx 'sleep 331' >/dev/null
  grep -q "stopped by the safety guard" "$T/curl.args"
  [ ! -e "$T/vmstate/scratch-exists" ]
  [ ! -e "$T/vmstate/bridge" ]
  grep -q "link del vmbrdrill" "$T/ip.calls"
  ! grep -q '^start 990' "$T/qm.calls"
  ram_empty
}
