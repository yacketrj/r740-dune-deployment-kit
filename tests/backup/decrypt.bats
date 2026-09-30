#!/usr/bin/env bats
# decrypt.bats -- tests for scripts/backup-decrypt.sh (the "open one set with the PRIVATE key" helper).
load helper

setup() {
  setup_env
  make_age_key
  SCRIPT="$REPO_ROOT/scripts/backup-decrypt.sh"
  export BK_RAM_DIR="$BATS_TEST_TMPDIR/ram"; mkdir -p "$BK_RAM_DIR"
  B="$BATS_TEST_TMPDIR/build"
  rm -rf "$B"; mkdir -p "$B/prod/runtime/backups/db" "$B/host/etc/pve"
  echo dumpdata >"$B/prod/runtime/backups/db/d.backup"
  echo 'authoritative=runtime/backups/db/d.backup' >"$B/prod/gate-manifest.txt"
  ln -s nodes/local "$B/host/etc/pve/local"
  manifest
  cd "$BATS_TEST_TMPDIR"
}

manifest() { ( cd "$B" && find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 sha256sum >MANIFEST.sha256 ); }
seal() { tar -C "$B" -cf "$BATS_TEST_TMPDIR/set.tar" . && age -r "$BK_AGE_RECIPIENT" -o "$BATS_TEST_TMPDIR/daily-x.tar.age" "$BATS_TEST_TMPDIR/set.tar"; }
dec() { run bash "$SCRIPT" "$BATS_TEST_TMPDIR/daily-x.tar.age" "$@"; }
ram_empty() { [ -z "$(ls -A "$BK_RAM_DIR")" ]; }

@test "works with the private key saved as a note with comment lines; unpacks, verifies and names the restore point" {
  seal
  { echo "# created: 2026-09-30"; echo "# public key: $BK_AGE_RECIPIENT"; grep '^AGE-SECRET-KEY' "$BK_AGE_IDENTITY"; } >"$BATS_TEST_TMPDIR/note.txt"
  dec --key "$BATS_TEST_TMPDIR/note.txt" --out "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Private key accepted"* ]]
  [[ "$output" == *"every file matches MANIFEST.sha256"* ]]
  [[ "$output" == *"Restore point"*"runtime/backups/db/d.backup"* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/out/prod/runtime/backups/db/d.backup")" = "dumpdata" ]
  [ -L "$BATS_TEST_TMPDIR/out/host/etc/pve/local" ]     # a relative symlink is fine
  ram_empty
}

@test "the private key is never printed" {
  seal
  dec --key "$BK_AGE_IDENTITY" --out "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  secret="$(grep '^AGE-SECRET-KEY' "$BK_AGE_IDENTITY")"
  [[ "$output" != *"$secret"* ]]
}

@test "giving the PUBLIC key is explained plainly and nothing is unpacked" {
  seal
  echo "$BK_AGE_RECIPIENT" >"$BATS_TEST_TMPDIR/pub.txt"
  dec --key "$BATS_TEST_TMPDIR/pub.txt" --out "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 1 ]
  [[ "$output" == *"that is the PUBLIC key"* ]]
  [[ "$output" == *"AGE-SECRET-KEY-1"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/out" ]
  ram_empty
}

@test "something that is not a key at all is explained" {
  seal
  echo "hunter2 and some words" >"$BATS_TEST_TMPDIR/junk.txt"
  dec --key "$BATS_TEST_TMPDIR/junk.txt" --out "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not find a private key"* ]]
}

@test "a truncated private key is reported as invalid" {
  seal
  head -c 40 "$BK_AGE_IDENTITY" | grep -o 'AGE-SECRET-KEY-1[A-Z0-9]*' >"$BATS_TEST_TMPDIR/cut.txt" || true
  grep '^AGE-SECRET-KEY' "$BK_AGE_IDENTITY" | cut -c1-30 >"$BATS_TEST_TMPDIR/cut.txt"
  dec --key "$BATS_TEST_TMPDIR/cut.txt" --out "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/out" ]
}

@test "a valid but WRONG private key says so and shows the key's public half for comparison" {
  seal
  age-keygen -o "$BATS_TEST_TMPDIR/other.key" 2>/dev/null
  dec --key "$BATS_TEST_TMPDIR/other.key" --out "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot open this file"* ]]
  other_pub="$(age-keygen -y "$BATS_TEST_TMPDIR/other.key")"
  [[ "$output" == *"${other_pub:0:16}"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/out" ]
  ram_empty
}

@test "a file that is not age-encrypted is refused" {
  echo "plain text" >"$BATS_TEST_TMPDIR/daily-x.tar.age"
  dec --key "$BK_AGE_IDENTITY"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not an age-encrypted file"* ]]
}

@test "a parent-relative path inside the set is refused" {
  echo evil >"$BATS_TEST_TMPDIR/evil.txt"
  tar -C "$B" -cf "$BATS_TEST_TMPDIR/set.tar" . --transform='s#^./prod/gate-manifest.txt#../escape.txt#'
  age -r "$BK_AGE_RECIPIENT" -o "$BATS_TEST_TMPDIR/daily-x.tar.age" "$BATS_TEST_TMPDIR/set.tar"
  dec --key "$BK_AGE_IDENTITY" --out "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 1 ]
  [[ "$output" == *"parent-relative"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/escape.txt" ]
}

@test "a link pointing outside the folder is refused" {
  ln -s /etc "$B/host/evil"
  seal
  dec --key "$BK_AGE_IDENTITY" --out "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 1 ]
  [[ "$output" == *"points outside"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/out" ]
}

@test "a non-empty output folder is never overwritten" {
  seal
  mkdir -p "$BATS_TEST_TMPDIR/out"; echo keep >"$BATS_TEST_TMPDIR/out/mine.txt"
  dec --key "$BK_AGE_IDENTITY" --out "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not empty"* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/out/mine.txt")" = "keep" ]
}

@test "a file that does not match the manifest is an integrity failure" {
  # the manifest was written for the original content; then the file is changed
  echo tampered >"$B/prod/runtime/backups/db/d.backup"
  seal
  dec --key "$BK_AGE_IDENTITY" --out "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 1 ]
  [[ "$output" == *"INTEGRITY FAILURE"* ]]
}

@test "without --key and without a terminal it stops with a clear message" {
  seal
  dec --out "$BATS_TEST_TMPDIR/out" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"no --key given"* ]]
}
