#!/usr/bin/env bash
# =============================================================================
# run-backup-tests.sh -- run the backup bats tests inside a sandbox.
#
# WHY: the tests create stub executables. On 2026-09-29 a test helper used
# outside bats, as root, overwrote /usr/bin/{mkdir,ssh,curl,mountpoint} on a
# production hypervisor, and the host failed at its next boot. This wrapper
# makes /usr (and therefore /bin, /sbin, /lib) and /etc read-only in a private
# mount namespace, so even a broken helper cannot damage the system: the write
# fails with "Read-only file system". The host's own view is never changed.
#
# USAGE: run-backup-tests.sh [bats arguments]      (default: tests/backup)
#        run-backup-tests.sh --exec CMD [ARGS...]  (run CMD in the sandbox)
# Needs root (mount namespaces). Set TMPDIR to a scratch directory outside /tmp.
# In CI (non-root ephemeral runner) run `bats tests/backup` directly instead.
# =============================================================================
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run-backup-tests.sh: needs root to create a mount namespace" >&2
  exit 1
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"

if [ "${1:-}" = "--exec" ]; then
  shift
  [ "$#" -gt 0 ] || { echo "run-backup-tests.sh: --exec needs a command" >&2; exit 2; }
  cmd=("$@")
else
  if [ "$#" -eq 0 ]; then
    set -- "$repo/tests/backup"
  fi
  cmd=(bats "$@")
fi

exec unshare --mount --propagation private bash -c '
  set -euo pipefail
  for d in /usr /etc; do
    mount --bind "$d" "$d"
    mount -o remount,ro,bind "$d"
  done
  exec "$@"
' _ "${cmd[@]}"
