# Shared bats helper: isolated temp dirs and stub binaries on PATH.
#
# SAFETY: these helpers create executables. If BATS_TEST_TMPDIR is empty (for
# example when a helper is copied into an ad-hoc `bash -c` outside bats),
# "$BATS_TEST_TMPDIR/bin/mkdir" becomes /bin/mkdir and, as root, silently
# replaces a real system binary. That happened on 2026-09-29 and took a
# production host down at its next reboot. Every function below therefore
# refuses to act unless BATS_TEST_TMPDIR is a real, non-system directory.
# Run these tests with scripts/run-backup-tests.sh, which also mounts /usr and
# /etc read-only for the duration, so a bug here cannot reach the system.

assert_safe_tmpdir() {
  local d="${BATS_TEST_TMPDIR:-}"
  case "$d" in
    "" | "/" | /bin | /bin/* | /sbin | /sbin/* | /usr | /usr/* | /lib | /lib/* | /lib64 | /lib64/* | /etc | /etc/* | /boot | /boot/* | /var/lib/dpkg*)
      echo "helper: refusing unsafe BATS_TEST_TMPDIR='$d'" >&2
      return 1
      ;;
  esac
  if [ ! -d "$d" ]; then
    echo "helper: BATS_TEST_TMPDIR is not a directory: '$d'" >&2
    return 1
  fi
}

setup_env() {
  assert_safe_tmpdir || return 1
  # Tests may be run from an ssh session; the gate refuses test mode on a real ssh connection.
  unset SSH_CONNECTION
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
  assert_safe_tmpdir || return 1
  local name="$1" body="${2:-:}"
  if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]] || [ "$name" = "." ] || [ "$name" = ".." ]; then
    echo "helper: refusing unsafe stub name '$name'" >&2
    return 1
  fi
  cat >"$BATS_TEST_TMPDIR/bin/$name" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/$name.calls"
$body
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/$name"
}

# make a real age keypair for tests; sets BK_AGE_RECIPIENT and BK_AGE_IDENTITY
make_age_key() {
  assert_safe_tmpdir || return 1
  BK_AGE_IDENTITY="$BATS_TEST_TMPDIR/age.key"
  age-keygen -o "$BK_AGE_IDENTITY" 2>/dev/null
  BK_AGE_RECIPIENT="$(age-keygen -y "$BK_AGE_IDENTITY")"
  export BK_AGE_IDENTITY BK_AGE_RECIPIENT
}
