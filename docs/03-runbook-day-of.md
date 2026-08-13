# July 30 Stand-Up Day — Exact Sequence

Print this or keep it open on a second device. Check off each step.

## Morning

- [ ] Confirm UCG-Max VLANs/firewall/port-forwards from
      `02-network-setup.md` are all in place and verified (should already
      be done by now if you followed the pre-work checklist)
- [ ] Confirm Proxmox VE is installed and reachable at its management IP
- [ ] Run `scripts/01-validate-avx2.sh` on the Proxmox host — **must pass**
      before continuing

## Provisioning

- [ ] Run `scripts/02-provision-vms.sh` on the Proxmox host
- [ ] Install Ubuntu Server 24.04 LTS on `dune-prod` (static IP on VLAN 20,
      OpenSSH enabled)
- [ ] Install Ubuntu Server 24.04 LTS on `dune-dev` (static IP on VLAN 21,
      OpenSSH enabled)
- [ ] SSH into `dune-prod`, run `scripts/03-vm-guest-bootstrap.sh`
- [ ] SSH into `dune-dev`, run `scripts/03-vm-guest-bootstrap.sh`

## Backup Transfer

- [ ] Confirm `scripts/06-pre-migration-backup.sh` was already run on the
      gaming PC the night before (7/29) — if not, run it now, but note this
      means less buffer time today
- [ ] `scp` the staged backup file + `.sha256` from the gaming PC to
      `dune-dev`'s `runtime/backups/db/` directory
- [ ] On `dune-dev`, verify the checksum matches before importing:
      `sha256sum <file> ` vs the transferred `.sha256`

## Battlegroup Initialization

- [ ] Have Prod's new Funcom token (account #1) and Dev's new Funcom token
      (account #2) ready — from your password manager, not memory
- [ ] On `dune-dev`: run `scripts/04-init-dev-battlegroup.sh`
      - Choose hosting mode: **Local/LAN** (per network design, Dev has no
        public port forwards)
      - Import the transferred backup when prompted
      - Confirm `dune sietches validate` and `dune status` both come back
        clean
- [ ] On `dune-prod`: run `scripts/05-init-prod-battlegroup.sh`
      - Choose hosting mode: **Public**
      - Configure 2x Sietch dimensions
      - Decide on Deep Desert dual-instance now vs. validate on Dev first
        (script will ask)
      - Confirm `dune status` and `dune ready` both come back clean

## Cutover

- [ ] On `dune-prod`, run `dune ports` — resolve any WARN lines about
      advertised-vs-bound IP mismatches before going further (this is the
      same class of warning seen on the old gaming-PC setup — don't let it
      slide through unexamined here)
- [ ] Confirm UCG-Max port forwards (7777-7810 UDP, 31982/31983 TCP) point
      at `dune-prod`'s actual static IP
- [ ] From OUTSIDE your LAN (phone on cellular data, or ask a friend), test
      actual reachability — don't rely solely on internal `dune ports`/`dune
      doctor` checks
- [ ] Repoint the Cloudflare tunnel (`console.darkdante.org`) at
      `dune-prod`'s console — but see `04-post-standup-hardening.md` first,
      don't just copy the old bare-hostname config forward
- [ ] Update DNS/DDNS records if anything else pointed at the old gaming-PC
      public IP specifically

## Announce

- [ ] Tell your player base the new Prod server is live (you mentioned
      they're already expecting a planned outage — this is the "all clear")
- [ ] Do NOT decommission the gaming PC yet — see burn-in note below

## Burn-In (days, not hours)

- [ ] Watch both VMs for at least a few days of real usage before touching
      `scripts/07-wsl-decommission.sh`
- [ ] Specifically watch for: memory pressure on Prod under real concurrent
      Sietch+DeepDesert load, any lag/stutter reports correlating with
      CPU-bound events (sandstorms, dense combat — per the single-thread
      clock-speed concern discussed throughout this project), and general
      stability of the dual-DeepDesert config if you enabled it
- [ ] Only after burn-in looks clean: run `scripts/07-wsl-decommission.sh`
      on the gaming PC
