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
BK_BACKUP_SSH=dune@prod.test
BK_DRILL_DESTROY_RETRY_S=0
BK_KILL_GRACE_S=2
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
  # never write a stub outside the test sandbox: an empty $T once put test stubs into the host's /usr/bin
  [ -n "${BATS_TEST_TMPDIR:-}" ] && [ -n "${T:-}" ] && [ "${T#"$BATS_TEST_TMPDIR"}" != "$T" ] && [ -d "$T/bin" ] || { echo "refusing to write stubs: T=[${T:-}] is not inside BATS_TEST_TMPDIR" >&2; return 1; }
  cat >"$T/bin/qm" <<'EOF'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "$*" >>"$T/qm.calls"
F="$T/vmstate"; mkdir -p "$F"
src_config() {
  echo "net0: e1000e=AA:BB:CC:DD:EE:FF,bridge=vmbr0,tag=20"
  echo "numa: 1"
  echo "numa0: cpus=0-39,hostnodes=0,memory=114688,policy=bind"
  echo "numa1: cpus=40-59,hostnodes=1,memory=81920,policy=bind"
  echo "affinity: 0-78"
  echo "scsi0: local-lvm:vm-990-disk-0,size=300G,discard=on"
  echo "onboot: 1"
  [ -f "$T/vm.extra" ] && cat "$T/vm.extra"
  return 0
}
drop() { grep -v "^$1: " "$F/out" >"$F/o2" || true; mv "$F/o2" "$F/out"; }
case "$1" in
  status) if [ -f "$F/scratch-exists" ]; then if [ -f "$F/started" ]; then echo "status: running"; [ "$3" = "--verbose" ] && { if [ -f "$T/low-read" ]; then echo "diskread: 4096"; else echo "diskread: 524288000"; fi; }; else echo "status: stopped"; fi; exit 0; fi; exit 2 ;;
  config) if [ -f "$F/set-done" ]; then
            cp "$F/cfg" "$F/out"
            [ -f "$T/nopin" ] && drop numa0
            [ -f "$T/noaff" ] && drop affinity
            [ -f "$T/nounits" ] && drop cpuunits
            [ -f "$T/nomem" ] && drop memory
            if [ -f "$T/post-override" ]; then
              while IFS= read -r l; do drop "${l%%:*}"; echo "$l" >>"$F/out"; done <"$T/post-override"
            fi
            cat "$F/out"
          else src_config; fi; exit 0 ;;
  set) [ -f "$T/set-fail" ] && exit 1
       if [ ! -f "$F/set-done" ]; then src_config >"$F/cfg"; : >"$F/set-done"; fi
       shift 2
       while [ $# -gt 0 ]; do
         case "$1" in
           --delete) IFS=, read -ra ks <<<"$2"
                     for k in "${ks[@]}"; do
                       if [ -f "$T/keep-extra" ]; then case "$k" in net*) continue ;; esac; fi
                       grep -v "^$k: " "$F/cfg" >"$F/cfg.n" || true; mv "$F/cfg.n" "$F/cfg"
                     done; shift 2 ;;
           --*) k="${1#--}"; grep -v "^$k: " "$F/cfg" >"$F/cfg.n" || true; mv "$F/cfg.n" "$F/cfg"; echo "$k: $2" >>"$F/cfg"; shift 2 ;;
           *) shift ;;
         esac
       done
       exit 0 ;;
  start) [ -f "$T/start-fail" ] && exit 1; : >"$F/started"
         if [ ! -f "$T/tap-silent" ]; then mkdir -p "$T/sysfs/tap990i0/statistics"; echo 40 >"$T/sysfs/tap990i0/statistics/rx_packets"; fi
         if [ -f "$T/stops-after-start" ]; then rm -f "$F/started"; fi ;;
  agent) [ -f "$F/started" ] && [ ! -f "$T/noagent" ] ;;
  guest) if [ -f "$T/check-fail" ]; then echo '{"exitcode":1}'; else echo '{"exitcode":0,"out-data":"ok"}'; fi ;;
  stop) rm -f "$F/started" ;;
  destroy) [ -f "$T/destroy-fails" ] && exit 1
           rm -f "$F/scratch-exists" "$F/started"; echo destroyed >>"$T/destroyed" ;;
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
          else echo "net0: name=eth0,bridge=vmbr0"; echo "rootfs: local-lvm:vm-990-disk-0,size=12G"; [ -f "$T/vm.extra" ] && cat "$T/vm.extra"; [ -f "$T/ct.extra" ] && cat "$T/ct.extra"; fi; exit 0 ;;
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
  cat >"$T/bin/lvs" <<'EOF'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
case "$*" in
  *lv_name*) cat "$T/lvnames" 2>/dev/null || true ;;
  *) if [ -f "$T/poolvals" ]; then cat "$T/poolvals"; else echo "  1634.87 20.00"; fi ;;
esac
EOF
  cat >"$T/bin/lvremove" <<'EOF'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "$*" >>"$T/lvremove.calls"
name="${@: -1}"; name="${name#*/}"
grep -v "^ *$name\$" "$T/lvnames" >"$T/lvnames.n" 2>/dev/null || true; mv "$T/lvnames.n" "$T/lvnames" 2>/dev/null || true
EOF
  cat >"$T/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$BATS_TEST_TMPDIR/systemd-run.calls"
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
exec "$@"
EOF
  cat >"$T/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "$*" >>"$T/sysctl.calls"
case "$1" in
  -n) [ -f "$T/dirty-unreadable" ] && exit 1; if [ -f "$T/dirty-zero" ]; then printf '%s\n' 0 0; else printf '%s\n' 20 10; fi ;;
  -q) [ -f "$T/sysctl-fail" ] && exit 1 ;;
esac
exit 0
EOF
  chmod +x "$T/bin/qm" "$T/bin/qmrestore" "$T/bin/pct" "$T/bin/ip" "$T/bin/lvs" "$T/bin/lvremove" "$T/bin/systemd-run" "$T/bin/sysctl"
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
  grep -q "^set 990 --onboot 0 --protection 0 --memory 4096 --cores 4 --net0 name=eth0,bridge=vmbrdrill,ip=manual" "$T/pct.calls"
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
# NOTE on negative assertions: bats (errexit) does NOT fail a test on a mid-test `! cmd`, so every
# "this never happened" check uses never()/nothing_created(), which return non-zero explicitly.

teardown() { pkill -KILL -fx 'sleep 319' 2>/dev/null || true; pkill -KILL -fx 'sleep 331' 2>/dev/null || true; pkill -KILL -fx 'sleep 57' 2>/dev/null || true; }

vm_ok_image() { make_image vm101-20261001-120000.vma.zst.age FAKEDISKDATA; echo 'BK_DRILL_VM_CHECK_101=boot-only' >>"$BK_CONFIG_DIR/backup.env"; }
# remove named files or directories inside the test's own temp dir
clean() { local n; for n in "$@"; do rm -rf -- "${T:?}/${n:?}"; done; }
never() { if grep -Eq -- "$1" "$2" 2>/dev/null; then echo "UNEXPECTED match of '$1' in $2:" >&3; grep -E -- "$1" "$2" >&3; return 1; fi; return 0; }
# nothing was created: no restore, no bridge, no scratch guest, no kernel-setting change, no cgroup scope
nothing_created() {
  [ ! -e "$T/qmrestore.calls" ] || { echo "qmrestore ran" >&3; return 1; }
  never 'link add' "$T/ip.calls" || return 1
  [ ! -e "$T/systemd-run.calls" ] || { echo "a scope was created" >&3; return 1; }
  never 'dirty' "$T/sysctl.calls" || return 1
  never '^set 990|^start 990' "$T/qm.calls" || return 1
}
# every qm/pct/qmrestore call names the scratch id, never anything else
only_scratch_id() {
  local bad
  bad="$(awk '$2 ~ /^[0-9]+$/ && $2 != "990" { print }' "$T/qm.calls" "$T/pct.calls" 2>/dev/null)"
  [ -z "$bad" ] || { echo "touched another id: $bad" >&3; return 1; }
  bad="$(grep -v '^- 990 ' "$T/qmrestore.calls" 2>/dev/null || true)"
  [ -z "$bad" ] || { echo "restored to another id: $bad" >&3; return 1; }
}

guard_on_stubs() {
  export BK_PSI_DIR="$T/psi"; mkdir -p "$BK_PSI_DIR"
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' >"$BK_PSI_DIR/io"
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' >"$BK_PSI_DIR/memory"
  stub iostat 'echo "Device r/s rMB/s rrqm/s %rrqm r_await rareq-sz w/s wMB/s wrqm/s %wrqm w_await wareq-sz d/s dMB/s drqm/s %drqm d_await dareq-sz f/s f_await aqu-sz %util"
for i in 1 2; do echo "sda 100.0 50.0 0 0 3.0 128 20.0 2.0 0 0 0.5 100 0 0 0 0 0 0 0 0 0 12.0"; done'
  # lvs: guard (data%, metadata%), pool headroom (size, used%), orphan volume listing
  cat >"$T/bin/lvs" <<'EOS'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
case "$*" in
  *lv_name*) cat "$T/lvnames" 2>/dev/null || true ;;
  *lv_size*) echo "  1634.87 20.00" ;;
  *) echo "  17.7  0.69" ;;
esac
EOS
  chmod +x "$T/bin/lvs"
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
  { echo 'BK_GUARD_INTERVAL_S=1'; echo 'BK_GUARD_CONSECUTIVE=2'; echo 'BK_KILL_GRACE_S=2'; } >>"$BK_CONFIG_DIR/backup.env"
}

# ---- preflight refusals: each creates nothing ------------------------------------------------

@test "vm guardrail: inside the blackout the drill refuses and creates nothing" {
  vm_ok_image
  BK_DRILL_NOW_MIN=290 drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "overlap the blackout 04:20-05:20" "$T/curl.args"
  nothing_created
}

@test "vm guardrail: a start that would RUN INTO the blackout is refused too (the whole run is checked, not just the start)" {
  vm_ok_image
  BK_DRILL_NOW_MIN=120 drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run   # 02:00 + 170 min = 04:50
  [ "$status" -eq 1 ]
  BK_DRILL_NOW_MIN=60 drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run    # 01:00 + 170 min = 03:50
  [ "$status" -eq 0 ]
  BK_DRILL_NOW_MIN=120 BK_DRILL_RESTORE_TIMEOUT_MIN=60 drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 0 ]
}

@test "vm guardrail: the blackout edges (20 minute margin), a window that wraps midnight, and a malformed spec" {
  vm_ok_image
  export BK_DRILL_RESTORE_TIMEOUT_MIN=1
  BK_DRILL_NOW_MIN=238 drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run   # 238 + 21 = 259 < 260
  [ "$status" -eq 0 ]
  BK_DRILL_NOW_MIN=239 drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run   # 239 + 21 = 260 = the start
  [ "$status" -eq 1 ]
  BK_DRILL_NOW_MIN=319 drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run   # still inside
  [ "$status" -eq 1 ]
  BK_DRILL_NOW_MIN=320 drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run   # 05:20 is the first free minute
  [ "$status" -eq 0 ]
  BK_DRILL_BLACKOUT=23:00-02:00 BK_DRILL_NOW_MIN=60 drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 1 ]
  BK_DRILL_BLACKOUT=23:00-02:00 BK_DRILL_NOW_MIN=720 drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 0 ]
  BK_DRILL_BLACKOUT=nonsense drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"BK_DRILL_BLACKOUT must look like"* ]]
}

@test "vm guardrail: a running weekly or daily backup stops the drill; a STALE lock file does not" {
  vm_ok_image
  mkdir -p "$BK_STATE_DIR"
  : >"$BK_STATE_DIR/backup-weekly.lock"          # exists but nobody holds it
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 0 ]
  mkfifo "$T/release"
  ( exec 7>"$BK_STATE_DIR/backup-daily.lock"; flock -n 7 || exit 1; : >"$T/held"; read -r _ <"$T/release" ) 3>&- &
  holder=$!
  for _ in $(seq 1 50); do [ -e "$T/held" ] && break; sleep 0.1; done
  [ -e "$T/held" ]
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
  [ "$status" -eq 1 ]
  grep -q "backup-daily backup is running" "$T/curl.args"
  nothing_created
}

@test "vm guardrail: too little host memory, or too little on the pinned NUMA node, refuses before anything is created" {
  vm_ok_image
  printf 'MemAvailable: 20000000 kB\n' >"$T/meminfo"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "of host memory is available" "$T/curl.args"
  nothing_created
  printf 'MemAvailable: 141000000 kB\n' >"$T/meminfo"
  printf 'Node 1 MemFree: 9000000 kB\n' >"$T/node/node1/meminfo"
  clean curl.args
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "NUMA node 1 has only" "$T/curl.args"
  nothing_created
}

@test "vm guardrail: every bad or unbounded setting is refused up front and creates nothing (no bridge, no scope, no kernel change)" {
  vm_ok_image
  for v in "BK_DRILL_BWLIMIT_KIB=0" "BK_DRILL_BWLIMIT_KIB=1023" "BK_DRILL_BWLIMIT_KIB=102401" "BK_DRILL_BWLIMIT_KIB=fast" \
    "BK_DRILL_AFFINITY=1;reboot" "BK_DRILL_CPUUNITS=0" "BK_DRILL_CPUUNITS=10001" "BK_DRILL_NUMA_NODE=x" \
    "BK_DRILL_RESTORE_TIMEOUT_MIN=abc" "BK_DRILL_RESTORE_TIMEOUT_MIN=0" "BK_DRILL_RESTORE_TIMEOUT_MIN=601" \
    "BK_DRILL_GUARD=true" "BK_DRILL_GUARD=yes" "BK_DRILL_GUARD=2" "BK_DRILL_RESTORE_MEMHIGH=2X" "BK_DRILL_DIRTY_MB=8" \
    "BK_DRILL_DIRTY_BG_MB=999" "BK_DRILL_DISK_MBPS_WR=0" "BK_DRILL_NODE_HEADROOM_MB=\$(id)" "BK_DRILL_MIN_AVAIL_GB=lots" "BK_DRILL_GUARD_IO_METRIC=most"; do
    clean curl.args
    # the config file wins over the environment, so a setting that backup.env already carries is changed there
    case "$v" in BK_DRILL_GUARD=*) sed -i "s/^BK_DRILL_GUARD=.*/$v/" "$BK_CONFIG_DIR/backup.env" ;; esac
    if env "$v" bash "$SCRIPT" vm --guest 101 --identity "$BK_AGE_IDENTITY" >/dev/null 2>&1; then echo "accepted: $v" >&3; return 1; fi
    grep -q "P1" "$T/curl.args" || { echo "no alert for: $v" >&3; return 1; }
    nothing_created || { echo "created something for: $v" >&3; return 1; }
  done
}

@test "vm guardrail: an existing scratch id is detected from its config file even if qm and pct say nothing" {
  vm_ok_image
  mkdir -p "$T/pve/qemu-server"; : >"$T/pve/qemu-server/990.conf"
  BK_DRILL_PVE_DIR="$T/pve" drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "already exists" "$T/curl.args"
  nothing_created
}

@test "vm guardrail: a planted image named for the far future never outranks the real newest image" {
  make_image vm101-20261001-120000.vma.zst.age REALIMAGE
  make_image vm101-99991231-235959.vma.zst.age PLANTED
  echo 'BK_DRILL_VM_CHECK_101=boot-only' >>"$BK_CONFIG_DIR/backup.env"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"vm101-20261001-120000"* ]]
  [[ "$output" != *"99991231"* ]]
}

@test "vm guardrail: the test-only overrides are read through tvar (bats only), never directly from the environment" {
  # BK_DRILL_NOW_MIN, _MEMINFO, _NODE_SYSFS, _PVE_DIR, _QEMU_RUN_DIR, _NET_SYSFS can each weaken a protection
  run grep -nE '\$\{?BK_DRILL_(NOW_MIN|MEMINFO|NODE_SYSFS|PVE_DIR|QEMU_RUN_DIR|NET_SYSFS)' "$SCRIPT"
  [ "$status" -eq 1 ]
  run grep -c 'tvar BK_DRILL_' "$SCRIPT"
  [ "$output" -ge 6 ]
  run grep -nE 'BK_PSI_DIR' "$REPO_ROOT/scripts/backup-guard.sh"
  [[ "$output" == *"BATS_TEST_TMPDIR"* ]]
}

@test "vm guardrail: --dry-run runs the preflight, prints a forecast, and creates nothing" {
  vm_ok_image
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"PREFLIGHT OK"* ]]
  [[ "$output" == *"disk /dev/sda write cap 40960KiB/s"* ]]
  [[ "$output" == *"also capped by qmrestore at 40960KiB/s"* ]]
  [[ "$output" == *"MemoryHigh=2G"* ]]
  [[ "$output" == *"NUMA node 1"* ]]
  [[ "$output" == *"CPU affinity 1,3,5,7"* ]]
  [[ "$output" == *"dirty-page limits lowered to 256MB/64MB"* ]]
  [[ "$output" == *"Nothing is ever written to guest 101"* ]]
  nothing_created
}

@test "vm guardrail: --dry-run fails each preflight problem too (blackout, memory, guard)" {
  vm_ok_image
  BK_DRILL_NOW_MIN=290 drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 1 ]
  printf 'MemAvailable: 1000000 kB\n' >"$T/meminfo"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 1 ]
  printf 'MemAvailable: 141000000 kB\n' >"$T/meminfo"
  guard_on_stubs
  echo 0 >"$T/degrade-after"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"not READY"* ]]
  nothing_created
}

# ---- what the run does: caps, pins, limits, cleanup ---------------------------------------

@test "vm guardrail: the restore is rate-limited, memory-capped in a cgroup scope, time-limited; the guest is pinned and its disk limited" {
  vm_ok_image
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ]
  grep -q -- "--bwlimit 40960" "$T/qmrestore.calls"
  grep -q "MemoryHigh=2G" "$T/systemd-run.calls"
  grep -q "MemorySwapMax=0" "$T/systemd-run.calls"
  grep -q "IOWriteBandwidthMax=/dev/sda 40960K" "$T/systemd-run.calls"
  grep -q "timeout -k 30 150m" "$T/systemd-run.calls"
  setlines="$(grep '^set 990' "$T/qm.calls")"
  [[ "$setlines" == *"--numa0 cpus=0-3,hostnodes=1,memory=4096,policy=bind"* ]]
  [[ "$setlines" == *"--affinity 1,3,5,7"* ]]
  [[ "$setlines" == *"--cpuunits 10"* ]]
  [[ "$setlines" == *"--protection 0"* ]]
  [[ "$setlines" == *"--scsi0 local-lvm:vm-990-disk-0,size=300G,discard=on,mbps_rd=60,mbps_wr=30"* ]]
  grep -q "net.ipv6.conf.vmbrdrill.disable_ipv6=1" "$T/sysctl.calls"
  only_scratch_id
}

@test "vm guardrail: configured pin, weight, restore rate and disk limits really reach qm and qmrestore" {
  vm_ok_image
  mkdir -p "$T/node/node0"; printf 'Node 0 MemFree: 66000000 kB\n' >"$T/node/node0/meminfo"
  BK_DRILL_NUMA_NODE=0 BK_DRILL_AFFINITY=2-5 BK_DRILL_CPUUNITS=25 BK_DRILL_BWLIMIT_KIB=20480 BK_DRILL_DISK_MBPS_RD=70 BK_DRILL_DISK_MBPS_WR=35 BK_DRILL_RESTORE_MEMHIGH=1G \
    drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ] || { echo "$output" >&3; false; }
  setlines="$(grep '^set 990' "$T/qm.calls")"
  [[ "$setlines" == *"hostnodes=0,memory=4096,policy=bind"* ]]
  [[ "$setlines" == *"--affinity 2-5 --cpuunits 25"* ]]
  [[ "$setlines" == *"mbps_rd=70,mbps_wr=35"* ]]
  grep -q -- "--bwlimit 20480" "$T/qmrestore.calls"
  grep -q "MemoryHigh=1G" "$T/systemd-run.calls"
}

@test "vm guardrail: any applied value that is missing or WRONG in the final config means the guest is never started (and is destroyed)" {
  vm_ok_image
  i=0
  for ov in "numa0: cpus=0-3,hostnodes=0,memory=4096,policy=bind" "numa0: cpus=0-3,hostnodes=10,memory=4096,policy=bind" \
    "numa0: cpus=0-3,hostnodes=1,memory=4096,policy=preferred" "numa1: cpus=4-7,hostnodes=0,memory=4096,policy=bind" \
    "affinity: 0-78" "cpuunits: 1000" "memory: 114688" "protection: 1" "hookscript: local:snippets/evil.sh" "args: -chardev x" \
    "hugepages: 1024" "cicustom: user=local:snippets/u.yml" "virtiofs0: /host/dir" "scsi0: local-lvm:vm-990-disk-0,size=300G,discard=on" \
    "net1: virtio=AA:BB:CC:DD:EE:01,bridge=vmbr0"; do
    i=$((i + 1))
    clean vmstate qm.calls curl.args destroyed post-override nopin noaff nounits nomem
    printf '%s\n' "$ov" >"$T/post-override"
    drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
    [ "$status" -eq 1 ] || { echo "case $i [$ov]: status $status (expected a refusal)" >&3; return 1; }
    grep -q "refusing to boot" "$T/curl.args" || { echo "case $i [$ov]: no refusal message" >&3; return 1; }
    never '^start 990' "$T/qm.calls" || return 1
    [ -e "$T/destroyed" ] || { echo "case $i [$ov]: scratch guest not destroyed" >&3; return 1; }
  done
  for f in nopin noaff nounits nomem; do
    clean vmstate qm.calls curl.args destroyed post-override nopin noaff nounits nomem
    : >"$T/$f"
    drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
    [ "$status" -eq 1 ] || { echo "$f: status $status" >&3; return 1; }
    never '^start 990' "$T/qm.calls" || return 1
  done
}

@test "vm guardrail: host-executing and host-sharing keys are stripped (only those present), protection is switched off, CD-ROMs are left alone" {
  vm_ok_image
  printf 'hookscript: local:snippets/evil.sh\nargs: -chardev x\nhugepages: 1024\ncicustom: user=local:snippets/u.yml\nvirtiofs0: /host/dir\nprotection: 1\nide2: none,media=cdrom\n' >"$T/vm.extra"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ] || { echo "$output" >&3; false; }
  setlines="$(grep '^set 990' "$T/qm.calls")"
  [[ "$setlines" == *"--delete numa1,hookscript,args,hugepages,cicustom,virtiofs0"* ]]
  [[ "$setlines" == *"--protection 0"* ]]
}

@test "vm guardrail: a disk that is not a fresh scratch volume (raw host device, another guest's disk) refuses before anything is changed" {
  vm_ok_image
  for d in "scsi1: /dev/sdb" "virtio1: local-lvm:vm-101-disk-1,size=1G" "sata0: /dev/disk/by-id/ata-X"; do
    clean vmstate qm.calls curl.args
    printf '%s\n' "$d" >"$T/vm.extra"
    drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
    [ "$status" -eq 1 ] || { echo "[$d] status $status" >&3; return 1; }
    grep -q "not on the scratch volumes" "$T/curl.args" || { echo "[$d] no message" >&3; return 1; }
    never '^set 990 --onboot|^start 990' "$T/qm.calls" || return 1
  done
}

@test "vm guardrail: the drill only ever touches its scratch id, never the guest it copies or any other guest" {
  vm_ok_image
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ]
  grep -q '^set 990' "$T/qm.calls"       # non-vacuous: it did work
  only_scratch_id
}

@test "vm guardrail: a container is restored with the same cap, and a CT with host bind mounts or raw lxc settings is refused" {
  make_image ct104-20261001-120000.vma.zst.age CTDATA
  echo 'BK_DRILL_VM_CHECK_104="systemctl is-active something"' >>"$BK_CONFIG_DIR/backup.env"
  drill vm --guest 104 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ] || { echo "$output" >&3; false; }
  grep -q -- "--bwlimit 40960" "$T/systemd-run.calls" || grep -q -- "--bwlimit 40960" "$T/pct.calls"
  for x in "mp0: /srv/host,mp=/data" "lxc.mount.entry: /dev/x dev/x none bind"; do
    clean vmstate pct.calls curl.args systemd-run.calls
    printf '%s\n' "$x" >"$T/ct.extra"
    drill vm --guest 104 --identity "$BK_AGE_IDENTITY"
    [ "$status" -eq 1 ] || { echo "[$x] status $status" >&3; return 1; }
    never '^start 990' "$T/pct.calls" || return 1
  done
}

@test "vm guardrail: cleanup removes protection and onboot first, destroys with --skiplock, and proves the guest is gone" {
  vm_ok_image
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ]
  grep -q '^set 990 --skiplock 1 --protection 0 --onboot 0' "$T/qm.calls"
  grep -q '^destroy 990 --skiplock 1 --purge 1 --destroy-unreferenced-disks 1' "$T/qm.calls"
  never "still exists" "$T/curl.args"
}

@test "vm guardrail: a guest that cannot be destroyed is a loud P1 alert and a non-zero exit, never silent" {
  vm_ok_image
  : >"$T/destroy-fails"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -ne 0 ]
  grep -q "scratch guest 990 still exists" "$T/curl.args"
  grep -q "do not start it" "$T/curl.args"
}

@test "vm guardrail: orphan volumes of a restore that died before its config existed are removed" {
  vm_ok_image
  printf 'vm-101-disk-0\nvm-990-disk-0\nvm-990-disk-1\nvm-9901-disk-0\n' >"$T/lvnames"
  age-keygen -o "$T/wrong.key" 2>/dev/null
  drill vm --guest 101 --identity "$T/wrong.key"
  [ "$status" -eq 1 ]
  grep -q "pve/vm-990-disk-0" "$T/lvremove.calls"
  grep -q "pve/vm-990-disk-1" "$T/lvremove.calls"
  never "vm-101-disk-0|vm-9901" "$T/lvremove.calls"
  never "volumes .* still exist" "$T/curl.args"
}

@test "vm guardrail: the kernel's dirty-page limits are lowered for the restore and put back, on success and on failure" {
  vm_ok_image
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ]
  grep -q -- "-q -w vm.dirty_background_bytes=67108864 vm.dirty_bytes=268435456" "$T/sysctl.calls"
  grep -q -- "-q -w vm.dirty_ratio=20 vm.dirty_background_ratio=10" "$T/sysctl.calls"
  lower="$(grep -n 'dirty_bytes' "$T/sysctl.calls" | head -1 | cut -d: -f1)"
  restore="$(grep -n 'vm.dirty_ratio=20' "$T/sysctl.calls" | head -1 | cut -d: -f1)"
  [ "$lower" -lt "$restore" ]
  clean sysctl.calls qmrestore.calls vmstate
  age-keygen -o "$T/wrong.key" 2>/dev/null
  drill vm --guest 101 --identity "$T/wrong.key"
  [ "$status" -eq 1 ]
  grep -q -- "vm.dirty_ratio=20 vm.dirty_background_ratio=10" "$T/sysctl.calls"
}

@test "vm guardrail: if the kernel's dirty-page limits cannot be read or set, nothing is restored" {
  vm_ok_image
  : >"$T/dirty-unreadable"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  [ ! -e "$T/qmrestore.calls" ]
  clean dirty-unreadable curl.args vmstate
  : >"$T/sysctl-fail"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  [ ! -e "$T/qmrestore.calls" ]
}

@test "vm guardrail: the scratch qemu is made the preferred OOM victim" {
  vm_ok_image
  mkdir -p "$T/run"
  sleep 57 &
  victim=$!
  echo "$victim" >"$T/run/990.pid"
  BK_DRILL_QEMU_RUN_DIR="$T/run" drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ]
  [ "$(cat /proc/$victim/oom_score_adj)" = "1000" ]
  kill "$victim" 2>/dev/null || true
}

@test "vm guardrail: a stale guard reason from an earlier run is never blamed on this run" {
  vm_ok_image
  mkdir -p "$BK_STATE_DIR"
  echo "old stale reason: game was DEGRADED" >"$BK_STATE_DIR/drill-guard.reason"
  age-keygen -o "$T/wrong.key" 2>/dev/null
  drill vm --guest 101 --identity "$T/wrong.key"
  [ "$status" -eq 1 ]
  never "safety guard" "$T/curl.args"
  [ ! -e "$BK_STATE_DIR/drill-guard.reason" ]
}

# ---- the guard -------------------------------------------------------------------------------

@test "vm guard: ON by default (nothing set), and a game that is not READY stops the drill at the pre-check" {
  vm_ok_image
  guard_on_stubs
  sed -i '/^BK_DRILL_GUARD=/d' "$BK_CONFIG_DIR/backup.env"
  echo 0 >"$T/degrade-after"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "the safety guard sees a problem" "$T/curl.args"
  grep -q "not READY" "$T/curl.args"
  nothing_created
}

@test "vm guard: OFF only by the exact value 0, and then it is loudly recorded in the audit log" {
  vm_ok_image
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: the safety guard is OFF"* ]]
  grep -q "drill_guard_off" "$BK_STATE_DIR/audit.log"
  grep -q "drill_start" "$BK_STATE_DIR/audit.log"
  grep -q "guard=0" "$BK_STATE_DIR/evidence.log"
}

@test "vm guard: with the guard on, the settings it ran under are recorded in evidence" {
  vm_ok_image
  guard_on_stubs
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ] || { echo "$output" >&3; false; }
  grep -q "guard=1 bwlimit_kib=40960 node=1 affinity=1,3,5,7 cpuunits=10 timeout_min=150" "$BK_STATE_DIR/evidence.log"
}

@test "vm guard: with no game host configured the guard would be blind, so the drill refuses" {
  vm_ok_image
  guard_on_stubs
  sed -i '/^BK_BACKUP_SSH=/d' "$BK_CONFIG_DIR/backup.env"
  unset BK_GUARD_GAME_SSH
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "no game host" "$T/curl.args"
  nothing_created
}

@test "vm guard: a guard that cannot start (or dies at once) means the drill refuses to run unguarded, restores nothing, and cleans up" {
  vm_ok_image
  guard_on_stubs
  echo 'BK_GUARD_INTERVAL_S=abc' >>"$BK_CONFIG_DIR/backup.env"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "did not start" "$T/curl.args"
  [ ! -e "$T/qmrestore.calls" ]
  [ ! -e "$T/vmstate/bridge" ]
}

@test "vm guard: host memory pressure, and a sampler that cannot read, each stop the drill at the pre-check" {
  vm_ok_image
  guard_on_stubs
  printf 'some avg10=40.00 avg60=0.00 avg300=0.00 total=1\n' >"$BK_PSI_DIR/memory"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "memory pressure" "$T/curl.args"
  nothing_created
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' >"$BK_PSI_DIR/memory"
  clean psi/io curl.args
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "cannot read host I/O pressure" "$T/curl.args"
  nothing_created
}

@test "vm guard: a healthy host lets the drill finish with the guard watching the whole run, and the guard is gone afterwards" {
  vm_ok_image
  guard_on_stubs
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ] || { echo "$output" >&3; false; }
  [[ "$output" == *"guard: watching PID"* ]]
  [ ! -e "$T/vmstate/scratch-exists" ]
  [ ! -e "$T/vmstate/bridge" ]
  if pgrep -f "backup-guard.sh --target" >/dev/null; then echo "a guard process leaked" >&3; return 1; fi
}

@test "vm guard: a problem DURING the restore stops it with exit 130, destroys the scratch guest and bridge, kills the restore, and says why" {
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
  [ "$status" -eq 130 ] || { echo "status $status" >&3; echo "$output" >&3; false; }
  if pgrep -fx 'sleep 331' >/dev/null; then echo "the restore process leaked" >&3; return 1; fi
  if pgrep -f "backup-guard.sh --target" >/dev/null; then echo "a guard process leaked" >&3; return 1; fi
  grep -q "stopped by the safety guard" "$T/curl.args"
  [ -e "$T/destroyed" ]
  [ ! -e "$T/vmstate/scratch-exists" ]
  [ ! -e "$T/vmstate/bridge" ]
  grep -q "link del vmbrdrill" "$T/ip.calls"
  never '^start 990' "$T/qm.calls"
  grep -q -- "vm.dirty_ratio=20 vm.dirty_background_ratio=10" "$T/sysctl.calls"
  [ ! -e "$BK_STATE_DIR/drill-guard.reason" ]
  ram_empty
}

@test "vm guard: a guard that dies AFTER the restore stops the drill before the copy of prod is booted" {
  vm_ok_image
  guard_on_stubs
  cat >"$T/bin/qmrestore" <<EOS
#!/usr/bin/env bash
echo "\$*" >>"$T/qmrestore.calls"
cat >"$T/restored.bin"
mkdir -p "$T/vmstate"; : >"$T/vmstate/scratch-exists"
pkill -KILL -f 'backup-guard.sh --target .*--reason-file $BK_STATE_DIR/' || true   # only THIS test's guard, never a real one
sleep 1
EOS
  chmod +x "$T/bin/qmrestore"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "no longer running" "$T/curl.args"
  never '^start 990' "$T/qm.calls"
  [ -e "$T/destroyed" ]
}

@test "vm guard: a kill (not a guard stop) is never reported as a guard stop, even if an old reason file existed" {
  vm_ok_image
  mkdir -p "$BK_STATE_DIR"
  echo "old stale reason: game was DEGRADED" >"$BK_STATE_DIR/drill-guard.reason"
  cat >"$T/bin/qmrestore" <<EOS
#!/usr/bin/env bash
echo "\$*" >>"$T/qmrestore.calls"
cat >"$T/restored.bin"
mkdir -p "$T/vmstate"; : >"$T/vmstate/scratch-exists"
exec sleep 331
EOS
  chmod +x "$T/bin/qmrestore"
  bash "$SCRIPT" vm --guest 101 --identity "$BK_AGE_IDENTITY" >"$T/out.txt" 2>&1 &
  drill_pid=$!
  for _ in $(seq 1 100); do [ -e "$T/qmrestore.calls" ] && break; sleep 0.1; done
  [ -e "$T/qmrestore.calls" ]
  sleep 1
  kill -TERM "$drill_pid"
  wait "$drill_pid" || true
  never "safety guard" "$T/curl.args"
  [ -e "$T/destroyed" ]
  [ ! -e "$BK_STATE_DIR/drill-guard.reason" ]
}

@test "vm drill: an operator interrupt says so loudly, is recorded as an interruption (not a failed drill), raises no alert and still cleans up" {
  vm_ok_image
  cat >"$T/bin/qmrestore" <<EOS
#!/usr/bin/env bash
echo "\$*" >>"$T/qmrestore.calls"
cat >"$T/restored.bin"
mkdir -p "$T/vmstate"; : >"$T/vmstate/scratch-exists"
exec sleep 332
EOS
  chmod +x "$T/bin/qmrestore"
  bash "$SCRIPT" vm --guest 101 --identity "$BK_AGE_IDENTITY" >"$T/out.txt" 2>&1 &
  drill_pid=$!
  for _ in $(seq 1 100); do [ -e "$T/qmrestore.calls" ] && break; sleep 0.1; done
  [ -e "$T/qmrestore.calls" ]
  sleep 1
  kill -TERM "$drill_pid"
  wait "$drill_pid" || true
  grep -q "INTERRUPTED by SIGTERM: this is a controlled shutdown, NOT a failure" "$T/out.txt"
  grep -q "shutdown complete: the host is back as it was" "$T/out.txt"
  grep -q "drill_interrupted" "$BK_STATE_DIR/audit.log"
  never "drill_failed" "$BK_STATE_DIR/audit.log"
  never "DRILL FAILED|unexpected error" "$T/out.txt"
  [ ! -e "$T/curl.args" ] || never "FAILED|unexpected error|P1" "$T/curl.args"
  [ -e "$T/destroyed" ]
}

@test "vm guard: the drill gives the guard a 5 minute WARMING grace, configurable, and refuses a bad value" {
  vm_ok_image
  guard_on_stubs
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"game WARMING tolerated up to 300s"* ]]
  sed -i '/^BK_DRILL_GUARD_WARMING_GRACE_S=/d' "$BK_CONFIG_DIR/backup.env"
  echo 'BK_DRILL_GUARD_WARMING_GRACE_S=900' >>"$BK_CONFIG_DIR/backup.env"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run
  [[ "$output" == *"tolerated up to 900s"* ]]
  sed -i '/^BK_DRILL_GUARD_WARMING_GRACE_S=/d' "$BK_CONFIG_DIR/backup.env"
  echo 'BK_DRILL_GUARD_WARMING_GRACE_S=abc' >>"$BK_CONFIG_DIR/backup.env"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 1 ]
}

@test "vm guard: if SIGINT is ignored in the shell that started the drill (so the guard could not stop it), the drill refuses" {
  vm_ok_image
  guard_on_stubs
  run bash -c 'trap "" INT; exec bash "$0" vm --guest 101 --identity "$1"' "$SCRIPT" "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "SIGINT is ignored" "$T/curl.args"
  [ ! -e "$T/qmrestore.calls" ]
}

@test "vm guardrail: a host that already runs its dirty-page limits in bytes mode (ratio 0) is refused, never left lowered" {
  vm_ok_image
  : >"$T/dirty-zero"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "bytes mode" "$T/curl.args"
  [ ! -e "$T/qmrestore.calls" ]
  never "dirty_bytes" "$T/sysctl.calls"
}

@test "vm guardrail: a UEFI/vTPM guest works: efidisk and tpmstate are checked to be scratch volumes but get no speed limit (they cannot take one)" {
  vm_ok_image
  printf 'efidisk0: local-lvm:vm-990-disk-1,efitype=4m,size=4M\ntpmstate0: local-lvm:vm-990-disk-2,size=4M,version=v2.0\n' >"$T/vm.extra"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ] || { echo "$output" >&3; false; }
  never '^set 990 --(efidisk0|tpmstate0)' "$T/qm.calls"
  grep -q '^set 990 --scsi0 .*mbps_rd=60,mbps_wr=30' "$T/qm.calls"
  # but a raw device on those types is still refused
  clean vmstate qm.calls curl.args
  printf 'efidisk0: /dev/sdb\n' >"$T/vm.extra"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "not on the scratch volumes" "$T/curl.args"
}

@test "vm guardrail: every extra NUMA node and a vcpus setting from the prod config are removed and verified gone" {
  vm_ok_image
  printf 'numa2: cpus=60-79,hostnodes=1,memory=1024,policy=bind\nvcpus: 60\n' >"$T/vm.extra"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 0 ] || { echo "$output" >&3; false; }
  setlines="$(grep '^set 990' "$T/qm.calls")"
  [[ "$setlines" == *"--delete numa1,numa2,vcpus,"* || "$setlines" == *"--delete numa1,numa2,vcpus "* ]] || [[ "$setlines" == *"--delete numa1,numa2,vcpus"* ]]
  clean vmstate qm.calls curl.args destroyed
  printf 'numa3: cpus=1,hostnodes=1,memory=1,policy=bind\n' >"$T/post-override"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  grep -q "still configured" "$T/curl.args"
  never '^start 990' "$T/qm.calls"
}

@test "vm guardrail: a --dry-run that is refused prints the reason but raises NO alert and records nothing" {
  vm_ok_image
  BK_DRILL_NOW_MIN=290 drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"overlap the blackout"* ]]
  [ ! -e "$T/curl.args" ]
  [ ! -e "$BK_STATE_DIR/evidence.log" ]
  guard_on_stubs
  echo 0 >"$T/degrade-after"
  drill vm --guest 101 --identity "$BK_AGE_IDENTITY" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"not READY"* ]]
  [ ! -e "$T/curl.args" ]
}
