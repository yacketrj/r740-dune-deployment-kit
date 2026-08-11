# Changelog

All notable changes to the R740 Dune: Awakening Deployment Kit will be
documented in this file. Format based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- `scripts/11-e2e-verify.sh` — 70+ automated verification checks across 11 categories
  (hardware, Proxmox, VMs, Docker, game servers, ACP bot, Cloudflare Tunnel,
  network isolation, WAN ports, security hardening, database integrity)
- `prompts/PROMPT-00-PREREQUISITES.md` — pre-deployment checklist for dev machine
- `prompts/PROMPT-01-PROXMOX-AND-VMS.md` — Proxmox install + VM provisioning prompt
- `prompts/PROMPT-02-GAME-SERVERS.md` — game server initialization prompt (with 4-DD validation gate)
- `prompts/PROMPT-03-ACP-BOT-AND-TUNNEL.md` — ACP bot deploy + Cloudflare Tunnel prompt
- `prompts/PROMPT-04-E2E-VERIFICATION.md` — go-live and verification prompt
- `compliance/evidence/decommissions/2026-08-07-oci-acp-bot-vnic.md` — OCI decommissioning evidence template
- `compliance/eight-hats-findings-register.md` — consolidated 8-hats review with 57 findings

### Changed
- **VM sizing revised** (2026-08-07): dune-prod from 80 GB/24 vCPU to 152 GB/40 vCPU,
  dune-dev from 40 GB/10 vCPU to 50 GB/20 vCPU. Based on final production config:
  2 Sietch (40 players each), 4 Deep Desert instances, auto-scaling dynamic maps.
- **ACP bot migration**: bot now runs on dune-prod VM alongside game stack (from OCI VPS,
  decommissioned 2026-08-07 to eliminate $300/month cloud costs)
- **Deep Desert config**: changed from dual-instance (`deepdesert dual enable`) to
  4-instance via `sietches set-max DeepDesert_1 4`
- **VLAN/bridge topology**: corrected from mismatched access-port cabling to trunk-port
  with `bridge-vlan-aware yes` (Critical finding C-1 from 8-hats review)
- **DB password rotation**: hardening doc procedure fixed to use console API's
  `changeDunePassword` endpoint instead of broken `.env` append (Critical finding C-3)
- **Cloudflare Access**: changed from "recommended" to mandatory with verification step
  (Critical finding C-8)
- **ACP SQLite backup**: documented systemd timer creation for daily backups
  (Critical finding C-4)
- Bot deploy remote updated from OCI IP to R740 dune-prod VM (192.168.20.10)
- `docs/02-network-setup.md`: Proxmox bridge config added, access-port→trunk topology
- `docs/03-runbook-day-of.md`: added Sietch + DD + hub city config steps, bot migration checklist
- `docs/04-post-standup-hardening.md`: DB password rotation procedure corrected

### Security
- Eight-hats architectural review completed with 57 findings (11 CRITICAL, 13 HIGH,
  18 MEDIUM, 15 LOW). Full register at `compliance/eight-hats-findings-register.md`.
- Discord bot token rotation procedure documented (Cloud finding CLOUD-01)
- OAuth client secret rotation procedure documented (Cloud finding CLOUD-03)
- `ACP_SECRETS_KEY` generation procedure documented (Cloud finding CLOUD-08)
- Cloudflare API token scope reduction recommended (Cloud finding CLOUD-04)
- 11-e2e-verify.sh includes security hardening verification checks

### Infrastructure
- OCI VPS `acp-bot-vnic` (129.146.238.118) decommissioned 2026-08-07
- ACP bot now self-hosted on Dell R740 dune-prod VM
- All bot-to-console traffic over localhost (zero WAN exposure for adapter token)
