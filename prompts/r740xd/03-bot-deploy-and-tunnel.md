# R740XD-03: ACP Bot Deployment + Cloudflare Tunnel

This prompt is run FROM your dev machine (all steps are `ssh`/`scp`
commands targeting the VM — there's no separate "log into the console and
type these" step), but every actual change it makes lands ON the dune-prod
VM (`192.168.20.10`). It deploys the ACP Discord bot, configures the
Cloudflare Tunnel, applies security hardening, and runs end-to-end
verification.

## Target Machines
- dune-prod VM (`dune@192.168.20.10`) — everything below changes state here
- Your dev machine — only used as the SSH client; also needed for the
  Cloudflare Zero Trust dashboard (browser-based) in Phase 3.2

## Pre-Requisites
- `r740xd/02-game-servers.md` completed — both battlegroups initialized
- `tabr-tau/01-bot-secrets-rotation.md` completed — bot secrets already
  rotated off the values transferred from OCI; this prompt's Phase 1
  clone step expects rotated values already committed to dune-prod's
  `.env`, not the original OCI-sourced ones
- Cloudflare Zero Trust dashboard accessible in your browser (Phase 3.2)

## Phase 1: Clone and Deploy the Bot

### 1.1 Clone the Repository
```bash
ssh dune@192.168.20.10 << 'ENDSSH'
git clone https://github.com/yacketrj/arrakis-control-panel.git ~/arrakis-control-panel
cd ~/arrakis-control-panel
npm ci --omit=dev
cp .env.example .env

# Set the essential values (update with your real values)
sed -i "s|^DUNE_CONSOLE_API_URL=.*|DUNE_CONSOLE_API_URL=http://localhost:8088|" .env
# DISCORD_BOT_TOKEN: use the ROTATED value from tabr-tau/01-bot-secrets-rotation.md,
#   not the original value transferred from OCI in tabr-tau/00-prerequisites.md
# DISCORD_CLIENT_ID already set from tabr-tau/00-prerequisites.md
# DUNE_DISCORD_ADAPTER_TOKEN already set from tabr-tau/00-prerequisites.md
ENDSSH
```

### 1.2 Register Slash Commands
```bash
ssh dune@192.168.20.10 "cd ~/arrakis-control-panel && npm run register"
```

**VERIFY:** The command output shows registration success with no errors.

### 1.3 (Optional) Install Local Pre-Commit Hooks

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

### 1.4 Install and Enable Systemd Service
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

## Phase 2: Configure Cloudflare Tunnel

### 2.1 Add Ingress Rules (C-8 fix — Access is MANDATORY)
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

### 2.2 Enforce Cloudflare Access (C-8 — was "recommended", now MANDATORY)

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

## Phase 3: Configure Database Backup (C-4 fix)

### 3.1 ACP SQLite Daily Backup
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

## Phase 4: End-to-End Verification

### 4.1 Discord Bot Smoke Test
Run `/dune server health` in your Discord server. The bot must respond
with server status within 5 seconds.

### 4.2 Adapter Endpoint Verification
```bash
ssh dune@192.168.20.10 << 'ENDSSH'
# Test that the bot can reach the console adapter
ADAPTER_TOKEN=$(grep DUNE_DISCORD_ADAPTER_TOKEN ~/arrakis-control-panel/.env | cut -d= -f2)
curl -s -H "Authorization: Bearer ${ADAPTER_TOKEN}" \
  http://localhost:8088/api/integrations/discord/health | jq .
ENDSSH
```
Expected: `{"ok": true, ...}`

### 4.3 Cloudflare Tunnel Verification
```bash
# From your dev machine:
curl -s https://ACP_SETUP_TUNNEL_HOSTNAME/api/live-stats | jq .players_online
curl -s -o /dev/null -w '%{http_code}' https://CONSOLE_TUNNEL_HOSTNAME
```
Expected: live stats returns JSON with a `players_online` field.
Console returns `302` or `200` (redirect to Access login is OK).

### 4.4 Firewall Isolation Verification
From dune-dev VM, confirm Prod is unreachable:
```bash
ssh dune@192.168.21.10 "ping -c 3 -W 2 192.168.20.10; echo EXIT=\$?"
```
Expected: ping fails (non-zero exit). If it succeeds, VLAN isolation is
broken — go back to Phase 2.0 of `r740xd/01-proxmox-and-vms.md` and fix
`bridge-vlan-aware`.

## Phase 5: Deploy Remote Setup (for future git push deploys)

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
Proceed to `tabr-tau/04-e2e-verification.md` for the full go-live checklist.
