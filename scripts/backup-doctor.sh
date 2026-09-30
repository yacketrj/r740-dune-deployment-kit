#!/usr/bin/env bash
# =============================================================================
# backup-doctor.sh -- "is this backup system actually ready?" (design v2, T10).
#
# Prints one line per check: [ OK ] / [WARN] / [FAIL]. Exit 0 only if nothing
# FAILED (warnings are allowed but listed). Run it after setup, before enabling
# the timers, and any time something feels off. It never changes the system:
# its only writes are a probe file it creates and removes on the SMB share.
#
#   backup-doctor.sh           local checks (no network beyond SMB/OneDrive/gate)
#   backup-doctor.sh --live    also: egress to Microsoft/Discord, a test Discord message
#
# RUN THIS: on the Proxmox host as root.
# =============================================================================
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
. "$here/backup-common.sh"
bk_load_config || { echo "[FAIL] config: cannot load $BK_CONFIG_DIR/backup.env"; exit 1; }

live=0
[ "${1:-}" = "--live" ] && live=1

fails=0
warns=0
ok() { printf '[ OK ] %s\n' "$1"; }
warn() { printf '[WARN] %s\n' "$1"; warns=$((warns + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; fails=$((fails + 1)); }

mode_of() { stat -c %a -- "$1" 2>/dev/null || echo "?"; }

# check_private FILE LABEL : exists, and not readable by group/other
check_private() {
  local f="$1" label="$2" m
  if [ -z "$f" ]; then bad "$label: not configured"; return; fi
  if [ ! -e "$f" ]; then bad "$label: $f does not exist"; return; fi
  m="$(mode_of "$f")"
  case "$m" in
    600 | 400 | 700) ok "$label: $f (mode $m)" ;;
    *) bad "$label: $f has mode $m (must be 600 or stricter)" ;;
  esac
}

# --- configuration and secrets -----------------------------------------------------------
cfgdir_mode="$(mode_of "$BK_CONFIG_DIR")"
if [ "$cfgdir_mode" = "700" ]; then ok "config directory $BK_CONFIG_DIR (mode 700)"; else bad "config directory $BK_CONFIG_DIR has mode $cfgdir_mode (must be 700)"; fi
check_private "$BK_CONFIG_DIR/backup.env" "config file"
check_private "${BK_DISCORD_WEBHOOK_FILE:-}" "Discord webhook file"
if [ "${BK_HEARTBEAT_REQUIRED:-1}" = "1" ]; then
  check_private "${BK_DEADMAN_URL_FILE:-}" "dead-man's-switch URL file (backup jobs)"
  check_private "${BK_CHECK_DEADMAN_URL_FILE:-}" "dead-man's-switch URL file (alarm)"
else
  # Optional: use it if it is there (and then it must be private), otherwise just say so.
  hb_any=0
  for hb in "${BK_DEADMAN_URL_FILE:-}" "${BK_CHECK_DEADMAN_URL_FILE:-}"; do
    [ -n "$hb" ] && [ -e "$hb" ] && { check_private "$hb" "dead-man's-switch URL file"; hb_any=1; }
  done
  [ "$hb_any" -eq 1 ] || warn "no external dead-man's-switch configured (BK_HEARTBEAT_REQUIRED=0): if this host or the alarm dies, nothing will tell you; Discord alerts are the only signal"
fi
check_private "${BK_BACKUP_SSH_KEY:-}" "backup SSH key"
check_private "${BK_KNOWN_HOSTS:-}" "pinned known_hosts"
check_private "${BK_DRILL_KNOWN_HOSTS:-}" "pinned known_hosts for the drill host"
[ -z "${BK_SMB_CREDENTIALS_FILE:-}" ] || check_private "$BK_SMB_CREDENTIALS_FILE" "SMB credentials file"
[ -z "${BK_RCLONE_REMOTE:-}" ] || check_private "${RCLONE_CONFIG:-/root/.config/rclone/rclone.conf}" "rclone config"

# --- keys: the host must hold only the public key ------------------------------------------
case "${BK_AGE_RECIPIENT:-}" in
  age1*) ok "age recipient configured (${BK_AGE_RECIPIENT:0:12}...)" ;;
  *) bad "age recipient: not configured (run backup-key.sh generate)" ;;
esac
leak=""
for d in "$BK_CONFIG_DIR" "$BK_STATE_DIR" "${BK_STAGE_DIR:-}"; do
  [ -n "$d" ] && [ -d "$d" ] || continue
  hit="$(grep -rl 'AGE-SECRET-KEY-' "$d" 2>/dev/null | head -n 1 || true)"
  [ -z "$hit" ] || leak="$hit"
done
if [ -n "$leak" ]; then bad "an age PRIVATE key is on this host: $leak (it must live off the host)"; else ok "no age private key on this host"; fi

evlog="$BK_STATE_DIR/evidence.log"
last_pass() {
  local ts
  ts="$(awk -F'\t' -v k="$1" '$2 == k && $3 == "PASS" { t = $1 } END { print t }' "$evlog" 2>/dev/null || true)"
  if [ -n "$ts" ]; then date -d "$ts" +%s 2>/dev/null || echo 0; else echo 0; fi
}
now="$(date +%s)"
e="$(last_pass escrow)"
if [ "$e" -eq 0 ]; then bad "key escrow: never verified (run backup-key.sh verify)"
elif [ $((now - e)) -gt $((${BK_ESCROW_MAX_AGE_D:-100} * 86400)) ]; then bad "key escrow: last verified $(((now - e) / 86400)) days ago"
else ok "key escrow verified $(((now - e) / 86400)) days ago"; fi

# --- audit trail: the hash chain must be intact ---------------------------------------------------
if broken="$(bk_audit_verify)"; then ok "audit log hash chain intact"; else bad "audit log hash chain BROKEN at line $broken (edited, truncated or reordered)"; fi

# --- tools ------------------------------------------------------------------------------------
missing=""
for t in ${BK_DOCTOR_TOOLS:-age age-keygen $([ -n "${BK_RCLONE_REMOTE:-}" ] && echo rclone) jq curl ssh tar sha256sum flock ionice nice timeout zstd vzdump qm pct mount.cifs}; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -n "$missing" ]; then bad "tools missing:$missing"; else ok "all required tools present"; fi

# --- host integrity (INC-2026-09-29) ------------------------------------------------------------
if out="$(dpkg -V coreutils curl openssh-client util-linux 2>/dev/null | grep -v ' c /etc/' || true)" && [ -z "$out" ]; then
  ok "core system binaries match their packages"
else
  bad "core system binaries differ from their packages: $(printf '%s' "$out" | head -n 3 | tr '\n' ';')"
fi

# --- storage: staging, RAM, share, pool -------------------------------------------------------------
if [ -n "${BK_STAGE_DIR:-}" ] && [ -d "$BK_STAGE_DIR" ]; then
  m="$(mode_of "$BK_STAGE_DIR")"
  if [ "$m" = "700" ]; then ok "staging directory $BK_STAGE_DIR (mode 700)"; else bad "staging directory $BK_STAGE_DIR has mode $m (must be 700)"; fi
elif [ -n "${BK_STAGE_DIR:-}" ]; then
  bad "staging directory $BK_STAGE_DIR does not exist"
fi
if [ -d "${BK_RAM_DIR:-/dev/shm}" ]; then ok "RAM-backed directory available (${BK_RAM_DIR:-/dev/shm})"; else bad "no RAM-backed directory for decrypted material"; fi

ls "${BK_SMB_MOUNT:-/nonexistent}" >/dev/null 2>&1 || true
if [ -n "${BK_SMB_MOUNT:-}" ] && mountpoint -q "$BK_SMB_MOUNT"; then
  probe="$BK_SMB_MOUNT/.doctor-probe-$$"
  if : >"$probe" 2>/dev/null && rm -f -- "$probe"; then ok "SMB share mounted and writable ($BK_SMB_MOUNT)"; else bad "SMB share mounted but NOT writable ($BK_SMB_MOUNT)"; fi
  smb_opts="$(findmnt -no OPTIONS "$BK_SMB_MOUNT" 2>/dev/null || true)"
  if [ -n "$smb_opts" ]; then
    smb_missing=""
    for want in vers=3.1.1 seal cache=none; do case ",$smb_opts," in *",$want,"*) ;; *) smb_missing="$smb_missing $want" ;; esac; done
    if [ -z "$smb_missing" ]; then ok "SMB mount options include vers=3.1.1, seal and cache=none"; else warn "SMB mount is missing option(s):$smb_missing (encryption in transit / honest read-back verification)"; fi
  fi
else
  bad "SMB share is not mounted at ${BK_SMB_MOUNT:-<unset>}"
fi

pool="${BK_THIN_POOL:-pve/data}"
if pool_line="$(lvs --noheadings --nosuffix --units g -o lv_size,data_percent "$pool" 2>/dev/null)" && [ -n "$pool_line" ]; then
  read -r psize ppct <<<"$pool_line"
  pfree="$(awk -v s="$psize" -v p="$ppct" 'BEGIN { printf "%d", s * (100 - p) / 100 }')"
  if [ "$pfree" -ge "${BK_MIN_POOL_FREE_GB:-150}" ]; then ok "thin pool $pool: ${pfree}GB free (${ppct}% used)"; else bad "thin pool $pool: only ${pfree}GB free (need ${BK_MIN_POOL_FREE_GB:-150}GB)"; fi
else
  bad "cannot read thin pool usage for $pool"
fi

# --- OneDrive -------------------------------------------------------------------------------------------
if [ -z "${BK_RCLONE_REMOTE:-}" ]; then
  ok "OneDrive not used (the share is the only target; copy it to your external media)"
elif timeout 60 rclone lsd "$BK_RCLONE_REMOTE" >/dev/null 2>&1; then ok "OneDrive reachable ($BK_RCLONE_REMOTE)"; else bad "OneDrive not reachable (token, network or remote name: $BK_RCLONE_REMOTE)"; fi

# --- the pull path from dune-prod ---------------------------------------------------------------------------
if [ -n "${BK_BACKUP_SSH:-}" ]; then
  bk_ssh_opts_init
  if st="$(ssh "${BK_SSH_OPTS[@]}" -- "$BK_BACKUP_SSH" status 2>/dev/null)"; then
    ep="$(printf '%s\n' "$st" | awk -F= '$1 == "newest_automatic_epoch" { print $2 }')"
    if [[ "$ep" =~ ^[0-9]+$ ]] && [ "$ep" -gt 0 ] && [ $((now - ep)) -lt $((30 * 3600)) ]; then ok "pull gate reachable; newest automatic dump is $(((now - ep) / 3600))h old"
    else bad "pull gate reachable but there is no fresh automatic dump (epoch=${ep:-?})"; fi
  else
    bad "pull gate not reachable as $BK_BACKUP_SSH (key, pinned host key or restriction)"
  fi
else
  bad "BK_BACKUP_SSH is not configured"
fi

# --- guests: agent state -------------------------------------------------------------------------------------
for id in ${BK_VMIDS:-}; do
  bk_valid_vmid "$id" || { bad "invalid guest id in BK_VMIDS: $id"; continue; }
  if qm status "$id" >/dev/null 2>&1; then
    if qm agent "$id" ping >/dev/null 2>&1; then ok "guest agent running in VM $id"; else warn "guest agent NOT running in VM $id (image will be crash-consistent)"; fi
  elif pct status "$id" >/dev/null 2>&1; then
    ok "container $id present (no agent needed)"
  else
    bad "guest $id does not exist"
  fi
done

# --- drills configured ---------------------------------------------------------------------------------------------
if [ -n "${BK_DRILL_SSH:-}" ] && [ -n "${BK_DRILL_PG_IMAGE:-}" ] && [ -n "${BK_DRILL_ROW_CHECKS:-}" ] && [[ "${BK_DRILL_MIN_TABLES:-}" =~ ^[0-9]+$ ]]; then ok "database drill configured"; else bad "database drill not fully configured (BK_DRILL_SSH, BK_DRILL_PG_IMAGE, BK_DRILL_ROW_CHECKS, BK_DRILL_MIN_TABLES)"; fi
nocheck=""
for id in ${BK_VMIDS:-}; do
  v="BK_DRILL_VM_CHECK_$id"
  [ -n "${!v:-}" ] || nocheck="$nocheck $id"
done
if [ -z "$nocheck" ]; then ok "in-guest drill checks configured for every guest"; else warn "no in-guest drill check configured for:$nocheck"; fi
e="$(last_pass drill-db)"
if [ "$e" -eq 0 ]; then warn "no database restore drill recorded yet"; else ok "database restore drill passed $(((now - e) / 86400)) days ago"; fi

# --- timers ---------------------------------------------------------------------------------------------------------------
inactive=""
for u in daily $([ "${BK_DBTIER_ENABLED:-1}" = "1" ] && echo dbtier) weekly check; do
  systemctl is-active "r740-backup-$u.timer" >/dev/null 2>&1 || inactive="$inactive $u"
done
if [ -z "$inactive" ]; then ok "backup timers active"; else warn "timers not active:$inactive (expected until the rollout enables them)"; fi

# --- live network checks ------------------------------------------------------------------------------------------------------
if [ "$live" -eq 1 ]; then
  for h in $([ -n "${BK_RCLONE_REMOTE:-}" ] && echo login.microsoftonline.com graph.microsoft.com onedrive.live.com) discord.com; do
    if curl -sS -m 8 -o /dev/null "https://$h/" 2>/dev/null; then ok "egress to $h"; else bad "cannot reach $h (egress or DNS)"; fi
  done
  bk_notify "r740 backup doctor: live test message (ignore)"
  if [ "$BK_NOTIFY_LAST_RC" -eq 0 ]; then ok "Discord webhook delivered a test message"; else bad "Discord webhook could not deliver (status $BK_NOTIFY_LAST_RC)"; fi
fi

printf '\n%s FAIL, %s WARN\n' "$fails" "$warns"
[ "$fails" -eq 0 ]
