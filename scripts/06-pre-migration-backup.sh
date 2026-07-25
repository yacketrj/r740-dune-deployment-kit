#!/usr/bin/env bash
# =============================================================================
# 06-pre-migration-backup.sh
#
# RUN THIS: on the GAMING PC (the current WSL2 box running "Tabr Tau - Dev"),
#           the night before or morning of the 7/30 stand-up.
# PURPOSE:  Take the FINAL, real database backup that will actually be
#           imported into the new Dev VM on the R740. This supersedes the
#           7/24 rehearsal backup taken earlier in this project - that one
#           stays only as a rollback reference, this one is the real source.
#
#           Also stages the backup file, its sidecar metadata, and a
#           redacted .env reference into a single directory for easy
#           transfer off this box.
#
# PREREQ:   Run from inside: /home/darkdante/dune-awakening-selfhost-docker
#
# USAGE: bash 06-pre-migration-backup.sh
# =============================================================================
set -euo pipefail

export DUNE_DOCKER_DIR="${DUNE_DOCKER_DIR:-/home/darkdante/dune-awakening-selfhost-docker}"
cd "$DUNE_DOCKER_DIR"

STAGING_DIR="/tmp/opencode/dune-migration-final"
mkdir -p "$STAGING_DIR"

echo "=== Final Pre-Migration Backup ==="
echo
echo "Current live server status:"
/usr/local/bin/dune status
echo

read -r -p "Confirm you want to take the FINAL migration backup now? [y/N]: " confirm
case "$confirm" in
  y|Y|yes|YES) ;;
  *) echo "Aborted. Re-run when ready."; exit 1 ;;
esac

echo
echo "--- Taking backup ---"
/usr/local/bin/dune db backup

echo
echo "--- Identifying the backup just taken ---"
LATEST_BACKUP="$(find runtime/backups/db -maxdepth 1 -name '*.backup' -printf '%T@ %p\n' \
  | sort -rn | head -1 | awk '{print $2}')"

if [ -z "$LATEST_BACKUP" ]; then
  echo "ERROR: could not locate the backup file just created. Check"
  echo "runtime/backups/db/ manually."
  exit 1
fi

echo "Latest backup: $LATEST_BACKUP"
sha256sum "$LATEST_BACKUP"

echo
echo "--- Staging for transfer ---"
cp "$LATEST_BACKUP" "$STAGING_DIR/"
cp "${LATEST_BACKUP}.yaml" "$STAGING_DIR/" 2>/dev/null || true
sha256sum "$LATEST_BACKUP" > "$STAGING_DIR/$(basename "$LATEST_BACKUP").sha256"

grep -v -i "token\|password\|secret" .env > "$STAGING_DIR/env-reference-redacted.txt"
cp runtime/addons/state.json "$STAGING_DIR/addon-state-reference.json" 2>/dev/null || true

echo
echo "=== Staged files ready for transfer ==="
ls -la "$STAGING_DIR"
echo
echo "sha256 checksum (verify this matches after transfer):"
cat "$STAGING_DIR/$(basename "$LATEST_BACKUP").sha256"
echo
echo "=== NEXT STEP: transfer this off the gaming PC ==="
echo
echo "Once dune-dev's VM is up and reachable, transfer with:"
echo "  scp $STAGING_DIR/*.backup* <dev-vm-user>@<dev-vm-ip>:~/dune-awakening-selfhost-docker/runtime/backups/db/"
echo
echo "Then on the dune-dev VM, verify integrity before importing:"
echo "  sha256sum ~/dune-awakening-selfhost-docker/runtime/backups/db/$(basename "$LATEST_BACKUP")"
echo "  (compare against the .sha256 file transferred alongside it)"
echo
echo "Then proceed with 04-init-dev-battlegroup.sh on the dune-dev VM."
