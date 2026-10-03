#!/usr/bin/env bats
# Tests for the safety guards in tests/backup/helper.bash and the sandbox
# wrapper. These exist because of the 2026-09-29 incident (see helper.bash).
load helper

@test "assert_safe_tmpdir rejects empty and system directories" {
  for d in "" / /bin /bin/x /usr /usr/bin /usr/local/bin /sbin /lib /lib64 /etc /etc/x /boot /var/lib/dpkg; do
    BATS_TEST_TMPDIR="$d" run assert_safe_tmpdir
    [ "$status" -eq 1 ]
  done
}

@test "assert_safe_tmpdir rejects a non-directory" {
  BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR/does-not-exist" run assert_safe_tmpdir
  [ "$status" -eq 1 ]
}

@test "assert_safe_tmpdir accepts the real bats temp directory" {
  run assert_safe_tmpdir
  [ "$status" -eq 0 ]
}

@test "stub refuses to run when BATS_TEST_TMPDIR is empty and writes nothing" {
  BATS_TEST_TMPDIR="" run stub bk-guard-probe 'exit 0'
  [ "$status" -eq 1 ]
  [ ! -e /bin/bk-guard-probe ]
  [ ! -e /usr/bin/bk-guard-probe ]
}

@test "stub refuses names that could escape the stub directory" {
  for n in "../../usr/bin/bk-guard-probe" "a/b" ".." "." ""; do
    run stub "$n" 'exit 0'
    [ "$status" -eq 1 ]
  done
  [ ! -e /usr/bin/bk-guard-probe ]
}

@test "setup_env refuses to run when BATS_TEST_TMPDIR is empty" {
  BATS_TEST_TMPDIR="" run setup_env
  [ "$status" -eq 1 ]
}

@test "stub creates an executable inside the bats temp dir when safe" {
  setup_env
  stub bk-guard-ok 'echo fine'
  [ -x "$BATS_TEST_TMPDIR/bin/bk-guard-ok" ]
  run bk-guard-ok
  [ "$output" = "fine" ]
}

@test "the sandbox wrapper makes /usr and /etc read-only even for root" {
  [ "$(id -u)" -eq 0 ] || skip "needs root"
  command -v unshare >/dev/null || skip "unshare not installed"
  run bash "$BATS_TEST_DIRNAME/../../scripts/run-backup-tests.sh" --exec touch /usr/bin/.bk-ro-probe
  [ "$status" -ne 0 ]
  [[ "$output" == *"Read-only file system"* ]]
  [ ! -e /usr/bin/.bk-ro-probe ]
  run bash "$BATS_TEST_DIRNAME/../../scripts/run-backup-tests.sh" --exec touch /etc/.bk-ro-probe
  [ "$status" -ne 0 ]
  [ ! -e /etc/.bk-ro-probe ]
}

@test "the sandbox wrapper still lets the tests write to the scratch directory" {
  [ "$(id -u)" -eq 0 ] || skip "needs root"
  command -v unshare >/dev/null || skip "unshare not installed"
  run bash "$BATS_TEST_DIRNAME/../../scripts/run-backup-tests.sh" --exec touch "$BATS_TEST_TMPDIR/writable"
  [ "$status" -eq 0 ]
  [ -e "$BATS_TEST_TMPDIR/writable" ]
}
