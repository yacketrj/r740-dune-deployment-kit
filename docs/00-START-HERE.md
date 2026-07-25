# R740 Dune: Awakening Prod/Dev Deployment — Master Runbook

**Target stand-up date:** Thursday, July 30, 2026
**Owner:** darkdante
**Scope:** Migrate off gaming PC (WSL2) onto dedicated Dell R740, stand up two
independent battlegroups (Prod: "Tabr Tau", Dev: "Tabr Tau - Dev"), decommission
WSL2 stack afterward.

## What You're Building

```
Dell R740 (Proxmox VE hypervisor)
├── VM: dune-prod   — new Funcom token (account #1), fresh battlegroup
│                      2x Sietch (Survival_1), 2x Deep Desert, Overmap
│                      Socket 0, ~80GB RAM hard alloc, 24-28 vCPU
├── VM: dune-dev    — new Funcom token (account #2), fresh battlegroup
│                      1x Sietch, dynamic Deep Desert, Overmap
│                      Socket 1, ~40GB RAM hard alloc, 8-10 vCPU
│                      Seeded from a real DB backup/import (see script 06)
└── (ACP Discord bot stays on the OCI VPS — out of scope, do not touch)
```

Network: UCG-Fiber router, 4 VLANs (Trusted / Prod / Dev / Management),
only Prod's game ports are forwarded to the internet. Admin consoles (port
8088) are never exposed to WAN on either VM.

## Prerequisites Checklist (do these BEFORE 7/30)

- [ ] UCG-Fiber router arrived, physically installed, basic setup done
- [ ] Proxmox VE install USB prepared (see `01-proxmox-install.md`)
- [ ] 2 new Funcom Self-Host Service Tokens generated (one per account, for
      Prod and Dev respectively) — save both strings in a password manager
- [ ] GitHub OAuth token on the OCI ACP box rotated (separate from this
      project, but do this before 7/30 so it's off your plate)
- [ ] R740 racked, powered, network cabled to the UCG-Fiber's LAN ports

## Directory Map

```
r740-deployment/
├── docs/
│   ├── 00-START-HERE.md              <- you are here
│   ├── 01-proxmox-install.md         <- hypervisor install (manual, BIOS-level)
│   ├── 02-network-setup.md           <- UCG-Fiber VLAN/firewall config (manual, UI-based)
│   ├── 03-runbook-day-of.md          <- the actual 7/30 sequence, step by step
│   └── 04-post-standup-hardening.md  <- security checklist after both VMs are live
└── scripts/
    ├── 01-validate-avx2.sh           <- run ON PROXMOX HOST, disposable test VM
    ├── 02-provision-vms.sh           <- run ON PROXMOX HOST, creates both real VMs
    ├── 03-vm-guest-bootstrap.sh      <- run INSIDE each VM after Ubuntu install
    ├── 04-init-dev-battlegroup.sh    <- run INSIDE dune-dev VM
    ├── 05-init-prod-battlegroup.sh   <- run INSIDE dune-prod VM
    ├── 06-pre-migration-backup.sh    <- run ON THE GAMING PC, night before cutover
    └── 07-wsl-decommission.sh        <- run ON THE GAMING PC, only after burn-in
```

## Order of Operations

1. Read `01-proxmox-install.md`, install Proxmox on the R740.
2. Read `02-network-setup.md`, configure the UCG-Fiber's VLANs and firewall
   rules (do this in parallel with #1 if you have two people, or before/after —
   order between these two doesn't matter, both must be done before VM traffic
   needs to flow).
3. Run `scripts/01-validate-avx2.sh` on Proxmox — **do not skip this**. If it
   fails, fix CPU type before proceeding to real VMs.
4. Run `scripts/02-provision-vms.sh` on Proxmox to create `dune-prod` and
   `dune-dev` VM shells, then install Ubuntu Server 24.04 LTS in each via the
   Proxmox console (this part is interactive, no script covers OS install).
5. Inside each VM, run `scripts/03-vm-guest-bootstrap.sh` to install Docker
   and clone the repo.
6. On the gaming PC, the night before or morning of cutover, run
   `scripts/06-pre-migration-backup.sh` to take the final DB backup and stage
   it for transfer.
7. Inside `dune-dev`, run `scripts/04-init-dev-battlegroup.sh` (imports the
   real backup).
8. Inside `dune-prod`, run `scripts/05-init-prod-battlegroup.sh` (clean build,
   no import).
9. Follow `03-runbook-day-of.md` for the exact cutover sequence (port
   forwards, cloudflared repoint, external reachability test).
10. Follow `04-post-standup-hardening.md` before considering either VM
    "production."
11. Burn in for at least a few days. Only then run
    `scripts/07-wsl-decommission.sh` on the gaming PC.

## Rollback Points

- Today's backup (`dune-db-overmap_and_survival_1-20260724-225614.backup`,
  sha256 `09f67b4a...`) is staged at `/tmp/opencode/dune-migration/` on the
  gaming PC as a reference/rollback point — separate from whatever fresh
  backup script 06 takes on 7/29.
- The gaming PC's WSL2 stack is NOT touched by any script until you
  explicitly run `07-wsl-decommission.sh` — everything before that is purely
  additive on the R740 side. You can abort at any point before step 11 with
  zero impact on the currently-live Dev server.
