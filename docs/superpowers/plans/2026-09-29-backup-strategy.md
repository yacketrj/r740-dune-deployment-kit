# R740 Backup Strategy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the R740 host scheduled, encrypted, off-box backups of the game DB, secrets, host config and all VM/CT images, with failure alerts and scripted restore tests.

**Architecture:** A small shell library (`backup-common.sh`) plus one script per job (daily app backup, weekly VM images, staleness check, restore test), driven by systemd timers on the Proxmox host. Everything is `age`-encrypted before it leaves the host. Off-site copies go to OneDrive through `rclone` (crypt remote); second-machine copies go to an SMB share mounted on the host. Scripts are tested with `bats` using stub binaries on `PATH`.

**Tech Stack:** bash, `age`, `rclone` (crypt), `vzdump`/`qmrestore`, `mount.cifs`, systemd timers, `bats`, `shellcheck`, `jq`, `curl`.

**Spec:** `docs/superpowers/specs/2026-09-29-backup-strategy-design.md`

## Global Constraints

- Encryption: `age`, applied before anything leaves the host; fail closed (never write plaintext) if the recipient is unset or malformed.
- Off-site target: OneDrive via `rclone` with client-side encryption; the OneDrive desktop client is NOT installed on Proxmox.
- Second-machine target: SMB share on the operator's always-on desktop; must be verified mounted (`mountpoint -q`) before any write.
- Schedule: daily app tier after the 04:30 game DB backup; weekly VM/CT image tier; RPO 24h (daily) and 7 days (weekly).
- Retention: OneDrive 30 daily + 12 monthly; desktop 3 weekly copies each of VM 101, 103 and CT 104, 1 copy of VM 102.
- Alarms: no successful daily backup in 26 hours, no successful weekly backup in 8 days.
- Restore tests: monthly, scripted and logged (Strict Requirement 25); a failed test is a P1.
- Secrets: credentials live in root-only files under `/root/.config/r740-backup/` (mode 0600 files, 0700 directory), never in a repo; secrets are redacted from all logs and alerts (Strict Requirement 24).
- systemd timers use `Persistent=true` so a missed run catches up.
- Staging is size-capped; every job runs a free-space pre-flight and fails rather than filling the thin pool.
- Repo rules: work on a branch and PR (Strict Requirement 21); `shellcheck -S warning` clean on every `scripts/*.sh` and `tests/*.sh` (CI); `tests/no-personal-identifiers.sh` must pass; no Claude co-author trailer on commits.

## Review Focus

Failure modes the spec implies that no happy-path test would exercise, most likely first:

1. **SMB share not mounted:** writing into an empty mountpoint fills the host's 94GB root volume silently. Expected: job aborts with an alert (Task 3 and Task 4 tests).
2. **Recipient unset/garbled:** must fail with no output file, never produce plaintext (Task 1 test).
3. **Interrupted run leaves a half-written file:** a partial file must never look like a valid backup and must not be pruned-around (writes go to `*.partial`, renamed only on success; Task 1 test).
4. **Pruning bug deletes everything:** empty directory, non-matching filenames, or fewer files than the retention count must delete nothing (Task 1 tests).
5. **Two runs overlap** (long weekly job still running at the next trigger): the second must exit without touching anything (Task 1 lock test).
6. **Alert webhook down or secret in output:** a failing webhook must not fail the backup, and no webhook URL or key may appear in any log line (Task 1 tests).

## File Structure

| Path | Responsibility |
|---|---|
| `scripts/backup-common.sh` | Sourced library: config load, logging + redaction, Discord notify, lock, free-space and mount checks, age encrypt, retention pruning, state files |
| `scripts/backup-init-keys.sh` | One-time: create the age keypair and config skeleton with safe permissions |
| `scripts/backup-daily.sh` | Daily tier: gather DB backups + secrets + host config, encrypt, copy to SMB and OneDrive, prune, record success |
| `scripts/backup-weekly.sh` | Weekly tier: vzdump every VM/CT, encrypt, move to SMB, prune, record success |
| `scripts/backup-check.sh` | Staleness alarm for both tiers |
| `scripts/backup-restore-test.sh` | Monthly restore test (`db` or `vm` mode) |
| `scripts/backup-install-timers.sh` | Generate and enable the systemd units |
| `backup.env.example` | Documented config template (no secrets) |
| `tests/backup/*.bats`, `tests/backup/helper.bash` | bats tests with stub binaries |
| `.github/workflows/ci.yml` | Add a `backup-tests` job, include it in `ci-gate` |
| `docs/07-backup-runbook.md` | Operator runbook: setup, restore, key handling, alarms |

---

### Task 0: Gate — Layer 1 design audit

Strict Requirement 20 requires a Layer 1 (design) audit before implementation. This is a process gate, not code.

- [ ] **Step 1:** Confirm with the operator whether the eight-hat design audit on `docs/superpowers/specs/2026-09-29-backup-strategy-design.md` is to be run now, or explicitly deferred (record the decision in issue #119).
- [ ] **Step 2:** If run: file each finding as a GitHub issue on `yacketrj/r740-dune-deployment-kit`, resolve CRITICAL/HIGH in the spec, then continue. Include the STRIDE mapping ask in every hat's prompt (Requirement 20).
- [ ] **Step 3:** Post the findings table and STRIDE table as a comment on issue #119.

---

### Task 1: Common library

**Files:**
- Create: `scripts/backup-common.sh`
- Create: `tests/backup/helper.bash`
- Create: `tests/backup/common.bats`

**Interfaces:**
- Produces (all sourced, no output on source):
  - `bk_load_config` — sources `$BK_CONFIG_FILE` (default `$BK_CONFIG_DIR/backup.env`), returns 1 if missing.
  - `bk_log MSG...` — timestamped line on stdout, through `bk_redact`.
  - `bk_redact` — stdin→stdout filter removing webhook URLs, `AGE-SECRET-KEY-…`, and `password|token|secret` values.
  - `bk_notify MSG` — POST to the webhook in `$BK_DISCORD_WEBHOOK_FILE`; always returns 0.
  - `bk_lock NAME` — flock on `$BK_STATE_DIR/NAME.lock`; returns 1 if held.
  - `bk_require_free_gb DIR GB` — returns 1 if less than GB free.
  - `bk_require_mounted PATH` — returns 1 unless `mountpoint -q PATH`.
  - `bk_age_encrypt IN OUT` — encrypts to `OUT` via `OUT.partial`; returns 1 and leaves no `OUT` on any failure or when `BK_AGE_RECIPIENT` is not `age1…`.
  - `bk_prune_daily_monthly DIR PREFIX KEEP_DAILY KEEP_MONTHLY`
  - `bk_prune_keep_newest DIR PREFIX KEEP`
  - `bk_prune_remote REMOTE PREFIX KEEP_DAILY KEEP_MONTHLY` — uses `rclone lsf` / `rclone deletefile`.
  - `bk_state_touch TIER`, `bk_state_age_seconds TIER`.
- Backup filenames: `PREFIX-YYYYMMDD-HHMMSS.EXT.age` where EXT is `tar` (daily) or `vma.zst` / `tar.zst` (weekly).

- [ ] **Step 1: Write the test helper and failing tests**

```bash file=tests/backup/helper.bash
# Shared bats helper: isolated temp dirs and stub binaries on PATH.
setup_env() {
  export BK_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export BK_CONFIG_DIR="$BATS_TEST_TMPDIR/config"
  export BK_STAGE_DIR="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$BK_STATE_DIR" "$BK_CONFIG_DIR" "$BK_STAGE_DIR" "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT
}

# stub NAME 'shell body' : create an executable stub that logs its args to $BATS_TEST_TMPDIR/NAME.calls
stub() {
  local name="$1" body="${2:-:}"
  cat >"$BATS_TEST_TMPDIR/bin/$name" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/$name.calls"
$body
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/$name"
}

# make a real age keypair for tests; sets BK_AGE_RECIPIENT and BK_AGE_IDENTITY
make_age_key() {
  BK_AGE_IDENTITY="$BATS_TEST_TMPDIR/age.key"
  age-keygen -o "$BK_AGE_IDENTITY" 2>/dev/null
  BK_AGE_RECIPIENT="$(age-keygen -y "$BK_AGE_IDENTITY")"
  export BK_AGE_IDENTITY BK_AGE_RECIPIENT
}
```

```bash file=tests/backup/common.bats
#!/usr/bin/env bats
load helper

setup() {
  setup_env
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/backup-common.sh"
}

@test "bk_redact removes webhook urls, age secret keys and password values" {
  run bash -c 'source "$REPO_ROOT/scripts/backup-common.sh"; printf "%s\n" \
    "hook https://discord.com/api/webhooks/123/abcSECRET" \
    "key AGE-SECRET-KEY-1QQQQQQQQQQQ" \
    "password=hunter2" | bk_redact'
  [ "$status" -eq 0 ]
  [[ "$output" != *"abcSECRET"* ]]
  [[ "$output" != *"1QQQQQQQQQQQ"* ]]
  [[ "$output" != *"hunter2"* ]]
  [[ "$output" == *"[REDACTED]"* ]]
}

@test "bk_load_config fails when the config file is missing" {
  BK_CONFIG_FILE="$BATS_TEST_TMPDIR/nope.env" run bk_load_config
  [ "$status" -eq 1 ]
}

@test "bk_notify returns 0 and does not fail the caller when the webhook is down" {
  stub curl 'exit 22'
  printf 'https://discord.com/api/webhooks/1/x\n' >"$BK_CONFIG_DIR/hook"
  BK_DISCORD_WEBHOOK_FILE="$BK_CONFIG_DIR/hook" run bk_notify "hello"
  [ "$status" -eq 0 ]
}

@test "bk_notify never prints the webhook url" {
  stub curl 'exit 0'
  printf 'https://discord.com/api/webhooks/1/TOPSECRET\n' >"$BK_CONFIG_DIR/hook"
  BK_DISCORD_WEBHOOK_FILE="$BK_CONFIG_DIR/hook" run bk_notify "hello"
  [[ "$output" != *"TOPSECRET"* ]]
}

@test "bk_lock: a second holder is refused" {
  run bash -c '
    source "$REPO_ROOT/scripts/backup-common.sh"
    bk_lock t1 || exit 10
    ( bk_lock t1 ) && exit 11
    exit 0'
  [ "$status" -eq 0 ]
}

@test "bk_require_mounted fails for a plain directory" {
  run bk_require_mounted "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
}

@test "bk_require_free_gb fails when more space is asked than exists" {
  run bk_require_free_gb "$BATS_TEST_TMPDIR" 99999999
  [ "$status" -eq 1 ]
}

@test "bk_require_free_gb passes for a trivial requirement" {
  run bk_require_free_gb "$BATS_TEST_TMPDIR" 0
  [ "$status" -eq 0 ]
}

@test "bk_age_encrypt round-trips" {
  make_age_key
  printf 'payload' >"$BATS_TEST_TMPDIR/in"
  run bk_age_encrypt "$BATS_TEST_TMPDIR/in" "$BATS_TEST_TMPDIR/out.age"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/out.age" ]
  [ ! -e "$BATS_TEST_TMPDIR/out.age.partial" ]
  run age -d -i "$BK_AGE_IDENTITY" "$BATS_TEST_TMPDIR/out.age"
  [ "$output" = "payload" ]
}

@test "bk_age_encrypt refuses an empty or malformed recipient and writes nothing" {
  printf 'payload' >"$BATS_TEST_TMPDIR/in"
  BK_AGE_RECIPIENT="" run bk_age_encrypt "$BATS_TEST_TMPDIR/in" "$BATS_TEST_TMPDIR/out.age"
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/out.age" ]
  BK_AGE_RECIPIENT="not-a-key" run bk_age_encrypt "$BATS_TEST_TMPDIR/in" "$BATS_TEST_TMPDIR/out.age"
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/out.age" ]
  [ ! -e "$BATS_TEST_TMPDIR/out.age.partial" ]
}

mk() { : >"$1/$2"; }

@test "prune_daily_monthly keeps newest N daily plus the newest of each of M months" {
  d="$BATS_TEST_TMPDIR/p"; mkdir -p "$d"
  for f in daily-20260701-040000 daily-20260702-040000 daily-20260801-040000 \
           daily-20260815-040000 daily-20260920-040000 daily-20260921-040000 \
           daily-20260922-040000; do mk "$d" "$f.tar.age"; done
  bk_prune_daily_monthly "$d" daily 2 2
  run ls "$d"
  # newest 2 daily (0921, 0922) + newest of the 2 newest months (Sep=0922 already kept, Aug=0815)
  [[ "$output" == *"daily-20260922-040000.tar.age"* ]]
  [[ "$output" == *"daily-20260921-040000.tar.age"* ]]
  [[ "$output" == *"daily-20260815-040000.tar.age"* ]]
  [[ "$output" != *"daily-20260701-040000.tar.age"* ]]
  [[ "$output" != *"daily-20260702-040000.tar.age"* ]]
  [[ "$output" != *"daily-20260801-040000.tar.age"* ]]
  [[ "$output" != *"daily-20260920-040000.tar.age"* ]]
}

@test "prune_daily_monthly deletes nothing on an empty directory" {
  d="$BATS_TEST_TMPDIR/e"; mkdir -p "$d"
  run bk_prune_daily_monthly "$d" daily 30 12
  [ "$status" -eq 0 ]
}

@test "prune_daily_monthly never touches non-matching files and keeps everything when under the limit" {
  d="$BATS_TEST_TMPDIR/n"; mkdir -p "$d"
  mk "$d" notes.txt; mk "$d" daily-20260901-040000.tar.age.partial
  mk "$d" daily-20260901-040000.tar.age
  bk_prune_daily_monthly "$d" daily 30 12
  [ -e "$d/notes.txt" ]
  [ -e "$d/daily-20260901-040000.tar.age.partial" ]
  [ -e "$d/daily-20260901-040000.tar.age" ]
}

@test "prune_keep_newest keeps the newest N per prefix and ignores other prefixes" {
  d="$BATS_TEST_TMPDIR/w"; mkdir -p "$d"
  for f in vm101-20260901-020000 vm101-20260908-020000 vm101-20260915-020000 vm101-20260922-020000 vm102-20260901-020000; do
    mk "$d" "$f.vma.zst.age"; done
  bk_prune_keep_newest "$d" vm101 3
  [ ! -e "$d/vm101-20260901-020000.vma.zst.age" ]
  [ -e "$d/vm101-20260922-020000.vma.zst.age" ]
  [ -e "$d/vm101-20260915-020000.vma.zst.age" ]
  [ -e "$d/vm101-20260908-020000.vma.zst.age" ]
  [ -e "$d/vm102-20260901-020000.vma.zst.age" ]
}

@test "prune_remote deletes exactly the names local pruning would drop" {
  stub rclone '
    case "$1" in
      lsf) printf "daily-20260701-040000.tar.age\ndaily-20260921-040000.tar.age\ndaily-20260922-040000.tar.age\n" ;;
      deletefile) : ;;
    esac'
  run bk_prune_remote "onedrive-crypt:r740" daily 2 1
  [ "$status" -eq 0 ]
  grep -q "deletefile onedrive-crypt:r740/daily-20260701-040000.tar.age" "$BATS_TEST_TMPDIR/rclone.calls"
  run grep "deletefile onedrive-crypt:r740/daily-2026092" "$BATS_TEST_TMPDIR/rclone.calls"
  [ "$status" -ne 0 ]
}

@test "state_touch then state_age_seconds is small; a missing tier is huge" {
  bk_state_touch daily
  age="$(bk_state_age_seconds daily)"
  [ "$age" -lt 5 ]
  age="$(bk_state_age_seconds weekly)"
  [ "$age" -gt 100000000 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/backup/common.bats`
Expected: FAIL — `scripts/backup-common.sh: No such file or directory` on every test.

- [ ] **Step 3: Write the implementation**

```bash file=scripts/backup-common.sh
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
    -e 's#(https://discord(app)?\.com/api/webhooks/)[^[:space:]"]+#\1[REDACTED]#g' \
    -e 's#(AGE-SECRET-KEY-)[A-Z0-9]+#\1[REDACTED]#g' \
    -e 's#((password|token|secret)[=:][[:space:]]*)[^[:space:]]+#\1[REDACTED]#Ig'
}

bk_log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | bk_redact
}

# Post a message to the Discord webhook. Never fails the caller.
bk_notify() {
  local msg="$1" url payload
  if [ -z "${BK_DISCORD_WEBHOOK_FILE:-}" ] || [ ! -r "$BK_DISCORD_WEBHOOK_FILE" ]; then
    bk_log "notify skipped (no webhook file)"
    return 0
  fi
  url="$(cat "$BK_DISCORD_WEBHOOK_FILE")"
  payload="$(jq -n --arg c "$msg" '{content:$c}')"
  if ! curl -sS -m 10 -H 'Content-Type: application/json' -d "$payload" "$url" >/dev/null 2>&1; then
    bk_log "notify failed (ignored)"
  fi
  return 0
}

# Exclusive per-name lock; the lock is held for the life of the calling shell.
bk_lock() {
  mkdir -p "$BK_STATE_DIR"
  exec 9>"$BK_STATE_DIR/$1.lock"
  if ! flock -n 9; then
    bk_log "another '$1' run holds the lock; exiting"
    return 1
  fi
}

bk_require_free_gb() {
  local dir="$1" need="$2" avail
  avail="$(df -BG --output=avail "$dir" | tail -n 1 | tr -dc '0-9')"
  if [ -z "$avail" ] || [ "$avail" -lt "$need" ]; then
    bk_log "insufficient free space in $dir: ${avail:-?}GB free, ${need}GB required"
    return 1
  fi
}

# Refuse to write into an unmounted mountpoint (it would fill the local disk).
bk_require_mounted() {
  if ! mountpoint -q "$1"; then
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

# Keep the newest KEEP_DAILY files plus the newest file of each of the newest
# KEEP_MONTHLY calendar months. Only touches PREFIX-YYYYMMDD-HHMMSS*.tar.age.
bk_prune_daily_monthly() {
  local dir="$1" prefix="$2" keep_daily="$3" keep_monthly="$4"
  local -a files=()
  local base ym months=" " mcount=0 n=0 keep_it f
  while IFS= read -r f; do
    files+=("$f")
  done < <(find "$dir" -maxdepth 1 -type f -name "${prefix}-[0-9]*.tar.age" -printf '%f\n' | sort -r)
  [ "${#files[@]}" -gt 0 ] || return 0
  for base in "${files[@]}"; do
    ym="$(printf '%s' "$base" | sed -nE "s/^${prefix}-([0-9]{6})[0-9]{2}-[0-9]{6}\.tar\.age$/\1/p")"
    [ -n "$ym" ] || continue
    n=$((n + 1))
    keep_it=0
    [ "$n" -le "$keep_daily" ] && keep_it=1
    if [[ "$months" != *" $ym "* ]]; then
      months="$months$ym "
      mcount=$((mcount + 1))
      [ "$mcount" -le "$keep_monthly" ] && keep_it=1
    fi
    [ "$keep_it" -eq 1 ] || rm -f -- "$dir/$base"
  done
}

# Keep the newest KEEP files whose name starts with PREFIX- (any extension).
bk_prune_keep_newest() {
  local dir="$1" prefix="$2" keep="$3" f n=0
  while IFS= read -r f; do
    n=$((n + 1))
    [ "$n" -le "$keep" ] || rm -f -- "$dir/$f"
  done < <(find "$dir" -maxdepth 1 -type f -name "${prefix}-[0-9]*.age" -printf '%f\n' | sort -r)
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
  for name in "${before[@]}"; do
    [ -e "$tmp/$name" ] || rclone deletefile "$remote/$name"
  done
  rm -rf "$tmp"
}

bk_state_touch() {
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/backup/common.bats && shellcheck -S warning scripts/backup-common.sh`
Expected: all tests `ok`; shellcheck prints nothing.

- [ ] **Step 5: Commit**

```bash
git add scripts/backup-common.sh tests/backup/helper.bash tests/backup/common.bats
git commit -m "feat(backup): common library with encryption, retention, locking and redaction"
```

---

### Task 2: Key and config initialisation

**Files:**
- Create: `scripts/backup-init-keys.sh`
- Create: `backup.env.example`
- Create: `tests/backup/init-keys.bats`

**Interfaces:**
- Consumes: `bk_log` from Task 1.
- Produces: `$BK_CONFIG_DIR/age.key` (0600), `$BK_CONFIG_DIR/backup.env` (0600) containing `BK_AGE_RECIPIENT`, `BK_AGE_IDENTITY`; refuses to overwrite an existing key.

- [ ] **Step 1: Write the failing test**

```bash file=tests/backup/init-keys.bats
#!/usr/bin/env bats
load helper

setup() { setup_env; }

@test "init-keys creates a 0600 key, a 0700 dir and a config with the recipient" {
  run bash "$REPO_ROOT/scripts/backup-init-keys.sh"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$BK_CONFIG_DIR/age.key")" = "600" ]
  [ "$(stat -c %a "$BK_CONFIG_DIR")" = "700" ]
  [ "$(stat -c %a "$BK_CONFIG_DIR/backup.env")" = "600" ]
  grep -q '^BK_AGE_RECIPIENT=age1' "$BK_CONFIG_DIR/backup.env"
}

@test "init-keys never prints the private key" {
  run bash "$REPO_ROOT/scripts/backup-init-keys.sh"
  [[ "$output" != *"AGE-SECRET-KEY"* ]]
}

@test "init-keys refuses to overwrite an existing key" {
  bash "$REPO_ROOT/scripts/backup-init-keys.sh" >/dev/null
  before="$(sha256sum "$BK_CONFIG_DIR/age.key")"
  run bash "$REPO_ROOT/scripts/backup-init-keys.sh"
  [ "$status" -eq 1 ]
  [ "$before" = "$(sha256sum "$BK_CONFIG_DIR/age.key")" ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/backup/init-keys.bats`
Expected: FAIL — script not found.

- [ ] **Step 3: Write the implementation and the config template**

```bash file=scripts/backup-init-keys.sh
#!/usr/bin/env bash
# =============================================================================
# backup-init-keys.sh -- ONE-TIME setup: create the age keypair and a config
# skeleton under /root/.config/r740-backup/ (never inside a repo).
#
# RUN THIS: on the Proxmox host as root.
# AFTER:    copy the private key (age.key) to a SECOND place you control (a
#           password manager). If both copies are lost, every backup is
#           unrecoverable.
# =============================================================================
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
. "$here/backup-common.sh"

umask 077
mkdir -p "$BK_CONFIG_DIR"
chmod 700 "$BK_CONFIG_DIR"

key="$BK_CONFIG_DIR/age.key"
if [ -e "$key" ]; then
  bk_log "refusing to overwrite existing key: $key"
  exit 1
fi

age-keygen -o "$key" 2>/dev/null
chmod 600 "$key"
recipient="$(age-keygen -y "$key")"

cfg="$BK_CONFIG_DIR/backup.env"
if [ ! -e "$cfg" ]; then
  cp "$here/../backup.env.example" "$cfg"
  chmod 600 "$cfg"
fi
sed -i -E "s#^BK_AGE_RECIPIENT=.*#BK_AGE_RECIPIENT=$recipient#; s#^BK_AGE_IDENTITY=.*#BK_AGE_IDENTITY=$key#" "$cfg"

bk_log "created $key (mode 600) and $cfg"
bk_log "public recipient: $recipient"
bk_log "NEXT: copy $key to a second location you control. Losing every copy makes all backups unrecoverable."
```

```bash file=backup.env.example
# Copy to /root/.config/r740-backup/backup.env (mode 0600). No secrets belong in
# this template; secret values live in their own root-only files referenced below.

# --- encryption (filled in by scripts/backup-init-keys.sh) ---
BK_AGE_RECIPIENT=
BK_AGE_IDENTITY=

# --- local paths ---
BK_STAGE_DIR=/mnt/backup-stage
BK_STATE_DIR=/var/lib/r740-backup

# --- second-machine target (SMB share mounted on the host) ---
BK_SMB_MOUNT=/mnt/desktop-backup

# --- off-site target (rclone crypt remote wrapping OneDrive) ---
BK_RCLONE_REMOTE=onedrive-crypt:r740

# --- what to back up ---
BK_PROD_SSH=dune@192.168.20.10
BK_PROD_REPO=dune-awakening-selfhost-docker
BK_DEV_SSH=dune@192.168.21.10
BK_HOST_PATHS="etc/pve etc/network/interfaces etc/hosts etc/hostname etc/cloudflared etc/vzdump.conf"
BK_VMIDS="101 102 103 104"
BK_KEEP_WEEKLY_DEFAULT=3
BK_KEEP_WEEKLY_102=1

# --- alerting: file containing the Discord webhook URL, mode 0600 ---
BK_DISCORD_WEBHOOK_FILE=/root/.config/r740-backup/discord-webhook
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/backup/init-keys.bats && shellcheck -S warning scripts/backup-init-keys.sh`
Expected: 3 tests `ok`; shellcheck clean.

- [ ] **Step 5: Commit**

```bash
git add scripts/backup-init-keys.sh backup.env.example tests/backup/init-keys.bats
git commit -m "feat(backup): one-time age key and config initialisation"
```

---

### Task 3: Daily tier

**Files:**
- Create: `scripts/backup-daily.sh`
- Create: `tests/backup/daily.bats`

**Interfaces:**
- Consumes: everything from Task 1; config keys from `backup.env.example`.
- Produces: `daily-YYYYMMDD-HHMMSS.tar.age` in `$BK_SMB_MOUNT/daily/` and at `$BK_RCLONE_REMOTE`; calls `bk_state_touch daily` only when every step succeeded.
- Tar layout inside the archive: `prod/` (from dune-prod: `runtime/backups/db`, `runtime/secrets`, `.env`) and `host/` (from `$BK_HOST_PATHS`).

- [ ] **Step 1: Write the failing tests**

```bash file=tests/backup/daily.bats
#!/usr/bin/env bats
load helper

setup() {
  setup_env
  make_age_key
  export BK_SMB_MOUNT="$BATS_TEST_TMPDIR/smb"
  mkdir -p "$BK_SMB_MOUNT"
  cat >"$BK_CONFIG_DIR/backup.env" <<EOF
BK_AGE_RECIPIENT=$BK_AGE_RECIPIENT
BK_AGE_IDENTITY=$BK_AGE_IDENTITY
BK_STAGE_DIR=$BK_STAGE_DIR
BK_STATE_DIR=$BK_STATE_DIR
BK_SMB_MOUNT=$BK_SMB_MOUNT
BK_RCLONE_REMOTE=fake:r740
BK_PROD_SSH=dune@prod.test
BK_PROD_REPO=repo
BK_HOST_PATHS="etc/hostname"
BK_DISCORD_WEBHOOK_FILE=
BK_MIN_STAGE_GB=0
EOF
  # ssh stub: emit a small tar stream like the real remote `tar -cf -`
  mkdir -p "$BATS_TEST_TMPDIR/remote/runtime/backups/db" "$BATS_TEST_TMPDIR/remote/runtime/secrets"
  echo dump >"$BATS_TEST_TMPDIR/remote/runtime/backups/db/x.backup"
  echo s3cret >"$BATS_TEST_TMPDIR/remote/runtime/secrets/funcom-token.txt"
  stub ssh "tar -C '$BATS_TEST_TMPDIR/remote' -cf - runtime/backups/db runtime/secrets"
  stub rclone 'case "$1" in lsf) : ;; esac'
  stub mountpoint 'exit 0'
}

@test "daily writes an encrypted archive to the SMB share and uploads it" {
  run bash "$REPO_ROOT/scripts/backup-daily.sh"
  [ "$status" -eq 0 ]
  f="$(ls "$BK_SMB_MOUNT"/daily/daily-*.tar.age)"
  [ -n "$f" ]
  grep -q "copyto" "$BATS_TEST_TMPDIR/rclone.calls"
  # decrypts and contains prod + host trees
  run bash -c "age -d -i '$BK_AGE_IDENTITY' '$f' | tar -tf -"
  [[ "$output" == *"prod/runtime/backups/db/x.backup"* ]]
  [[ "$output" == *"prod/runtime/secrets/funcom-token.txt"* ]]
  [[ "$output" == *"host/etc/hostname"* ]]
}

@test "daily leaves no plaintext or partial files in staging" {
  bash "$REPO_ROOT/scripts/backup-daily.sh"
  run bash -c "ls -A '$BK_STAGE_DIR' | wc -l"
  [ "$output" = "0" ]
}

@test "daily records success only after everything worked" {
  bash "$REPO_ROOT/scripts/backup-daily.sh"
  [ -s "$BK_STATE_DIR/last-success-daily" ]
}

@test "daily aborts and records nothing when the SMB share is not mounted" {
  stub mountpoint 'exit 1'
  run bash "$REPO_ROOT/scripts/backup-daily.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$BK_STATE_DIR/last-success-daily" ]
  [ ! -d "$BK_SMB_MOUNT/daily" ]
}

@test "daily fails closed with no recipient and writes nothing" {
  sed -i 's#^BK_AGE_RECIPIENT=.*#BK_AGE_RECIPIENT=#' "$BK_CONFIG_DIR/backup.env"
  run bash "$REPO_ROOT/scripts/backup-daily.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$BK_STATE_DIR/last-success-daily" ]
  run bash -c "ls '$BK_SMB_MOUNT'/daily 2>/dev/null | wc -l"
  [ "$output" = "0" ]
}

@test "daily fails and records nothing when the prod ssh fetch fails" {
  stub ssh 'exit 255'
  run bash "$REPO_ROOT/scripts/backup-daily.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$BK_STATE_DIR/last-success-daily" ]
}

@test "daily fails and records nothing when the upload fails" {
  stub rclone 'case "$1" in copyto) exit 1 ;; esac'
  run bash "$REPO_ROOT/scripts/backup-daily.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$BK_STATE_DIR/last-success-daily" ]
}

@test "daily output never contains the secret file contents" {
  run bash "$REPO_ROOT/scripts/backup-daily.sh"
  [[ "$output" != *"s3cret"* ]]
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/backup/daily.bats`
Expected: FAIL — `scripts/backup-daily.sh` not found.

- [ ] **Step 3: Write the implementation**

```bash file=scripts/backup-daily.sh
#!/usr/bin/env bash
# =============================================================================
# backup-daily.sh -- daily tier: game DB backups + secrets + host config,
# age-encrypted, copied to the SMB share and to OneDrive (rclone crypt).
#
# RUN THIS: on the Proxmox host as root, from the r740-backup-daily.timer.
# =============================================================================
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
. "$here/backup-common.sh"
bk_load_config

fail() {
  bk_log "FAILED: $*"
  bk_notify "r740 daily backup FAILED: $*"
  exit 1
}

bk_lock daily || exit 1

stamp="$(date -u +%Y%m%d-%H%M%S)"
name="daily-$stamp.tar.age"
work=""
cleanup() { [ -z "$work" ] || rm -rf "$work"; }
trap cleanup EXIT

bk_require_mounted "$BK_SMB_MOUNT" || fail "SMB share not mounted at $BK_SMB_MOUNT"
bk_require_free_gb "$BK_STAGE_DIR" "${BK_MIN_STAGE_GB:-2}" || fail "not enough staging space"
work="$(mktemp -d "$BK_STAGE_DIR/daily.XXXXXX")"
mkdir -p "$work/prod" "$work/host"

# 1. dune-prod: DB backups, secrets, .env (streamed as tar over ssh)
ssh -o BatchMode=yes -o ConnectTimeout=15 \
  -o UserKnownHostsFile="$BK_CONFIG_DIR/known_hosts" -o StrictHostKeyChecking=accept-new \
  "$BK_PROD_SSH" \
  "cd ~/$BK_PROD_REPO && tar -cf - runtime/backups/db runtime/secrets .env" \
  | tar -xf - -C "$work/prod" || fail "could not fetch backups from $BK_PROD_SSH"

# 2. host config (missing optional paths are tolerated)
# shellcheck disable=SC2086
tar -C / -cf - $BK_HOST_PATHS 2>/dev/null | tar -xf - -C "$work/host" || true

# 3. bundle + encrypt
tar -C "$work" -cf "$work/bundle.tar" prod host || fail "could not create bundle"
bk_age_encrypt "$work/bundle.tar" "$work/$name" || fail "encryption failed"
rm -f "$work/bundle.tar"

# 4. SMB share
mkdir -p "$BK_SMB_MOUNT/daily"
cp -f -- "$work/$name" "$BK_SMB_MOUNT/daily/$name.partial" || fail "copy to SMB failed"
mv -f -- "$BK_SMB_MOUNT/daily/$name.partial" "$BK_SMB_MOUNT/daily/$name"

# 5. OneDrive (rclone crypt)
rclone copyto "$work/$name" "$BK_RCLONE_REMOTE/$name" || fail "upload to $BK_RCLONE_REMOTE failed"

# 6. retention
bk_prune_daily_monthly "$BK_SMB_MOUNT/daily" daily 30 12
bk_prune_remote "$BK_RCLONE_REMOTE" daily 30 12

bk_state_touch daily
bk_log "daily backup OK: $name"
bk_notify "r740 daily backup OK: $name"
```

- [ ] **Step 4: Run to verify they pass**

Run: `bats tests/backup/daily.bats && shellcheck -S warning scripts/backup-daily.sh`
Expected: 8 tests `ok`; shellcheck clean.

- [ ] **Step 5: Commit**

```bash
git add scripts/backup-daily.sh tests/backup/daily.bats
git commit -m "feat(backup): daily tier to SMB share and OneDrive"
```

---

### Task 4: Weekly VM image tier

**Files:**
- Create: `scripts/backup-weekly.sh`
- Create: `tests/backup/weekly.bats`

**Interfaces:**
- Consumes: Task 1 library; `BK_VMIDS`, `BK_KEEP_WEEKLY_DEFAULT`, `BK_KEEP_WEEKLY_<vmid>`.
- Produces: `vm<ID>-YYYYMMDD-HHMMSS.vma.zst.age` (or `.tar.zst.age` for a container) in `$BK_SMB_MOUNT/vm/`; `bk_state_touch weekly` only when every VMID succeeded.

- [ ] **Step 1: Write the failing tests**

```bash file=tests/backup/weekly.bats
#!/usr/bin/env bats
load helper

setup() {
  setup_env
  make_age_key
  export BK_SMB_MOUNT="$BATS_TEST_TMPDIR/smb"
  mkdir -p "$BK_SMB_MOUNT"
  cat >"$BK_CONFIG_DIR/backup.env" <<EOF
BK_AGE_RECIPIENT=$BK_AGE_RECIPIENT
BK_STAGE_DIR=$BK_STAGE_DIR
BK_STATE_DIR=$BK_STATE_DIR
BK_SMB_MOUNT=$BK_SMB_MOUNT
BK_VMIDS="101 104"
BK_KEEP_WEEKLY_DEFAULT=3
BK_KEEP_WEEKLY_102=1
BK_DISCORD_WEBHOOK_FILE=
BK_MIN_STAGE_GB=0
EOF
  # vzdump stub: create a fake dump in --dumpdir like the real tool
  stub vzdump '
    id="$1"; dir=""
    while [ $# -gt 0 ]; do [ "$1" = "--dumpdir" ] && dir="$2"; shift; done
    case "$id" in
      104) echo ct >"$dir/vzdump-lxc-104-2026_09_29-02_30_00.tar.zst" ;;
      *)   echo vm >"$dir/vzdump-qemu-$id-2026_09_29-02_30_00.vma.zst" ;;
    esac'
  stub qm 'exit 0'
  stub mountpoint 'exit 0'
}

@test "weekly encrypts one image per id into the share and clears staging" {
  run bash "$REPO_ROOT/scripts/backup-weekly.sh"
  [ "$status" -eq 0 ]
  ls "$BK_SMB_MOUNT"/vm/vm101-*.vma.zst.age
  ls "$BK_SMB_MOUNT"/vm/vm104-*.tar.zst.age
  run bash -c "ls -A '$BK_STAGE_DIR' | wc -l"
  [ "$output" = "0" ]
  [ -s "$BK_STATE_DIR/last-success-weekly" ]
}

@test "weekly images decrypt back to the original bytes" {
  bash "$REPO_ROOT/scripts/backup-weekly.sh"
  f="$(ls "$BK_SMB_MOUNT"/vm/vm101-*.age)"
  run age -d -i "$BK_AGE_IDENTITY" "$f"
  [ "$output" = "vm" ]
}

@test "weekly aborts and writes nothing when the share is not mounted" {
  stub mountpoint 'exit 1'
  run bash "$REPO_ROOT/scripts/backup-weekly.sh"
  [ "$status" -ne 0 ]
  [ ! -d "$BK_SMB_MOUNT/vm" ]
  [ ! -e "$BK_STATE_DIR/last-success-weekly" ]
  [ ! -s "$BATS_TEST_TMPDIR/vzdump.calls" ]
}

@test "weekly does not record success when one vzdump fails, but still tries the others" {
  stub vzdump '
    id="$1"; dir=""
    while [ $# -gt 0 ]; do [ "$1" = "--dumpdir" ] && dir="$2"; shift; done
    [ "$id" = "101" ] && exit 1
    echo ct >"$dir/vzdump-lxc-$id-2026_09_29-02_30_00.tar.zst"'
  run bash "$REPO_ROOT/scripts/backup-weekly.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$BK_STATE_DIR/last-success-weekly" ]
  ls "$BK_SMB_MOUNT"/vm/vm104-*.age
}

@test "weekly retention keeps the newest 3 per vm and 1 for vm 102" {
  mkdir -p "$BK_SMB_MOUNT/vm"
  for d in 20260901 20260908 20260915 20260922; do : >"$BK_SMB_MOUNT/vm/vm101-$d-020000.vma.zst.age"; done
  bash "$REPO_ROOT/scripts/backup-weekly.sh"
  n="$(ls "$BK_SMB_MOUNT"/vm/vm101-*.age | wc -l)"
  [ "$n" -eq 3 ]
}

@test "weekly leaves a failed encryption with no partial output" {
  sed -i 's#^BK_AGE_RECIPIENT=.*#BK_AGE_RECIPIENT=#' "$BK_CONFIG_DIR/backup.env"
  run bash "$REPO_ROOT/scripts/backup-weekly.sh"
  [ "$status" -ne 0 ]
  run bash -c "ls '$BK_SMB_MOUNT'/vm 2>/dev/null | wc -l"
  [ "$output" = "0" ]
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/backup/weekly.bats`
Expected: FAIL — script not found.

- [ ] **Step 3: Write the implementation**

```bash file=scripts/backup-weekly.sh
#!/usr/bin/env bash
# =============================================================================
# backup-weekly.sh -- weekly tier: vzdump every VM/CT in BK_VMIDS, age-encrypt,
# move to the SMB share, prune. One id failing does not stop the others, but
# the tier is only marked successful when every id succeeded.
#
# RUN THIS: on the Proxmox host as root, from the r740-backup-weekly.timer.
# =============================================================================
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
. "$here/backup-common.sh"
bk_load_config

bk_lock weekly || exit 1

failures=()
note_fail() { failures+=("$1"); bk_log "FAILED: $1"; }

if ! bk_require_mounted "$BK_SMB_MOUNT"; then
  bk_notify "r740 weekly backup FAILED: SMB share not mounted at $BK_SMB_MOUNT"
  exit 1
fi
mkdir -p "$BK_SMB_MOUNT/vm"
stamp="$(date -u +%Y%m%d-%H%M%S)"

for id in $BK_VMIDS; do
  keep_var="BK_KEEP_WEEKLY_$id"
  keep="${!keep_var:-${BK_KEEP_WEEKLY_DEFAULT:-3}}"

  if ! bk_require_free_gb "$BK_STAGE_DIR" "${BK_MIN_STAGE_GB:-100}"; then
    note_fail "vm$id: not enough staging space"
    continue
  fi
  if qm status "$id" >/dev/null 2>&1 && ! qm agent "$id" ping >/dev/null 2>&1; then
    bk_log "warning: guest agent not running for $id; backup will be crash-consistent"
  fi

  work="$(mktemp -d "$BK_STAGE_DIR/weekly-$id.XXXXXX")"
  if ! vzdump "$id" --mode snapshot --compress zstd --dumpdir "$work" --quiet 1; then
    note_fail "vm$id: vzdump failed"
    rm -rf "$work"
    continue
  fi

  dump="$(find "$work" -maxdepth 1 -type f -name 'vzdump-*' ! -name '*.log' ! -name '*.notes' | head -n 1)"
  if [ -z "$dump" ]; then
    note_fail "vm$id: vzdump produced no file"
    rm -rf "$work"
    continue
  fi
  ext="${dump#*"$id"-????_??_??-??_??_??.}"
  out="$work/vm$id-$stamp.$ext.age"

  if ! bk_age_encrypt "$dump" "$out"; then
    note_fail "vm$id: encryption failed"
    rm -rf "$work"
    continue
  fi
  rm -f "$dump"

  dest="$BK_SMB_MOUNT/vm/$(basename "$out")"
  if cp -f -- "$out" "$dest.partial" && mv -f -- "$dest.partial" "$dest"; then
    bk_prune_keep_newest "$BK_SMB_MOUNT/vm" "vm$id" "$keep"
    bk_log "vm$id OK: $(basename "$dest")"
  else
    rm -f -- "$dest.partial"
    note_fail "vm$id: copy to SMB failed"
  fi
  rm -rf "$work"
done

if [ "${#failures[@]}" -gt 0 ]; then
  bk_notify "r740 weekly backup FAILED: ${failures[*]}"
  exit 1
fi

bk_state_touch weekly
bk_notify "r740 weekly backup OK: $BK_VMIDS"
bk_log "weekly backup OK"
```

- [ ] **Step 4: Run to verify they pass**

Run: `bats tests/backup/weekly.bats && shellcheck -S warning scripts/backup-weekly.sh`
Expected: 6 tests `ok`; shellcheck clean.

- [ ] **Step 5: Commit**

```bash
git add scripts/backup-weekly.sh tests/backup/weekly.bats
git commit -m "feat(backup): weekly VM/CT image tier to the SMB share"
```

---

### Task 5: Staleness check

**Files:**
- Create: `scripts/backup-check.sh`
- Create: `tests/backup/check.bats`

**Interfaces:**
- Consumes: `bk_state_age_seconds`, `bk_notify`.
- Produces: exit 0 when both tiers are fresh (daily < 26h = 93600s, weekly < 8d = 691200s); exit 1 and a Discord alert naming the stale tier(s) otherwise. Thresholds overridable through `BK_DAILY_MAX_AGE` / `BK_WEEKLY_MAX_AGE` (seconds) for tests.

- [ ] **Step 1: Write the failing tests**

```bash file=tests/backup/check.bats
#!/usr/bin/env bats
load helper

setup() {
  setup_env
  printf 'BK_STATE_DIR=%s\nBK_DISCORD_WEBHOOK_FILE=\n' "$BK_STATE_DIR" >"$BK_CONFIG_DIR/backup.env"
}

@test "check passes when both tiers are fresh" {
  date +%s >"$BK_STATE_DIR/last-success-daily"
  date +%s >"$BK_STATE_DIR/last-success-weekly"
  run bash "$REPO_ROOT/scripts/backup-check.sh"
  [ "$status" -eq 0 ]
}

@test "check fails when the daily tier is older than 26 hours" {
  echo $(( $(date +%s) - 27*3600 )) >"$BK_STATE_DIR/last-success-daily"
  date +%s >"$BK_STATE_DIR/last-success-weekly"
  run bash "$REPO_ROOT/scripts/backup-check.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"daily"* ]]
}

@test "check fails when the weekly tier is older than 8 days" {
  date +%s >"$BK_STATE_DIR/last-success-daily"
  echo $(( $(date +%s) - 9*86400 )) >"$BK_STATE_DIR/last-success-weekly"
  run bash "$REPO_ROOT/scripts/backup-check.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"weekly"* ]]
}

@test "check fails when a tier has never succeeded" {
  run bash "$REPO_ROOT/scripts/backup-check.sh"
  [ "$status" -eq 1 ]
}

@test "check sends an alert when stale" {
  stub curl 'exit 0'
  printf 'https://discord.com/api/webhooks/1/x\n' >"$BK_CONFIG_DIR/hook"
  printf 'BK_STATE_DIR=%s\nBK_DISCORD_WEBHOOK_FILE=%s\n' "$BK_STATE_DIR" "$BK_CONFIG_DIR/hook" >"$BK_CONFIG_DIR/backup.env"
  run bash "$REPO_ROOT/scripts/backup-check.sh"
  [ "$status" -eq 1 ]
  grep -q "STALE" "$BATS_TEST_TMPDIR/curl.calls"
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/backup/check.bats`
Expected: FAIL — script not found.

- [ ] **Step 3: Write the implementation**

```bash file=scripts/backup-check.sh
#!/usr/bin/env bash
# =============================================================================
# backup-check.sh -- alarm if a backup tier has not succeeded recently.
# Catches a silently dead timer, which a per-run success alert cannot.
#
# RUN THIS: on the Proxmox host as root, hourly from r740-backup-check.timer.
# =============================================================================
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
. "$here/backup-common.sh"
bk_load_config

daily_max="${BK_DAILY_MAX_AGE:-93600}"     # 26 hours
weekly_max="${BK_WEEKLY_MAX_AGE:-691200}"  # 8 days

stale=()
d="$(bk_state_age_seconds daily)"
w="$(bk_state_age_seconds weekly)"
[ "$d" -le "$daily_max" ] || stale+=("daily (${d}s since last success, limit ${daily_max}s)")
[ "$w" -le "$weekly_max" ] || stale+=("weekly (${w}s since last success, limit ${weekly_max}s)")

if [ "${#stale[@]}" -gt 0 ]; then
  msg="r740 backup STALE: ${stale[*]}"
  bk_log "$msg"
  bk_notify "$msg"
  exit 1
fi
bk_log "backup freshness OK (daily ${d}s, weekly ${w}s)"
```

- [ ] **Step 4: Run to verify they pass**

Run: `bats tests/backup/check.bats && shellcheck -S warning scripts/backup-check.sh`
Expected: 5 tests `ok`; shellcheck clean.

- [ ] **Step 5: Commit**

```bash
git add scripts/backup-check.sh tests/backup/check.bats
git commit -m "feat(backup): staleness alarm for the daily and weekly tiers"
```

---

### Task 6: Restore test

**Files:**
- Create: `scripts/backup-restore-test.sh`
- Create: `tests/backup/restore-test.bats`

**Interfaces:**
- Consumes: Task 1 library; `BK_AGE_IDENTITY`, `BK_DEV_SSH`, `BK_SMB_MOUNT`.
- Produces: `backup-restore-test.sh db` and `backup-restore-test.sh vm`; each appends one line to `$BK_STATE_DIR/restore-tests.log` (`ISO-timestamp mode PASS|FAIL detail`), alerts on FAIL (a P1), exit 0/1.
- Safety: `db` mode only ever creates and drops a scratch database named `restore_test_<epoch>` on dune-dev's Postgres; `vm` mode only ever uses scratch VMID `BK_SCRATCH_VMID` (default 990) and aborts if that VMID already exists.

- [ ] **Step 1: Write the failing tests**

```bash file=tests/backup/restore-test.bats
#!/usr/bin/env bats
load helper

setup() {
  setup_env
  make_age_key
  export BK_SMB_MOUNT="$BATS_TEST_TMPDIR/smb"
  mkdir -p "$BK_SMB_MOUNT/daily" "$BK_SMB_MOUNT/vm"
  cat >"$BK_CONFIG_DIR/backup.env" <<EOF
BK_AGE_RECIPIENT=$BK_AGE_RECIPIENT
BK_AGE_IDENTITY=$BK_AGE_IDENTITY
BK_STAGE_DIR=$BK_STAGE_DIR
BK_STATE_DIR=$BK_STATE_DIR
BK_SMB_MOUNT=$BK_SMB_MOUNT
BK_DEV_SSH=dune@dev.test
BK_DISCORD_WEBHOOK_FILE=
BK_MIN_STAGE_GB=0
EOF
  # a real daily archive with a dump inside
  w="$BATS_TEST_TMPDIR/mk"; mkdir -p "$w/prod/runtime/backups/db" "$w/prod/runtime/secrets" "$w/host"
  echo dump >"$w/prod/runtime/backups/db/game-20260929-041500.backup"
  echo x >"$w/prod/runtime/secrets/funcom-token.txt"
  tar -C "$w" -cf "$w.tar" prod host
  age -r "$BK_AGE_RECIPIENT" -o "$BK_SMB_MOUNT/daily/daily-20260929-050000.tar.age" "$w.tar"
  stub mountpoint 'exit 0'
}

@test "db mode passes when pg_restore lists entries and the scratch restore works" {
  stub ssh '
    case "$*" in
      *"pg_restore --list"*) echo "; TOC Entries: 12"; exit 0 ;;
      *) exit 0 ;;
    esac'
  run bash "$REPO_ROOT/scripts/backup-restore-test.sh" db
  [ "$status" -eq 0 ]
  grep -q " db PASS" "$BK_STATE_DIR/restore-tests.log"
}

@test "db mode fails and logs FAIL when the dump cannot be listed" {
  stub ssh 'exit 1'
  run bash "$REPO_ROOT/scripts/backup-restore-test.sh" db
  [ "$status" -eq 1 ]
  grep -q " db FAIL" "$BK_STATE_DIR/restore-tests.log"
}

@test "db mode fails when no daily archive exists" {
  rm -f "$BK_SMB_MOUNT"/daily/*
  stub ssh 'exit 0'
  run bash "$REPO_ROOT/scripts/backup-restore-test.sh" db
  [ "$status" -eq 1 ]
  grep -q " db FAIL" "$BK_STATE_DIR/restore-tests.log"
}

@test "db mode always attempts to drop the scratch database, even when the restore fails" {
  stub ssh '
    case "$*" in
      *"pg_restore --list"*) echo "; TOC Entries: 12" ;;
      *"pg_restore -d"*) exit 1 ;;
    esac
    exit 0'
  run bash "$REPO_ROOT/scripts/backup-restore-test.sh" db
  [ "$status" -eq 1 ]
  grep -q "dropdb" "$BATS_TEST_TMPDIR/ssh.calls"
}

@test "vm mode refuses to run if the scratch VMID already exists" {
  ex="$BK_SMB_MOUNT/vm/vm102-20260929-020000.vma.zst.age"; : >"$ex"
  stub qm 'exit 0'   # 'qm status 990' succeeding means the id is taken
  stub qmrestore ':'
  run bash "$REPO_ROOT/scripts/backup-restore-test.sh" vm
  [ "$status" -eq 1 ]
  [ ! -s "$BATS_TEST_TMPDIR/qmrestore.calls" ]
}

@test "vm mode restores to the scratch id, isolates its network, then destroys it" {
  printf 'img' >"$BATS_TEST_TMPDIR/img"
  age -r "$BK_AGE_RECIPIENT" -o "$BK_SMB_MOUNT/vm/vm102-20260929-020000.vma.zst.age" "$BATS_TEST_TMPDIR/img"
  stub qm '
    case "$1 $2" in
      "status 990") [ -e "$BATS_TEST_TMPDIR/created" ] && { echo "status: running"; exit 0; } || exit 2 ;;
      "agent 990") exit 0 ;;
      *) exit 0 ;;
    esac'
  stub qmrestore 'touch "$BATS_TEST_TMPDIR/created"'
  run bash "$REPO_ROOT/scripts/backup-restore-test.sh" vm
  [ "$status" -eq 0 ]
  grep -q "990" "$BATS_TEST_TMPDIR/qmrestore.calls"
  grep -q -- "--unique 1" "$BATS_TEST_TMPDIR/qmrestore.calls"
  grep -q "tag=99" "$BATS_TEST_TMPDIR/qm.calls"
  grep -q "destroy 990" "$BATS_TEST_TMPDIR/qm.calls"
  grep -q " vm PASS" "$BK_STATE_DIR/restore-tests.log"
}

@test "rejects an unknown mode" {
  run bash "$REPO_ROOT/scripts/backup-restore-test.sh" bogus
  [ "$status" -eq 2 ]
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/backup/restore-test.bats`
Expected: FAIL — script not found.

- [ ] **Step 3: Write the implementation**

```bash file=scripts/backup-restore-test.sh
#!/usr/bin/env bash
# =============================================================================
# backup-restore-test.sh -- monthly restore test (Strict Requirement 25).
#
#   backup-restore-test.sh db   restore the newest daily archive's game DB dump
#                               into a scratch database on dune-dev, check it,
#                               drop it
#   backup-restore-test.sh vm   restore the newest dune-dev image to scratch
#                               VMID $BK_SCRATCH_VMID (default 990) on an
#                               isolated VLAN, confirm it boots, destroy it
#
# A FAIL is a P1: the backup is the recovery path.
# =============================================================================
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
. "$here/backup-common.sh"
bk_load_config

mode="${1:-}"
case "$mode" in db | vm) ;; *) echo "usage: $0 db|vm" >&2; exit 2 ;; esac

log_result() { # PASS|FAIL detail
  mkdir -p "$BK_STATE_DIR"
  printf '%s %s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$mode" "$1" "$2" | bk_redact >>"$BK_STATE_DIR/restore-tests.log"
  bk_log "restore test $mode $1: $2"
  if [ "$1" = "FAIL" ]; then
    bk_notify "P1: r740 restore test ($mode) FAILED: $2"
  else
    bk_notify "r740 restore test ($mode) passed: $2"
  fi
}
die() { log_result FAIL "$*"; exit 1; }

bk_lock "restore-$mode" || exit 1
work="$(mktemp -d "$BK_STAGE_DIR/restore.XXXXXX")"
scratch_db=""
scratch_created=0
cleanup() {
  if [ -n "$scratch_db" ]; then
    ssh -o BatchMode=yes "$BK_DEV_SSH" "docker exec dune-postgres dropdb -U postgres --if-exists $scratch_db" >/dev/null 2>&1 || true
  fi
  if [ "$scratch_created" -eq 1 ]; then
    qm stop "${BK_SCRATCH_VMID:-990}" >/dev/null 2>&1 || true
    qm destroy "${BK_SCRATCH_VMID:-990}" --purge 1 --destroy-unreferenced-disks 1 >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

bk_require_mounted "$BK_SMB_MOUNT" || die "SMB share not mounted"

if [ "$mode" = "db" ]; then
  archive="$(find "$BK_SMB_MOUNT/daily" -maxdepth 1 -type f -name 'daily-*.tar.age' -printf '%f\n' 2>/dev/null | sort -r | head -n 1)"
  [ -n "$archive" ] || die "no daily archive found"
  age -d -i "$BK_AGE_IDENTITY" -o "$work/bundle.tar" "$BK_SMB_MOUNT/daily/$archive" || die "cannot decrypt $archive"
  tar -xf "$work/bundle.tar" -C "$work" || die "cannot unpack $archive"
  dump="$(find "$work/prod/runtime/backups/db" -type f -name '*.backup' 2>/dev/null | sort | tail -n 1)"
  [ -n "$dump" ] || die "no .backup file inside $archive"

  ssh -o BatchMode=yes "$BK_DEV_SSH" "docker exec -i dune-postgres pg_restore --list" <"$dump" >"$work/toc.txt" \
    || die "pg_restore --list failed on $(basename "$dump")"
  grep -q 'TOC Entries' "$work/toc.txt" || die "no TOC entries in $(basename "$dump")"

  scratch_db="restore_test_$(date +%s)"
  ssh -o BatchMode=yes "$BK_DEV_SSH" "docker exec dune-postgres createdb -U postgres $scratch_db" || die "cannot create scratch database"
  ssh -o BatchMode=yes "$BK_DEV_SSH" "docker exec -i dune-postgres pg_restore -d $scratch_db -U postgres --no-owner --exit-on-error" <"$dump" \
    || die "restore into $scratch_db failed"
  log_result PASS "$archive -> $(basename "$dump") restored into $scratch_db and dropped"
  exit 0
fi

# ---- vm mode ----
scratch="${BK_SCRATCH_VMID:-990}"
if qm status "$scratch" >/dev/null 2>&1; then
  die "scratch VMID $scratch already exists; refusing to touch it"
fi
image="$(find "$BK_SMB_MOUNT/vm" -maxdepth 1 -type f -name 'vm102-*.age' -printf '%f\n' 2>/dev/null | sort -r | head -n 1)"
[ -n "$image" ] || die "no vm102 image found"
bk_require_free_gb "$BK_STAGE_DIR" "${BK_MIN_STAGE_GB:-100}" || die "not enough staging space"
plain="$work/${image%.age}"
age -d -i "$BK_AGE_IDENTITY" -o "$plain" "$BK_SMB_MOUNT/vm/$image" || die "cannot decrypt $image"

qmrestore "$plain" "$scratch" --storage local-lvm --unique 1 || die "qmrestore failed"
scratch_created=1
# Isolate: nonexistent VLAN tag 99, never autostart.
qm set "$scratch" --onboot 0 --net0 "e1000e,bridge=vmbr0,tag=99" >/dev/null || die "cannot isolate scratch VM"
qm start "$scratch" || die "scratch VM failed to start"
up=0
for _ in $(seq 1 60); do
  if qm agent "$scratch" ping >/dev/null 2>&1; then up=1; break; fi
  sleep 5
done
[ "$up" -eq 1 ] || die "scratch VM did not answer the guest agent within 5 minutes"
log_result PASS "$image restored to VMID $scratch, booted, destroyed"
```

- [ ] **Step 4: Run to verify they pass**

Run: `bats tests/backup/restore-test.bats && shellcheck -S warning scripts/backup-restore-test.sh`
Expected: 7 tests `ok`; shellcheck clean.

- [ ] **Step 5: Commit**

```bash
git add scripts/backup-restore-test.sh tests/backup/restore-test.bats
git commit -m "feat(backup): scripted monthly restore tests (db and vm)"
```

---

### Task 7: systemd units and CI

**Files:**
- Create: `scripts/backup-install-timers.sh`
- Create: `tests/backup/install-timers.bats`
- Modify: `.github/workflows/ci.yml` (add job `backup-tests`, add it to `ci-gate`)

**Interfaces:**
- Consumes: the four job scripts from Tasks 3–6 by absolute path (resolved from the script's own location, never hard-coded).
- Produces: `r740-backup-{daily,weekly,check,restore-db,restore-vm}.{service,timer}` in `$UNIT_DIR` (default `/etc/systemd/system`); `--no-enable` writes the files only.

- [ ] **Step 1: Write the failing test**

```bash file=tests/backup/install-timers.bats
#!/usr/bin/env bats
load helper

setup() {
  setup_env
  export UNIT_DIR="$BATS_TEST_TMPDIR/units"
  mkdir -p "$UNIT_DIR"
  stub systemctl 'exit 0'
}

@test "writes a service and a timer for each job with absolute ExecStart paths" {
  run bash "$REPO_ROOT/scripts/backup-install-timers.sh" --no-enable
  [ "$status" -eq 0 ]
  for j in daily weekly check restore-db restore-vm; do
    [ -f "$UNIT_DIR/r740-backup-$j.service" ]
    [ -f "$UNIT_DIR/r740-backup-$j.timer" ]
  done
  grep -q "^ExecStart=$REPO_ROOT/scripts/backup-daily.sh" "$UNIT_DIR/r740-backup-daily.service"
  grep -q "^ExecStart=$REPO_ROOT/scripts/backup-restore-test.sh vm" "$UNIT_DIR/r740-backup-restore-vm.service"
}

@test "every timer is Persistent so a missed run catches up" {
  bash "$REPO_ROOT/scripts/backup-install-timers.sh" --no-enable
  for t in "$UNIT_DIR"/r740-backup-*.timer; do
    grep -q '^Persistent=true' "$t"
  done
}

@test "daily runs after the 04:30 game db backup" {
  bash "$REPO_ROOT/scripts/backup-install-timers.sh" --no-enable
  grep -q '^OnCalendar=\*-\*-\* 05:15:00' "$UNIT_DIR/r740-backup-daily.timer"
}

@test "services are oneshot with low CPU and IO priority" {
  bash "$REPO_ROOT/scripts/backup-install-timers.sh" --no-enable
  grep -q '^Type=oneshot' "$UNIT_DIR/r740-backup-weekly.service"
  grep -q '^Nice=10' "$UNIT_DIR/r740-backup-weekly.service"
  grep -q '^IOSchedulingClass=idle' "$UNIT_DIR/r740-backup-weekly.service"
}

@test "without --no-enable it reloads systemd and enables each timer" {
  run bash "$REPO_ROOT/scripts/backup-install-timers.sh"
  [ "$status" -eq 0 ]
  grep -q "daemon-reload" "$BATS_TEST_TMPDIR/systemctl.calls"
  grep -q "enable --now r740-backup-daily.timer" "$BATS_TEST_TMPDIR/systemctl.calls"
}

@test "generated units pass systemd-analyze verify when available" {
  command -v systemd-analyze >/dev/null || skip "systemd-analyze not installed"
  bash "$REPO_ROOT/scripts/backup-install-timers.sh" --no-enable
  run systemd-analyze verify "$UNIT_DIR"/r740-backup-*.timer
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/backup/install-timers.bats`
Expected: FAIL — script not found.

- [ ] **Step 3: Write the installer**

```bash file=scripts/backup-install-timers.sh
#!/usr/bin/env bash
# =============================================================================
# backup-install-timers.sh -- write and enable the r740-backup systemd units.
#
# RUN THIS: on the Proxmox host as root, after backup.env exists.
# USAGE:    backup-install-timers.sh [--no-enable]
# =============================================================================
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unit_dir="${UNIT_DIR:-/etc/systemd/system}"
enable=1
[ "${1:-}" = "--no-enable" ] && enable=0

# job | script + args | OnCalendar | description
jobs=(
  "daily|$here/backup-daily.sh|*-*-* 05:15:00|daily encrypted DB, secrets and host config backup"
  "weekly|$here/backup-weekly.sh|Sun *-*-* 02:30:00|weekly VM and container image backup"
  "check|$here/backup-check.sh|hourly|backup freshness alarm"
  "restore-db|$here/backup-restore-test.sh db|Sat *-*-01..07 03:30:00|monthly database restore test"
  "restore-vm|$here/backup-restore-test.sh vm|Sat *-*-08..14 03:30:00|monthly VM restore test"
)

mkdir -p "$unit_dir"
for j in "${jobs[@]}"; do
  IFS='|' read -r name exec_line calendar desc <<<"$j"
  cat >"$unit_dir/r740-backup-$name.service" <<EOF
[Unit]
Description=R740 $desc
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$exec_line
Nice=10
IOSchedulingClass=idle
EOF
  cat >"$unit_dir/r740-backup-$name.timer" <<EOF
[Unit]
Description=Schedule: R740 $desc

[Timer]
OnCalendar=$calendar
Persistent=true
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
EOF
done

if [ "$enable" -eq 1 ]; then
  systemctl daemon-reload
  for j in "${jobs[@]}"; do
    IFS='|' read -r name _ <<<"$j"
    systemctl enable --now "r740-backup-$name.timer"
  done
fi
echo "installed r740-backup units in $unit_dir (enable=$enable)"
```

- [ ] **Step 4: Add the CI job**

Modify `.github/workflows/ci.yml`: insert this job immediately before `ci-gate:`, add `- backup-tests` to `ci-gate.needs`, add `BACKUP_TESTS: ${{ needs.backup-tests.result }}` to its `env:`, and add `"$BACKUP_TESTS"` to the `for result in ...` list.

```yaml
  backup-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install test tooling
        run: |
          sudo apt-get update
          sudo apt-get install -y bats age jq
      - name: Run backup tests
        run: bats tests/backup
```

- [ ] **Step 5: Run everything locally**

Run: `bats tests/backup && shellcheck -S warning scripts/*.sh tests/*.sh && for f in scripts/*.sh; do bash -n "$f"; done && bash tests/no-personal-identifiers.sh`
Expected: all bats tests `ok`; shellcheck, `bash -n` and the identifier guard print no errors.

- [ ] **Step 6: Commit**

```bash
git add scripts/backup-install-timers.sh tests/backup/install-timers.bats .github/workflows/ci.yml
git commit -m "feat(backup): systemd timers and CI job for the backup tests"
```

---

### Task 8: Runbook and docs

**Files:**
- Create: `docs/07-backup-runbook.md`
- Modify: `CHANGELOG.md` (Unreleased → Added)
- Modify: `README.md` (add the runbook to the docs list if one exists; otherwise skip and say so in the PR)

- [ ] **Step 1: Write the runbook** covering, with the exact commands from Tasks 1–7 and Task 9: what is backed up and when; where copies live; the key handling rule (two copies, loss is unrecoverable); how to restore the DB (decrypt with `age -d -i`, `tar -xf`, then the console's Restore UI or `dune db restore <file> --adopt-backup-battlegroup` for a new-host restore); how to restore a VM (`age -d`, `qmrestore <file> <vmid> --unique 1`, then reapply the network identity); what each alert means; and how to re-authorise OneDrive.
- [ ] **Step 2: Add the CHANGELOG entry** under `## Unreleased` → `### Added`: one bullet per script plus the CI job, referencing issue #119.
- [ ] **Step 3: Verify docs** — Run: `bash tests/no-personal-identifiers.sh` and the CI link check (`docs/*.md README.md` relative links). Expected: no findings, no broken links.
- [ ] **Step 4: Commit**

```bash
git add docs/07-backup-runbook.md CHANGELOG.md README.md
git commit -m "docs(backup): operator runbook and changelog"
```

---

### Task 9: Rollout on the host (operator-assisted, each step approved)

These steps change the live host and guests. Each needs the operator's go-ahead, and some need the operator's own action. Strict Requirement 7 applies: none of these stop the game server.

- [ ] **Step 1: Install and start the guest agent in each guest.** For each of dune-prod, dune-dev, acp-bot: `sudo apt-get install -y qemu-guest-agent && sudo systemctl enable --now qemu-guest-agent`. Verify on the host: `qm agent 101 ping` (repeat for 102, 103); expected exit 0. (CT 104 has no agent; LXC snapshots do not need one.)
- [ ] **Step 2: Install rclone on the host.** `apt-get install -y rclone`; verify `rclone version`.
- [ ] **Step 3: Create the SMB mount.** Operator supplies the share path and a dedicated backup-user credential. Write the credential to `/root/.config/r740-backup/smb-credentials` (mode 0600, lines `username=` and `password=`); add an `/etc/fstab` line with `credentials=/root/.config/r740-backup/smb-credentials,_netdev,x-systemd.automount,nofail,vers=3.0` mounting at `/mnt/desktop-backup`; `mount /mnt/desktop-backup && mountpoint /mnt/desktop-backup`. Expected: `is a mountpoint`.
- [ ] **Step 4: Create the size-capped staging volume.** Choose the size from the first measured image (start with 150GB): `lvcreate -V 150G -T pve/data -n backup-stage && mkfs.ext4 /dev/pve/backup-stage`, mount at `/mnt/backup-stage` via fstab. Verify `df -h /mnt/backup-stage`.
- [ ] **Step 5: Configure OneDrive.** Operator runs `rclone config` interactively (a one-time browser login) creating a `onedrive` remote, then a `onedrive-crypt` crypt remote over `onedrive:r740-backups` with the password stored by rclone. The rclone config file holds the OAuth token; keep `/root/.config/rclone/rclone.conf` mode 0600. Verify `rclone lsd onedrive-crypt:`.
- [ ] **Step 6: Run key/config init.** `bash scripts/backup-init-keys.sh`, then have the operator copy `/root/.config/r740-backup/age.key` into their password manager. Edit `backup.env` for the real paths; create `/root/.config/r740-backup/discord-webhook` (mode 0600) with the alert webhook URL.
- [ ] **Step 7: First manual daily run.** `bash scripts/backup-daily.sh`. Verify an encrypted file exists in both `/mnt/desktop-backup/daily/` and on `rclone lsf onedrive-crypt:`, and a Discord OK message arrived.
- [ ] **Step 8: First manual weekly run for one small guest, then all.** `BK_VMIDS=103 bash scripts/backup-weekly.sh`, then the full `bash scripts/backup-weekly.sh`. Record each image's real size; adjust `BK_KEEP_WEEKLY_*` and the staging volume from the measured sizes. Confirm the log shows a guest-agent freeze (`qm agent` ping succeeded).
- [ ] **Step 9: Enable the schedule.** `bash scripts/backup-install-timers.sh`; verify `systemctl list-timers 'r740-backup-*'` shows all five.
- [ ] **Step 10: First restore tests.** `bash scripts/backup-restore-test.sh db`, then `bash scripts/backup-restore-test.sh vm`. Expected: both log `PASS` in `/var/lib/r740-backup/restore-tests.log`. Keep the output as evidence on issue #119.
- [ ] **Step 11: Close out.** Update the meta README Live Systems section (backups now exist, where, cadence), update memory, comment on issue #119 with the evidence, and close it once the first scheduled daily and weekly runs have succeeded.

---

## Self-Review

- **Spec coverage:** daily tier (Task 3) ✔; weekly tier (Task 4) ✔; guest agent (Task 9 step 1) ✔; age encryption and two-copy key rule (Tasks 1, 2, 8) ✔; retention 30+12 / 3 / 1 (Tasks 1, 3, 4) ✔; staging cap and pre-flight (Tasks 1, 3, 4, 9 step 4) ✔; systemd timers with `Persistent=true` (Task 7) ✔; Discord alerts and 26h/8d alarms (Tasks 1, 5) ✔; monthly restore tests (Tasks 6, 7) ✔; redaction (Task 1) ✔; rollout order (Task 9) ✔; Layer 1 audit (Task 0) ✔. Deliberate deviation: the daily archive includes host config every day (superset of the spec's weekly host config), which costs almost nothing and tightens RPO.
- **Placeholder scan:** no TBD/TODO; Task 8's runbook is specified by content rather than pasted text because it is prose documentation, not code.
- **Type consistency:** function names and signatures in Tasks 3–7 match Task 1's Interfaces block (`bk_prune_daily_monthly DIR PREFIX KEEP_DAILY KEEP_MONTHLY`, `bk_prune_keep_newest DIR PREFIX KEEP`, `bk_prune_remote REMOTE PREFIX KEEP_DAILY KEEP_MONTHLY`, `bk_state_touch TIER`, `bk_state_age_seconds TIER`); config keys match `backup.env.example`.
- **Review Focus coverage:** unmounted share (Tasks 3, 4 tests) ✔; empty/garbled recipient (Tasks 1, 3, 4 tests) ✔; partial files (Task 1 `.partial` + Task 3 staging test) ✔; pruning safety (Task 1 tests) ✔; overlapping runs (Task 1 lock test) ✔; webhook down and secret leakage (Task 1 and Task 3 tests) ✔.
