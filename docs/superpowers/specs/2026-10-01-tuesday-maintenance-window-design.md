# Tuesday maintenance window: backup, update, verify (design v2)

Status: DESIGN v2, not built. As of 2026-10-01. v2 resolves the Layer 1 audit (docs/superpowers/audits/2026-10-01-maintenance-window-layer1-audit.md, 41 items, 1 CRITICAL). Operator decisions: section 2a. Open decisions: section 9 (two).
Related: `2026-09-29-backup-strategy-design.md`, `docs/08-backup-runbook.md`, README Requirements 7, 20, 32.

## 0. OPERATOR AMENDMENT 2026-10-02 (supersedes every clock time below)

Operator (verbatim): "the weekly Tuesday maintance window starts at 0400 and goes until the backup is completed, with battlegroup restart aftwards."

- **Start 04:00 Tuesday local, no fixed end.** The window runs until the backup has completed, then the battlegroup is restarted. The old 00:30-04:15 window, the 01:00 stop, the 04:15 hard stop and the 04:25 READY deadline in the sections below are SUPERSEDED. Shift the countdown to T-30 03:30, T-15 03:45, T-10 03:50, T-1 03:59; stop at 04:00 (decision 9.1 otherwise unchanged).
- **Open-ended means the hard stop becomes a duration cap, not a clock time.** Proposed: a maximum window length (default 4 h, from the actual start, configurable) after which the safety timer on prod restarts the game and re-enables auto-update, and the operator is paged. An unbounded window with players locked out is not acceptable without a cap.
- **The game's own 05:00 daily restart (warning 04:45) falls inside the window.** It must be suppressed for the window (or the window must treat it as an expected event) so it cannot start the game mid-backup or trip the guard. Not yet designed; decision 4 below ("leave as is") no longer holds.
- **"Battlegroup restart afterwards" is read as a stop/start of the battlegroup once the backup finishes** (replacing the earlier "restart right after the snapshot" step). This changes the downtime profile: if the game stays down for the whole backup (about 47 min imaging for prod, longer with the daily set) the outage is far longer than the earlier design's roughly 5 minutes. OPEN QUESTION for the operator: (a) stop the game for the whole backup, or (b) keep the earlier snapshot-then-restart and treat "restart afterwards" as the post-update restart?
- **OPEN QUESTION: is the update phase (decision A) still part of the window?** The amendment mentions only backup and restart. Until answered, the update phase stays in the design after the backup and before the restart.
- **Restore-drill blackout** (`BK_DRILL_BLACKOUT`, currently 04:20-05:20) must be replaced by "Tuesday from 03:30 until the maintenance marker is gone", since the end is no longer a fixed time.
- The persistent-timer catch-up rule, the DST-change refusal, `backup-status.sh` window display, the tests' clock edges and the runbook's desktop-sleep setting (Never from 03:30) all move with the new start.

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

## 2a. Operator authorization, recorded verbatim (change record, 2026-10-01 08:08 PDT)

The operator's chat messages, quoted exactly (the first answered the design proposal; the second answered the list of
gaps and concerns). They are the standing authorization for this window, scoped to this job and to upstream releases
only (README Requirements 7 and 32 exceptions are drafted from them):

> "1) disable auto patching for the maintenance window 2) perform the backup as outlined. 3) Once backup has completed, check for update and apply if needed (both console and game) 4) verify backup/update/server statusgame status"

> "1) always latest 2) can this be done vi a ! command? 3) lets use dune-dev as a test bed 4) agreed 5) agree, real gaps - design/arch them, stef 4 agree/ the bot vm is a production env, dune dev is as the name suggest a dev env, its purpose is to test and be broken."

Later the same day the operator answered the release-trust question (decision 9.5) and the players-online question (9.1):

> "A) Correct, I was vague. latest trusted upstream release"

> "B) if after 30, 15, 10, 1 minute warning and players are online, proceed. They were given ample warning."

The first fixes "always latest" to mean the latest release that passes the trust policy in 9.5 (Option A).

Interpretation recorded with them (the operator did not restate these): (1) the update policy is **always the latest
upstream release, no pinning**; the compensating control is the verified pre-update image. (2) the privileged gate
install on prod is done by a script the operator runs with the `!` prefix. (3) every rehearsal runs on dune-dev.
(4) auto-update is always re-enabled. (5) the architectural gaps from the Layer 1 audit are designed, not deferred.
The bot VM (103) is production: images only, no automated change in this window. dune-dev is a dev environment that
may be broken on purpose.

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
| `dune start` clears the manual-stop marker (`rm -f manual-stop.env`); `dune stop` is the only thing that sets it | Core `runtime/scripts/dune:249,255` (architect review) |
| `dune stop` stops game servers, then RabbitMQ, then postgres with `docker stop --time 120` (clean); a failure leaves postgres running | Core `stop-all.sh:57-69`, `stop-postgres-container.sh` (DBA review) |
| Game servers are removed with `docker rm -f` (no grace); the console applies queued base/vehicle writes before postgres goes down | Core `recycle-world-game-servers.sh:90`, `stop-game-servers-for-db-writes.sh` |
| `update auto enable` writes defaults (notify `15,10,5,1`) unless given values; `disable` stops the service and removes the unit files | Core `update.sh:435-440,493,504-509` |
| The stack updater has no checksum or signature check; the env vars for API base, web base, token and repo are honoured; tar extraction has no member-path guard | Core `self-update.sh:110-112,531-536,1605-1629` |
| Only the `INFO: N%` vzdump line means the backup job has started (earlier INFO lines exist) | `backup-weekly.sh:320,340,351` |
| The existing guard counts "not READY" as a bad sample and interrupts its target after 3 | `backup-guard.sh:68-69,102-105` |

## 4. Sequence (v2)

Constants: window 00:30-04:15 local (America/Los_Angeles, pinned; the job refuses on a DST-change night),
countdown 00:30-01:00, **latest start** of P4 01:05, the update phase never starts after 03:45, **post-update READY deadline 04:25**,
everything else finished by 04:15. Marker file `/var/lib/r740-backup/maintenance.active` (PID, start time, phase).

| Phase | When | What | On failure |
|---|---|---|---|
| P0 preflight | 00:30 | Refuse unless **all** hold: Tuesday and inside the window; `backup-doctor` 0 FAIL; share mounted and a **write+fsync probe** succeeds; free space >= 3x the last prod image; thin pool headroom; game READY; **no `update.sh auto run` active and no staged pending update**; maintenance gate reachable; egress/DNS to Steam and GitHub resolve; previous run not holding the lock; no stale marker. | Do **nothing** (no patching change, no stop). Send "maintenance postponed" and page. |
| P1 notices | 00:30-01:00 | Window set of messages (section 10): 30/15/10/1-minute warnings in game (T-30 00:30, T-15 00:45, T-10 00:50, T-1 00:59; stop at 01:00); one Discord post "window started". Read the population (via `dune status`). | none |
| P2 pause patching | 01:00 | Gate verb `auto-disable`: **waits for the auto-update service to be inactive**, stores the live policy file (`update-auto.env`: notify minutes, wait-until-empty, apply) on prod, then `dune update auto disable`. Records "disabled by this job" and the stored policy hash. | Cannot disable: stop here, before touching the game. |
| P3 daily set | 01:00 | `backup-daily.sh --tier daily` under its own lock. | Failure: stop the window, alert (the daily set is the baseline restore point). |
| P4 prod image | 01:05 | (a) `dune db backup` (the **pairing dump**, timestamp recorded with the image). (b) Share liveness probe again. (c) "going down" notice (policy 9.1: proceed regardless of population). (d) `dune stop`; **require rc 0 and the `dune-postgres` container exited**, else `dune start` and abort. (e) Start vzdump of VM 101. (f) A background watcher waits for the first **`INFO: N%`** vzdump line (snapshot captured, timeout 120 s). (g) `dune start`, wait for READY (15 min), "back online" notice with the measured downtime. | Snapshot not captured in 120 s: kill vzdump, `dune start`, alert, skip the update phase. READY not reached: one more `dune start`, then PAGE; imaging continues. Postgres still running after stop: do not snapshot, `dune start`, page. |
| P5 other guests | after P4 | Images of VM 102 and CT 104. **VM 103 (the bot, production) is imaged only**, no other action. | Per-guest failure alerts; continue. |
| P6 verify backup | after the prod copy + read-back | Read-back SHA matches, header decrypts, file present with the right size, audit entry, pairing dump present with size and sha. **Gate: the update phase only proceeds if all of these hold.** | Skip the update phase, alert (no restore point). |
| P7 update | not before P6; start by 03:30, never after 03:45 | (a) `dune db backup` again (pre-update dump; gate on size and sha). (b) `dune update check`: if a build is available, `dune update --yes`, wait READY. (c) The stack check (exit **100** = update available, 0 = current, any other exit = "check failed" alert and no install); apply only if the release passes the trust policy (9.5) and can finish before 04:15: gate verb `selfupdate-apply` (fixed environment, repo pinned), wait READY. Per-step timeout 20 min, no retries. | First failure stops the phase; alert with the step and the redacted output tail. |
| P8 verify | by 04:10 (READY deadline 04:25) | Section 6 pass criteria; the public probe retries for 5 min after READY (the tunnel may flap). | Any FAIL pages the operator. |
| P9 always | every exit path | **Game-up guarantee** (if this job stopped the game and it is down: `dune start`, wait, page if it fails); `auto-enable` **restores the stored policy values** and verifies equality; remove the marker; final Discord report (PASS/FAIL lines first). | Re-enable or start failure is a page, never a warning. |

## 5. Guards and failure handling

- **Game-up guarantee.** The EXIT trap (normal, error, TERM, INT, HUP, TSTP, timeout) brings the game back if this job stopped it
  and then re-enables patching if this job disabled it, in that order. SIGKILL and a host reboot cannot run a trap, so:
  (1) the hourly `backup-check` alarm pages when the game is down or auto-update is disabled **while no live marker exists**,
  or while a marker is older than the window, and (2) the maintenance gate arms a **transient systemd timer on prod at the
  hard stop (04:15)** that re-enables auto-update and starts the game if it is down, independent of the orchestrator.
- **Cancel semantics.** `systemctl stop <maintenance unit>` is the cancel: the trap runs, the game is brought up, patching
  is re-enabled, then a page says what was interrupted. Documented per phase in the runbook (cancelling in P7 reports a possibly
  half-applied update and tells the operator to run `dune doctor`).
- **Guard integration.** `backup-guard.sh` gains `--pause-file`: the orchestrator holds the file during P4 (stop to READY) and P7;
  the guard resumes only after READY and a fresh clean sample. The guard is not started before P0 passes.
- **Share loss mid-image.** The existing stall watchdog (300 s) kills vzdump (which releases the snapshot) and pages; the window
  documentation requires the desktop's sleep and updates to be inhibited 00:30-04:15 (an operator setting, listed in the runbook).
- **Concurrency (Req 16).** The maintenance gate refuses **any** mutating verb that does not carry the job's current token while
  the marker exists; `backup-status.sh` shows the window; sessions must not touch the server. A stale marker (dead PID,
  /proc start-time mismatch, older than 4 h) is removed at the next P0 or at the hard stop.
- **Never loops.** One retry of `dune start`, no retry of updates. No phase starts after its latest-start time.
- **Catch-up protection.** Timers are persistent but the job refuses outside Tuesday 00:30-04:15 (as the weekly does).

## 6. Verification (step 4) pass criteria

| Area | Pass when |
|---|---|
| Backup | Read-back SHA matches; header decrypts (public-key check); image listed on the share with the expected size; daily set present; pairing dump present (size, sha); audit log has `image_ok` for 101 (and 102, 104 if run). |
| Update | Versions before and after recorded (`dune version`, build ID); "no update needed" is reported as that, not as success; console answers HTTP 200 on 8088; `dune doctor` has no new FAIL; patching policy equals the stored policy. |
| Server | `dune status` READY; all three Sietch partitions and the Overmap READY; public probe healthy (5-minute retry); population readable. |
| Housekeeping | Auto-update enabled again with the original values; marker removed; no stray vzdump or staging files; transient safety timer cancelled. |

The Discord report is one message, PASS/FAIL lines first (1900-character cap), then versions, image size and time, measured game
downtime, and a @mention only on failure. Output tails are redacted (`bk_redact` gains a `dak_` rule).

## 7. Privilege, security and the README changes

**Separate maintenance key.** The read-only pull key and its gate are unchanged. A new key `maint_ed25519` and a new gate
script on prod, with `command=`, `restrict`, `no-pty`, `from=192.168.68.127` and a rotation date.
The gate is fixed-word and zero-argument; every verb runs under `env -i` with a fixed PATH:

| Verb | Runs |
|---|---|
| `status`, `ready`, `doctor`, `version`, `auto-status`, `update-check`, `selfupdate-check` | read-only |
| `db-backup` | the database backup command |
| `auto-disable` / `auto-enable` | store/restore `update-auto.env`, then disable/enable auto-update (waits for the service to be inactive) |
| `stop` / `start` | the game stop / start commands |
| `update-apply` | the game build update, non-interactive |
| `selfupdate-apply` | the stack update to the latest release with the repo variable set to `Red-Blink/dune-awakening-selfhost-docker` and the API and web bases hard-coded to GitHub, preceded in the same verb by a database backup chained with `&&` (README Requirement 32 form) |

Mutating verbs (`db-backup` excepted) work **only while** the marker exists, is younger than 4 h, the time is inside Tuesday
00:30-04:15, and the previous phase's verb succeeded (a small state machine: the two apply verbs require
the verified-image flag from P6). **Write-before-act:** the gate (and the orchestrator) writes the audit record first and
refuses the verb if that write fails; records are mirrored to the share (`BK_AUDIT_SHIP_DIR`) and the gate logs verb and
source to syslog on prod. The broadcast key (`admin:broadcast`) is never widened; population is read via `dune status`.
The runbook credential table gains the announce key and the maintenance key with rotation dates (Requirement 27). No
provider configuration (Cloudflare, GitHub) is changed.

**README amendments, landed with this work (meta repo PR, operator merges):**
- Requirement 32 gets a written exception: this job, and only this job, may run the stack and game updates on dune-prod,
  unattended, in the Tuesday window, upstream releases only, subject to section 9.5 and the controls above. Sessions remain
  forbidden.
- Requirement 7 records a standing authorization for the scheduled stop of the live server (section 2a), scoped to this window.
- Requirement 16 states that the gate enforces the maintenance marker against sessions.

**Compensating controls for unattended change (SOC 2 CC8.1):** a verified pre-update image and pairing dumps, the audit
chain, a per-window evidence bundle (the hash-chained record plus the archived Discord report, **retained 7 years** per the
GRC program decision), a post-hoc operator review of each window within 24 h, and a first run that is attended.
A failed window is an incident logged in `INCIDENT-INDEX.md`.

## 8. Rollout and tests

1. **Prod restore drill** (boot-only plus a postgres query check) of the 2026-10-01 image with a **measured RTO**: a gate for the first run.
2. Capture **contract fixtures** read-only from dune-dev and prod (`dune status`, the update checks incl. the exit 100 case,
   `update auto status`, real vzdump logs), and test the parsers against them.
3. Build with tests under `scripts/run-backup-tests.sh` only. Required tests, in priority order: re-enable/game-up on every
   exit path (TERM, INT, HUP, TSTP, error, timeout) with positive and negative cases; the SIGKILL/reboot path via the alarm and
   the 04:15 safety timer; preflight-does-nothing (one test per refusal reason, each with an inverted twin); the verified-image
   gate (one test per way verification fails); the hard clock with an advancing time stub (03:29/03:30, 03:44/03:45, 04:15,
   Monday 23:59, Wednesday 00:30, a DST-change night); snapshot detection (first line, no line, warning-only line, crash before
   any line); start retry (fail once, fail twice, never READY); first-failure-stops-the-phase; the marker (PID reuse, stale,
   hard stop); gate near-misses (extra args, `;`, `$()`, missing env, a version other than `latest`) and audit-before-act; policy
   restore equals the stored policy. **Mutation procedure:** each guard is deliberately broken on a scratch copy and the matching
   test must fail.
4. **Rehearse on dune-dev** (the test bed; no players): real stop/start timing and READY, whether the first `INFO: N%`
   really coincides with the snapshot, game consistency after restart, auto-update disable/enable persistence, an hourly
   auto-update firing mid-window, real exit codes, the updater replacing running scripts, in-game notices, the manual-stop marker,
   persistent-timer catch-up, a host reboot mid-window. Players-online behavior cannot be rehearsed there.
5. Layer 2 and Layer 3 audits; operator merges.
6. **First prod run attended** (runbook section "first attended window": pre-flight, the watch command, the abort command),
   timer enabled for one Tuesday only; then permanent. The maintenance key and gate are installed by a script the **operator
   runs with the `!` prefix**. Retire the Sunday weekly timer; the daily keeps the other six days.

## 9. Decisions

1. **RESOLVED (operator, 2026-10-01), players online at 01:00:** after the 30, 15, 10 and 1 minute warnings, proceed with the stop even if players are online; no waiting for the server to empty. Quote: "B) if after 30, 15, 10, 1 minute warning and players are online, proceed. They were given ample warning." The population is still read and logged for the evidence bundle.
2. RESOLVED: `dune shutdown-protection` does not gate `dune stop`; `dune start` clears the manual-stop marker.
3. RESOLVED: dune-dev is the rehearsal test bed and not in the window; the bot VM (103) is production and is imaged only.
4. Tuesday 05:00 game restart: leave as is (it restarts a freshly patched game); the Tuesday notice says so.
5. **RESOLVED (operator, 2026-10-01), release trust for "always latest": Option A.** The operator clarified "always latest" means the *latest trusted upstream release*, quoted in section 2a. The trust controls below are therefore mandatory, not optional, and a release that fails any of them is skipped with an alert (never installed). Residual supply-chain risk (no upstream signature) is recorded as accepted, mitigated by the verified pre-update image and dump. Original analysis follows.
   (Original text:) The operator chose the latest upstream release. The operator chose the latest upstream release. The reviewers found that
   the stack updater performs no verification (no checksum or signature; a hostile or hijacked release would run as root-equivalent
   code on prod, unattended). Option A (recommended): keep "always latest" with controls: only a published, non-draft,
   non-pre-release GitHub release from `Red-Blink/dune-awakening-selfhost-docker` whose tag matches `^v[0-9]+\.[0-9]+\.[0-9]+$`,
   **at least 24 hours old**, same major version as the installed one, with the verified pre-update image and dump as rollback.
   These reduce but do not remove supply-chain risk. Option B: the job only reports "update available" and the operator
   applies it attended. (Chosen: A.)

## 10. Messages (draft wording for review; plain facts, lore tone kept; title <= 80, body <= 500)

Window set (new keys; the existing set stays for images that do not stop the game):
- `maint-lead N`: "The Mentats Seal the Great Record" / "In N minutes the server goes down for the weekly recording and patching, about 5 minutes for the recording; patching may add more. Your progress is saved. This happens every Tuesday, 00:30-04:15 Pacific."
- `maint-down`: "The Sands Fall Quiet" / "The server is going down now for the weekly recording. Expected return in about 5 minutes."
- `maint-up`: "The Sands Stir Again" / "The server is back online. Downtime: M minutes. Patching, if any, follows later in the window."
- `maint-update-start`: "The Mentats Mend the Machinery" / "A patch is being applied. The server will restart; expect about X minutes of downtime."
- `maint-update-done`: "The Machinery Is Mended" / "Patching is finished and the server is online. Thank you for your patience."
- `maint-update-failed`: "The Mending Was Interrupted" / "Patching did not finish. The server is being checked; the operator has been notified."
- `maint-none`: "No Patch Today" / "The weekly recording is complete. No update was needed."
- `maint-postponed`: "The Recording Is Postponed" / "This week's maintenance did not run. The server stays up and nothing is needed from you."
- Each also goes to the community Discord (a pinned "every Tuesday 00:30-04:15 Pacific" notice plus a weekly post). The game's own auto-update warnings (30/15/10/5/1) do not fire while patching is paused; these replace them. The "about 5 minutes" figures are placeholders until measured on dune-dev.

## 11. Not in scope

Updating dune-dev or the bot VM (the bot VM is production: images only); changing the game's 05:00 daily restart; off-site copy
automation; the OneDrive tier; a cryptographic verification layer for upstream releases (an upstream change; a Core issue is to be
filed for the missing checksum/signature and the unguarded tar extraction).
