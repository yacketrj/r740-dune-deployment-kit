#!/usr/bin/env bash
# =============================================================================
# backup-drill.sh -- restore drills (design v2, themes T1/T4/T5).
# A backup nobody has restored is a hope. These drills prove the data is usable.
#
#   backup-drill.sh pipeline
#       Automated, needs NO real key. Encrypts synthetic data to a throwaway key
#       and pushes it through the real SMB share and OneDrive, reads it back,
#       decrypts, and proves truncation, tampering and a wrong key all FAIL.
#   backup-drill.sh db --identity FILE [--archive NAME] [--dry-run]
#       ASSISTED (the operator supplies the private key for the drill; it is
#       used, never stored). Decrypts the newest daily set in RAM, verifies its
#       manifest, restores the authoritative dump into a THROWAWAY Postgres
#       container on dune-dev (never dune-dev's own database) and asserts table
#       and row counts.
#   backup-drill.sh vm --guest ID --identity FILE [--dry-run]
#       ASSISTED. Restores the guest's newest image to a scratch VMID on a
#       transient no-uplink bridge with its memory and cores capped and NUMA
#       pinning removed, boots it, runs the configured in-guest check, destroys it.
#
# Every result is appended to the evidence log; a FAIL is a P1 alert.
# --dry-run verifies what can be verified in RAM and prints the plan; it starts
# nothing and records no evidence.
#
# RUN THIS: on the Proxmox host as root (assisted drills need the operator).
# =============================================================================
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
. "$here/backup-common.sh"

usage() {
  echo "usage: $0 pipeline | db --identity FILE [--archive NAME] [--dry-run] | vm --guest ID --identity FILE [--dry-run]" >&2
  exit 2
}

sub="${1:-}"
[ -n "$sub" ] || usage
shift
identity=""; archive=""; guest=""; dry=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --identity) identity="${2:-}"; shift 2 ;;
    --archive) archive="${2:-}"; shift 2 ;;
    --guest) guest="${2:-}"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) usage ;;
  esac
done
case "$sub" in pipeline | db | vm) ;; *) usage ;; esac

BK_JOB="restore drill ($sub)"
export BK_JOB
bk_secure_umask
bk_load_config
: "${BK_SMB_MOUNT:?}"

STAGE="start"
RERUN="bash $here/backup-drill.sh $sub"
alerted=0
main_pid=$$
ram=""
container=""
scratch=""
scratch_kind=""
scratch_created=0
bridge_created=0
DRILL_BRIDGE="vmbrdrill"

remote() { ssh -o BatchMode=yes -o ConnectTimeout=15 "${BK_DRILL_SSH:?}" "$@"; }

cleanup() {
  local rc=$?
  if [ -n "$container" ] && [[ "$container" =~ ^bk-drill-[0-9]+-[0-9]+$ ]]; then
    remote "docker rm -f $container" >/dev/null 2>&1 || true
  fi
  if [ "$scratch_created" -eq 1 ] && [[ "$scratch" =~ ^9[0-9]{2}$ ]]; then
    if [ "$scratch_kind" = "ct" ]; then
      pct stop "$scratch" >/dev/null 2>&1 || true
      pct destroy "$scratch" --purge 1 >/dev/null 2>&1 || true
    else
      qm stop "$scratch" --skiplock 1 >/dev/null 2>&1 || true
      qm destroy "$scratch" --purge 1 --destroy-unreferenced-disks 1 >/dev/null 2>&1 || true
    fi
  fi
  if [ "$bridge_created" -eq 1 ]; then
    ip link del "$DRILL_BRIDGE" >/dev/null 2>&1 || true
  fi
  [ -z "$ram" ] || bk_wipe_dir "$ram" || true
  return "$rc"
}
trap cleanup EXIT

report_failure() {
  if [ "$alerted" -eq 0 ]; then
    alerted=1
    bk_evidence "drill-$sub" FAIL "stage=$STAGE $1"
    bk_audit_log drill_failed "kind=$sub" "stage=$STAGE" "error=$1"
    bk_alert "$STAGE" "P1: $1" "$RERUN"
    bk_dead_man_ping fail || true
  fi
}
on_err() {
  local line="$1"
  trap - ERR
  if [ "$BASHPID" = "$main_pid" ]; then report_failure "unexpected error at line $line"; fi
  exit 1
}
trap 'on_err $LINENO' ERR
fail_drill() { bk_log "DRILL FAILED at $STAGE: $*"; report_failure "$*"; exit 1; }

bk_lock "drill-$sub" || exit 1
ram="$(bk_make_ram_dir)" || fail_drill "no RAM-backed working directory"

# ---- shared: decrypt + verify a daily set into $ram/set --------------------------------
open_daily_set() {
  local path
  [ -n "$identity" ] && [ -r "$identity" ] || fail_drill "--identity FILE is required and must be readable (the drill uses the private key and never stores it)"
  STAGE="select"
  if [ -z "$archive" ]; then
    archive="$(find "$BK_SMB_MOUNT/daily" -maxdepth 1 -type f -name 'daily-*.tar.age' -printf '%f\n' 2>/dev/null | sort | tail -n 1)"
  fi
  [[ "$archive" =~ ^daily-[0-9]{8}-[0-9]{6}\.tar\.age$ ]] || fail_drill "no valid daily archive selected ('$archive')"
  path="$BK_SMB_MOUNT/daily/$archive"
  [ -f "$path" ] || fail_drill "archive not found on the share: $archive"
  STAGE="decrypt"
  age -d -i "$identity" -o "$ram/set.tar" "$path" 2>/dev/null || fail_drill "cannot decrypt $archive with the supplied key (wrong key or damaged archive)"
  tar -tf "$ram/set.tar" >"$ram/set.list" 2>/dev/null || fail_drill "decrypted archive is not a readable tar"
  if grep -qE '^/|(^|/)\.\.(/|$)' "$ram/set.list"; then fail_drill "archive contains an absolute or parent-relative path"; fi
  bk_tar_members_safe "$ram/set.tar" || fail_drill "archive contains a link, device or other non-regular member"
  mkdir -p "$ram/set"
  tar -xf "$ram/set.tar" -C "$ram/set" --no-same-owner --no-same-permissions || fail_drill "could not unpack the decrypted archive"
  STAGE="integrity"
  ( cd "$ram/set" && sha256sum -c --quiet MANIFEST.sha256 >/dev/null 2>&1 ) || fail_drill "MANIFEST.sha256 does not verify: the archive contents are damaged"
  authoritative="$(awk -F= '$1 == "authoritative" { print $2; exit }' "$ram/set/prod/gate-manifest.txt" 2>/dev/null || true)"
  [ -n "$authoritative" ] || fail_drill "no authoritative dump named in the archive manifest"
  dump="$ram/set/prod/$authoritative"
  [ -s "$dump" ] || fail_drill "authoritative dump is missing or empty"
  [ "$(head -c 5 -- "$dump")" = "PGDMP" ] || fail_drill "authoritative dump has no PGDMP header"
  grep -q '^battlegroup_id: ' "$dump.yaml" 2>/dev/null || fail_drill "the dump's sidecar has no battlegroup_id (identity cannot be restored)"
  grep -q '^format: pg_dump_custom' "$dump.yaml" 2>/dev/null || fail_drill "the dump's sidecar does not say pg_dump_custom"
}

# ---- pipeline drill ---------------------------------------------------------------------
drill_pipeline() {
  local pub stamp name remote_dir n
  STAGE="synthesize"
  age-keygen -o "$ram/test.key" 2>/dev/null
  pub="$(age-keygen -y "$ram/test.key")"
  mkdir -p "$ram/b/prod/runtime/backups/db" "$ram/b/prod/runtime/secrets"
  { printf 'PGDMP'; head -c 65536 /dev/urandom; } >"$ram/b/prod/runtime/backups/db/drill.backup"
  printf 'backup_origin: automatic\nbattlegroup_id: drill\nformat: pg_dump_custom\n' >"$ram/b/prod/runtime/backups/db/drill.backup.yaml"
  echo "synthetic-secret" >"$ram/b/prod/runtime/secrets/x.txt"
  ( cd "$ram/b" && find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 sha256sum >MANIFEST.sha256 )
  tar -C "$ram/b" -cf "$ram/bundle.tar" .
  age -r "$pub" -o "$ram/set.age" "$ram/bundle.tar"
  stamp="$(date -u +%Y%m%d-%H%M%S)"
  name="drill-pipeline-$stamp.tar.age"

  STAGE="smb"
  bk_require_mounted "$BK_SMB_MOUNT" || fail_drill "SMB share not mounted"
  mkdir -p "$BK_SMB_MOUNT/drill"
  cp -f -- "$ram/set.age" "$BK_SMB_MOUNT/drill/$name.partial"
  bk_verify_copy "$ram/set.age" "$BK_SMB_MOUNT/drill/$name.partial" || { rm -f -- "$BK_SMB_MOUNT/drill/$name.partial"; fail_drill "SMB round trip did not verify"; }
  mv -f -- "$BK_SMB_MOUNT/drill/$name.partial" "$BK_SMB_MOUNT/drill/$name"

  STAGE="onedrive"
  : "${BK_RCLONE_REMOTE:?}"
  remote_dir="$BK_RCLONE_REMOTE/drill"
  rclone copyto "$ram/set.age" "$remote_dir/$name" || fail_drill "upload to OneDrive failed (token, quota or network)"
  rclone copyto "$remote_dir/$name" "$ram/back.age" || fail_drill "download from OneDrive failed"
  bk_verify_copy "$ram/set.age" "$ram/back.age" || fail_drill "OneDrive round trip did not verify bit-exactly"

  STAGE="decrypt"
  age -d -i "$ram/test.key" -o "$ram/out.tar" "$ram/back.age" || fail_drill "the round-tripped file does not decrypt"
  tar -tf "$ram/out.tar" >/dev/null || fail_drill "the round-tripped bundle is not a valid tar"
  mkdir -p "$ram/out"
  tar -xf "$ram/out.tar" -C "$ram/out"
  ( cd "$ram/out" && sha256sum -c --quiet MANIFEST.sha256 >/dev/null 2>&1 ) || fail_drill "round-tripped manifest does not verify"

  STAGE="negative-cases"
  size="$(stat -c %s "$ram/set.age")"
  head -c $((size / 2)) "$ram/set.age" >"$ram/trunc.age"
  if age -d -i "$ram/test.key" -o "$ram/x1" "$ram/trunc.age" 2>/dev/null && tar -tf "$ram/x1" >/dev/null 2>&1; then fail_drill "a TRUNCATED archive was accepted"; fi
  cp -- "$ram/set.age" "$ram/tamper.age"
  printf '\xff' | dd of="$ram/tamper.age" bs=1 seek=$((size / 2)) conv=notrunc 2>/dev/null
  if age -d -i "$ram/test.key" -o "$ram/x2" "$ram/tamper.age" 2>/dev/null; then fail_drill "a TAMPERED archive was accepted"; fi
  age-keygen -o "$ram/wrong.key" 2>/dev/null
  if age -d -i "$ram/wrong.key" -o "$ram/x3" "$ram/set.age" 2>/dev/null; then fail_drill "a WRONG key decrypted the archive"; fi

  STAGE="cleanup"
  rm -f -- "$BK_SMB_MOUNT/drill/$name"
  rclone deletefile "$remote_dir/$name" || bk_log "could not delete the drill object on OneDrive (ignored): $name"
  n="$name"
  bk_evidence drill-pipeline PASS "object=$n size=$size"
  bk_audit_log drill_ok "kind=pipeline" "object=$n"
  bk_dead_man_ping || true
  bk_log "pipeline drill PASSED ($n): share and OneDrive round trip; truncation, tampering and a wrong key are rejected"
}

# ---- database drill ---------------------------------------------------------------------
drill_db() {
  local name tables chk tbl min cnt i
  open_daily_set
  if [ "$dry" -eq 1 ]; then
    echo "DRY RUN OK: $archive decrypts, MANIFEST verifies, authoritative dump $authoritative has a PGDMP header and a battlegroup_id."
    echo "PLAN: start a throwaway ${BK_DRILL_PG_IMAGE:-<BK_DRILL_PG_IMAGE unset>} container on ${BK_DRILL_SSH:-<BK_DRILL_SSH unset>} (no network, tmpfs data), pg_restore the dump, assert tables >= ${BK_DRILL_MIN_TABLES:-?} and rows: ${BK_DRILL_ROW_CHECKS:-<none configured>}, remove the container."
    return 0
  fi
  STAGE="configure"
  : "${BK_DRILL_SSH:?}"
  [ -n "${BK_DRILL_PG_IMAGE:-}" ] || fail_drill "BK_DRILL_PG_IMAGE is not set (use the same Postgres image tag as prod)"
  [[ "${BK_DRILL_MIN_TABLES:-}" =~ ^[0-9]+$ ]] || fail_drill "BK_DRILL_MIN_TABLES must be a number"
  [ -n "${BK_DRILL_ROW_CHECKS:-}" ] || fail_drill "no row-count assertions configured (BK_DRILL_ROW_CHECKS); a restore that asserts nothing proves nothing"
  local mem="${BK_DRILL_MEMORY:-4g}" tmpfs="${BK_DRILL_TMPFS_SIZE:-2g}" max_err="${BK_DRILL_MAX_RESTORE_ERRORS:-0}"
  [[ "$mem" =~ ^[0-9]+[mMgG]$ ]] || fail_drill "BK_DRILL_MEMORY must look like 4g"
  [[ "$tmpfs" =~ ^[0-9]+[mMgG]$ ]] || fail_drill "BK_DRILL_TMPFS_SIZE must look like 2g"
  [[ "$max_err" =~ ^[0-9]+$ ]] || fail_drill "BK_DRILL_MAX_RESTORE_ERRORS must be a number"

  STAGE="start-container"
  name="bk-drill-$(date +%s)-$RANDOM"
  [[ "$name" =~ ^bk-drill-[0-9]+-[0-9]+$ ]] || fail_drill "internal: bad container name"
  container="$name"
  remote "docker run -d --name $name --label r740-backup-drill=1 --network none --memory $mem --tmpfs /var/lib/postgresql/data:rw,size=$tmpfs -e POSTGRES_HOST_AUTH_METHOD=trust $BK_DRILL_PG_IMAGE" >/dev/null || fail_drill "could not start the throwaway Postgres container on $BK_DRILL_SSH"
  local tries="${BK_DRILL_READY_TRIES:-60}"
  for i in $(seq 1 "$tries"); do
    # The image starts a temporary init server, stops it, then starts the real one: wait for
    # the SECOND "ready to accept connections", or the restore can hit the shutdown.
    if remote "docker exec $name pg_isready -U postgres && [ \$(docker logs $name 2>&1 | grep -c 'ready to accept connections') -ge 2 ]" >/dev/null 2>&1; then break; fi
    [ "$i" -lt "$tries" ] || fail_drill "the throwaway Postgres did not become ready"
    sleep "${BK_DRILL_READY_SLEEP:-2}"
  done

  STAGE="restore"
  remote "docker exec -i $name sh -c 'cat > /tmp/drill.backup'" <"$dump" || fail_drill "could not copy the dump into the container"
  # Mirror the real restore (dune db restore): create the dune role and database, then a
  # plain pg_restore into it. Errors are counted, not ignored: the default allows none.
  remote "docker exec $name psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c 'create role dune login' -c 'create database dune owner dune'" >/dev/null 2>"$ram/restore.err" || fail_drill "could not create the dune role/database in the throwaway container: $(tr '\n' ' ' <"$ram/restore.err" | cut -c1-300)"
  restore_rc=0
  remote "docker exec $name pg_restore -U postgres -d dune /tmp/drill.backup" >/dev/null 2>"$ram/restore.err" || restore_rc=$?
  errs="$(grep -c 'error:' "$ram/restore.err" || true)"
  if [ "$restore_rc" -ne 0 ] && [ "$errs" -eq 0 ]; then errs=1; fi
  if [ "$errs" -gt "$max_err" ]; then
    fail_drill "pg_restore FAILED with $errs error(s) (allowed $max_err): $(tr '\n' ' ' <"$ram/restore.err" | cut -c1-300)"
  fi

  STAGE="assert"
  tables="$(remote "docker exec $name psql -U postgres -d dune -Atc 'select count(*) from information_schema.tables where table_schema not in (\$\$pg_catalog\$\$,\$\$information_schema\$\$)'" 2>/dev/null || true)"
  [[ "$tables" =~ ^[0-9]+$ ]] || fail_drill "could not count restored tables"
  [ "$tables" -ge "$BK_DRILL_MIN_TABLES" ] || fail_drill "only $tables tables restored (expected at least $BK_DRILL_MIN_TABLES)"
  for chk in $BK_DRILL_ROW_CHECKS; do
    tbl="${chk%%:*}"; min="${chk##*:}"
    [[ "$tbl" =~ ^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*$ ]] || fail_drill "invalid table in BK_DRILL_ROW_CHECKS: $tbl"
    [[ "$min" =~ ^[0-9]+$ ]] || fail_drill "invalid minimum in BK_DRILL_ROW_CHECKS: $chk"
    cnt="$(remote "docker exec $name psql -U postgres -d dune -Atc 'select count(*) from $tbl'" 2>/dev/null || true)"
    [[ "$cnt" =~ ^[0-9]+$ ]] || fail_drill "could not count rows in $tbl"
    [ "$cnt" -ge "$min" ] || fail_drill "$tbl has $cnt rows (expected at least $min)"
  done

  STAGE="record"
  bk_evidence drill-db PASS "archive=$archive dump=$authoritative tables=$tables checks=$BK_DRILL_ROW_CHECKS"
  bk_audit_log drill_ok "kind=db" "archive=$archive" "tables=$tables"
  bk_dead_man_ping || true
  bk_log "database drill PASSED: $archive -> $authoritative restored into a throwaway container; $tables tables; row checks OK"
}

# ---- VM / CT drill ------------------------------------------------------------------------
drill_vm() {
  local image kind base check_var check_cmd mem cores model out rc up i
  bk_valid_vmid "$guest" || fail_drill "--guest must be a VM/CT id"
  case " $BK_VMIDS " in *" $guest "*) ;; *) fail_drill "guest $guest is not in BK_VMIDS" ;; esac
  [ -n "$identity" ] && [ -r "$identity" ] || fail_drill "--identity FILE is required and must be readable"

  STAGE="select"
  image="$(find "$BK_SMB_MOUNT/vm" -maxdepth 1 -type f -name "[vc][mt]${guest}-*.age" -printf '%f\n' 2>/dev/null | sort | tail -n 1)"
  [ -n "$image" ] || fail_drill "no image for guest $guest on the share"
  base="${image%%-*}"
  case "$base" in vm*) kind="vm" ;; ct*) kind="ct" ;; *) fail_drill "unrecognised image name $image" ;; esac

  scratch="${BK_SCRATCH_VMID:-990}"
  [[ "$scratch" =~ ^9[0-9]{2}$ ]] || fail_drill "BK_SCRATCH_VMID must be 900-999"
  case " $BK_VMIDS " in *" $scratch "*) fail_drill "scratch id $scratch is a production id" ;; esac
  if qm status "$scratch" >/dev/null 2>&1 || pct status "$scratch" >/dev/null 2>&1; then
    fail_drill "scratch id $scratch already exists; refusing to touch it"
  fi
  check_var="BK_DRILL_VM_CHECK_$guest"
  check_cmd="${!check_var:-}"
  [ -n "$check_cmd" ] || fail_drill "no in-guest check configured ($check_var); booting proves little without one"
  mem="${BK_DRILL_VM_MEMORY_MB:-8192}"
  cores="${BK_DRILL_VM_CORES:-4}"
  [[ "$mem" =~ ^[0-9]+$ && "$cores" =~ ^[0-9]+$ ]] || fail_drill "invalid drill memory/cores"

  if [ "$dry" -eq 1 ]; then
    echo "DRY RUN OK: guest $guest image $image ($kind)."
    echo "PLAN: transient bridge $DRILL_BRIDGE (no uplink); restore to scratch id $scratch with new MACs; cap to ${mem}MB/${cores} cores, drop NUMA pinning, autostart off; boot; run '$check_var'; destroy the scratch guest and the bridge."
    return 0
  fi

  STAGE="network"
  if ip link show "$DRILL_BRIDGE" >/dev/null 2>&1; then fail_drill "bridge $DRILL_BRIDGE already exists; refusing to reuse it"; fi
  ip link add name "$DRILL_BRIDGE" type bridge
  ip link set "$DRILL_BRIDGE" up
  bridge_created=1

  STAGE="restore"
  scratch_kind="$kind"
  scratch_created=1
  if [ "$kind" = "vm" ]; then
    age -d -i "$identity" <"$BK_SMB_MOUNT/vm/$image" | zstd -dc | ionice -c3 nice -n 19 qmrestore - "$scratch" --storage "${BK_DRILL_STORAGE:-local-lvm}" --unique 1 || fail_drill "restore of $image failed"
  else
    age -d -i "$identity" <"$BK_SMB_MOUNT/vm/$image" | zstd -dc | ionice -c3 nice -n 19 pct restore "$scratch" - --storage "${BK_DRILL_STORAGE:-local-lvm}" --unique 1 || fail_drill "restore of $image failed"
  fi

  STAGE="isolate"
  if [ "$kind" = "vm" ]; then
    conf="$(qm config "$scratch")" || fail_drill "could not read the scratch VM config"
    # A copy of a guest must not fight the live one for a host device.
    if printf '%s\n' "$conf" | grep -Eq '^(hostpci|usb|serial|parallel)[0-9]+:'; then
      fail_drill "the restored config has host-bound devices (hostpci/usb/serial/parallel); refusing to boot a copy that could contend with the live guest"
    fi
    model="$(printf '%s\n' "$conf" | awk -F'[:=,]' '/^net0:/ { gsub(/ /, "", $2); print $2; exit }')"
    [ -n "$model" ] || model="virtio"
    extra_nets="$(printf '%s\n' "$conf" | awk -F: '/^net[1-9][0-9]*:/ { print $1 }' | paste -sd, -)"
    qm set "$scratch" --onboot 0 --memory "$mem" --balloon 0 --cores "$cores" --sockets 1 --numa 0 --delete "affinity,numa0,numa1${extra_nets:+,$extra_nets}" --net0 "$model,bridge=$DRILL_BRIDGE" >/dev/null || fail_drill "could not isolate and cap the scratch VM"
    stray="$(qm config "$scratch" | awk -F: -v b="bridge=$DRILL_BRIDGE" '/^net[0-9]+:/ && index($0, b) == 0 { print $1 }' | paste -sd, -)"
    [ -z "$stray" ] || fail_drill "scratch VM still has network device(s) outside $DRILL_BRIDGE ($stray); refusing to boot"
  else
    pct set "$scratch" --onboot 0 --memory "$mem" --cores "$cores" --net0 "name=eth0,bridge=$DRILL_BRIDGE,ip=manual" >/dev/null || fail_drill "could not isolate and cap the scratch CT"
    stray="$(pct config "$scratch" | awk -F: -v b="bridge=$DRILL_BRIDGE" '/^net[0-9]+:/ && index($0, b) == 0 { print $1 }' | paste -sd, -)"
    [ -z "$stray" ] || fail_drill "scratch CT still has network device(s) outside $DRILL_BRIDGE ($stray); refusing to boot"
  fi

  STAGE="boot"
  if [ "$kind" = "vm" ]; then qm start "$scratch" || fail_drill "scratch VM did not start"; else pct start "$scratch" || fail_drill "scratch CT did not start"; fi
  up=0
  for i in $(seq 1 "${BK_DRILL_BOOT_TRIES:-120}"); do
    if [ "$kind" = "vm" ]; then
      qm agent "$scratch" ping >/dev/null 2>&1 && { up=1; break; }
    else
      pct status "$scratch" 2>/dev/null | grep -q running && { up=1; break; }
    fi
    sleep "${BK_DRILL_BOOT_SLEEP:-5}"
  done
  [ "$up" -eq 1 ] || fail_drill "the restored guest did not come up (no guest-agent answer / not running)"

  STAGE="in-guest-check"
  if [ "$kind" = "vm" ]; then
    out="$(qm guest exec "$scratch" --timeout 120 -- /bin/sh -c "$check_cmd" 2>&1)" || fail_drill "in-guest check could not run: $(printf '%s' "$out" | cut -c1-200)"
    rc="$(printf '%s' "$out" | jq -r '.exitcode // 1' 2>/dev/null || echo 1)"
  else
    if pct exec "$scratch" -- /bin/sh -c "$check_cmd" >/dev/null 2>&1; then rc=0; else rc=1; fi
  fi
  [ "$rc" = "0" ] || fail_drill "in-guest check FAILED (exit $rc): $check_var"

  STAGE="record"
  bk_evidence drill-vm PASS "guest=$guest image=$image scratch=$scratch check=$check_var"
  bk_audit_log drill_ok "kind=vm" "guest=$guest" "image=$image"
  bk_dead_man_ping || true
  bk_log "VM drill PASSED: $image restored to scratch $scratch, booted isolated, in-guest check passed; destroying the scratch guest"
}

case "$sub" in
  pipeline) drill_pipeline ;;
  db) drill_db ;;
  vm) drill_vm ;;
esac
