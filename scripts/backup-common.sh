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
