# R740 Backup Runbook

**Status:** written 2026-09-30 for design v2 (`docs/superpowers/specs/2026-09-29-backup-strategy-design.md`). **Nothing described here is deployed until the rollout in section 9 is complete**; until then the running game server has no off-box backup.

If you are here because something is broken, jump to **section 5 (alerts)** or **section 6 (restore)**.

## 1. What is protected, where it goes, how fresh it is

| Tier | Contents | Schedule | Copies | Freshness limit (alarm) |
|---|---|---|---|---|
| Database tier | newest official dump pair(s) | every 6h (04:45, 10:45, 16:45, 22:45) | OneDrive + desktop share | 8h |
| Daily set | recent dump pairs, `runtime/secrets`, `.env`, host config | 05:15 | OneDrive + desktop share | 26h |
| Weekly images | full images of VM 101, 102, 103 and CT 104 | Sunday 01:00, hard stop 04:15 | desktop share | 8 days |

- Everything is encrypted with `age` before it leaves the hypervisor. **The hypervisor holds only the public key.** The private key lives in your password manager plus a second escrow.
- `market-bot-seed` dumps (a feature seed made every 15 minutes) are excluded. The authoritative restore point is the newest dump whose sidecar says `backup_origin: automatic` (the scheduled 04:30 job).
- **VM images are not the primary database source.** They are for rebuilding the whole server. The primary database source is a logical dump.

Where things live on the hypervisor:

| What | Path |
|---|---|
| Config (mode 0600) | `/root/.config/r740-backup/backup.env` |
| Secret files (mode 0600) | `/root/.config/r740-backup/` (webhook, dead-man URLs, SSH key, pinned known_hosts, SMB credentials) |
| State, audit log, evidence log | `/var/lib/r740-backup/` (`audit.log`, `evidence.log`) |
| Scripts | `scripts/backup-*.sh` in this repository |
| Units | `/etc/systemd/system/r740-backup-*.{service,timer}` |

## 2. The commands

| Command | Purpose |
|---|---|
| `scripts/backup-doctor.sh [--live]` | Is everything actually ready? Run after setup, before enabling timers, and whenever unsure. |
| `scripts/backup-key.sh generate --handoff-dir DIR` | One-time key creation (private key handed off, never stored). |
| `scripts/backup-key.sh verify --identity FILE` | Prove the escrowed key really decrypts. |
| `scripts/backup-daily.sh --tier db\|daily` | Run a tier by hand. |
| `scripts/backup-weekly.sh` | Run the weekly images by hand (`BK_WEEKLY_FORCE=1` for a watched run outside the window). |
| `scripts/backup-check.sh` | Run the alarm by hand. |
| `scripts/backup-drill.sh pipeline\|db\|vm` | Restore drills (section 7). |
| `scripts/backup-install-timers.sh [--no-enable]` | Write and enable the timers. |
| `scripts/run-backup-tests.sh` | Run the test suite in the read-only sandbox (never run tests any other way on the hypervisor). |

## 3. Definition of P1

A **P1** is: a backup tier is stale or failing, a restore drill failed, or the alarm could not deliver its alert (exit code 5). It is delivered by a Discord ping **and** by the external dead-man's-switch going silent-or-failed. Treat a P1 as "there is currently no backup for that tier": fix it the same day.

## 4. Setup (first time, in order)

Every step is safe to repeat. Stop at any step that does not end as described.

1. **Prerequisites on the hypervisor:** `apt-get install -y age jq zstd cifs-utils rclone bats shellcheck`. Confirm `age --version` and `rclone version` run. (Install from the distribution; do not download binaries.)
2. **Desktop share.** On the desktop create a dedicated local account (for example `r740backup`) with write access to one folder only, and take periodic desktop-side snapshots of that folder (Windows shadow copies or filesystem snapshots): this is what protects the history if the hypervisor is ever compromised. Record the desktop's IP, VLAN, and whether it is wired. Then on the hypervisor put the credentials in `/root/.config/r740-backup/smb-credentials` (mode 0600, lines `username=` and `password=`), and add to `/etc/fstab`:
   `//DESKTOP/share /mnt/desktop-backup cifs credentials=/root/.config/r740-backup/smb-credentials,vers=3.1.1,seal,soft,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=60 0 0`
   then `systemctl daemon-reload && ls /mnt/desktop-backup && mountpoint /mnt/desktop-backup`. If the desktop is on another VLAN, the router needs one rule: hypervisor `192.168.68.127` to the desktop on TCP 445 only; the desktop never initiates connections to the hypervisor.
3. **OneDrive (dedicated Microsoft account with MFA).** The interactive login cannot happen on a headless host. On any machine with a browser and `rclone`, run `rclone authorize "onedrive"`, sign in to the **dedicated backup account**, and copy the token it prints. On the hypervisor run `rclone config`: create remote `onedrive` (paste the token), then a `crypt` remote named `onedrive-crypt` wrapping `onedrive:r740-backups` with **standard** filename encryption and your own generated password and salt. **Save the crypt password and salt in the password manager immediately**; without them the remote is unreadable. `chmod 600 /root/.config/rclone/rclone.conf`. Test: `rclone lsd onedrive-crypt:`.
4. **Keys.** `mkdir -p /mnt/desktop-backup/keyhandoff && scripts/backup-key.sh generate --handoff-dir /mnt/desktop-backup/keyhandoff`. The private key is written **only** to that hand-off folder (never printed). Move it into the password manager **and** a second escrow (for example a sealed printout in a safe), then prove it: retrieve it from the password manager into a file and run `scripts/backup-key.sh verify --identity thatfile`. It must print `escrow verified`. Only then delete the hand-off file from the share.
5. **Pull gate on dune-prod.** Copy `scripts/dune-prod/r740-backup-gate.sh` to `~/bin/` on dune-prod (mode 755). On the hypervisor: `ssh-keygen -t ed25519 -N "" -f /root/.config/r740-backup/backup_ed25519`. On dune-prod append to `~/.ssh/authorized_keys` (one line, using the **public** key): `restrict,command="/home/dune/bin/r740-backup-gate.sh" ssh-ed25519 AAAA... r740-backup`. Pin the host key: on the hypervisor `ssh-keyscan -t ed25519 192.168.20.10 > /root/.config/r740-backup/known_hosts`, then compare the fingerprint (`ssh-keygen -lf` of that file) with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` **on dune-prod** before trusting it. Test: `ssh -i /root/.config/r740-backup/backup_ed25519 -o UserKnownHostsFile=/root/.config/r740-backup/known_hosts backup@192.168.20.10 status` (use the real login user).
6. **Six-hourly game dumps.** On dune-prod run `dune db auto enable 04:30 7 6` (04:30, keep 7 days, every 6 hours) so a fresh official dump exists before each tier run.
7. **Dead-man's-switch.** Create two checks at an external heartbeat service (one for the backup jobs, one for the alarm), and put each ping URL in a 0600 file (`deadman-url`, `deadman-check-url`) under `/root/.config/r740-backup/`. Configure the service to alert you when a heartbeat is late.
8. **Config.** Copy `backup.env.example` to `/root/.config/r740-backup/backup.env` (0600) and fill it in. The restore drill also needs `BK_DRILL_SSH`, `BK_DRILL_PG_IMAGE` (the same Postgres image tag as prod), `BK_DRILL_MIN_TABLES`, `BK_DRILL_ROW_CHECKS` (for example `dune.world_partition:30`) and one `BK_DRILL_VM_CHECK_<id>` per guest.
9. **Guest agents.** Install `qemu-guest-agent` in each guest (dune-dev first, then acp-bot, dune-prod **last** in a low-population window) and check `qm agent <id> ping`.
10. **`scripts/backup-doctor.sh --live`** must show `0 FAIL`. Fix every `[FAIL]`; read every `[WARN]`.
11. **Do not enable the timers yet.** Continue with the rollout gates in section 9.

## 5. Alerts: what each means and what to do

Every failure alert has the same shape: `r740 <job> FAILED at stage '<stage>': <error> | re-run: <command> | runbook: <link>`. Run the re-run command after fixing the cause. Success is silent except one daily summary line and the dead-man heartbeat.

| Stage | Meaning | First thing to check |
|---|---|---|
| `preflight` | share not mounted, no recipient, no staging space, outside the weekly window | `scripts/backup-doctor.sh`; `mountpoint /mnt/desktop-backup` |
| `pull` | the gate on dune-prod refused or was unreachable (stale/tiny/incomplete dump, SSH key or pinned host key) | run the `status` command from step 5; check the game's own dump timer on dune-prod |
| `verify` | the pulled archive was truncated, unsafe, missing secrets, or a dump failed its header check | re-run; if it repeats, look at the dump files on dune-prod |
| `host-config` | host config archive empty or failed | check `BK_HOST_PATHS` |
| `encrypt` | `age` failed or the recipient is wrong | `scripts/backup-key.sh fingerprint` |
| `smb` | share dropped or the copy did not verify bit-exactly | desktop asleep or share unreachable; TCP 445 |
| `upload` | OneDrive upload failed | token expired/revoked, quota, network; `rclone lsd onedrive-crypt:` |
| `verify-transfer` | the OneDrive copy does not match | re-run; if it repeats, suspect the account or network |
| `prune` | retention could not run | disk/share state; nothing valuable is deleted before both copies verified |
| `guest-<id>` (weekly) | one guest's image failed | the message names the error; the other guests still ran |
| `check` | the alarm found a stale/missing/undersized artifact, a dead OneDrive, or an overdue drill | read the listed findings |

- **Alarm exit code 5** means the Discord alert could not be delivered. The dead-man's-switch was still pinged; fix the webhook first.
- **OneDrive token dead** (`OneDrive probe failed`): repeat step 3's `rclone authorize` and update the `onedrive` remote's token. Yearly re-auth is normal.
- **Weekly "outside the maintenance window"** on a catch-up after downtime is expected and harmless; run a watched manual run: `BK_WEEKLY_FORCE=1 scripts/backup-weekly.sh`.

## 6. Restore (works from a bare Linux box)

You need: the **private age key** (password manager), and either the OneDrive account (with the crypt password and salt) or the desktop share.

**Never run two servers with the same battlegroup identity at once.** Before restoring a server, make sure the old one is off.

### 6a. Get and open a set

```bash
# from OneDrive (bare box): recreate the two rclone remotes as in setup step 3, then
rclone lsf onedrive-crypt:r740-backups/daily | tail -3
rclone copyto onedrive-crypt:r740-backups/daily/daily-YYYYMMDD-HHMMSS.tar.age ./set.tar.age
# or copy it from the desktop share (daily/ or dbtier/)
age -d -i private.key -o set.tar set.tar.age          # a wrong key or damaged file fails here
tar -xf set.tar && sha256sum -c MANIFEST.sha256        # every line must say OK
cat prod/gate-manifest.txt                              # authoritative= names the restore point
```

### 6b. Database only (server is up but data is damaged)

1. Stop players out (`dune stop` when nobody is on).
2. Copy `prod/runtime/backups/db/<authoritative>` and its `.yaml` into `runtime/backups/db/` on the server.
3. **Restore with the adopt flag:** `dune db restore runtime/backups/db/<file> --adopt-backup-battlegroup`. `--keep-current-battlegroup` would hide every existing character in-game; do not use it for recovery. (The console's Backup/Restore page can do the same import and restore if the command line misbehaves.)
4. `dune start`, then `dune status` until READY.

### 6c. One VM or container

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
| VM/CT restore | quarterly at minimum (rotate 101, 102, 103, 104) | you, assisted | `scripts/backup-drill.sh vm --guest <id> --identity <key file>` |
| Key escrow | quarterly | you | `scripts/backup-key.sh verify --identity <key file>` |

For the assisted drills, make the private key available as a file for the duration of the drill only (fetch it from the password manager, run the drill, then delete the file). Use `--dry-run` first: it verifies the archive in RAM and prints exactly what would happen. The database drill restores only the dump into a **throwaway** Postgres container on dune-dev with no network; secrets never enter dune-dev. The VM drill restores to a scratch VMID on a transient bridge with no uplink, caps its memory and cores, removes NUMA pinning, boots it, runs your configured in-guest check, then destroys it. Every result is written to `evidence.log`; **an overdue drill (35 days for the database, 100 for VMs and escrow) raises an alarm.** A failed drill is a P1.

## 8. Credentials, keys and rotation

| Credential | Where | Scope | Rotation |
|---|---|---|---|
| age private key | password manager + second escrow (**not** the host) | decrypts every backup | on suspected exposure: generate a new keypair, keep the old private key for old archives, note the change date |
| age recipient (public) | `backup.env` | encrypts only | replaced with the key |
| rclone crypt password and salt | password manager and host `rclone.conf` | filename and content layer | with the token if exposed |
| OneDrive token | `/root/.config/rclone/rclone.conf` (0600) | the dedicated account | re-auth yearly and after any host compromise |
| SMB credential | `/root/.config/r740-backup/smb-credentials` (0600) | one share, one account | yearly |
| Backup SSH key | `/root/.config/r740-backup/backup_ed25519` (0600) | can only run the gate's commands | yearly; replace the `authorized_keys` line |
| Discord webhook, dead-man URLs | 0600 files | alerts and heartbeats | yearly |

Migrating the hypervisor means **rotating** these, not copying them. **If every copy of the private key is lost, all backups are unrecoverable.** `backup-key.sh verify` and the doctor exist so you learn that before a disaster.

## 9. Rollout gates (the timers stay off until all pass)

1. `backup-doctor.sh --live` shows `0 FAIL`.
2. A daily set decrypts **on a second machine using only the password-manager copy of the key**.
3. `backup-drill.sh db` passes for real.
4. One manual weekly image, watched (game latency, disk, time), then `backup-drill.sh vm` for the prod image passes.
5. `backup-install-timers.sh` (only now), then deliberately skip one run and confirm the external dead-man's-switch alerts.
6. First scheduled runs succeed; the evidence log has a record of each gate.

## 10. Data protection

- **What the backups contain:** player personal data (Steam IDs, Discord IDs, chat and character data) and server secrets.
- **Why and how long:** operational recovery only; 30 daily and 12 monthly sets on OneDrive, three weekly images on the desktop share.
- **Erasure requests:** a player's data is removed from the live database when they ask; it expires from backups as the retention cycle rolls (at most 12 months), it is **not** selectively erased from historical backups, and **deletions made since a backup was taken must be re-applied after any restore**. State this in the server's privacy notice.
- **Where:** a dedicated Microsoft account, with the OneDrive region recorded by the operator. The account has a named owner and an alternate with recovery access.

## 11. Network paths (Requirement 23)

| Path | From to | Protocol | Notes |
|---|---|---|---|
| Pull | hypervisor to dune-prod | SSH 22, restricted key, pinned host key | can only run `status`, `set`, `newest-db`, `dump-now` |
| Share | hypervisor to desktop | SMB 3.1.1 with sealing, TCP 445 | automount, `soft`; one router rule if inter-VLAN |
| Off-site | hypervisor to Microsoft | HTTPS: `login.microsoftonline.com`, `graph.microsoft.com`, `onedrive.live.com`, `*.sharepoint.com` | outbound only |
| Alerts | hypervisor to Discord and the heartbeat service | HTTPS | outbound only |
| Drill | hypervisor to dune-dev | SSH 22 | throwaway container only |
