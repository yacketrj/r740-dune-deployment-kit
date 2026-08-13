#!/usr/bin/env bash
# =============================================================================
# 03-vm-guest-bootstrap.sh
#
# RUN THIS: INSIDE each VM (dune-prod AND dune-dev), after Ubuntu Server
#           26.04 is installed and you can SSH in. Run it once per VM.
# PURPOSE:  Confirm AVX2 is visible inside the guest (final sanity check),
#           install Docker, clone the dune-awakening-selfhost-docker repo,
#           and prep the directory structure. Stops BEFORE running `dune
#           init` - that's a deliberate manual step in the next script,
#           since it prompts for the Funcom token interactively.
#
# USAGE: bash 03-vm-guest-bootstrap.sh
# =============================================================================
set -euo pipefail

echo "=== Guest Bootstrap: $(hostname) ==="
echo

# --- Final AVX2 sanity check, inside the actual guest -----------------------
echo "--- Confirming AVX2 inside this guest ---"
if grep -q avx2 /proc/cpuinfo; then
  echo "OK: AVX2 present in this VM's /proc/cpuinfo."
else
  echo "FAIL: AVX2 NOT present in this guest. Do not proceed."
  echo "Go back to the Proxmox host and confirm this VM's CPU type is"
  echo "'host', not a generic model. Fix and reboot this VM before"
  echo "re-running this script."
  exit 1
fi
echo

# --- Basic OS prep -----------------------------------------------------------
echo "--- Updating base system ---"
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y ca-certificates curl gnupg git tar

# --- Docker install (per repo's own documented bootstrap pattern) ----------
echo
echo "--- Installing Docker Engine + Compose plugin ---"
if command -v docker >/dev/null 2>&1; then
  echo "Docker already installed, skipping."
else
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker
  sudo usermod -aG docker "$USER"
  echo
  echo "Docker installed. You added yourself to the 'docker' group - this"
  echo "requires a fresh login/shell to take effect. Log out and back in"
  echo "(or run 'newgrp docker') before continuing."
fi

docker --version
docker compose version

# --- Clone the repo -----------------------------------------------------------
echo
echo "--- Cloning dune-awakening-selfhost-docker ---"
REPO_DIR="$HOME/dune-awakening-selfhost-docker"
if [ -d "$REPO_DIR" ]; then
  echo "Repo directory already exists at $REPO_DIR, skipping clone."
  echo "If you want a fresh clone, remove it first: rm -rf $REPO_DIR"
else
  latest_url="$(curl -fsSLI -o /dev/null -w "%{url_effective}" \
    https://github.com/yacketrj/dune-awakening-selfhost-docker/releases/latest)"
  version="${latest_url##*/}"
  mkdir -p "$REPO_DIR"
  cd "$REPO_DIR"
  curl -fsSL "https://github.com/yacketrj/dune-awakening-selfhost-docker/archive/refs/tags/${version}.tar.gz" \
    | tar -xz --strip-components=1
  chmod +x install.sh
  echo "Cloned release ${version} into $REPO_DIR"
fi

echo
echo "=== Guest bootstrap complete on $(hostname) ==="
echo
echo "NEXT STEP:"
echo "  If this is dune-dev: run 04-init-dev-battlegroup.sh"
echo "  If this is dune-prod: run 05-init-prod-battlegroup.sh"
echo
echo "Both scripts expect to be run from: $REPO_DIR"
