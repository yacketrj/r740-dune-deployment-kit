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
│                      2x Sietch (Survival_1, 40 players each),
│                      4x Deep Desert, Overmap, dynamic maps
│                      Socket 0 (40 threads), 152 GB RAM hard alloc
├── VM: dune-dev    — new Funcom token (account #2), fresh battlegroup
│                      1x Sietch, dynamic Deep Desert, Overmap
│                      Socket 1 (half, 20 threads), 50 GB RAM hard alloc
│                      Seeded from a real DB backup/import (see script 06)
└── (ACP Discord bot runs on dune-prod VM alongside the game stack —
      migrated from OCI VPS 2026-08-07 to eliminate $300/month costs)
```

Network: UCG-Max router, 4 VLANs (Trusted / Prod / Dev / Management),
only Prod's game ports are forwarded to the internet. Admin consoles (port
8088) are never exposed to WAN on either VM.

## Hardware Specification

| Component | Detail |
|---|---|
| Server | Dell PowerEdge R740 |
| CPU | 2× Intel Xeon Gold 6248 (20c/40t each, 2.5 GHz base / 3.9 GHz turbo) |
| RAM | 256 GB DDR4 |
| Storage | 2× 1.92TB SATA SSD (RAID1 via PERC H730P + CacheVault) |
| Network | 4× 1GbE RJ45 (quad-port rNDC) |
| Internet | 2.5 Gbps symmetric fiber, single static public IPv4 |
| Router | Ubiquiti UCG-Fiber (10G SFP+, 5 Gbps IDS/IPS) |

## VM Allocation

| VM | vCPU | RAM | Disk | Socket | Notes |
|---|---|---|---|---|---|
| dune-prod | 40 (0-19) | 152 GB | 300 GB | Socket 0 | 2 Sietch (40p/ea), 4 Deep Desert, Overmap, dynamics |
| dune-dev | 20 (20-29) | 50 GB | 300 GB | Socket 1 | 1 Sietch, 1 Deep Desert, Overmap, dynamics |
| _free_ | 20 (30-39) | 54 GB | — | Socket 1 | Proxmox overhead + future expansion |

## Prerequisites Checklist (do these BEFORE 7/30)

- [ ] UCG-Max router arrived, physically installed, basic setup done
- [ ] Proxmox VE install USB prepared (see `01-proxmox-install.md`)
- [ ] 2 new Funcom Self-Host Service Tokens generated (one per account, for
      Prod and Dev respectively) — save both strings in a password manager
- [ ] GitHub OAuth token on the OCI ACP box rotated (separate from this
      project, but do this before 7/30 so it's off your plate)
- [ ] R740 racked, powered, network cabled to the UCG-Max's LAN ports

## Directory Map

```
r740-deployment/
├── docs/
│   ├── 00-START-HERE.md              <- you are here
│   ├── 01-proxmox-install.md         <- hypervisor install (manual, BIOS-level)
│   ├── 02-network-setup.md           <- UCG-Max VLAN/firewall config (manual, UI-based)
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
2. Read `02-network-setup.md`, configure the UCG-Max's VLANs and firewall
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
