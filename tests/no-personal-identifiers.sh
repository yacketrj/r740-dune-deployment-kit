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
  # In a git repo: scan only staged content (pre-commit hook context)
  SCAN_TARGET="staged"
  DIFF_CONTENT="$(git diff --cached -U0 2>/dev/null || true)"
else
  SCAN_TARGET="tree"
fi

found=0
for pattern in "${DENYLIST[@]}"; do
  if [ "$SCAN_TARGET" = "staged" ]; then
    if printf '%s' "$DIFF_CONTENT" | grep -qE "$pattern"; then
      echo "BLOCKED: staged changes contain a known personal identifier matching: $pattern"
      found=1
    fi
  else
    if grep -rqE "$pattern" --exclude-dir=.git . 2>/dev/null; then
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
