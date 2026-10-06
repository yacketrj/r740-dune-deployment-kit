#!/usr/bin/env bash
# =============================================================================
# r740-backup-gate.sh -- restricted command gate for the R740 backup pull.
#
# INSTALLED ON: dune-prod (not the hypervisor), e.g. ~/bin/r740-backup-gate.sh.
# USED VIA:     a dedicated SSH key in ~/.ssh/authorized_keys, restricted so
#                 restrict,command="/home/dune/bin/r740-backup-gate.sh" ssh-ed25519 AAAA... r740-backup
#               The hypervisor then runs `ssh backup@dune-prod status` etc. and
#               can do nothing else: every request is parsed from
#               SSH_ORIGINAL_COMMAND and matched against the allow-list below.
#               No shell is ever evaluated on request text.
#
# Subcommands (all arguments are integers or fixed words):
#   status                          key=value facts about the newest dump
#   set MAX_AGE_H SINCE_H           tar of non-seed dump pairs from the last
#                                   SINCE_H hours (plus the newest automatic
#                                   dump), runtime/secrets, .env, and a
#                                   gate-manifest.txt. Refuses (exit 3, nothing
#                                   on stdout) unless the newest automatic dump
#                                   is younger than MAX_AGE_H, larger than the
#                                   size floor, complete (PGDMP header) and no
#                                   longer being written.
#   newest-db MAX_AGE_H SINCE_H     same, database pairs only (no secrets)
#   dump-now                        run `dune db backup` (one at a time)
#
# Selection rule: every *.backup with a *.backup.yaml sidecar EXCEPT those whose
# sidecar says backup_origin: market-bot-seed (a feature seed produced every 15
# minutes, not a restore point). The authoritative restore point is the newest
# backup_origin: automatic dump (the scheduled 04:30 job).
#
# Exit codes: 0 ok, 2 refused request, 3 gate not satisfied, 4 internal error.
# =============================================================================
set -euo pipefail

# The R740_GATE_* overrides exist only for the test suite. In production they are ignored
# (an SSH client or a permissive AcceptEnv/PermitUserEnvironment must never be able to
# swap the dune binary or weaken the freshness and size gates), and PATH is pinned.
# Never honoured on a real SSH session, whatever the client managed to put in the environment.
if [ "${R740_GATE_TEST_MODE:-}" = "1" ] && [ -z "${SSH_CONNECTION:-}" ]; then
  REPO="${R740_GATE_REPO:-$HOME/dune-awakening-selfhost-docker}"
  DUNE_CMD="${R740_GATE_DUNE:-$REPO/runtime/scripts/dune}"
  SIZE_FLOOR="${R740_GATE_SIZE_FLOOR:-1000000}"   # bytes
  SETTLE_SECONDS="${R740_GATE_SETTLE_SECONDS:-30}"
  NOW="${R740_GATE_NOW:-$(date +%s)}"
else
  export PATH=/usr/local/bin:/usr/bin:/bin
  REPO="$HOME/dune-awakening-selfhost-docker"
  DUNE_CMD="$REPO/runtime/scripts/dune"
  SIZE_FLOOR=1000000   # bytes
  SETTLE_SECONDS=30
  NOW="$(date +%s)"
fi
DB_DIR="$REPO/runtime/backups/db"

GATE_TMP=""
cleanup() { [ -z "$GATE_TMP" ] || rm -rf -- "$GATE_TMP"; }
trap cleanup EXIT

refuse() { echo "gate: refused: $*" >&2; exit 2; }
gate_fail() { echo "gate: not satisfied: $*" >&2; exit 3; }

origin_of() { # sidecar path -> backup_origin value
  awk '$1 == "backup_origin:" { print $2; exit }' "$1" 2>/dev/null || true
}

# Fixed integer arguments only.
int_arg() { # name value min max
  [[ "$2" =~ ^(0|[1-9][0-9]{0,3})$ ]] || refuse "$1 must be an integer without leading zeros"
  [ "$2" -ge "$3" ] && [ "$2" -le "$4" ] || refuse "$1 out of range ($3-$4)"
}

# Print "epoch<TAB>name" for every eligible pair (sidecar present, not a seed).
list_pairs() {
  local f y base origin mt
  shopt -s nullglob
  for f in "$DB_DIR"/*.backup; do
    y="$f.yaml"
    [ -f "$y" ] || continue
    origin="$(origin_of "$y")"
    [ "$origin" = "market-bot-seed" ] && continue
    mt="$(stat -c %Y -- "$f")"
    base="$(basename -- "$f")"
    printf '%s\t%s\t%s\n' "$mt" "$base" "$origin"
  done
}

newest_automatic() { # prints "epoch<TAB>name" or nothing
  list_pairs | awk -F'\t' '$3 == "automatic"' | sort -rn | sed -n 1p | cut -f1,2
}

check_gate() { # max_age_h ; sets AUTO_NAME, AUTO_EPOCH
  local max_age_h="$1" line size magic
  line="$(newest_automatic)"
  [ -n "$line" ] || gate_fail "no automatic dump found"
  AUTO_EPOCH="${line%%$'\t'*}"
  AUTO_NAME="${line#*$'\t'}"
  if [ $((NOW - AUTO_EPOCH)) -gt $((max_age_h * 3600)) ]; then
    gate_fail "newest automatic dump $AUTO_NAME is older than ${max_age_h}h"
  fi
  if [ $((NOW - AUTO_EPOCH)) -lt "$SETTLE_SECONDS" ]; then
    gate_fail "newest automatic dump $AUTO_NAME may still be being written"
  fi
  size="$(stat -c %s -- "$DB_DIR/$AUTO_NAME")"
  [ "$size" -ge "$SIZE_FLOOR" ] || gate_fail "newest automatic dump $AUTO_NAME is below the size floor ($size bytes)"
  magic="$(head -c 5 -- "$DB_DIR/$AUTO_NAME" 2>/dev/null || true)"
  [ "$magic" = "PGDMP" ] || gate_fail "newest automatic dump $AUTO_NAME does not have a PGDMP header"
}

select_pairs() { # since_h ; prints file names (dump + sidecar), newest automatic always included
  local since_h="$1" cutoff
  cutoff=$((NOW - since_h * 3600))
  {
    list_pairs | awk -F'\t' -v c="$cutoff" '$1 >= c { print $2 }'
    echo "$AUTO_NAME"
  } | sort -u | while IFS= read -r n; do
    [ -f "$DB_DIR/$n" ] || continue
    printf '%s\n%s\n' "runtime/backups/db/$n" "runtime/backups/db/$n.yaml"
  done
}

build_tar() { # include_secrets(0|1) max_age_h since_h
  local secrets="$1" max_age_h="$2" since_h="$3"
  check_gate "$max_age_h"
  GATE_TMP="$(mktemp -d)"
  local -a files=()
  while IFS= read -r f; do files+=("$f"); done < <(select_pairs "$since_h")
  {
    echo "authoritative=runtime/backups/db/$AUTO_NAME"
    echo "authoritative_epoch=$AUTO_EPOCH"
    echo "generated_epoch=$NOW"
    echo "since_hours=$since_h"
    echo "pair_files=$((${#files[@]}))"
  } >"$GATE_TMP/gate-manifest.txt"
  local -a extra=()
  if [ "$secrets" = "1" ]; then
    [ -d "$REPO/runtime/secrets" ] || gate_fail "runtime/secrets is missing"
    [ -f "$REPO/.env" ] || gate_fail ".env is missing"
    extra=(runtime/secrets .env)
  fi
  tar -cf - -C "$GATE_TMP" gate-manifest.txt -C "$REPO" "${files[@]}" "${extra[@]}"
}

cmd_status() {
  local line count
  line="$(newest_automatic || true)"
  count="$(list_pairs | wc -l)"
  echo "repo_present=$([ -d "$REPO" ] && echo 1 || echo 0)"
  echo "pairs_non_seed=$count"
  if [ -n "$line" ]; then
    echo "newest_automatic_epoch=${line%%$'\t'*}"
    echo "newest_automatic_name=${line#*$'\t'}"
    echo "newest_automatic_size=$(stat -c %s -- "$DB_DIR/${line#*$'\t'}")"
  else
    echo "newest_automatic_epoch=0"
  fi
  echo "now_epoch=$NOW"
}

cmd_dump_now() {
  local lock="$REPO/runtime/generated/.r740-backup-gate.lock"
  mkdir -p "$(dirname "$lock")"
  exec 8>"$lock"
  flock -n 8 || gate_fail "another dump is already running"
  "$DUNE_CMD" db backup >&2
  echo "dump-now: done"
}

# --- request parsing (never eval'd) -------------------------------------------
req="${SSH_ORIGINAL_COMMAND:-${*:-}}"
[ -n "$req" ] || refuse "no command"
[[ "$req" =~ ^[A-Za-z0-9\ -]+$ ]] || refuse "unexpected characters in request"
read -r -a words <<<"$req"
verb="${words[0]}"

case "$verb" in
  status)
    [ "${#words[@]}" -eq 1 ] || refuse "status takes no arguments"
    cmd_status
    ;;
  set | newest-db)
    [ "${#words[@]}" -eq 3 ] || refuse "$verb needs MAX_AGE_H SINCE_H"
    int_arg MAX_AGE_H "${words[1]}" 1 168
    int_arg SINCE_H "${words[2]}" 1 720
    if [ "$verb" = "set" ]; then build_tar 1 "${words[1]}" "${words[2]}"; else build_tar 0 "${words[1]}" "${words[2]}"; fi
    ;;
  dump-now)
    [ "${#words[@]}" -eq 1 ] || refuse "dump-now takes no arguments"
    cmd_dump_now
    ;;
  *)
    refuse "unknown command '$verb'"
    ;;
esac
