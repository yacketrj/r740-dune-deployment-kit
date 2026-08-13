# OCI Decommissioning Evidence — `acp-bot-vnic` (TEMPLATE — NOT YET EXECUTED)

**Status as of 2026-08-13: This is a blank template for a FUTURE migration
that has NOT happened.** The all-blank Sign-Off section below and the
"2026-08-07" date in the filename reflect when this template was drafted
during the eight-hats review, not when the migration was performed — no
migration has occurred. The ACP Discord bot is a live, currently-running
production service on its existing OCI VPS as of this writing. Do not treat
any checklist item below as completed, and do not act on this document
until the migration is explicitly planned and scheduled.

**Instance:** `acp-bot-vnic` (`OCI_BOT_IP` — placeholder, substitute your
own real value from your password manager/infra notes when this migration
is actually executed; see `tests/no-personal-identifiers.sh` for why real
values aren't checked into this repo directly)
**Reason (planned):** Migrate ACP Discord bot to Dell R740 dune-prod VM to
eliminate cloud hosting cost. Bot would run alongside the game server stack
on the same VM, calling the console API over localhost.

---

## Pre-Decommission Verification

### 1. Bot Migration Confirmed
- [ ] Bot running on dune-prod VM (`ssh dune@192.168.20.10 "systemctl is-active acp-bot.service"`)
- [ ] Bot responding to Discord slash commands (`/dune server health`)
- [ ] Setup portal accessible (`https://ACP_SETUP_TUNNEL_HOSTNAME/setup`)
- [ ] Live stats endpoint responding (`curl -s https://ACP_SETUP_TUNNEL_HOSTNAME/api/live-stats | jq .players_online`)
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
- [ ] Reserved IP `OCI_BOT_IP` released
- [ ] Verify: `Networking → Reserved Public IPs → (empty or no OCI_BOT_IP)`

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
- [ ] SSH config entries for `acp-bot-oci` and `OCI_BOT_IP` removed from `~/.ssh/config`

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
