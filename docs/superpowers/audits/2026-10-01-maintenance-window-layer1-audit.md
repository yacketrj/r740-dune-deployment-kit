# Layer 1 design audit: Tuesday maintenance window (issue #142), 2026-10-01

Method (README Requirement 20): the design `docs/superpowers/specs/2026-10-01-tuesday-maintenance-window-design.md` (v1,
commit 1f34e04) was reviewed by eight independent read-only reviewers, one per hat, each told to map findings to STRIDE.
The reviewers read files only (no execution, no writes). Their reports are model output and are treated as findings to
verify, not as decisions. Every finding below was checked against the design and, where cheap, the cited source.
Resolution status refers to **design v2** (same file, rewritten after this audit); "OPEN" means the operator must decide.

IDs: AR architect, SE security, GR GRC, NW network, CL cloud security, UX UI/UX, DB DBA, QA QA/test.

## Findings register (deduplicated: 70 raw findings became 41 items)

| ID | Sev | STRIDE | Finding | Status in v2 |
|---|---|---|---|---|
| SE-1/CL-3 | CRITICAL | E, T | The key that pulls backups would also stop/start prod and install software, unattended | Resolved: separate maintenance key + gate, `from=`, `no-pty`, mutating verbs only while the maintenance marker is live and inside the Tuesday window (section 7) |
| SE-2/CL-1 | HIGH | T, E | `self-update install latest` runs unattended with no release verification (no checksum/signature in self-update.sh; tarball extracted over the install dir) | **OPEN (operator)**: operator chose "always latest"; v2 adds compensating controls and asks for explicit risk acceptance (section 9.5) |
| SE-3/CL-2 | HIGH | T | `DUNE_SELF_UPDATE_API_BASE/WEB_BASE/TOKEN/REPO` are environment-overridable | Resolved: gate runs `env -i`, fixed PATH, hard-coded repo and hosts, zero-argument verbs (section 7) |
| SE-4 | MED | S, R | Gate is stateless: any key holder can call stop/update/disable any time | Resolved with SE-1 (marker, age < 4 h, Tuesday window, state machine) |
| SE-5 | MED | D, T | `dune update auto disable` could be left without an enable | Resolved: independent transient timer re-enables at the hard stop (section 5) |
| SE-6/SE-7 | LOW | T, R | Audit log has no external anchor and can skip a record; gate logs nothing on prod | Resolved: write-before-act (a privileged verb runs only after its audit record is written), mirror to the share, prod-side syslog of verb and source |
| SE-8 | LOW | T | `tar -xf` of the release has no member-path or symlink guard (upstream self-update.sh) | Upstream issue to file on Core; compensating control in v2 (see SE-2) |
| CL-4 | MED | E | Broadcast key must never gain wider scope | Resolved: stated as a rule; population is read via `dune status` over ssh |
| CL-5 | LOW | R | Announce key and the new maintenance key missing from the credential table (Req 27) | Resolved: added to runbook section 8 with rotation dates |
| CL-6/CL-7 | LOW | I | `bk_redact` lacks `dak_`; output tails go into the Discord report; 1900-char cap can truncate PASS/FAIL | Resolved: new redaction rule, every tail redacted, PASS/FAIL lines first |
| AR-1 | HIGH | D | `update auto enable` resets operator policy (defaults 15,10,5,1) | Resolved: capture the stored policy before `disable`, restore exact values, verify equality (section 4 P2, P9) |
| AR-2 | HIGH | D | P2 can race a running `update.sh auto run`; `disable` stops it mid-patch | Resolved: wait for the service to be inactive before disabling; refuse if a pending update is staged |
| AR-3 | HIGH | D | The existing guard aborts the job during the deliberate stop (no suspend interface) | Resolved: `--pause-file` interface; guard resumes only after READY |
| AR-4/UX-6 | HIGH | D | An exit between `dune stop` and `dune start` leaves the game down; trap only re-enabled patching | Resolved: EXIT trap ensures "game up" (start + READY wait, then page) and the hourly alarm covers game-down with a marker |
| AR-5/QA-6 | MED | T | "First vzdump progress line" under-specified: vzdump.err has earlier INFO lines; backup_one is blocking | Resolved: match `INFO: +[0-9]+%` only, background watcher, tested against a captured real log |
| AR-6 | MED | E | gate_ssh 900 s budget too short for `dune update --yes` plus READY wait | Resolved: per-verb timeouts, long verbs async with polling |
| AR-7 | LOW | N/A | Window start/lead and daily child lock handling | Resolved: constants defined (section 4) |
| GR-1 | HIGH | R | Operator approval only paraphrased | **Resolved**: recorded verbatim with timestamp in design section 2a (commit 1f34e04) |
| GR-2 | HIGH | E, R | Req 32 exception promised but not written; merging would leave the README contradicting the automation | Resolved in v2: README Requirement 32/7/16 amendments drafted in the same change set (section 7) |
| GR-3 | HIGH | R | Req 7 confirmation not covered for unattended stops | Resolved with GR-2: standing authorization scoped to this window; policy 9.1 decided before Layer 2 |
| GR-4 | MED | R | Per-window evidence incomplete (commands, exit codes, rollback target, actor, retention) | Resolved: per-window evidence bundle with retention (7 years per the GRC program decision) |
| GR-5 | MED | T | CC8.1: unattended change, weak separation of duties | Resolved: post-hoc review of each window within 24 h, documented compensating controls |
| GR-6 | MED | D | No rollback/incident procedure; failed window not an incident class | Resolved: rollback runbook, failed window = incident in INCIDENT-INDEX |
| GR-7 | MED | T | Req 16 marker advisory only | Resolved: the gate refuses session-originated calls while the marker exists |
| GR-8/GR-9 | LOW | N/A, I | Hard-coded values go stale; Discord report content/retention | Resolved: single source links, "last verified" date, classification note |
| NW-1/NW-2 | HIGH | D | Share loss mid-image while the game is back up; game stopped before the share is proven | Resolved: write+fsync probe on the share immediately before `dune stop`; desktop sleep/updates inhibited for the window; mid-image stall kills vzdump (releases the snapshot) and pages |
| NW-3 | MED | N/A | Req 23: undocumented network paths (prod egress to Steam/GitHub, console 8088, Cloudflare) | Resolved: rows added to runbook section 11 |
| NW-4/NW-5 | MED | D | No per-step update timeouts; hard clock does not cover update end; check exit codes conflated | Resolved: 20-minute step timeouts, egress/DNS pre-check, exit codes other than 0/100 = "check failed", no install that cannot finish before 04:15, post-update READY deadline 04:25 |
| NW-6 | MED | D | `dune start` depends on ssh with no fallback | Resolved: one retry then page |
| NW-7/NW-8/NW-10 | LOW | N/A | Tunnel flap, announcement races, time interplay | Resolved: verify probe retries 5 min; notices accept best-effort; documented |
| UX-1/UX-2 | HIGH | R, I | Player messages are false for this window ("needs no restart") and states are missing (down, back, update start/done/failed) | Resolved: separate window message set with plain facts and downtime minutes; Discord community post and pinned notice |
| UX-3 | HIGH | D | Players online and `dune stop` kicks them | **OPEN (operator)**: section 9.1 |
| UX-4 | HIGH | D, R | No operator "run this next" per failure | Resolved: runbook table phase / symptom / command and a "game down" recovery recipe |
| UX-5 | HIGH | R, D | `backup-status.sh` is blind to the window and would advise Ctrl-C | Resolved: phase-aware dashboard (marker, phase, patching state, deadlines) |
| UX-7/UX-8/UX-9/UX-10 | MED/LOW | N/A | No start-of-window ping; onboarding and first attended run uncovered; postponed/05:00 notice; wording | Resolved in v2 (sections 4, 8) |
| DB-1 | HIGH | T | Postgres stopped-before-snapshot is not enforced | Resolved: require `dune stop` rc 0 and `dune-postgres` exited before vzdump starts; otherwise abort and start |
| DB-2 | MED | T | Game servers stopped with `docker rm -f` (queued writes) | Resolved: pre-stop quiesce step if the CLI offers one, else accepted and documented; verified in rehearsal |
| DB-3/DB-7/DB-8 | HIGH/MED | T | Dump and image at different times; RPO undocumented; pre-update dump not gated | Resolved: `dune db backup` immediately before the stop (pairing artifact), another before P7, gate on dump size and sha, RPO stated |
| DB-4/DB-5/DB-6 | HIGH/MED | T, D | No tested rollback, unmeasured RTO, boot-only drill does not prove DB integrity | Resolved: prod restore drill with a postgres query check and measured RTO is a gate for the first run; rollback runbook |
| QA-1..QA-11 | HIGH/MED | T, D, E | No contract fixtures; re-enable on every exit path, preflight-does-nothing, verified-image gate, hard clock, snapshot detection, start retry, marker PID reuse, gate near-misses need tests; DST/time zone; things stubs cannot prove | Resolved: test plan and rehearsal list in v2 section 8; fixtures captured from dune-dev/prod read-only |

## STRIDE report (Layer 1)

| STRIDE | Findings | Highest | Status |
|---|---|---|---|
| Spoofing | SE-4 | MED | Resolved in v2 |
| Tampering | SE-2, SE-3, SE-6, SE-8, AR-5, GR-5, GR-7, DB-1..DB-8, QA | HIGH | SE-2 OPEN (operator risk acceptance); SE-8 upstream issue; rest resolved in v2 |
| Repudiation | GR-1..GR-7, SE-4, SE-7, CL-5, UX-1, UX-5 | HIGH | Resolved |
| Information disclosure | CL-6, GR-9, UX-2 | LOW | Resolved |
| Denial of service | AR-1..AR-4, NW-1..NW-6, UX-3..UX-6, DB-4, DB-5 | HIGH | UX-3 OPEN (operator); rest resolved in v2 |
| Elevation of privilege | SE-1, SE-3, CL-3, AR-6, CL-4, GR-2 | CRITICAL | Resolved in v2 (SE-1); no CRITICAL/HIGH left except the two OPEN operator decisions |

## Gate status

CRITICAL: 1, resolved in design v2. HIGH: all resolved in v2 except **two operator decisions** (SE-2 release trust,
UX-3 players online). MEDIUM/LOW: resolved in v2 or filed (SE-8 as a Core issue). Layer 2 (implementation) and Layer 3
audits remain, per Requirement 20, before the first production run.
