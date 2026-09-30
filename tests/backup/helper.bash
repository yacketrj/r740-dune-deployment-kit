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
