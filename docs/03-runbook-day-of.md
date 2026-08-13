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
- [ ] Repoint the Cloudflare tunnel (`CONSOLE_TUNNEL_HOSTNAME` -- your own console subdomain) at
      `dune-prod`'s console — but see `04-post-standup-hardening.md` first,
      don't just copy the old bare-hostname config forward
- [ ] Update DNS/DDNS records if anything else pointed at the old gaming-PC
      public IP specifically

## Announce

- [ ] Tell your player base the new Prod server is live (you mentioned
      they're already expecting a planned outage — this is the "all clear")
- [ ] **Configure Sietch topology** — `dune sietches set-max Survival_1 2 && dune sietches set-active Survival_1 2` (2 dimensions, 40 players each target)
- [ ] **Configure Deep Desert** — `dune sietches set-max DeepDesert_1 4 && dune sietches set-active DeepDesert_1 4` (4 concurrent instances, 16 GB each = 64 GB allocation)
- [ ] **Configure hub cities** — set SH_Arrakeen and SH_HarkoVillage to always-on for pre-warmed travel (3 GB each)
- [ ] Do NOT decommission the gaming PC yet — see burn-in note below

## ACP Bot Migration (from OCI VPS to R740 dune-prod VM)

**This section describes a FUTURE, not-yet-scheduled migration.** As of
this writing, the ACP Discord bot is a live, currently-running production
service on its existing OCI VPS — it has NOT been migrated, and this
section must not be read as describing something already done or
imminent. Do not act on this section until the migration is explicitly
planned and scheduled separately from the R740 game-server stand-up.
`OCI_BOT_IP` below is a placeholder — substitute your own real value from
your password manager/infra notes when this migration is actually
executed.

**Prerequisite:** the OCI VPS (`acp-bot-vnic` at `OCI_BOT_IP`) is
running the production bot and must not be terminated until migration is
verified.

- [ ] **Stop the OCI bot** — `ssh ubuntu@OCI_BOT_IP && sudo systemctl stop acp-bot.service`
- [ ] **Copy the SQLite database** — `scp ubuntu@OCI_BOT_IP:~/arrakis-control-panel/data/acp.db ~/r740-bot-backup/data/`
- [ ] **Copy the .env file** — `scp ubuntu@OCI_BOT_IP:~/arrakis-control-panel/.env ~/r740-bot-backup/`
- [ ] **Clone the bot repo on dune-prod VM** — `ssh dune@192.168.20.10 && git clone https://github.com/yacketrj/arrakis-control-panel.git ~/arrakis-control-panel`
- [ ] **Restore config** — scp the `.env` and `data/acp.db` from the backup location to the dune-prod VM
- [ ] **Update `.env` on dune-prod** — change `DUNE_CONSOLE_API_URL` to `http://localhost:8088`
- [ ] **Install dependencies** — `ssh dune@192.168.20.10 && cd ~/arrakis-control-panel && npm ci --omit=dev`
- [ ] **Install systemd service** — `sudo cp ~/arrakis-control-panel/systemd/acp-bot.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable acp-bot.service`
- [ ] **Add Cloudflare Tunnel ingress rules** — update `/etc/cloudflared/config.yml` on the dune-prod VM to include `ACP_SETUP_TUNNEL_HOSTNAME` → `localhost:3100` (see `INSTALL.md` in the bot repo). **Coordinate this change carefully**: the same Cloudflare account's tunnel/DDNS infrastructure is shared with other independent services (e.g. the ACP landing page and other sites using the same Cloudflare DDNS setup) — verify you are only adding a new ingress rule for this hostname, not modifying shared tunnel config that other services depend on.
- [ ] **Restart the tunnel** — `sudo systemctl restart cloudflared` (this restarts the ENTIRE tunnel daemon, not just this one ingress rule — confirm current status of every hostname/service sharing this tunnel before restarting, per this project's own Requirement 23 on documenting network ingress points)
- [ ] **Start the bot** — `sudo systemctl start acp-bot.service && sudo systemctl status acp-bot.service`
- [ ] **Smoke test** — run `/dune server health` in Discord; verify setup portal at `https://ACP_SETUP_TUNNEL_HOSTNAME/setup`
- [ ] **Verify live stats** — `curl https://ACP_SETUP_TUNNEL_HOSTNAME/api/live-stats` returns valid JSON
- [ ] **Wait 24 hours** — confirm no Discord alerts, no player complaints, no bot restarts
- [ ] **Terminate OCI instance** — via Oracle Cloud console, after verifying no orphaned block volumes or reserved IPs remain

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
