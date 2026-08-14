# TABR-TAU-04: End-to-End Verification & Go-Live Cutover

This prompt runs in its own session, ON YOUR DEV MACHINE, after ALL
R740xd deployment phases are complete
(`r740xd/01-proxmox-and-vms.md` through `r740xd/03-bot-deploy-and-tunnel.md`).
It runs the full automated verification suite, performs manual checks
that only make sense from outside the R740's own network (WAN
reachability, browser-based checks), and walks through the go-live
announcement.

**Scope note (2026-08-14):** this prompt previously also included
performance-baseline capture and SSH-based troubleshooting commands —
those were R740-side operations mistakenly included here and have moved
to `r740xd/04-post-deployment-ops.md` (issue #59). If you need those,
start a separate R740xd session for that prompt instead.

## Pre-Requisites
- `r740xd/01-proxmox-and-vms.md` through `r740xd/03-bot-deploy-and-tunnel.md`
  fully executed (in their own R740xd session)
- Both VMs online with game servers running
- ACP bot deployed and connected to Discord
- Cloudflare Tunnel configured with Access enforced
- You have a device outside your LAN (phone on cellular) for WAN testing

## Phase 1: Run Automated Verification Suite

### 1.1 Execute the E2E Verification Script
```bash
bash ~/r740-deployment/scripts/11-e2e-verify.sh
```

This runs 70+ checks across 11 categories:
1. Hardware & Proxmox (7 checks)
2. VM Configuration (11 checks)
3. Guest OS & Docker (8 checks)
4. Game Server Stack (10 checks)
5. ACP Discord Bot (12 checks)
6. Cloudflare Tunnel & Access (6 checks)
7. Network Isolation & Firewall (5 checks)
8. WAN Port Forwards (4 checks)
9. Security Hardening (6 checks)
10. Database Integrity (4 checks)
11. ACP Landing & DNS (2 checks)

### 1.2 Review the Report
The report is saved to `/tmp/opencode/e2e-report-YYYYMMDD-HHMMSS.txt`.

**CRITICAL failures (any):** DO NOT GO LIVE. Fix the failing checks before
proceeding (in a separate R740xd session, if the fix requires touching
the VMs — this dev-machine session shouldn't apply fixes itself).

**Warnings only:** Review each warning. Warnings about optional hardening
items (SSH, firewall, metrics) can be addressed post-launch. Warnings about
game server or network reachability should be investigated.

**All green:** Proceed to Phase 2.

## Phase 2: Manual WAN Verification (from outside LAN)

### 2.1 Game Ports
From a device on cellular data (NOT your home WiFi):
- Open the game and attempt to connect to your server
- Verify you see the server in the server browser at your public IP
- Join the server and confirm you can play

### 2.2 Console Access (behind Cloudflare Access)
From a cellular device or incognito browser:
1. Navigate to `https://CONSOLE_TUNNEL_HOSTNAME`
2. **Verify you see the Cloudflare Access login page** (email/PIN prompt)
3. Complete the Access login
4. **Verify you reach the Dune Console login page**
5. Sign in with your admin password
6. Confirm the console loads, server status displays, maps tab works

### 2.3 Setup Portal
1. Navigate to `https://ACP_SETUP_TUNNEL_HOSTNAME/setup`
2. Verify the setup wizard loads
3. Verify live stats: `https://ACP_SETUP_TUNNEL_HOSTNAME/api/live-stats`

### 2.4 ACP Landing
1. Navigate to `https://ACP_LANDING_HOSTNAME`
2. Verify the landing page loads
3. Verify the stats widget shows player counts (may be 0 at first)

## Phase 3: Discord Bot Verification

### 3.1 Slash Commands
In your Discord server, run each of these commands and verify they respond:
```
/dune server health     → Returns server status
/dune server status     → Returns detailed status card
/dune data population   → Shows player count
/dune server readiness  → Shows readiness state
/dune core ping         → Returns latency
```

### 3.2 Player Features
Have a player (or a test account) verify:
```
/dune data whoami       → Shows linked character
/dune data inventory    → Shows inventory items
/dune data storage      → Shows storage contents
```

### 3.3 Scheduled Posts (if enabled)
If `DUNE_POST_SCHEDULE_TYPE` is set, wait for the next scheduled post
and verify it appears in the configured channel.

## Phase 4: Go-Live Cutover

### 4.1 Final Check Before Announcement
- [ ] All CRITICAL checks from 11-e2e-verify.sh pass
- [ ] Cloudflare Access enforced on `CONSOLE_TUNNEL_HOSTNAME`
- [ ] Game ports reachable from WAN (cellular test passed)
- [ ] Discord bot responds to all slash commands
- [ ] Setup portal and landing page accessible
- [ ] DB password rotated (different on Prod vs Dev)
- [ ] Strong admin password set
- [ ] Restart schedule enabled
- [ ] DB backups enabled
- [ ] SQLite backup timer active (C-4 fix)
- [ ] At least one player tested connectivity from outside

### 4.2 Update Server Listing (if applicable)
If your server is listed on community server lists, update the IP address
to your new public IP.

### 4.3 Announce to Player Base
Post in your Discord community:
```
@everyone The server migration to new hardware is complete!

Server: Tabr Tau
Features: 2 Sietch dimensions (40 players each), Deep Desert open

The server IP remains the same. If you experience any issues,
please report them in <#support-channel>.
```

## Phase 5: Post-Deployment Ops (start a NEW R740xd session)

Performance baseline capture, first-24-hours monitoring, and
troubleshooting commands all require SSH access to the VMs — that's
R740-side work. Start a separate session and run
`r740xd/04-post-deployment-ops.md` for those steps.

## Phase 6: Post-Deployment Evidence (back in this dev-machine session)

### 6.1 Save Verification Report
```bash
cp /tmp/opencode/e2e-report-*.txt ~/r740-deployment/compliance/evidence/go-live/
```

### 6.2 Complete OCI Decommissioning Evidence
Fill in and sign `~/r740-deployment/compliance/evidence/decommissions/2026-08-07-oci-acp-bot-vnic.md`
— **only once the OCI-to-R740 bot migration has actually been executed**
(see `r740xd/03-bot-deploy-and-tunnel.md`); this evidence file itself is
currently just an unexecuted template (see the file's own status note),
and this step must not be checked off before that migration is real.

### 6.3 Update Incident Index
Add an entry to `~/archive/INCIDENT-INDEX.md`:
```
INC-2026-08-07-001 | Low | R740 migration — deployment completed, all e2e checks passed, zero incidents
```

### 6.4 Archive Gaming PC (after burn-in)
Only after at least 3 days of stable production with real players, and
after `r740xd/04-post-deployment-ops.md`'s monitoring phase looks clean:
```bash
# On the gaming PC:
bash ~/r740-deployment/scripts/07-wsl-decommission.sh
```

## State After Completion
- [ ] Full E2E verification suite run, report saved
- [ ] All CRITICAL checks passing
- [ ] Manual WAN verification passed (cellular + incognito browser)
- [ ] Discord bot responding to all slash commands
- [ ] Player base announced
- [ ] Post-deployment ops session started (`r740xd/04-post-deployment-ops.md`)
- [ ] OCI decommissioning evidence completed (only once migration is real)
- [ ] Incident index updated
- [ ] Go-live evidence saved under `compliance/evidence/go-live/`
