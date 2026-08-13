#!/usr/bin/env bash
# =============================================================================
# 05-init-prod-battlegroup.sh
#
# RUN THIS: INSIDE the dune-prod VM, after 03-vm-guest-bootstrap.sh has
#           completed successfully.
# PURPOSE:  Interactively initialize a FRESH Prod battlegroup using a NEW
#           Funcom Self-Host Service Token (account #1). This is a clean
#           build - there is no existing Prod state anywhere to import, so
#           this script does NOT run a db import step, unlike Dev's script.
#
#           After init, configures the 2x Sietch + 2x Deep Desert topology
#           discussed throughout this project. NOTE: the dual-Deep-Desert
#           pattern is UNVALIDATED - if you have not already tested
#           `dune deepdesert dual enable` on the Dev VM first, strongly
#           consider doing that validation pass before running the
#           corresponding step below on Prod. This script will pause and
#           ask you to confirm before touching Deep Desert config.
#
# PREREQ:
#   - You have Prod's NEW Funcom Self-Host Service Token ready to paste
#     (from account #1, generated at account.duneawakening.com)
#
# USAGE: bash 05-init-prod-battlegroup.sh
# =============================================================================
set -euo pipefail

REPO_DIR="$HOME/dune-awakening-selfhost-docker"
cd "$REPO_DIR"

echo "=== Production Battlegroup Initialization ==="
echo
echo "This will run 'dune init' interactively. When prompted:"
echo "  - Server title: 'Tabr Tau' (no '- Dev' suffix - this is Prod)"
echo "  - Region: pick your usual region"
echo "  - Hosting mode: choose option 1 (Public) - Prod needs the port"
echo "    forwards configured in docs/02-network-setup.md to work."
echo "  - Funcom token: paste Prod's NEW token (account #1) when prompted."
echo
read -r -p "Press Enter to start 'dune init' now (or Ctrl+C to abort): "

sudo ./install.sh || true
runtime/scripts/dune init

echo
echo "=== dune init complete. Checking status... ==="
runtime/scripts/dune status

echo
echo "=== Configuring Sietch topology (2x dimensions under Survival_1) ==="
runtime/scripts/dune sietches set-max Survival_1 2
runtime/scripts/dune sietches set-active Survival_1 2

echo
echo "=== Deep Desert configuration (4 concurrent instances) ==="
echo
echo "This sets max_dimensions=4 and active_dimensions=4 for DeepDesert_1."
echo "At 16 GB per instance, 4 DD instances consume 64 GB of the 152 GB VM."
echo
echo "WARNING: 4 concurrent Deep Desert instances is an UNVALIDATED"
echo "configuration pattern. The 'deepdesert dual' helper only enables 2."
echo "For 4, we set dimensions directly via the sietch commands below."
echo "Strongly recommend validating on the Dev VM first."
echo
read -r -p "Have you already validated 4 DD instances on Dev, and want to proceed on Prod? [y/N]: " dd_confirm
case "$dd_confirm" in
  y|Y|yes|YES)
    runtime/scripts/dune sietches set-max DeepDesert_1 4
    runtime/scripts/dune sietches set-active DeepDesert_1 4
    echo "Deep Desert configured for 4 concurrent instances. Validating..."
    runtime/scripts/dune sietches validate
    ;;
  *)
    echo "Skipping 4-instance Deep Desert config for now."
    echo "Prod will start with default single dynamic Deep Desert."
    echo "Re-run later with:"
    echo "    runtime/scripts/dune sietches set-max DeepDesert_1 4"
    echo "    runtime/scripts/dune sietches set-active DeepDesert_1 4"
    ;;
esac

echo
echo "=== Final status check ==="
runtime/scripts/dune status
runtime/scripts/dune ready || true

echo
echo "=== Prod battlegroup initialized ==="
echo "Next steps:"
echo "  1. Confirm docs/02-network-setup.md's port forwards are pointed at"
echo "     this VM's actual IP."
echo "  2. Run 'dune ports' here and check for any WARN lines about"
echo "     advertised vs. bound IP mismatches (same class of warning seen"
echo "     on the old gaming-PC box - resolve before going live)."
echo "  3. Test external reachability from OUTSIDE your LAN (e.g. phone on"
echo "     cellular data, or a friend) before telling your player base"
echo "     the outage is over."
