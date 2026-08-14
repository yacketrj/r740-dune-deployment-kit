# R740XD-02: Game Server Initialization

This prompt is run FROM your dev machine (all steps are `ssh` commands)
and targets both VMs — everything it changes lands on the R740's VMs, not
your dev machine itself. It initializes both battlegroups, configures map
topology, imports the Dev database backup from the gaming PC, and applies
the hardening checklist.

## Target Machines
- dune-dev VM (dune@192.168.21.10) — initialized FIRST with backup import
- dune-prod VM (dune@192.168.20.10) — clean battlegroup init SECOND

## Pre-Requisites
- `r740xd/01-proxmox-and-vms.md` completed — both VMs have Docker +
  `dune-awakening-selfhost-docker` cloned
- `tabr-tau/00-prerequisites.md` completed — Funcom tokens generated,
  values.env filled
- For Dev: gaming PC backup transferred per `scripts/06-pre-migration-backup.sh`
- Read `scripts/04-init-dev-battlegroup.sh` and `scripts/05-init-prod-battlegroup.sh`

## Phase 1: Transfer Backup to Dev VM

If you haven't already transferred the gaming PC backup:
```bash
scp /tmp/opencode/dune-migration-final/*.backup \
  dune@192.168.21.10:~/dune-awakening-selfhost-docker/runtime/backups/db/
scp /tmp/opencode/dune-migration-final/*.sha256 \
  dune@192.168.21.10:~/dune-awakening-selfhost-docker/runtime/backups/db/
```

**VERIFY** checksum on the Dev VM matches:
```bash
ssh dune@192.168.21.10 "cd ~/dune-awakening-selfhost-docker/runtime/backups/db && sha256sum -c *.sha256"
```
All checksums must report "OK".

## Phase 2: Initialize Dev Battlegroup (WITH backup import)

### 2.1 Run dune init
```bash
ssh -t dune@192.168.21.10 "cd ~/dune-awakening-selfhost-docker && sudo ./install.sh || true && runtime/scripts/dune init"
```

Follow the interactive prompts:
- **Server title:** `Tabr Tau - Dev`
- **Region:** Your region
- **Hosting mode:** Option 2 — Local/LAN (Dev has NO WAN port forwards)
- **Funcom token:** Paste account #2's token

### 2.2 Import the Gaming PC Backup
```bash
ssh dune@192.168.21.10 << 'ENDSSH'
cd ~/dune-awakening-selfhost-docker
BACKUP=$(ls -t runtime/backups/db/*.backup | head -1)
echo "Importing: $(basename $BACKUP)"
DUNE_DB_ASSUME_YES=1 runtime/scripts/dune db import "$(basename $BACKUP)"
ENDSSH
```

**VERIFY:**
```bash
ssh dune@192.168.21.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune sietches validate && runtime/scripts/dune status && runtime/scripts/dune db health"
```

### 2.3 Test 4 Deep Desert Instances on Dev (C-11 fix — mechanical gate)
This validates the 4-DD configuration BEFORE it reaches Prod:

```bash
ssh dune@192.168.21.10 << 'ENDSSH'
cd ~/dune-awakening-selfhost-docker
echo "Setting DeepDesert_1 to 4 instances for validation..."
runtime/scripts/dune sietches set-max DeepDesert_1 4
runtime/scripts/dune sietches set-active DeepDesert_1 4
sleep 10

echo "Checking instance status..."
docker ps --format '{{.Names}} {{.Status}}' | grep deepdesert

echo "Running sietch validation..."
runtime/scripts/dune sietches validate

echo "Running farm readiness check..."
runtime/scripts/dune ready || echo "WARNING: ready check had warnings — review"

echo "4-DD validation complete. Running for 10 minutes to check stability..."
ENDSSH

# Wait 10 minutes, then verify no crashes:
sleep 600
ssh dune@192.168.21.10 "docker ps --format '{{.Names}} {{.Status}}' | grep deepdesert && runtime/scripts/dune sietches validate"

# If stable, save the state as the validation evidence:
ssh dune@192.168.21.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune status > /tmp/dd4-validation-$(date +%Y%m%d).txt"
```

**If 4 DD fails on Dev (crashes, OOM, instability):** reduce to 2-3 instances
and adjust Prod accordingly. Document the actual validated count in the
day-of runbook.

## Phase 3: Initialize Prod Battlegroup (CLEAN, no import)

### 3.1 Run dune init
```bash
ssh -t dune@192.168.20.10 "cd ~/dune-awakening-selfhost-docker && sudo ./install.sh || true && runtime/scripts/dune init"
```

Follow the interactive prompts:
- **Server title:** `Tabr Tau`
- **Region:** Your region
- **Hosting mode:** Option 1 — Public (uses WAN port forwards)
- **Funcom token:** Paste account #1's token

### 3.2 Configure Sietch Topology (2 dimensions)
```bash
ssh dune@192.168.20.10 << 'ENDSSH'
cd ~/dune-awakening-selfhost-docker
runtime/scripts/dune sietches set-max Survival_1 2
runtime/scripts/dune sietches set-active Survival_1 2
ENDSSH
```

### 3.3 Configure Deep Desert (4 instances — only if Dev validation passed)
```bash
ssh dune@192.168.20.10 << 'ENDSSH'
cd ~/dune-awakening-selfhost-docker
runtime/scripts/dune sietches set-max DeepDesert_1 4
runtime/scripts/dune sietches set-active DeepDesert_1 4
ENDSSH
```

**If Dev validation failed**, use the validated count instead (e.g., `set-max DeepDesert_1 2`).

### 3.4 Configure Hub Cities as Always-On
```bash
ssh dune@192.168.20.10 << 'ENDSSH'
cd ~/dune-awakening-selfhost-docker
# Set Arrakeen and Harko Village to always-on for pre-warmed travel
runtime/scripts/dune maps mode SH_Arrakeen always-on
runtime/scripts/dune maps mode SH_HarkoVillage always-on
ENDSSH
```

### 3.5 Verify Prod Status
```bash
ssh dune@192.168.20.10 << 'ENDSSH'
cd ~/dune-awakening-selfhost-docker
runtime/scripts/dune status
runtime/scripts/dune sietches validate
runtime/scripts/dune db health
runtime/scripts/dune ports
ENDSSH
```

**VERIFY:** `dune ports` must show no WARN lines about advertised vs bound
IP mismatches. Server IP must match your public IP.

Check container count matches expected:
- 2 Survival_1 dimensions = 2 containers
- 4 DeepDesert_1 = 4 containers  
- Overmap = 1
- Director + Gateway + Autoscaler + TextRouter = 4
- Postgres + RabbitMQ × 2 = 3
- Total: ~14 containers

```bash
ssh dune@192.168.20.10 "docker ps --format '{{.Names}}' | wc -l"
```

## Phase 4: Apply Hardening Checklist

### 4.1 Rotate Default DB Password (C-3 fix — use the console API)
```bash
ssh dune@192.168.20.10 << 'ENDSSH'
cd ~/dune-awakening-selfhost-docker
NEWPASS="$(openssl rand -base64 32)"

# Via console API (handles both ALTER ROLE + .env update):
CSRF=$(curl -s http://localhost:8088/api/auth/state | jq -r '.csrfToken')
ADMIN_PASS=$(grep ADMIN_PASSWORD .env | cut -d= -f2)
SESSION=$(curl -s -X POST http://localhost:8088/api/auth/login \
  -H "Content-Type: application/json" \
  -d "{\"password\":\"${ADMIN_PASS}\"}" \
  -c - | grep asc_session | awk '{print $NF}')

curl -s -X POST http://localhost:8088/api/database/password \
  -H "Content-Type: application/json" \
  -H "X-CSRF-Token: ${CSRF}" \
  -b "asc_session=${SESSION}" \
  -d "{\"password\":\"${NEWPASS}\"}"

# Verify new password works:
docker compose restart
sleep 10
runtime/scripts/dune db health
ENDSSH
```

Repeat for dune-dev with a DIFFERENT password.

### 4.2 Set Strong Admin Passwords
```bash
# On each VM:
ssh dune@192.168.20.10 "cd ~/dune-awakening-selfhost-docker && ADMIN_PASS=\$(openssl rand -base64 24) && echo \"ADMIN_PASSWORD=\${ADMIN_PASS}\" >> .env"
ssh dune@192.168.21.10 "cd ~/dune-awakening-selfhost-docker && ADMIN_PASS=\$(openssl rand -base64 24) && echo \"ADMIN_PASSWORD=\${ADMIN_PASS}\" >> .env"
```

### 4.3 Enable Restart Schedule
```bash
ssh dune@192.168.20.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune restart-schedule enable 04:00 15"  
ssh dune@192.168.21.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune restart-schedule enable 04:00 15"  
```

### 4.4 Enable DB Auto-Backup
```bash
ssh dune@192.168.20.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune db auto enable"  
ssh dune@192.168.21.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune db auto enable"  
```

### 4.5 Enable Auto-Update

Applies self-host-kit updates automatically on a schedule rather than
relying on someone remembering to run `dune update install latest`
manually. Review the kit's own changelog/release notes before enabling
this on Prod if you'd rather review updates before they apply — `apply 0`
below only notifies without actually installing, `apply 1` installs.

```bash
# enable [interval-minutes] [apply 0|1] [notify 0|1] [notify-minutes] [wait-empty 0|1] [max-wait-minutes]
# (default check interval is 60 minutes if omitted -- shown explicitly
# below for clarity, not because it differs from the default)
# Dev: apply automatically (low risk, no players depending on uptime)
ssh dune@192.168.21.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune update auto enable 60 1 1 15 0 360"

# Prod: notify only, don't auto-apply -- review updates before they land
# on the live battlegroup (adjust to 'apply 1' later once you're
# comfortable trusting unattended updates on Prod specifically)
ssh dune@192.168.20.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune update auto enable 60 0 1 15 0 360"
```

**VERIFY:**
```bash
ssh dune@192.168.20.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune update auto status"
ssh dune@192.168.21.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune update auto status"
```

### 4.6 Enable IP-Change-Restart

This project's own findings register already flags "single static IPv4
with no failover" (L-7) as an accepted risk -- this doesn't fix that, but
it does make sure that if your ISP ever *does* rotate your public IP
(common on non-business tiers even with a "static" plan), the game server
restarts and re-advertises the new IP to FLS automatically instead of
silently becoming unreachable until someone notices.

```bash
ssh dune@192.168.20.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune ip-change-restart enable"
ssh dune@192.168.21.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune ip-change-restart enable"
```

**VERIFY:**
```bash
ssh dune@192.168.20.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune ip-change-restart status"
ssh dune@192.168.21.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune ip-change-restart status"
```

## State After Completion
- [ ] Dev battlegroup: initialized, backup imported, Sietch validates, DB healthy
- [ ] 4 Deep Desert instances validated on Dev (mechanical gate C-11 fixed)
- [ ] Prod battlegroup: initialized clean, 2 Sietch configured
- [ ] Prod Deep Desert: 4 instances (or validated count if Dev failed)
- [ ] Hub cities: Arrakeen + Harko Village set to always-on
- [ ] DB password rotated on both VMs (different passwords, C-3 fix)
- [ ] Strong admin passwords set on both VMs
- [ ] Restart schedules enabled (6-hourly)
- [ ] DB auto-backup enabled on both VMs
- [ ] Auto-update enabled on both VMs (Dev auto-applies, Prod notify-only
      by default — adjust once comfortable trusting unattended Prod updates)
- [ ] IP-change-restart enabled on both VMs
- [ ] `dune ports` clean — no IP mismatch warnings

## Next Prompt
Proceed to `r740xd/03-bot-deploy-and-tunnel.md`, which rotates the ACP
bot's secrets, deploys the bot, configures the Cloudflare Tunnel, and
hardens the services — all in the same R740xd session (see issue #59:
secret rotation moved out of a separate `tabr-tau/01` prompt since it's
R740-side configuration work, not dev-machine gathering).
