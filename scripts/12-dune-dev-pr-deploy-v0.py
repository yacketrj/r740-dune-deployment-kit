#!/usr/bin/env python3
"""
12-dune-dev-pr-deploy-v0.py -- MINIMAL viable PR deploy/rollback tool for dune-dev.

STATUS: v0 / unhardened stopgap. This is NOT the tool designed in issue #97
(45-section spec + Amendments 1-15, all posted as comments on
https://github.com/yacketrj/r740-dune-deployment-kit/issues/97). This script
implements ONLY the core content-addressed deploy/rollback mechanism -- it
deliberately skips almost everything issue #97's design requires before that
tool may become "the project's standard test-deploy path" per Requirement 20:

    MISSING vs. the full design (tracked, not forgotten):
    - No trusted-source repo allowlist beyond a single hardcoded repo check (§11)
    - No candidate code scan gate (semgrep/trivy/gitleaks) before deploy (§11a)
    - No decompression-bomb/extraction-size limits (§13, Amendment 7)
    - No GitHub-token scope/rotation policy -- reads a token from a fixed
      path but does not verify its scope at runtime (§10a, Amendment 2)
    - No invocation-authorization policy beyond "you can SSH to dune-dev
      and run this script" (§9a, Amendment 6)
    - No DB-schema-risk content detection or backup-gate enforcement (§25/§29,
      Amendments 3/4) -- IF YOUR PR TOUCHES console/api/src/duneDb.js OR ANY
      SCHEMA/DDL, TAKE A MANUAL `dune db backup` BEFORE RUNNING deploy.
    - No Compose-identity/volume-change special-casing (§25, Amendment 11) --
      IF YOUR PR TOUCHES docker-compose*.yml's `name:` OR `volumes:`, DO NOT
      USE THIS SCRIPT; get a human to review manually.
    - No transaction journal / interrupted-transaction recovery (§22/§23)
    - No exclusive lock (§21) -- do not run two invocations concurrently,
      and do not run this while another operator might be using it.
    - No timeout/TLS-validation hardening on GitHub calls beyond Python's
      urllib defaults (Amendment 13) -- defaults are TLS-verified, but no
      explicit hard timeout is set below what urllib already provides.
    - No fault-injection test suite, no unit tests, no security-abuse tests.
    - No fidelity requirement on the docker/health-check calls this script
      makes (they call real commands directly, not via a tested wrapper).

    WHAT THIS SCRIPT DOES DO (the safety floor a stopgap must not skip):
    - Resolves a PR number to an exact, frozen 40-char commit SHA via the
      GitHub API -- never deploys a branch name, only a specific SHA.
    - Downloads the COMPLETE repository tree at that SHA (not a diff, not
      changed-files-only) as a tarball, hashes it, stages it before ANY
      live-service mutation.
    - Safely extracts the tarball (rejects absolute paths, `../` traversal,
      and unsafe symlinks -- the one archive-security control from §13 that
      is cheap enough to implement in a stopgap and dangerous enough to skip).
    - Reconciles the COMPLETE staged tree onto the live directory via rsync,
      excluding the same protected-state paths as the real target repo's own
      .gitignore (.env, runtime/secrets/, runtime/generated/, and the rest --
      read directly from the live .gitignore at runtime, not hardcoded, so it
      can't silently drift from the real list).
    - Snapshots the CURRENT live tree (respecting the same exclusions) before
      touching anything, so `rollback` always has something real to restore
      to -- this is a lightweight, ad hoc version of the design's `adopt`,
      run automatically before every deploy rather than as a separate
      one-time step.
    - Restarts the console service and runs `dune status`/`dune ready` as a
      health check; does NOT auto-rollback on failure (v0 requires a human
      to look at the output and decide -- see `rollback` usage below).
    - Every deploy/rollback prints exactly what SHA is now live and where
      the pre-deploy snapshot was saved, so an operator always knows current
      state without guessing.

    THREAT MODEL WARNING: this script grants whatever PR it deploys the same
    Docker-socket-adjacent privilege the full design's threat model describes
    (dune-dev's console mounts /var/run/docker.sock). Only use this against
    PRs from Project-Arrakis/dune-awakening-selfhost-docker (own repo, own
    branches) that you already trust enough to run unattended -- this script
    enforces that repo check but nothing beyond it. Do not point this at an
    external fork's PR.

USAGE:
    # Deploy PR #349 (resolves to whatever its current head SHA is *right now*,
    # then freezes and uses only that SHA for the rest of the operation):
    python3 12-dune-dev-pr-deploy-v0.py deploy --pr 349

    # Roll back to the snapshot taken immediately before the last deploy:
    python3 12-dune-dev-pr-deploy-v0.py rollback

    # Show current state (what SHA/PR is live, what snapshot rollback would use):
    python3 12-dune-dev-pr-deploy-v0.py status

Run this ON dune-dev itself (SSH in first), not from your dev machine --
it operates on local paths and the local Docker daemon.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
from pathlib import Path

REPO = "Project-Arrakis/dune-awakening-selfhost-docker"  # renamed from yacketrj/* in the 2026-08-21 org migration
LIVE_DIR = Path.home() / "dune-awakening-selfhost-docker"
STATE_DIR = Path.home() / ".dune-dev-pr-deploy-v0"
SNAPSHOT_DIR = STATE_DIR / "snapshots"
STATE_FILE = STATE_DIR / "state.json"
TOKEN_FILE = Path.home() / ".config" / "dune-dev-pr-deploy" / "github-token"

SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def log(msg):
    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] {msg}", flush=True)


def die(msg, code=1):
    log(f"ABORT: {msg}")
    sys.exit(code)


def gh_api(path):
    """GET a GitHub API path, using a token if one is configured (raises rate
    limits from 60/hr to 5000/hr; not required for a handful of manual runs)."""
    url = f"https://api.github.com{path}"
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
    if TOKEN_FILE.exists():
        token = TOKEN_FILE.read_text().strip()
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())


def resolve_pr(pr_number: int):
    """Resolve a PR number to its exact head SHA + head repo full_name.
    Freezes both -- everything downstream uses ONLY these values, never a
    branch name, and never re-queries the PR again mid-operation."""
    data = gh_api(f"/repos/{REPO}/pulls/{pr_number}")
    head_sha = data["head"]["sha"]
    head_repo = data["head"]["repo"]["full_name"] if data["head"]["repo"] else None
    base_repo = data["base"]["repo"]["full_name"]
    state = data["state"]
    draft = data.get("draft", False)

    if not SHA_RE.match(head_sha):
        die(f"resolved head SHA '{head_sha}' failed format validation")

    # Minimal trusted-source check: this v0 tool only ever deploys code that
    # already lives in the same repo it's targeting (own branches, own forks
    # of your own account are NOT auto-trusted -- head_repo must be an exact
    # match). This is a single hardcoded check, not the full allowlist +
    # scan-gate system §11/§11a describe -- do not extend this tool's use to
    # any other repo without re-reading that design first.
    if head_repo != REPO:
        die(
            f"head repo '{head_repo}' != trusted repo '{REPO}' -- this v0 "
            f"tool only deploys branches from within the target repo itself, "
            f"not external forks. Use manual review for anything else."
        )

    if state != "open":
        log(f"WARNING: PR #{pr_number} state is '{state}', not 'open' -- proceeding anyway (v0 has no re-check).")
    if draft:
        log(f"WARNING: PR #{pr_number} is a draft -- proceeding anyway (v0 has no re-check).")

    log(f"Resolved PR #{pr_number} -> {head_repo}@{head_sha}")
    return head_sha, head_repo, base_repo


def download_and_stage(head_sha: str, stage_dir: Path):
    """Download the COMPLETE tarball at head_sha (never a diff), hash it,
    safely extract it into stage_dir. Fails before any live mutation if
    anything here goes wrong."""
    url = f"https://api.github.com/repos/{REPO}/tarball/{head_sha}"
    log(f"Downloading complete tree at {head_sha} ...")
    tmp_tar = stage_dir / "artifact.tar.gz"
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
    if TOKEN_FILE.exists():
        req.add_header("Authorization", f"Bearer {TOKEN_FILE.read_text().strip()}")
    with urllib.request.urlopen(req, timeout=120) as resp, open(tmp_tar, "wb") as f:
        shutil.copyfileobj(resp, f)

    sha256 = hashlib.sha256(tmp_tar.read_bytes()).hexdigest()
    log(f"Downloaded artifact.tar.gz, sha256={sha256}")

    extract_dir = stage_dir / "tree"
    extract_dir.mkdir(exist_ok=True)
    safe_extract_tar(tmp_tar, extract_dir)

    # GitHub tarballs contain one top-level dir like "owner-repo-shortsha/"
    subdirs = [d for d in extract_dir.iterdir() if d.is_dir()]
    if len(subdirs) != 1:
        die(f"expected exactly one top-level dir in extracted tarball, found {len(subdirs)}")
    return subdirs[0], sha256


def safe_extract_tar(tar_path: Path, dest: Path):
    """The one archive-security control from §13 cheap enough for a stopgap:
    reject absolute paths, '../' traversal, and symlinks escaping dest.
    This is NOT the full hardened extraction function §13 requires (no
    decompression-bomb/size limits -- see Amendment 7 in the full design)."""
    dest_resolved = dest.resolve()
    with tarfile.open(tar_path, "r:gz") as tf:
        for member in tf.getmembers():
            member_path = (dest / member.name).resolve()
            if not str(member_path).startswith(str(dest_resolved) + os.sep) and member_path != dest_resolved:
                die(f"archive member '{member.name}' escapes staging root -- refusing to extract")
            if member.issym() or member.islnk():
                link_target = (member_path.parent / member.linkname).resolve()
                if not str(link_target).startswith(str(dest_resolved) + os.sep):
                    die(f"archive member '{member.name}' is a symlink/hardlink escaping staging root -- refusing to extract")
        tf.extractall(dest, filter="data" if sys.version_info >= (3, 12) else None)


def read_protected_paths():
    """Read the REAL .gitignore's runtime-state section from the live tree,
    at run time -- never hardcode this list, so it can't silently drift from
    the actual target repo's own protected-state convention."""
    gitignore = LIVE_DIR / ".gitignore"
    if not gitignore.exists():
        die(f"{gitignore} not found -- cannot determine protected-state paths")
    protected = []
    for line in gitignore.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        # Only treat directory-like or dotfile entries as protected-state
        # exclusions for rsync purposes; skip generic build-artifact globs
        # (node_modules/, *.pyc, etc.) that aren't operator/host state.
        if line in (".env",) or line.startswith("runtime/") or line == "work/":
            protected.append(line.rstrip("/"))
    log(f"Protected paths (excluded from sync in both directions): {protected}")
    return protected


def rsync_exclude_args(protected_paths):
    args = []
    for p in protected_paths:
        args += ["--exclude", p]
        args += ["--exclude", p + "/"]
    return args


def snapshot_live_tree(protected_paths) -> Path:
    """Snapshot the CURRENT live tree (excluding protected state) before
    touching anything -- this is what `rollback` restores to. Runs before
    every deploy automatically; this is v0's lightweight substitute for the
    real design's one-time `adopt` step (§19)."""
    SNAPSHOT_DIR.mkdir(parents=True, exist_ok=True)
    ts = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    snap_path = SNAPSHOT_DIR / f"pre-deploy-{ts}"
    snap_path.mkdir()
    log(f"Snapshotting current live tree to {snap_path} ...")
    cmd = ["rsync", "-a"] + rsync_exclude_args(protected_paths) + [str(LIVE_DIR) + "/", str(snap_path) + "/"]
    subprocess.run(cmd, check=True)
    return snap_path


def reconcile(source_dir: Path, protected_paths, dry_run=False):
    """Full-tree rsync of source_dir onto LIVE_DIR, excluding protected
    paths, with --delete so stale files are removed too (per the design's
    core principle: full reconciliation, never a diff-apply)."""
    cmd = ["rsync", "-a", "--delete"] + rsync_exclude_args(protected_paths)
    if dry_run:
        cmd.append("--dry-run")
        cmd.append("-v")
    cmd += [str(source_dir) + "/", str(LIVE_DIR) + "/"]
    log(f"Reconciling {source_dir} -> {LIVE_DIR} (dry_run={dry_run}) ...")
    result = subprocess.run(cmd, check=True, capture_output=dry_run, text=True)
    if dry_run:
        return result.stdout
    return None


def restart_and_health_check() -> bool:
    # The console lives in docker-compose.web.yml, not the base
    # docker-compose.yml, as service `redblink-dune-docker-console` -- not
    # bare `console`. Confirmed live via `docker compose config --services`;
    # the base compose file alone only has `orchestrator`. Matches exactly
    # what runtime/scripts/dune's own `manager`/`start` commands run (see
    # that script's start_compose_service_if_available, web branch) --
    # --force-recreate is added here (unlike that helper) because a redeploy
    # must always replace the running container, never no-op because one
    # happens to already be up.
    log("Restarting console service (redblink-dune-docker-console) ...")
    env = os.environ.copy()
    env["COMPOSE_PROJECT_NAME"] = env.get("DUNE_WEB_COMPOSE_PROJECT_NAME", "dune-awakening-selfhost-docker")
    env["DUNE_HOST_REPO_ROOT"] = env.get("DUNE_HOST_REPO_ROOT", str(LIVE_DIR))
    env["DUNE_HOST_UID"] = env.get("DUNE_HOST_UID", str(os.getuid()))
    env["DUNE_HOST_GID"] = env.get("DUNE_HOST_GID", str(os.getgid()))
    try:
        subprocess.run(
            ["docker", "compose", "-f", "docker-compose.web.yml", "up", "-d",
             "--build", "--force-recreate", "redblink-dune-docker-console"],
            cwd=LIVE_DIR, check=True, env=env,
        )
    except subprocess.CalledProcessError as err:
        # The file deploy (the actually risky, stateful part) already
        # succeeded by the time this runs -- a restart failure must still
        # let cmd_deploy record state (pr/sha/snapshot), or `status` and
        # `rollback` are left blind to what's really live on disk. v0's own
        # contract is "don't auto-rollback, let a human decide" -- crashing
        # here instead denies the human even the state to decide from.
        log(f"Console restart command failed: {err}")
        return False
    time.sleep(5)
    # `dune status` never prints an "Overall:" summary line -- `dune ready`
    # is the pass/wait/fail check this tool's own docstring already points
    # operators at; confirmed live, its success line is "READY: ... looks
    # healthy." (no "Overall:" text exists in either command's real output).
    log("Running health check (dune ready) ...")
    result = subprocess.run(
        ["./runtime/scripts/dune", "ready"],
        cwd=LIVE_DIR, capture_output=True, text=True,
    )
    print(result.stdout)
    healthy = "READY: " in result.stdout and result.returncode == 0
    if not healthy:
        log("Health check did NOT report READY.")
    return healthy


def load_state():
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text())
    return {}


def save_state(state):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2))


def cmd_status(args):
    state = load_state()
    if not state:
        print("No deploy has been performed by this tool yet.")
        return
    print(json.dumps(state, indent=2))


def cmd_deploy(args):
    if LIVE_DIR.name != "dune-awakening-selfhost-docker":
        die(f"LIVE_DIR ({LIVE_DIR}) does not look like the expected target directory")

    protected = read_protected_paths()
    head_sha, head_repo, base_repo = resolve_pr(args.pr)

    with tempfile.TemporaryDirectory(prefix="dune-dev-pr-deploy-") as tmp:
        stage_dir = Path(tmp)
        extracted_dir, artifact_sha256 = download_and_stage(head_sha, stage_dir)

        if args.dry_run:
            diff_output = reconcile(extracted_dir, protected, dry_run=True)
            print("=== DRY RUN: files that would change ===")
            print(diff_output)
            log("Dry run complete. No changes made.")
            return

        pre_deploy_snapshot = snapshot_live_tree(protected)
        prev_state = load_state()

        log(f"Deploying PR #{args.pr} ({head_sha}) onto {LIVE_DIR} ...")
        reconcile(extracted_dir, protected, dry_run=False)

        healthy = restart_and_health_check()

        new_state = {
            "pr": args.pr,
            "head_sha": head_sha,
            "head_repo": head_repo,
            "artifact_sha256": artifact_sha256,
            "deployed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "pre_deploy_snapshot": str(pre_deploy_snapshot),
            "previous_state": prev_state or None,
            "healthy_after_deploy": healthy,
        }
        save_state(new_state)

        print("")
        print(f"=== Deploy of PR #{args.pr} ({head_sha[:12]}) complete ===")
        print(f"Healthy: {healthy}")
        print(f"Pre-deploy snapshot: {pre_deploy_snapshot}")
        if not healthy:
            print("")
            print("HEALTH CHECK DID NOT PASS. This v0 tool does NOT auto-rollback.")
            print(f"To roll back manually, run: python3 {sys.argv[0]} rollback")


def cmd_rollback(args):
    state = load_state()
    if not state:
        die("no recorded deploy to roll back from (state file empty/missing)")

    snap_path = Path(state["pre_deploy_snapshot"])
    if not snap_path.exists():
        die(f"recorded snapshot {snap_path} no longer exists on disk -- cannot roll back automatically")

    protected = read_protected_paths()
    log(f"Rolling back to snapshot {snap_path} (pre-deploy state before PR #{state['pr']} / {state['head_sha'][:12]}) ...")
    reconcile(snap_path, protected, dry_run=False)

    healthy = restart_and_health_check()

    print("")
    print(f"=== Rollback to pre-deploy state (before PR #{state['pr']}) complete ===")
    print(f"Healthy: {healthy}")

    # Restore whatever state existed before the deploy we just rolled back,
    # so `status`/a subsequent `rollback` reflects reality, not the deploy
    # we just undid.
    save_state(state.get("previous_state") or {})


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p_deploy = sub.add_parser("deploy", help="Deploy a PR's exact head SHA onto dune-dev")
    p_deploy.add_argument("--pr", type=int, required=True)
    p_deploy.add_argument("--dry-run", action="store_true")
    p_deploy.set_defaults(func=cmd_deploy)

    p_rollback = sub.add_parser("rollback", help="Roll back to the pre-deploy snapshot")
    p_rollback.set_defaults(func=cmd_rollback)

    p_status = sub.add_parser("status", help="Show current deploy state")
    p_status.set_defaults(func=cmd_status)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
