# R740XD-04: Post-Deployment Performance Baseline, Monitoring & Troubleshooting

This prompt runs in its own session, executed via SSH against the R740's
VMs — split out of the former `tabr-tau/04-e2e-verification.md` (issue
#59) since capturing performance data and troubleshooting commands are
R740-side operations, not dev-machine gathering, even though you may be
typing them from your dev machine's terminal.

## Pre-Requisites
- `r740xd/01-proxmox-and-vms.md` through `r740xd/03-bot-deploy-and-tunnel.md`
  fully executed
- `tabr-tau/04-e2e-verification.md`'s automated suite and manual WAN/Discord
  checks passed

## Phase 1: Performance Baseline

### 1.1 Capture Idle Resource Usage
```bash
ssh dune@192.168.20.10 << 'ENDSSH'
echo "=== IDLE BASELINE $(date) ==="
free -h | head -2
echo "---"
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null | head -20
echo "---"
uptime
ENDSSH
```

Save this output — it's your baseline for comparing against when players
are online.

### 1.2 Monitor During First Player Session
After players join, re-run the stats command above and compare:
- Memory usage should remain below 140 GB (92% of 152 GB)
- No container should show CPU consistently above 80%
- `dune status` should remain healthy

## Phase 2: First 24 Hours Monitoring

```bash
# Watch dune status hourly for any warnings:
ssh dune@192.168.20.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune status"

# Check bot logs for errors:
ssh dune@192.168.20.10 "journalctl -u acp-bot -n 50 --no-pager"

# Verify daily DB backups ran successfully:
ssh dune@192.168.20.10 "ls -la ~/dune-awakening-selfhost-docker/runtime/backups/db/ | tail -5"
```

Also monitor player reports for lag, disconnects, or instability, and
check Cloudflare Tunnel health (`systemctl status cloudflared` on the VM).

## Troubleshooting

### `dune status` shows warnings
```bash
# Check each service individually:
ssh dune@192.168.20.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune services && runtime/scripts/dune ports"
# Common fix: if IP mismatch, update SERVER_IP in .env and restart
```

### Bot not responding in Discord
```bash
ssh dune@192.168.20.10 "journalctl -u acp-bot --since '10 min ago' --no-pager | grep -i error"
# Common fix: verify DISCORD_BOT_TOKEN in .env, restart service
```

### Players can't connect
```bash
# From dev machine, test each port:
nc -zu -w 2 <PUBLIC_IP> 7778
nc -z -w 2 <PUBLIC_IP> 31982

# On the VM, verify ports are listening:
ssh dune@192.168.20.10 "ss -ulnp | grep '777[7-9]'"
```

### Cloudflare Access not working
```bash
# Test tunnel health:
ssh dune@192.168.20.10 "systemctl status cloudflared && cloudflared tunnel info"
# Verify Access policy in Cloudflare Zero Trust dashboard
```

## State After Completion
- [ ] Performance baseline captured
- [ ] 24-hour monitoring initiated, no unresolved warnings
- [ ] Daily DB backups confirmed running

## After This Prompt Completes
Once burn-in (a few days of stable production with real players) is
complete, start a Tabr-Tau session for the final evidence/decommission
steps in `tabr-tau/04-e2e-verification.md`'s Phase 6 and
`scripts/07-wsl-decommission.sh` on the gaming PC.
