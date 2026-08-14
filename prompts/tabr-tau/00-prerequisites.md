# TABR-TAU-00: Prerequisites — Gather Before Racking Hardware

**Scope note (2026-08-14):** this prompt runs in its own, separate
session on YOUR DEV MACHINE and is strictly limited to gathering
credentials, tokens, and configuration values — nothing that installs,
configures, or connects to R740-side infrastructure. All installation
and configuration work (ISO acquisition, Proxmox install, VM
provisioning, bot deployment) happens exclusively in `r740xd/*` prompts,
run in their own separate session, on/against the R740 itself. If a step
here ever needs to SSH into a VM or the Proxmox host, that step belongs
in `r740xd/`, not here — see issue #59 for the audit that established
this boundary and moved several misplaced steps out of this file.

**Status on this deployment (2026-08-14):** Steps 1 and 3 verified
read-only, directly on the Tabr-Tau dev machine this prompt targets (the
R740xd-side session has no access to this host's filesystem, SSH keys, or
network vantage point to run these checks itself). See issue #57 for the
full verification record.

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

### 2. Verify SSH Keys
```bash
# The SSH key used for deploy remote (issue #81)
ls -la ~/.ssh/ssh-key-2026-07-18.key
chmod 600 ~/.ssh/ssh-key-2026-07-18.key
```
**Verified 2026-08-14:** already `600`, no change needed.

### 3. Gather Network Values
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

**Verified 2026-08-14 (partial):** current public IP confirmed via
`curl https://api.ipify.org` — matches the IP already live in the
current Dev battlegroup's own `dune status` output, no drift. The real
`values.env` file itself has not yet been created (correct, expected
state — nothing to leak).

### 4. Prepare ACP Bot Secrets Backup (gathering only — do not act on migration timing)

**This step describes gathering secrets for a FUTURE, not-yet-scheduled
bot migration.** The ACP bot is a live, currently-running production
service on its existing OCI VPS as of this writing — the actual
migration (stopping the OCI bot, deploying to dune-prod, rotating
secrets) is R740-side work that happens entirely in
`r740xd/03-bot-deploy-and-tunnel.md`'s own Phase 1, not here. This step
only stages a
local backup bundle on your dev machine so those later steps have
something to work from — it does not SSH into or configure `dune-prod`.
`OCI_BOT_IP` below is a placeholder — substitute your own real value
from your password manager/infra notes when actually executing this.

```bash
mkdir -p ~/r740-bot-backup/secrets

# If you can SSH to the OCI instance (this is the CURRENT production
# host, not the R740 -- reading its own existing secrets is gathering,
# not R740-side configuration):
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
- `DUNE_CONSOLE_API_URL=` (will be changed to `http://localhost:8088`
  during the actual R740-side deployment, not here)
- `DUNE_DISCORD_ADAPTER_TOKEN=`

### 5. Final Checklist Before Moving to r740xd/01
- [ ] `values.env` filled in with real values
- [x] SSH keys verified (2026-08-14 — already `600`, see Step 2)
- [ ] 2× Funcom tokens generated and stored in password manager
- [ ] Bot secrets backup staged to `~/r740-bot-backup/secrets/` (Step 4)
- [ ] R740 racked, powered, network cabled to UCG-Max

## After This Prompt Completes
Start a NEW, separate session and proceed to `r740xd/01-proxmox-and-vms.md`,
which runs ON THE PROXMOX HOST itself. That prompt handles ISO
acquisition (Proxmox VE + Ubuntu Server), the actual Proxmox install, and
VM provisioning — none of which belongs in this gathering-only session.
