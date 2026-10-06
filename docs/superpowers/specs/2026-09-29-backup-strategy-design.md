# R740 Backup Strategy — Design (v2, post Layer 1 audit)

**Status:** v2, 2026-09-30. v1 was operator-approved 2026-09-29; the Layer 1 audit (`docs/superpowers/audits/2026-09-30-backup-layer1-audit.md`, themes T1–T12 = issues #121–#132) changed it substantially. **Operator accepted all recommended defaults for D1–D7 on 2026-09-30** ("go with the recommendations"); D3, D5 and D7 still need operator-supplied inputs (a dedicated Microsoft account, an external heartbeat account, and the desktop's network details) before the matching rollout steps. Implementation on the host is gated on the rollout gates in section 6.
**Scope:** the R740 Proxmox host and guests: `dune-prod` (VM 101), `dune-dev` (VM 102), `acp-bot` (VM 103), `theparlor` (CT 104), plus the Kadir game database and the secrets that tie the battlegroup to its VM.
**Tracking:** `Project-Arrakis/meta`#73 (context), issue #119 (this design), issues #121–#132 (audit themes).

## 1. Problem

Verified 2026-09-29/30: the host has one rotational 1.7TB disk behind a PERC H730P (RAID level unknown) shared by host root and all guests in one LVM thin pool; there are zero Proxmox backup jobs, no NAS/PBS/second disk; the daily game DB backup (04:30) lands on dune-prod's own disk; `runtime/secrets` ties the battlegroup identity to the VM; the QEMU guest agent is enabled in each VM config but not running; dune-prod is the only copy of Kadir. On 2026-09-29 an agent's test helper overwrote system binaries on this host and the game was offline about 2h16m (INC-2026-09-29), which is why this design also has to be **safe to implement and operate on a live hypervisor** (Requirement 30).

## 2. Goals and non-goals

**Goals**
- Survive loss of the disk, controller or chassis, and recover the game server with its identity.
- Automatic, scheduled, encrypted before leaving the host, with alerts that cannot fail silently.
- Restores that are **proven usable**, not merely decryptable (Requirement 25).
- Never harm the live game server while backing it up.

**Non-goals**
- No Proxmox Backup Server and no WAL archiving/PITR in this iteration (revisit if D2 or image sizes demand it).
- No high availability or live replication.
- No selective erasure of individual players from historical backups (see 4.9).

## 3. Decisions

### Approved (v1)
Tiered design; OneDrive via `rclone` crypt (never the OneDrive desktop client on Proxmox); second copy on the operator's always-on desktop over SMB; `age`; systemd timers on the host; Discord alerts.

### Operator decisions — ACCEPTED 2026-09-30 (recommended defaults)
| ID | Decision | Recommended default |
|---|---|---|
| D1 | Key custody and restore-drill procedure | Host holds only the age **public** key. Private key and rclone crypt password/salt live in the password manager plus a second escrow. Real-key restore drills are **assisted monthly**: the operator makes the key available for the drill, it is removed afterwards. |
| D2 | Database RPO | **6 hours**: a small DB-only tier every 6h (newest official dump pair only), plus the daily set. 24h is acceptable only as a signed acceptance. |
| D3 | Backup account and residual risk | A **dedicated Microsoft account** for backups (MFA, recovery codes) and a written acceptance that a fully root-compromised host can delete what its credentials reach. |
| D4 | Weekly maintenance window | Sunday **01:00–04:15**, hard stop at 04:15 (before the 04:30 dump and 05:00 restart). |
| D5 | External dead-man's-switch | A free external heartbeat service pinged on every successful run; silence alarms. |
| D6 | Player-data retention and deletion stance | Keep 30 daily + 12 monthly; erasure requests are honoured by the backup cycle expiring, deletions are re-applied after any restore, stated in the privacy notice; use the dedicated account (not a personal one). |
| D7 | Desktop network details | Operator supplies the desktop's IP, VLAN and wired/wifi status; wifi is rejected for the weekly tier unless explicitly accepted. |

## 4. Design

### 4.1 Tiers, schedule and what is archived

| Tier | What | When | Destination | RPO |
|---|---|---|---|---|
| DB tier (if D2 = 6h) | newest **official** `.backup` + `.backup.yaml` pair only | every 6h, offset after the dump | OneDrive, desktop | 6h |
| Daily set | official `.backup` + `.backup.yaml` pairs (authoritative file named in a manifest), `runtime/secrets`, `.env`, host config | daily 05:15 (after the 04:30 dump completes) | OneDrive, desktop | 24h |
| Weekly images | full VM/CT images: 101, 102, 103, CT 104 | Sunday window (D4) | desktop | 7 days |

- **Exclude** the 15-minute `market-bot-seed` dumps (a different artifact class) except the newest one; never let them be mistaken for the restore point.
- **Exclude** `/root/.config` (rclone config, keys) from the host-config archive.
- **Pull path (T7):** a dedicated backup SSH key, root-only on the host, restricted on dune-prod with `restrict,command="<fixed tar of official dumps + secrets + .env>"`; pinned host key in a private known_hosts. The job runs only after the newest official dump is newer than the scheduled dump time and above a size floor (a completion gate, not a fixed clock time). The host-to-`192.168.20.10:22` firewall path is documented (Requirement 23).
- **Flow:** pull → pre-upload checks (`tar -tf`, `pg_restore -l` on every dump, non-zero size, sha256 manifest) → tar → `age -r <public recipient>` → write to SMB (`.partial` then rename) → upload to OneDrive → verify transfer bit-exactly (`rclone check`/comparison against the encrypted file) → record manifest → prune.

### 4.2 Consistency (T5, T6)
- **VM images are disaster-recovery images of the whole server, never the primary database source.** The primary DB restore source is a logical `.backup`.
- Immediately before each weekly image, the job runs `dune db backup` on dune-prod (via the restricted key) so the image contains a known-good dump.
- The job pings the guest agent before each image. If it is not running the run **alerts** that the image is crash-consistent; it does not silently proceed.
- **Guest-agent rollout order:** dune-dev first (test freeze/thaw), then acp-bot, then dune-prod last, in a low-population window, with a freeze timeout and a documented no-freeze fallback.

### 4.3 Keys, credentials and rotation (T1, T2, T9, T12)
- **Encryption is public-key only on the host.** The age private key is never on the host during unattended runs. Escrow is **proven**, not assumed: `backup-verify-key` has the operator supply the key from its second location and decrypts a canary; it runs at setup and quarterly, and its result is logged.
- **Credential inventory** (owner, scope, expiry, rotation cadence, revocation), Requirement 27:

| Credential | Where | Scope | Rotation |
|---|---|---|---|
| age private key | password manager + second escrow (not the host) | decrypts all backups | on suspected exposure; new recipient added, old key kept for old archives, re-encrypt policy documented |
| rclone crypt password/salt | password manager (and host `rclone.conf`) | names/content layer | with the token if exposed |
| OneDrive OAuth token | `/root/.config/rclone/rclone.conf`, mode 0600 | dedicated account (D3) | re-auth at least yearly and after any host compromise; daily probe |
| SMB credential | root-only file | dedicated desktop backup account, backup share only | yearly |
| backup SSH key | root-only file | restricted command on dune-prod | yearly |
| Discord webhook | root-only file | alerts | yearly |

- Migrating the host means **rotating** these, not copying them.
- Secrets are never in argv, logs or alerts (Requirement 24); permission checks (0700 dirs, 0600 files) are part of the job pre-flight.
- Tools are installed from distro packages or pinned, checksummed releases. VMIDs are validated (`^[0-9]+$`), names are allow-listed, paths use `--`, and no script deletes outside its staging root.

### 4.4 Retention and sizing
OneDrive: 30 daily + 12 monthly of the small set. Desktop: 3 weekly copies each of 101, 103, CT 104; 1 of 102. Sizes are estimates (about 138GB written per 300GB guest disk today); the first measured run sets real retention. A retention test guarantees prune never removes the last verified-good set.

### 4.5 Protecting the live game while backing up (T3)
- Weekly images stream `vzdump --stdout --compress zstd | age | SMB`: **no plaintext image lands on disk and there is no second write.**
- `ionice -c3`, `nice`, vzdump `--bwlimit`, rclone `--bwlimit` and `--transfers 2`.
- Fixed window (D4) with a hard `timeout` before 04:15; a run still going at 04:15 is aborted and alerted.
- Pre-flight: thin-pool free space against a hard-fail threshold (snapshot copy-on-write growth), SMB reachable.
- The first prod image is run with the operator present, watching game latency, before any schedule is enabled.

### 4.6 Network (T8)
- Record the desktop IP, VLAN and wired/wifi (D7). If inter-VLAN, one UCG-Max rule: host `192.168.68.127` to the desktop on TCP 445 only; the desktop never initiates connections to the host.
- SMB 3.1.1 with signing/seal; **systemd automount with a timeout and `soft`** so an asleep desktop cannot hang the host; dedicated desktop account; TCP 445 pre-flight with retry and alert.
- Egress FQDNs verified before rollout: `login.microsoftonline.com`, `graph.microsoft.com`, `onedrive.live.com`, `*.sharepoint.com`, `discord.com`.
- Scratch restore VMs use a **no-uplink bridge** (a vmbr with no NIC, no VLAN), regenerated MACs, and can never reach Funcom, Discord or a production VLAN.

### 4.7 Monitoring and alerting (T4, T10)
- **The alarm verifies artifacts**, not a local touch file: newest remote object via listing, newest SMB file, size floor and mtime. A daily token probe checks OneDrive independently.
- **External dead-man's-switch (D5):** every successful run pings an external service; silence alarms even if the host, timer, or Discord webhook is dead. A failing webhook is detected and returns a distinct exit code.
- **Alert format:** job, failed stage (pull / verify / encrypt / SMB / upload / verify-transfer), redacted error, the exact re-run command, runbook link. One quiet daily summary line; loud (ping) only on failure, staleness, an overdue restore drill, or token pre-expiry.
- Every run writes a tamper-evident manifest and audit line (what, when, hashes, sizes), shipped off-host.
- **P1** means the operator is paged (Discord ping and the dead-man's-switch) and the failing tier is treated as no backup.

### 4.8 Restore and drills (T4, T5, T10)
- **Runbook per scenario** (database only; one VM; whole host), linear and copy-pasteable, usable from a bare Linux box, with an offline copy (printed page plus password-manager entry). Identity ordering is mandatory: restore secrets and `.env`, then the database with `--adopt-backup-battlegroup`, then start. Restoring with `--keep-current-battlegroup` hides characters and must never be used for DR.
- **Automated monthly pipeline test** (no real key): a throwaway test key exercises encrypt → transfer → decrypt → `tar -tf` on synthetic data and fails on truncation, tampering, wrong key and partial upload.
- **Assisted monthly real-key drill (D1):**
  - *Database:* restore the newest daily `.backup` into a **throwaway Postgres container of the same image tag as prod** (not into dune-dev's database), then assert table counts and row counts above a floor on key tables. Secrets are not restored into dune-dev.
  - *VM:* restore an image to a scratch VMID on the no-uplink bridge, boot it, and run in-guest checks (Postgres up, `dune status`). Rotate across 101, 102, 103 and CT 104; prod's image is drilled at least quarterly.
  - Every drill appends a record (date, backup id, hashes, duration, result, who) to a named evidence log; an overdue drill alarms after 35 days. A failed drill is a P1.

### 4.9 Data protection and governance (T9)
- **Data inventory:** the daily set and images contain player personal data (Steam IDs, Discord IDs, chat/character data) and server secrets.
- Retention basis: operational recovery; 30 daily + 12 monthly; the backup cycle expiring is the erasure mechanism, deletions are re-applied after any restore, and this is stated in the privacy notice (D6). Data residency of the OneDrive tenant is recorded.
- A **dedicated** account is used because the data is third-party player data (D3).
- Named owner and alternate; OneDrive account recovery documented (bus factor).
- Deliverables: findings register and STRIDE table (done), CHANGELOG, README Live Systems update (backups now exist), Requirement 23 ingress documentation (SMB, OneDrive, SSH), incident cross-reference INC-2026-09-29, recorded RTO/RPO sign-off.

### 4.10 Implementation safety (Requirement 30, T11, T12)
- All tests run through the sandbox runner (`/usr` and `/etc` read-only); no agent runs code on the hypervisor outside it.
- The library refuses to run under bats unless its state dir is under the test temp dir. CI fails, not skips, the sandbox test.
- Tests use real `age`/`tar` and, in CI, real `rclone` against a local remote. Real vzdump/qm/rclone/SMB outputs are captured as fixtures in the rollout's contract step before the stubs are trusted.
- Negative tests are mandatory: truncated/tampered archive, wrong key, partial upload, full disk mid-copy, leftover dumps, overlapping timers, failing webhook.

## 5. Failure modes and accepted residual risk

| Risk | Handling |
|---|---|
| Desktop off/asleep | automount timeout + retry + alert; OneDrive independent |
| Host root compromise deletes remote copies | dedicated account, version history/recycle bin, desktop snapshots; **residual risk accepted in writing (D3)** |
| Lost private key | escrow proven quarterly; loss of all copies is unrecoverable and stated |
| OneDrive token dies | daily probe, pre-expiry warning, external dead-man's-switch |
| Weekly image slows the game | window, ionice, bwlimit, hard stop, thin-pool pre-flight, first run watched |
| Crash-consistent image | never the DB source; dump taken immediately before; agent-ping alert |
| Backup fills the pool/staging | streaming removes staging; thin-pool hard-fail threshold |
| Up to RPO of game progression lost | RPO chosen and signed (D2) |

## 6. Rollout order (each step is a go/no-go gate)
1. Operator answers D1–D7. Register and decisions recorded on issue #119.
2. Contract step: capture real `vzdump --stdout`, `qmrestore -`, `qm agent`, `rclone lsf/check`, and SMB mount behaviour on the host as fixtures (read-only or on scratch objects).
3. Guest agent on dune-dev, then acp-bot (test freeze/thaw); dune-prod last, in a low-population window.
4. Key and credentials: generate the age keypair **off the host**, put only the recipient on the host, store the private key and rclone crypt secrets in the password manager plus second escrow; run `backup-verify-key`.
5. SMB mount and OneDrive (`rclone authorize` on another machine); `backup-doctor` must be all green.
6. DB tier + daily set; **gate:** an archive decrypts on a **second machine using only the password-manager key**, and a real DB restore into a throwaway Postgres container passes its row-count checks.
7. One manual weekly image, watched; measure size, time and game latency; set retention. **Gate:** a real restore of the prod image to a scratch VM boots and passes in-guest checks.
8. Only then enable the timers and the alarm; confirm the external dead-man's-switch fires when a run is deliberately skipped.
9. First scheduled runs succeed; record evidence; close the audit issues.

## 7. Audit
Layer 1 is complete (register linked above). Requirement 20 Layer 2 (implementation audit) runs on the code before it is used on the host, and Layer 3 (`/code-review high`) on the PR diff.
