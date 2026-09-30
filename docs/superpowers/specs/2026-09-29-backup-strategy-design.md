# R740 Backup Strategy — Design

**Status:** design approved by the operator 2026-09-29; awaiting written-spec review, then an implementation plan.
**Scope:** the R740 Proxmox host and its guests: `dune-prod` (VM 101), `dune-dev` (VM 102), `acp-bot` (VM 103), `theparlor` (CT 104), plus the Kadir game database and the secrets that tie the battlegroup to its VM.
**Tracking:** `Project-Arrakis/meta`#73 (context), this repo's backup issue (linked from the PR).

## 1. Problem

Today nothing on this host is backed up off-box. Verified 2026-09-29:

- The host has **one** disk (`sda`, 1.7TB, a virtual disk behind a PERC H730P). Host root, every VM disk and the LXC share it.
- There are **zero** Proxmox backup jobs, no NAS or NFS/CIFS mounts, no Proxmox Backup Server (only the client tools are installed), and no second disk. The `local` directory storage is on a 94GB root volume with ~38GB free, too small to hold 300GB VMs.
- The game DB backup runs daily (`dune-awakening-db-backup.timer`, 04:30) but writes to `runtime/backups` **on the VM's own disk**, so a lost disk loses the backups with it.
- `runtime/secrets` (Funcom token, admin/session secrets, alert relay and Discord adapter tokens) ties the battlegroup identity to the VM. A backup without it cannot restore the server.
- The QEMU guest agent is enabled in each VM's config but **not running** in any guest, so a snapshot backup is crash-consistent only.

Consequence: the running dune-prod VM is the only copy of the Kadir battlegroup.

## 2. Goals and non-goals

**Goals**
- Survive loss of the disk, the RAID controller, or the whole chassis, not just a bad update.
- Automatic and scheduled, encrypted before leaving the host, with failure alerts.
- A restore path that is tested on a schedule (Strict Requirement 25).

**Non-goals (YAGNI)**
- No deduplicating backup server (Proxmox Backup Server) in this iteration; revisit if weekly image sizes prove unmanageable.
- No high availability or live replication.
- No backup of player-side data; only what the server holds.

## 3. Decisions (operator-approved)

| Decision | Choice |
|---|---|
| Approach | **Tiered**: daily small encrypted app backups off-site, weekly full VM images to a second machine |
| Off-site target | **OneDrive** via `rclone` with client-side encryption (the OneDrive desktop client is **not** installed on Proxmox) |
| Second-machine target | **The operator's always-on desktop** over SMB, 500GB+ free |
| Encryption | `age`, applied before anything leaves the host |
| Scheduling | systemd timers on the Proxmox host; scripts live in this repo and go through PR review |

## 4. Design

### 4.1 What is protected and when

| Data | Schedule | Destination | RPO |
|---|---|---|---|
| Game DB backup (existing 04:30 output), `runtime/secrets`, key configs | Daily, after the 04:30 job | OneDrive and desktop | 24h |
| Full VM/CT images: 101, 102, 103, 104 | Weekly, off-hours | Desktop (SMB) | 7 days |
| Proxmox host config (`/etc/pve`, network, tunnel config record) | Weekly | OneDrive and desktop | 7 days |

Recovery time targets: DB restore under about 1 hour; full-VM restore from the desktop about 1–2 hours.

### 4.2 Consistency

Install and start `qemu-guest-agent` in every guest so snapshot backups freeze the filesystem. The existing `dune db backup` output stays the authoritative source for restoring the database; the VM image is the disaster-recovery copy.

### 4.3 Encryption and keys

- Everything is encrypted with `age` before upload or SMB write. VM images contain the Funcom token, so they are treated as secrets.
- The private key exists in two places: a root-only file on the host and a second copy the operator controls (password manager). **If both are lost, the backups are unrecoverable.** This is stated to the operator and recorded in the runbook.
- OneDrive (`rclone` config) and SMB credentials live in root-only files under `~/.config`, never inside a repo (Conventions, Requirement 5).

### 4.4 Retention and sizing

- **OneDrive:** 30 daily sets + 12 monthly (small; roughly 100–150GB).
- **Desktop:** 3 weekly copies of dune-prod, acp-bot and theparlor; 1 copy of dune-dev. About 300GB if images compress to 40–90GB each.
- The 40–90GB figure is an estimate (about 138GB written per 300GB guest disk today). The first manual run measures real sizes and retention is tuned from that.

### 4.5 Scheduling and staging

- systemd timers on the host, one unit per job, with `Persistent=true` so a missed run (host was off) catches up.
- VM images are dumped to a temporary staging area, encrypted, moved to the desktop share, and the staging copy deleted. Staging must not fill the thin pool: use a dedicated size-capped volume and fail the job if free space is insufficient.

### 4.6 Monitoring

- Each run posts success or failure to the existing Discord alert channel (webhook stored root-only).
- A separate check alarms if no successful backup exists within 26 hours (daily tier) or 8 days (weekly tier), so a silently dead timer is caught.
- Secrets are redacted from all logs (Requirement 24).

### 4.7 Restore testing (Requirement 25)

Monthly, scripted and logged:
- DB: restore the latest daily backup into a throwaway database and run integrity checks.
- VM: restore the latest dune-dev image to a scratch VMID on an isolated network, confirm it boots, then destroy it. A failed test is a P1.

## 5. Failure modes and open items

| Risk | Handling |
|---|---|
| Desktop off or unreachable at backup time | Job retries and alerts; OneDrive tier is independent |
| Ransomware on the desktop reaching the share | Host prunes its own copies; desktop credentials are write-scoped; OneDrive versioning is the second line |
| Lost encryption key | Documented as unrecoverable; key stored in two places |
| OneDrive OAuth token expiry | Refresh happens on use; the token-age check is part of monitoring; re-auth is a documented one-time interactive step |
| Backup fills thin pool | Size-capped staging volume; pre-flight free-space check |

**Unverified, to confirm during implementation**
- The PERC virtual disk's RAID level (not readable from the host tools installed). RAID 5/10 covers a disk failure but not controller or chassis loss.
- That the host can reach the desktop's SMB share, and the share name/credentials.
- OneDrive account type and free space; a one-time browser login is required from the operator.

## 6. Rollout order

1. Install and start the guest agent in every guest.
2. Encrypted DB + secrets + host-config job to OneDrive and desktop; verify a restore of the DB.
3. Run one manual VM image backup; measure real sizes; set retention.
4. Enable the weekly VM schedule and the alerting.
5. Run the first scripted restore test; record the result.

## 7. Audit

Requirement 20 Layer 1 (design audit) is required before implementation begins; findings are filed as GitHub issues and this spec is updated before the implementation plan is written.
