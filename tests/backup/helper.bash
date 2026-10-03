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

# run_with_signal SIGNAL MARKER SCRIPT [ARGS...]
# Start `bash SCRIPT ARGS` (with default signal handling, unlike a bats background job), wait until a
# process whose whole command line is "sleep MARKER" exists (the hung stub), send SIGNAL to the script,
# then print "rc=<exit code> leftover=<number of sleep MARKER still running>" and the script's output.
# The output goes to a file, so a surviving child can never hang the test; leftovers are force-killed.
run_with_signal() {
  python3 - "$@" <<'PY'
import os, signal, subprocess, sys, tempfile, time
name, marker, script, args = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
sig = getattr(signal, "SIG" + name)
pat = "sleep " + marker
def left():
    return subprocess.run(["pgrep", "-fx", pat], capture_output=True, text=True).stdout.split()
def reap():
    subprocess.run(["pkill", "-KILL", "-fx", pat], capture_output=True)
outfile = os.path.join(os.environ["BATS_TEST_TMPDIR"], "sig.out")
with open(outfile, "w") as out:
    p = subprocess.Popen(["bash", script] + args, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
    for _ in range(300):
        if left(): break
        time.sleep(0.1)
    else:
        p.kill(); reap(); print("never started"); print(open(outfile).read()); sys.exit(1)
    time.sleep(1)
    os.kill(p.pid, sig)
    try:
        rc = p.wait(timeout=40)
    except subprocess.TimeoutExpired:
        p.kill(); reap(); print("script did not exit"); sys.exit(1)
time.sleep(0.5)
n = len(left())
reap()
print("rc=%d leftover=%d" % (rc, n))
print(open(outfile).read())
PY
}
