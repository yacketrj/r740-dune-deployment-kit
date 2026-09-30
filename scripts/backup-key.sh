#!/usr/bin/env bash
# =============================================================================
# backup-key.sh -- age key tooling for the backup system (design v2, theme T1).
#
# The host holds ONLY the age public key (recipient). The private key is needed
# solely to restore, so it lives off the host: in the operator's password
# manager plus a second escrow. This script never prints the private key and
# never leaves it on the host.
#
#   backup-key.sh generate --handoff-dir DIR   create a keypair in RAM, write
#       only the recipient to backup.env, copy the private key to DIR (the
#       desktop share) for the operator to move into the password manager,
#       then shred the RAM copy.
#   backup-key.sh verify --identity FILE       prove escrow: encrypt a canary
#       to the configured recipient and decrypt it with the supplied identity.
#       The identity is used, never stored. Logs "escrow verified".
#   backup-key.sh fingerprint                  show recipient, creation date and
#       the last verified escrow date.
#
# RUN THIS: on the Proxmox host as root.
# =============================================================================
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
. "$here/backup-common.sh"
bk_secure_umask

usage() {
  echo "usage: $0 generate --handoff-dir DIR | verify --identity FILE | fingerprint" >&2
  exit 2
}

cfg="$BK_CONFIG_DIR/backup.env"
ram_base="${BK_RAM_DIR:-/dev/shm}"
ram=""

cleanup() {
  if [ -n "$ram" ] && [ -d "$ram" ]; then
    find "$ram" -type f -exec shred -u -n 1 {} + 2>/dev/null || true
    rm -rf -- "$ram"
  fi
}
trap cleanup EXIT

make_ram_dir() {
  if [ ! -d "$ram_base" ]; then
    echo "backup-key: RAM-backed directory not available: $ram_base" >&2
    exit 1
  fi
  ram="$(mktemp -d "$ram_base/bk-key.XXXXXX")"
  chmod 700 "$ram"
}

ensure_config() {
  mkdir -p "$BK_CONFIG_DIR"
  chmod 700 "$BK_CONFIG_DIR"
  if [ ! -f "$cfg" ]; then
    cp -- "$here/../backup.env.example" "$cfg"
  fi
  chmod 600 "$cfg"
}

# set_cfg KEY VALUE : replace the KEY= line or append it; values are never interpreted.
set_cfg() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp "$cfg.XXXXXX")"
  awk -v k="$key" -v v="$value" '
    BEGIN { done = 0 }
    $0 ~ ("^" k "=") { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }' "$cfg" >"$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$cfg"
}

cfg_get() {
  awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$cfg" 2>/dev/null || true
}

evidence() { # kind result detail
  bk_require_test_isolation || return 0
  mkdir -p "$BK_STATE_DIR"
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >>"$BK_STATE_DIR/evidence.log"
}

cmd_generate() {
  local handoff="" recipient existing dest
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --handoff-dir) handoff="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$handoff" ] || usage
  if [ ! -d "$handoff" ]; then
    echo "backup-key: hand-off directory does not exist: $handoff" >&2
    exit 1
  fi
  case "$(realpath -m -- "$handoff")" in
    "$(realpath -m -- "$BK_CONFIG_DIR")" | "$(realpath -m -- "$BK_CONFIG_DIR")"/*)
      echo "backup-key: the hand-off directory must not be inside the host config directory" >&2
      exit 1
      ;;
  esac
  ensure_config
  existing="$(cfg_get BK_AGE_RECIPIENT)"
  case "$existing" in
    age1*)
      echo "backup-key: a recipient is already configured; refusing to overwrite (rotate deliberately)" >&2
      exit 1
      ;;
  esac

  make_ram_dir
  age-keygen -o "$ram/key.txt" 2>/dev/null
  recipient="$(age-keygen -y "$ram/key.txt")"
  dest="$handoff/backup-age-key-${recipient: -8}.txt"
  cp -- "$ram/key.txt" "$dest"
  chmod 600 "$dest"
  if ! cmp -s -- "$ram/key.txt" "$dest"; then
    rm -f -- "$dest"
    echo "backup-key: the hand-off copy did not verify; nothing was configured" >&2
    exit 1
  fi

  set_cfg BK_AGE_RECIPIENT "$recipient"
  set_cfg BK_AGE_RECIPIENT_CREATED "$(date -u +%Y-%m-%d)"
  cleanup
  ram=""
  bk_audit_log key_generated "recipient=$recipient"
  echo "recipient: $recipient"
  echo "created:   $(date -u +%Y-%m-%d)"
  echo "The PRIVATE key was written to: $dest"
  echo "NEXT: move it into your password manager and a second escrow, run"
  echo "      backup-key.sh verify --identity <that file>, then DELETE the hand-off file."
  echo "The private key is not stored on this host."
}

cmd_verify() {
  local identity="" recipient derived
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --identity) identity="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$identity" ] || usage
  if [ ! -r "$identity" ]; then
    echo "backup-key: identity file not readable: $identity" >&2
    exit 1
  fi
  [ -f "$cfg" ] || { echo "backup-key: no config; run generate first" >&2; exit 1; }
  recipient="$(cfg_get BK_AGE_RECIPIENT)"
  case "$recipient" in age1*) ;; *) echo "backup-key: no recipient configured" >&2; exit 1 ;; esac
  if ! derived="$(age-keygen -y "$identity" 2>/dev/null)"; then
    evidence escrow FAIL "identity unreadable"
    echo "backup-key: not a valid age identity" >&2
    exit 1
  fi
  if [ "$derived" != "$recipient" ]; then
    evidence escrow FAIL "identity does not match the configured recipient"
    echo "backup-key: this identity does not match the configured recipient" >&2
    exit 1
  fi
  make_ram_dir
  head -c 48 /dev/urandom | base64 >"$ram/canary"
  age -r "$recipient" -o "$ram/canary.age" "$ram/canary"
  if ! age -d -i "$identity" -o "$ram/canary.out" "$ram/canary.age" 2>/dev/null; then
    evidence escrow FAIL "decrypt failed"
    echo "backup-key: decryption with this identity FAILED" >&2
    exit 1
  fi
  if ! cmp -s -- "$ram/canary" "$ram/canary.out"; then
    evidence escrow FAIL "canary mismatch"
    echo "backup-key: decrypted canary does not match" >&2
    exit 1
  fi
  evidence escrow PASS "recipient=$recipient"
  bk_audit_log escrow_verified "recipient=$recipient"
  echo "escrow verified $(date -u +%Y-%m-%d)"
}

cmd_fingerprint() {
  local recipient last
  [ -f "$cfg" ] || { echo "backup-key: no config" >&2; exit 1; }
  recipient="$(cfg_get BK_AGE_RECIPIENT)"
  last="never"
  if [ -f "$BK_STATE_DIR/evidence.log" ]; then
    last="$(awk -F'\t' '$2 == "escrow" && $3 == "PASS" { t = $1 } END { if (t) print t }' "$BK_STATE_DIR/evidence.log")"
    [ -n "$last" ] || last="never"
  fi
  echo "recipient=$recipient"
  echo "created=$(cfg_get BK_AGE_RECIPIENT_CREATED)"
  echo "last_verified=$last"
}

sub="${1:-}"
[ -n "$sub" ] || usage
shift
case "$sub" in
  generate) cmd_generate "$@" ;;
  verify) cmd_verify "$@" ;;
  fingerprint) cmd_fingerprint "$@" ;;
  *) usage ;;
esac
