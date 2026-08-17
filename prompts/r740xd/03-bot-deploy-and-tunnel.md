# R740XD-03: ACP Bot Deployment + Cloudflare Tunnel

You are an LLM coding agent running in your own session, executed from
the dev machine's terminal via `ssh`/`scp` (there's no separate "log into
the console and type these" step), but every actual change you make
lands ON the dedicated bot VM (`192.168.22.10`, VMID 103, "Services"
VLAN 22) — this is R740xd-side configuration work, not a Tabr-Tau
gathering step, regardless of which physical keyboard you're typing on
(see issue #59's session boundary). Your job in this session: provision
the bot VM if it doesn't exist yet, rotate the bot's secrets off the
values transferred from OCI, clone and deploy the bot, configure the
Cloudflare Tunnel, apply security hardening, and run end-to-end
verification.

**Update (2026-08-17, issue #93):** this prompt previously targeted the
`dune-prod` VM directly (`192.168.20.10`). That decision was reversed —
co-locating a public-facing Discord bot process with the live game
server increases blast radius for no benefit (if the bot is ever
compromised, production is directly exposed). The bot now gets its own
dedicated VM on a new "Services" VLAN, isolated from both game-server
VMs and the Proxmox hypervisor itself — see issue #93 for the full
decision record (which also rejected running the bot directly on the
Proxmox host, `arrakis-control-panel#166`, for the same reason applied
to the hypervisor's own risk profile).

## Target Machines
- **Bot VM** (`bot@192.168.22.10`, VMID 103, "acp-bot") — everything
  below changes state here. If this VM doesn't exist yet, see Phase 0
  below (provisioning) before Phase 1.
- The dev machine — only used as the SSH client; the user will also need
  browser access to the Discord Developer Portal and Cloudflare Zero
  Trust dashboard (Phase 1 and Phase 3.2) — you cannot drive those
  browser steps yourself, walk the user through them.

## Before You Start, Confirm
- `docs/02-network-setup.md` Steps 1-4 completed for the Services VLAN
  (22) specifically — network created, bridge-vids includes 22, trunk
  port carries it, and the `Services-Zone` policies (issue #93) exist
  and are verified in both directions, not just the Allow direction
- `r740xd/02-game-servers.md` completed — both battlegroups initialized
  (the bot needs both consoles' adapter APIs reachable, which requires
  both VMs to already exist and be running)
- `tabr-tau/00-prerequisites.md` completed — bot secrets staged locally
  to `~/r740-bot-backup/secrets/`, Discord/Funcom credentials ready in
  the user's password manager (that prompt only gathers/stages; it does
  not rotate or deploy anything — do not assume it did)
- The user has Discord Developer Portal access ready (Phase 1)
- The user has Cloudflare Zero Trust dashboard access ready (Phase 3.2)

## Phase 0: Provision the Bot VM (if it doesn't exist yet)

Follow the exact same pattern as `r740xd/01-proxmox-and-vms.md` Phase 3,
scaled down for a Discord bot's actual resource needs (2 vCPU / 4 GB RAM
is generous — this is not a resource-constrained sizing decision, purely
an isolation one; see issue #93):

```bash
# On the Proxmox host, as root:
qm create 103 \
  --name acp-bot \
  --memory 4096 \
  --balloon 0 \
  --cores 2 \
  --sockets 1 \
  --cpu host \
  --net0 virtio,bridge=vmbr0,tag=22 \
  --scsihw virtio-scsi-pci \
  --scsi0 local-lvm:20 \
  --ide2 local:iso/ubuntu-26.04-live-server-amd64.iso,media=cdrom \
  --boot 'order=ide2;scsi0' \
  --ostype l26 \
  --agent enabled=1
qm set 103 --onboot 1
```

Unlike `dune-prod`/`dune-dev`, this VM does **not** need NUMA-node CPU
affinity pinning — 2 vCPUs for a Discord bot process has no meaningful
NUMA locality concern, and pinning would only reduce the scheduler's
flexibility for no latency benefit at this scale.

Install Ubuntu Server 26.04 interactively via the Proxmox console
(same process as `r740xd/01-proxmox-and-vms.md` Phase 3.2):
- **Network**: Manual IPv4 — `192.168.22.10/24`, gateway `192.168.22.1`,
  DNS `1.1.1.1`
- **Profile**: username `bot`, hostname `acp-bot`, generate + store the
  password in the user's password manager
- **SSH**: Enable "Install OpenSSH server"

Verify SSH access before proceeding to Phase 1:
```bash
ssh bot@192.168.22.10 "hostname && free -h | head -2 && nproc"
# Expected: acp-bot, ~4 GB RAM, 2 CPUs
```

Also verify the Services-Zone firewall policies actually work as
intended (per `docs/02-network-setup.md` Step 7 item 4) before
proceeding — confirm both the Allow direction (bot → both consoles'
`:8088`) and the Block direction (dune-prod/dune-dev → bot VM, and bot
VM → Mgmt-Zone) with real commands, not just by reading the policy
table back:
```bash
# From the bot VM -- both should succeed:
ssh bot@192.168.22.10 "curl -s -o /dev/null -w '%{http_code}\n' http://192.168.20.10:8088"
ssh bot@192.168.22.10 "curl -s -o /dev/null -w '%{http_code}\n' http://192.168.21.10:8088"

# From dune-prod toward the bot VM -- should fail (blocked):
ssh bot@192.168.22.10 "ping -c 3 -W 2 192.168.22.10; echo EXIT=\$?"
```
Report the actual output of all three checks — do not assume the
firewall policy took effect just because it was created in the UI.

## Phase 1: Rotate Secrets Migrated from OCI (C-6 fix)

The bot token/secrets staged in `~/r740-bot-backup/secrets/` (from
`tabr-tau/00-prerequisites.md`) were copied from the still-live OCI
instance. They must never be the ones actually used going forward — the
old host, or backups of it, could retain access to them indefinitely.
Rotate BEFORE cloning/deploying the bot below, not after — do not skip
ahead to Phase 2 with the OCI-origin secrets still in play.

### 1.1 Rotate Discord Bot Token
Ask the user to:
1. Go to Discord Developer Portal → Your Application → Bot → **Reset Token**
2. Give you the new token string — you'll use it in Phase 2's `.env`
   setup below. Do not write it anywhere yet.

### 1.2 Rotate Discord OAuth Client Secret (CLOUD-03 fix)
This deployment's multi-tenant mode uses `DISCORD_CLIENT_SECRET` for
per-guild OAuth onboarding — not conditional here (see the Phase 2.1
correction). Ask the user to:
1. Go to Discord Developer Portal → OAuth2 → **Reset Client Secret**
2. Give you the new secret — same as above, used in Phase 2.

### 1.3 Shred the Staged Secrets Backup (on the dev machine)
Once you've used the values you need from
`~/r740-bot-backup/secrets/bot-env.txt` for Phase 2 below, shred the
local staging copy — it must not persist once its values are in use:
```bash
# On the dev machine:
shred -u ~/r740-bot-backup/secrets/bot-env.txt
shred -u ~/r740-bot-backup/secrets/acp.db
rm -rf ~/r740-bot-backup/secrets/
```
Confirm the directory no longer exists after running this.

## Phase 2: Clone and Deploy the Bot

### 2.1 Clone the Repository

**Correction (2026-08-17, issue #93):** this step previously set
`DUNE_CONSOLE_API_URL=http://localhost:8088`, which assumed the bot
runs in single-tenant mode co-located with one console on the same
host. Neither assumption holds now: the bot runs in **multi-tenant
mode** (`ACP_MULTI_TENANT=true`, confirmed live on OCI today), which
resolves each guild's own console URL and adapter token from its SQLite
`guilds` table per-call rather than from a single static `.env` value
— and it no longer co-locates with either console at all, since it now
lives on its own Services-VLAN VM. `DUNE_CONSOLE_API_URL` and
`DUNE_DISCORD_ADAPTER_TOKEN` are single-tenant-mode-only fields (only
read when `!multiTenant`) and should be left **unset** in `.env`, not
pointed at `localhost` or either console's real IP — leaving a stale
value here would be dead config, not a functional bug, but should not
be carried forward to avoid confusion about which mode is actually
active.

```bash
ssh bot@192.168.22.10 << 'ENDSSH'
git clone https://github.com/yacketrj/arrakis-control-panel.git ~/arrakis-control-panel
cd ~/arrakis-control-panel
npm ci --omit=dev
cp .env.example .env

# Set the essential values (update with the real values):
# ACP_MULTI_TENANT=true (confirm this is set -- do NOT set
#   DUNE_CONSOLE_API_URL or DUNE_DISCORD_ADAPTER_TOKEN; multi-tenant
#   mode resolves these per-guild instead, see the correction above)
# DISCORD_BOT_TOKEN: use the ROTATED value from Phase 1.1 above, NOT the
#   original value staged from OCI in tabr-tau/00-prerequisites.md
# DISCORD_CLIENT_ID: from tabr-tau/00-prerequisites.md (this one doesn't
#   need rotation -- it's a public identifier, not a secret)
# DISCORD_CLIENT_SECRET: use the ROTATED value from Phase 1.2 above
# ACP_BASE_URL / ACP_OAUTH_REDIRECT_URI / ACP_STEAM_LINK_BASE_URL /
#   STEAM_LINK_REDIRECT_URI: carry forward from OCI's current live
#   config unchanged -- these are hostname-based (the Cloudflare Tunnel
#   hostname), not host-IP-based, and do not change as part of this
#   migration
ENDSSH
```
Set each `.env` value using the rotated secrets from Phase 1, not the
original OCI-origin values — double-check this before moving on. If
you are migrating an existing OCI `.env` rather than starting fresh,
also **remove** `DUNE_CONSOLE_API_URL`, `DUNE_DISCORD_ADAPTER_TOKEN`,
`CLOUDFLARE_ACCOUNT_ID`, and `KV_NAMESPACE_ID` if present — all four
are confirmed dead/single-tenant-only config that should not be carried
forward (see `arrakis-control-panel#166` for the verification that
established this).

### 2.2 Generate ACP_SECRETS_KEY (CLOUD-08 fix)
This deployment always runs `ACP_MULTI_TENANT=true` (confirmed live on
OCI today, unchanged by this migration — see the Phase 2.1 correction
above) — per-guild adapter tokens in the SQLite database are stored in
plaintext unless this key is set, so this step is not conditional here:
```bash
ssh bot@192.168.22.10 << 'ENDSSH'
cd ~/arrakis-control-panel
KEY=$(node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")
echo "ACP_SECRETS_KEY=${KEY}" >> .env
echo "ACP_SECRETS_KEY generated. Existing plaintext tokens in acp.db will"
echo "need re-provisioning via the setup portal."
ENDSSH
```
Tell the user existing plaintext tokens will need re-provisioning via
the setup portal after this change.

### 2.3 Register Slash Commands
```bash
ssh bot@192.168.22.10 "cd ~/arrakis-control-panel && npm run register"
```
Confirm the command output shows registration success with no errors —
report the actual output, don't assume success.

### 2.4 (Optional) Install Local Pre-Commit Hooks

Only do this if the user plans to edit the bot's code directly on this
VM (debugging, quick fixes) rather than exclusively pushing from the dev
machine via `git push deploy` (the intended workflow — see Phase 6). The
bot repo already ships its own `.pre-commit-config.yaml`
(gitleaks/ggshield/trivy) that travels with the clone; this just
activates it locally so a direct commit on this VM gets the same scan
coverage the dev machine's commits already get, rather than only
catching issues later in CI:

```bash
ssh bot@192.168.22.10 << 'ENDSSH'
cd ~/arrakis-control-panel
python3 -m pip install --user pre-commit 2>/dev/null || sudo apt-get install -y pipx python3-pip && python3 -m pip install --user pre-commit
pre-commit install
ENDSSH
```

Skip this step entirely if this VM will only ever receive deploys via
`git push deploy` and no one edits code on it directly — ask the user if
unsure rather than running it unconditionally.

### 2.5 Install and Enable Systemd Service
```bash
ssh bot@192.168.22.10 << 'ENDSSH'
sudo cp ~/arrakis-control-panel/systemd/acp-bot.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable acp-bot.service
sudo systemctl start acp-bot.service
sudo systemctl status acp-bot.service
ENDSSH
```

Confirm `systemctl status` shows `active (running)`. Check logs:
```bash
ssh bot@192.168.22.10 "journalctl -u acp-bot -n 30 --no-pager"
```
Confirm the bot shows "Ready!" and connects to Discord's gateway — report
the actual log lines, don't just assume it worked because the service
"started".

## Phase 3: Configure Cloudflare Tunnel

**Correction (2026-08-17, issue #93):** this phase previously had you
install and run a *new* `cloudflared` daemon directly on the bot's
target VM, with its own local `config.yml`. That doesn't match this
deployment's actual, current tunnel architecture (see the Arrakis-Project
README's Live Systems section): the `acp-console` tunnel already runs
centrally on the **Proxmox host** (`cloudflared.service`, dashboard/API-
managed — its local `/etc/cloudflared/config.yml` is kept for
readability but does **not** itself control routing; the authoritative
ingress list lives in Cloudflare's Tunnel Configuration API), and it
already reaches both `dune-prod:8088` and `dune-dev:8088` remotely
across VLANs without running anything on either VM. The bot VM should
work the same way: add its ingress rule to the **existing** Proxmox-
hosted tunnel, pointing at the bot VM's IP, rather than standing up a
second tunnel daemon. This is also literally the migration this
project's README already describes as the end state — folding the
bot's separate OCI-hosted tunnel into the one Proxmox-hosted tunnel.

### 3.1 Add Ingress Rules via the Cloudflare API (C-8 fix — Access is MANDATORY)

Do this from wherever you have Cloudflare API credentials configured
(the dev machine, or the Proxmox host itself) — **not** by SSHing into
the bot VM, since nothing needs to run there for this step:

```bash
# Fetch the current tunnel configuration first -- do not skip this and
# construct a new config from scratch, or you will silently drop every
# other hostname (console, console-dev, landing, etc.) this tunnel
# already serves.
curl -s -X GET \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${ACP_CONSOLE_TUNNEL_ID}/configurations" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" | jq . > /tmp/opencode/current-tunnel-config.json
```

Add two new ingress rules to the fetched config's `ingress` array
(inserted before the catch-all `http_status:404` rule, which must
always remain last):

```json
{
  "hostname": "ACP_SETUP_TUNNEL_HOSTNAME",
  "service": "http://192.168.22.10:3100"
},
{
  "hostname": "ACP_SETUP_TUNNEL_HOSTNAME",
  "path": "/auth/steam",
  "service": "http://192.168.22.10:3101"
}
```

Then `PUT` the modified configuration back:
```bash
curl -s -X PUT \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${ACP_CONSOLE_TUNNEL_ID}/configurations" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  --data @/tmp/opencode/modified-tunnel-config.json | jq .
```

**Coordinate this change carefully**: the same tunnel already serves
`CONSOLE_TUNNEL_HOSTNAME` and its Dev-VM equivalent (both live
game-server admin consoles). A `PUT` replaces the entire ingress list —
always fetch-modify-PUT the full current config (as above), never
construct a partial one, or you will silently take down every other
hostname this tunnel serves. Verify with a follow-up `GET` (not just
trusting the `PUT` response) that all pre-existing hostnames are still
present alongside the two new ones before moving on.

**This does not require restarting `cloudflared.service` on the Proxmox
host** — per the README, this tunnel is dashboard/API-managed; a config
API update takes effect without a daemon restart. If you need to
confirm the daemon itself is still healthy after the API change (it
should be, since nothing about the running process changed), you may
optionally check `ssh root@<proxmox-mgmt-ip> "systemctl status
cloudflared"`, but do not restart it as part of this step.

Per this project's Requirement 23 on documenting network ingress
points, update the Arrakis-Project README's Live Systems section to
reflect the new `192.168.22.10:3100`/`:3101` ingress targets once this
is live (see issue #93 for the tracking reference).

### 3.2 Enforce Cloudflare Access (C-8 — was "recommended", now MANDATORY)

**This step is NOT optional.** Without it, anyone who discovers the
hostname can reach the admin console login page. The console mounts the
Docker socket — reaching that page is one password away from
root-equivalent VM access. Do not report this phase complete without it.

Walk the user through (you cannot drive the Cloudflare dashboard
yourself):
1. Cloudflare Zero Trust Dashboard → Access → Applications → **Add Application**
2. Type: **Self-hosted**
3. Application name: `Dune Console`
4. Subdomain: `CONSOLE_TUNNEL_HOSTNAME`
5. Identity providers: Accept all (or add the user's email provider)
6. **Create policy:**
   - Policy name: `Admin Only`
   - Action: **Allow**
   - Include → Emails → the user's email
   - (Add any additional trusted operators the user specifies)
7. Save policy → **repeat for `ACP_SETUP_TUNNEL_HOSTNAME`** (at minimum,
   protect the `/auth/steam` path)
8. Save and close

Ask the user to open an incognito/private browser window and navigate to
`https://CONSOLE_TUNNEL_HOSTNAME`, and report back what they see. They
MUST see a Cloudflare Access login page (email/PIN prompt) BEFORE
reaching the Dune Console login. If they report seeing the console login
directly, Access is NOT configured — treat this as a blocking failure
and go back to step 1 above.

## Phase 4: Configure Database Backup (C-4 fix)

### 4.1 ACP SQLite Daily Backup
Create a systemd timer on the bot VM:

```bash
ssh bot@192.168.22.10 << 'ENDSSH'
sudo tee /etc/systemd/system/acp-db-backup.service << 'UNIT'
[Unit]
Description=ACP Bot SQLite Database Backup
After=network.target

[Service]
Type=oneshot
User=bot
ExecStart=/bin/bash -c '\
  BACKUP_DIR="/home/bot/arrakis-control-panel/data/backups"; \
  mkdir -p "$BACKUP_DIR"; \
  DB="/home/bot/arrakis-control-panel/data/acp.db"; \
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

Confirm:
```bash
ssh bot@192.168.22.10 "ls -la ~/arrakis-control-panel/data/backups/ && systemctl list-timers acp-db-backup.timer"
```
Report the actual backup file listing and timer status.

## Phase 5: End-to-End Verification

### 5.1 Discord Bot Smoke Test
Ask the user to run `/dune server health` in their Discord server and
report whether the bot responds with server status within 5 seconds.

### 5.2 Adapter Endpoint Verification

**Correction (2026-08-17, issue #93):** this step previously assumed
single-tenant mode with one static `DUNE_DISCORD_ADAPTER_TOKEN` and a
co-located console at `localhost:8088`. In multi-tenant mode, each
guild has its own console URL and adapter token stored in the bot's own
`guilds` SQLite table — there is no single "the" adapter token to test
directly. Verify per-guild connectivity instead, from an already-
onboarded Discord guild (not from the VM's shell):

```bash
# From the bot VM, confirm network reachability to both consoles
# (the actual per-guild adapter-token auth is exercised end-to-end by
# the Discord command test in 5.1 above, not testable directly here
# without a specific guild's stored token):
ssh bot@192.168.22.10 "curl -s -o /dev/null -w 'dune-prod: %{http_code}\n' http://192.168.20.10:8088"
ssh bot@192.168.22.10 "curl -s -o /dev/null -w 'dune-dev: %{http_code}\n' http://192.168.21.10:8088"
```
Expected: both return a real HTTP status (`200`/`302`/`401` are all
"reachable" — anything other than a connection timeout/refused
confirms the Services-Zone → Prod-Zone/Dev-Zone firewall policies from
`docs/02-network-setup.md` Step 4 are working end-to-end for this VM,
not just in the abstract). Report the actual codes.

### 5.3 Cloudflare Tunnel Verification
```bash
# From the dev machine:
curl -s https://ACP_SETUP_TUNNEL_HOSTNAME/api/live-stats | jq .players_online
curl -s -o /dev/null -w '%{http_code}' https://CONSOLE_TUNNEL_HOSTNAME
```
Expected: live stats returns JSON with a `players_online` field. Console
returns `302` or `200` (redirect to Access login is OK). Report actual
results.

### 5.4 Firewall Isolation Verification
From dune-dev VM, confirm Prod is unreachable (pre-existing Prod/Dev
isolation, unrelated to the bot VM):
```bash
ssh dune@192.168.21.10 "ping -c 3 -W 2 192.168.20.10; echo EXIT=\$?"
```
Expected: ping fails (non-zero exit). **If it succeeds, VLAN isolation
is broken — stop, report this to the user, and go back to Phase 2.0 of
`r740xd/01-proxmox-and-vms.md` to fix `bridge-vlan-aware` before
continuing this prompt.**

### 5.5 Services-Zone Isolation Verification (added 2026-08-17, issue #93)

Confirm the bot's new zone policies actually hold, both directions —
this was already checked once in Phase 0 before the bot software was
even installed, but re-verify now that the full stack is live, since a
Cloudflare Access policy or an application-level change earlier in this
prompt could not have affected the network-layer firewall, but it's
still worth confirming nothing changed:
```bash
# From dune-prod and dune-dev toward the bot VM -- both should fail:
ssh dune@192.168.20.10 "ping -c 3 -W 2 192.168.22.10; echo EXIT=\$?"
ssh dune@192.168.21.10 "ping -c 3 -W 2 192.168.22.10; echo EXIT=\$?"
```
Expected: both pings fail (non-zero exit). If either succeeds, the
Services-Zone → Prod-Zone/Dev-Zone block rules (`docs/02-network-setup.md`
Step 4, rule 8) are not actually in effect — stop, report this to the
user, and go back to that step before considering this migration done.

## Phase 6: Deploy Remote Setup (for future git push deploys)

```bash
ssh bot@192.168.22.10 << 'ENDSSH'
mkdir -p ~/acp-deploy.git && cd ~/acp-deploy.git && git init --bare
cp ~/arrakis-control-panel/scripts/deploy-post-receive.sh hooks/post-receive
chmod +x hooks/post-receive
ENDSSH

# On the dev machine, add the deploy remote (path corrected 2026-08-17,
# issue #95 -- the dev machine's real, current clone layout is a flat
# ~/projects/repos/, not ~/projects/acp/; see Arrakis-Project#27/#28):
git -C ~/projects/repos/arrakis-control-panel remote add deploy \
  ssh://bot@192.168.22.10/home/bot/acp-deploy.git

# CRITICAL, previously missing step (issue #95): the bot VM's OWN
# working-tree clone (~/arrakis-control-panel) also needs a `deploy`
# remote, pointing back at the local bare repo -- the post-receive
# hook's own `git fetch deploy "$DEPLOY_BRANCH"` step depends on this
# remote existing, and nothing above this point creates it. Confirmed
# via real reproduction: the first actual `git push deploy deploy`
# against a bot VM set up by this exact procedure failed at this step
# with `fatal: 'deploy' does not appear to be a git repository` --
# caught and fixed live, then folded back into this prompt so the next
# VM build doesn't hit the same gap.
ssh bot@192.168.22.10 << 'ENDSSH'
cd ~/arrakis-control-panel && git remote add deploy ~/acp-deploy.git
ENDSSH
```

**Verify this phase actually works, not just that the commands ran
without error** -- do a real test push (`git push deploy main:deploy`
from the dev machine) and confirm the hook completes end-to-end (test
suite runs, service restarts, `systemctl status acp-bot.service` shows
`active`). A remote being *configured* does not prove a deploy will
actually *succeed* -- the `WORK_DIR` path inside
`scripts/deploy-post-receive.sh` must also match this VM's real user
(`bot`) and home directory, which is a separate thing to verify (see
`arrakis-control-panel#174` for a real case where this specific path
had drifted and the only reason it was caught was a real test deploy,
not a code review).

## What to Report Back When This Prompt Is Done
Confirm and explicitly report each of the following, not just "looks
done":
- Bot VM (VMID 103) provisioned on Services VLAN 22, or confirmed
  already existing (Phase 0)
- Services-Zone firewall policies verified in both directions (Phase 0
  and 5.5) — not just the Allow direction
- Discord bot token rotated (C-6)
- OAuth client secret rotated (CLOUD-03)
- Staged secrets backup shredded on the dev machine
- ACP_SECRETS_KEY generated (CLOUD-08) — multi-tenant mode is always
  on for this deployment, this is not conditional
- `.env` confirmed to NOT contain `DUNE_CONSOLE_API_URL` or
  `DUNE_DISCORD_ADAPTER_TOKEN` (single-tenant-only, dead in this
  deployment's multi-tenant mode — see the Phase 2.1 correction)
- ACP bot cloned, installed, running on the bot VM
- Systemd service `acp-bot.service` active and enabled
- **Deploy remote configured on BOTH ends** (dev machine's clone AND
  the bot VM's own working-tree clone -- the latter is easy to miss,
  see Phase 6's correction) **and verified with a real test push**,
  not just "the remote-add commands ran" -- confirm the hook actually
  completed (tests ran, service restarted, `active`) end-to-end
- Cloudflare Tunnel ingress rules added to the **existing**
  Proxmox-hosted `acp-console` tunnel via the Configuration API (incl.
  Steam port 3101) — confirmed via a follow-up GET that pre-existing
  hostnames (console, console-dev) are still present, not just that
  the two new rules were added
- Cloudflare Access MANDATORY policy confirmed in front of
  CONSOLE_TUNNEL_HOSTNAME (confirmed via the user's incognito test, not
  assumed)
- SQLite daily backup timer created and active (C-4)
- Bot responds to slash commands in Discord
- Bot's network reachability to both consoles verified (5.2)
- Prod/Dev VLAN isolation verified (ping from Dev to Prod failed as
  expected, 5.4)
- Services-Zone isolation verified (ping from Prod/Dev to the bot VM
  both failed as expected, 5.5)
- Deploy remote configured, pointing at the bot VM (not dune-prod)

## When This Prompt Is Done
Tell the user to start a NEW, separate session on the dev machine and
proceed to `tabr-tau/04-e2e-verification.md` for the full go-live
checklist — that prompt's scope is narrowed to dev-machine-appropriate
checks only (running the automated verification script, external
WAN/browser tests); see issue #59.
</content>
