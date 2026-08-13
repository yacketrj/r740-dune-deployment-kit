#!/usr/bin/env bash
# =============================================================================
# 07-wsl-decommission.sh
#
# RUN THIS: on the GAMING PC, ONLY AFTER both dune-prod and dune-dev on the
#           R740 have been confirmed stable for a real burn-in period
#           (recommend at least several days of real/simulated player
#           traffic on Prod before running this).
# PURPOSE:  Cleanly stop and disable everything Dune-related and
#           Cloudflare-tunnel-related on this box, reclaim Docker's disk
#           footprint, and prepare for full WSL2 distro removal (the final
#           removal step itself happens from Windows PowerShell, not from
#           inside WSL - this script gets you to that point safely).
#
# THIS SCRIPT DOES NOT DELETE YOUR DATA. It stops services and reclaims
# Docker's cache/image footprint. Your repo checkout, backups, and configs
# remain on disk at ~/dune-awakening-selfhost-docker unless you remove them
# yourself afterward.
#
# USAGE: bash 07-wsl-decommission.sh
# =============================================================================
set -euo pipefail

export DUNE_DOCKER_DIR="${DUNE_DOCKER_DIR:-/home/darkdante/dune-awakening-selfhost-docker}"
cd "$DUNE_DOCKER_DIR"

echo "=== WSL2 Gaming-PC Decommission ==="
echo
echo "Before proceeding, confirm the following are TRUE:"
echo "  [ ] dune-prod on the R740 has been live and stable for several days"
echo "  [ ] dune-dev on the R740 has been validated and is in regular use"
echo "  [ ] Router port forwards point at the R740's dune-prod VM, not here"
echo "  [ ] cloudflared console tunnel hostname has been repointed to the"
echo "      R740 (behind VPN/Access, not bare public - see"
echo "      docs/04-post-standup-hardening.md)"
echo "  [ ] You have a final backup of this box's database taken and"
echo "      verified importable (should already be true from script 06)"
echo
read -r -p "Confirm ALL of the above are true and you want to proceed? [y/N]: " confirm
case "$confirm" in
  y|Y|yes|YES) ;;
  *) echo "Aborted. Nothing was changed."; exit 1 ;;
esac

echo
echo "--- Stopping the Dune stack ---"
/usr/local/bin/dune stop || true

echo
echo "--- Disabling systemd timers/services ---"
sudo systemctl disable --now dune-awakening-db-backup.timer 2>/dev/null || true
sudo systemctl disable --now dune-awakening-db-backup.service 2>/dev/null || true
sudo systemctl disable --now dune-awakening-auto-update.timer 2>/dev/null || true
sudo systemctl disable --now dune-awakening-auto-update.service 2>/dev/null || true
sudo systemctl disable --now dune-awakening-scheduled-restart.timer 2>/dev/null || true
sudo systemctl disable --now dune-awakening-scheduled-restart-warning.timer 2>/dev/null || true

echo
echo "--- Disabling Cloudflare tunnel/DDNS on this box ---"
echo "(Only do this AFTER confirming cloudflared config has been repointed"
echo "at the R740 elsewhere - otherwise you'll lose remote console access"
echo "entirely until the new tunnel is confirmed working.)"
read -r -p "Confirm the Cloudflare tunnel has ALREADY been repointed elsewhere? [y/N]: " cf_confirm
case "$cf_confirm" in
  y|Y|yes|YES)
    sudo systemctl disable --now cloudflared.service 2>/dev/null || true
    sudo systemctl disable --now cloudflare-ddns.service 2>/dev/null || true
    echo "Cloudflare services disabled on this box."
    ;;
  *)
    echo "Skipping Cloudflare service disable - re-run this step manually"
    echo "later once the tunnel repoint is confirmed:"
    echo "  sudo systemctl disable --now cloudflared.service cloudflare-ddns.service"
    ;;
esac

echo
echo "--- Reclaiming Docker disk footprint ---"
docker system df
echo
read -r -p "Run 'docker system prune -a --volumes' to reclaim space? This deletes ALL stopped containers, unused images, and unused volumes on this box. [y/N]: " prune_confirm
case "$prune_confirm" in
  y|Y|yes|YES)
    docker system prune -a --volumes -f
    ;;
  *)
    echo "Skipping prune. Run manually later if desired:"
    echo "  docker system prune -a --volumes -f"
    ;;
esac

echo
echo "=== Gaming-PC-side decommission complete ==="
echo
echo "FINAL STEP (run from Windows PowerShell, NOT from inside this WSL shell):"
echo
echo "  wsl --list --verbose        # confirm current distros"
echo "  wsl --unregister Ubuntu-26.04"
echo "  wsl --unregister docker-desktop"
echo
echo "Optionally also uninstall Docker Desktop for Windows via"
echo "'Add or remove programs' if you no longer need it for anything else."
echo
echo "After that, this PC is back to being a pure gaming/work machine."
