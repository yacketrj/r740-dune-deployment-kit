# TABR-TAU-01: Rotate Bot Secrets Migrated from OCI

This prompt runs ON YOUR DEV MACHINE. It rotates the ACP Discord bot's
secrets before they're relied upon in the new deployment — the token
values transferred from the OCI backup (`tabr-tau/00-prerequisites.md`)
should never be the ones actually used going forward, since they existed
on a host now being decommissioned and may exist in orphaned volumes or
backup copies.

**This prompt only touches dune-prod's `.env` file via a single remote
`sed` per step — it does not deploy, clone, or configure anything else on
the VM.** The actual bot deployment, systemd service, and Cloudflare
Tunnel configuration happen in `r740xd/03-bot-deploy-and-tunnel.md`, which
depends on this prompt completing first (that prompt clones the repo
fresh and expects `.env` values to already be rotated).

## Target Machines
- Your dev machine (Discord Developer Portal, Cloudflare dashboard —
  browser-based work)
- dune-prod VM (`dune@192.168.20.10`) — touched only for a few remote
  `.env` edits, not full configuration

## Pre-Requisites
- `r740xd/02-game-servers.md` completed — both battlegroups initialized
- Bot secrets backed up to `~/r740-bot-backup/secrets/` from
  `tabr-tau/00-prerequisites.md`
- Cloudflare Zero Trust dashboard accessible in your browser
- Discord Developer Portal accessible in your browser

## Phase 1: Rotate Secrets Migrated from OCI (C-6 fix)

### 1.1 Rotate Discord Bot Token
The bot token was copied from the decommissioned OCI instance. It may
exist on orphaned OCI volumes or in backup copies. Rotate immediately:

1. Discord Developer Portal → Your Application → Bot → **Reset Token**
2. Copy the new token string
3. Update on dune-prod:
   ```bash
   ssh dune@192.168.20.10
   cd ~/arrakis-control-panel
   sed -i "s/^DISCORD_BOT_TOKEN=.*/DISCORD_BOT_TOKEN=<NEW_TOKEN>/" .env
   ```

### 1.2 Rotate Discord OAuth Client Secret (CLOUD-03 fix)
If multi-tenant mode uses `DISCORD_CLIENT_SECRET`:

1. Discord Developer Portal → OAuth2 → **Reset Client Secret**
2. Update `.env` on dune-prod:
   ```bash
   sed -i "s/^DISCORD_CLIENT_SECRET=.*/DISCORD_CLIENT_SECRET=<NEW_SECRET>/" .env
   ```

### 1.3 Generate ACP_SECRETS_KEY (CLOUD-08 fix)
If `ACP_MULTI_TENANT=true` and `ACP_SECRETS_KEY` is unset, per-guild
adapter tokens in the SQLite database are stored in plaintext:

```bash
ssh dune@192.168.20.10
cd ~/arrakis-control-panel
KEY=$(node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")
echo "ACP_SECRETS_KEY=${KEY}" >> .env
echo "ACP_SECRETS_KEY generated. Existing plaintext tokens in acp.db will"
echo "need re-provisioning via the setup portal."
```

### 1.4 Shred Backup Copies of Secrets
After rotation, delete the secrets backup on both machines:
```bash
# On dev machine:
shred -u ~/r740-bot-backup/secrets/bot-env.txt
shred -u ~/r740-bot-backup/secrets/acp.db
rm -rf ~/r740-bot-backup/secrets/

# On dune-prod VM:
ssh dune@192.168.20.10 "shred -u ~/r740-bot-backup/secrets/* && rm -rf ~/r740-bot-backup/"
```

## State After Completion
- [ ] Discord bot token rotated (C-6)
- [ ] OAuth client secret rotated if multi-tenant (CLOUD-03)
- [ ] ACP_SECRETS_KEY generated if multi-tenant (CLOUD-08)
- [ ] Old secrets backup copies shredded

## After This Prompt Completes
Proceed to `r740xd/03-bot-deploy-and-tunnel.md`, which clones the bot repo
fresh onto dune-prod and expects these rotated values to already be in
place.
