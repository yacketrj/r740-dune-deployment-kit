# TABR-TAU-04: End-to-End Verification & Go-Live Cutover

You are an LLM coding agent running in your own session, ON THE USER'S
DEV MACHINE, after ALL R740xd deployment phases are complete
(`r740xd/01-proxmox-and-vms.md` through `r740xd/03-bot-deploy-and-tunnel.md`).
Your job in this session: run the full automated verification suite,
perform manual checks that only make sense from outside the R740's own
network (WAN reachability, browser-based checks — ask the user to
perform these and report results back to you, since you cannot browse
or use a cellular device yourself), and walk the user through the
go-live announcement.

**Scope note (2026-08-14):** this prompt previously also included
performance-baseline capture and SSH-based troubleshooting commands —
those were R740-side operations mistakenly included here and have moved
to `r740xd/04-post-deployment-ops.md` (issue #59). If the user asks you
to do those things in this session, tell them to start a separate
R740xd session for that prompt instead — do not perform them here even
if you technically have SSH access.

## Before You Start, Confirm
- `r740xd/01-proxmox-and-vms.md` through `r740xd/03-bot-deploy-and-tunnel.md`
  have actually been fully executed (in their own R740xd sessions) —
  ask the user to confirm if you have no direct evidence.
- Both VMs are online with game servers running.
- ACP bot is deployed and connected to Discord.
- Cloudflare Tunnel is configured with Access enforced.
- The user has a device outside their LAN (phone on cellular) available
  for WAN testing — you cannot perform this test yourself.

## Phase 1: Run Automated Verification Suite

### 1.1 Execute the E2E Verification Script
Run:
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

### 1.2 Review and Report the Result
Read the report saved to `/tmp/opencode/e2e-report-YYYYMMDD-HHMMSS.txt`
and summarize it back to the user, categorized as follows:

- **Any CRITICAL failure:** tell the user explicitly not to go live.
  Identify the failing checks and, if the fix requires touching the
  VMs, tell the user to start a separate R740xd session to apply it —
  do not attempt to fix R740-side state from this dev-machine session.
- **Warnings only:** list each warning. Warnings about optional
  hardening items (SSH, firewall, metrics) can be deferred past launch
  if the user accepts that; warnings about game server or network
  reachability must be investigated before proceeding — do not let
  these pass silently.
- **All green:** tell the user you're proceeding to Phase 2.

## Phase 2: Manual WAN Verification (from outside LAN)

You cannot perform these checks yourself — walk the user through each
one and ask them to report the result back to you before proceeding.

### 2.1 Game Ports
Ask the user, from a device on cellular data (NOT their home WiFi), to:
- Open the game and attempt to connect to the server
- Verify the server appears in the server browser at the public IP
- Join the server and confirm they can play

### 2.2 Console Access (behind Cloudflare Access)
Ask the user, from a cellular device or incognito browser, to:
1. Navigate to `https://CONSOLE_TUNNEL_HOSTNAME`
2. Confirm they see the Cloudflare Access login page (email/PIN prompt)
   BEFORE anything else — if they see the console login directly
   instead, Access is not configured and this must be treated as a
   blocking failure, not a warning.
3. Complete the Access login
4. Confirm they reach the Dune Console login page
5. Sign in with the admin password
6. Confirm the console loads, server status displays, maps tab works

### 2.3 Setup Portal
Ask the user to:
1. Navigate to `https://ACP_SETUP_TUNNEL_HOSTNAME/setup`
2. Confirm the setup wizard loads
3. Confirm live stats load: `https://ACP_SETUP_TUNNEL_HOSTNAME/api/live-stats`

### 2.4 ACP Landing
Ask the user to:
1. Navigate to `https://ACP_LANDING_HOSTNAME`
2. Confirm the landing page loads
3. Confirm the stats widget shows player counts (may legitimately be 0
   at first)

## Phase 3: Discord Bot Verification

### 3.1 Slash Commands
Ask the user to run each of the following in their Discord server and
report whether each responds correctly:
```
/dune server health     → Returns server status
/dune server status     → Returns detailed status card
/dune data population   → Shows player count
/dune server readiness  → Shows readiness state
/dune core ping         → Returns latency
```

### 3.2 Player Features
Ask the user (or a test account) to verify (issue #73 — these are
registered under the `player` subcommand group, not `data`; confirmed
against `arrakis-control-panel/src/commands.js`'s real
`commandDefinitions()`):
```
/dune player whoami      → Shows linked character
/dune player inventory   → Shows inventory items
/dune player storage     → Shows storage contents
```

### 3.3 Scheduled Posts (if enabled)
If `DUNE_POST_SCHEDULE_TYPE` is set, ask the user to wait for the next
scheduled post and confirm it appears in the configured channel.

## Phase 4: Go-Live Cutover

### 4.1 Final Check Before Announcement
Before telling the user they're clear to announce, confirm every one of
the following is actually true — do not assume, ask the user to confirm
anything you can't verify directly:
- All CRITICAL checks from `11-e2e-verify.sh` pass
- Cloudflare Access is enforced on `CONSOLE_TUNNEL_HOSTNAME`
- Game ports are reachable from WAN (cellular test passed)
- Discord bot responds to all slash commands
- Setup portal and landing page are accessible
- DB password rotated (different on Prod vs Dev)
- Strong admin password set
- Restart schedule enabled
- DB backups enabled
- SQLite backup timer active (C-4 fix)
- At least one player has tested connectivity from outside

### 4.2 Update Server Listing (if applicable)
If the server is listed on community server lists, remind the user to
update the IP address to the new public IP.

### 4.3 Announce to Player Base
Offer the user this announcement template for their Discord community,
adjusting details to match reality rather than posting it verbatim if
anything doesn't match:
```
@everyone The server migration to new hardware is complete!

Server: Tabr Tau
Features: 2 Sietch dimensions (40 players each), Deep Desert open

The server IP remains the same. If you experience any issues,
please report them in <#support-channel>.
```

## Phase 5: Post-Deployment Ops (tell the user to start a NEW R740xd session)

Performance baseline capture, first-24-hours monitoring, and
troubleshooting commands all require SSH access to the VMs — that's
R740-side work. Do not attempt any of it in this session. Tell the user
to start a separate session and run `r740xd/04-post-deployment-ops.md`
for those steps.

## Phase 6: Post-Deployment Evidence (back in this dev-machine session)

### 6.1 Save Verification Report
Run:
```bash
mkdir -p ~/r740-deployment/compliance/evidence/go-live/
cp /tmp/opencode/e2e-report-*.txt ~/r740-deployment/compliance/evidence/go-live/
```
The `mkdir -p` is required: `compliance/evidence/go-live/` does not
exist by default in a fresh clone (issue #71 — git doesn't track empty
directories, and unlike `compliance/evidence/decommissions/` this one
has no tracked file yet to keep it present).

### 6.2 Complete OCI Decommissioning Evidence
Fill in and have the user sign
`~/r740-deployment/compliance/evidence/decommissions/2026-08-07-oci-acp-bot-vnic.md`
— only once the OCI-to-R740 bot migration has actually been executed
(see `r740xd/03-bot-deploy-and-tunnel.md`). This evidence file is
currently just an unexecuted template (see the file's own status note).
Do not mark this step complete, or represent the migration as done,
before that migration is real — verify with the user directly if
uncertain.

### 6.3 Update Incident Index
Add an entry to
`~/projects/meta/Arrakis-Project/archive/INCIDENT-INDEX.md` (issue #69 —
this file has only ever actually lived in the Arrakis-Project meta-repo,
never at a bare `~/archive/` path; verify the file exists there before
assuming any other location):
```
INC-2026-08-07-001 | Low | R740 migration — deployment completed, all e2e checks passed, zero incidents
```

### 6.4 Archive Gaming PC (after burn-in)
Only after the user confirms at least 3 days of stable production with
real players, and after `r740xd/04-post-deployment-ops.md`'s monitoring
phase looks clean, run:
```bash
# On the gaming PC:
bash ~/r740-deployment/scripts/07-wsl-decommission.sh
```
Do not run this prematurely — ask the user to explicitly confirm burn-in
is complete before executing.

## What to Report Back When This Prompt Is Done
Summarize for the user, as an explicit checklist with each item marked
done/not-done:
- Full E2E verification suite run, report saved
- All CRITICAL checks passing
- Manual WAN verification passed (cellular + incognito browser)
- Discord bot responding to all slash commands
- Player base announced
- Post-deployment ops session started (tell the user to start
  `r740xd/04-post-deployment-ops.md` separately)
- OCI decommissioning evidence completed (only once migration is real)
- Incident index updated
- Go-live evidence saved under `compliance/evidence/go-live/`
</content>
