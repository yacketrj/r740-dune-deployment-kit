#!/usr/bin/env bash
# =============================================================================
# backup-announce.sh -- review and test the in-game backup announcements.
# =============================================================================
#   backup-announce.sh print                 show EVERY message exactly as players would see it
#                                            (sends nothing; always safe)
#   backup-announce.sh status                is the announcement channel configured?
#   backup-announce.sh send KEY [N] --yes    send ONE real in-game banner to ALL players now
#                                            (KEY: lead start ongoing done halted postponed test;
#                                             N = minutes, for lead/ongoing). Refuses without --yes.
#
# The backup job (backup-weekly.sh --announce) uses the same messages: warnings 30, 15, 5 and 1
# minute before the start, a notice when it starts and every 30 minutes while it runs, and a closing
# message. Set it up once:
#   1. In the game console: Settings -> API Keys -> create a key named "backup-announce" with ONLY the
#      action admin:broadcast (per-action scope; nothing else).
#   2. Save the key (starts dak_) in a root-only file, e.g. /root/.config/r740-backup/announce-key (0600).
#   3. In backup.env:  BK_ANNOUNCE_URL=http://192.168.20.10:8088
#                      BK_ANNOUNCE_KEY_FILE=/root/.config/r740-backup/announce-key
# =============================================================================
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
. "$here/backup-common.sh"
bk_load_config 2>/dev/null || true

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
cmd="${1:-}"
[ -n "$cmd" ] || usage

case "$cmd" in
  print)
    echo "Messages players will see (title <= 80 characters, body <= 500; banner shown for ${BK_ANNOUNCE_DURATION_S:-40} seconds):"
    echo
    for spec in "lead 30" "lead 15" "lead 5" "lead 1" "start 0" "ongoing 30" "ongoing 60" "done 0" "halted 0" "postponed 0"; do
      read -r k m <<<"$spec"
      bk_announce_text "$k" "$m"
      label="$k"
      [ "$m" = 0 ] || label="$k $m"
      printf '[%s]  (%d + %d characters)\n  %s\n  %s\n\n' "$label" "${#BK_ANN_TITLE}" "${#BK_ANN_BODY}" "$BK_ANN_TITLE" "$BK_ANN_BODY"
    done
    ;;
  status)
    if bk_announce_configured; then
      echo "configured: URL ${BK_ANNOUNCE_URL}, key file ${BK_ANNOUNCE_KEY_FILE} (readable)"
    else
      echo "NOT configured (need BK_ANNOUNCE_URL and a readable BK_ANNOUNCE_KEY_FILE): announcements are skipped"
    fi
    ;;
  send)
    key="${2:-}"
    n="${3:-0}"
    yes=0
    for a in "$@"; do [ "$a" = "--yes" ] && yes=1; done
    [ "$n" = "--yes" ] && n=0
    [ -n "$key" ] && [ "$key" != "--yes" ] || usage
    bk_announce_text "$key" "$n" || { echo "unknown message: $key" >&2; exit 2; }
    if [ "$yes" -ne 1 ]; then
      echo "This would show ALL online players this banner:" >&2
      printf '  %s\n  %s\n' "$BK_ANN_TITLE" "$BK_ANN_BODY" >&2
      echo "Add --yes to send it for real." >&2
      exit 2
    fi
    bk_announce_configured || { echo "not configured; nothing sent (see: $0 status)" >&2; exit 1; }
    bk_announce "$key" "$n"
    [ "$BK_ANNOUNCE_LAST_RC" -eq 0 ] || { echo "the console did not accept the broadcast" >&2; exit 1; }
    echo "sent."
    ;;
  *) usage ;;
esac
