# R740 Backup Runbook

**Status:** written 2026-09-30, revised the same day after the Layer 2 audit, for design v2 (`docs/superpowers/specs/2026-09-29-backup-strategy-design.md`). **Nothing described here is deployed until the rollout in section 9 is complete**; until then the running game server has no off-box backup.

If you are here because something is broken, jump to **section 5 (alerts)** or **section 6 (restore)**.

## 1. What is protected, where it goes, how fresh it is

| Tier | Contents | Schedule | Copies | Freshness limit (alarm) |
|---|---|---|---|---|
| Database tier | newest official dump pair(s) | every 6h (04:45, 10:45, 16:45, 22:45) | OneDrive + desktop share | 8h |
| Daily set | recent dump pairs, `runtime/secrets`, `.env`, host config | 05:15 | OneDrive + desktop share | 26h |
| Weekly images | full images of VM 101, 102, 103 and CT 104 | Sunday 01:00, no new image starts after 04:15 | **desktop share only** | 8 days |

- Everything is encrypted with `age` before it leaves the hypervisor. **The hypervisor holds only the public key.** The private key lives in your password manager plus a second escrow.
- `market-bot-seed` dumps (a feature seed made every 15 minutes) are excluded. The authoritative restore point is the newest dump whose sidecar says `backup_origin: automatic` (the scheduled 04:30 job).
- **VM images are not the primary database source.** They are for rebuilding the whole server. The primary database source is a logical dump.
- **The two targets are independent.** If the desktop is asleep or off, the daily and database tiers still upload to OneDrive; the run ends with a loud `DEGRADED` alert so you know the desktop copy is missing. Weekly images need the desktop and are skipped with an alert if it is unreachable.
- Retention: database tier keeps 28 files and 1 per month for 1 month; daily keeps 30 files plus the newest of each of the last 12 months, on both targets. Weekly images: 3 per guest (1 for VM 102). Files are only pruned after **that target's** new copy has been verified, and only names with a plausible, not-in-the-future timestamp are ever counted or deleted.

Where things live on the hypervisor:

| What | Path |
|---|---|
| Config (mode 0600) | `/root/.config/r740-backup/backup.env` |
| Secret files (mode 0600) | `/root/.config/r740-backup/` (webhook, dead-man URLs, SSH key, pinned known_hosts, SMB credentials) |
| State, audit log, evidence log | `/var/lib/r740-backup/` (`audit.log` is a hash chain; `evidence.log`) |
| Scripts | `scripts/backup-*.sh` in this repository |
| Units | `/etc/systemd/system/r740-backup-*.{service,timer}` |
| Job output | `journalctl -u r740-backup-<name>` (`dbtier`, `daily`, `weekly`, `check`, `pipeline`) |

## 2. The commands

| Command | Purpose |
|---|---|
| `scripts/backup-doctor.sh [--live]` | Is everything actually ready? Run after setup, before enabling timers, and whenever unsure. |
| `scripts/backup-key.sh generate --handoff-dir DIR` | One-time key creation (private key handed off, never stored on the host or the share). |
| `scripts/backup-key.sh verify --identity FILE` | Prove the escrowed key really decrypts. |
| `scripts/backup-daily.sh --tier db\|daily` | Run a tier by hand. |
| `scripts/backup-weekly.sh` | Run the weekly images by hand (`BK_WEEKLY_FORCE=1 scripts/backup-weekly.sh` for a watched run outside the window). |
| `scripts/backup-check.sh` | Run the alarm by hand. |
| `scripts/backup-drill.sh pipeline\|db\|vm` | Restore drills (section 7). |
| `scripts/backup-install-timers.sh [--no-enable]` | Write and enable the timers. |
| `scripts/run-backup-tests.sh` | Run the test suite in the read-only sandbox (never run tests any other way on the hypervisor). |

## 3. Definition of P1

A **P1** is: a backup tier is stale or failing, a restore drill failed, an image or database set is DEGRADED (one target missing), or the alarm could not deliver its alert (exit code 5). It is delivered by a Discord message that pings `BK_ALERT_MENTION` **and** by the external dead-man's-switch going silent-or-failed. Every failure alert from these scripts is a P1: treat it as "there is currently less backup than there should be" and fix it the same day. An overdue drill (35 days for the database, 100 for VM/CT and escrow) is also raised by the alarm.

## 4. Setup (first time, in order)

Every step is safe to repeat. Stop at any step that does not end as described.

1. **Prerequisites on the hypervisor:** `apt-get install -y age jq zstd cifs-utils rclone bats shellcheck`. Confirm `age --version` and `rclone version` run. (Install from the distribution; do not download binaries.) Create the staging directory: `mkdir -p -m 700 /mnt/backup-stage` (on a filesystem with room for several times one daily set).
2. **Desktop share.** On the desktop create a dedicated local account (for example `r740backup`) with write access to one folder only, and take periodic desktop-side snapshots of that folder (Windows shadow copies or filesystem snapshots): this is what protects the history if the hypervisor is ever compromised, so agree a frequency and retention and check the snapshots exist. **The private age key must never be placed on this share** (its snapshots would keep it). Record the desktop's IP, VLAN, and whether it is wired. On the hypervisor put the credentials in `/root/.config/r740-backup/smb-credentials` (mode 0600, lines `username=` and `password=`), and add to `/etc/fstab` (use the desktop's **IP address**; NetBIOS names do not resolve here):
   `//DESKTOP-IP/share /mnt/desktop-backup cifs credentials=/root/.config/r740-backup/smb-credentials,vers=3.1.1,seal,cache=none,soft,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=60 0 0`
   then `systemctl daemon-reload && ls /mnt/desktop-backup && mountpoint /mnt/desktop-backup`. `seal` encrypts in transit, and `cache=none` makes the read-back checks read the desktop's copy rather than the local cache; the doctor warns if either is missing. If the desktop is on another VLAN, the router needs one rule: hypervisor `192.168.68.127` to the desktop on TCP 445 only; the desktop never initiates connections to the hypervisor.
3. **OneDrive (dedicated Microsoft account with MFA).** The interactive login cannot happen on a headless host. On any machine with a browser and `rclone`, run `rclone authorize "onedrive"`, sign in to the **dedicated backup account**, and copy the token it prints (then clear the terminal scrollback and clipboard). On the hypervisor run `rclone config`: create remote `onedrive` (paste the token), then a `crypt` remote named `onedrive-crypt` wrapping `onedrive:r740-backups` with **standard** filename encryption and your own generated password and salt. **Save the crypt password and salt in the password manager immediately**; without them the remote is unreadable. `chmod 600 /root/.config/rclone/rclone.conf`. Create the target folder: `rclone mkdir onedrive-crypt:r740` (the jobs write to `onedrive-crypt:r740/<tier>/`, so `BK_RCLONE_REMOTE=onedrive-crypt:r740`; the doctor's reachability probe fails until this folder exists). Test: `rclone lsd onedrive-crypt:r740`.
4. **Keys.** Put a **removable disk** (USB stick) in the hypervisor, mount it at `/mnt/keyusb`, then: `scripts/backup-key.sh generate --handoff-dir /mnt/keyusb`. The script refuses a hand-off directory on the backup share or on any network filesystem. The private key is written **only** to that directory (never printed). Move it into the password manager **and** a second escrow (for example a sealed printout in a safe), then prove it: retrieve it from the password manager into a file and run `scripts/backup-key.sh verify --identity thatfile`. It must print `escrow verified`. Only then wipe the key from the stick and unmount it. `generate` also creates `backup.env` from the template and fills in `BK_AGE_RECIPIENT`.
5. **Pull gate on dune-prod.** Copy `scripts/dune-prod/r740-backup-gate.sh` to `~/bin/` on dune-prod (mode 755; confirm the login user that owns the game stack, assumed `dune` below). On the hypervisor: `ssh-keygen -t ed25519 -N "" -f /root/.config/r740-backup/backup_ed25519`. On dune-prod append to `~/.ssh/authorized_keys` (one line, using the **public** key): `from="192.168.68.127",restrict,command="/home/dune/bin/r740-backup-gate.sh" ssh-ed25519 AAAA... r740-backup`. Pin the host key: on the hypervisor `ssh-keyscan -t ed25519 192.168.20.10 > /root/.config/r740-backup/known_hosts`, then compare the fingerprint (`ssh-keygen -lf` of that file) with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` **on dune-prod** before trusting it. Test: `ssh -F /dev/null -i /root/.config/r740-backup/backup_ed25519 -o UserKnownHostsFile=/root/.config/r740-backup/known_hosts dune@192.168.20.10 status`. Do the same pinning for the drill host: `ssh-keyscan -t ed25519 192.168.21.10 > /root/.config/r740-backup/known_hosts_dev` and compare its fingerprint the same way; the drill uses root's key to reach dune-dev, so authorise that key there deliberately and note it in the credential inventory.
6. **Six-hourly game dumps.** On dune-prod run `dune db auto enable 04:30 7 6` (04:30, keep 7 days, every 6 hours) so a fresh official dump exists before each tier run. Afterwards confirm with `ls -lt runtime/backups/db | head` that a new `automatic` dump appears every six hours.
7. **Dead-man's-switch.** Create two checks at an external Healthchecks-style heartbeat service (a failure is reported by appending `/fail` to the ping URL; a service that does not support that will only alert on silence), one for the backup jobs and one for the alarm. Put each ping URL in a 0600 file (`deadman-url`, `deadman-check-url`) under `/root/.config/r740-backup/`. Configure the service to alert you when a heartbeat is late. Create the Discord webhook the same way (`discord-webhook`, 0600).
8. **Config.** Edit the existing `/root/.config/r740-backup/backup.env` (mode 0600) with the values documented in `backup.env.example` (do **not** copy the template over it: that would erase the recipient from step 4). Fill in at least: `BK_BACKUP_SSH`, `BK_BACKUP_SSH_KEY`, `BK_KNOWN_HOSTS`, `BK_DEADMAN_URL_FILE`, `BK_CHECK_DEADMAN_URL_FILE`, `BK_DISCORD_WEBHOOK_FILE`, `BK_ALERT_MENTION`, `BK_RUNBOOK_URL`, `BK_AUDIT_SHIP_DIR` (for example a folder on the share, so a copy of the audit log exists off the host), and for the drills `BK_DRILL_SSH`, `BK_DRILL_KNOWN_HOSTS`, `BK_DRILL_PG_IMAGE` (the same Postgres image tag as prod), `BK_DRILL_MIN_TABLES`, `BK_DRILL_ROW_CHECKS` (several tables that hold real data, for example `dune.world_partition:30 dune.<players table>:1`), `BK_DRILL_TMPFS_SIZE` (larger than the restored database, and remember dune-dev's free memory) and one `BK_DRILL_VM_CHECK_<id>` per guest (for VM 101 include a check that Postgres answers).
9. **Guest agents.** Install `qemu-guest-agent` in each guest (dune-dev first, then acp-bot, dune-prod **last** in a low-population window) and check `qm agent <id> ping`.
10. **`scripts/backup-doctor.sh --live`** must show `0 FAIL`. Fix every `[FAIL]`; read every `[WARN]`.
11. **Do not enable the timers yet.** Continue with the rollout gates in section 9. (Enabling them before the first drills have passed makes the alarm report the drills as overdue.)

## 5. Alerts: what each means and what to do

Every failure alert has the same shape: `r740 <job> FAILED at stage '<stage>': <error> | re-run: <command> | runbook: <link>`. Run the re-run command after fixing the cause (a weekly re-run outside its window needs `BK_WEEKLY_FORCE=1` in front). Success is silent except one daily summary line, the Sunday weekly line and the dead-man heartbeat.

| Stage | Meaning | First thing to check |
|---|---|---|
| `preflight` | no recipient, no staging space, outside the weekly window | `scripts/backup-doctor.sh` |
| `pull` | the gate on dune-prod refused or was unreachable (stale/tiny/incomplete dump, SSH key or pinned host key) | run the `status` command from step 5; check the game's own dump timer on dune-prod |
| `verify` | the pulled archive was truncated, contained a link or unsafe path, was missing secrets, or a dump failed its header check | re-run; if it repeats, look at the dump files on dune-prod |
| `host-config` | host config archive empty, failed, or a path resolves to a forbidden place | check `BK_HOST_PATHS` |
| `encrypt` | `age` failed or the recipient is wrong | `scripts/backup-key.sh fingerprint` |
| `smb` | **DEGRADED**: the OneDrive copy is fine, the desktop copy is missing (share not mounted, dropped, copy or verification failed) | desktop asleep or share unreachable; TCP 445; `mountpoint /mnt/desktop-backup`; re-run the tier |
| `upload` | OneDrive upload failed | token expired/revoked, quota, network; `rclone lsd onedrive-crypt:r740` |
| `verify-transfer` | the OneDrive copy does not match | re-run; if it repeats, suspect the account or network |
| `prune` | retention could not run | share/remote state; nothing valuable is deleted before that target's new copy verified |
| `summary` (weekly) | one or more guests failed; the message names each guest and why (`stalled`, `no time left`, `read-back hash differs`, ...) | the named guest; the other guests still ran |
| `check` | the alarm found a stale/missing/undersized artifact, a dead OneDrive, or an overdue drill | read the listed findings |

- **Alarm exit code 5** means the Discord alert could not be delivered (a deleted or rejected webhook counts). The dead-man's-switch was still pinged, and the alarm retries on its next run instead of staying quiet; fix the webhook first.
- **OneDrive token dead** (`OneDrive probe failed`): repeat step 3's `rclone authorize` and update the `onedrive` remote's token. Yearly re-auth is normal.
- **Weekly "output stalled"**: the share or network hung while an image was being written; the run aborted the image so the live VM is not held waiting on it. Check the desktop and the network, then run the watched manual weekly.
- **Weekly "outside the maintenance window"** on a catch-up after downtime is expected and harmless; run a watched manual run: `BK_WEEKLY_FORCE=1 scripts/backup-weekly.sh`.
- Where to look: `journalctl -u r740-backup-<name>`, `/var/lib/r740-backup/audit.log` (`backup-doctor.sh` verifies its hash chain) and `evidence.log`.

## 6. Restore (works from a bare Linux box)

You need: the **private age key** (password manager), `age`, `zstd` and `rclone` installed on the machine you restore from, and either the OneDrive account (with the crypt password and salt) or the desktop share.

**Never run two servers with the same battlegroup identity at once.** Before restoring a server, make sure the old one is off.

### 6a. Get and open a set

```bash
# from OneDrive (bare box): recreate the two rclone remotes as in setup step 3, then
rclone lsf onedrive-crypt:r740/daily | tail -3
rclone copyto onedrive-crypt:r740/daily/daily-YYYYMMDD-HHMMSS.tar.age ./set.tar.age
# or copy it from the desktop share (daily/ or dbtier/)
age -d -i private.key -o set.tar set.tar.age          # a wrong key or damaged file fails here
tar -xf set.tar && sha256sum -c MANIFEST.sha256        # every line must say OK
cat prod/gate-manifest.txt                              # authoritative=<path> names the restore point
```

The `authoritative=` value is a path relative to the set's `prod/` folder (for example `runtime/backups/db/<file>.backup`), so the dump is at `prod/<that value>`.

### 6b. Database only (server is up but data is damaged)

1. Get the players out. **Do not run `dune stop` or `dune db stop` first**: `dune db restore` needs the Postgres container running and stops the game services itself.
2. Copy the dump and its `.yaml` from `prod/<authoritative>` into `runtime/backups/db/` on the server (for example with `scp`).
3. Make sure `runtime/secrets/funcom-token.txt` on the server is the token that belongs to the backup's battlegroup; the restore refuses to adopt the backup identity otherwise. (After a rebuild, restore `prod/runtime/secrets` and `prod/.env` from the set first.)
4. Restore with the adopt flag: `dune db restore runtime/backups/db/<file>.backup --adopt-backup-battlegroup`. `--keep-current-battlegroup` would hide every existing character in-game; do not use it for recovery. It asks for confirmation and takes a safety backup of the current database first; **if the database is too damaged for that safety backup to succeed, add `--no-safety-backup`.** (The console's Backup/Restore page can do the same import and restore if the command line misbehaves.)
5. `dune start`, then `dune status` until READY.

### 6c. One VM or container

**Weekly images exist only on the desktop share.** If the desktop is lost too, rebuild the guest from the deployment kit and restore the database from OneDrive as in 6b.

```bash
age -d -i private.key vm101-YYYYMMDD-HHMMSS.vma.zst.age | zstd -dc | qmrestore - 101 --storage local-lvm --unique 0
age -d -i private.key ct104-YYYYMMDD-HHMMSS.tar.zst.age | zstd -dc | pct restore 104 - --storage local-lvm
```
Use `--unique 0` only to **replace** a guest that no longer exists (it keeps the original MAC and identity); use `--unique 1` for a side-by-side copy. A restored dune-prod is crash-consistent: on first boot check `dune status`, and if the database is doubtful restore the newest logical dump as in 6b.

### 6d. Whole host (new hardware)

1. Install Proxmox and rebuild networking from the host-config set (`host/etc/network/interfaces`, `host/etc/pve`, `host/etc/cloudflared`).
2. Restore the guests as in 6c, dune-prod last.
3. Restore `prod/runtime/secrets` and `prod/.env` on dune-prod **before** starting the game stack, then restore the database as in 6b.
4. Recreate the Cloudflare tunnel routing and the router port forwards from `docs/`; run `backup-doctor.sh`.

## 7. Drills: proving the backups are usable

| Drill | Cadence | Who | Command |
|---|---|---|---|
| Pipeline (no real key) | monthly, automated (timer) | nobody | `scripts/backup-drill.sh pipeline` |
| Database restore | monthly | you, assisted | `scripts/backup-drill.sh db --identity <key file>` |
| VM/CT restore | quarterly at minimum (rotate 101, 102, 103, 104; the prod image at least quarterly) | you, assisted | `scripts/backup-drill.sh vm --guest <id> --identity <key file>` |
| Key escrow | quarterly | you | `scripts/backup-key.sh verify --identity <key file>` |

For the assisted drills, make the private key available as a file for the duration of the drill only (fetch it from the password manager, run the drill, then delete the file). Use `--dry-run` first: for the **database** drill it opens the archive in RAM and checks it; for the **VM** drill it only prints the plan and does not touch the archive or the key. The database drill restores only the dump into a **throwaway** Postgres container on dune-dev (no network, size-limited tmpfs, removed afterwards), mirroring the real restore (create the `dune` role and database, then a plain `pg_restore`), and fails if more than `BK_DRILL_MAX_RESTORE_ERRORS` (default 0) errors occur or any configured row check fails. **Player data does reach dune-dev's memory during this drill**; secrets never do. The VM drill restores to a scratch VMID on a transient bridge with no uplink, removes every extra network device, refuses images that carry passthrough devices, caps memory and cores, removes NUMA pinning, boots it, runs your configured in-guest check, then destroys it. Every result is written to `evidence.log` and to the chained audit log. **An overdue drill raises an alarm.** A failed drill is a P1.

## 8. Credentials, keys and rotation

| Credential | Where | Owner / scope | Rotation |
|---|---|---|---|
| age private key | password manager + second escrow (**not** the host, **not** the share) | operator; decrypts every backup | on suspected exposure: see below |
| age recipient (public) | `backup.env` | operator; encrypts only | changes with the key |
| rclone crypt password and salt | password manager and host `rclone.conf` | operator; filename and content layer | with the token if exposed; **keep the old pair to read old objects** |
| Microsoft account, MFA and recovery codes | password manager | named owner + named alternate | password yearly; verify MFA and recovery quarterly |
| OneDrive token | `/root/.config/rclone/rclone.conf` (0600) | the dedicated account | re-auth yearly and after any host compromise |
| SMB credential | `/root/.config/r740-backup/smb-credentials` (0600) | one share, one desktop account | yearly |
| Desktop share administrator | desktop | operator | per desktop policy |
| Backup SSH key | `/root/.config/r740-backup/backup_ed25519` (0600) | can only run the gate's commands, only from the hypervisor | yearly; replace the `authorized_keys` line |
| Root SSH key to dune-dev (drill) | hypervisor root | unrestricted on dune-dev: authorise it deliberately | yearly |
| Discord webhook, dead-man URLs | 0600 files | alerts and heartbeats | yearly |
| Password manager itself | operator | holds the private key | per its own policy |

Migrating the hypervisor means **rotating** these, not copying them. **If every copy of the private key is lost, all backups are unrecoverable.** `backup-key.sh verify` and the doctor exist so you learn that before a disaster.

**Rotating the age key (manual; there is no rotate command):** generate the new key on a trusted machine (`age-keygen`), keep the old private key with a note of the date, put the **new public** recipient into `BK_AGE_RECIPIENT` and update `BK_AGE_RECIPIENT_CREATED`, run `backup-key.sh verify` with the new private key, and run a daily tier. Archives made before the change remain readable only with the **old** key, and anyone who held the exposed old key can still read them; delete old sets you no longer need.

## 9. Rollout gates (the timers stay off until all pass)

1. `backup-doctor.sh --live` shows `0 FAIL`.
2. A daily set decrypts **on a second machine using only the password-manager copy of the key**.
3. `backup-drill.sh db` passes for real (this also captures the real restore behaviour of the Postgres image; adjust `BK_DRILL_*` if needed).
4. One manual weekly image, watched (game latency, disk, network, time), then `backup-drill.sh vm` for the prod image passes.
5. `backup-install-timers.sh` (only now), then deliberately skip one run and confirm the external dead-man's-switch alerts.
6. First scheduled runs succeed; the evidence log has a record of each gate.

## 10. Data protection

- **What the backups contain:** player personal data (Steam IDs, Discord IDs, chat and character data) and server secrets.
- **Why:** operational recovery only. Controller: the server operator (contact details go in the server's privacy notice); Microsoft is a processor for the OneDrive copy (the dedicated account's data region is recorded by the operator).
- **Where:** OneDrive (encrypted client-side, including file names), the desktop share (encrypted files, plus the desktop's own snapshots), the drill container's memory on dune-dev (during a database drill), and the escrow locations of the decryption key.
- **How long:** database tier about 7 days plus one per month for a month; daily sets 30 days plus the newest of each of the last 12 months, so **a set can be kept for up to about 12 months, and longer where months are missing**; weekly images about 3 weeks; **the desktop's snapshots and the OneDrive recycle bin and version history add to this and are not controlled by these scripts**: set them to the shortest acceptable retention.
- **Erasure requests:** a player's data is removed from the live database when they ask; it is **not** selectively erased from existing backups and expires as the cycle rolls. **Deletions made since a backup was taken must be re-applied after any restore**: keep a dated erasure log (a private file, ids only) and apply it to the restored database before players are let back in. State this, and data-subject rights and breach handling, in the server's privacy notice.

## 11. Network paths (Requirement 23)

| Path | From to | Protocol | Notes |
|---|---|---|---|
| Pull | hypervisor `192.168.68.127` to dune-prod `192.168.20.10` | SSH 22, restricted key with `from=`, pinned host key | can only run `status`, `set`, `newest-db`, `dump-now` |
| Share | hypervisor to desktop | SMB 3.1.1 with sealing, TCP 445 | automount, `soft`, `cache=none`; one router rule if inter-VLAN |
| Off-site | hypervisor to Microsoft | HTTPS: `login.microsoftonline.com`, `graph.microsoft.com`, `onedrive.live.com`, `*.sharepoint.com` (capture the real list in rollout gate 1) | outbound only, rate-limited by `BK_RCLONE_BWLIMIT` |
| Alerts | hypervisor to Discord and the heartbeat service | HTTPS | outbound only |
| Drill | hypervisor `192.168.68.127` to dune-dev `192.168.21.10` | SSH 22, pinned host key | throwaway container only |

## 12. Known limits and accepted risks

- **A root-compromised hypervisor can delete or alter both remote copies.** Both targets accept deletes from the hypervisor (the jobs prune). What limits the damage: the desktop's own snapshots (only if you set them up and check them), OneDrive's recycle bin and version history (limited retention, not controlled here), the off-host copy of the audit log, and the fact that the private key is not on the host. There is no immutable or append-only target. This was accepted with the design (decision D3); revisit it if the desktop can offer immutable snapshots.
- **The audit log detects edits, reorders and mid-log deletion, not removal of its newest records**; the shipped copy (`BK_AUDIT_SHIP_DIR`) is what exposes a truncated tail. The evidence log is a plain local file that root can rewrite; drill and escrow currency are also recorded in the chained log.
- **Images are crash-consistent**, not application-consistent; the logical dump is the trusted database source.
- **Weekly image rate and window are estimates** (`--bwlimit 51200` KiB/s, four guests in about three hours): measure them in rollout gate 4 and tune `BK_VZDUMP_BWLIMIT_KIB`, and lower it if the game's latency suffers.
- The host config set includes `/etc/pve` (with its private keys) and the Cloudflare tunnel credentials, protected by the same single age key.
