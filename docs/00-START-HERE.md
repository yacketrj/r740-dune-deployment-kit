# R740 Dune: Awakening Prod/Dev Deployment — Master Runbook

**Target stand-up date:** Thursday, July 30, 2026
**Owner:** (see this repo's own operator — not tracked in this file per
`tests/no-personal-identifiers.sh`)
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
└── (ACP Discord bot: PLANNED to run on dune-prod VM alongside the game
      stack, migrating from its current OCI VPS to eliminate cloud costs
      -- this has NOT happened yet as of this writing. The bot is a live,
      currently-running production service on OCI right now. See
      `prompts/tabr-tau/01-bot-secrets-rotation.md` and
      `prompts/r740xd/03-bot-deploy-and-tunnel.md` for the planned,
      not-yet-executed migration procedure.)
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
| Router | Ubiquiti UCG-Max (5x 2.5GbE RJ45, 1 default WAN, 2.3 Gbps IDS/IPS) |

## VM Allocation

**CPU affinity correction (2026-08-13):** this table previously listed
contiguous logical-CPU ranges (`0-19`, `20-29`, `30-39`) as if socket 0
and socket 1 each occupy a contiguous block of logical CPU IDs. Confirmed
via this exact host's real `lscpu -p=CPU,NODE` output that this R740's
actual layout is **interleaved** — socket 0 = all even-numbered logical
CPUs, socket 1 = all odd-numbered logical CPUs — not two contiguous
blocks. `scripts/02-provision-vms.sh` now detects the real per-socket CPU
list at runtime instead of hardcoding a range; the table below reflects
the corrected, verified assignment.

| VM | vCPU | RAM | Disk | Socket | Notes |
|---|---|---|---|---|---|
| dune-prod | 40 (all of socket 0 — CPUs 0,2,4,...,78) | 152 GB | 300 GB | Socket 0 | 2 Sietch (40p/ea), 4 Deep Desert, Overmap, dynamics |
| dune-dev | 20 (first 20 of socket 1 — CPUs 1,3,5,...,39) | 50 GB | 300 GB | Socket 1 | 1 Sietch, 1 Deep Desert, Overmap, dynamics |
| _free_ | 20 (remaining socket 1 — CPUs 41,43,...,79) | 54 GB | — | Socket 1 | Proxmox overhead + future expansion |

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
│   ├── 04-post-standup-hardening.md  <- security checklist after both VMs are live
│   ├── 05-dell-support-case-boot-failure.md
│   ├── 06-multi-battlegroup-public-exposure.md
│   └── values.env.example            <- copy to a gitignored values.env,
│                                         fill in real values, keep it open
│                                         alongside the prompts below
├── prompts/                          <- step-by-step execution prompts,
│                                         split by WHICH MACHINE runs them
│   ├── tabr-tau/                     <- runs on your dev machine
│   │   ├── 00-prerequisites.md
│   │   ├── 01-bot-secrets-rotation.md
│   │   └── 04-e2e-verification.md
│   └── r740xd/                       <- runs on/against the R740 and its VMs
│       ├── 01-proxmox-and-vms.md
│       ├── 02-game-servers.md
│       └── 03-bot-deploy-and-tunnel.md
└── scripts/
    ├── 01-validate-avx2.sh           <- run ON PROXMOX HOST, disposable test VM
    ├── 02-provision-vms.sh           <- run ON PROXMOX HOST, creates both real VMs
    ├── 03-vm-guest-bootstrap.sh      <- run INSIDE each VM after Ubuntu install
    ├── 04-init-dev-battlegroup.sh    <- run INSIDE dune-dev VM
    ├── 05-init-prod-battlegroup.sh   <- run INSIDE dune-prod VM
    ├── 06-pre-migration-backup.sh    <- run ON THE GAMING PC, night before cutover
    ├── 07-wsl-decommission.sh        <- run ON THE GAMING PC, only after burn-in
    └── 11-e2e-verify.sh              <- run FROM your dev machine, after full deployment
```

The `docs/*.md` files are the narrative walkthrough/reference material;
`prompts/` is the condensed, copy-paste-able execution sequence that
assumes you've already read the corresponding `docs/` chapter. Follow
`prompts/` in order on stand-up day; refer back to `docs/` when a prompt
says "see `docs/0N-...md`" for the full explanation of why a step exists.

## Order of Operations

1. Read `01-proxmox-install.md`, install Proxmox on the R740.
2. Read `02-network-setup.md`, configure the UCG-Max's VLANs and firewall
   rules (do this in parallel with #1 if you have two people, or before/after —
   order between these two doesn't matter, both must be done before VM traffic
   needs to flow).
3. On your dev machine, run through `prompts/tabr-tau/00-prerequisites.md`
   (ISOs, Funcom tokens, `values.env` filled in).
4. Run `scripts/01-validate-avx2.sh` on Proxmox — **do not skip this**. If it
   fails, fix CPU type before proceeding to real VMs. (Also covered as
   Phase 1 of `prompts/r740xd/01-proxmox-and-vms.md`.)
5. Run `scripts/02-provision-vms.sh` on Proxmox to create `dune-prod` and
   `dune-dev` VM shells, then install Ubuntu Server 26.04 LTS in each via the
   Proxmox console (this part is interactive, no script covers OS install).
   (`prompts/r740xd/01-proxmox-and-vms.md` covers this end to end.)
6. Inside each VM, run `scripts/03-vm-guest-bootstrap.sh` to install Docker
   and clone the repo.
7. On the gaming PC, the night before or morning of cutover, run
   `scripts/06-pre-migration-backup.sh` to take the final DB backup and stage
   it for transfer.
8. Inside `dune-dev`, run `scripts/04-init-dev-battlegroup.sh` (imports the
   real backup). Inside `dune-prod`, run `scripts/05-init-prod-battlegroup.sh`
   (clean build, no import). (`prompts/r740xd/02-game-servers.md` covers
   both, plus restart-schedule/db-auto/update-auto/ip-change-restart
   automation setup.)
9. On your dev machine, run `prompts/tabr-tau/01-bot-secrets-rotation.md`
   to rotate the ACP bot's secrets — **only when the bot migration is
   actually being executed**, not as part of the initial game-server
   stand-up (see the bot-migration warning in `docs/03-runbook-day-of.md`).
10. Run `prompts/r740xd/03-bot-deploy-and-tunnel.md` to deploy the bot and
    configure the Cloudflare Tunnel — same timing caveat as step 9.
11. Follow `03-runbook-day-of.md` for the exact cutover sequence (port
    forwards, cloudflared repoint, external reachability test).
12. Follow `04-post-standup-hardening.md` before considering either VM
    "production."
13. Run `prompts/tabr-tau/04-e2e-verification.md` (or
    `scripts/11-e2e-verify.sh` directly) for the full automated go-live
    verification suite.
14. Burn in for at least a few days. Only then run
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
