#!/usr/bin/env bash
# =============================================================================
# 04-init-dev-battlegroup.sh
#
# RUN THIS: INSIDE the dune-dev VM, after 03-vm-guest-bootstrap.sh has
#           completed successfully.
# PURPOSE:  Interactively initialize a FRESH Dev battlegroup using a NEW
#           Funcom Self-Host Service Token (account #2 - never reuse the
#           token from the currently-live "Tabr Tau - Dev" on the gaming
#           PC), then import the real player/world-state backup taken from
#           that gaming PC via 06-pre-migration-backup.sh.
#
# WHY IMPORT IS SAFE HERE: dune's own db.sh has adopt_backup_battlegroup_id()
# and adapt_imported_battlegroup() functions that automatically detect the
# mismatch between the backup's old BATTLEGROUP_ID and this fresh install's
# newly-generated one, and rewrite every reference across the whole `dune`
# schema (text/json/jsonb columns) to the new ID. You do NOT need to do any
# manual identity surgery - just run `dune init` normally, then `dune db
# import <file>` normally, and the tool handles the remap itself.
#
# PREREQ:
#   - The backup file from 06-pre-migration-backup.sh has been transferred
#     onto this VM (e.g. via scp) into:
#       ~/dune-awakening-selfhost-docker/runtime/backups/db/
#   - You have Dev's NEW Funcom Self-Host Service Token ready to paste
#     (from account #2, generated at account.duneawakening.com)
#
# USAGE: bash 04-init-dev-battlegroup.sh
# =============================================================================
set -euo pipefail

REPO_DIR="$HOME/dune-awakening-selfhost-docker"
cd "$REPO_DIR"

echo "=== Dev Battlegroup Initialization ==="
echo
echo "This will run 'dune init' interactively. When prompted:"
echo "  - Server title: something like 'Tabr Tau - Dev'"
echo "  - Region: pick your usual region"
echo "  - Hosting mode: choose option 2 (Local/LAN) since Dev has no public"
echo "    port forwards in this design - OR option 1 (Public) if you"
echo "    changed your mind and want Dev reachable externally too. Confirm"
echo "    against docs/02-network-setup.md before choosing."
echo "  - Funcom token: paste Dev's NEW token (account #2) when prompted."
echo "    Do NOT reuse the token from the currently-live gaming-PC Dev box."
echo
read -r -p "Press Enter to start 'dune init' now (or Ctrl+C to abort): "

sudo ./install.sh || true   # ensures Docker prereqs the installer expects are met; safe to re-run
runtime/scripts/dune init

echo
echo "=== dune init complete. Checking status before import... ==="
runtime/scripts/dune status

echo
echo "=== Locating backup file to import ==="
BACKUP_DIR="$REPO_DIR/runtime/backups/db"
mapfile -t candidates < <(find "$BACKUP_DIR" -maxdepth 1 -name '*.backup' -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk '{print $2}')

if [ "${#candidates[@]}" -eq 0 ]; then
  echo "No .backup files found in $BACKUP_DIR"
  echo "Transfer the backup from the gaming PC first, e.g.:"
  echo "  scp /tmp/opencode/dune-migration/*.backup <this-vm-user>@<this-vm-ip>:$BACKUP_DIR/"
  echo "Then re-run this script, or run the import step manually:"
  echo "  runtime/scripts/dune db import <backup-filename>"
  exit 1
fi

echo "Found backup candidates (newest first):"
i=1
for f in "${candidates[@]}"; do
  echo "  [$i] $(basename "$f")"
  i=$((i+1))
done
echo
read -r -p "Enter the number of the backup to import (should be the 7/29 final backup, not the 7/24 rehearsal copy): " choice
selected="${candidates[$((choice-1))]}"
echo "Selected: $(basename "$selected")"
echo

read -r -p "Confirm import of $(basename "$selected") into this FRESH Dev battlegroup? [y/N]: " confirm
case "$confirm" in
  y|Y|yes|YES) ;;
  *) echo "Import cancelled. Re-run this script when ready."; exit 1 ;;
esac

DUNE_DB_ASSUME_YES=1 runtime/scripts/dune db import "$(basename "$selected")"

echo
echo "=== Import complete. Validating sietch/partition state ==="
runtime/scripts/dune sietches validate
runtime/scripts/dune status

echo
echo "=== Dev battlegroup ready ==="
echo "Next: bring up the web console if not already running, confirm you"
echo "can reach it at http://<dune-dev-vm-ip>:8088 from your Trusted-LAN"
echo "or VPN (never expose this port to WAN per docs/02-network-setup.md)."
