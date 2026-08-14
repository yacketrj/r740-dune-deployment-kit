# R740XD-02: Game Server Initialization

You are an LLM coding agent running in your own session, driving SSH
commands from wherever this session executes, but every change lands on
the R740's VMs, not the machine you're typing from. Your job in this
session: initialize both battlegroups, configure map topology, import
the Dev database backup from the gaming PC, and apply the hardening
checklist.

## Target Machines
- dune-dev VM (dune@192.168.21.10) — initialize FIRST, with backup import
- dune-prod VM (dune@192.168.20.10) — clean battlegroup init SECOND

## Before You Start, Confirm
- `r740xd/01-proxmox-and-vms.md` completed — both VMs have Docker +
  `dune-awakening-selfhost-docker` cloned; verify directly rather than
  assuming if you have no evidence from this session
- `tabr-tau/00-prerequisites.md` completed — Funcom tokens generated,
  values.env filled
- For Dev: gaming PC backup transferred per `scripts/06-pre-migration-backup.sh`
- Read `scripts/04-init-dev-battlegroup.sh` and `scripts/05-init-prod-battlegroup.sh`
  before running them, so you understand what each interactive prompt
  expects

## Phase 1: Transfer Backup to Dev VM

If the gaming PC backup hasn't already been transferred, run:
```bash
scp /tmp/opencode/dune-migration-final/*.backup \
  dune@192.168.21.10:~/dune-awakening-selfhost-docker/runtime/backups/db/
scp /tmp/opencode/dune-migration-final/*.sha256 \
  dune@192.168.21.10:~/dune-awakening-selfhost-docker/runtime/backups/db/
```

Verify the checksum on the Dev VM matches before proceeding:
```bash
ssh dune@192.168.21.10 "cd ~/dune-awakening-selfhost-docker/runtime/backups/db && sha256sum -c *.sha256"
```
All checksums must report "OK". If any fail, stop and do not import —
report the failure to the user rather than proceeding with a possibly
corrupt backup.

### 1.1 Transfer and Restore runtime/secrets/ and runtime/generated/ (issue #80)

`scripts/06-pre-migration-backup.sh` also stages `runtime-secrets.tar.gz`
and `runtime-generated.tar.gz` in the same staging directory. Decide
per-value whether Dev needs the gaming PC's credentials/config carried
forward, or whether it should get its own fresh `runtime/secrets/` from
`dune init` below (issue #80's fix intentionally leaves this a manual
decision, not a blanket copy) — ask the user if unclear. If restoring
onto Dev:
```bash
scp /tmp/opencode/dune-migration-final/runtime-secrets.tar.gz \
    /tmp/opencode/dune-migration-final/runtime-generated.tar.gz \
    dune@192.168.21.10:~/dune-awakening-selfhost-docker/runtime/
ssh dune@192.168.21.10 "cd ~/dune-awakening-selfhost-docker/runtime && \
    tar -xzf runtime-secrets.tar.gz && tar -xzf runtime-generated.tar.gz && \
    chmod 600 secrets/* && rm runtime-secrets.tar.gz runtime-generated.tar.gz"
```
If restoring, do this BEFORE running `dune init` in Phase 2 below, so
`init` sees the carried-forward `runtime/secrets/funcom-token.txt`
rather than prompting fresh. If Dev should get fresh credentials
instead, skip this step entirely and let `dune init` create
`runtime/secrets/` from scratch.

## Phase 2: Initialize Dev Battlegroup (WITH backup import)

### 2.1 Run dune init
```bash
ssh -t dune@192.168.21.10 "cd ~/dune-awakening-selfhost-docker && sudo ./install.sh || true && runtime/scripts/dune init"
```

This is interactive. When it prompts, supply or have the user supply:
- **Server title:** `Tabr Tau - Dev`
- **Region:** the user's usual region
- **Hosting mode:** Option 2 — Local/LAN (Dev has NO WAN port forwards)
- **Funcom token:** account #2's token

### 2.2 Import the Gaming PC Backup
```bash
ssh dune@192.168.21.10 << 'ENDSSH'
cd ~/dune-awakening-selfhost-docker
BACKUP=$(ls -t runtime/backups/db/*.backup | head -1)
echo "Importing: $(basename $BACKUP)"
DUNE_DB_ASSUME_YES=1 runtime/scripts/dune db import "$(basename $BACKUP)"
ENDSSH
```

Confirm afterward:
```bash
ssh dune@192.168.21.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune sietches validate && runtime/scripts/dune status && runtime/scripts/dune db health"
```
Report the actual output of all three commands — do not report this
phase complete unless `sietches validate`, `status`, and `db health` all
report healthy.

### 2.3 Test 4 Deep Desert Instances on Dev (C-11 fix — mechanical gate)
This validates the 4-DD configuration BEFORE it reaches Prod. Run:

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

**If 4 DD fails on Dev** (crashes, OOM, instability): reduce to 2-3
instances and adjust the Prod plan accordingly in Phase 3.3 below.
Document the actual validated count you use, and report it explicitly to
the user rather than silently substituting a different number.

## Phase 3: Initialize Prod Battlegroup (CLEAN, no import)

### 3.1 Run dune init
```bash
ssh -t dune@192.168.20.10 "cd ~/dune-awakening-selfhost-docker && sudo ./install.sh || true && runtime/scripts/dune init"
```

Interactive prompts — supply or have the user supply:
- **Server title:** `Tabr Tau` (no "- Dev" suffix — this is Prod)
- **Region:** the user's usual region
- **Hosting mode:** Option 1 — Public (uses WAN port forwards)
- **Funcom token:** account #1's token

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

If Dev validation failed in Phase 2.3, use the validated count instead
(e.g., `set-max DeepDesert_1 2`) — do not default to 4 just because it's
what the doc originally said.

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

Confirm `dune ports` shows no WARN lines about advertised vs bound IP
mismatches, and that the server IP matches the public IP — report the
actual output, not just "looks fine".

Confirm the container count matches expectation:
- 2 Survival_1 dimensions = 2 containers
- 4 DeepDesert_1 (or validated count) = N containers
- Overmap = 1
- Director + Gateway + Autoscaler + TextRouter = 4
- Postgres + RabbitMQ × 2 = 3
- Total: ~14 containers (with 4 DD)

```bash
ssh dune@192.168.20.10 "docker ps --format '{{.Names}}' | wc -l"
```
Report the actual count and whether it matches expectation, and
investigate any mismatch before proceeding.

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

Repeat the same for dune-dev, generating a DIFFERENT password — never
reuse the Prod password on Dev. Confirm `dune db health` reports healthy
on both after rotation before moving on.

### 4.2 Set Strong Admin Passwords
```bash
# On each VM:
ssh dune@192.168.20.10 "cd ~/dune-awakening-selfhost-docker && ADMIN_PASS=\$(openssl rand -base64 24) && echo \"ADMIN_PASSWORD=\${ADMIN_PASS}\" >> .env"
ssh dune@192.168.21.10 "cd ~/dune-awakening-selfhost-docker && ADMIN_PASS=\$(openssl rand -base64 24) && echo \"ADMIN_PASSWORD=\${ADMIN_PASS}\" >> .env"
```
Tell the user to record both new passwords in their password manager —
never print the generated values back into chat.

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

This applies self-host-kit updates automatically on a schedule rather
than relying on someone remembering to run `dune update install latest`
manually. Review the kit's own changelog/release notes before enabling
this on Prod if the user would rather review updates before they apply —
`apply 0` below only notifies without installing; `apply 1` installs.

```bash
# enable [interval-minutes] [apply 0|1] [notify 0|1] [notify-minutes] [wait-empty 0|1] [max-wait-minutes]
# (default check interval is 60 minutes if omitted -- shown explicitly
# below for clarity, not because it differs from the default)
# Dev: apply automatically (low risk, no players depending on uptime)
ssh dune@192.168.21.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune update auto enable 60 1 1 15 0 360"

# Prod: notify only, don't auto-apply -- review updates before they land
# on the live battlegroup (only change to 'apply 1' if the user
# explicitly asks for unattended updates on Prod specifically)
ssh dune@192.168.20.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune update auto enable 60 0 1 15 0 360"
```

Confirm on both VMs:
```bash
ssh dune@192.168.20.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune update auto status"
ssh dune@192.168.21.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune update auto status"
```
Report the actual status output for both — confirm Dev shows auto-apply
enabled and Prod shows notify-only, unless the user explicitly asked for
something different.

### 4.6 Enable IP-Change-Restart

This project's own findings register already flags "single static IPv4
with no failover" (L-7) as an accepted risk — this doesn't fix that, but
it does make sure that if the ISP ever does rotate the public IP (common
on non-business tiers even with a "static" plan), the game server
restarts and re-advertises the new IP to FLS automatically instead of
silently becoming unreachable until someone notices.

```bash
ssh dune@192.168.20.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune ip-change-restart enable"
ssh dune@192.168.21.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune ip-change-restart enable"
```

Confirm:
```bash
ssh dune@192.168.20.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune ip-change-restart status"
ssh dune@192.168.21.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune ip-change-restart status"
```
Report the actual status for both.

## What to Report Back When This Prompt Is Done
Confirm and explicitly report each of the following, not just "looks
done":
- Dev battlegroup: initialized, backup imported, Sietch validates, DB
  healthy
- 4 Deep Desert instances validated on Dev (or the actually-validated
  count, if different — state which)
- Prod battlegroup: initialized clean, 2 Sietch configured
- Prod Deep Desert: 4 instances (or the validated count if Dev's
  validation failed — state which)
- Hub cities: Arrakeen + Harko Village set to always-on
- DB password rotated on both VMs (confirm they are actually different
  passwords, not the same value copied twice)
- Strong admin passwords set on both VMs
- Restart schedules enabled (6-hourly)
- DB auto-backup enabled on both VMs
- Auto-update enabled on both VMs (Dev auto-applies, Prod notify-only —
  state explicitly if this deployment used a different setting)
- IP-change-restart enabled on both VMs
- `dune ports` clean on Prod — no IP mismatch warnings

## When This Prompt Is Done
Tell the user to proceed to `r740xd/03-bot-deploy-and-tunnel.md`, which
rotates the ACP bot's secrets, deploys the bot, configures the
Cloudflare Tunnel, and hardens the services — all in its own new R740xd
session (see issue #59: secret rotation was moved out of a separate
`tabr-tau/01` prompt since it's R740-side configuration work, not
dev-machine gathering).
</content>
