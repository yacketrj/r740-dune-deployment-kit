#!/usr/bin/env bash
# =============================================================================
# backup-common.sh -- sourced by the backup-*.sh scripts. Do not run directly.
# See docs/superpowers/specs/2026-09-29-backup-strategy-design.md
# =============================================================================
# shellcheck shell=bash

BK_CONFIG_DIR="${BK_CONFIG_DIR:-/root/.config/r740-backup}"
BK_STATE_DIR="${BK_STATE_DIR:-/var/lib/r740-backup}"

bk_load_config() {
  local cfg="${BK_CONFIG_FILE:-$BK_CONFIG_DIR/backup.env}"
  if [ ! -f "$cfg" ]; then
    echo "backup: config not found: $cfg" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  . "$cfg"
}

# Strip anything secret-shaped from stdin (Strict Requirement 24).
bk_redact() {
  sed -E \
    -e 's#(https://(ptb\.|canary\.)?discord(app)?\.com/api/webhooks/)[^[:space:]"]+#\1[REDACTED]#g' \
    -e 's#(AGE-SECRET-KEY-)[A-Z0-9]+#\1[REDACTED]#g' \
    -e 's#((password|token|secret|pass)[[:space:]]*[=:][[:space:]]*)[^[:space:]]+#\1[REDACTED]#Ig' \
    -e 's#"([A-Za-z_]*(password|token|secret|passwd)[A-Za-z_]*)"[[:space:]]*:[[:space:]]*"[^"]*"#"\1":"[REDACTED]"#Ig' \
    -e 's#(://[^/:@[:space:]]+:)[^/@[:space:]]+@#\1[REDACTED]@#g' \
    -e 's#(Authorization:[[:space:]]*Basic[[:space:]]+)[^[:space:]]+#\1[REDACTED]#Ig' \
    -e 's#(Authorization:[[:space:]]*Bearer[[:space:]]+)[^[:space:]]+#\1[REDACTED]#Ig' \
    -e 's#(Bearer[[:space:]]+)[^[:space:]]+#\1[REDACTED]#Ig'
}

bk_log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | bk_redact
}

# Post a message to the Discord webhook. Never fails the caller, but records the
# outcome in BK_NOTIFY_LAST_RC (0 delivered, 1 failed, 2 skipped: no webhook) so
# a caller that MUST know (the alarm) can react to a dead webhook.
export BK_NOTIFY_LAST_RC=2
bk_notify() {
  local msg="$1" url payload
  BK_NOTIFY_LAST_RC=2
  if [ -z "${BK_DISCORD_WEBHOOK_FILE:-}" ] || [ ! -r "$BK_DISCORD_WEBHOOK_FILE" ]; then
    bk_log "notify skipped (no webhook file)"
    return 0
  fi
  BK_NOTIFY_LAST_RC=1
  url="$(cat "$BK_DISCORD_WEBHOOK_FILE")" || { bk_log "notify: could not read webhook file (ignored)"; return 0; }
  msg="$(printf '%s' "$msg" | bk_redact)"
  [ "${#msg}" -le 1900 ] || msg="${msg:0:1890} [truncated]"
  payload="$(jq -n --arg c "$msg" '{content:$c}')" || { bk_log "notify: could not build payload (ignored)"; return 0; }
  if printf 'url = "%s"\n' "$url" | curl -fsS -m 10 -H 'Content-Type: application/json' -d "$payload" -K - >/dev/null 2>&1; then
    BK_NOTIFY_LAST_RC=0
  else
    bk_log "notify failed (ignored)"
  fi
  return 0
}

# Exclusive per-name lock; the lock is held for the life of the calling shell.
bk_lock() {
  bk_require_test_isolation || return 1
  mkdir -p "$BK_STATE_DIR"
  exec 9>"$BK_STATE_DIR/$1.lock"
  if ! flock -n 9; then
    bk_log "another '$1' run holds the lock; exiting"
    return 1
  fi
}

bk_require_free_gb() {
  local dir="$1" need="$2" avail
  if ! [[ "$need" =~ ^[0-9]+$ ]]; then
    bk_log "invalid free space requirement: $need (must be numeric)"
    return 1
  fi
  avail="$(df -BG --output=avail "$dir" | tail -n 1 | tr -dc '0-9')"
  if [ -z "$avail" ] || [ "$avail" -lt "$need" ]; then
    bk_log "insufficient free space in $dir: ${avail:-?}GB free, ${need}GB required"
    return 1
  fi
}

# Fill BK_SSH_OPTS with the hardened client options every pull/probe uses: no user ssh
# config, no agent or port forwarding, keepalives so a stalled peer cannot hang a run,
# a pinned host key when BK_KNOWN_HOSTS is set.
bk_ssh_opts_init() {
  BK_SSH_OPTS=(-F /dev/null -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4
    -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o ForwardAgent=no -o ClearAllForwardings=yes)
  [ -z "${BK_BACKUP_SSH_KEY:-}" ] || BK_SSH_OPTS+=(-i "$BK_BACKUP_SSH_KEY")
  [ -z "${BK_KNOWN_HOSTS:-}" ] || BK_SSH_OPTS+=(-o "UserKnownHostsFile=$BK_KNOWN_HOSTS")
}

# Thin-pool headroom: fail (message on stderr) when free space or usage is out of bounds.
# A full thin pool freezes I/O for every guest, so anything that writes a big volume into
# it (a snapshot backup, a scratch restore) must check first.
bk_pool_headroom() { # min_free_gb [max_pct]
  local min_free="${1:?min free GB}" max_pct="${2:-${BK_MAX_POOL_PCT:-80}}" pool line size pct free
  pool="${BK_THIN_POOL:-pve/data}"
  if ! line="$(lvs --noheadings --nosuffix --units g -o lv_size,data_percent "$pool" 2>/dev/null)" || [ -z "$line" ]; then
    echo "cannot read thin pool usage for $pool" >&2
    return 1
  fi
  read -r size pct <<<"$line"
  free="$(awk -v s="$size" -v p="$pct" 'BEGIN { printf "%d", s * (100 - p) / 100 }')"
  if [ "$free" -lt "$min_free" ]; then echo "thin pool $pool has only ${free}GB free (need ${min_free}GB)" >&2; return 1; fi
  if awk -v p="$pct" -v m="$max_pct" 'BEGIN { exit !(p + 0 > m + 0) }'; then echo "thin pool $pool is ${pct}% full (limit ${max_pct}%)" >&2; return 1; fi
  return 0
}

# Refuse to write into an unmounted mountpoint (it would fill the local disk).
bk_require_mounted() {
  if ! timeout 20 mountpoint -q "$1"; then
    bk_log "not a mounted filesystem: $1"
    return 1
  fi
}

# Encrypt IN to OUT with age. Fails closed and leaves no OUT on any error.
bk_age_encrypt() {
  local in="$1" out="$2"
  case "${BK_AGE_RECIPIENT:-}" in
    age1*) ;;
    *)
      bk_log "BK_AGE_RECIPIENT is unset or not an age recipient; refusing to write"
      return 1
      ;;
  esac
  if age -r "$BK_AGE_RECIPIENT" -o "$out.partial" "$in"; then
    mv -f -- "$out.partial" "$out"
  else
    rm -f -- "$out.partial"
    bk_log "age encryption failed for $(basename "$in")"
    return 1
  fi
}

# A backup name is trusted for retention only when its embedded YYYYMMDD-HHMMSS
# stamp is a real date that is not in the future: the share is writable by other
# machines, so a planted "...-99991231-235959..." name must never outrank real files.
bk_stamp_plausible() {
  local stamp="${1:?stamp}" epoch
  [[ "$stamp" =~ ^[0-9]{8}-[0-9]{6}$ ]] || return 1
  epoch="$(date -u -d "${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}" +%s 2>/dev/null)" || return 1
  [ "$epoch" -le $(( $(date -u +%s) + 3600 )) ]
}

# Keep the newest KEEP_DAILY files plus the newest file of each of the newest
# KEEP_MONTHLY calendar months. Only touches PREFIX-YYYYMMDD-HHMMSS*.tar.age.
bk_prune_daily_monthly() {
  local dir="$1" prefix="$2" keep_daily="$3" keep_monthly="$4"
  local -a files=()
  local base ym months=" " mcount=0 n=0 keep_it f failed=0
  if ! [[ "$keep_daily" =~ ^[0-9]+$ ]] || [ "$keep_daily" -lt 1 ]; then
    bk_log "invalid keep_daily: $keep_daily (must be numeric and >= 1)"
    return 1
  fi
  if ! [[ "$keep_monthly" =~ ^[0-9]+$ ]] || [ "$keep_monthly" -lt 1 ]; then
    bk_log "invalid keep_monthly: $keep_monthly (must be numeric and >= 1)"
    return 1
  fi
  while IFS= read -r f; do
    files+=("$f")
  done < <(find "$dir" -maxdepth 1 -type f -name "${prefix}-[0-9]*.tar.age" -printf '%f\n' | sort -r)
  [ "${#files[@]}" -gt 0 ] || return 0
  for base in "${files[@]}"; do
    ym="$(printf '%s' "$base" | sed -nE "s/^${prefix}-([0-9]{6})[0-9]{2}-[0-9]{6}\.tar\.age$/\1/p")"
    [ -n "$ym" ] || continue
    bk_stamp_plausible "$(printf '%s' "$base" | sed -nE "s/^${prefix}-([0-9]{8}-[0-9]{6})\.tar\.age$/\1/p")" || continue
    n=$((n + 1))
    keep_it=0
    [ "$n" -le "$keep_daily" ] && keep_it=1
    if [[ "$months" != *" $ym "* ]]; then
      months="$months$ym "
      mcount=$((mcount + 1))
      [ "$mcount" -le "$keep_monthly" ] && keep_it=1
    fi
    if [ "$keep_it" -ne 1 ]; then rm -f -- "$dir/$base" || failed=1; fi
  done
  return "$failed"
}

# Keep the newest KEEP files whose name starts with PREFIX- (any extension).
bk_prune_keep_newest() {
  local dir="$1" prefix="$2" keep="$3" f n=0
  if ! [[ "$keep" =~ ^[0-9]+$ ]] || [ "$keep" -lt 1 ]; then
    bk_log "invalid keep count: $keep (must be numeric and >= 1)"
    return 1
  fi
  local stamp failed=0
  while IFS= read -r f; do
    stamp="$(printf '%s' "$f" | sed -nE "s/^${prefix}-([0-9]{8}-[0-9]{6})\.[A-Za-z0-9.]+\.age$/\1/p")"
    [ -n "$stamp" ] && bk_stamp_plausible "$stamp" || continue
    n=$((n + 1))
    if [ "$n" -gt "$keep" ]; then rm -f -- "$dir/$f" || failed=1; fi
  done < <(find "$dir" -maxdepth 1 -type f -name "${prefix}-[0-9]*.age" -printf '%f\n' | sort -r)
  return "$failed"
}

# Apply the daily/monthly rule to an rclone remote by mirroring names locally.
bk_prune_remote() {
  local remote="$1" prefix="$2" keep_daily="$3" keep_monthly="$4"
  local tmp name
  local -a before=()
  tmp="$(mktemp -d)"
  while IFS= read -r name; do
    : >"$tmp/$name"
    before+=("$name")
  done < <(rclone lsf --files-only "$remote")
  bk_prune_daily_monthly "$tmp" "$prefix" "$keep_daily" "$keep_monthly"
  local failed=0
  for name in "${before[@]}"; do
    if [ ! -e "$tmp/$name" ]; then
      rclone deletefile "$remote/$name" || { bk_log "could not delete $remote/$name"; failed=1; }
    fi
  done
  rm -rf "$tmp"
  return "$failed"
}

bk_state_touch() {
  bk_require_test_isolation || return 1
  mkdir -p "$BK_STATE_DIR"
  date +%s >"$BK_STATE_DIR/last-success-$1"
}

# Seconds since the last success for a tier; a very large number if never.
bk_state_age_seconds() {
  local f="$BK_STATE_DIR/last-success-$1" ts
  if [ ! -s "$f" ]; then
    echo 999999999
    return 0
  fi
  ts="$(cat "$f")"
  echo $(($(date +%s) - ts))
}

# =============================================================================
# v2 additions (design v2, audit themes T4/T10/T11/T12)
# =============================================================================

# Backups hold secrets: files created by the jobs must not be world-readable.
bk_secure_umask() {
  umask 077
}

# Under bats, refuse to touch any state directory outside the test's own temp
# dir (a test that forgets to override BK_STATE_DIR must not be able to alter
# production state, e.g. silence the staleness alarm). No effect outside bats.
bk_require_test_isolation() {
  [ -n "${BATS_TEST_TMPDIR:-}" ] || return 0
  case "$BK_STATE_DIR" in
    "$BATS_TEST_TMPDIR"/*) return 0 ;;
  esac
  bk_log "refusing to run under bats: BK_STATE_DIR='$BK_STATE_DIR' is not under BATS_TEST_TMPDIR"
  return 1
}

# Proxmox VM/CT ids are 100 and up; anything else must never reach a command.
bk_valid_vmid() {
  [[ "${1:-}" =~ ^[1-9][0-9]{2,8}$ ]]
}

# rm -rf PATH only if it resolves strictly inside ROOT. Refuses empty arguments,
# "/", ROOT itself, "..", and symlink escapes (realpath -m resolves them).
bk_safe_rm_under() {
  local root="${1:-}" path="${2:-}" real_root real_path
  if [ -z "$root" ] || [ -z "$path" ]; then
    bk_log "bk_safe_rm_under: refusing an empty argument"
    return 1
  fi
  real_root="$(realpath -m -- "$root")"
  real_path="$(realpath -m -- "$path")"
  if [ "$real_root" = "/" ] || [ "$real_path" = "/" ] || [ "$real_path" = "$real_root" ]; then
    bk_log "bk_safe_rm_under: refusing to remove the root itself or /"
    return 1
  fi
  case "$real_path" in
    "$real_root"/*) ;;
    *)
      bk_log "bk_safe_rm_under: '$path' resolves outside '$root'"
      return 1
      ;;
  esac
  rm -rf -- "$real_path"
}

# Refuse a tar that holds anything but plain files and directories. A symlink,
# hardlink, device or fifo member lets a later member be written through it, so a
# hostile archive could write outside the extraction directory as root. Names are
# checked separately by the callers. Returns 0 only for an all-regular archive.
bk_tar_members_safe() {
  local tarfile="${1:?tar file}" listing types
  listing="$(tar -tvf "$tarfile" 2>/dev/null)" || return 1
  [ -n "$listing" ] || return 1
  types="$(printf '%s\n' "$listing" | cut -c1 | sort -u | tr -d '\n')"
  case "$types" in
    ''|*[!d-]*) return 1 ;;
  esac
  return 0
}

# Append "sha256  size  name" for FILE to MANIFEST.
bk_manifest_add() {
  local manifest="${1:?manifest}" f="${2:?file}" sum size
  if [ ! -f "$f" ]; then
    bk_log "manifest: no such file: $f"
    return 1
  fi
  sum="$(sha256sum -- "$f" | cut -d' ' -f1)" || return 1
  size="$(stat -c %s -- "$f")" || return 1
  printf '%s  %s  %s\n' "$sum" "$size" "$(basename -- "$f")" >>"$manifest"
}

# Bit-exact comparison of a source file and its transferred copy.
bk_verify_copy() {
  if cmp -s -- "${1:?src}" "${2:?dst}"; then
    return 0
  fi
  bk_log "copy verification FAILED: $(basename -- "$1") differs from its destination"
  return 1
}

# Ping the external dead-man's-switch (URL in a root-only file, sent on curl's
# stdin so it never appears in argv). Arg "fail" pings the failure endpoint.
# Returns 0 ok, 3 not configured, 4 ping failed. Never aborts the caller.
bk_dead_man_ping() {
  local f="${BK_DEADMAN_URL_FILE:-}" url
  if [ -z "$f" ] || [ ! -r "$f" ]; then
    bk_log "dead-man ping skipped (no URL file configured)"
    return 3
  fi
  url="$(tr -d '\r\n' <"$f")" || return 4
  [ "${1:-}" = "fail" ] && url="${url%/}/fail"
  if printf 'url = "%s"\n' "$url" | curl -fsS -m 10 -K - >/dev/null 2>&1; then
    return 0
  fi
  bk_log "dead-man ping failed"
  return 4
}

# Actionable failure alert: job, failed stage, redacted error, re-run command,
# runbook. bk_notify redacts and never fails the caller.
bk_alert() {
  local stage="${1:-unknown}" err="${2:-}" rerun="${3:-}" job="${BK_JOB:-backup}"
  bk_notify "${BK_ALERT_MENTION:-} r740 ${job} FAILED at stage '${stage}': ${err:-no detail} | re-run: ${rerun:-see runbook} | runbook: ${BK_RUNBOOK_URL:-docs/08-backup-runbook.md}"
}

# Append one JSON line (time, event, host, plus key=value pairs) to the audit
# log, and mirror it to $BK_AUDIT_SHIP_DIR when that is a directory. Values are
# redacted. Never fails the caller.
bk_audit_log() {
  local ev="${1:?event}" kv k v filter='{time:$time,event:$event,host:$host,prev:$prev'
  shift
  bk_require_test_isolation || return 0
  mkdir -p "$BK_STATE_DIR" 2>/dev/null || return 0
  local -a args=(--arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg event "$ev" --arg host "$(hostname)")
  for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    case "$k" in time | event | host | prev) continue ;; esac
    v="$(printf '%s' "$v" | bk_redact)"
    args+=(--arg "$k" "$v")
    filter="$filter,$k:\$$k"
  done
  filter="$filter}"
  # Hash chain: every record carries the sha256 of the previous line, so an edit, a
  # deletion or a reordering anywhere breaks every later link (bk_audit_verify). Reading
  # the last line and appending happen under one lock, or two overlapping jobs would
  # both link to the same predecessor and fork the chain.
  (
    flock -x -w 30 9 || exit 0
    prev="genesis"
    if [ -s "$BK_STATE_DIR/audit.log" ]; then
      prev="$(tail -n 1 "$BK_STATE_DIR/audit.log" | sha256sum | cut -d' ' -f1)"
    fi
    line="$(jq -nc "${args[@]}" --arg prev "$prev" "$filter")" || exit 0
    printf '%s\n' "$line" >>"$BK_STATE_DIR/audit.log" 2>/dev/null || exit 0
    if [ -n "${BK_AUDIT_SHIP_DIR:-}" ] && [ -d "$BK_AUDIT_SHIP_DIR" ]; then
      printf '%s\n' "$line" >>"$BK_AUDIT_SHIP_DIR/audit.log" 2>/dev/null || bk_log "audit ship failed (ignored)"
    fi
  ) 9>"$BK_STATE_DIR/audit.lock" || true
  return 0
}

# Append one tab-separated evidence record: time, kind, PASS|FAIL, detail.
# The alarm reads this log to know whether escrow checks and restore drills are due.
bk_evidence() { # kind result detail
  bk_require_test_isolation || return 0
  mkdir -p "$BK_STATE_DIR" || return 0
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >>"$BK_STATE_DIR/evidence.log"
  # Also into the chained (and optionally shipped) audit log, where an edit is detectable.
  bk_audit_log evidence "kind=$1" "result=$2" "detail=$3"
}

# Verify the audit log's hash chain. Prints the first broken line number on failure.
bk_audit_verify() { # [file]
  local f="${1:-$BK_STATE_DIR/audit.log}" n=0 prev="genesis" line want
  [ -s "$f" ] || return 0
  while IFS= read -r line; do
    n=$((n + 1))
    want="$(printf '%s' "$line" | jq -r '.prev // empty' 2>/dev/null)" || want=""
    if [ "$want" != "$prev" ]; then
      echo "$n"
      return 1
    fi
    prev="$(printf '%s\n' "$line" | sha256sum | cut -d' ' -f1)"
  done <"$f"
  return 0
}

# Create a private (0700) RAM-backed working directory and print its path.
# Decrypted backup material must never touch persistent disk.
bk_make_ram_dir() {
  local base="${BK_RAM_DIR:-/dev/shm}" d
  if [ ! -d "$base" ]; then
    bk_log "RAM-backed directory not available: $base"
    return 1
  fi
  d="$(mktemp -d "$base/bk-work.XXXXXX")" || return 1
  chmod 700 "$d"
  printf '%s\n' "$d"
}

# Shred every file in DIR (a bk_make_ram_dir directory) and remove it. Refuses
# anything that is not a bk-work.* directory directly under the RAM base.
bk_wipe_dir() {
  local d="${1:-}" base="${BK_RAM_DIR:-/dev/shm}"
  [ -n "$d" ] || return 0
  case "$d" in
    "$base"/bk-work.*) ;;
    *)
      bk_log "bk_wipe_dir: refusing '$d' (not a bk-work directory under $base)"
      return 1
      ;;
  esac
  [ -d "$d" ] || return 0
  find "$d" -type f -exec shred -u -n 1 {} + 2>/dev/null || true
  rm -rf -- "$d"
}

