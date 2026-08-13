# Post-Stand-Up Security Hardening Checklist

Do this before considering either VM "done," ideally before or immediately
after the 7/30 cutover — not weeks later.

## 1. Rotate default database password (both VMs)

The upstream project falls back to a hardcoded `dune`/`dune` Postgres
credential in three independent locations if `DUNE_DB_PASSWORD` isn't
explicitly set. On EACH VM, use the console API's password-change endpoint
— **do NOT just append to `.env` and restart or you will break the
connection** (the console connects with the new password but the Postgres
role still has the old one):

```bash
cd ~/dune-awakening-selfhost-docker
NEWPASS="$(openssl rand -base64 32)"

# The console API handles BOTH: ALTER ROLE in Postgres + update .env
curl -s -X POST http://localhost:8088/api/database/password \
  -H "Content-Type: application/json" \
  -H "X-CSRF-Token: $(curl -s http://localhost:8088/api/auth/state | jq -r '.csrfToken')" \
  -b "asc_session=$(curl -s -X POST http://localhost:8088/api/auth/login \
    -H "Content-Type: application/json" \
    -d "{\"password\":\"$(grep ADMIN_PASSWORD .env | cut -d= -f2)\"}" \
    -c - | grep asc_session | awk '{print $NF}')" \
  -d "{\"password\":\"${NEWPASS}\"}"
```

If the console API is not accessible (e.g. first-time setup), use the
direct `psql` path instead:

```bash
docker exec -i dune-postgres psql -U dune -d dune \
  -c "ALTER ROLE dune WITH PASSWORD '${NEWPASS}';"
echo "DUNE_DB_PASSWORD=${NEWPASS}" >> .env
```

Then restart the stack so game containers pick up the new password:
```bash
docker compose restart
```

**Verify:** `dune db health` must return healthy with no authentication
errors after the restart. Use a **different** generated password on
Prod vs. Dev — don't reuse one across both.

## 2. Confirm the admin console is NOT reachable from WAN

On each VM:
```bash
grep ADMIN_BIND_HOST .env
```
Should be `127.0.0.1` or a private VLAN IP, never `0.0.0.0` exposed with a
WAN port-forward pointed at it. Cross-check against your UCG-Max port
forward list (`docs/02-network-setup.md` Step 5) — there should be **no**
forward rule for port 8088 on either VM, period.

## 3. Cloudflare Tunnel / Access for remote console access

If you want your console tunnel hostname (`CONSOLE_TUNNEL_HOSTNAME` —
substitute your own real subdomain) to keep working after migration, do NOT
just repoint the existing tunnel config at the new IP as-is — the old config
had no additional access gate in front of it (bare hostname → :8088). Add
**Cloudflare Access** (free tier supports this) in front of the tunnel:

1. In the Cloudflare Zero Trust dashboard, go to **Access → Applications →
   Add an Application**
2. Select "Self-hosted", point it at your `CONSOLE_TUNNEL_HOSTNAME`
3. Add a policy requiring your email (or a small allowlist of trusted
   emails) to authenticate via one-time PIN or an identity provider before
   the tunnel even forwards the request through
4. This means even if someone finds the hostname, they hit a Cloudflare
   login wall before ever reaching your console's own login page — a second
   independent layer, not a replacement for the console's own auth

Alternatively, skip the public hostname entirely and only reach the console
via the UniFi Teleport/WireGuard VPN set up in `02-network-setup.md` Step 6
— simpler, one less moving part, and arguably better given the console
mounts the Docker socket (see item 5 below).

## 4. Firewall Postgres/RabbitMQ to loopback only (both VMs)

Independent of what the app itself does, confirm at the OS level:
```bash
sudo ss -tlnp | grep -E '15432|32573|31982|31983'
```
`15432` (Postgres) and `32573` (RabbitMQ admin) should only show
`127.0.0.1:PORT`, never `0.0.0.0:PORT` or the VM's real IP. `31982`/`31983`
(RabbitMQ game) are intentionally forwarded on Prod per the network design —
that's expected and correct, don't lock those down.

## 5. Do not enable the metrics/observability stack yet

`docker-compose.metrics.yml`'s cAdvisor service runs `privileged: true` with
broad host filesystem mounts — a filed, unresolved CRITICAL finding
upstream. If you want container metrics, either:
- Wait for upstream to fix this (track the issue), or
- Manually patch the compose file to replace `privileged: true` with scoped
  `cap_add`/`cap_drop` + `security_opt: no-new-privileges:true` before
  enabling it, or
- Run `node_exporter` directly via systemd on the VM instead (the audit's
  own suggested alternative) — avoids the privileged-container pattern
  entirely

## 6. Set a strong ADMIN_PASSWORD on both consoles

```bash
grep ADMIN_PASSWORD .env
```
If blank, set one — generate with `openssl rand -base64 24` and store it in
your password manager. Use different passwords for Prod vs. Dev.

## 7. Confirm VLAN firewall isolation is actually working

From the `dune-dev` VM, try to reach `dune-prod`'s IP and vice versa:
```bash
# on dune-dev:
ping -c 3 <dune-prod-ip>      # should fail/timeout
curl -m 5 http://<dune-prod-ip>:8088   # should fail/timeout
```
If either succeeds, go back to `02-network-setup.md` Step 4 and fix the
inter-VLAN firewall zone policies before going further — this is the
isolation that contains blast radius if one VM is ever compromised.

## 8. Confirm iDRAC/Proxmox management plane has no WAN route

From outside your network entirely (phone on cellular), confirm you
**cannot** reach the Proxmox web UI or iDRAC directly — only via the VPN set
up in `02-network-setup.md` Step 6. This is your hypervisor-level admin
plane; it should never be internet-facing under any circumstance.

## 9. Rotate the Funcom tokens' file permissions

On each VM, confirm:
```bash
ls -la ~/dune-awakening-selfhost-docker/runtime/secrets/funcom-token.txt
```
Should show `-rw-------` (600), owned by your user, not world-readable.
`dune init` sets this automatically, but worth a one-time confirmation on
both VMs.

## 10. Schedule automated restarts (both VMs)

Multiple independent community reports (cited earlier in this project's
research) recommend restarting map-server processes roughly every 6 hours to
prevent progressive lag/memory degradation, even with adequate RAM. Set this
up rather than relying on manual restarts:
```bash
cd ~/dune-awakening-selfhost-docker
runtime/scripts/dune restart-schedule enable 04:00 15
# adjust the time to a low-player-count window for your community;
# 15 = minutes of in-game warning before the restart
```
