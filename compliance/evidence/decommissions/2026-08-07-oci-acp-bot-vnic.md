# OCI Decommissioning Evidence — `acp-bot-vnic`

**Date:** 2026-08-07
**Performer:** __________________
**Instance:** `acp-bot-vnic` (129.146.238.118)
**Reason:** Migrated ACP Discord bot to Dell R740 dune-prod VM to eliminate
$300/month cloud hosting cost. Bot now runs alongside game server stack on
same VM, calling console API over localhost.

---

## Connection Reference

SSH access to the OCI instance (now decommissioned):

| Field | Value |
|---|---|
| Host | `acp-bot-oci` (alias) / `129.146.238.118` |
| User | `ubuntu` |
| SSH key | `~/.ssh/ssh-key-2026-07-18.key` (RSA 2048-bit) |
| Key fingerprint | `SHA256:TQtdpVJgSfCNAWmwks80ggVN4E1Z02ACow0M6Pi83A0` |
| SSH config | `~/.ssh/config` — \`Host 129.146.238.118 acp-bot-oci\` block |
| Key created | 2026-07-18, specifically for OCI provisioning |

This key was used solely for the OCI `acp-bot-vnic` instance and is not
reused for any other system. The default `id_ed25519` key is used for all
other hosts (GitHub, R740 VMs, etc.).

---

## Pre-Decommission Verification

### 1. Bot Migration Confirmed
- [ ] Bot running on dune-prod VM (`ssh dune@192.168.20.10 "systemctl is-active acp-bot.service"`)
- [ ] Bot responding to Discord slash commands (`/dune server health`)
- [ ] Setup portal accessible (`https://acp-setup.darkdante.org/setup`)
- [ ] Live stats endpoint responding (`curl -s https://acp-setup.darkdante.org/api/live-stats | jq .players_online`)
- [ ] 24-hour burn-in completed with zero incidents

### 2. Data Migration Verified
- [ ] SQLite database (`acp.db`) checksum matches between OCI source and R740 copy
  - Source SHA256: `________________________________`
  - Dest SHA256:  `________________________________`
- [ ] `.env` file transferred, `DUNE_CONSOLE_API_URL` updated to `http://localhost:8088`
- [ ] Secrets backup copies shredded (`shred -u ~/r740-bot-backup/secrets/*`)

### 3. Credentials Rotated Post-Migration
- [ ] Discord bot token rotated
- [ ] Discord OAuth client secret rotated (if multi-tenant)
- [ ] `ACP_SECRETS_KEY` generated (if multi-tenant, had been unset)
- [ ] `DUNE_DISCORD_ADAPTER_TOKEN` rotated (optional, localhost-only now)

---

## OCI Resource Termination

### 4. Compute Instance
- [ ] Instance `acp-bot-vnic` terminated
- [ ] Console screenshot or API output attached
  - Attach: `oci-termination-XXXXXXXX.png`

### 5. Block Volumes
- [ ] Boot volume destroyed (NOT just detached — must be explicitly deleted)
- [ ] All attached block volumes destroyed
- [ ] All unattached block volumes destroyed
- [ ] Verify: `Block Storage → Block Volumes → (empty list)`

### 6. Boot Volumes
- [ ] Boot volume for `acp-bot-vnic` destroyed
- [ ] Verify: `Block Storage → Boot Volumes → no volumes referencing acp-bot-vnic`

### 7. Reserved Public IPs
- [ ] Reserved IP `129.146.238.118` released
- [ ] Verify: `Networking → Reserved Public IPs → (empty or no 129.146.238.118)`

### 8. Snapshots
- [ ] All block volume snapshots deleted
- [ ] All boot volume snapshots deleted
- [ ] Verify: `Block Storage → Block Volume Snapshots → (empty)`
- [ ] Verify: `Block Storage → Boot Volume Snapshots → (empty)`

### 9. API Keys
- [ ] Any OCI API signing keys that existed on the instance rotated
- [ ] SSH key `ssh-key-2026-07-18.key` revoked from any OCI authorized_keys
- [ ] Verify: `Identity → Users → API Keys → (review and rotate as needed)`

---

## Post-Termination Verification

### 10. Cost Confirmation
- [ ] OCI Cost Analysis shows zero projected charges for current month
- [ ] No running resources visible in OCI Console → Compute → Instances
- [ ] Billing → Cost Analysis → filtered to current month → $0.00 projected

### 11. SSH Key Cleanup
- [ ] `~/.ssh/ssh-key-2026-07-18.key` archived (kept for audit, not active use)
  - Path: `~/archive/oci-decommission/ssh-key-2026-07-18.key`
- [ ] SSH config entries for `acp-bot-oci` and `129.146.238.118` removed from `~/.ssh/config`

---

## Sign-Off

| Role | Name | Date | Signature |
|---|---|---|---|
| Performer | | 2026-08-07 | |
| Reviewer | | 2026-08-__ | |

---

## Attachments

- [ ] Screenshot: OCI Console showing zero compute instances
- [ ] Screenshot: OCI Console showing zero block volumes
- [ ] Screenshot: OCI Console showing zero reserved IPs
- [ ] Screenshot: OCI Cost Analysis showing $0.00 projected
- [ ] Log: Bot startup on dune-prod VM (`journalctl -u acp-bot -n 50`)
- [ ] Log: Smoke test results (Discord `/dune server health` response)
