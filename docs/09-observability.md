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

Per-VM CPU and memory come from the Proxmox API through `prometheus-pve-exporter`
with a read-only token (15 s; job `host-pve`, pushed by the host agent).

Players online, per-partition readiness, per-map memory and the Funcom FLS health
checks come from the console's HTTP API through a small adapter (`obs-dune-api`,
10 s; job `dune-api`). The console has no Prometheus endpoint, so the adapter polls
four read-only JSON endpoints and serves `/metrics`.

Board temperatures (CPU packages, inlet, exhaust), fan speeds and server power draw
come from the board's sensors through in-band IPMI (`prometheus-ipmi-exporter` on
the host, 15 s; job `host-ipmi`). It needs no iDRAC login.

Not collected yet: per-DIMM and per-PSU readings (they need the iDRAC's Redfish
interface: change the iDRAC factory password first, and use a dedicated read-only
Redfish user).

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

### CPU placement

The map servers are pinned to guest CPUs 0-39 (the guest's first NUMA node) by `dune-game-pin`. Every monitoring
container is pinned to CPUs 40-59 with `cpuset: "40-59"` in its compose file (Core's own Prometheus,
cAdvisor and exporters through `docker-compose.metrics.override.yml`), so a scrape, a Grafana query or a
database compaction can never run on a core a map's main thread is using. Measured cost on 2026-11-23: Prometheus
about 0.03 of a core and 240 MB, Grafana under 0.1% of a core, the whole stack well under 0.1 core and about 600 MB of
the VM's 60 vCPUs and 192 GB; over 24 hours no tick-rate dip came within a minute of a Prometheus compaction.
Postgres, RabbitMQ and the game are not moved. Live change without a restart: `docker update --cpuset-cpus 40-59
<container>`. Undo: `docker update --cpuset-cpus ""` and remove the `cpuset` lines.

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

### Per-VM metrics (pve-exporter)

There is no Debian package; install the pinned release from PyPI into its own venv:

```bash
python3 -m venv /opt/pve-exporter
/opt/pve-exporter/bin/pip install "prometheus-pve-exporter==3.12.0"
pveum user add metrics@pve --comment "read-only monitoring"
pveum acl modify / --users metrics@pve --roles PVEAuditor
install -d -m 750 -o root -g prometheus /etc/prometheus-pve-exporter
pveum user token add metrics@pve exporter --privsep 1 --output-format json   # keep the value out of chat and logs
pveum acl modify / --tokens 'metrics@pve!exporter' --roles PVEAuditor
# write the token into /etc/prometheus-pve-exporter/pve.yml (see host/pve.yml.example), root:prometheus, mode 640
install -m 644 observability/host/prometheus-pve-exporter.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now prometheus-pve-exporter
```

The token has `PVEAuditor` only (read-only), privilege separation on, and the
exporter listens on `127.0.0.1:9221`. The `host-pve` job in `prometheus-agent.yml`
(metrics path `/pve`, `module=default`, `cluster=1`, `node=1`) scrapes it; reload
the agent with `systemctl reload prometheus`. Query it with those parameters; a
request without `cluster` and `node` returns only partial data. Undo:
`systemctl disable --now prometheus-pve-exporter`, `pveum user delete metrics@pve`
(removes its token and ACLs), `rm -r /opt/pve-exporter /etc/prometheus-pve-exporter`.

### Console API adapter (prod VM)

1. In the console, create one API key just for monitoring with **read** scope only
   (server status, map status, map memory, online players). Never reuse another key.
2. Save it on the VM at `/home/dune/observability/console-api-monitor.key`, mode 600,
   outside any repo. Do not paste it into chat or notes.
3. Copy `observability/prod/dune-api-exporter/` and `docker-compose.dune-api.yml`
   next to the other files, then
   `COMPOSE_IGNORE_ORPHANS=true docker compose -f docker-compose.dune-api.yml up -d`.
   The container runs as the file owner's uid (so it can read the key), read-only,
   no capabilities, 0.25 CPU / 64 MB.
4. Add the `dune-api` job from `prometheus/prometheus.yml` and reload Prometheus
   (`POST /-/reload`).

Series: `dune_players_online`, `dune_population_capacity`, `dune_server_ready`,
`dune_partition_ready` / `_alive` (per partition), `dune_gameserver_ready`,
`dune_fls_ok{check}`, `dune_map_memory_used_bytes` / `_limit_bytes`,
`dune_map_swap_used_bytes`, `dune_api_up`. Many partitions (story maps) are dormant
and read 0 by design; any alert on readiness must be limited to the always-on maps
(Survival, Overmap, Deep Desert). The third dashboard, "Dune - Game state and
players", is private; population is deliberately not on the public bursts dashboard.
Undo: `docker compose -f docker-compose.dune-api.yml down`, delete the key in the
console and the key file, remove the job.

### Server tick rate (from the game's own log)

The game does not log frame times, but every Unreal log line begins with
`[timestamp][frame counter mod 1000]`. For two lines 1 to 25 s apart, the frame
difference (mod 1000) divided by the time difference is the **server tick rate**.
Measured on the live log: median exactly 20.0 Hz (the target), p1 17.4 Hz, so dips
are visible. `obs-game-log` (`docker-compose.game-log.yml`,
`game-log-exporter/game_log_exporter.py`) follows the live log of each map (only
files written in the last 10 minutes), reads only the line prefix (game logs can
contain tokens; nothing from a line body is stored or printed), and exports counters
(`dune_game_frames_total`, `dune_game_frame_seconds_total`,
`dune_game_slow_seconds_total`, `dune_game_physics_throttled_total`, per `server`).
`rules-extra/dune-tick.yml` records `dune:game_tick_rate:hz` and alerts when a map
stays below 18 Hz for 2 minutes. The container mounts the stack's `runtime/game`
directory read-only; set `GAME_RUNTIME_DIR` if yours differs.

Limits: a map that logs nothing has no tick data (Overmap was silent when this was
built), history starts when the exporter starts, and a gap over 25 s is skipped
rather than guessed. Undo: `docker compose -f docker-compose.game-log.yml down`,
remove the job and rule file.

### Alerting (Alertmanager and Discord)

Alert rules in `prometheus/rules-extra/dune-alerts.yml` (server or an always-on
partition not ready, FLS check failing, burst rate, map memory and swap, CPU steal,
CPU/inlet temperature, fan failure, host metrics missing) go to Alertmanager
(`obs-alertmanager`, `docker-compose.alertmanager.yml`) and from there to one Discord
channel.

1. Create a webhook for the target channel in Discord (Edit Channel, Integrations).
   A webhook can only post to that channel; it is the only credential this needs.
2. Save the URL at `/home/dune/observability/alertmanager/discord-webhook-bot.url`
   (the compose file mounts this one), mode 600, directory mode 700, outside any repo.
   Use a separate channel from the status message: firing and resolved posts bury a
   single edited status message if they share a channel. Never paste it into chat or notes;
   anyone holding it can post to the channel.
3. `docker compose -f docker-compose.alertmanager.yml up -d` (container runs as the
   file owner, read-only, no capabilities), then add the `alerting:` block from
   `prometheus/prometheus.yml` and reload Prometheus.

Alerts are grouped by name, first sent after 30 s, repeated every 4 h (critical 1 h),
and a resolved message is sent. **Check which channel before enabling:** Prometheus
also evaluates Core's own rules, so connecting Alertmanager immediately sends
anything already firing (here: RabbitMQ unroutable messages, and
`DuneContainerMissing`, a false positive from the cAdvisor limitation in section 7,
which is silenced for 30 days with `amtool silence add`). `DuneRabbitMQUnroutableMessages` is silenced for a year: the brokers drop a steady ~75 messages/s from the unbound `heartbeats` exchange, so the stock rule never clears (fork issue #1356). Readiness rules only cover
the always-on maps because story-map partitions are dormant by design. Undo:
`docker compose -f docker-compose.alertmanager.yml down`, delete the webhook in
Discord, remove the `alerting:` block.

### Player-facing status message (Discord)

`obs-status-post` (`docker-compose.status-post.yml`, `status-post/status_post.py`)
keeps one message in a Discord channel up to date, editing it in place every 5
minutes so the channel is not spammed. It shows status, players, maps online, a
game-performance rating (Smooth under 0.6 of a core on the busiest map main thread,
Busy to 0.9, Heavy load above) with lag spikes in the last hour, server CPU, memory,
disk, network in and out, and uptime. It is written for players: no addresses, host
names, temperatures or player names. It reads from Prometheus and uses the same
webhook file as the status message channel (`discord-webhook.url`), which is
deliberately a different webhook from alerting so the status message stays visible. The first run posts the message and stores its id in `status-post/state`;
if the message is deleted it posts a new one. Preview without sending:
`python status_post.py --dry-run`. Undo: `docker compose -f
docker-compose.status-post.yml down`, then delete the message in Discord.

### Board sensors (in-band IPMI)

`/dev/ipmi0` exists on the host, so the sensors can be read locally with no network
path and no credentials. Debian package, same no-auto-start trick as above:

```bash
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod 755 /usr/sbin/policy-rc.d
apt-get install -y --no-install-recommends prometheus-ipmi-exporter
rm -f /usr/sbin/policy-rc.d
install -m 644 observability/host/ipmi_local_inband.yml /etc/prometheus/
install -m 644 observability/host/prometheus-ipmi-exporter.default /etc/default/prometheus-ipmi-exporter
install -D -m 644 observability/host/prometheus-ipmi-exporter.override.conf /etc/systemd/system/prometheus-ipmi-exporter.service.d/override.conf
systemctl daemon-reload && systemctl enable --now prometheus-ipmi-exporter
systemctl reload prometheus      # after adding the host-ipmi job from prometheus-agent.yml
```

`/dev/ipmi0` is root-only, so the drop-in runs the exporter as root with
confinement (`ProtectSystem=strict`, no new privileges, restricted address
families); it listens on `127.0.0.1:9290` only. A scrape takes about 1.2 s, so keep
the interval at 15 s or more. Undo: `systemctl disable --now
prometheus-ipmi-exporter`, remove the drop-in, `apt-get remove` the package, and
delete the `host-ipmi` job.

## 5. Dashboards and burst tracking

Five dashboards, provisioned in the folder "Dune" and sharing one Dune look (below). **Arrakis - Overview**
is the home page: state, players, tick rate, load, temperature, storage, alerts and queue backlog
as tiles, four charts, and links to the others. (**Dune - Game state and players**
shows population, map readiness, map memory, FLS health and tick rate from the console
API and the game log; **Dune - Database and queues** shows Postgres connections,
transactions, cache hit ratio, size and RabbitMQ backlog, rates, connections and
memory from Core's own exporters; both are private):

- **Dune - Bursts and maps:** main-thread CPU per map with a 0.9-core burst line,
  bursts per interval by map, whole-process CPU, guest vCPUs above 90%, steal and
  CPU pressure.
- **Dune - Database and queues:** six tiles (Postgres up, connections, limit, database
  size, deadlocks in 24 h, messages waiting) and panels for connections by state,
  transactions, cache hit ratio, rows changed, rollback share, and per broker (admin and
  game) messages waiting, unacknowledged, connections, publish and deliver rates,
  unroutable drops, memory against limit and consumers. On a healthy stack the admin
  broker publishes about 81 messages/s and delivers about 10, and drops about 75 as
  unroutable (the unbound heartbeats exchange, fork issue #1356): published minus
  delivered matches the drops, which is why that alert is silenced.
- **Dune - Host, VM and services:** host core clocks, temperatures, NUMA misses,
  guest load and memory, service CPU, and per-VM CPU and memory from the Proxmox
  API, board temperatures (CPU, inlet, exhaust), fan speeds and power draw from
  IPMI. (The hypervisor's memory view of a VM includes the guest's file cache, so
  a VM can read near 100% without the game using that much.)
  A lower block covers the network and disks: NIC errors and drops (guest eth0, host
  nic0), TCP retransmit share, disk busy time, read and write latency, disk I/O
  pressure, Proxmox storage used (thin pool `local-lvm` and root `local`; a full thin
  pool freezes every VM on it), and swap activity. All of it is zero or near zero when
  healthy, so a steady non-zero line is the signal. Baseline on 2026-11-23: host NIC in
  drops about 0.03 per second, thin pool about 27% used, host root storage about 64%.

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

### The Dune look

Every dashboard has a banner (dune ridges, two moons, the heading in Dune Rise), section rows, and a
bar of links to the others. Grafana 11.1 OSS cannot be re-themed, so the look is drawn inside the
dashboards:

- **Colours** are the Awakening look of the public MIT design tokens in
  `Project-Arrakis/tabr-tau` (`design/assets/tokens-awakening.css`): warm charcoal, bone text, spice orange,
  gold headings, bronze rules and its status colours. They are used for chrome and for tile states
  (`observability/tools/dune_theme.py`).
- **Chart series keep the validated palette** (`gen_dashboards.py`; blue, orange, aqua, yellow,
  magenta, violet, checked with the dataviz validator against Grafana's panel colour), assigned by
  name so a map or broker keeps its colour on every dashboard. The theme's spice orange is too light for
  the validated lightness band, so it is not used for series.
- **State tiles show a word** (READY, UP, OK, NOT READY) as well as a colour, and threshold tiles turn
  amber or red at set values, so colour never carries meaning alone.
- **The heading typeface** is Dune Rise (SIL Open Font License 1.1, unmodified; licence text in
  `observability/tools/fonts/`), embedded in the banner image so it needs no font install.
- The banner is an image inside a text panel. Grafana strips some CSS from text panels and clips
  them to the panel, so the banner is an inset card, not edge to edge. Public dashboards follow the
  viewer's own light or dark setting; the banner is dark either way.
- Set the home page and dark default once (the home dashboard is an org setting, not a file):
  `PUT /api/org/preferences` with `{"homeDashboardUID":"dune-overview","theme":"dark"}`.

Check any change by rendering it: load the dashboard in a headless browser and look at the
screenshot, and run each panel's queries through Grafana's own `/api/ds/query`, because queries
that work against Prometheus directly can still fail in Grafana (duplicate query ids did).

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
