# R740 Backup Runbook

**Status:** written 2026-09-30, revised the same day after the Layer 2 audit, for design v2 (`docs/superpowers/specs/2026-09-29-backup-strategy-design.md`). **Nothing described here is deployed until the rollout in section 9 is complete**; until then the running game server has no off-box backup.

If you are here because something is broken, jump to **section 5 (alerts)** or **section 6 (restore)**.

## 1. What is protected, where it goes, how fresh it is

| Tier | Contents | Schedule | Copies | Freshness limit (alarm) |
|---|---|---|---|---|
| Database tier (optional, off in the lite profile) | newest official dump pair(s) | every 6h (04:45, 10:45, 16:45, 22:45) | desktop share | 8h |
| Daily set | recent dump pairs, `runtime/secrets`, `.env`, host config | 05:15 | desktop share (OneDrive optional) | 26h |
| Weekly images | full images of VM 101, 102, 103 and CT 104 | Sunday 01:00, no new image starts after 04:15 | desktop share | 8 days |

- Everything is encrypted with `age` before it leaves the hypervisor. **The hypervisor holds only the public key.** The private key lives in your password manager plus a second escrow.
- `market-bot-seed` dumps (a feature seed made every 15 minutes) are excluded. The authoritative restore point is the newest dump whose sidecar says `backup_origin: automatic` (the scheduled 04:30 job).
- **VM images are not the primary database source.** They are for rebuilding the whole server. The primary database source is a logical dump.
- **The share is the backup; the USB key is the off-site copy.** The desktop's `E:\r740\backups` folder is the only target the jobs write to. OneDrive is an optional second target that this installation does not use (`BK_RCLONE_REMOTE` empty). If the desktop is off or the share unreachable, the run **fails loudly** (there is no other copy), so the desktop has to be awake at 05:15 and Sunday 01:00-04:15 (set Windows sleep to Never when plugged in). You copy the share to a USB key yourself; see section 9b.
- Retention: database tier keeps 28 files and 1 per month for 1 month; daily keeps 30 files plus the newest of each of the last 12 months, on both targets. Weekly images: 3 per guest (1 for VM 102). Files are only pruned after the new copy has been verified, and only names with a plausible, not-in-the-future timestamp are ever counted or deleted.

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
| `scripts/backup-weekly.sh [--progress] [--verbose] [--only "ID ID"]` | Run the weekly images by hand (`BK_WEEKLY_FORCE=1` for a watched run outside the window). **Use `--progress` (`-p`) for a manual run: it prints a status line every 10 seconds (time elapsed, bytes written, speed, vzdump's own percent), so a long image never looks hung.** `--verbose` (`-v`) adds vzdump's log lines and each stage; `--only` images just the named guests. |
| `scripts/backup-check.sh` | Run the alarm by hand. |
| `scripts/backup-drill.sh pipeline\|db\|vm` | Restore drills (section 7). |
| `scripts/backup-install-timers.sh [--no-enable]` | Write and enable the timers. |
| `scripts/run-backup-tests.sh` | Run the test suite in the read-only sandbox (never run tests any other way on the hypervisor). |

### VM restore drill for guests without a guest agent (boot-only)

The drill can run an in-guest command only when the guest runs the QEMU guest agent. None of these guests do, so set `BK_DRILL_VM_CHECK_<id>=boot-only` for each VM (101, 102, 103) in `backup.env`. The drill then restores the image into a scratch VM on an isolated bridge (no uplink), starts it, and requires **all three**: it is running, it sent at least 5 packets on its isolated network port, and it **read at least 64 MiB from its disk** (a failed disk boot can still send packets from a firmware network-boot fallback, but it cannot read the disk). No command is run inside the guest, so this proves the image **decrypts, restores and boots**, not that a service inside works; the result is recorded as `mode=boot-only`. Thresholds: `BK_DRILL_MIN_PACKETS`, `BK_DRILL_MIN_DISK_READ_BYTES`. First real result (2026-10-01, bot VM image): restored 20 GiB in 41 s, booted, 13 packets, 473 MiB read. The host-device safety check refuses passthrough only (PCI, host USB, a serial/parallel port on a `/dev` path); Proxmox's virtual `serial0: socket` is fine.

### Watching a job

- **`scripts/backup-status.sh`** is a live, read-only dashboard (refreshes every 10 s; `--once`, `--interval N`): what the backup is doing, host disk and pressure numbers, the game's own status, and an OK/WATCH verdict. Safe to run during a backup and safe to stop at any time.
- **`tail -f /var/lib/r740-backup/weekly-progress.log`** follows the weekly job's progress lines (restarted for each run).
- Run the weekly job by hand with `--progress` so its own terminal shows a line every 10 seconds.
- **Measured on 2026-09-30 (dune-dev, 300 GB disk, 140 GB used): 47 minutes end to end** (19 min of data at about 70 MB/s, 16.5 min sweeping empty disk with no output, 10.5 min verified read-back), 76 GB compressed. Long stretches with no output are normal; the hang watchdog treats vzdump's progress log as a sign of life.

### Stopping a job safely

Ctrl-C, Ctrl-Z, a `kill`, or closing the terminal **stops the whole job and everything it started** (the ssh pull, the `vzdump` image pipeline, a scratch VM or container in a drill), removes its partial file and exits. Ctrl-Z does not suspend a job: a suspended image would keep holding its snapshot. A deliberate Ctrl-C or Ctrl-Z raises no alert; a `kill` or timeout from outside does. Never stop a run with `kill -9` on a single process: use Ctrl-C, or `kill <PID of the backup-*.sh script>`.

### Protecting live players: the safety guard and in-game announcements

For an unattended image of a guest that hosts players (the prod game VM), run the weekly job with `--guard --announce` (or set `BK_WEEKLY_GUARD=1` / `BK_WEEKLY_ANNOUNCE=1`).

**Guard (`scripts/backup-guard.sh`).** Before the job starts it checks that the game reports READY (`dune status` over ssh), that disk pressure (PSI `io` avg10 <= `BK_GUARD_IO_PRESSURE_MAX`, default 30), disk busy (<= `BK_GUARD_DISK_BUSY_MAX`, default 95 %) and the thin pool (<= `BK_GUARD_POOL_MAX`, default 85 %) are healthy. If not, nothing starts and a "postponed" notice is sent. While the job runs a background sample every 10 seconds repeats the checks; **3 bad samples in a row (about 30 seconds)** stop the whole job cleanly, send a "halted" notice and alert Discord. `backup-guard.sh --once` runs the checks once and prints `OK` or the reason.

**Announcements (`scripts/backup-announce.sh`).** The job warns players in-game through the console's broadcast API: **30, 15, 5 and 1 minute before the start** (`BK_ANNOUNCE_LEAD_MINUTES`), a notice when it starts, **a notice every 30 minutes** while it runs (`BK_ANNOUNCE_EVERY_MIN`), and a closing notice. Only guests listed in `BK_ANNOUNCE_GUESTS` (default `101`) are announced. The countdown happens inside the job, so a run for 05:30 must be started at 05:00. Announcements are best-effort: a failed broadcast is logged and never stops a backup.

- `backup-announce.sh print` shows every message exactly as players will see it (sends nothing).
- `backup-announce.sh status` says whether announcements are configured.
- `backup-announce.sh send KEY [N] --yes` sends one real banner to all online players; it refuses without `--yes`.

**One-time setup.** In the console (Settings -> API Keys) create a key named `backup-announce` limited to the single action `admin:broadcast`. Save it in a root-only file (mode 600) and set `BK_ANNOUNCE_URL` and `BK_ANNOUNCE_KEY_FILE` in `backup.env`. The key can broadcast text and nothing else; revoke it in the same page at any time. Keep the key out of notes and chat.

**The game restarts itself every day at 05:00 (warning 04:45).** On dune-prod the timer `dune-awakening-scheduled-restart.timer` stops and restarts the whole battlegroup (the game is back by about 05:05-05:10). A backup job that is running then would see the game not READY and the guard would stop it after 3 bad samples, and players would be told "no backup restart" while the game restarts anyway. So **imaging must start after about 05:15, with its countdown also after the restart** (the 2026-10-01 run started at 05:00 and imaged from 05:30, which worked, but its first two warnings went out during the restart). Check the real schedule before choosing a time: `ssh dune@192.168.20.10 systemctl list-timers dune-awakening-scheduled-restart.timer`.

**Scheduling a one-off prod image.** Use a transient timer that runs a pinned copy of the scripts, so later edits cannot change what runs:

```
git archive <commit> scripts | tar -x -C /root/.local/share/r740-backup-pinned/<commit>
systemd-run --unit=r740-prod-image-YYYYMMDD --on-calendar='YYYY-MM-DD 05:00:00' \
  --setenv=HOME=/root --setenv=BK_WEEKLY_FORCE=1 --property=Nice=10 --property=IOSchedulingClass=idle \
  /usr/bin/bash /root/.local/share/r740-backup-pinned/<commit>/scripts/backup-weekly.sh --only 101 --progress --guard --announce
```

Cancel before it starts with `systemctl stop <unit>.timer`; stop it mid-run with `systemctl stop <unit>.service`. A transient timer does not survive a host reboot.

## 3. Definition of P1

A **P1** is: a backup tier is stale or failing, a restore drill failed, an image or database set is DEGRADED (one target missing), or the alarm could not deliver its alert (exit code 5). It is delivered by a Discord message that pings `BK_ALERT_MENTION` **and** by the external dead-man's-switch going silent-or-failed. Every failure alert from these scripts is a P1: treat it as "there is currently less backup than there should be" and fix it the same day. An overdue drill (35 days for the database, 100 for VM/CT and escrow) is also raised by the alarm.

## 4. Setup (first time, in order)

Every step is safe to repeat. Stop at any step that does not end as described.

1. **Prerequisites on the hypervisor:** `apt-get install -y age jq zstd cifs-utils bats shellcheck` (plus `rclone` only if you use OneDrive). Confirm `age --version` and `rclone version` run. (Install from the distribution; do not download binaries.) Create the staging directory: `mkdir -p -m 700 /mnt/backup-stage` (on a filesystem with room for several times one daily set).
2. **Desktop share.** On the desktop create a dedicated local account (for example `r740backup`) with write access to one folder only, and take periodic desktop-side snapshots of that folder (Windows shadow copies or filesystem snapshots): this is what protects the history if the hypervisor is ever compromised, so agree a frequency and retention and check the snapshots exist. **The private age key must never be placed on this share** (its snapshots would keep it). Record the desktop's IP, VLAN, and whether it is wired. On the hypervisor put the credentials in `/root/.config/r740-backup/smb-credentials` (mode 0600, lines `username=` and `password=`), and add to `/etc/fstab` (use the desktop's **IP address**; NetBIOS names do not resolve here):
   `//DESKTOP-IP/share /mnt/desktop-backup cifs credentials=/root/.config/r740-backup/smb-credentials,vers=3.1.1,seal,soft,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=60 0 0`
   then `systemctl daemon-reload && ls /mnt/desktop-backup && mountpoint /mnt/desktop-backup`. `seal` encrypts in transit (the doctor warns if it or `vers=3.1.1` is missing). **Do not add `cache=none`**: it roughly halves write speed (measured 61 vs 111 MB/s). With the default caching, a file just written is still in the host's memory cache, so the scripts **flush it to the desktop and evict it from the cache, and verify the eviction, before every read-back** (falling back to a direct read if the cache cannot be dropped); that is what keeps the verification honest. `cache=loose` must not be used. If the desktop is on another VLAN, the router needs one rule: hypervisor `192.168.68.127` to the desktop on TCP 445 only; the desktop never initiates connections to the hypervisor.
3. **OneDrive: skipped in this installation.** Leave `BK_RCLONE_REMOTE` empty in `backup.env` (an older copy of the template may have a value: add a later line `BK_RCLONE_REMOTE=`). If you ever want a cloud copy, use a **separate, backup-only Microsoft account**, never your personal one: a full-access token on this host would expose everything in that account. Create an `rclone` `onedrive` remote plus a `crypt` remote wrapping it, set `BK_RCLONE_REMOTE=onedrive-crypt:r740`, `rclone mkdir` that folder, and re-run the doctor.
4. **Keys.** Use a **RAM folder** (`mkdir -m 700 /dev/shm/keyhandoff`) or a removable disk as the hand-off directory, then: `scripts/backup-key.sh generate --handoff-dir /dev/shm/keyhandoff`. The script refuses a hand-off directory on the backup share or on any network filesystem. The private key is written **only** to that directory (never printed). Move it into the password manager **and** a second escrow (for example a sealed printout in a safe), **Save it BEFORE you verify, and do not close the terminal until it is saved** (the script cannot tell where a pasted key came from, so a verify that passes does not prove it was saved: on 2026-09-30 a verify passed from the terminal's own output and the key was never stored). Then prove the SAVED copy: open the password-manager entry, copy the key out of it (not from the terminal) into a file, and run `scripts/backup-key.sh verify --identity thatfile`. It must print `escrow verified`. Only then `shred -u` the hand-off files (and unmount a removable disk). `generate` also creates `backup.env` from the template and fills in `BK_AGE_RECIPIENT`.
5. **Pull gate on dune-prod.** On dune-prod, find the real home directory and login user (`echo $HOME; id -un`), create the folder (`mkdir -p ~/bin`), and copy `scripts/dune-prod/r740-backup-gate.sh` into it (`chmod 755`). The `authorized_keys` line below needs the **absolute** path (assumed `/home/dune/bin/...`; use the real one, or the forced command silently fails). On the hypervisor: `ssh-keygen -t ed25519 -N "" -f /root/.config/r740-backup/backup_ed25519`. On dune-prod append to `~/.ssh/authorized_keys` (one line, using the **public** key): `from="192.168.68.127",restrict,command="/home/dune/bin/r740-backup-gate.sh" ssh-ed25519 AAAA... r740-backup`. Pin the host key: on the hypervisor `ssh-keyscan -t ed25519 192.168.20.10 > /root/.config/r740-backup/known_hosts`, then compare the fingerprint (`ssh-keygen -lf` of that file) with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` **on dune-prod** before trusting it. Test: `ssh -F /dev/null -i /root/.config/r740-backup/backup_ed25519 -o UserKnownHostsFile=/root/.config/r740-backup/known_hosts dune@192.168.20.10 status`. Do the same pinning for the drill host: `ssh-keyscan -t ed25519 192.168.21.10 > /root/.config/r740-backup/known_hosts_dev` and compare its fingerprint the same way; the drill uses root's key to reach dune-dev, so authorise that key there deliberately and note it in the credential inventory.
6. **Six-hourly game dumps.** On dune-prod run `dune db auto enable 04:30 7 6` (04:30, keep 7 days, every 6 hours) so a fresh official dump exists before each tier run. Afterwards confirm with `ls -lt runtime/backups/db | head` that a new `automatic` dump appears every six hours.
7. **Dead-man's-switch (optional in this installation).** Without it, if this host or the alarm itself dies nothing tells you, and Discord alerts are the only signal; set `BK_HEARTBEAT_REQUIRED=0` to accept that (the doctor then warns instead of failing). Create two checks at an external Healthchecks-style heartbeat service (a failure is reported by appending `/fail` to the ping URL; a service that does not support that will only alert on silence), one for the backup jobs and one for the alarm. Put each ping URL in a 0600 file (`deadman-url`, `deadman-check-url`) under `/root/.config/r740-backup/`. Configure the service to alert you when a heartbeat is late. Create the Discord webhook the same way (`discord-webhook`, 0600).
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
| `smb` | the share is not mounted, dropped, or the copy did not verify. **With no OneDrive this is a failure: no backup was written.** (With OneDrive configured it is a DEGRADED run instead.) | desktop asleep or off (set Windows sleep to Never when plugged in); share and password; `mountpoint /mnt/desktop-backup`; re-run the tier |
| `upload` | (OneDrive only) upload failed | token expired/revoked, quota, network |
| `verify-transfer` | (OneDrive only) the cloud copy does not match | re-run; if it repeats, suspect the account or network |
| `prune` | retention could not run | share/remote state; nothing valuable is deleted before that target's new copy verified |
| `summary` (weekly) | one or more guests failed; the message names each guest and why (`stalled`, `no time left`, `read-back hash differs`, ...) | the named guest; the other guests still ran |
| `check` | the alarm found a stale, missing or undersized archive, a missing share, or an overdue drill | read the listed findings |

- **Alarm exit code 5** means the Discord alert could not be delivered (a deleted or rejected webhook counts). The dead-man's-switch was still pinged, and the alarm retries on its next run instead of staying quiet; fix the webhook first.
- **Desktop asleep or off** is the most likely cause of an `smb` failure. The alarm reports a stale archive an hour later. Wake it, then re-run the tier by hand (`scripts/backup-daily.sh --tier daily`).
- **Weekly "output stalled"**: the share or network hung while an image was being written; the run aborted the image so the live VM is not held waiting on it. Check the desktop and the network, then run the watched manual weekly.
- **Weekly "outside the maintenance window"** on a catch-up after downtime is expected and harmless; run a watched manual run: `BK_WEEKLY_FORCE=1 scripts/backup-weekly.sh`.
- Where to look: `journalctl -u r740-backup-<name>`, `/var/lib/r740-backup/audit.log` (`backup-doctor.sh` verifies its hash chain) and `evidence.log`.

## 6. Restore (works from a bare Linux box)

You need: the **private age key** (password manager), `age` and `zstd` installed on the machine you restore from, and the backup files: from the desktop share or from your USB key (the same folder layout: `daily/`, `vm/`).

**Never run two servers with the same battlegroup identity at once.** Before restoring a server, make sure the old one is off.

### 6a. Get and open a set

**Which key?** The **PRIVATE** key: one line starting `AGE-SECRET-KEY-1` (from your password manager or printed copy). The public key (`age1...`) cannot open anything, and the script says so if you give it that one.

Copy the set you want (from the desktop share `daily/` folder or from your USB key) and the script `scripts/backup-decrypt.sh` to the machine you are restoring on (any Linux box with `age` installed; nothing else from this repository is needed), then:

```bash
./backup-decrypt.sh daily-YYYYMMDD-HHMMSS.tar.age
# it asks you to paste the private key line (nothing is shown while you paste),
# decrypts, refuses unsafe contents, unpacks into ./restored-<name>/, verifies every
# file against MANIFEST.sha256 and prints the restore point. Use --key FILE to read the key
# from a file instead, and --out DIR to choose the folder (it must be empty or new).
```

The last lines tell you the **restore point**: the newest automatic database dump, at `<folder>/prod/<authoritative>`.

### 6b. Database only (server is up but data is damaged)

1. Get the players out. **Do not run `dune stop` or `dune db stop` first**: `dune db restore` needs the Postgres container running and stops the game services itself.
2. Copy the dump and its `.yaml` from `prod/<authoritative>` into `runtime/backups/db/` on the server (for example with `scp`).
3. Make sure `runtime/secrets/funcom-token.txt` on the server is the token that belongs to the backup's battlegroup; the restore refuses to adopt the backup identity otherwise. (After a rebuild, restore `prod/runtime/secrets` and `prod/.env` from the set first.)
4. Restore with the adopt flag: `dune db restore runtime/backups/db/<file>.backup --adopt-backup-battlegroup`. `--keep-current-battlegroup` would hide every existing character in-game; do not use it for recovery. It asks for confirmation and takes a safety backup of the current database first; **if the database is too damaged for that safety backup to succeed, add `--no-safety-backup`.** (The console's Backup/Restore page can do the same import and restore if the command line misbehaves.)
5. `dune start`, then `dune status` until READY.

### 6c. One VM or container

**Weekly images exist only on the desktop share and whatever you copied to the USB key.** If both are gone, rebuild the guest from the deployment kit and restore the database from a daily set as in 6b.

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

## 9b. The off-site copy: your USB key

The jobs write only to the desktop share. The off-site copy is one you make by hand:

1. **Weekly (or after any big change):** plug the USB key into the desktop and copy the contents of `E:\r740\backups` to it: at least the `daily` folder (small) and, if it fits, the newest files in `vm`. Everything in there is already age-encrypted, so a lost key exposes nothing without the private key.
2. Use **two keys** and alternate them, keeping the one not in use away from the house. After copying, check the newest `daily-*.tar.age` on the key has today's (or yesterday's) date and a size close to the one on the share.
3. **Do not** put the private age key on the same USB key as the backups.
4. Once a quarter, prove a copy is usable: on any machine with `age` and the private key from your password manager, decrypt the newest `daily` file from the key and run `sha256sum -c MANIFEST.sha256` (section 6a).

The alarm cannot see the USB key, so nothing reminds you: put a recurring reminder in your calendar.

## 10. Data protection

- **What the backups contain:** player personal data (Steam IDs, Discord IDs, chat and character data) and server secrets.
- **Why:** operational recovery only. Controller: the server operator (contact details go in the server's privacy notice). No third-party processor is involved unless you enable the optional OneDrive target.
- **Where:** the desktop share `E:\r740\backups` (encrypted files, plus any snapshots the desktop takes), **your USB keys** (encrypted copies: label them and keep them somewhere safe), the drill container's memory on dune-dev during a database drill, and the escrow locations of the decryption key.
- **How long:** daily sets 30 days plus the newest of each of the last 12 months, so **a set can be kept for up to about 12 months, and longer where months are missing**; weekly images about 3 weeks; **copies on USB keys and in any desktop snapshots are kept until you delete them**, so delete old USB copies on a schedule.
- **Erasure requests:** a player's data is removed from the live database when they ask; it is **not** selectively erased from existing backups and expires as the cycle rolls. **Deletions made since a backup was taken must be re-applied after any restore**: keep a dated erasure log (a private file, ids only) and apply it to the restored database before players are let back in. State this, and data-subject rights and breach handling, in the server's privacy notice.

## 11. Network paths (Requirement 23)

| Path | From to | Protocol | Notes |
|---|---|---|---|
| Pull | hypervisor `192.168.68.127` to dune-prod `192.168.20.10` | SSH 22, restricted key with `from=`, pinned host key | can only run `status`, `set`, `newest-db`, `dump-now` |
| Share | hypervisor to desktop | SMB 3.1.1 with sealing, TCP 445 | automount, `soft`; one router rule if inter-VLAN |
| Off-site | (not used) | | | OneDrive is optional and disabled; the off-site copy is the USB key |
| Alerts | hypervisor to Discord and the heartbeat service | HTTPS | outbound only |
| Drill | hypervisor `192.168.68.127` to dune-dev `192.168.21.10` | SSH 22, pinned host key | throwaway container only |

## 12. Known limits and accepted risks

- **A root-compromised hypervisor can delete or alter the backups on the share.** The jobs hold write and delete rights there (they prune). What limits the damage: **your USB key copies, which are offline and out of reach of the hypervisor** (this is the most valuable protection, so do section 9b regularly), the desktop's own snapshots if you set them up, the off-host copy of the audit log, and the fact that the private key is not on the host. There is no immutable target. Accepted (decision D3).
- **The audit log detects edits, reorders and mid-log deletion, not removal of its newest records**; the shipped copy (`BK_AUDIT_SHIP_DIR`) is what exposes a truncated tail. The evidence log is a plain local file that root can rewrite; drill and escrow currency are also recorded in the chained log.
- **The private age key is kept on the hypervisor's disk** (`/root/.config/backup-age-key-<suffix>.txt`, mode 600) in addition to the password manager and the paper copy. **Accepted risk, operator decision 2026-10-01:** the host is reachable only by SSH and physical access, and only the game ports are exposed. The cost: anyone who gets root on this host can decrypt the backups on the desktop and the USB keys. The benefit: restore drills can be run (or later automated) without anyone fetching the key. Revisit if the host ever becomes reachable from outside the closed network.
- **Images are crash-consistent**, not application-consistent; the logical dump is the trusted database source.
- **Weekly image speed (measured 2026-09-30).** Three things limited it, all fixed: `vzdump --bwlimit` caps the rate it *reads* the source (a 50 MiB/s cap gave only ~12 MB/s of compressed output); small writes to a `cache=none` mount gave 25 MB/s; plain `sha256sum` read-back gave 42 MB/s. Now: read cap 150 MiB/s (`BK_VZDUMP_BWLIMIT_KIB=153600`); 4 MB writes with `oflag=nocache conv=fdatasync` to a default-cache mount (about 110 MB/s, the 1 Gb line rate, with only a few MiB of dirty memory; without `nocache` a 4 GiB write left 4 GiB dirty and stalled at the final flush); read-back in 4 MB blocks after a verified cache eviction (about 117 MB/s). The remaining limit is vzdump's own compression (about 66 MB/s output), so a big guest (about 140 GB used) should take roughly 40 minutes and the whole weekly run about 1.5 hours. **Watch game latency during the first prod image and lower the read cap if needed.**
- The host config set includes `/etc/pve` (with its private keys) and the Cloudflare tunnel credentials, protected by the same single age key.
