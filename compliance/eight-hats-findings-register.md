# R740 Deployment — Eight-Hats Review: Findings Register

**Date:** 2026-08-07 | **Review scope:** Full R740 deployment (Proxmox → VMs → game servers → ACP bot → Cloudflare)  
**Status key:** ✅ Resolved | 📝 Documented | 🔧 Code needed | 🐛 Issue filed | ⏳ Deferred

**Correction (2026-08-14):** this register's CRITICAL section was
missing entirely from the earliest version of this file that ever
landed on `main` — despite the Summary table at the bottom always
having claimed 11 CRITICAL findings. Every issue-number citation
throughout the HIGH/MEDIUM/LOW sections below was also wrong (a
consistent off-by-one and worse, verified 2026-08-14 by cross-checking
every `🐛 #N` citation against the real GitHub issue at that number) —
both defects are fixed in this pass. 7 of the original 11 CRITICAL
findings were reconstructable from real fix-references already
scattered across this repo's `prompts/`/`docs/` (C-2, C-3, C-4, C-6,
C-7, C-8, C-11); the remaining ~4 CRITICAL findings' actual content was
never captured anywhere recoverable and could not be reconstructed —
see the note in the CRITICAL section below rather than fabricating
content to hit the original count of 11.

---

## CRITICAL Findings (11 originally claimed — 7 recoverable, ~4 lost)

### C-2: Game containers run `--privileged --seccomp=unconfined --network host`
**Status:** 🔧 Code needed | 🐛 #3  
**Hat:** Security, Architect  
Inherited from upstream, required by Funcom's closed-source binary. A
remote code execution exploit provides root-equivalent VM compromise.  
**Fix (per issue #3):** Document this as an accepted risk with
compensating controls (host-level egress filtering, auditd for breakout
detection, verified VLAN isolation) — not something this kit can
eliminate given the upstream binary's requirements.

### C-3: Postgres password rotation instructions in hardening doc were wrong
**Status:** ✅ Resolved  
**Hat:** DBA, Security  
The hardening doc previously said to append a new password to `.env`
and restart — this does not actually rotate the live Postgres role's
password, only the app's expectation of it, leaving them out of sync.  
**Fix:** Corrected to use the console API's `changeDunePassword`
endpoint, which handles both the `ALTER ROLE` and the `.env` update
atomically. See `docs/04-post-standup-hardening.md` and
`prompts/r740xd/02-game-servers.md` Phase 4.1.

### C-4: No automated backup for the ACP bot's SQLite database
**Status:** ✅ Resolved  
**Hat:** DBA, GRC  
The bot's `acp.db` (per-guild adapter tokens, link state) had no backup
mechanism at all, unlike the game server's Postgres DB.  
**Fix:** Daily systemd timer (`acp-db-backup.timer`) created, documented
in `prompts/r740xd/03-bot-deploy-and-tunnel.md` Phase 3.1 and verified
in `prompts/tabr-tau/04-e2e-verification.md`.

### C-6: Discord bot secrets copied verbatim from the OCI instance, never rotated
**Status:** ✅ Resolved (documented, operator must execute)  
**Hat:** Cloud Security  
Secrets transferred during the planned bot migration (token, OAuth
client secret, `ACP_SECRETS_KEY`) would otherwise carry over unrotated
from a host being decommissioned — anyone with residual access to the
old host's backups would retain live credential access indefinitely.  
**Fix:** Full rotation procedure documented in
`prompts/r740xd/03-bot-deploy-and-tunnel.md` Phase 1 (moved there
2026-08-14 from a since-removed `tabr-tau/01-bot-secrets-rotation.md` —
see issue #59: secret rotation is R740-side configuration work, not
dev-machine gathering) — must be executed as part of the migration, not
treated as optional.

### C-7: `deploy-post-receive.sh` had no working-tree dirty guard
**Status:** ✅ Resolved | 🐛 #2, closed 2026-08-14 (fixed in
`arrakis-control-panel` PR #165 — `deploy-post-receive.sh` has never
existed in *this* repo; this finding was filed here by mistake during
the original eight-hats review, a process note worth remembering: an
issue's severity/finding-code can be right even when the repo it's
filed against is wrong)  
**Hat:** Architect, Security  
`git reset --hard` with no pre-check for local modifications — a
debugging session SSH'd into the deploy target would have its
in-progress work silently discarded by the next deploy.  
**Fix:** Added an explicit dirty-tree check before the reset, refusing
to deploy if the working tree has uncommitted changes.

### C-8: Cloudflare Access was "recommended", not enforced, for the admin console
**Status:** ✅ Resolved  
**Hat:** Security, Cloud Security  
The admin console mounts the Docker socket — reaching its login page is
one password away from root-equivalent VM access. Treating Cloudflare
Access as optional left a real path to that exposure.  
**Fix:** Documented as MANDATORY, not optional, in
`prompts/r740xd/03-bot-deploy-and-tunnel.md` Phase 2.2, with an explicit
verification step (confirm an incognito browser hits the Access login
wall, not the console login, before considering the console safe).

### C-11: 4 concurrent Deep Desert instances is an unvalidated configuration
**Status:** ✅ Resolved (mechanical gate added)  
**Hat:** QA, Architect  
No confirmed report existed of anyone else running 4 concurrent Deep
Desert instances — deploying this configuration straight to Prod without
validation risked an unknown failure mode under real load.  
**Fix:** `prompts/r740xd/02-game-servers.md` Phase 2.3 requires
validating 4 instances on Dev first (10-minute stability run, captured
evidence) as a mechanical gate before the same configuration is applied
to Prod in Phase 4.

### C-1, and 3 more CRITICAL findings — content permanently lost
**Status:** ⏳ Unrecoverable  
**Hat:** N/A  
This register's CRITICAL section was empty in the earliest version that
ever landed in this repo's git history — the Summary table's claim of
"11 CRITICAL findings" was never backed by actual written content for
at least 4 of them (the 7 above account for C-2/C-3/C-4/C-6/C-7/C-8/C-11
specifically; whichever findings were originally numbered C-1, C-5,
C-9, C-10, or similar were never captured anywhere this correction pass
could find — no cross-references to them exist in any commit, doc, or
script comment in this repo's history). If the original eight-hats
review session that produced this register still has any record of
them (chat history, a draft that was never committed), they should be
added here properly cited; otherwise this gap is permanent and this
note stands as the honest record of that loss, per this project's own
Requirement 12 (documentation must reflect verified reality, not
assumption) — fabricating plausible-sounding findings to hit the
original count of 11 would be worse than an honest gap.

---

## HIGH Findings (13)

### H-1: NUMA misconfiguration — guest RAM may be allocated from socket 1
**Status:** 🔧 Code needed | 🐛 #1  
**Hat:** Architect  
Guest uses `--numa 1` but physical host has 2 sockets. 152 GB may be allocated from socket 1's memory controller over UPI at 2× latency.  
**Fix:** Add `--numa0 cpus=0-39,hostnodes=0,memory=155648,policy=bind` to `02-provision-vms.sh` line 71. Document NUMA topology in `01-proxmox-install.md`.

### H-2: Prod VM CPU oversubscribed by ~30% at peak
**Status:** 📝 Documented (no GitHub issue filed — accepted-risk finding,
mitigation is monitoring-based, not a code change; correction 2026-08-14:
previously cited `#2`, which is actually issue C-7, unrelated to this
finding)  
**Hat:** Architect  
52 vCPU peak vs 40 threads allocated. SMT contention under single-threaded game workloads.  
**Mitigation:** Monitor CPU steal time. Increase to 48 vCPU if contention observed. Documented as accepted risk in architecture docs.

### H-3: Bot co-location is an undocumented risk acceptance
**Status:** 🔧 Code needed | 🐛 #14 (correction 2026-08-14: previously
cited `#3`, which is actually issue C-2, unrelated to this finding.
Also correcting this entry's own status from "📝 Documented" with a
past-tense "Fix: Created..." — `docs/risk-acceptance-bot-colocation.md`
does not exist anywhere in this repo's history; verified via direct
file search, not assumed. This finding is NOT resolved.)  
**Hat:** Architect, GRC, Security  
Moving bot from independent OCI VPS onto game server VM eliminates operational isolation. Cost trade-off (~$3,600/yr saved) with zero written risk acceptance.  
**Fix (not yet done):** Create a formal risk acceptance doc per issue
#14's own description — document what's gained (cost), what's traded
(isolation, blast radius), existing mitigations (VLAN isolation, Proxmox
backups), and a review trigger.

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
**Status:** ✅ Resolved (documented in `prompts/r740xd/03-bot-deploy-and-tunnel.md`
Phase 1.2 — moved there 2026-08-14, see issue #59)  
**Hat:** Cloud Security  
`DISCORD_CLIENT_SECRET` was on OCI instance. Rotation procedure documented. Operator must execute.

### H-7: ACP_SECRETS_KEY status unknown — plaintext secrets at risk
**Status:** ✅ Resolved (documented in `prompts/r740xd/03-bot-deploy-and-tunnel.md`
Phase 2.2 — moved there 2026-08-14, see issue #59)  
**Hat:** Cloud Security  
If unset, per-guild adapter tokens in acp.db are plaintext. Generation + shred procedure documented.

### H-8: Postgres password rotation instructions in hardening doc are wrong
**Status:** ✅ Resolved (fixed in C-3)  
**Hat:** DBA, Security  
Hardening doc previously said append to .env and restart. Now uses console API's changeDunePassword endpoint. Fixed in `04-post-standup-hardening.md` and `prompts/r740xd/02-game-servers.md` Phase 4.1.

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
**Status:** ✅ Resolved (documented in `prompts/r740xd/03-bot-deploy-and-tunnel.md` Cloud finding CLOUD-04)  
**Hat:** Cloud Security  
Token may still carry KV read/write scopes. New token creation procedure documented.

### H-13: Steam OAuth port 3101 missing from tunnel ingress
**Status:** ✅ Resolved (documented in `prompts/r740xd/03-bot-deploy-and-tunnel.md` Phase 2.1)  
**Hat:** Network, Cloud Security  
Tunnel config now includes `ACP_SETUP_TUNNEL_HOSTNAME path=/auth/steam → localhost:3101`.

---

## MEDIUM Findings (18)

### M-1: Dev VM has zero RAM headroom — OOM inevitable under load
**Status:** 📝 Documented | 🐛 #15 (correction 2026-08-14: previously
cited `#6`, which is actually finding M-10)  
**Hat:** Architect  
50 GB allocated vs 50 GB estimated peak = zero headroom.  
**Mitigation:** Increase to 56 GB or document as accepted dev-only risk.

### M-2: Bot has implicit Docker + cloudflared deps not declared in systemd
**Status:** ✅ Resolved  
**Hat:** Architect  
`acp-bot.service` should add `After=docker.service cloudflared.service` and `Requires=docker.service`. Fixed in the systemd unit template.

### M-3: --cpu host blocks future live migration
**Status:** 📝 Documented (no GitHub issue filed — accepted permanent
constraint, not a code change; correction 2026-08-14: previously cited
`#7`, which is actually finding M-9)  
**Hat:** Architect  
Required for AVX2 passthrough. Document as permanent constraint.

### M-4: No host-level firewall on either VM
**Status:** 🔧 Code needed | 🐛 #8 (verified correct 2026-08-14)  
**Hat:** Security  
VLAN isolation is single layer. Add UFW/nftables rules as defense-in-depth.  
**Fix:** Add to hardening checklist: install `ufw`, allow SSH + game ports, deny all else. Add verification to 11-e2e-verify.sh.

### M-5: No egress filtering from VMs
**Status:** 🔧 Code needed | 🐛 #12 (correction 2026-08-14: previously
cited `#9`, which is actually finding M-7)  
**Hat:** Security  
Compromised container can initiate outbound C2. Add iptables egress rules restricting outbound to known services (Discord API, Steam, Funcom, Cloudflare).  
**Fix:** Document egress allowlist in hardening doc. Add iptables rules to initialization script.

### M-6: Bot systemd hardening gaps
**Status:** 🔧 Code needed | 🐛 ACP#  
**Hat:** Security  
Missing: `ProtectProc=invisible`, `ProcSubset=pid`, `CapabilityBoundingSet=`, `PrivateDevices=yes`, `PrivateUsers=yes`, `IPAddressDeny=any` (with Discord API allows), `UMask=0077`.  
**Fix:** Add to `systemd/acp-bot.service` in ACP repo. Document rationale per directive.

### M-7: No SSH hardening beyond default install
**Status:** 🔧 Code needed | 🐛 #9 (correction 2026-08-14: previously
cited `#10`, which is actually finding M-8)  
**Hat:** Security  
Missing: `PasswordAuthentication no`, `AllowUsers dune`, `MaxAuthTries 3`, fail2ban.  
**Fix:** Add to `03-vm-guest-bootstrap.sh` or separate hardening script. Add to 11-e2e-verify.sh.

### M-8: No intrusion detection, file integrity monitoring, or audit logging
**Status:** 🔧 Code needed | 🐛 #10 (correction 2026-08-14: previously
cited `#11`, which is actually finding M-11)  
**Hat:** Security  
Zero HIDS/NIDS. No auditd, AIDE, osquery, fail2ban, or log forwarding.  
**Fix:** Document minimum viable monitoring stack (auditd + fail2ban) in hardening doc. Create install script.

### M-9: No Proxmox-level VM backup or snapshot strategy
**Status:** 🔧 Code needed | 🐛 #7 (correction 2026-08-14: previously
cited `#12`, which is actually finding M-5)  
**Hat:** Security, DBA  
Backups exist only for game DB + bot SQLite. VM disks have no snapshot schedule. `vzdump` with QEMU guest agent is available (agent enabled).  
**Fix:** Add weekly `vzdump 101 102 --mode snapshot --compress zstd` cron on Proxmox host. Document retention policy.

### M-10: No credential rotation schedule exists
**Status:** 📝 Documented | 🐛 #6 (correction 2026-08-14: previously
cited `#13`, which is actually finding M-18, already closed)  
**Hat:** GRC  
No rotation cadence for any of 10+ credentials (Proxmox root, VM users, Funcom tokens, Discord tokens, DB passwords, SSH key).  
**Fix:** Create `docs/07-credential-rotation.md` with inventory, recommended cadences, and last-rotation tracking.

### M-11: No full "R740 dies" rebuild procedure
**Status:** 📝 Documented | 🐛 #11 (correction 2026-08-14: previously
cited `#14`, which is actually finding H-3)  
**Hat:** GRC  
Skeletal 9-line DR section in backup-recovery.md. No step-by-step rebuild with sequenced commands.  
**Fix:** Create `docs/08-disaster-recovery-full-rebuild.md` with hardware procurement → rack → BIOS → Proxmox → VMs → Docker → dune init → bot → tunnel → verification.

### M-12: No migration evidence artifacts under compliance/evidence/
**Status:** ✅ Resolved  
**Hat:** GRC  
Evidence templates created: OCI decommissioning (`compliance/evidence/decommissions/2026-08-07-oci-acp-bot-vnic.md`), go-live verification report location.

### M-13: Real OCI IP in docs intended to become public
**Status:** ✅ Resolved (2026-08-13) | 🐛 needs its own issue — the `#15`
reference this finding originally cited actually points to a different
finding (M-1, Dev VM RAM headroom) on GitHub; that cross-reference was
wrong from when this register was first written and should not be
trusted for this finding specifically.
**Hat:** GRC  
**Correction:** the OCI instance is a live, currently-running production
service as of this writing — NOT decommissioned. The original finding
text incorrectly assumed decommissioning as a precondition for the fix
("fix after OCI decommissioning is confirmed"); that assumption was wrong
and the fix was correctly independent of decommissioning status. The real
IP and the personal-domain subdomains (see this repo's own personal-identifier
guard denylist for the exact values) appeared in 8+ locations across
`docs/03-runbook-day-of.md`, `scripts/07-wsl-decommission.sh`,
`scripts/11-e2e-verify.sh`, and the flat `prompts/PROMPT-00`, `PROMPT-03`,
`PROMPT-04` files that existed at the time (since split into
`prompts/tabr-tau/` and `prompts/r740xd/` — see #50), and this register
itself. All replaced with placeholders
(`OCI_BOT_IP`, `CONSOLE_TUNNEL_HOSTNAME`, `ACP_SETUP_TUNNEL_HOSTNAME`,
`ACP_LANDING_HOSTNAME`), already present in
`tests/no-personal-identifiers.sh`'s denylist.

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
**Status:** ✅ Resolved | 🐛 #13, closed (correction 2026-08-14:
previously cited `#16`, which is actually finding L-1; this finding's
own fix landed and #13 was closed via PR #30)  
**Hat:** QA  
`ci.yml:73-80` uses `grep | while read` which creates subshell — `fail=` assignment lost.  
**Fix:** Use process substitution `while read ... done < <(grep ...)` or rewrite without pipe.

---

## LOW Findings (15) — All Deferred with Issues

**Correction (2026-08-14):** every issue number in this table was off
by exactly +1 against the real GitHub issue at that number (e.g. L-1
cited `#17`, which is actually L-2; the real issue for L-1 is `#16`).
Corrected below after verifying every number against the real issue
title at that number.

| # | Finding | Issue |
|---|---|---|
| L-1 | Single physical host — RAID1 covers disk not controller/PSU/motherboard | 🐛 #16 |
| L-2 | Game assets path (`~/game-assets/`) not replicated to VMs | 🐛 #17 |
| L-3 | ISO storage variable drift between script and prompt | 🐛 #18 |
| L-4 | R740 BIOS side-channel surface (Spectre/Meltdown) not mitigated | 🐛 #19 |
| L-5 | No network monitoring defined (SNMP, UniFi API, external probes) | 🐛 #20 |
| L-6 | Firewall established/related rule position may break inter-VLAN blocks | 🐛 #21 |
| L-7 | Single static IPv4 with no failover — accepted, needs documentation | 🐛 #22 |
| L-8 | DNS hardcoded to 1.1.1.1 — no split-horizon for internal services | 🐛 #23 |
| L-9 | Proxmox credential recovery path undocumented | 🐛 #24 |
| L-10 | "Dual Deep Desert" UI language misleading for 4-instance deployment | 🐛 Core# |
| L-11 | Deep Desert instances show identical names in embeds/console | 🐛 Core# |
| L-12 | Setup portal uses raw `alert()` for errors, destroys DOM on success | 🐛 ACP# |
| L-13 | No Cloudflare service monitoring/alerting (tunnel, Pages, Access) | 🐛 #25 |
| L-14 | Dynamic map despawn leaves orphaned `player_state` rows | 🐛 Core# |
| L-15 | No test for `07-wsl-decommission.sh` — destroys without verifying | 🐛 #26 |

---

## Summary

**Corrected 2026-08-14** — see the CRITICAL section header and the LOW
table note above for the two defects fixed in this pass (missing
CRITICAL content, systematically wrong issue-number citations
throughout). The table below reflects only what is actually documented
in this file as of this correction, not the original, never-substantiated
claim of 57 total findings across all severities.

| Severity | Total (documented) | Resolved | Documented | Needs Code | Unrecoverable |
|---|---|---|---|---|---|
| CRITICAL | 7 (of 11 originally claimed) | 6 | 0 | 1 | 4 |
| HIGH | 13 | 7 | 1 | 5 | 0 |
| MEDIUM | 18 | 6 | 4 | 8 | 0 |
| LOW | 15 | 0 | 0 | 15 | 0 |
| **TOTAL** | **53** (of 57 originally claimed) | **19** | **5** | **29** | **4** |

**53 of the originally-claimed 57 findings have real, verifiable content
and a resolution path** — either already resolved, documented as an
accepted risk, or tracked with a correctly-cited GitHub issue (every
citation independently re-verified 2026-08-14 against the real issue
title at that number). **4 CRITICAL findings' content is permanently
lost** (see the CRITICAL section's closing note) — treat "57" as this
register's original, unverified aspiration, and "53" as its actual,
audited content going forward.

---

## 2026-08-14 (separate review) — Issue #88: Prod/Dev VM NTP sync via Proxmox host — REJECTED

This is a standalone Requirement 20 Layer 1 (design, pre-implementation)
audit, unrelated to the 2026-08-07 review above — recorded here as this
repo's established home for eight-hats findings, not folded into the
counts/tables above.

**Proposal:** give dune-prod/dune-dev a single internal NTP source (the
Proxmox host) instead of each syncing from internet NTP pools directly.
Required a new firewall policy: `Prod-Zone/Dev-Zone -> Internal: ALLOW,
UDP/123, destination 192.168.68.127/32` — the first-ever initiated path
from a battlegroup VM into the Internal zone (where Proxmox lives),
reversing this project's own documented isolation intent (Step 4, rule
5: "if a VM is ever compromised, this stops it from pivoting to the
hypervisor layer").

**Outcome: rejected, unanimously, by every applicable hat.** Full
findings in issue #88's dispatched review. Summary:

- **Architect:** solves a non-problem — all 4 hosts already synced
  within 1-4ms of real UTC before this was proposed; no drift issue,
  no incident. Trades resilience (each VM independently reachable to
  the internet) for a new single-point dependency and East/West
  exposure, for zero measured benefit.
- **Security (CRITICAL):** directly reverses documented threat-model
  intent with no compensating control. chrony has a real CVE history;
  granting a `--privileged`, third-party-binary game-server VM (this
  register's own C-2) a standing network path to the hypervisor's own
  IP is a permanent, nonzero increase in hypervisor attack surface.
- **GRC:** no risk-acceptance record existed prior to this entry (now
  resolved by this entry existing). Separately flagged a process
  inconsistency: the chrony *server-side* config on Proxmox was applied
  live, before this review was requested — assessed as inert/low-risk
  in isolation (nothing could reach it without the firewall rule, and
  it was independently, cleanly reverted), but noted as a pattern not
  to repeat: sensitive-host config changes should go through the same
  review gate as the network change they're paired with, not be
  treated as pre-approved because they're harmless standing alone.
- **Network:** the proposed rule's narrowness (UDP/123, single /32) was
  technically sound as written, but would have needed live
  verification against the UniFi zone-firewall's actual behavior
  before being trusted. The discarded alternative (second Proxmox IP
  on the Mgmt VLAN) was independently found to be *worse*, not
  equivalent — it dual-homes Proxmox across two zones instead of one,
  multiplying its attack surface rather than relocating a single
  exception.
- Cloud Security / UI / DBA: not applicable, confirmed and stated why
  in the full review.
- **QA/Test:** no test plan or rollback procedure existed for the
  firewall policy itself (only for the already-reverted chrony config),
  independently sufficient to call this not implementation-ready even
  setting the reject recommendation aside.

**Remediation:** the already-applied Proxmox chrony server config
(`/etc/chrony/conf.d/lan-ntp-server.conf`) was reverted the same
session this review completed (`rm` + `systemctl restart chrony`,
verified running afterward). No firewall policy change was ever
applied — issue #88 caught this before implementation, exactly as
Requirement 20's Layer 1 gate is meant to. Each VM continues syncing
NTP from internet pools directly, unchanged from before this issue was
opened.

---

## Issue #97 — PR deploy/rollback tool for dune-dev (Layer 1 design audit, 2026-08-18)

Another standalone Requirement 20 Layer 1 (design, pre-implementation)
audit, unrelated to the 2026-08-07 review above and to issue #88's
NTP review — recorded here per this repo's established convention of
mirroring eight-hats findings in both the tracking issue's own comment
thread and this register.

**Proposal:** a Python-based, content-addressed, transactional
deploy/rollback tool (`dune-dev-pr-deploy`) letting an operator deploy
an arbitrary unmerged `dune-awakening-selfhost-docker` PR onto the
persistent `dune-dev` VM for live testing, then cleanly roll back —
replacing the ad hoc manual process that had already caused two
real incidents (a failed `git apply` against 618 lines of undocumented
drift, and a manual revert with no repeatable procedure). Proposed as
a 45-section implementation spec posted as a comment on issue #97.

**Outcome: not rejected, but not approved as-written — 5 CRITICAL
findings required a design revision before Layer 2 implementation
could begin.** Full findings and STRIDE mapping posted as an issue
comment on #97 (per Requirement 20's issue-comment rule); each CRITICAL
finding was additionally filed as its own tracked, closeable issue
(#98-#102) since each was independently resolvable. Summary of the 5
CRITICAL findings, all resolved via a same-day design revision (see
issue #97's second comment) before any code was written:

- **Security (#98, CRITICAL):** the design's only gate on candidate PR
  code before it runs with Docker-socket-adjacent privilege was a
  static `head.repo.full_name` allowlist check — answers "did this
  code arrive via a trusted repo," not "is this specific commit safe
  to run with host-root-equivalent privilege." The design's
  health-gate/auto-rollback model is availability-oriented only; a
  malicious-but-healthy candidate is invisible to it. **Resolved:**
  design revision adds a mandatory static/dependency scan
  (semgrep/trivy/gitleaks) before quiescence, a human-confirmation
  token required for any unattended deploy, and an explicit documented
  limitation that the health gate is not a security control.
- **Cloud Security (#99, CRITICAL):** the tool's own GitHub API
  credential had no specified scope, storage location, or rotation
  cadence anywhere in the 1616-line spec, despite this credential's
  compromise being architecturally equivalent to compromising the
  tool's own trust boundary (it authenticates the same control plane
  that vets candidate code). **Resolved:** design revision specifies a
  fine-grained, single-repo, read-only PAT, `~/.config/`-scoped
  storage matching this workstream's personal-tooling convention
  (explicitly not the target app's `runtime/secrets/`), 90-day
  rotation, and runtime scope/permission self-verification.
- **GRC (#102, CRITICAL — invocation authorization):** nothing in the
  design gated *who* may invoke the tool against the shared, persistent
  dune-dev host — only *what host* (§9) and *what source repo* (§11)
  were validated. The audit-log `operator` field was attribution only,
  not authorization. **Resolved:** design revision adds a dedicated
  POSIX group requirement and derives the audit log's operator field
  from a verified UID, not a caller-overridable environment variable.
- **DBA (#100, CRITICAL):** the design's file-path-based
  `database/schema` risk classification cannot reliably detect real
  DDL in this specific target repo — verified directly that
  `dune-awakening-selfhost-docker` has no dedicated schema/migration
  directory; DDL for the `console` schema lives inline inside an
  11,000+ line general-purpose file (`duneDb.js`), indistinguishable
  by path alone from an ordinary query change. **Resolved:** design
  revision requires diff-content DDL-keyword detection as a
  supplementary signal to path-matching, plus a mechanical
  (not merely documented) backup-verification gate before any
  DB-risk-classified deploy.
- **QA (#101, CRITICAL):** the design's fake `docker`/`rsync`/`curl`
  test-wrapper approach for integration testing had no requirement to
  validate wrapper fidelity against real command behavior — the exact
  mock-divergence failure class this workstream has been burned by
  before. **Resolved:** design revision requires each wrapper to
  document its modeled command version/contract and cross-check it
  against dune-dev's actual installed versions during real-host
  validation.

Additional non-blocking findings (23 HIGH, ~14 MEDIUM across Architect,
Network, and UI/Operator-UX hats) were recorded in the issue #97
findings comment but did not block Layer 2 implementation from
proceeding once the 5 CRITICAL items above were resolved; several are
tracked as follow-up refinements to be picked up during or shortly
after Layer 2 implementation rather than as separate blocking issues.

**Remediation:** a design-revision comment (Amendments 1-6) was posted
on issue #97 the same session the findings were raised, addressing all
5 CRITICAL findings at the design level before any implementation
code was written — consistent with Requirement 20's "shift left"
principle (catching design errors before they become multi-system
rework). Issues #98-#102 were each closed referencing the specific
amendment that resolves them. Project Arrakis `Priority` for #97 was
updated from Medium to High to reflect the docker-socket-adjacent risk
profile identified during the review. This repo's own label taxonomy
(previously missing `severity:*`/`security`/`stride:*` entirely) was
backfilled to match `dune-awakening-selfhost-docker`,
`arrakis-control-panel`, and `dune-ops-observability-addon` as part of
this same review.

### Follow-up: STRIDE report resolution-status drift caught and corrected

The Layer 1 STRIDE table posted alongside the findings above was found,
in a later session, to have gone stale within minutes of being posted:
every row still said "Open — design fix required before Layer 2" after
the design-revision comment (Amendments 1-6) had already resolved the
5 CRITICAL findings 7 minutes later. A corrected STRIDE table was
posted as a follow-up issue comment on #97, and in producing it, 9
additional HIGH-severity findings were confirmed still open (never
addressed by Amendments 1-6, which were explicitly scoped only to the
5 CRITICALs): H-1, H-2, H-3, H-4, H-6, H-11, H-14, H-21, H-22, spanning
all 6 STRIDE categories. This is itself a real instance of the
documentation-drift discipline this workstream's own README requires
(Requirement 12/14): a claim ("all findings resolved") that was true
when written became false minutes later and was not corrected until
independently re-checked — the fix was applying that same "never
assume, always verify" principle to this register's own prior entry,
not just to the underlying design.

Each of the 9 open HIGH findings was filed as its own tracked issue
(#104-#112, matching the #98-#102 pattern — labeled, added to Project
Arrakis with Priority=High/Workstream=Dune) and then resolved via a
second design-revision comment (Amendments 7-15, Design Revision v1.2)
in the same session they were filed:

- **#109 (H-1, DoS):** no decompression-bomb/extraction-size limits.
  **Resolved:** explicit per-file/cumulative/compression-ratio/
  entry-count bounds enforced during streaming extraction.
- **#110 (H-2, Elevation of Privilege):** host-identity guard's
  `/etc/machine-id` signal is regenerable on VM clone; sentinel
  provenance unspecified. **Resolved:** added a fourth,
  non-regeneratable signal (Proxmox VMID) and required sentinel
  provisioning to be a separate, loud, one-time step.
- **#104 (H-3, Information Disclosure):** `docker compose config`
  secret-expansion redaction was hedged ("where available"), not
  concretely closed — confirmed 15+ secret-bearing env vars in
  `docker-compose.web.yml` that this command expands by design.
  **Resolved:** mandatory redaction pass on every captured subprocess
  output, modeled on the addon's `redactSecrets()` pattern.
- **#107 (H-4, Tampering):** GitHub changed-file-path metadata wasn't
  held to the same hostile-input bar as archive-internal paths.
  **Resolved:** extended the existing archive-hardening posture
  explicitly to this separate untrusted-input source.
- **#112 (H-6, Tampering):** full-tree reconciliation had no special
  case for a diff changing `docker-compose.web.yml`'s `name:` field or
  volume declarations — exactly this project's own prior Compose
  project-identity incident's failure shape (confirmed this file's
  fixed `name:` pin was never reverted, unlike the other two Compose
  files). **Resolved:** new maximum-risk `compose-identity`
  classification tier requiring manual review, plus a mandatory
  `test-compose-project-name-portability.sh` preflight gate.
- **#106 (H-11, Information Disclosure / Elevation of Privilege):**
  leaked-token blast radius was undefined because scope was undefined
  (companion to #99's fix). **Resolved:** hardened the redaction
  abuse test to use realistic GitHub token-format strings, tied
  explicitly back to #99's scope-minimization control.
- **#108 (H-14, Denial of Service):** no timeout/TLS-validation
  mandate on GitHub calls; an unbounded hang could hold the single
  exclusive lock indefinitely, blocking `status`/`rollback`/`cleanup`
  for every operation. **Resolved:** hard connect/read timeouts,
  TLS-validation-never-disabled mandate, and lock acquisition
  reordered to exclude network I/O from the critical section.
- **#105 (H-21, Tampering / Elevation of Privilege):** no
  fault-injection test proving the frozen head SHA can't be silently
  swapped for a since-advanced branch tip (TOCTOU). **Resolved:**
  added an explicit fault-injection scenario proving SHA-addressed
  (not branch-addressed) archive download.
- **#111 (H-22, Spoofing / Tampering):** no fault-injection test for a
  race between the trust-allowlist check and archive acquisition.
  **Resolved:** added an explicit scenario with a strong preference
  for structurally eliminating the race (never re-querying source
  identity after initial resolution) over merely detecting it.

**Net result:** all 14 CRITICAL+HIGH findings from the Layer 1 audit
of issue #97 (5 CRITICAL via Amendments 1-6, 9 HIGH via Amendments
7-15) are now resolved at the design level, before any implementation
code was written. The original 45-section spec plus all 15 amendments
is the design baseline for Layer 2 implementation.
