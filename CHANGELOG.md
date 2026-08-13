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

### Added

- This `CHANGELOG.md` (closes a Requirement 13 gap — every repo in this
  account's workstream must maintain one).

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
