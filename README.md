# R740 Dune: Awakening Deployment Kit

Scripts and step-by-step documentation for standing up two independent,
self-hosted **Dune: Awakening** battlegroups (a Production and a Development
environment) on a single piece of dedicated server hardware, using free,
open-source virtualization — migrating off of an ad-hoc gaming-PC/WSL2 setup
onto a properly isolated, VLAN-segmented deployment.

This kit is built around:

- **[Proxmox VE](https://www.proxmox.com/)** — free, open-source Type-1
  hypervisor, used to split one physical server into two fully isolated
  virtual machines (one per battlegroup)
- **[dune-awakening-selfhost-docker](https://github.com/yacketrj/dune-awakening-selfhost-docker)**
  — the Docker-based self-host console/orchestrator for Dune: Awakening
  dedicated servers
- A UniFi-based router/firewall (e.g. Ubiquiti UCG-Max or similar) for
  VLAN segmentation, firewall isolation between environments, and WAN port
  forwarding

## Why This Exists

Running a self-hosted game server directly on a personal gaming PC (or
inside WSL2 on one) works, but it comes with real problems this kit is
designed to solve:

- **No isolation** — a Dev/test environment and a Prod/live environment
  sharing one Docker daemon, one Postgres instance, and one network
  namespace means a mistake in one can affect the other
- **No network segmentation** — a single flat network means a compromised
  admin console (a real, documented risk in the underlying self-host
  project — see `docs/04-post-standup-hardening.md`) has a much larger
  blast radius
- **Competing for resources with daily-driver use** — a gaming PC running a
  public-facing game server 24/7 is not a great place to also game, browse,
  or do other personal computing
- **No clean separation between "things I'm testing" and "things my player
  base depends on"**

This kit's approach: one physical server, two VMs, real VLAN isolation
between them, and a router/firewall configuration that only exposes what
Production actually needs to the public internet.

## Is Proxmox Free?

Yes. Proxmox VE itself — the hypervisor, the web management UI, VM
snapshots, everything used in this kit — is fully open-source (AGPLv3) and
free with no feature restrictions. Proxmox Server Solutions GmbH sells an
**optional** paid support subscription (professional support, a more
conservative update channel); this is not required to use any part of what
this kit sets up.

## What's in This Repo

```
docs/
├── 00-START-HERE.md              Master runbook - read this first
├── 01-proxmox-install.md         Hypervisor install, BIOS tuning, RAID setup
├── 02-network-setup.md           VLANs, firewall rules, port forwards
├── 03-runbook-day-of.md          The exact stand-up-day checklist
└── 04-post-standup-hardening.md  Security checklist before going live

scripts/
├── 01-validate-avx2.sh           Run on the hypervisor - confirms AVX2 passthrough
├── 02-provision-vms.sh           Run on the hypervisor - creates both VM shells
├── 03-vm-guest-bootstrap.sh      Run inside each VM - installs Docker, clones the repo
├── 04-init-dev-battlegroup.sh    Run inside the Dev VM - init + optional data import
├── 05-init-prod-battlegroup.sh   Run inside the Prod VM - clean battlegroup init
├── 06-pre-migration-backup.sh    Run on your OLD server - stages a final backup for transfer
└── 07-wsl-decommission.sh        Run on your OLD server - safe teardown, after burn-in

tests/
└── no-personal-identifiers.sh    Pre-commit/CI guard against leaking real infra details
```

## Quick Start

1. Read `docs/00-START-HERE.md` in full before running anything.
2. Follow `docs/01-proxmox-install.md` to get Proxmox VE installed on your
   server hardware.
3. Follow `docs/02-network-setup.md` to configure your router/firewall.
4. Work through `scripts/01` through `scripts/05` in order, per the
   sequencing in `docs/00-START-HERE.md`.
5. Use `docs/03-runbook-day-of.md` as your literal checklist on stand-up day.
6. Complete every item in `docs/04-post-standup-hardening.md` before
   considering either environment production-ready.

## Important: This Is Written Around One Real Deployment

Every IP address, subnet, and hostname in this kit's docs and scripts is a
**documentation placeholder** (private RFC1918 ranges like
`192.168.20.0/24`) — **adjust them to match your own network** before
running anything. Nothing in this kit was designed to be run unmodified
against a network topology different from what's described in
`docs/02-network-setup.md`.

Hardware/software specifics referenced throughout (CPU model, RAM sizing,
etc.) were derived for one specific server configuration (a dual-socket
Intel Xeon Gold 6248 system). If your hardware differs meaningfully — fewer
cores, different CPU generation, less RAM — revisit the sizing numbers in
`docs/00-START-HERE.md` and `scripts/02-provision-vms.sh` rather than using
them as-is.

## Security

This repo ships with the same class of security tooling used by the
upstream `dune-awakening-selfhost-docker` project: gitleaks, GitGuardian
(ggshield), Trivy, Semgrep, ShellCheck, and pre-commit hooks wiring them all
together — plus a project-specific guard
(`tests/no-personal-identifiers.sh`) that blocks known real infrastructure
identifiers from ever landing in a commit, since this repo is intended to
eventually become a public, genericized community guide.

If you fork or adapt this kit for your own deployment, **update the
denylist in `tests/no-personal-identifiers.sh`** to match your own real
values (or remove them once you've replaced them with placeholders) before
relying on that guard for your own OpSec.

To run the checks locally before committing:

```bash
pip install pre-commit
pre-commit install
pre-commit run --all-files
```

## Status

This kit is actively being used for a real deployment as of August 2026 and
is **not yet genericized** for general community use — it still reflects
one specific setup's naming conventions, sizing decisions, and topology.
The eventual goal is to turn this into a broader "how to self-host Dune:
Awakening Prod/Dev on your own hardware" community guide once the current
deployment is validated in production.

**2026-08-07 update:** the ACP Discord bot was migrated from an OCI VPS to
the dune-prod VM, eliminating a $300/month cloud hosting cost. The bot shares
the VM with the game server stack, calling the console API over localhost.

**Sizing revision (2026-08-07):** VM allocations updated for the final
production configuration — 2 Sietch dimensions (40 players each), 4 Deep
Desert instances, and auto-scaling dynamic maps (dungeons, overlands, story
zones). dune-prod: 40 vCPU / 152 GB RAM (socket 0, all 20 cores). dune-dev:
20 vCPU / 50 GB RAM (socket 1, cores 20-29). Compute headroom: 20 threads,
106 GB RAM remaining for Proxmox host and future expansion.

## License

MIT — see [LICENSE](LICENSE).

## Related Projects

- [dune-awakening-selfhost-docker](https://github.com/yacketrj/dune-awakening-selfhost-docker) —
  the Docker-based self-host console this kit deploys
- [Arrakis Control Panel](https://github.com/yacketrj/Arrakis-Control-Panel) —
  the self-hosted Discord bot for Dune: Awakening servers. As of 2026-08-07,
  the production bot runs on the dune-prod VM (VMID 101) of this very R740 —
  the same VM that hosts the production game server stack. See
  `systemd/acp-bot.service` and `compliance/runbooks/backup-recovery.md` in
  that repo for the R740 deployment configuration. Previously hosted on an
  OCI VPS (`acp-bot-vnic`); migrated to eliminate $300/month cloud costs.
- [dune-ops-observability-addon](https://github.com/yacketrj/dune-ops-observability-addon) —
  a read-only operations/observability addon for the console above
