# R740 Dune: Awakening Deployment Kit

**Correction (2026-09-17): full document-set accuracy review — most of
this repo's `docs/`/`prompts/` describe the ORIGINAL July/August 2026
stand-up plan, and real execution has since diverged from it in several
significant, unreconciled ways.** For the current, actively-maintained
live state (VM sizing, network topology, tunnel ingress, repo names/
locations), always check `Project-Arrakis/meta`'s README (Live Systems
section) first — that document is kept current session-to-session; this
repo's stand-up docs are largely a historical record of the initial
build-out. Known divergences found in this review, none yet reconciled
line-by-line throughout every file below:

- **Repo org/names**: every `yacketrj/*` GitHub link and `~/projects/dune/`,
  `~/projects/acp/`, `~/r740-deployment/`, `~/projects/meta/Arrakis-Project/`
  path in this repo's docs is stale. The real, current locations: this
  repo is `yacketrj/r740-dune-deployment-kit` (not yet itself migrated
  into the `Project-Arrakis` org, unlike most other repos in this
  workstream) cloned at `~/projects/repos/r740-dune-deployment-kit`;
  the game server fork is `Project-Arrakis/dune-awakening-selfhost-docker`
  at `~/projects/repos/dune-awakening-selfhost-docker`; the bot
  (`arrakis-control-panel` throughout this repo's docs) is now
  `Project-Arrakis/mentat` at `~/projects/repos/mentat` (renamed twice:
  `arrakis-control-panel` → `sentinel` → `mentat`); the meta-repo is
  `Project-Arrakis/meta` at `~/projects/meta/Project-Arrakis/`.
- **VM sizing has been revised multiple times since this repo's docs
  were written** (the "40 vCPU/152GB dune-prod, 20 vCPU/50GB dune-dev"
  figures throughout this repo are at least two revisions stale).
  **Current state as of 2026-09-29 (verified live, `Project-Arrakis/meta`#73):**
  `dune-prod` was briefly split into `dune-prod1`/`dune-prod2`
  (2026-09-16/17), then **reverted to a single `dune-prod`** on
  2026-09-28/29 because the planned second restored battlegroup was
  cancelled. It is now VM 101, `192.168.20.10` (Instance-1 default ports),
  **60 vCPU / 192GB / 300GB** across two NUMA nodes (node0 40 vCPU/112GB,
  node1 20 vCPU/80GB); `dune-dev` (VM 102) is **8 vCPU / 26GB**;
  `acp-bot` (VM 103) is 2 vCPU/4GB. This repo's docs still describe the
  original 40 vCPU/152GB, 4-Deep-Desert plan.
- **Map layout.** Live layout (verified 2026-09-29, final for now; will expand as server need grows): **3 Sietches** (`Survival_1` dimensions, always-on: Abbir/partition 1, Alraab/37, Barkan/38) + Overmap always-on, and **3 Deep Desert dimensions** (partitions 8, 36, 40) configured as **on-demand** (Dedicated Scaling, `MinServers=0`, none running while empty). Whether any Deep Desert should instead be always-on is the operator's call and is not configured. Capacity check at the `memory.sh` ceilings (16GB per `Survival_1`/`DeepDesert_1` partition, 3GB Overmap, ~4GB for the two hubs, ~25GB OS and infrastructure): 3+3 is about 128GB of dune-prod's 192GB, leaving roughly 64GB of headroom, about four more 16GB partitions at ceiling. Those are ceilings, not typical use: measured guest use with 3 Sietches + Overmap up and all Deep Deserts idle is about 34GB (each Sietch ~9-10GB).
- **The ACP bot ended up on its own dedicated VM (VMID 103, Services
  VLAN 22)**, not co-located on `dune-prod` as several of this repo's
  earlier-written sections still describe (`prompts/r740xd/03-bot-deploy-and-tunnel.md`
  already carries its own correct 2026-08-17 correction for this;
  `docs/00-START-HERE.md`, `docs/03-runbook-day-of.md`'s main body, and
  this README's own "Sizing revision" note below do not).
- **The actual live battlegroup's identity doesn't match this repo's
  planning docs.** This repo's stand-up plan describes fresh battlegroups
  titled "Tabr Tau" (Prod) / "Tabr Tau - Dev" (Dev), each with a newly
  generated Funcom token. The real, current dune-prod1/dune-prod2
  battlegroup is titled "Chronicles of Kanly" (Sietch "Kadir") — how or
  why this diverged from the "Tabr Tau" plan was not established during
  this review; flagging as a known, unreconciled discrepancy rather than
  guessing.

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

**2026-08-07 update (superseded 2026-08-17, issue #93 — see the top-of-file
correction):** this originally said the ACP bot would share the dune-prod
VM. That plan was reversed before execution — the bot got its own
dedicated VM (VMID 103, Services VLAN 22) instead, for blast-radius
isolation. It was never actually deployed onto dune-prod.

**Sizing revision (2026-08-07, now itself superseded — see the
top-of-file correction):** VM allocations described here (2 Sietch
dimensions at 40 players each, 4 Deep Desert instances, dune-prod at
40 vCPU/152GB, dune-dev at 20 vCPU/50GB) reflected the plan at the time
of writing, not the current live state, which has been revised multiple
times since and now involves two separate Prod VMs
(`Project-Arrakis/meta`#73). Also note: a later, corrected capacity
model established that a Sietch is a `Survival_1` *partition* at 16GB
each (not a lighter, separate allocation) — see
`dune-awakening-selfhost-docker`'s own `runtime/scripts/memory.sh` and
`docs/runtime/MULTI-SERVER-SINGLE-PUBLIC-IP.md` for the real, current
per-map memory model this repo's sizing plans should be re-derived
from, not the "40 players each" framing used when this note was
written.

## License

MIT — see [LICENSE](LICENSE).

## Related Projects

**Correction (2026-09-17):** the links and VM placement below are stale
— see the top-of-file correction for current repo names/locations.

- [dune-awakening-selfhost-docker](https://github.com/Project-Arrakis/dune-awakening-selfhost-docker) —
  the Docker-based self-host console this kit deploys
- [Mentat](https://github.com/Project-Arrakis/mentat) (formerly "Arrakis
  Control Panel", then "Sentinel") — the self-hosted Discord bot for
  Dune: Awakening servers. Runs on its own dedicated VM (VMID 103,
  Services VLAN 22, `192.168.22.10`) — **not** on dune-prod/dune-prod1/
  dune-prod2, despite this README's own now-corrected 2026-08-07 note
  above once saying otherwise. See `systemd/acp-bot.service` and
  `compliance/runbooks/backup-recovery.md` in that repo. Previously
  hosted on an OCI VPS (`acp-bot-vnic`); migrated 2026-08-17 to
  eliminate $300/month cloud costs.
- [dune-ops-observability-addon](https://github.com/Project-Arrakis/dune-ops-observability-addon) —
  a read-only operations/observability addon for the console above
