#!/usr/bin/env bash
# =============================================================================
# no-personal-identifiers.sh
#
# Project-specific guard on top of the generic gitleaks/ggshield/trivy scans.
# Those tools are pattern-based (they look for things that LOOK like secrets
# - API key shapes, private key headers, etc). This script instead blocks a
# short, explicit list of real values known from this project's own history
# that would NOT be caught by generic secret-shape detection, because they
# are not secrets in shape - they're real IPs/hostnames/IDs that happen to
# identify a specific person's infrastructure. This matters especially given
# this repo's stated goal of eventually becoming a public community guide -
# any of these values leaking into a commit is a privacy/OpSec issue, not a
# "secret" in the gitleaks sense, and would otherwise slip through.
#
# If you are adapting this repo/script for your OWN deployment, replace the
# list below with your OWN real values before using this guard, or it will
# not protect you.
# =============================================================================
set -euo pipefail

# Known real values from this project's history that must never appear in
# a commit to this repo. Add to this list if new real values come up in
# future conversation/session history.
DENYLIST=(
  "50\.123\.64\.61"                    # old gaming-PC public IP
  "192\.168\.68\.21"                    # old gaming-PC LAN IP
  "129\.146\.238\.118"                  # OCI ACP bot VPS IP
  "sh-afe0154f3afe602c-icgvmx"          # old Dev BATTLEGROUP_ID
  "darkdante\.org"                      # personal domain used for tunnels
  "acp-setup\.darkdante"                # ACP setup subdomain
  "console\.darkdante"                  # console subdomain
)

echo "== Personal identifier guard =="

if git rev-parse --git-dir >/dev/null 2>&1; then
  DIFF_CONTENT="$(git diff --cached -U0 2>/dev/null || true)"
  if [ -n "$DIFF_CONTENT" ]; then
    SCAN_TARGET="staged"
  elif [ -n "${CI:-}" ]; then
    # In CI, scan only the PR diff — not the full tree.  Committed
    # docs legitimately reference real deployment values (IPs, domain
    # names).  A full-tree scan would always fail on those existing
    # commits, which is not useful.  We want to catch NEW introductions
    # in the PR, just like the pre-commit hook does locally.
    BASE="${GITHUB_BASE_REF:-main}"
    git fetch origin "$BASE" --depth=1 2>/dev/null || true
    DIFF_CONTENT="$(git diff "origin/$BASE...HEAD" -U0 2>/dev/null || true)"
    SCAN_TARGET="ci-diff"
  else
    # Not CI, no staged changes: scan the full working tree (e.g.
    # run manually outside a git-workflow context).
    SCAN_TARGET="tree"
  fi
else
  SCAN_TARGET="tree"
fi

# When scanning a diff, only look at ADDED lines (prefixed with a single
# '+', excluding the '+++ b/path' file-header line). Scanning the whole
# diff text would also match a denylisted value that appears on a
# REMOVED ('-') line or in unchanged context around a hunk -- i.e. fixing
# a bad value by deleting it would itself trigger a false "found in
# diff" block, exactly backwards from what this guard is for. Found via
# the ported copy of this script in arrakis-control-panel#165, when
# removing real personal identifiers there tripped this guard on the
# deletions themselves.
ADDED_LINES="$(printf '%s\n' "$DIFF_CONTENT" | grep -E '^\+' | grep -vE '^\+\+\+ ' || true)"

found=0
for pattern in "${DENYLIST[@]}"; do
  if [ "$SCAN_TARGET" = "staged" ] || [ "$SCAN_TARGET" = "ci-diff" ]; then
    if printf '%s' "$ADDED_LINES" | grep -qE "$pattern"; then
      echo "BLOCKED: $SCAN_TARGET changes contain a known personal identifier matching: $pattern"
      found=1
    fi
  else
    if grep -rqE "$pattern" --exclude-dir=.git --exclude="no-personal-identifiers.sh" . 2>/dev/null; then
      echo "BLOCKED: working tree contains a known personal identifier matching: $pattern"
      found=1
    fi
  fi
done

if [ "$found" -ne 0 ]; then
  echo
  echo "One or more known personal IPs/hostnames/IDs were found. Remove them"
  echo "or replace with a documentation placeholder (e.g. 192.168.20.10 for"
  echo "example subnets, which ARE allowed - see .gitleaks.toml) before"
  echo "committing."
  exit 1
fi

echo "No known personal identifiers found."
