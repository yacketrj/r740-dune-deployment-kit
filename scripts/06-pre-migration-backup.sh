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
#           Also stages the backup file, its sidecar metadata, a
#           redacted .env reference, and tarballs of runtime/secrets/
#           and runtime/generated/ into a single directory for easy
#           transfer off this box (issue #80 -- neither directory was
#           previously captured by any migration step; runtime/secrets/
#           holds credential material with no other source of truth,
#           e.g. the Funcom token, which may not be re-issuable on
#           demand). runtime/generated/'s tar deliberately excludes the
#           dune-fake-k8s-serviceaccount-<service>-<pid> directories
#           (recreated fresh on every container restart -- see
#           runtime/scripts/spawn-server.sh's FAKE_K8S_SERVICEACCOUNT_DIR,
#           not real state) and rotating *.log files, keeping every
#           other config/state file.
#
#           runtime/addons/ is explicitly NOT captured here -- addons are
#           easily reinstalled, no preservation needed (operator
#           decision, 2026-08-14). The existing addon state.json
#           reference below predates that decision and is kept as-is
#           since it's a small, already-working, separate mechanism.
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
# Restrict access: the backup contains the live game database -- other
# local users on a shared VM must not be able to read it.  /tmp is
# typically 1777 and new files default to 0644, so a chmod 700 on the
# directory + 600 on each staged file is defense in depth, not just
# convention.
chmod 700 "$STAGING_DIR"

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
echo "--- Staging runtime/secrets/ (issue #80) ---"
if [ -d runtime/secrets ]; then
  tar -czf "$STAGING_DIR/runtime-secrets.tar.gz" -C runtime secrets
  echo "Staged runtime-secrets.tar.gz ($(du -h "$STAGING_DIR/runtime-secrets.tar.gz" | cut -f1))"
else
  echo "WARNING: runtime/secrets/ not found -- skipping. This is unexpected"
  echo "unless this is a fresh, never-initialized install."
fi

echo
echo "--- Staging runtime/generated/ (issue #80) ---"
if [ -d runtime/generated ]; then
  # --exclude flags are positional in GNU tar and must come BEFORE the
  # archive path arguments, or they're silently ignored with a warning
  # (confirmed by testing this exact command against a synthetic
  # directory before trusting it against real data -- the original
  # ordering here archived everything, excludes included, with no
  # error, just a warning easy to miss in scrollback).
  tar --exclude='generated/dune-fake-k8s-serviceaccount-*' \
      --exclude='generated/*.log' \
      -czf "$STAGING_DIR/runtime-generated.tar.gz" -C runtime generated
  echo "Staged runtime-generated.tar.gz ($(du -h "$STAGING_DIR/runtime-generated.tar.gz" | cut -f1))"
  echo "(excludes dune-fake-k8s-serviceaccount-* ephemeral dirs and *.log files --"
  echo " neither is real state, see this script's header comment)"
else
  echo "WARNING: runtime/generated/ not found -- skipping. This is unexpected"
  echo "unless this is a fresh, never-initialized install."
fi

chmod 600 "$STAGING_DIR"/*

echo
echo "=== Staged files ready for transfer ==="
ls -la "$STAGING_DIR"
echo
echo "sha256 checksum (verify this matches after transfer):"
cat "$STAGING_DIR/$(basename "$LATEST_BACKUP").sha256"
echo
echo "=== NEXT STEP: transfer this off the gaming PC ==="
echo
echo "Once dune-dev's VM is up and reachable, transfer the DB backup with:"
echo "  scp $STAGING_DIR/*.backup* <dev-vm-user>@<dev-vm-ip>:~/dune-awakening-selfhost-docker/runtime/backups/db/"
echo
echo "Then on the dune-dev VM, verify integrity before importing:"
echo "  sha256sum ~/dune-awakening-selfhost-docker/runtime/backups/db/$(basename "$LATEST_BACKUP")"
echo "  (compare against the .sha256 file transferred alongside it)"
echo
echo "Separately, transfer and restore runtime/secrets/ and runtime/generated/"
echo "(issue #80) onto EACH VM that needs them (both dune-prod and dune-dev if"
echo "both are meant to carry forward this host's config/credentials -- decide"
echo "this per-value, do not assume a blanket copy to both is correct):"
echo "  scp $STAGING_DIR/runtime-secrets.tar.gz $STAGING_DIR/runtime-generated.tar.gz \\"
echo "      <vm-user>@<vm-ip>:~/dune-awakening-selfhost-docker/runtime/"
echo "  ssh <vm-user>@<vm-ip> 'cd ~/dune-awakening-selfhost-docker/runtime && \\"
echo "      tar -xzf runtime-secrets.tar.gz && tar -xzf runtime-generated.tar.gz && \\"
echo "      chmod 600 secrets/* && rm runtime-secrets.tar.gz runtime-generated.tar.gz'"
echo
echo "Then proceed with 04-init-dev-battlegroup.sh on the dune-dev VM."
