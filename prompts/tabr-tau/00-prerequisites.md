# TABR-TAU-00: Prerequisites — Gather Before Racking Hardware

This prompt runs on YOUR DEV MACHINE before the R740 is physically set up.
It gathers all tokens, keys, ISOs, and credentials needed during the
deployment so you're not hunting for them on stand-up day.

**Status on this deployment (2026-08-14):** Steps 1 and 5 verified
read-only, directly on the Tabr-Tau dev machine this prompt targets (the
R740xd-side session has no access to this host's filesystem, SSH keys, or
network vantage point to run these checks itself). Steps 2/3/4/6/7 remain
not started — see issue #57 for the full verification record and why each
of those steps is deliberately deferred (destructive, secret-handling, or
operator-credential-gated) rather than run automatically.

## Target Machine
Your current dev machine (Ubuntu 24.04).

## Pre-Requisites
- You have a password manager with the following stored (or will generate
  them during this prompt):
  - 2× Funcom Self-Host Service Tokens (accounts #1 and #2)
  - Discord bot token for the ACP bot
  - Discord application client ID
  - GitHub personal access token (for cloning private repos if needed)

## Steps

### 1. Verify Required Files Exist
```bash
ls ~/projects/dune/dune-awakening-selfhost-docker/runtime/scripts/dune
ls ~/projects/acp/arrakis-control-panel/package.json
ls ~/r740-deployment/prompts/tabr-tau/00-prerequisites.md
```
**Verified 2026-08-14:** all three paths present on the Tabr-Tau dev
machine.

### 2. Download Proxmox VE ISO
```bash
# Download to your dev machine for USB creation
wget -P /tmp/opencode/r740-isos/ \
  https://enterprise.proxmox.com/iso/proxmox-ve_8.2-1.iso
# Verify checksum matches the Proxmox downloads page
sha256sum /tmp/opencode/r740-isos/proxmox-ve_8.2-1.iso
```

### 3. Download Ubuntu Server 26.04 LTS ISO
```bash
wget -P /tmp/opencode/r740-isos/ \
  https://releases.ubuntu.com/26.04/ubuntu-26.04-live-server-amd64.iso
sha256sum /tmp/opencode/r740-isos/ubuntu-26.04-live-server-amd64.iso
# Verify against the published checksum:
# https://releases.ubuntu.com/26.04/SHA256SUMS
```

### 4. Prepare ACP Bot Secrets Backup

**This step describes a FUTURE, not-yet-scheduled bot migration.** The ACP
bot is a live, currently-running production service on its existing OCI
VPS as of this writing — this is not something to act on until that
migration is explicitly planned separately from the R740 game-server
stand-up. `OCI_BOT_IP` below is a placeholder — substitute your own real
value from your password manager/infra notes when actually executing this.

Copy the bot's secrets from the current OCI deployment or from secure
backup so they're ready to transfer to the R740. Create a secrets bundle:

```bash
mkdir -p ~/r740-bot-backup/secrets

# If you can SSH to the OCI instance:
ssh ubuntu@OCI_BOT_IP "cat ~/arrakis-control-panel/.env" \
  > ~/r740-bot-backup/secrets/bot-env.txt

# NOTE: chmod 600 (not 644) on the remote temp copy -- the SQLite DB
# contains per-guild adapter tokens; a world-readable temp copy on a
# shared host is the same class of exposure this project's own #28
# finding flagged for the local staging directory.
ssh ubuntu@OCI_BOT_IP "sudo cp ~/arrakis-control-panel/data/acp.db /tmp/ && sudo chmod 600 /tmp/acp.db" \
  && scp ubuntu@OCI_BOT_IP:/tmp/acp.db ~/r740-bot-backup/secrets/ \
  && ssh ubuntu@OCI_BOT_IP "shred -u /tmp/acp.db"

# Or, if you already have the .env backed up locally:
# Copy it from your secure backup location to ~/r740-bot-backup/secrets/

chmod 600 ~/r740-bot-backup/secrets/*
```

Verify the bot-env.txt contains at minimum:
- `DISCORD_BOT_TOKEN=`
- `DISCORD_CLIENT_ID=`
- `DUNE_CONSOLE_API_URL=` (will be changed to `http://localhost:8088`)
- `DUNE_DISCORD_ADAPTER_TOKEN=`

### 5. Verify SSH Keys
```bash
# The SSH key used for deploy remote (issue #81)
ls -la ~/.ssh/ssh-key-2026-07-18.key
chmod 600 ~/.ssh/ssh-key-2026-07-18.key
```
**Verified 2026-08-14:** already `600`, no change needed.

### 6. Gather Network Values
Fill in `r740-deployment/docs/values.env.example` with your actual values.
Copy it to a gitignored file:

```bash
cp ~/r740-deployment/docs/values.env.example ~/r740-deployment/docs/values.env
# Edit values.env with your real public IP, server names, region
```

Complete this checklist:
- [ ] `PUBLIC_IP=` filled in (use `curl -s https://api.ipify.org` from the gaming PC or router)
- [ ] `SERVER_TITLE_PROD=` set (e.g., "Tabr Tau")
- [ ] `SERVER_TITLE_DEV=` set (e.g., "Tabr Tau - Dev")
- [ ] `SERVER_REGION=` set
- [ ] Funcom tokens noted (which account goes to which VM)

### 7. Create Bootable Proxmox USB
Using a USB drive (8 GB+):
```bash
# WARNING: /dev/sdX must be your USB device. Check with lsblk first.
# This DESTROYS all data on the target device.
#
# On Linux:
sudo dd if=/tmp/opencode/r740-isos/proxmox-ve_8.2-1.iso \
  of=/dev/sdX bs=4M status=progress conv=fsync
```

### 8. Final Checklist Before Moving to r740xd/01
- [ ] Proxmox VE ISO downloaded and verified
- [ ] Ubuntu Server 26.04 ISO downloaded and verified
- [ ] Bootable Proxmox USB created
- [ ] Bot secrets backed up to `~/r740-bot-backup/secrets/`
- [ ] `values.env` filled in with real values
- [x] SSH keys verified (2026-08-14 — already `600`, see Step 5)
- [ ] 2× Funcom tokens generated and stored in password manager
- [ ] R740 racked, powered, network cabled to UCG-Max

## After This Prompt Completes
Proceed to `r740xd/01-proxmox-and-vms.md` which runs ON THE PROXMOX HOST
after booting from the USB you just created.
