# Changelog

This repo has no independent version/release train yet (see the "Internal
tooling" category in this account's Unified Release Configuration docs —
not yet tagged, starts at `v0.1.0` on first real tagged release). Until
then, entries here are grouped by date and reference the merged PR that
introduced them, in Keep a Changelog style, newest first.

## Unreleased

### Changed

- `scripts/06-pre-migration-backup.sh` now also stages `runtime/secrets/`
  and `runtime/generated/` for transfer, in addition to the DB backup it
  already staged — neither directory was previously captured by any
  migration step, despite `runtime/secrets/` holding credential material
  with no other source of truth (e.g. the Funcom token). Audited both
  directories against the real, live host before implementing: found
  10 real secret files in `runtime/secrets/` and confirmed `runtime/generated/`
  is dominated by ~295 ephemeral `dune-fake-k8s-serviceaccount-<service>-<pid>`
  directories recreated on every container restart (not real state, see
  `runtime/scripts/spawn-server.sh`) — the new `runtime/generated/` tar
  excludes those plus rotating `*.log` files, keeping every other
  config/state file (`battlegroup.env`, `sietch-config.json`,
  `care-package*`, etc.). `runtime/addons/` is explicitly out of scope
  — addons are easily reinstalled (operator decision, 2026-08-14).
  Caught and fixed a real bug during implementation, before it shipped:
  GNU `tar`'s `--exclude` flags are positional and must precede the
  archive-path arguments or they're silently ignored (verified via a
  synthetic test directory both before and after the fix — the original
  flag ordering archived everything, excludes included, with no error).
  (#80)

- Rewrote all six `prompts/tabr-tau/*` and `prompts/r740xd/*` deployment
  prompt files from human-runbook style (numbered steps, "follow the
  interactive prompts", checklists addressed to a person at a keyboard)
  to second-person imperative instructions addressed directly to the
  executing LLM agent. All real operational content (exact commands,
  IPs/hostnames, verification steps, the tabr-tau/r740xd session
  boundary from #59, and prior corrections including the #61 boot-order
  bug and the netplan static-IP installer bug) was preserved unchanged
  in substance. Also fixed a stale claim found during the rewrite:
  `tabr-tau/00-prerequisites.md` listed the dev machine's own OS as
  Ubuntu 24.04, left over from before #52 updated the *VM guest* OS
  target to 26.04 — the separate dev-machine-OS line was never updated.
  (#66)
- Enforced a genuine session boundary between `prompts/tabr-tau/*`
  (gathering-only: credentials, tokens, config values — never installs
  or configures anything) and `prompts/r740xd/*` (all actual
  installation/configuration work, even when typed at a dev machine's
  terminal but targeting the R740 or its VMs via SSH) (#59). Found real
  violations: `tabr-tau/00-prerequisites.md` downloaded ISOs and created
  a bootable USB (now moved into `r740xd/01-proxmox-and-vms.md`'s new
  Phase 0, also now technically simpler since ISOs can be pulled directly
  onto the Proxmox host); `tabr-tau/01-bot-secrets-rotation.md` SSHed
  into `dune-prod` and edited its `.env` (removed entirely, folded into
  `r740xd/03-bot-deploy-and-tunnel.md`'s new Phase 1/2.2); `tabr-tau/04-e2e-verification.md`
  mixed dev-machine-appropriate checks with R740-side SSH work
  (performance baseline, troubleshooting, split into new
  `r740xd/04-post-deployment-ops.md`).
- Corrected `r740xd/01-proxmox-and-vms.md`'s inline VLAN-aware-bridge
  snippet, which was stale/wrong (`bridge-ports eno1` instead of this
  deployment's actual `nic0`; `bridge-vids 10 20 21 30` including a
  VLAN 10 that doesn't exist per the real UniFi network config). Replaced
  with the actual verified-working config, applied live on 2026-08-14
  with zero connectivity loss, plus a live-verification method (check
  actual interface names/VLANs before editing, not from an example).
- Corrected the same file's manual `qm create` fallback commands, which
  still used the old, already-fixed-elsewhere wrong NUMA affinity ranges
  (`--affinity 0-19`, `20-29`) that `scripts/02-provision-vms.sh`
  corrected weeks earlier in this same repo but was never propagated to
  this prompt's inline fallback.
- Fixed a duplicated `## Troubleshooting` header in the former
  `tabr-tau/04-e2e-verification.md` (now resolved by the file split
  above).
- `scripts/11-e2e-verify.sh` checks V5/V10 (CPU affinity) hardcoded the
  old, already-corrected contiguous-range affinity values (`0-19`,
  `20-29`) from before `scripts/02-provision-vms.sh`'s NUMA fix, which
  now pins VMs to a runtime-detected, host-specific, interleaved CPU
  list instead. As written, both checks would always fail once VMs are
  actually provisioned with the corrected affinity, falsely reporting
  the deployment as NOT READY FOR PRODUCTION. Replaced with a structural
  check (all-even CPU IDs for dune-prod/socket 0, all-odd for
  dune-dev/socket 1, explicitly rejecting stale range syntax like
  `0-19`) that doesn't depend on this host's specific CPU numbering.
  (#62)
- `prompts/tabr-tau/04-e2e-verification.md` Phase 6.3 referenced a stale
  `~/archive/INCIDENT-INDEX.md` path that never actually existed — per
  the Arrakis-Project meta-repo README's own 2026-08-12 correction, this
  file has only ever lived at
  `~/projects/meta/Arrakis-Project/archive/INCIDENT-INDEX.md`. This
  prompt was never updated to match that correction. (#69)
- `prompts/tabr-tau/04-e2e-verification.md` Phase 6.1's `cp` command
  targeted `compliance/evidence/go-live/`, a directory that did not
  exist anywhere in the repo (git doesn't track empty directories, and
  unlike `compliance/evidence/decommissions/` this one had no tracked
  file yet to keep it present) — would have failed with "No such file
  or directory" if run verbatim on a fresh clone. Added a `mkdir -p`
  before the `cp`, plus a `.gitkeep` so the directory exists from a
  fresh clone even before this step runs. (#71)
- `prompts/tabr-tau/04-e2e-verification.md` Phase 3.2 told the agent to
  verify `/dune data whoami`, `/dune data inventory`, and
  `/dune data storage` — these commands don't exist under the `data`
  subcommand group. Confirmed against `arrakis-control-panel`'s real,
  currently-registered command set (`src/commands.js`'s
  `commandDefinitions()`, corroborated by `test/commands.test.js`): the
  `data` group only has `population`/`backups`/`maps`, and the real
  character/inventory/storage commands are registered under `player`
  (`player:whoami`, `player:inventory`, `player:storage`). Running the
  prompt's commands verbatim in Discord would have failed. Phase 3.1's
  five commands were independently cross-checked against the same real
  command list and are all correct. (#73)
- `prompts/tabr-tau/00-prerequisites.md`'s SSH-key comment referenced
  bare "issue #81", which doesn't exist in this repo — it's actually
  `arrakis-control-panel#81`, unqualified. Qualified the reference
  explicitly. (#75)
- `prompts/tabr-tau/00-prerequisites.md` Step 4's key-presence check
  expected `DISCORD_BOT_TOKEN=` and `DUNE_DISCORD_ADAPTER_TOKEN=`
  inline, but the real deployment's `.env` uses the `_FILE`-suffixed
  pattern for both (pointing at secret files elsewhere on the host
  rather than storing values inline) — found by actually executing this
  step against the live OCI bot host and diagnosing why two of the four
  expected keys appeared "missing." The deployment is not
  misconfigured; the `_FILE` pattern is the better practice per this
  project's own Requirement 24. Updated the check to accept either
  form. (#78)

### Fixed

- Corrected `docs/05-dell-support-case-boot-failure.md`'s status from a
  stale "Unresolved" (2026-08-12) to "operationally resolved, Dell RCA
  pending" — Proxmox VE 9.2.2 is confirmed installed and running on the
  target host as of 2026-08-13. The operator's working theory (a missed
  virtual-media ISO-mount step) is documented explicitly as unconfirmed
  pending Dell's written report. (#47)
- Fixed remaining `UCG-Fiber` → `UCG-Max` device-name references left after
  #31/#33: `README.md`, `docs/00-START-HERE.md`, `docs/01-proxmox-install.md`,
  `docs/03-runbook-day-of.md`. (#32, #46)
- CI `no-personal-identifiers.sh` guard was dead code in CI: it always
  entered "staged" mode, but `git diff --cached` is always empty on a
  fresh `actions/checkout`, so the guard silently passed every run. Now
  detects CI context and diffs against the PR base branch instead. (#27, #30)
- `markdown-lint` CI job's `grep | while read` pipeline lost its `fail=`
  assignment to a subshell — broken-link checks always reported success.
  Fixed with `shopt -s lastpipe` + `set +m`. (#13, #30)
- `scripts/06-pre-migration-backup.sh` staged the live game DB backup and a
  redacted `.env` in `/tmp/` at default (world-readable) permissions. Now
  sets `chmod 700` on the staging directory and `chmod 600` on staged
  files. (#28, #30)
- **NUMA affinity ranges in `scripts/02-provision-vms.sh` were wrong for
  this host's actual CPU topology.** The script assumed socket 0 = logical
  CPUs 0-39 and socket 1 = 40-79 (a contiguous-block layout), but this
  R740's real topology (confirmed via `lscpu` against the live host) is
  interleaved: socket 0 = all even-numbered CPUs (0,2,4,...,78), socket 1 =
  all odd-numbered CPUs (1,3,5,...,79). The prior affinity ranges (`0-19`,
  `20-39`) each mixed roughly half-and-half from both sockets, achieving
  no real single-socket isolation despite the surrounding comments
  claiming otherwise. Corrected to the actual interleaved CPU lists,
  verified against this host directly. Also fixes a vCPU-count/affinity-
  range mismatch on Dev (20 vCPUs vs. a 10-CPU affinity range). (#1)
- Real OCI VPS IP and the personal-domain tunnel subdomains (see this
  repo's own personal-identifier guard denylist for the exact values)
  were committed across 8 files in `prompts/PROMPT-00/03/04`,
  `docs/03-runbook-day-of.md`,
  `scripts/07-wsl-decommission.sh`, `scripts/11-e2e-verify.sh`, and
  `compliance/`. Confirmed with the operator this infrastructure is live
  and active — genericized to placeholders (`OCI_BOT_IP`,
  `CONSOLE_TUNNEL_HOSTNAME`, `ACP_SETUP_TUNNEL_HOSTNAME`,
  `ACP_LANDING_HOSTNAME`), already present in
  `tests/no-personal-identifiers.sh`'s denylist. Also corrected several
  docs that read as though the OCI-to-R740 bot migration had already
  happened — it has not; the bot is a live, currently-running production
  service. (#30)
- `compliance/eight-hats-findings-register.md` M-13: corrected a wrong
  issue cross-reference (cited #15, which is actually a different
  finding — M-1) and removed an incorrect "fix after decommissioning is
  confirmed" precondition. (#30)
- `compliance/evidence/decommissions/2026-08-07-oci-acp-bot-vnic.md`:
  corrected from reading as a completed decommissioning record to an
  explicit unexecuted template. (#30)
- `prompts/PROMPT-00`'s OCI secrets-backup step used `chmod 644`
  (world-readable) on a temp copy of the bot's SQLite DB on the remote
  host — same exposure class as #28's local-staging finding. Fixed to
  `chmod 600` + `shred` after transfer. (#30)

### Added

- `prompts/tabr-tau/01-bot-secrets-rotation.md` and
  `prompts/r740xd/03-bot-deploy-and-tunnel.md` — split out of the former
  flat `PROMPT-03-ACP-BOT-AND-TUNNEL.md`, which mixed dev-machine secret
  rotation with VM-side bot deployment/tunnel config in one file. Part of
  the broader `prompts/tabr-tau/` vs `prompts/r740xd/` restructuring by
  execution machine (#50). (#30, #50)
- `dune update auto enable` and `dune ip-change-restart enable` added to
  `prompts/r740xd/02-game-servers.md` — two real upstream automation
  mechanisms (confirmed against `dune-awakening-selfhost-docker`'s
  `runtime/scripts/update.sh` and `ip-change-restart.sh`) that were never
  wired into any deployment prompt, despite `restart-schedule` and
  `db auto` already being present. `ip-change-restart` is directly
  relevant to this repo's own L-7 finding (single static IPv4, no
  failover). (#30)
- Optional `pre-commit install` step added to
  `prompts/r740xd/03-bot-deploy-and-tunnel.md` for the case where the
  bot repo is edited directly on dune-prod rather than exclusively via
  `git push deploy`. (#30)

- This `CHANGELOG.md` (closes a Requirement 13 gap — every repo in this
  account's workstream must maintain one).
- `scripts/11-e2e-verify.sh` — automated post-deployment verification
  checks across hardware, Proxmox, VMs, Docker, game servers, ACP bot,
  Cloudflare Tunnel, network isolation, WAN ports, security hardening, and
  database integrity. (#30)
- `prompts/tabr-tau/` and `prompts/r740xd/` — the sequenced rebuild/setup
  prompts referenced by the disaster-recovery runbook (#11), split by
  which physical machine each prompt actually runs on (#50). (#30, #50)
- `compliance/eight-hats-findings-register.md` — consolidated eight-hats
  review findings from the 2026-08-07 review session, cross-referenced to
  issues #1, #4-#26. **Known gap in this file, not yet corrected:** its own
  summary table claims 11 CRITICAL findings, but the document contains no
  CRITICAL section at all (only HIGH/MEDIUM/LOW) — this inconsistency
  predates this changelog entry and is flagged here for follow-up, not
  silently carried forward as fact. (#30)
- `compliance/evidence/decommissions/2026-08-07-oci-acp-bot-vnic.md` — OCI
  VPS decommissioning evidence template. (#30)

### Changed

- VM sizing revised (2026-08-07 findings, landed this session): `dune-prod`
  from 80 GB/24 vCPU to 152 GB/40 vCPU, `dune-dev` from 40 GB/10 vCPU to
  50 GB/20 vCPU, based on final production config (2 Sietch @ 40 players
  each, 4 Deep Desert instances, auto-scaling dynamic maps). (#30)
- `scripts/05-init-prod-battlegroup.sh`: Deep Desert config changed from
  the 2-instance `deepdesert dual enable` helper to 4 instances via
  `sietches set-max/set-active DeepDesert_1 4`, since the dual-enable
  helper only supports 2. (#30)

## 2026-08-12

### Added

- Dell ProSupport case writeup for the R740xd's persistent "No bootable
  devices" UEFI boot failure — full troubleshooting timeline, checked into
  the repo so it survives reboots. (#43)

### Fixed

- WAN port forward consolidation: discovered two pre-existing forwards
  (`DA-UDP`, `DA-TCP`) already pointing at the live game server at
  `192.168.68.92`; renamed and added the missing 31983/TCP port rather than
  creating a premature, unused third forward. (#40, #41)

## 2026-08-11 — 2026-08-12

### Added

- Firewall zone-based policies (Prod-Zone, Dev-Zone, Mgmt-Zone) on the
  UCG-Max, verified via the UniFi Integration API. (#39)
- Trunk-port configuration for the R740's data NIC (tagged VLANs 1/20/21/30),
  verified via the legacy internal API with no disruption to the physical
  link. (#38)

### Fixed

- Corrected the primary network-setup walkthrough to reflect the actual
  hardware (UCG-Max, not UCG-Fiber) and the zone-based firewall model
  introduced in UniFi Network 9.0+. (#31, #33)
- Documented that "Trusted-LAN" already exists as the gateway's built-in
  Default network (VLAN 1) — no new VLAN 10 needed. (#36, #37)

### CI

- Granted `pull-requests:read` so `gitleaks-action` can comment on PRs,
  fixing an intermittent 403 on `pull_request` events. (#34, #35)

## Initial commit

- R740 Dune: Awakening Prod/Dev deployment kit: docs (00-04), provisioning
  scripts (01-07), pre-commit/CI security tooling (gitleaks, ggshield,
  trivy, semgrep, shellcheck), and the project-specific
  `tests/no-personal-identifiers.sh` guard.

<!--
NOTE ON MERGE (2026-08-13): PR #30's own changelog draft additionally
claimed an ACP bot migration onto dune-prod, OCI VPS decommissioning,
Cloudflare Access enforcement, and several "Critical finding C-N"
resolutions. None of these are independently verified against this
session's actual state -- qm list on the live Proxmox host shows zero
VMs provisioned, so no bot migration onto a VM that doesn't exist yet
can have occurred. These claims are not carried into this changelog as
fact. If they describe real, separately-completed work, they should be
re-added with their own verification (matching this file's existing
discipline of citing what was actually checked, not just claimed) once
confirmed against real system state.
-->
