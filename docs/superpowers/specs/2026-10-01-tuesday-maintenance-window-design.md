# Tuesday maintenance window: backup, update, verify (design v1)

Status: DESIGN, not built. As of 2026-10-01. Operator decisions are in section 2; open decisions in section 9.
Related: `2026-09-29-backup-strategy-design.md`, `docs/08-backup-runbook.md`, README Requirements 7, 20, 32.

## 1. Goal

One weekly maintenance window, **Tuesday 00:30-04:15 local**, that replaces the separate Sunday weekly and
that day's separate daily, so there is never a daily and a weekly backup on the same day. In order:

1. Disable the game stack's auto-patching for the window.
2. Back up: the daily set, then a **consistent** image of dune-prod (clean game stop, snapshot, game back up),
   then the other guests' images with no game impact.
3. After the backup is verified, check for updates and apply them if needed: the game build (`dune update`)
   and the console/stack (`dune self-update`).
4. Verify backup, update and server status, report to Discord, and always re-enable auto-patching.

## 2. Operator decisions (2026-10-01, in chat)

- Disable auto patching for the maintenance window (and re-enable after).
- Perform the backup as outlined: stop the game, take the snapshot, bring the game back, image continues.
- After the backup completes, check for an update and apply it if needed, **both console and game**.
- Verify backup, update and server status at the end.
- Tuesday was chosen because it is the usual patch day; the window gives a restore point before a patch.

## 3. Verified facts this design relies on

| Fact | Evidence |
|---|---|
| dune-prod runs stock upstream v1.4.42 (release archive, non-git), follows `Red-Blink/dune-awakening-selfhost-docker` | `dune version`, `dune self-update check` on 2026-10-01 |
| `dune self-update check` exits **100** when a newer release exists; `dune update check` exits 0 and prints "No update available" | same run |
| Game build and stack are updated by two separate commands (`dune update --yes`, `dune self-update install latest`) | `dune help` |
| Auto-update is enabled, hourly, applies updates, notifies players 30/15/10/5/1 min, does not wait for empty | `dune update auto status` |
| Auto-update is a systemd oneshot, `update.sh auto run`, hourly timer | `systemctl cat dune-awakening-auto-update.service` |
| vzdump snapshot mode captures the point in time in the first seconds; first progress line appeared 10 s after start | journal of the 2026-10-01 prod image (05:30:17 start, 05:30:27 first line) |
| The game restarts itself daily at 05:00 (warning 04:45); the in-guest DB dump runs 04:30 | guest timers, journal |
| A prod image takes about 47 minutes end to end (36 min copy, 11 min read-back) | 2026-10-01 run |
| `dune stop` runs `stop-all.sh` with `DUNE_MANUAL_STOP=1` (stops autoscaler, game servers, postgres) and **checks nothing about players**; `dune shutdown-protection` is only a host-shutdown hook (graceful stop when the VM shuts down), not an interlock | Core source `runtime/scripts/dune`, `stop-all.sh`, `shutdown-protection.sh` |

## 4. Sequence

All times are targets; the job is driven by a hard clock, not by durations.

| Phase | When | What | Abort rule |
|---|---|---|---|
| P0 preflight | 00:30 | Refuse unless: Tuesday window, share mounted+writable, free space >= 3x last prod image, thin pool headroom, game READY, `backup-doctor` has 0 FAIL, the previous run is not still holding the lock, `dune db backup` works. | Do **nothing**: do not disable auto-update, do not stop the game. Alert. |
| P1 notices | 00:30-01:00 | 30/15/5/1-minute maintenance warnings (in-game + a Discord note). | none |
| P2 pause patching | 01:00 | `dune update auto disable`; record that **this job** disabled it (so it re-enables only what it disabled). | If it cannot disable, stop here (before touching the game). |
| P3 daily set | 01:00 | `backup-daily.sh --tier daily` (dumps, secrets, host config). | Failure: stop the window and alert (the daily set is the baseline restore point). |
| P4 prod image | 01:05 | In-game "going down" notice. `dune stop` (clean). Start the vzdump of VM 101. **When the first vzdump progress line appears (snapshot captured, timeout 120 s)**, run `dune start`, wait for READY (timeout 15 min), in-game "back online" notice. | If the snapshot is not captured in 120 s: kill vzdump, `dune start` immediately, alert, skip the update phase. If READY is not reached: retry `dune start` once, then PAGE the operator (Discord ping); the backup continues. |
| P5 other guests | after P4 | Images of 102, 103, CT 104 (no game impact). | per-guest failure alerts; continue. |
| P6 verify backup | after P4 copy + read-back | Prod image read-back SHA matches, header decrypts, file listed in the share, audit-log entry. **Gate: updates only proceed if the prod image is verified OK.** | If not verified: skip updates (no restore point), alert. |
| P7 update | not before P6, **start by 03:30, never after 03:45** | `dune update check`; if a build is available: `dune update --yes`. `dune self-update check`; if exit 100: `dune db backup && DUNE_SELF_UPDATE_REPO=Red-Blink/dune-awakening-selfhost-docker dune self-update install latest` (README Req 32 form). One at a time, READY verified between. | First failure stops the phase; no retry loop; alert with the exact step and output tail. |
| P8 verify | after P7, by 04:10 | Section 6 pass criteria. | Any FAIL pages the operator. |
| P9 always | every exit path | `dune update auto enable` **if this job disabled it**; remove the maintenance marker; final report. | Re-enable failure is a page, not a warning. |

The weekly images for 102/103/CT104 may overlap the update phase only if P5 is finished first; the default is
sequential so the update never competes with a running image for disk or CPU.

## 5. Guards and failure handling

- **Always re-enable patching.** A trap on every exit path (normal, error, signal) re-enables auto-update when this job
  disabled it. A second line of defence: the hourly `backup-check` alarm pages when auto-update is disabled
  **outside** an active maintenance marker for more than 2 hours, so a dead job or a reboot mid-window cannot leave
  the server silently unpatched.
- **Maintenance marker.** A file the job holds for the window (`/var/lib/r740-backup/maintenance.active`, with the
  job's PID and start time). `backup-status.sh` shows it, other sessions must not touch the server while it exists
  (README Requirement 16), and the hard stop at 04:15 removes a stale one.
- **Hard clock.** Nothing starts after its latest-start time; P7 never starts after 03:45 and everything ends by 04:15,
  ahead of the 04:30 DB dump, 04:45 restart warning and 05:00 restart.
- **Catch-up protection.** The timer is persistent, so after a host outage it could fire late: the job refuses to run
  outside 00:30-04:15 on Tuesday (as the weekly already does).
- **Players online.** Default (pending decision 9.1): proceed after the 30/15/5/1 warnings. `dune stop` is clean.
- **Never loops.** One retry of `dune start`, no retry of updates.
- **Guard** (existing `backup-guard.sh`) stays active, but is suspended during P4's deliberate stop and
  P7 (the game is intentionally not READY then); the job resumes it only after READY.

## 6. Verification (step 4) pass criteria

| Area | Pass when |
|---|---|
| Backup | Read-back SHA matches; header decrypts with the public-key check; image listed on the share with the right size; daily set present; audit log has `image_ok` for 101 (and 102/103/104 if run). |
| Update | Versions before and after recorded (`dune version`, build ID); if nothing was available that is reported as "no update needed", not as success; console answers (HTTP 200 on 8088); `dune doctor` has no new FAIL. |
| Server | `dune status` READY; all three Sietch partitions and the Overmap READY; public probe healthy; population readable. |
| Housekeeping | auto-update is enabled again; maintenance marker removed; no stray vzdump or staging files. |

The Discord report is one message: per-area PASS/FAIL, versions, image size and time, game downtime in minutes, and a
@mention only on failure.

## 7. Privilege and security

The backup pull key is restricted to read-only commands on prod. This job needs more: `dune stop`, `dune start`,
`dune update auto enable|disable`, `dune update check|--yes`, `dune self-update check|install latest` (with the
environment in the Req 32 form), `dune status`, `dune ready`, `dune doctor`, `dune db backup`. The gate script gains an
**allow-list of exactly these commands** with fixed arguments (no free-form arguments, no shell), every call is written
to the hash-chained audit log, and the key's `from=` restriction stays. This is a deliberate privilege increase and is
a design-audit item. README Requirement 32 forbids a **session** from self-updating prod; this job is operator-approved
automation, so Requirement 32 needs a written exception covering only this job and only upstream releases.

## 8. Rollout

1. Prod restore drill (boot-only) of the 2026-10-01 image. **Prerequisite:** the window's update step relies on it.
2. Build the orchestrator and gate commands with tests (sandbox runner only), including mutation checks for: the
   re-enable trap, the "do nothing on preflight failure" rule, the verified-image gate before updates, the hard clock.
3. Rehearse on dune-dev (stop, snapshot, start, update check; dune-dev has no players). Fix findings.
4. File and complete the Layer 2/3 audits; operator merges.
5. **First prod run attended** by the operator, with the timer enabled for one Tuesday only; then enable it permanently.
6. Retire the Sunday weekly timer; the daily keeps running on the other six days.

## 9. Open decisions

1. Players online at 01:00: proceed after the warnings (default assumed above) or wait for the server to empty (up to a limit)?
2. RESOLVED (2026-10-01): `dune shutdown-protection` does not gate `dune stop`; the job itself must read the population
   (`dune status`) and apply decision 1, because `dune stop` will stop the game regardless of players. `DUNE_MANUAL_STOP=1`
   leaves a manual-stop marker, so P4 must confirm `dune start` clears it (to be tested on dune-dev).
3. Should dune-dev and the bot VM be updated in the same window? Default no (dune-dev rests on the latest release by operator
   decision; the bot VM deploys through its own hook).
4. Tuesday 05:00 game restart: leave as is (it just restarts a patched game) or skip that one day?

## 10. Not in scope

Updating dune-dev or the bot VM; changing the game's 05:00 daily restart; off-site copy automation; the OneDrive tier.
