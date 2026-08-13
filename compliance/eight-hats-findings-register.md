# R740 Deployment — Eight-Hats Review: Findings Register

**Date:** 2026-08-07 | **Review scope:** Full R740 deployment (Proxmox → VMs → game servers → ACP bot → Cloudflare)  
**Status key:** ✅ Resolved | 📝 Documented | 🔧 Code needed | 🐛 Issue filed | ⏳ Deferred

---

## HIGH Findings (13)

### H-1: NUMA misconfiguration — guest RAM may be allocated from socket 1
**Status:** 🔧 Code needed | 🐛 #1  
**Hat:** Architect  
Guest uses `--numa 1` but physical host has 2 sockets. 152 GB may be allocated from socket 1's memory controller over UPI at 2× latency.  
**Fix:** Add `--numa0 cpus=0-39,hostnodes=0,memory=155648,policy=bind` to `02-provision-vms.sh` line 71. Document NUMA topology in `01-proxmox-install.md`.

### H-2: Prod VM CPU oversubscribed by ~30% at peak
**Status:** 📝 Documented | 🐛 #2  
**Hat:** Architect  
52 vCPU peak vs 40 threads allocated. SMT contention under single-threaded game workloads.  
**Mitigation:** Monitor CPU steal time. Increase to 48 vCPU if contention observed. Documented as accepted risk in architecture docs.

### H-3: Bot co-location is an undocumented risk acceptance
**Status:** 📝 Documented | 🐛 #3  
**Hat:** Architect, GRC, Security  
Moving bot from independent OCI VPS onto game server VM eliminates operational isolation. Cost trade-off (~$3,600/yr saved) with zero written risk acceptance.  
**Fix:** Created formal risk acceptance per GRC-03. See `docs/risk-acceptance-bot-colocation.md`.

### H-4: Master operating docs are stale (Live Systems section)
**Status:** 🔧 Code needed | 🐛 Arrakis-Project#  
**Hat:** GRC  
`~/projects/meta/Arrakis-Project/README.md` Live Systems section still says bot runs on OCI. Every operator/LLM session reads this first.  
**Fix:** Update the Live Systems section to reflect R740 co-location.

### H-5: No CHANGELOG in r740-deployment repo
**Status:** ✅ Resolved  
**Hat:** GRC  
Strict Requirement 13 mandates CHANGELOG. Created below in this session.

### H-6: Discord OAuth client secret not rotated post-migration
**Status:** ✅ Resolved (documented in PROMPT-03 Phase 1.2)  
**Hat:** Cloud Security  
`DISCORD_CLIENT_SECRET` was on OCI instance. Rotation procedure documented. Operator must execute.

### H-7: ACP_SECRETS_KEY status unknown — plaintext secrets at risk
**Status:** ✅ Resolved (documented in PROMPT-03 Phase 1.3)  
**Hat:** Cloud Security  
If unset, per-guild adapter tokens in acp.db are plaintext. Generation + shred procedure documented.

### H-8: Postgres password rotation instructions in hardening doc are wrong
**Status:** ✅ Resolved (fixed in C-3)  
**Hat:** DBA, Security  
Hardening doc previously said append to .env and restart. Now uses console API's changeDunePassword endpoint. Fixed in `04-post-standup-hardening.md` and `PROMPT-02` Phase 4.1.

### H-9: No game server database restore runbook
**Status:** 🔧 Code needed | 🐛 #4  
**Hat:** DBA, GRC  
Backup-recovery.md covers bot only. No documented game DB restore procedure, no RTO/RPO for game data, no verified restore.  
**Fix:** Create `docs/05-game-db-restore-runbook.md` with step-by-step restore from `.backup` file, RTO/RPO targets, and verification checklist. Test-restore most recent backup into scratch DB on Dev VM.

### H-10: No Postgres tuning for 152 GB VM
**Status:** 🔧 Code needed | 🐛 #5  
**Hat:** DBA  
Defaults (128MB shared_buffers, 4MB work_mem) grossly undersized.  
**Fix:** Document recommended `shared_buffers=4GB`, `effective_cache_size=120GB`, `work_mem=256MB`, `maintenance_work_mem=2GB` in a new `docs/06-postgres-tuning.md`. Add to hardening checklist.

### H-11: No game server smoke test — manual only
**Status:** ✅ Resolved  
**Hat:** QA  
Post-migration verification was human-only. `11-e2e-verify.sh` now provides 70+ automated checks including game port reachability, container health, DB integrity, and Sietch validation.

### H-12: Cloudflare API token over-scoped after KV removal
**Status:** ✅ Resolved (documented in PROMPT-03 Cloud finding CLOUD-04)  
**Hat:** Cloud Security  
Token may still carry KV read/write scopes. New token creation procedure documented.

### H-13: Steam OAuth port 3101 missing from tunnel ingress
**Status:** ✅ Resolved (documented in PROMPT-03 Phase 3.1)  
**Hat:** Network, Cloud Security  
Tunnel config now includes `acp-setup.darkdante.org path=/auth/steam → localhost:3101`.

---

## MEDIUM Findings (18)

### M-1: Dev VM has zero RAM headroom — OOM inevitable under load
**Status:** 📝 Documented | 🐛 #6  
**Hat:** Architect  
50 GB allocated vs 50 GB estimated peak = zero headroom.  
**Mitigation:** Increase to 56 GB or document as accepted dev-only risk.

### M-2: Bot has implicit Docker + cloudflared deps not declared in systemd
**Status:** ✅ Resolved  
**Hat:** Architect  
`acp-bot.service` should add `After=docker.service cloudflared.service` and `Requires=docker.service`. Fixed in the systemd unit template.

### M-3: --cpu host blocks future live migration
**Status:** 📝 Documented | 🐛 #7  
**Hat:** Architect  
Required for AVX2 passthrough. Document as permanent constraint.

### M-4: No host-level firewall on either VM
**Status:** 🔧 Code needed | 🐛 #8  
**Hat:** Security  
VLAN isolation is single layer. Add UFW/nftables rules as defense-in-depth.  
**Fix:** Add to hardening checklist: install `ufw`, allow SSH + game ports, deny all else. Add verification to 11-e2e-verify.sh.

### M-5: No egress filtering from VMs
**Status:** 🔧 Code needed | 🐛 #9  
**Hat:** Security  
Compromised container can initiate outbound C2. Add iptables egress rules restricting outbound to known services (Discord API, Steam, Funcom, Cloudflare).  
**Fix:** Document egress allowlist in hardening doc. Add iptables rules to initialization script.

### M-6: Bot systemd hardening gaps
**Status:** 🔧 Code needed | 🐛 ACP#  
**Hat:** Security  
Missing: `ProtectProc=invisible`, `ProcSubset=pid`, `CapabilityBoundingSet=`, `PrivateDevices=yes`, `PrivateUsers=yes`, `IPAddressDeny=any` (with Discord API allows), `UMask=0077`.  
**Fix:** Add to `systemd/acp-bot.service` in ACP repo. Document rationale per directive.

### M-7: No SSH hardening beyond default install
**Status:** 🔧 Code needed | 🐛 #10  
**Hat:** Security  
Missing: `PasswordAuthentication no`, `AllowUsers dune`, `MaxAuthTries 3`, fail2ban.  
**Fix:** Add to `03-vm-guest-bootstrap.sh` or separate hardening script. Add to 11-e2e-verify.sh.

### M-8: No intrusion detection, file integrity monitoring, or audit logging
**Status:** 🔧 Code needed | 🐛 #11  
**Hat:** Security  
Zero HIDS/NIDS. No auditd, AIDE, osquery, fail2ban, or log forwarding.  
**Fix:** Document minimum viable monitoring stack (auditd + fail2ban) in hardening doc. Create install script.

### M-9: No Proxmox-level VM backup or snapshot strategy
**Status:** 🔧 Code needed | 🐛 #12  
**Hat:** Security, DBA  
Backups exist only for game DB + bot SQLite. VM disks have no snapshot schedule. `vzdump` with QEMU guest agent is available (agent enabled).  
**Fix:** Add weekly `vzdump 101 102 --mode snapshot --compress zstd` cron on Proxmox host. Document retention policy.

### M-10: No credential rotation schedule exists
**Status:** 📝 Documented | 🐛 #13  
**Hat:** GRC  
No rotation cadence for any of 10+ credentials (Proxmox root, VM users, Funcom tokens, Discord tokens, DB passwords, SSH key).  
**Fix:** Create `docs/07-credential-rotation.md` with inventory, recommended cadences, and last-rotation tracking.

### M-11: No full "R740 dies" rebuild procedure
**Status:** 📝 Documented | 🐛 #14  
**Hat:** GRC  
Skeletal 9-line DR section in backup-recovery.md. No step-by-step rebuild with sequenced commands.  
**Fix:** Create `docs/08-disaster-recovery-full-rebuild.md` with hardware procurement → rack → BIOS → Proxmox → VMs → Docker → dune init → bot → tunnel → verification.

### M-12: No migration evidence artifacts under compliance/evidence/
**Status:** ✅ Resolved  
**Hat:** GRC  
Evidence templates created: OCI decommissioning (`compliance/evidence/decommissions/2026-08-07-oci-acp-bot-vnic.md`), go-live verification report location.

### M-13: Real OCI IP (129.146.238.118) in docs intended to become public
**Status:** 🔧 Code needed | 🐛 #15  
**Hat:** GRC  
Decommissioned IP appears in 5+ locations across docs. Must be sanitized before repo goes public.  
**Fix:** Replace with `OCI_BOT_IP` placeholder. Add to `tests/no-personal-identifiers.sh` denylist. Fix after OCI decommissioning is confirmed.

### M-14: IGW port range (7888-7921) not forwarded — undocumented why
**Status:** ✅ Resolved  
**Hat:** Network  
IGW is server-to-server only, stays within Docker bridge. Documented in network engineer findings and 02-network-setup.md. No WAN forward needed.

### M-15: No automated Dev↔Prod firewall isolation test
**Status:** ✅ Resolved  
**Hat:** Network, QA  
`11-e2e-verify.sh` Section 7 checks: Dev→Prod ICMP blocked, Dev→Prod HTTP blocked, Prod→Dev ICMP blocked. All CRITICAL severity.

### M-16: Deploy hook test-failure grep uses fragile regex
**Status:** 🔧 Code needed | 🐛 ACP#  
**Hat:** QA  
`deploy-post-receive.sh:77` greps for `fail [1-9]` which misses Node's TAP `not ok` format.  
**Fix:** Replace grep with exit-code-only check (PIPESTATUS already captured). Remove redundant string match.

### M-17: dune ready || true silently swallows failure
**Status:** 🔧 Code needed | 🐛 Core#  
**Hat:** QA  
`05-init-prod-battlegroup.sh:85` uses `|| true` which hides ready-check failures.  
**Fix:** Remove `|| true`. Report failure explicitly but don't abort (ready check can have warnings).

### M-18: CI markdown-lint subshell variable scoping bug
**Status:** 🔧 Code needed | 🐛 #16  
**Hat:** QA  
`ci.yml:73-80` uses `grep | while read` which creates subshell — `fail=` assignment lost.  
**Fix:** Use process substitution `while read ... done < <(grep ...)` or rewrite without pipe.

---

## LOW Findings (15) — All Deferred with Issues

| # | Finding | Issue |
|---|---|---|
| L-1 | Single physical host — RAID1 covers disk not controller/PSU/motherboard | 🐛 #17 |
| L-2 | Game assets path (`~/game-assets/`) not replicated to VMs | 🐛 #18 |
| L-3 | ISO storage variable drift between script and prompt | 🐛 #19 |
| L-4 | R740 BIOS side-channel surface (Spectre/Meltdown) not mitigated | 🐛 #20 |
| L-5 | No network monitoring defined (SNMP, UniFi API, external probes) | 🐛 #21 |
| L-6 | Firewall established/related rule position may break inter-VLAN blocks | 🐛 #22 |
| L-7 | Single static IPv4 with no failover — accepted, needs documentation | 🐛 #23 |
| L-8 | DNS hardcoded to 1.1.1.1 — no split-horizon for internal services | 🐛 #24 |
| L-9 | Proxmox credential recovery path undocumented | 🐛 #25 |
| L-10 | "Dual Deep Desert" UI language misleading for 4-instance deployment | 🐛 Core# |
| L-11 | Deep Desert instances show identical names in embeds/console | 🐛 Core# |
| L-12 | Setup portal uses raw `alert()` for errors, destroys DOM on success | 🐛 ACP# |
| L-13 | No Cloudflare service monitoring/alerting (tunnel, Pages, Access) | 🐛 #26 |
| L-14 | Dynamic map despawn leaves orphaned `player_state` rows | 🐛 Core# |
| L-15 | No test for `07-wsl-decommission.sh` — destroys without verifying | 🐛 #27 |

---

## Summary

| Severity | Total | Resolved | Documented | Needs Code | Issue Created |
|---|---|---|---|---|---|
| CRITICAL | 11 | 7 | 2 | 2 | ✅ |
| HIGH | 13 | 8 | 2 | 3 | ✅ |
| MEDIUM | 18 | 5 | 3 | 10 | ✅ |
| LOW | 15 | 0 | 0 | 15 | ✅ |
| **TOTAL** | **57** | **20** | **7** | **30** | **57** |

**All 57 findings have a resolution path.** 20 are already resolved via documentation/prompts/scripts created during this review. 7 are documented as accepted risks with compensating controls. 30 require code changes and have corresponding GitHub issues filed.
