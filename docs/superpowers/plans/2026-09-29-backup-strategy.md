# R740 Backup Strategy Implementation Plan (v2)

> **Executor rules:** implement task by task; **all code and tests run only through `scripts/run-backup-tests.sh`** (sandbox: `/usr` and `/etc` read-only); no subagent executes code — reviewers are read-only. Every change to the live host is a numbered rollout step (Task 12) and waits for the operator.

**Goal:** scheduled, encrypted, off-box backups of the game DB, secrets, host config and all VM/CT images that are proven restorable, cannot fail silently, and cannot harm the live game server.

**Spec:** `docs/superpowers/specs/2026-09-29-backup-strategy-design.md` (v2). **Audit:** `docs/superpowers/audits/2026-09-30-backup-layer1-audit.md` (issues #121–#132). **Operator decisions D1–D7:** accepted (defaults).

**Stack:** bash, `age` (public-key only on the host), `rclone` (crypt), `vzdump --stdout`, `mount.cifs`, systemd timers, `bats`, `shellcheck`, `jq`, `curl`.

## Execution safety (INC-2026-09-29)
1. Tests only via `scripts/run-backup-tests.sh` (private mount namespace, `/usr` and `/etc` read-only). Never a hand-written harness, never a bare `bats` on the hypervisor.
2. `tests/backup/helper.bash` refuses unsafe paths (`assert_safe_tmpdir`); do not weaken it. The library refuses to run under bats unless its state dir is under `BATS_TEST_TMPDIR` (Task 1).
3. `TMPDIR` is the session scratchpad, never `/tmp`.
4. After any work session on the host, `dpkg -V` must show no modified binaries.
5. Reviewers are read-only and execute nothing.

## Global constraints
- Encryption: `age -r <recipient>` only; the host never holds the private key during unattended runs; fail closed (no plaintext output) on a missing or malformed recipient.
- Schedule/RPO: DB tier every 6h (offset after the 04:30 dump), daily set 05:15, weekly window Sunday 01:00–04:15 with a hard stop at 04:15.
- Retention: OneDrive 30 daily + 12 monthly; desktop 3 weekly each of 101, 103, CT 104 and 1 of 102; prune never removes the last verified-good set.
- Archive content: official `.backup` + `.backup.yaml` pairs (authoritative file named in a manifest), `runtime/secrets`, `.env`, host config; **exclude** `market-bot-seed` dumps (except the newest) and `/root/.config`.
- Weekly images stream `vzdump --stdout --compress zstd | age | SMB` — no plaintext image and no staging copy; `ionice -c3`, `nice`, `--bwlimit`, rclone `--bwlimit`/`--transfers 2`.
- Alarms: artifact-based (newest remote object + newest SMB file, size floor, mtime), a daily OneDrive token probe, an external dead-man's-switch ping on every success, a restore drill overdue after 35 days, daily 26h / weekly 8d staleness.
- Secrets: redacted from logs and alerts; never in argv; credentials in root-only files under `/root/.config/r740-backup/`.
- Repo rules: branch + PR; `shellcheck -S warning` clean on `scripts/*.sh` and `tests/*.sh`; `tests/no-personal-identifiers.sh`; no Claude co-author trailer.

## Tasks

### Task 1 — Library v2 (`scripts/backup-common.sh`, `tests/backup/common.bats`)
Keep the reviewed v1 functions (config, redact, notify, lock, free-space, mounted, age-encrypt, prune, state). Add and test:
- `bk_require_test_isolation`: under bats, abort unless `BK_STATE_DIR` is under `BATS_TEST_TMPDIR`.
- `bk_valid_vmid`, `bk_safe_rm_under ROOT PATH` (refuse empty/outside-root), `umask 077` defaults.
- Manifest: `bk_manifest_add FILE`, `bk_manifest_write OUT` (sha256, size, time).
- `bk_verify_copy SRC DST` (bit-exact); `bk_dead_man_ping` (URL from a root-only file; failure returns a distinct code and never aborts the job); `bk_alert STAGE ERROR RERUN_CMD` (job, stage, redacted error, re-run command, runbook link); `bk_audit_log` (append-only JSON line).
- Remove any use of a private key from library paths.
**Acceptance:** all v1 tests still pass; new tests cover each function including negative cases (empty path, outside-root delete, mismatching copy, dead-man URL unreachable, webhook failure).

### Task 2 — Key tooling (`scripts/backup-key.sh`, replaces `backup-init-keys.sh`)
- `generate --handoff-dir DIR`: create the keypair in a RAM-backed 0700 directory, write only the **recipient** to `backup.env`, copy the private key to the hand-off directory (the desktop share) for the operator to move into the password manager, **shred the RAM copy**, print only the recipient/fingerprint. The private key is never printed.
- `verify --identity FILE`: encrypt a canary to the configured recipient and decrypt with the supplied identity; on success append `escrow verified <date> <fingerprint>` to the evidence log; never persist the identity.
- `fingerprint`: print recipient and its creation date.
**Acceptance:** tests prove the private key never appears on stdout/stderr or persistently on the host, the RAM copy is removed, verify fails on a wrong key and passes on the right one, and the config never contains an identity path.

### Task 3 — Restricted pull gate for dune-prod (`scripts/dune-prod/r740-backup-gate.sh`)
A script installed on dune-prod and bound to the backup SSH key via `restrict,command="…"`. It reads `SSH_ORIGINAL_COMMAND` and allows only: `set` (tar of official dump pairs + `runtime/secrets` + `.env`), `newest-db` (newest official pair), `dump-now` (runs `dune db backup`), `status`. Anything else exits non-zero. Includes the **completion gate** (newest official dump newer than the scheduled dump time and above a size floor) and excludes `market-bot-seed` except the newest.
**Acceptance:** tests (against a fake repo dir) cover each subcommand, refusal of unknown/injected commands, exclusion rules, and the gate refusing a stale or tiny dump.

### Task 4 — DB tier and daily set (`scripts/backup-daily.sh --tier db|daily`)
Pull via the gate; pre-upload checks (`tar -tf`, `PGDMP` magic and non-zero size for every dump, manifest); tar; `age -r`; write to SMB via `.partial` then rename; upload to OneDrive; verify the transfer bit-exactly; write manifest and audit line; prune (verified-good set protected); dead-man ping; actionable alerts. The v1 hardening carries over: single-shot ERR alert, cleanup of partial/stale files, mount re-check before writing, host-config failure detection, lock, no plaintext left in staging.
**Acceptance:** tests for success, every failure stage, truncated/tampered pull, wrong recipient, partial upload, full disk, unmounted share, overlapping run, leftover files, and secrets never in output.

### Task 5 — Weekly images (`scripts/backup-weekly.sh`)
Window enforcement and hard `timeout`; thin-pool free-space pre-flight; `dune db backup` via the gate immediately before the prod image; guest-agent ping with an **alert** (not silent) if absent; per-VMID `vzdump --stdout --compress zstd | age | SMB` with `ionice`/`nice`/`--bwlimit`; `.partial` + rename; transfer verification; per-VMID retention; success only if every id succeeded.
**Acceptance:** tests with real `age`/`tar` and stubbed `vzdump`, covering window abort, a failing id not stopping the others, no plaintext file ever on disk, retention, and partial cleanup. Real `vzdump --stdout` behaviour is captured in the rollout contract step (Task 12).

### Task 6 — Alarm (`scripts/backup-check.sh`)
Checks the artifacts: newest OneDrive object (listing), newest SMB file, size floor, mtime; daily OneDrive token probe; restore-drill overdue (35 days); staleness 26h/8d; external dead-man ping on healthy; distinct exit codes; alert format per Task 1.
**Acceptance:** tests where local state says fresh but the remote object is missing/old (must alarm), token probe failure, webhook down (distinct exit code), drill overdue.

### Task 7 — Drills (`scripts/backup-drill.sh pipeline|db|vm`)
- `pipeline`: throwaway test key; encrypt → transfer → decrypt → `tar -tf`; must fail on truncation, tampering, wrong key.
- `db` (assisted, needs the real identity supplied for the drill): decrypt the newest daily set, restore the newest `.backup` into a **throwaway Postgres container of prod's image tag on dune-dev** (never dune-dev's own database), assert table counts and key-table row counts above a floor, remove the container, remove the decrypted material.
- `vm` (assisted): decrypt an image stream, `qmrestore -` to a scratch VMID onto a **transient no-uplink bridge** (created and removed by the script), regenerate MACs, never autostart, boot, run in-guest checks, destroy. Refuse if the scratch VMID exists; rotate across 101/102/103/CT104.
- Every drill appends an evidence-log record (date, backup id, hashes, duration, result).
**Acceptance:** tests with stubs for `docker`/`qm`/`qmrestore`/`ip`, real `age`/`tar`; assertions that cleanup runs on every failure path and that scratch VMID/bridge are never reused or leaked.

### Task 8 — Doctor (`scripts/backup-doctor.sh`)
Green/red readiness: config and credential permissions, tools present and pinned versions, SMB mounted and writable, OneDrive reachable, escrow verified within 100 days, guest-agent state per VM, timers active, thin-pool headroom, dead-man configured, egress FQDNs reachable.
**Acceptance:** tests for each check turning red.

### Task 9 — Timers and installer (`scripts/backup-install-timers.sh`) and CI
Units: DB tier (6h), daily set (05:15), weekly (Sunday 01:00), check (hourly), drill reminders; `Persistent=true`, oneshot, `Nice`, `IOSchedulingClass=idle`. CI job runs `bats tests/backup` and runs the sandbox-wrapper test under `sudo` so it **fails rather than skips**.
**Acceptance:** generated units pass `systemd-analyze verify`; timer/oncalendar assertions; CI green.

### Task 10 — Documentation
Runbooks per scenario (database only, one VM, whole host) usable from a bare Linux box; setup guide (OneDrive `rclone authorize` on another machine, SMB, key hand-off); credential inventory and rotation; data-protection notice; alert reference; README/Live Systems update; Requirement 23 ingress documentation; CHANGELOG.

### Task 11 — Audit gates
Layer 2 (implementation): eight read-only hats on the code, findings filed and CRITICAL/HIGH resolved; Layer 3: `/code-review high` on the PR diff; STRIDE tables and issue comments each time.

### Task 12 — Rollout on the host (operator-assisted, every step waits for a go)
Follows spec section 6 gates: (1) real-tool contract capture; (2) guest agent on dune-dev → acp-bot → dune-prod last; (3) key generation with hand-off, `backup-key verify`; (4) SMB automount and OneDrive; `backup-doctor` green; (5) install the gate on dune-prod and the restricted key; (6) DB tier + daily set; **gate:** decrypt on a second machine and a real DB restore passes; (7) one watched prod image; **gate:** scratch-VM restore boots and passes in-guest checks; (8) enable timers and alarm; deliberately skip a run to confirm the dead-man's-switch fires; (9) first scheduled runs recorded as evidence; close audit issues.

## Operator inputs required
A dedicated Microsoft account (D3); a heartbeat-service check and ping URL (D5); the desktop's IP, VLAN, wired/wifi and an SMB backup account (D7); a place for the private key (password manager plus second escrow) (D1).
