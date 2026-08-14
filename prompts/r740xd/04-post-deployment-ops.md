# R740XD-04: Post-Deployment Performance Baseline, Monitoring & Troubleshooting

You are an LLM coding agent running in your own session, executed via
SSH against the R740's VMs — split out of the former
`tabr-tau/04-e2e-verification.md` (issue #59) since capturing
performance data and troubleshooting commands are R740-side operations,
not dev-machine gathering, even though you may be typing them from the
dev machine's terminal.

## Before You Start, Confirm
- `r740xd/01-proxmox-and-vms.md` through `r740xd/03-bot-deploy-and-tunnel.md`
  fully executed
- `tabr-tau/04-e2e-verification.md`'s automated suite and manual WAN/Discord
  checks passed — ask the user to confirm if you have no direct evidence

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

Save this output and report it back to the user — it's the baseline for
comparing against when players are online later.

### 1.2 Monitor During First Player Session
After players join, re-run the stats command above and compare against
the baseline. Flag explicitly if any of the following are true rather
than reporting a generic "looks fine":
- Memory usage exceeds 140 GB (92% of 152 GB)
- Any container shows CPU consistently above 80%
- `dune status` reports anything other than healthy

## Phase 2: First 24 Hours Monitoring

Run each of the following and report the actual output:
```bash
# Watch dune status hourly for any warnings:
ssh dune@192.168.20.10 "cd ~/dune-awakening-selfhost-docker && runtime/scripts/dune status"

# Check bot logs for errors:
ssh dune@192.168.20.10 "journalctl -u acp-bot -n 50 --no-pager"

# Verify daily DB backups ran successfully:
ssh dune@192.168.20.10 "ls -la ~/dune-awakening-selfhost-docker/runtime/backups/db/ | tail -5"
```

Also ask the user to report any player-reported lag, disconnects, or
instability, and check Cloudflare Tunnel health yourself
(`systemctl status cloudflared` on the VM) rather than assuming it's
still up because it was earlier.

## Troubleshooting

Use these if the user reports a problem, or if your own monitoring above
surfaces one — don't wait to be asked if you've already detected an
issue.

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
# From the dev machine, test each port:
nc -zu -w 2 <PUBLIC_IP> 7778
nc -z -w 2 <PUBLIC_IP> 31982

# On the VM, verify ports are listening:
ssh dune@192.168.20.10 "ss -ulnp | grep '777[7-9]'"
```

### Cloudflare Access not working
```bash
# Test tunnel health:
ssh dune@192.168.20.10 "systemctl status cloudflared && cloudflared tunnel info"
# Verify Access policy in Cloudflare Zero Trust dashboard -- ask the
# user to check this, you cannot access the dashboard yourself
```

## What to Report Back When This Prompt Is Done
Confirm and explicitly report each of the following:
- Performance baseline captured (include the actual numbers)
- 24-hour monitoring initiated, and whether any warnings remain
  unresolved
- Daily DB backups confirmed running (include the actual file listing)

## When This Prompt Is Done
Tell the user that once burn-in (a few days of stable production with
real players) is complete, they should start a Tabr-Tau session for the
final evidence/decommission steps in `tabr-tau/04-e2e-verification.md`'s
Phase 6 and `scripts/07-wsl-decommission.sh` on the gaming PC. Do not
run the decommission script yourself in this session.
</content>
