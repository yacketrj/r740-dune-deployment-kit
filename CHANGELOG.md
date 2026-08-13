# Changelog

This repo has no independent version/release train yet (see the "Internal
tooling" category in this account's Unified Release Configuration docs —
not yet tagged, starts at `v0.1.0` on first real tagged release). Until
then, entries here are grouped by date and reference the merged PR that
introduced them, in Keep a Changelog style, newest first.

## Unreleased

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

### Added

- This `CHANGELOG.md` (closes a Requirement 13 gap — every repo in this
  account's workstream must maintain one).
- `scripts/11-e2e-verify.sh` — automated post-deployment verification
  checks across hardware, Proxmox, VMs, Docker, game servers, ACP bot,
  Cloudflare Tunnel, network isolation, WAN ports, security hardening, and
  database integrity. (#30)
- `prompts/PROMPT-00` through `PROMPT-04` — the sequenced rebuild/setup
  prompts referenced by the disaster-recovery runbook (#11). (#30)
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

