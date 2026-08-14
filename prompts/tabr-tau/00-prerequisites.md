# TABR-TAU-00: Prerequisites — Gather Before Racking Hardware

You are an LLM coding agent running in your own, separate session on the
user's DEV MACHINE (Tabr-Tau). Your scope in this session is gathering
only: collect credentials, tokens, and configuration values, and verify
their presence/permissions. Do not install, configure, or connect to
any R740-side infrastructure (Proxmox host or either VM) in this
session — that work belongs exclusively to the `r740xd/*` prompts, which
run in their own separate sessions, targeting the R740 itself. If any
step in this file ever appears to require SSH-ing into a VM or the
Proxmox host, stop and tell the user that step belongs in `r740xd/`
instead — see issue #59 for the audit that established this boundary and
moved several misplaced steps out of this file. Never weaken this
boundary just because it would be technically possible to reach the R740
from this machine.

**Status on this deployment (2026-08-14):** Steps 1 and 3 have already
been verified read-only, directly on this dev machine (a prior R740xd
session has no access to this host's filesystem, SSH keys, or network
vantage point to run these checks itself). See issue #57 for the full
verification record. Re-verify rather than assume these are still true
if meaningful time has passed or the environment may have changed.

## Target Machine
Your current dev machine (Ubuntu 26.04). Do not target anything else.

## Before You Start
Confirm the user has, or is ready to generate during this session:
- 2× Funcom Self-Host Service Tokens (accounts #1 and #2)
- Discord bot token for the ACP bot
- Discord application client ID
- GitHub personal access token (for cloning private repos if needed)

Ask the user for any of these you don't already have, rather than
guessing or leaving a placeholder unfilled.

## Steps

### 1. Verify Required Files Exist
Run:
```bash
ls ~/projects/dune/dune-awakening-selfhost-docker/runtime/scripts/dune
ls ~/projects/acp/arrakis-control-panel/package.json
ls ~/r740-deployment/prompts/tabr-tau/00-prerequisites.md
```
Report back which paths exist and which don't. If any are missing, stop
and ask the user how they want to proceed rather than assuming an
alternate path.

**Verified 2026-08-14:** all three paths present on the Tabr-Tau dev
machine.

### 2. Verify SSH Keys
Run:
```bash
# The SSH key used for deploy remote (arrakis-control-panel#81 -- a
# different repo; #81 does not exist in this repo)
ls -la ~/.ssh/ssh-key-2026-07-18.key
chmod 600 ~/.ssh/ssh-key-2026-07-18.key
```
Confirm the permissions are `600` after running this. Report the result.

**Verified 2026-08-14:** already `600`, no change needed.

### 3. Gather Network Values
Fill in `r740-deployment/docs/values.env.example` with the user's actual
values. Copy it to a gitignored file first — never edit the `.example`
file itself with real values:

```bash
cp ~/r740-deployment/docs/values.env.example ~/r740-deployment/docs/values.env
# Edit values.env with the real public IP, server names, region
```

Populate and confirm each of the following, asking the user for any
value you cannot determine yourself:
- `PUBLIC_IP=` (determine via `curl -s https://api.ipify.org` run from
  the gaming PC or router, not from this dev machine if it's on a
  different network)
- `SERVER_TITLE_PROD=` (e.g., "Tabr Tau")
- `SERVER_TITLE_DEV=` (e.g., "Tabr Tau - Dev")
- `SERVER_REGION=`
- Funcom tokens noted (which account goes to which VM)

Report which of these are filled in and which still need the user's
input. Never invent a placeholder value and present it as real.

**Verified 2026-08-14 (partial):** current public IP confirmed via
`curl https://api.ipify.org` — matches the IP already live in the
current Dev battlegroup's own `dune status` output, no drift. The real
`values.env` file itself has not yet been created (correct, expected
state — nothing to leak).

### 4. Prepare ACP Bot Secrets Backup (gathering only — do not act on migration timing)

This step gathers secrets for a FUTURE, not-yet-scheduled bot migration.
The ACP bot is a live, currently-running production service on its
existing OCI VPS as of this writing — the actual migration (stopping the
OCI bot, deploying to dune-prod, rotating secrets) is R740-side work that
happens entirely in `r740xd/03-bot-deploy-and-tunnel.md`'s own Phase 1,
not here. This step only stages a local backup bundle on this dev
machine so those later steps have something to work from — it must not
SSH into or configure `dune-prod`. `OCI_BOT_IP` below is a placeholder —
ask the user for the real value (from their password manager/infra
notes) before running these commands; never guess or fabricate it.

```bash
mkdir -p ~/r740-bot-backup/secrets

# Reading the CURRENT production host's (OCI, not the R740) own existing
# secrets is gathering, not R740-side configuration:
ssh ubuntu@OCI_BOT_IP "cat ~/arrakis-control-panel/.env" \
  > ~/r740-bot-backup/secrets/bot-env.txt

# Use chmod 600 (not 644) on the remote temp copy -- the SQLite DB
# contains per-guild adapter tokens; a world-readable temp copy on a
# shared host is the same class of exposure this project's own #28
# finding flagged for the local staging directory.
ssh ubuntu@OCI_BOT_IP "sudo cp ~/arrakis-control-panel/data/acp.db /tmp/ && sudo chmod 600 /tmp/acp.db" \
  && scp ubuntu@OCI_BOT_IP:/tmp/acp.db ~/r740-bot-backup/secrets/ \
  && ssh ubuntu@OCI_BOT_IP "shred -u /tmp/acp.db"

chmod 600 ~/r740-bot-backup/secrets/*
```

Verify `bot-env.txt` contains at minimum the following keys, and report
which are present/missing (never print the actual secret values back to
the user in chat). Check key *names* only via `grep -q`/`grep -c`, never
the file's contents:
- `DISCORD_BOT_TOKEN=` OR `DISCORD_BOT_TOKEN_FILE=` (issue #78 — this
  deployment uses the `_FILE` pattern for this key, pointing at a
  secret file elsewhere on the host rather than storing the token
  inline; both forms are valid, prefer `_FILE` per this project's own
  Requirement 24)
- `DISCORD_CLIENT_ID=`
- `DUNE_CONSOLE_API_URL=` (will be changed to `http://localhost:8088`
  during the actual R740-side deployment, not here)
- `DUNE_DISCORD_ADAPTER_TOKEN=` OR `DUNE_DISCORD_ADAPTER_TOKEN_FILE=`
  (issue #78 — same `_FILE` pattern as above)

### 5. Report Final Status Before Moving to r740xd/01
Report the status of each of the following back to the user as a
checklist, explicitly marking each item done/not-done:
- `values.env` filled in with real values
- SSH keys verified (permissions `600`)
- 2× Funcom tokens generated and stored in the user's password manager
- Bot secrets backup staged to `~/r740-bot-backup/secrets/` (Step 4)
- R740 racked, powered, network cabled to UCG-Max (ask the user to
  confirm this — you have no way to verify it from this session)

## When This Prompt Is Done
Tell the user to start a NEW, separate session and run
`r740xd/01-proxmox-and-vms.md`, which runs ON THE PROXMOX HOST itself.
That prompt handles ISO acquisition (Proxmox VE + Ubuntu Server), the
actual Proxmox install, and VM provisioning — none of which belongs in
this gathering-only session. Do not attempt any of that work yourself in
this session even if asked; redirect to the correct prompt/session.
</content>
