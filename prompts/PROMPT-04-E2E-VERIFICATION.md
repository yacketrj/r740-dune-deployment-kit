# PROMPT-04: End-to-End Verification & Go-Live

This prompt runs ON YOUR DEV MACHINE after ALL deployment phases are
complete (PROMPT-00 through PROMPT-03). It runs the full automated
verification suite, performs manual checks that can't be automated,
and walks through the go-live cutover sequence.

## Pre-Requisites
- PROMPT-01 through PROMPT-03 fully executed
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
proceeding.

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
1. Navigate to `https://console.darkdante.org`
2. **Verify you see the Cloudflare Access login page** (email/PIN prompt)
3. Complete the Access login
4. **Verify you reach the Dune Console login page**
5. Sign in with your admin password
6. Confirm the console loads, server status displays, maps tab works

### 2.3 Setup Portal
1. Navigate to `https://acp-setup.darkdante.org/setup`
2. Verify the setup wizard loads
3. Verify live stats: `https://acp-setup.darkdante.org/api/live-stats`

### 2.4 ACP Landing
1. Navigate to `https://acp.darkdante.org`
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

## Phase 4: Performance Baseline

### 4.1 Capture Idle Resource Usage
```bash
ssh dune@192.168.20.10 << 'ENDSSH'
echo "=== IDLE BASELINE $(date) ==="
free -h | head -2
echo "---"
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null | head -20
echo "---"
uptime
ENDSSH
```

Save this output — it's your baseline for comparing against when players
are online.

### 4.2 Monitor During First Player Session
After players join, re-run the stats command above and compare:
- Memory usage should remain below 140 GB (92% of 152 GB)
- No container should show CPU consistently above 80%
- `dune status` should remain healthy

## Phase 5: Go-Live Cutover

### 5.1 Final Check Before Announcement
- [ ] All CRITICAL checks from 11-e2e-verify.sh pass
- [ ] Cloudflare Access enforced on `console.darkdante.org`
- [ ] Game ports reachable from WAN (cellular test passed)
- [ ] Discord bot responds to all slash commands
- [ ] Setup portal and landing page accessible
- [ ] DB password rotated (different on Prod vs Dev)
- [ ] Strong admin password set
- [ ] Restart schedule enabled
- [ ] DB backups enabled
- [ ] SQLite backup timer active (C-4 fix)
- [ ] At least one player tested connectivity from outside

### 5.2 Update Server Listing (if applicable)
If your server is listed on community server lists, update the IP address
to your new public IP.

### 5.3 Announce to Player Base
Post in your Discord community:
```
@everyone The server migration to new hardware is complete!

Server: Tabr Tau
Features: 2 Sietch dimensions (40 players each), Deep Desert open

The server IP remains the same. If you experience any issues,
please report them in <#support-channel>.
```

### 5.4 Monitor First 24 Hours
- [ ] Watch `dune status` hourly for any warnings
- [ ] Check `journalctl -u acp-bot -n 50` for any bot errors
- [ ] Monitor player reports for lag, disconnects, or instability
- [ ] Check Cloudflare Tunnel health
- [ ] Verify daily DB backups ran successfully

## Phase 6: Post-Deployment Evidence

### 6.1 Save Verification Report
```bash
cp /tmp/opencode/e2e-report-*.txt ~/r740-deployment/compliance/evidence/go-live/
```

### 6.2 Complete OCI Decommissioning Evidence
Fill in and sign `~/r740-deployment/compliance/evidence/decommissions/2026-08-07-oci-acp-bot-vnic.md`

### 6.3 Update Incident Index
Add an entry to `~/archive/INCIDENT-INDEX.md`:
```
INC-2026-08-07-001 | Low | R740 migration — deployment completed, all e2e checks passed, zero incidents
```

### 6.4 Archive Gaming PC (after burn-in)
Only after at least 3 days of stable production with real players:
```bash
# On the gaming PC:
bash ~/r740-deployment/scripts/07-wsl-decommission.sh
```

## Troubleshooting

### dune status shows warnings

## Troubleshooting

### dune status shows warnings
```bash
# Check each service individually:
ssh dune@192.168.20.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune services && runtime/scripts/dune ports"
# Common fix: if IP mismatch, update SERVER_IP in .env and restart
```

### Bot not responding in Discord
```bash
ssh dune@192.168.20.10 "journalctl -u acp-bot --since '10 min ago' --no-pager | grep -i error"
# Common fix: verify DISCORD_BOT_TOKEN in .env, restart service
```

### Players can't connect
```bash
# From dev machine, test each port:
nc -zu -w 2 <PUBLIC_IP> 7778
nc -z -w 2 <PUBLIC_IP> 31982

# On the VM, verify ports are listening:
ssh dune@192.168.20.10 "ss -ulnp | grep '777[7-9]'"
```

### Cloudflare Access not working
```bash
# Test tunnel health:
ssh dune@192.168.20.10 "systemctl status cloudflared && cloudflared tunnel info"
# Verify Access policy in Cloudflare Zero Trust dashboard
```

## State After Completion
- [ ] Full E2E verification suite run, report saved
- [ ] All CRITICAL checks passing
- [ ] Manual WAN verification passed (cellular + incognito browser)
- [ ] Discord bot responding to all slash commands
- [ ] Performance baseline captured
- [ ] Player base announced
- [ ] 24-hour monitoring initiated
- [ ] OCI decommissioning evidence completed
- [ ] Incident index updated
- [ ] Go-live evidence saved under `compliance/evidence/go-live/`
