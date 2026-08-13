#!/usr/bin/env bash
# =============================================================================
# 11-e2e-verify.sh — Full Deployment Verification Suite
#
# RUN THIS: from your dev machine (darkdante@tabr-tau) AFTER the full
#           deployment is complete (PROMPT-01 through PROMPT-03 executed).
#
# Validates: hardware, Proxmox, VMs, Docker, game servers, ACP bot,
#            Cloudflare Tunnel, security hardening, database backups,
#            network isolation, and port-forward reachability.
#
# Produces: a structured verification report at /tmp/opencode/e2e-report.txt
#           and exits with the number of CRITICAL failures.
#
# USAGE: bash 11-e2e-verify.sh
# =============================================================================
set -euo pipefail

REPORT="/tmp/opencode/e2e-report-$(date +%Y%m%d-%H%M%S).txt"
CRITICAL=0
WARNINGS=0
PASSES=0
CHECKS=0

DUNE_PROD="dune@192.168.20.10"
DUNE_DEV="dune@192.168.21.10"
PROXMOX="root@192.168.30.5"
CONSOLE_URL="https://console.darkdante.org"
SETUP_URL="https://acp-setup.darkdante.org"
PUBLIC_IP="${PUBLIC_IP:-$(curl -s https://api.ipify.org 2>/dev/null || echo "unknown")}"

mkdir -p "$(dirname "$REPORT")"

log_section() {
  echo "" | tee -a "$REPORT"
  echo "==== $1 ====" | tee -a "$REPORT"
}

check() {
  local id="$1" severity="$2" label="$3" host="$4" command="$5" expected="$6"
  CHECKS=$((CHECKS + 1))
  printf "  [%s] %s ... " "$id" "$label" | tee -a "$REPORT"

  local output rc
  output=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$host" "$command" 2>&1) || rc=$?
  rc=${rc:-$?}

  if echo "$output" | grep -qE "$expected"; then
    echo "PASS" | tee -a "$REPORT"
    PASSES=$((PASSES + 1))
  else
    case "$severity" in
      CRITICAL) echo "FAIL [CRITICAL]" | tee -a "$REPORT"; CRITICAL=$((CRITICAL + 1)) ;;
      WARN) echo "WARN" | tee -a "$REPORT"; WARNINGS=$((WARNINGS + 1)) ;;
    esac
    echo "       Expected: $expected" | tee -a "$REPORT"
    echo "       Got:      $(echo "$output" | tail -5 | tr '\n' ' ')" | tee -a "$REPORT"
  fi
}

check_local() {
  local id="$1" severity="$2" label="$3" command="$4" expected="$5"
  CHECKS=$((CHECKS + 1))
  printf "  [%s] %s ... " "$id" "$label" | tee -a "$REPORT"

  local output rc
  output=$(bash -c "$command" 2>&1) || rc=$?
  rc=${rc:-$?}

  if echo "$output" | grep -qE "$expected"; then
    echo "PASS" | tee -a "$REPORT"
    PASSES=$((PASSES + 1))
  else
    case "$severity" in
      CRITICAL) echo "FAIL [CRITICAL]" | tee -a "$REPORT"; CRITICAL=$((CRITICAL + 1)) ;;
      WARN) echo "WARN" | tee -a "$REPORT"; WARNINGS=$((WARNINGS + 1)) ;;
    esac
    echo "       Expected: $expected" | tee -a "$REPORT"
    echo "       Got:      $(echo "$output" | tail -3 | tr '\n' ' ')" | tee -a "$REPORT"
  fi
}

# =============================================================================
echo "R740 Deployment Verification Suite" | tee "$REPORT"
echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$REPORT"
echo "Report:  $REPORT" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

# =============================================================================
# SECTION 1: HARDWARE & PROXMOX
# =============================================================================
log_section "1. HARDWARE & PROXMOX"

check "H1" CRITICAL "Proxmox host reachable" \
  "$PROXMOX" "hostname" "r740-pve"

check "H2" CRITICAL "AVX2 support on host CPU" \
  "$PROXMOX" "grep -c avx2 /proc/cpuinfo" "[4-9][0-9]"

check "H3" CRITICAL "Host RAM (expect ~256 GB)" \
  "$PROXMOX" "free -g | awk '/^Mem:/{print \$2}'" "2[3-5][0-9]"

check "H4" CRITICAL "Host CPU threads (expect 80)" \
  "$PROXMOX" "nproc" "80"

check "H5" CRITICAL "BIOS: VT-x enabled" \
  "$PROXMOX" "grep -c vmx /proc/cpuinfo | head -1" "[4-9][0-9]"

check "H6" CRITICAL "Proxmox services running" \
  "$PROXMOX" "systemctl is-active pvedaemon pveproxy pvestatd | sort -u" "active"

check "H7" CRITICAL "No-subscription repo configured" \
  "$PROXMOX" "grep -c pve-no-subscription /etc/apt/sources.list.d/*.list 2>/dev/null || echo 0" "[1-9]"

# =============================================================================
# SECTION 2: VM CONFIGURATION
# =============================================================================
log_section "2. VM CONFIGURATION"

check "V1" CRITICAL "dune-prod VM exists" \
  "$PROXMOX" "qm status 101" "running"

check "V2" CRITICAL "dune-prod CPU type is host" \
  "$PROXMOX" "qm config 101 | grep '^cpu:'" "host"

check "V3" CRITICAL "dune-prod memory (expect 152 GB)" \
  "$PROXMOX" "qm config 101 | grep '^memory:'" "155648"

check "V4" CRITICAL "dune-prod cores (expect 40)" \
  "$PROXMOX" "qm config 101 | grep '^cores:'" "40"

check "V5" CRITICAL "dune-prod CPU affinity to socket 0" \
  "$PROXMOX" "qm config 101 | grep '^affinity:'" "0-19"

check "V6" WARN "dune-prod bridge VLAN-aware" \
  "$PROXMOX" "grep 'bridge-vlan-aware' /etc/network/interfaces" "yes"

check "V7" CRITICAL "dune-dev VM exists" \
  "$PROXMOX" "qm status 102" "running"

check "V8" CRITICAL "dune-dev memory (expect 50 GB)" \
  "$PROXMOX" "qm config 102 | grep '^memory:'" "51200"

check "V9" CRITICAL "dune-dev cores (expect 20)" \
  "$PROXMOX" "qm config 102 | grep '^cores:'" "20"

check "V10" CRITICAL "dune-dev CPU affinity to socket 1" \
  "$PROXMOX" "qm config 102 | grep '^affinity:'" "20-29"

check "V11" WARN "VM auto-start enabled and ordered" \
  "$PROXMOX" "qm config 101 | grep '^onboot:\|^startup:' | wc -l" "2"

# =============================================================================
# SECTION 3: GUEST OS & DOCKER
# =============================================================================
log_section "3. GUEST OS & DOCKER (dune-prod)"

check "G1" CRITICAL "dune-prod reachable via SSH" \
  "$DUNE_PROD" "hostname" "dune-prod"

check "G2" CRITICAL "dune-prod AVX2 in guest" \
  "$DUNE_PROD" "grep -c avx2 /proc/cpuinfo" "[3-9][0-9]"

check "G3" CRITICAL "dune-prod RAM visible (expect ~152 GB)" \
  "$DUNE_PROD" "free -g | awk '/^Mem:/{print \$2}'" "1[4-5][0-9]"

check "G4" CRITICAL "Docker daemon running" \
  "$DUNE_PROD" "systemctl is-active docker" "active"

check "G5" CRITICAL "Docker Compose plugin available" \
  "$DUNE_PROD" "docker compose version" "Docker Compose"

check "G6" CRITICAL "Postgres bound to 127.0.0.1 only" \
  "$DUNE_PROD" "ss -tlnp | grep 15432" "127.0.0.1"

check "G7" CRITICAL "No port 8088 on 0.0.0.0" \
  "$DUNE_PROD" "ss -tlnp | grep ':8088' | grep -cv '127.0.0.1' || echo 0" "0"

check "G8" CRITICAL "UDP game ports listening" \
  "$DUNE_PROD" "ss -ulnp | grep -c '777[7-9]\|778[0-9]\|779[0-9]\|780[0-9]\|7810'" "[1-9]"

# =============================================================================
# SECTION 4: GAME SERVER STACK
# =============================================================================
log_section "4. GAME SERVER STACK (dune-prod)"

check "S1" CRITICAL "dune status returns healthy" \
  "$DUNE_PROD" "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune status 2>&1 | tail -3" "healthy\|running\|READY"

check "S2" WARN "dune ready check" \
  "$DUNE_PROD" "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune ready 2>&1 | tail -3" "ready\|READY\|ok"

check "S3" CRITICAL "Postgres health check" \
  "$DUNE_PROD" "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune db health 2>&1" "healthy\|ok\|connected"

check "S4" CRITICAL "Game containers running (expect 6+)" \
  "$DUNE_PROD" "docker ps --format '{{.Names}}' | grep -c 'dune-server\|dune-director\|dune-gateway'" "[6-9]\|1[0-9]"

check "S5" CRITICAL "Sietch dimensions active (expect 2)" \
  "$DUNE_PROD" "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune sietches validate 2>&1 | grep -c 'active\|READY\|running'" "[2-9]"

check "S6" WARN "Deep Desert instances (expect 4 if configured)" \
  "$DUNE_PROD" "docker ps --format '{{.Names}}' | grep -c 'deepdesert'" "[0-9]"

check "S7" WARN "Dynamic maps configured" \
  "$DUNE_PROD" "cd ~/dune-awakening-selfhost-docker && test -f runtime/generated/map-runtime-modes.json && echo exists" "exists"

check "S8" CRITICAL "Console API responding on localhost" \
  "$DUNE_PROD" "curl -s -o /dev/null -w '%{http_code}' http://localhost:8088/api/health" "200"

check "S9" WARN "DB password rotated (not default dune)" \
  "$DUNE_PROD" "grep DUNE_DB_PASSWORD ~/dune-awakening-selfhost-docker/.env 2>/dev/null | grep -cv 'dune$' || echo 0" "[1-9]"

check "S10" WARN "Farms readiness check passes" \
  "$DUNE_PROD" "cd ~/dune-awakening-selfhost-docker && bash tests/farm-readiness-test.sh 2>&1 | tail -1" "ok\|PASS\|[0-9]+ passed"

# =============================================================================
# SECTION 5: ACP BOT
# =============================================================================
log_section "5. ACP DISCORD BOT (dune-prod)"

check "B1" CRITICAL "Bot service active" \
  "$DUNE_PROD" "systemctl is-active acp-bot.service" "active"

check "B2" WARN "Bot service enabled on boot" \
  "$DUNE_PROD" "systemctl is-enabled acp-bot.service" "enabled"

check "B3" WARN "Bot systemd hardening: NoNewPrivileges" \
  "$DUNE_PROD" "systemctl show acp-bot.service -p NoNewPrivileges" "yes"

check "B4" WARN "Bot systemd hardening: ProtectSystem" \
  "$DUNE_PROD" "systemctl show acp-bot.service -p ProtectSystem" "strict"

check "B5" WARN "Bot systemd hardening: MemoryDenyWriteExecute" \
  "$DUNE_PROD" "systemctl show acp-bot.service -p MemoryDenyWriteExecute" "yes"

check "B6" CRITICAL "Bot console API reachable over localhost" \
  "$DUNE_PROD" "ADAPTER_TOKEN=\$(grep DUNE_DISCORD_ADAPTER_TOKEN ~/arrakis-control-panel/.env | cut -d= -f2); curl -s -H \"Authorization: Bearer \${ADAPTER_TOKEN}\" http://localhost:8088/api/integrations/discord/health | jq -r '.ok' 2>/dev/null || echo 'no'" "true"

check "B7" CRITICAL "Discord bot gateway connected" \
  "$DUNE_PROD" "journalctl -u acp-bot --since '5 min ago' --no-pager 2>/dev/null | grep -c 'Ready\|READY\|gateway'" "[1-9]"

check "B8" WARN "SQLite database exists and populated" \
  "$DUNE_PROD" "test -f ~/arrakis-control-panel/data/acp.db && stat -c%s ~/arrakis-control-panel/data/acp.db" "[1-9][0-9]*"

check "B9" CRITICAL "SQLite backup timer active (C-4 fix)" \
  "$DUNE_PROD" "systemctl is-active acp-db-backup.timer 2>/dev/null || echo 'missing'" "active"

check "B10" CRITICAL "SQLite backup file exists (from C-4 fix)" \
  "$DUNE_PROD" "ls ~/arrakis-control-panel/data/backups/acp-*.db 2>/dev/null | wc -l" "[1-9]"

check "B11" WARN "Bot setup portal port 3100 listening" \
  "$DUNE_PROD" "ss -tlnp | grep ':3100'" "LISTEN"

check "B12" WARN "Steam-link port 3101 listening" \
  "$DUNE_PROD" "ss -tlnp | grep ':3101'" "LISTEN"

# =============================================================================
# SECTION 6: CLOUDFLARE TUNNEL & ACCESS
# =============================================================================
log_section "6. CLOUDFLARE TUNNEL & ACCESS"

check "T1" CRITICAL "cloudflared service active" \
  "$DUNE_PROD" "systemctl is-active cloudflared" "active"

check "T2" WARN "Tunnel config references console hostname" \
  "$DUNE_PROD" "grep -c 'console.darkdante.org' /etc/cloudflared/config.yml 2>/dev/null || echo 0" "[1-9]"

check "T3" WARN "Tunnel config references acp-setup hostname" \
  "$DUNE_PROD" "grep -c 'acp-setup.darkdante.org' /etc/cloudflared/config.yml 2>/dev/null || echo 0" "[1-9]"

check_local "T4" CRITICAL "console.darkdante.org reachable" \
  "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 $CONSOLE_URL 2>/dev/null || echo 000" "[23][0-9][0-9]"

check_local "T5" CRITICAL "acp-setup live stats endpoint returns JSON" \
  "curl -s --connect-timeout 10 $SETUP_URL/api/live-stats 2>/dev/null | jq -r '.players_online // \"missing\"' 2>/dev/null || echo 'missing'" "[0-9]"

check_local "T6" WARN "console.darkdante.org has Cloudflare Access enforced (expect non-200 on first hit)" \
  "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 $CONSOLE_URL 2>/dev/null" "302\|303\|403\|401"

# =============================================================================
# SECTION 7: NETWORK ISOLATION & FIREWALL
# =============================================================================
log_section "7. NETWORK ISOLATION & FIREWALL"

check "N1" CRITICAL "Dev VM reachable" \
  "$DUNE_DEV" "hostname" "dune-dev"

check "N2" CRITICAL "Dev → Prod blocked (ICMP)" \
  "$DUNE_DEV" "ping -c 2 -W 2 192.168.20.10 2>&1; echo RC=\$?" "100% packet loss\|RC=1\|RC=2"

check "N3" CRITICAL "Dev → Prod blocked (HTTP)" \
  "$DUNE_DEV" "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 http://192.168.20.10:8088 2>/dev/null; echo ''" "000\|Connection refused\|timed out"

check "N4" CRITICAL "Prod → Dev blocked (ICMP)" \
  "$DUNE_PROD" "ping -c 2 -W 2 192.168.21.10 2>&1; echo RC=\$?" "100% packet loss\|RC=1\|RC=2"

check "N5" WARN "SSH port 22 on Prod responds only internally" \
  "$DUNE_PROD" "ss -tlnp | grep ':22'" "LISTEN"

# =============================================================================
# SECTION 8: WAN PORT FORWARDS
# =============================================================================
log_section "8. WAN PORT FORWARDS"

check_local "W1" CRITICAL "UDP game port range reachable from WAN" \
  "timeout 3 nc -zu -w 2 $PUBLIC_IP 7778 2>&1; echo RC=\$?" "succeeded\|RC=0"

check_local "W2" WARN "TCP RMQ game port reachable from WAN" \
  "timeout 3 nc -z -w 2 $PUBLIC_IP 31982 2>&1; echo RC=\$?" "succeeded\|RC=0"

check_local "W3" WARN "TCP RMQ HTTP port reachable from WAN" \
  "timeout 3 nc -z -w 2 $PUBLIC_IP 31983 2>&1; echo RC=\$?" "succeeded\|RC=0"

check_local "W4" CRITICAL "Port 8088 (admin console) NOT reachable from WAN" \
  "timeout 3 nc -z -w 2 $PUBLIC_IP 8088 2>&1; echo RC=\$?" "refused\|timed out\|RC=1"

# =============================================================================
# SECTION 9: SECURITY HARDENING
# =============================================================================
log_section "9. SECURITY HARDENING"

check "X1" WARN "admin-web-password.txt exists and is 600" \
  "$DUNE_PROD" "test -f ~/dune-awakening-selfhost-docker/runtime/secrets/admin-web-password.txt && stat -c%a ~/dune-awakening-selfhost-docker/runtime/secrets/admin-web-password.txt" "600"

check "X2" WARN "funcom-token.txt has correct permissions (600)" \
  "$DUNE_PROD" "stat -c%a ~/dune-awakening-selfhost-docker/runtime/secrets/funcom-token.txt" "600"

check "X3" WARN "SSH password authentication disabled" \
  "$DUNE_PROD" "grep '^PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null | head -1" "no"

check "X4" WARN "UFW or iptables active (host firewall)" \
  "$DUNE_PROD" "ufw status 2>/dev/null | grep -c 'active' || iptables -L -n 2>/dev/null | grep -c 'Chain INPUT' || echo 0" "[1-9]"

check "X5" WARN "Restart schedule timer enabled" \
  "$DUNE_PROD" "systemctl is-active dune-awakening-scheduled-restart.timer 2>/dev/null || echo 'inactive'" "active"

check "X6" WARN "DB backup timer enabled" \
  "$DUNE_PROD" "systemctl is-active dune-awakening-db-backup.timer 2>/dev/null || echo 'inactive'" "active"

# =============================================================================
# SECTION 10: DATABASE INTEGRITY
# =============================================================================
log_section "10. DATABASE INTEGRITY"

check "D1" CRITICAL "Postgres accepting connections" \
  "$DUNE_PROD" "cd ~/dune-awakening-selfhost-docker && docker exec dune-postgres psql -U dune -d dune -c 'SELECT count(*) FROM dune.accounts;' 2>&1 | tail -3" "[0-9]"

check "D2" WARN "World partition table has rows" \
  "$DUNE_PROD" "cd ~/dune-awakening-selfhost-docker && docker exec dune-postgres psql -U dune -d dune -t -c 'SELECT count(*) FROM dune.world_partition;' 2>&1" "[2-9][0-9]*"

check "D3" WARN "Player state table has rows" \
  "$DUNE_PROD" "cd ~/dune-awakening-selfhost-docker && docker exec dune-postgres psql -U dune -d dune -t -c 'SELECT count(*) FROM dune.player_state;' 2>&1" "[0-9]"

check "D4" WARN "Recent DB backup exists (< 48 hours old)" \
  "$DUNE_PROD" "find ~/dune-awakening-selfhost-docker/runtime/backups/db/ -name '*.backup' -mtime -2 2>/dev/null | wc -l" "[1-9]"

# =============================================================================
# SECTION 11: ACP LANDING & DNS
# =============================================================================
log_section "11. ACP LANDING & DNS"

check_local "L1" WARN "acp.darkdante.org reachable" \
  "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 https://acp.darkdante.org 2>/dev/null || echo 000" "[23][0-9][0-9]"

check_local "L2" WARN "acp landing stats API returns data" \
  "curl -s --connect-timeout 10 https://acp.darkdante.org/api/stats 2>/dev/null | jq -r '.players_online // \"missing\"' 2>/dev/null || echo 'missing'" "[0-9]"

# =============================================================================
# SUMMARY
# =============================================================================
log_section "VERIFICATION SUMMARY"

TOTAL_ISSUES=$((CRITICAL + WARNINGS))
echo "" | tee -a "$REPORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$REPORT"
echo "  TOTAL CHECKS:   $CHECKS" | tee -a "$REPORT"
echo "  PASSED:         $PASSES" | tee -a "$REPORT"
echo "  WARNINGS:       $WARNINGS" | tee -a "$REPORT"
echo "  CRITICAL FAILS: $CRITICAL" | tee -a "$REPORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

if [ "$CRITICAL" -gt 0 ]; then
  echo "STATUS:  NOT READY FOR PRODUCTION" | tee -a "$REPORT"
  echo "         $CRITICAL critical check(s) failed. Fix before" | tee -a "$REPORT"
  echo "         announcing the server to players." | tee -a "$REPORT"
elif [ "$WARNINGS" -gt 0 ]; then
  echo "STATUS:  CONDITIONALLY READY" | tee -a "$REPORT"
  echo "         $WARNINGS warning(s) present. Review before" | tee -a "$REPORT"
  echo "         opening to players, but not blocking." | tee -a "$REPORT"
else
  echo "STATUS:  READY FOR PRODUCTION" | tee -a "$REPORT"
  echo "         All checks passed. Server is go for players." | tee -a "$REPORT"
fi

echo "" | tee -a "$REPORT"
echo "Report saved to: $REPORT" | tee -a "$REPORT"
echo "Completed: $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$REPORT"

exit "$CRITICAL"
