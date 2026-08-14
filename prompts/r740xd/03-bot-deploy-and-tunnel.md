# R740XD-03: ACP Bot Deployment + Cloudflare Tunnel

This prompt runs in its own session, executed FROM your dev machine's
terminal via `ssh`/`scp` (there's no separate "log into the console and
type these" step), but every actual change it makes lands ON the
dune-prod VM (`192.168.20.10`) — this is R740xd-side configuration work,
not a Tabr-Tau gathering step, regardless of which physical keyboard
you're typing on (see issue #59's session boundary). It rotates the
bot's secrets off the values transferred from OCI, clones and deploys
the bot, configures the Cloudflare Tunnel, applies security hardening,
and runs end-to-end verification.

## Target Machines
- dune-prod VM (`dune@192.168.20.10`) — everything below changes state here
- Your dev machine — only used as the SSH client; also needed for the
  Discord Developer Portal and Cloudflare Zero Trust dashboard
  (browser-based, Phase 1 and Phase 3.2)

## Pre-Requisites
- `r740xd/02-game-servers.md` completed — both battlegroups initialized
- `tabr-tau/00-prerequisites.md` completed — bot secrets staged locally
  to `~/r740-bot-backup/secrets/`, Discord/Funcom credentials ready in
  your password manager (that prompt only gathers/stages; it does not
  rotate or deploy anything)
- Discord Developer Portal accessible in your browser (Phase 1)
- Cloudflare Zero Trust dashboard accessible in your browser (Phase 3.2)

## Phase 1: Rotate Secrets Migrated from OCI (C-6 fix)

The bot token/secrets staged in `~/r740-bot-backup/secrets/` (from
`tabr-tau/00-prerequisites.md`) were copied from the still-live OCI
instance. They must never be the ones actually used going forward — the
old host, or backups of it, could retain access to them indefinitely.
Rotate BEFORE cloning/deploying the bot below, not after.

### 1.1 Rotate Discord Bot Token
1. Discord Developer Portal → Your Application → Bot → **Reset Token**
2. Copy the new token string — you'll use it in Phase 2's `.env` setup
   below, not written anywhere yet.

### 1.2 Rotate Discord OAuth Client Secret (CLOUD-03 fix)
If multi-tenant mode uses `DISCORD_CLIENT_SECRET`:
1. Discord Developer Portal → OAuth2 → **Reset Client Secret**
2. Copy the new secret — same as above, used in Phase 2.

### 1.3 Shred the Staged Secrets Backup (on your dev machine)
Once you've copied the values you need from
`~/r740-bot-backup/secrets/bot-env.txt` for Phase 2 below, shred the
local staging copy — it should not persist once its values are in use:
```bash
# On your dev machine:
shred -u ~/r740-bot-backup/secrets/bot-env.txt
shred -u ~/r740-bot-backup/secrets/acp.db
rm -rf ~/r740-bot-backup/secrets/
```

## Phase 2: Clone and Deploy the Bot

### 2.1 Clone the Repository
```bash
ssh dune@192.168.20.10 << 'ENDSSH'
git clone https://github.com/yacketrj/arrakis-control-panel.git ~/arrakis-control-panel
cd ~/arrakis-control-panel
npm ci --omit=dev
cp .env.example .env

# Set the essential values (update with your real values)
sed -i "s|^DUNE_CONSOLE_API_URL=.*|DUNE_CONSOLE_API_URL=http://localhost:8088|" .env
# DISCORD_BOT_TOKEN: use the ROTATED value from Phase 1.1 above, NOT the
#   original value staged from OCI in tabr-tau/00-prerequisites.md
# DISCORD_CLIENT_ID: from tabr-tau/00-prerequisites.md (this one doesn't
#   need rotation -- it's a public identifier, not a secret)
# DISCORD_CLIENT_SECRET: use the ROTATED value from Phase 1.2 above, if
#   multi-tenant mode is enabled
# DUNE_DISCORD_ADAPTER_TOKEN: from tabr-tau/00-prerequisites.md
ENDSSH
```

### 2.2 Generate ACP_SECRETS_KEY (CLOUD-08 fix, if multi-tenant)
If `ACP_MULTI_TENANT=true`, per-guild adapter tokens in the SQLite
database are stored in plaintext unless this key is set:
```bash
ssh dune@192.168.20.10 << 'ENDSSH'
cd ~/arrakis-control-panel
KEY=$(node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")
echo "ACP_SECRETS_KEY=${KEY}" >> .env
echo "ACP_SECRETS_KEY generated. Existing plaintext tokens in acp.db will"
echo "need re-provisioning via the setup portal."
ENDSSH
```

### 2.3 Register Slash Commands
```bash
ssh dune@192.168.20.10 "cd ~/arrakis-control-panel && npm run register"
```

**VERIFY:** The command output shows registration success with no errors.

### 2.4 (Optional) Install Local Pre-Commit Hooks

**Only needed if you plan to edit the bot's code directly on this VM**
(debugging, quick fixes) rather than exclusively pushing from your dev
machine via `git push deploy` (the intended workflow — see Phase 6). The
bot repo already ships its own `.pre-commit-config.yaml`
(gitleaks/ggshield/trivy) that travels with the clone; this just activates
it locally so a direct commit on this VM gets the same scan coverage your
dev machine's commits already get, rather than only catching issues later
in CI:

```bash
ssh dune@192.168.20.10 << 'ENDSSH'
cd ~/arrakis-control-panel
python3 -m pip install --user pre-commit 2>/dev/null || sudo apt-get install -y pipx python3-pip && python3 -m pip install --user pre-commit
pre-commit install
ENDSSH
```

Skip this step entirely if this VM will only ever receive deploys via
`git push deploy` and no one edits code on it directly.

### 2.5 Install and Enable Systemd Service
```bash
ssh dune@192.168.20.10 << 'ENDSSH'
sudo cp ~/arrakis-control-panel/systemd/acp-bot.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable acp-bot.service
sudo systemctl start acp-bot.service
sudo systemctl status acp-bot.service
ENDSSH
```

**VERIFY:** `systemctl status` shows `active (running)`. Check logs:
```bash
ssh dune@192.168.20.10 "journalctl -u acp-bot -n 30 --no-pager"
```
The bot should show "Ready!" and connect to Discord's gateway.

## Phase 3: Configure Cloudflare Tunnel

### 3.1 Add Ingress Rules (C-8 fix — Access is MANDATORY)
Edit `/etc/cloudflared/config.yml` on the dune-prod VM:

```yaml
tunnel: <your-tunnel-id>
credentials-file: /home/dune/.cloudflared/<tunnel-id>.json

ingress:
  # Console admin — MUST have Cloudflare Access policy
  - hostname: CONSOLE_TUNNEL_HOSTNAME
    service: http://localhost:8088

  # ACP setup portal + live stats API
  - hostname: ACP_SETUP_TUNNEL_HOSTNAME
    service: http://localhost:3100

  # Steam OAuth callback (was missing — network engineer finding F3)
  - hostname: ACP_SETUP_TUNNEL_HOSTNAME
    path: /auth/steam
    service: http://localhost:3101

  # Catch-all
  - service: http_status:404
```

**Coordinate this change carefully**: the same Cloudflare account's
tunnel/DDNS infrastructure is shared with other independent services
(e.g. the ACP landing page and other sites using the same Cloudflare DDNS
setup) — verify you are only adding new ingress rules for these
hostnames, not modifying shared tunnel config that other services depend
on.

Restart the tunnel:
```bash
ssh dune@192.168.20.10 "sudo systemctl restart cloudflared && sudo systemctl status cloudflared"
```
This restarts the ENTIRE tunnel daemon, not just these ingress rules —
confirm current status of every hostname/service sharing this tunnel
before restarting, per this project's own Requirement 23 on documenting
network ingress points.

### 3.2 Enforce Cloudflare Access (C-8 — was "recommended", now MANDATORY)

**This step is NOT optional.** Without it, anyone who discovers the
hostname can reach the admin console login page. The console mounts the
Docker socket — reaching that page is one password away from root-equivalent
VM access.

1. Cloudflare Zero Trust Dashboard → Access → Applications → **Add Application**
2. Type: **Self-hosted**
3. Application name: `Dune Console`
4. Subdomain: `CONSOLE_TUNNEL_HOSTNAME`
5. Identity providers: Accept all (or add your email provider)
6. **Create policy:**
   - Policy name: `Admin Only`
   - Action: **Allow**
   - Include → Emails → `your-email@example.com`
   - (Add any additional trusted operators)
7. Save policy → **repeat for `ACP_SETUP_TUNNEL_HOSTNAME`** (at minimum,
   protect the `/auth/steam` path)
8. Save and close

**VERIFY:** Open an incognito/private browser window and navigate to
`https://CONSOLE_TUNNEL_HOSTNAME`. You MUST see a Cloudflare Access login
page (email/PIN prompt) BEFORE reaching the Dune Console login. If you
see the console login directly, Access is NOT configured.

## Phase 4: Configure Database Backup (C-4 fix)

### 4.1 ACP SQLite Daily Backup
Create a systemd timer on the dune-prod VM:

```bash
ssh dune@192.168.20.10 << 'ENDSSH'
sudo tee /etc/systemd/system/acp-db-backup.service << 'UNIT'
[Unit]
Description=ACP Bot SQLite Database Backup
After=network.target

[Service]
Type=oneshot
User=dune
ExecStart=/bin/bash -c '\
  BACKUP_DIR="/home/dune/arrakis-control-panel/data/backups"; \
  mkdir -p "$BACKUP_DIR"; \
  DB="/home/dune/arrakis-control-panel/data/acp.db"; \
  if [ -f "$DB" ]; then \
    cp "$DB" "$BACKUP_DIR/acp-$(date +%%Y%%m%%d-%%H%%M%%S).db"; \
    find "$BACKUP_DIR" -name "acp-*.db" -mtime +30 -delete; \
  fi'
UNIT

sudo tee /etc/systemd/system/acp-db-backup.timer << 'UNIT'
[Unit]
Description=Daily ACP Bot SQLite Backup

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now acp-db-backup.timer
sudo systemctl start acp-db-backup.service
ENDSSH
```

**VERIFY:**
```bash
ssh dune@192.168.20.10 "ls -la ~/arrakis-control-panel/data/backups/ && systemctl list-timers acp-db-backup.timer"
```

## Phase 5: End-to-End Verification

### 5.1 Discord Bot Smoke Test
Run `/dune server health` in your Discord server. The bot must respond
with server status within 5 seconds.

### 5.2 Adapter Endpoint Verification
```bash
ssh dune@192.168.20.10 << 'ENDSSH'
# Test that the bot can reach the console adapter
ADAPTER_TOKEN=$(grep DUNE_DISCORD_ADAPTER_TOKEN ~/arrakis-control-panel/.env | cut -d= -f2)
curl -s -H "Authorization: Bearer ${ADAPTER_TOKEN}" \
  http://localhost:8088/api/integrations/discord/health | jq .
ENDSSH
```
Expected: `{"ok": true, ...}`

### 5.3 Cloudflare Tunnel Verification
```bash
# From your dev machine:
curl -s https://ACP_SETUP_TUNNEL_HOSTNAME/api/live-stats | jq .players_online
curl -s -o /dev/null -w '%{http_code}' https://CONSOLE_TUNNEL_HOSTNAME
```
Expected: live stats returns JSON with a `players_online` field.
Console returns `302` or `200` (redirect to Access login is OK).

### 5.4 Firewall Isolation Verification
From dune-dev VM, confirm Prod is unreachable:
```bash
ssh dune@192.168.21.10 "ping -c 3 -W 2 192.168.20.10; echo EXIT=\$?"
```
Expected: ping fails (non-zero exit). If it succeeds, VLAN isolation is
broken — go back to Phase 2.0 of `r740xd/01-proxmox-and-vms.md` and fix
`bridge-vlan-aware`.

## Phase 6: Deploy Remote Setup (for future git push deploys)

```bash
ssh dune@192.168.20.10 << 'ENDSSH'
mkdir -p ~/acp-deploy.git && cd ~/acp-deploy.git && git init --bare
cp ~/arrakis-control-panel/scripts/deploy-post-receive.sh hooks/post-receive
chmod +x hooks/post-receive
ENDSSH

# On your dev machine, add the deploy remote:
git -C ~/projects/acp/arrakis-control-panel remote add deploy \
  ssh://dune@192.168.20.10/home/dune/acp-deploy.git
```

## State After Completion
- [ ] Discord bot token rotated (C-6)
- [ ] OAuth client secret rotated if multi-tenant (CLOUD-03)
- [ ] Staged secrets backup shredded on dev machine
- [ ] ACP_SECRETS_KEY generated if multi-tenant (CLOUD-08)
- [ ] ACP bot cloned, installed, running on dune-prod VM
- [ ] Systemd service `acp-bot.service` active and enabled
- [ ] Cloudflare Tunnel ingress rules configured (incl. Steam port 3101)
- [ ] Cloudflare Access MANDATORY policy in front of CONSOLE_TUNNEL_HOSTNAME
- [ ] SQLite daily backup timer created and active (C-4)
- [ ] Bot responds to slash commands in Discord
- [ ] All adapter endpoints verified
- [ ] VLAN isolation verified
- [ ] Deploy remote configured

## After This Prompt Completes
Start a NEW, separate session on your dev machine and proceed to
`tabr-tau/04-e2e-verification.md` for the full go-live checklist — that
prompt's own scope has been narrowed to dev-machine-appropriate checks
only (running the automated verification script, external WAN/browser
tests); see issue #59.
