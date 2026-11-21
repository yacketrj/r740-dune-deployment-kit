# 09 - Observability: Prometheus, Grafana and burst tracking (2026-11-20)

**Status:** Current as of 2026-11-20 (Pacific). Built during the rubberbanding
investigation (`Project-Arrakis/meta`#99, fork issue 1352) to measure the
single-thread bursts in the game maps and to compare before and after the BIOS and
pinning changes in `07-live-tuning-2026-11.md`. The files are in `observability/`.

## 1. What it collects

| Layer | Source | Interval | Notes |
|---|---|---|---|
| Game maps, per map | `process-exporter` in the prod guest | 5 s | One group per map server, named `<Map>_p<PartitionIndex>`; per-thread CPU, so the game's main thread (`DuneSandboxServ`) is visible |
| Guest CPU, memory, PSI | node-exporter (Core's metrics stack) | 5 s | Per-vCPU busy share, steal, pressure |
| Host clocks, temperatures, NUMA | node-exporter on the Proxmox host, pushed by a Prometheus agent | 5 s | Per-core frequency (80 CPUs), hwmon temperatures, `numa_*` counters |
| Services | process-exporter | 5 s | Director, RabbitMQ (`beam.smp`), Postgres, dockerd, containerd |
| Game stack metrics | Core's own targets (RabbitMQ, Postgres, cAdvisor root) | 10-15 s | Unchanged |

Retention is 30 days or 8 GB on dune-prod (Core's default is 7 days / 2 GB).

Not collected yet: per-VM CPU and steal from the Proxmox API (a
`prometheus-pve-exporter` with a read-only token), and iDRAC temperatures, fans and
power (a Redfish exporter; change the iDRAC factory password first).

## 2. How it fits together

```
 Proxmox host (management LAN)                 dune-prod VM (Prod VLAN)
 ┌──────────────────────────────┐              ┌───────────────────────────────────────────┐
 │ node-exporter  127.0.0.1:9100│              │ obs-write-proxy (nginx)  <VLAN IP>:9091   │
 │ prometheus --agent :9092     │──remote_write▶│   only POST /api/v1/write, only from host │
 │   (no local database)        │   (push)     │ dune-prometheus 127.0.0.1:9090            │
 └──────────────────────────────┘              │ obs-process-exporter, node-exporter       │
                                               │ obs-grafana  <VLAN IP>:3000               │
                                               └───────────────────────────────────────────┘
```

The Prod VLAN cannot reach the management LAN (by design), so the host cannot be
scraped from the VM. The host pushes instead, and nothing on Prod ever connects into
the hypervisor. Prometheus's UI and API stay on `127.0.0.1`: the write proxy exposes
only `POST /api/v1/write` and only to the host's address, because the API has no
login and `--web.enable-lifecycle` allows reload and shutdown.

Host series carry `source="r740-host"` (job `host-node`). They share metric names
with the guest's `node_*` series, so every rule and panel must filter on `job` or
`source`. The burst rules use `job="dune-node"`; an unfiltered rule mixes the host's
80 CPUs with the guest's 60.

## 3. Install on the prod VM

Everything lives outside Core's managed checkout (`/home/dune/observability/`), so a
self-update cannot remove it. Copy `observability/prod/` there and `observability/tools/`
beside it, then:

1. Edit `docker-compose.grafana.yml`: set `GF_SERVER_ROOT_URL` and the bind address.
   Create the admin password in a root-only file, never in this repo, and set your own
   afterwards: `grafana cli admin reset-admin-password --password-from-stdin`.
2. Edit `write-proxy/nginx.conf`: `allow` the Proxmox host's management IP.
3. `docker compose -f docker-compose.grafana.yml up -d`
4. `docker compose -f docker-compose.exporters.yml up -d` (process-exporter and the
   write proxy).
5. `./metrics-up.sh dune-prometheus` recreates Core's Prometheus with
   `docker-compose.metrics.override.yml` (30 d / 8 GB, remote-write receiver, our
   `prometheus.yml` and `rules-extra/`). **Use `metrics-up.sh`, not `dune metrics
   restart`**: the latter starts Core's own file only and reverts to 7 d / 2 GB.
6. Dashboards in `dashboards/` are provisioned (folder "Dune"). They are files:
   edit `tools/gen_dashboards.py`, run `gen_dashboards.py <dir>`, copy the JSON to
   `dashboards/`; edits made in the Grafana UI are not kept.

`prometheus/prometheus.yml` is a copy of Core's `runtime/metrics/prometheus.yml` with
the node job at 5 s, the process job and the extra rules directory added. Diff it
against Core's file after a stack update.

## 4. Install on the Proxmox host

Debian packages from the standard repository (no extra downloads):

```bash
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod 755 /usr/sbin/policy-rc.d
apt-get install -y --no-install-recommends prometheus-node-exporter prometheus
rm -f /usr/sbin/policy-rc.d
install -m 644 observability/host/prometheus-node-exporter.default /etc/default/prometheus-node-exporter
install -m 644 observability/host/prometheus.default /etc/default/prometheus
install -m 644 observability/host/prometheus-agent.yml /etc/prometheus/prometheus.yml
systemctl restart prometheus-node-exporter && systemctl enable --now prometheus
```

The temporary `policy-rc.d` stops the package from starting a full Prometheus
server on all interfaces before agent mode is configured. Edit the `remote_write`
URL in `prometheus-agent.yml` first. Both services listen on `127.0.0.1` only.
Undo: `systemctl disable --now prometheus prometheus-node-exporter`, then
`apt-get remove` both.

## 5. Dashboards and burst tracking

Two dashboards, provisioned in the folder "Dune":

- **Dune - Bursts and maps:** main-thread CPU per map with a 0.9-core burst line,
  bursts per interval by map, whole-process CPU, guest vCPUs above 90%, steal and
  CPU pressure.
- **Dune - Host, VM and services:** host core clocks, temperatures, NUMA misses,
  guest load and memory, service CPU.

The recording rules in `prometheus/rules-extra/dune-bursts.yml` define a burst as a
map's main thread at or above 0.9 core (`dune:map_main_thread_hot`); `changes()` of
that series counts bursts. Success after the 2026-11-20 BIOS and pin changes looks
like fewer and shorter bursts per hour than the 2026-11-18/19 baseline (about 1.2
Atrium events per hour) and busy host cores at 3.8-3.9 GHz.

A baseline caveat: per-map data only starts on 2026-11-20 after the reboot, so
before/after comparisons of the main thread are only possible going forward. The
guest-level series and the older perf-sampler logs cover the period before.

Colors follow the dataviz reference palette (dark-mode steps, validated), assigned
to each map in a fixed order so a map keeps its color. A Grafana annotation tagged
`change` marks the reboot; add one for each later change.

Public sharing: a dashboard can be shared with Grafana's "Public dashboards" (a
read-only link, no data source access). The operator made only the bursts dashboard
public; the host dashboard stays private. Treat the link as the access control and
revoke or regenerate it if it leaks. Consider a Cloudflare rate limit on
`/api/public/*`.

## 6. Security notes

- **Game command lines contain secrets** (a service auth token and the database
  password). `process-exporter` names must come only from named regex captures (map
  name, partition index). Never use `{{.Cmdline}}` in a name template.
- The write proxy is the only new inbound path on the Prod VLAN. It allows one
  method, one path and one source address.
- Do not print `.env` lines or the Grafana password file into logs or chat.

### Credentials: one token per purpose

Never reuse a token for a second job, and never widen one to save creating another.
Keep each secret in a root-only file (mode 600) outside any repo; record its path,
never its value, in notes and docs. A token for a one-time job is deleted afterwards.

| System | Token | Scope | Used by |
|---|---|---|---|
| Cloudflare | DDNS | Zone DNS edit and Zone read, one zone | the DDNS service only |
| Cloudflare | Rate limit (create when needed) | Zone WAF/Rulesets edit, one zone | one-time setup of the `/api/public/*` rule, then delete |
| Proxmox | `metrics@pve!exporter` | `PVEAuditor` only, privilege separation on | the pve-exporter only; a new consumer gets its own token |
| Grafana | per-purpose service-account tokens | read-only role | scripts; the admin password is for the operator only |
| iDRAC | a dedicated read-only Redfish user | read-only | the Redfish exporter, never `root` |

A token that fails a read-only probe of the permission you expect (for example a
403 on `GET /zones/<id>/rulesets`) lacks it; check with a probe before relying on it,
passing the token through a shell variable so it is never printed. Two copies of the
same secret in two files count as one credential with two places to rotate; keep one.

## 7. Known limitations

- **cAdvisor shows no per-container data.** Docker 29 uses the containerd image
  store, and cAdvisor v0.52.1 cannot find the legacy layer metadata it reads
  (`failed to identify the read-write layer ID`), so only the root cgroup is exported.
  Sharing the host cgroup namespace (`cgroup: host`) did not help and was reverted. Per-map process
  data from process-exporter replaces it for this purpose.
- Core's `dune metrics start` no longer starts Grafana (its compose file has no
  Grafana service). The Grafana in `observability/` replaces it.
- A self-update can replace Core's metrics files; the overrides and our
  `prometheus.yml` copy live outside them but should be re-diffed.
