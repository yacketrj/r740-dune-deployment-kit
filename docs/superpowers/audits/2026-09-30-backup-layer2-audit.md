# Backup system: Layer 2 (implementation) audit, 2026-09-30

Scope: `scripts/backup-*.sh`, `scripts/dune-prod/r740-backup-gate.sh`, `tests/backup/*`, `.github/workflows/ci.yml` (backup job), `docs/08-backup-runbook.md`, `backup.env.example`, at branch `feat/backup-scripts` (Requirement 20, Layer 2). Tracking issue: #119.

Method: eight hats dispatched as five independent read-only reviewers (Architect; Security; GRC + Cloud Security; Network + DBA; QA + UI). Each read the code and verified claims by reading; **none executed anything** (no test, script or stub was run by a reviewer, nothing was written). Every CRITICAL/HIGH finding was then confirmed or corrected by the implementer against the code (and, for the restore procedure, against the real `dune` CLI source) before being fixed, and each fix has a test that was mutation-checked (the fix removed from a scratch copy, the test seen to fail).

Result: **0 CRITICAL, 14 HIGH (H1-H12, H14, H15; the numbering skips H13), about 45 MEDIUM/LOW.** Every HIGH is resolved, mitigated with the residual stated, or explicitly accepted (H15). Remaining MEDIUM/LOW are filed as issues with a deferral reason (section 3).

## 1. HIGH findings and disposition

| ID | Hat(s) | Finding | STRIDE | Disposition |
|---|---|---|---|---|
| H1 | Architect F1, Security F1 | Root extracts a tar built by the untrusted game VM checking member **names** only; a symlink member followed by a file under it writes outside the work dir as root. Same in the drill for anything written to the share. | E, T | **Fixed.** `bk_tar_members_safe` rejects any non-file/non-directory member before extraction, at both sites. Tests: symlink + hardlink archives, nothing written through the link; unit test. |
| H2 | Security F2 | Retention pruned by filename order on a share other machines can write: a planted `...-99991231-235959...` name made the prune keep the fake and delete the real newest image/sets. | T, D | **Fixed.** Only names with a real, not-in-the-future timestamp are counted or deleted (`bk_stamp_plausible`), in both pruners. Tests incl. mutation. |
| H3 | QA Q1 | A deleted/rejected Discord webhook answers HTTP 404; curl exited 0, so the "dead webhook" exit-5 path never fired; tests faked it with the impossible exit 22. | R, D | **Fixed.** `curl -f`; test uses real curl against a local server returning 404 and 204. Messages capped at Discord's limit. |
| H4 | DBA D1 | The database drill restored with `--create --exit-on-error -d postgres`, unlike production (`create database dune owner dune` then plain `pg_restore -d dune`); it would false-FAIL or test the wrong path. | R, D | **Fixed.** Drill mirrors production (role, database, plain restore), counts errors against `BK_DRILL_MAX_RESTORE_ERRORS`, waits for the *second* ready message, bounds the tmpfs. Real-Postgres behaviour is still to be captured in rollout gate 3. |
| H5 | DBA D2, D3 | Runbook restore told the operator to `dune db stop` first (the restore requires Postgres running), omitted `--no-safety-backup` for a damaged DB, and the Funcom-token precondition of `--adopt-backup-battlegroup`. | D | **Fixed** in the runbook, each flag and precondition verified against `db.sh`. |
| H6 | Network N1 | An asleep desktop failed preflight: no OneDrive copy either, contradicting "OneDrive independent"; the 6h RPO silently became "no backup". | D | **Fixed.** SMB failure is a DEGRADED run (loud alert at the end, no success recorded); OneDrive is always attempted; each target pruned only after its own new copy verified. Tests + mutations. |
| H7 | Network N2 | A snapshot backup stalls guest I/O when its sink stalls; a hung CIFS write during the weekly run could hold the live game VM. | D | **Fixed.** The pipeline runs as its own process group; a watchdog kills every process in it if the output stops growing for `BK_WEEKLY_STALL_S`. Test with a hung producer. (Real CIFS/vzdump behaviour still to be observed in rollout gate 4.) |
| H8 | QA Q2, Q3, Q4 | The retention test passed with pruning disabled; prune-after-verify was untested for the transfer-verify and weekly paths; the production `cryptcheck` call was never exercised (seam `BK_RCLONE_CHECK_CMD=check`). | T | **Fixed.** Exact-count retention test through the daily flow; seeded files survive every failure path (daily and weekly); the `cryptcheck` argument shape is asserted. Mutation-verified. |
| H9 | UI U1, U2, U3; GRC G1, G2 | Runbook step 8 copied the template over the recipient set in step 4; `backup.env.example` lacked the required variables and named unused ones; the OneDrive restore path in the runbook differed from the path the jobs write. | D, R | **Fixed.** Template rewritten from the variables the scripts really read; step 8 edits in place; paths unified (`onedrive-crypt:r740/<tier>`). |
| H10 | UI U4, Cloud C2, Security F8 | The private key was handed off to a folder on the backup share, which the runbook also snapshots. | I | **Fixed.** `generate` refuses a hand-off dir on the share or any network filesystem; runbook uses a removable disk. Tests. |
| H11 | GRC G10, G11 | Audit and evidence logs were local, forgeable, not tamper-evident, shipping optional and undocumented; the alarm's "never trusts local state" claim contradicted its use of `evidence.log`. | R, T | **Partly fixed; the rest accepted.** The audit log is now a hash chain with `bk_audit_verify` (edit, deletion and reorder detected; doctor verifies it); evidence is mirrored into it; shipping is documented (`BK_AUDIT_SHIP_DIR`). Residual: tail truncation and a root rewrite of `evidence.log` (documented in runbook section 12). |
| H12 | GRC G14 | The data-protection notice's "at most 12 months" was untrue (gaps stretch it; snapshots, recycle bin, drill container). | I | **Fixed** (accurate retention, locations, processor, drill exposure; a privacy notice text is an operator deliverable). |
| H14 | Architect F2, GRC G2 | Missing/unset config aborted with no alert and no fail ping (`:?` before the ERR trap). | D, R | **Mitigated.** The template now contains every variable; the doctor fails on missing ones before rollout. The script-level silent abort itself is filed as a deferred MEDIUM (issue below). |
| H15 | Cloud C1 | A root-compromised hypervisor can delete both remote copies (the jobs hold delete rights; no immutable target). | T, D | **Accepted risk (decision D3)**, documented with its mitigations (desktop snapshots, OneDrive recycle bin/version history, off-host audit copy, key not on host) in runbook section 12. |

## 2. STRIDE report

| Category | Findings | Severity | Status |
|---|---|---|---|
| Spoofing | pinned host key for the drill host and hardened ssh options (F9, C7); alarm silenced by a forged file (F3) | MED | pinned/hardened: fixed; forged-file check deferred |
| Tampering | H1 link members; H2 filename trust; verify strength (`pg_restore -l`, D4); cache-served "bit-exact" verification (F5/C6); audit chain (H11) | HIGH/MED | H1, H2, H11(partly), C6 (mount options + doctor) fixed; `pg_restore -l` deferred |
| Repudiation | H3 dead webhook undetected; H11 forgeable evidence; missing runbook/notice content | HIGH | fixed / partly accepted |
| Information disclosure | H10 key next to ciphertext; plaintext staging on persistent disk (F4/C3); redaction gaps (F5) | HIGH/MED | H10, redaction fixed; staging deferred |
| Denial of service | H4 false drill FAIL; H5 restore failure; H6 desktop asleep; H7 stalled sink holds the VM; rclone and SSH without limits (N3, N7); unbounded pull (F6); partial-file leak (F7) | HIGH/MED | H4-H7, N3, N7, F7 fixed; unbounded pull deferred |
| Elevation of privilege | H1 tar-through-symlink (guest to host root); gate env hooks (F7); host-path guard bypass (F10); drill host devices/NICs (N6, F11) | HIGH/MED | all fixed (gate ignores `R740_GATE_*` and pins PATH outside test mode) |

## 3. MEDIUM and LOW findings deferred (filed as issues)

Each is real but does not block the gated rollout; each has a reason.

| Group | Findings | Why deferred / when |
|---|---|---|
| Plaintext staging | F4/C3/Arch F3: decrypted secrets and dumps sit on the staging directory (0700, `rm` not shred), no mountpoint check on it, weak space check | RAM staging is infeasible for multi-GB sets; needs a stream-encrypt redesign. Before rollout: put staging on a dedicated LUKS/tmpfs or accept and record. |
| Verification depth | D4/Arch F4: only a `PGDMP` header check on dumps (no `pg_restore -l`); other in-window pairs not settle-checked; F8: a OneDrive object that failed `cryptcheck` stays and the alarm counts it fresh; F3: alarm accepts a forged big file on the share | Detected by the monthly drill for the authoritative dump; add `pg_restore -l` in the gate and delete a failed object. |
| Hardening leftovers | F6 unbounded pull size/member count, `authoritative` value not validated; F11 recipient not pinned, curl-config quoting, `BK_CONFIG_FILE` and other `BK_*` hooks; C8 config perms not checked at load; D11 tamper-test 1/256 false FAIL; `allowed_mentions` on alerts | Low exploitability (root-owned config); batch into one hardening pass. |
| Operations | N4 vzdump `--bwlimit` default unmeasured; N5 VM drill restore has no thin-pool headroom check; N8 SMB TCP-445 probe (timeouts added, probe not); N10/F6 read-back time budget; Arch F2 silent abort on unset variable (no ERR trap yet); F10 one dead-man URL shared by all tiers; F12 `dump-now` rate limit; D5/D9/D12 gate sidecar parsing lag, pre-image dump, plaintext stage | Tune with real data in rollout gates 3 and 4. |
| Tests and CI | Q6 stubs simpler than real vzdump/qmrestore/rclone/pg_restore; Q7 skipped tests pass in CI and bats files are not shellchecked; Q8/Q9 sloppy assertions and coverage gaps | Real-tool contract capture is rollout step 12a; CI tightening is a small follow-up. |
| Governance | G6 no token pre-expiry warning; G11 evidence lacks hashes/duration/operator; G12 no pipeline-drill staleness alarm; G16 no RTO/RPO sign-off, no D3 written residual-risk acceptance, no README Live Systems update | Operator decisions and post-deployment documentation. |

## 4. Verification evidence

- Whole backup suite (`scripts/run-backup-tests.sh tests/backup`, sandboxed): **278 of 278 pass, 0 skipped** (it was 248 before this audit; every fix above added or strengthened tests).
- `shellcheck -S warning` (CI level) and `bash -n` clean on all scripts.
- Mutation checks (fix removed on a scratch copy, test observed failing): `curl -f`, both stamp checks, SMB prune at all / when degraded, remote prune, upload rate limit, gate test-mode guard.
- Not done: `gitleaks` could not be run (the binary is not on this host's PATH; a known open repair item). It must be run in CI before merge.
- Not verified by any reviewer or test: behaviour against the real `vzdump --stdout`, `qmrestore -`, `rclone cryptcheck` on a crypt remote, CIFS `cache=none` and the official Postgres image. These are rollout step 12a.
