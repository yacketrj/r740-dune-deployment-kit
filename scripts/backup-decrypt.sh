#!/usr/bin/env bash
# =============================================================================
# backup-decrypt.sh -- open one encrypted backup set and verify it.
# =============================================================================
# WHAT KEY DO I NEED?
#
#   The PRIVATE key. It is ONE line that starts with:   AGE-SECRET-KEY-1
#   (followed by capital letters and digits). You saved it in your password
#   manager when you ran backup-key.sh generate; it may sit in a note that also
#   has two "# ..." comment lines above it. That is fine: this script finds the
#   right line.
#
#   NOT the public key. The public key starts with   age1...   and can only
#   LOCK backups. It cannot open anything. If you give this script the public
#   key, it will tell you so and stop.
#
# USAGE
#   backup-decrypt.sh SET.tar.age                    # asks you to paste the key
#   backup-decrypt.sh SET.tar.age --key KEYFILE      # key read from a file
#   backup-decrypt.sh SET.tar.age --out DIR          # where to unpack (default
#                                                    #   ./restored-<set name>)
#
# Needs only: bash, age, tar, sha256sum. It works on any Linux box; it does not
# need the rest of this repository or the backup host.
#
# WHAT IT DOES
#   1. finds the private key (from --key, or a silent paste prompt), keeps it
#      only in RAM (/dev/shm, mode 600) and wipes it on exit; never prints it
#   2. decrypts the set and refuses unsafe contents (absolute paths, "..",
#      links that point outside the folder)
#   3. unpacks into an EMPTY folder (refuses to overwrite anything)
#   4. verifies every file against MANIFEST.sha256
#   5. tells you which database dump is the restore point
# =============================================================================
set -euo pipefail

usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }
die() { echo "backup-decrypt: $*" >&2; exit 1; }

set_file=""
key_file=""
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --key) key_file="${2:-}"; [ -n "$key_file" ] || usage; shift 2 ;;
    --out) out="${2:-}"; [ -n "$out" ] || usage; shift 2 ;;
    -h | --help) usage 0 ;;
    -*) usage ;;
    *) [ -z "$set_file" ] || usage; set_file="$1"; shift ;;
  esac
done
[ -n "$set_file" ] || usage
[ -f "$set_file" ] || die "no such file: $set_file"
for t in age age-keygen tar sha256sum; do
  command -v "$t" >/dev/null 2>&1 || die "'$t' is not installed (on Debian/Ubuntu: apt-get install age)"
done
if [ "$(head -c 21 -- "$set_file")" != "age-encryption.org/v1" ]; then
  die "$set_file is not an age-encrypted file (wrong file, or damaged)"
fi

ram_base="${BK_RAM_DIR:-/dev/shm}"
[ -d "$ram_base" ] || die "no RAM-backed folder at $ram_base (the key is never written to a normal disk)"
ram="$(mktemp -d "$ram_base/bk-decrypt.XXXXXX")"
chmod 700 "$ram"
cleanup() {
  [ -z "${ram:-}" ] || { find "$ram" -type f -exec shred -u {} + 2>/dev/null || true; rm -rf "$ram"; }
}
trap cleanup EXIT

# ---- 1. find the private key ------------------------------------------------------
extract_key() { # file-or-stdin-text -> prints the secret line, or returns 1
  tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -m1 -E '^AGE-SECRET-KEY-1[A-Z0-9]+$'
}

explain_no_key() { # text that did not contain a secret key
  if printf '%s' "$1" | grep -qE '^age1[a-z0-9]{50,}'; then
    cat >&2 <<'MSG'
backup-decrypt: that is the PUBLIC key (it starts with "age1...").
The public key can only LOCK backups. To open one you need the PRIVATE key:
one line starting with   AGE-SECRET-KEY-1   , saved in your password manager
(and on your printed copy) when the key was created.
MSG
  else
    cat >&2 <<'MSG'
backup-decrypt: I could not find a private key in what you gave me.
It is ONE line that starts with   AGE-SECRET-KEY-1   followed by capital letters
and digits. Copy that line (or the whole saved note) from your password manager.
MSG
  fi
  exit 1
}

if [ -n "$key_file" ]; then
  [ -r "$key_file" ] || die "cannot read the key file: $key_file"
  text="$(cat -- "$key_file")"
  printf '%s\n' "$text" | extract_key >"$ram/key.txt" || explain_no_key "$text"
else
  [ -t 0 ] || die "no --key given and no terminal to ask on"
  echo "Paste the PRIVATE key (the line starting AGE-SECRET-KEY-1) and press Enter." >&2
  echo "Nothing will be shown while you paste." >&2
  IFS= read -rs text
  echo >&2
  printf '%s\n' "$text" | extract_key >"$ram/key.txt" || explain_no_key "$text"
  text=""
fi
chmod 600 "$ram/key.txt"
if ! pub="$(age-keygen -y "$ram/key.txt" 2>/dev/null)"; then
  die "that line starts like a private key but is not valid (was it cut off or mistyped?)"
fi
echo "Private key accepted. Its public half is: ${pub:0:16}... (this identifies the key; it is safe to show)"

# ---- 2. decrypt -----------------------------------------------------------------------
age -d -i "$ram/key.txt" -o "$ram/set.tar" "$set_file" 2>"$ram/age.err" || {
  cat >&2 <<MSG
backup-decrypt: this key cannot open this file.
  - The file was made for a different key. Check the public half above (${pub:0:16}...)
    against the recipient the backups use (BK_AGE_RECIPIENT in backup.env, or the
    "recipient=" line in the escrow record). If they differ, you need the OTHER key.
  - Or the file is damaged. age says: $(tr '\n' ' ' <"$ram/age.err" | cut -c1-200)
MSG
  exit 1
}
echo "Decrypted."

# ---- 3. refuse unsafe contents -------------------------------------------------------
tar -tf "$ram/set.tar" >"$ram/names" 2>/dev/null || die "the decrypted data is not a readable archive"
if grep -qE '^/|(^|/)\.\.(/|$)' "$ram/names"; then
  die "the archive has an absolute or parent-relative path; refusing to unpack it"
fi
# links are allowed only when they point inside the folder (Proxmox's /etc/pve is made of relative symlinks)
if tar -tvf "$ram/set.tar" 2>/dev/null | grep -E '^[lh]' | grep -E -- ' (->|link to) (/|.*\.\.)' >/dev/null; then
  die "the archive has a link that points outside its folder; refusing to unpack it"
fi

# ---- 4. unpack into an empty folder ------------------------------------------------
if [ -z "$out" ]; then
  base="$(basename -- "$set_file")"
  out="./restored-${base%.tar.age}"
fi
if [ -e "$out" ] && [ -n "$(ls -A -- "$out" 2>/dev/null)" ]; then
  die "$out already exists and is not empty; choose another --out (nothing was unpacked)"
fi
mkdir -p -- "$out"
tar -xf "$ram/set.tar" -C "$out" --no-same-owner --no-same-permissions
echo "Unpacked into: $out"

# ---- 5. verify and report -------------------------------------------------------------
if [ -f "$out/MANIFEST.sha256" ]; then
  if ( cd "$out" && sha256sum -c --quiet MANIFEST.sha256 ); then
    echo "Integrity: every file matches MANIFEST.sha256."
  else
    die "INTEGRITY FAILURE: some files do not match MANIFEST.sha256 (see above). Do not restore from this set."
  fi
else
  echo "WARNING: no MANIFEST.sha256 in this set, so file integrity could not be checked."
fi
if [ -f "$out/prod/gate-manifest.txt" ]; then
  auth="$(awk -F= '$1 == "authoritative" { print $2; exit }' "$out/prod/gate-manifest.txt")"
  echo "Restore point (newest automatic database dump): $out/prod/$auth"
fi
echo
echo "Contents: $(find "$out" -type f | wc -l) files. Top level:"
ls -1 "$out" | sed 's/^/  /'
echo
echo "Next: to restore the database see docs/08-backup-runbook.md section 6b."
