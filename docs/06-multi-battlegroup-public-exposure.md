# Running a Second, Independently-Public Battlegroup on One WAN IP

**Status: NOT YET VERIFIED END-TO-END.** This document exists to preserve a
correct, source-verified procedure for the *mechanical* part of this setup
(distinct ports, port forwards, container config) so it's ready to test —
it does **not** confirm the whole thing actually works with real players,
because one critical piece is explicitly unverified. Read the "What Is NOT
Yet Verified" section before building any real plan around this.

This is a different scenario from the Prod/Dev split covered by
`00-START-HERE.md`/`02-network-setup.md`: those two VMs are on **separate
VLANs with separate IPs** (`192.168.20.10`, `192.168.21.10`), so they never
share a port and no remapping is needed between them. This document covers
a **third** scenario: two battlegroups that are **both meant to be publicly
reachable from the internet, behind the same single WAN IP** — e.g. a
second public "Prod2" VM in addition to the existing Prod. Tracked as
[issue #42](https://github.com/yacketrj/r740-dune-deployment-kit/issues/42)
in this repo.

## Why This Is Needed At All

A single WAN IP can only forward each port number to one internal
destination. If Prod1 and Prod2 both bind the game/RabbitMQ ports at their
defaults, the router literally cannot forward the same WAN port to two
different internal IPs — one of them needs to run on different ports, and
the WAN-side forwards need to route each port range to the correct VM.

## What Actually Needs to Change (verified against upstream source)

The upstream `dune-awakening-selfhost-docker` project exposes several
independent port-configuration mechanisms. **They are not all the same
kind of setting** — mixing them up is exactly the kind of "the override
isn't wired to what you think it's wired to" mistake that caused this
project's own command-auth-token production outage
(`dune-awakening-selfhost-docker/docs/security/command-auth-token-vulnerability-and-failed-remediation.md`).
Verified directly against the actual source (not the docs) as of this
writing:

### Group 1 — real `.env` overrides (confirmed via `runtime/scripts/runtime-env.sh:83-88`)

These genuinely change what port the container binds to, and are safe to
set in `.env` on Prod2's VM:

| Variable | Default | Used by |
|---|---|---|
| `POSTGRES_PORT` | 15432 | `start-postgres.sh` |
| `RMQ_ADMIN_PORT` | 32573 | `start-rabbitmq.sh` |
| `RMQ_GAME_PORT` | 31982 | `start-rabbitmq.sh`, `start-server-gateway.sh` |
| `RMQ_GAME_HTTP_PORT` | 31983 | `start-rabbitmq.sh`, `start-server-gateway.sh` |
| `TEXT_ROUTER_PORT` | 5059 | `start-text-router.sh` |
| `DIRECTOR_PORT` | 11717 | `start-director.sh` |
| `ADMIN_WEB_PORT` | 8088 (via `ADMIN_BIND_PORT`) | `docker-compose.web.yml:33`, `console.sh` |

Since Postgres/RabbitMQ-admin/Director are already loopback-bound
(`127.0.0.1:<port>`, confirmed in `start-postgres.sh:49`,
`start-rabbitmq.sh:109`, `start-director.sh:276`), these don't strictly
need to change between two VMs on separate machines — they only matter if
you ever run two battlegroups on the **same host/VM** sharing one Docker
daemon, which upstream's own fixed container-naming scheme
(`dune-rmq-game`, `dune-postgres`, etc. — see issue #42's own findings)
does not support at all. **This document assumes Prod2 is a separate VM**,
same as Prod1 — in that case only the two ports that are actually forwarded
through the router (`RMQ_GAME_PORT`, `RMQ_GAME_HTTP_PORT`) need to differ,
so the WAN-side forwards can tell the two VMs apart.

### Group 2 — NOT `.env`-driven, despite looking like it (the actual mistake this document exists to prevent)

`CLIENT_PORT_BASE` and `IGW_PORT_BASE` (the actual game-client and
inter-server ports, defaults 7777/7888) are **not** read from `.env` by
anything that starts the game server engine. Confirmed by reading every
script that launches a map process
(`start-server-survival-1.sh:33-34`, `start-server-overmap.sh:33-34`,
`spawn-server.sh:70-71`, `local-loopback-optimize.sh:15-16`): they all call
`resolve_client_port_base`/`resolve_igw_port_base`
(`runtime-env.sh:585-591`), which read `runtime/generated/usersettings.json`'s
`engine.port`/`engine.igw_port` fields — never an environment variable.

The **only** place `CLIENT_PORT_BASE`/`IGW_PORT_BASE` env vars are actually
read is the console API's own diagnostic preflight check
(`console/api/src/preflight.js:31-32`, wired via
`docker-compose.web.yml:51-52`) — a display-only "is this port free"
health check in the admin console UI. **Setting them in `.env` alone does
not move where the game server actually listens.** If you only do this,
the console's own health check will happily agree with a port the engine
isn't actually using.

**To actually change the game/IGW port, you must also change
`usersettings.json`'s `engine.port`/`engine.igw_port` values** — as of the
current console UI, the structured "Edit UserEngine" form explicitly
excludes these two fields (confirmed:
`console/web/src/features/maps/MapsPanel.tsx:1081` filters `port` and
`igw_port` out of the editable field list — they're treated as
infrastructure-level, not gameplay, settings). The two ways this is
actually exposed to an operator today:

1. **Raw INI editor** (Dune Docker Console web UI → Sietches/Maps →
   UserEngine.ini raw editor): edit the `[URL]` section directly —
   `Port=<value>` and `IGWPort=<value>` — then Save. Confirmed this maps
   directly to `usersettings.py`'s known field mapping
   (`"port": ("URL", "Port", "7777")`, `"igw_port": ("URL", "IGWPort",
   "7888")` — `runtime/scripts/usersettings.py:81-82`).
2. **The deprecated CLI manager** (`runtime/scripts/manager.sh`, if still
   directly callable on your installed version — the `dune manager`/
   `dune menu` wrapper command itself now only prints a message pointing
   at the web console instead of launching this menu, confirmed via
   `runtime/scripts/dune:203-205`): Main Menu → **3) Sietches** → **4)
   Edit UserEngine** → **1) Port** / **2) IGWPort**.

**Set both** — the real `usersettings.json` value (via one of the two
methods above) so the engine actually binds there, AND the `.env`
`CLIENT_PORT_BASE`/`IGW_PORT_BASE` values so the console's own health
check agrees with reality instead of reporting a stale/incorrect port.

### Example `.env` additions for Prod2 (verified variable names only — see caveats above)

```bash
# Prod2 -- second public battlegroup, distinct ports so WAN forwards can
# route to the correct VM. CLIENT_PORT_BASE/IGW_PORT_BASE here only affect
# the console's own preflight display -- the actual engine port MUST be
# changed separately via the raw UserEngine.ini editor or manager.sh
# (see body of this doc). Setting these two alone does nothing to the
# real game server.
CLIENT_PORT_BASE=7877
IGW_PORT_BASE=7988

# These ARE real overrides -- read directly by the container start scripts.
RMQ_GAME_PORT=32982
RMQ_GAME_HTTP_PORT=32983
ADMIN_WEB_PORT=8090

# Only needed if Prod2 somehow shares a Docker daemon/host with another
# battlegroup (not the case in this kit's documented one-VM-per-battlegroup
# model) -- included for completeness since they were part of the original
# proposal, but not required for the separate-VM model this doc assumes:
# POSTGRES_PORT=16432
# RMQ_ADMIN_PORT=33573
# TEXT_ROUTER_PORT=5159
# DIRECTOR_PORT=12717
```

**Then, separately, via the raw UserEngine.ini editor or `manager.sh`:**
set `Port=7877` and `IGWPort=7988` in `usersettings.json` to match.

## UCG-Max Port Forwarding for Prod2

Per `02-network-setup.md` Step 5, Prod1 already uses the WAN-side default
ports (7777-7810/UDP, 31982/TCP, 31983/TCP) forwarded to its VLAN 20 IP.
Prod2 needs its **own** WAN-side ports forwarded to its own VM IP (example
below assumes Prod2 also lives on VLAN 20, e.g. `192.168.20.11` — adjust to
match your actual addressing):

| Name | WAN Port(s) | Forward IP | Forward Port(s) | Protocol |
|---|---|---|---|---|
| Dune Game Traffic (Prod2) | 7877-7910 | 192.168.20.11 | 7877-7910 | UDP |
| Dune RMQ Game (Prod2) | 32982 | 192.168.20.11 | 32982 | TCP |
| Dune RMQ HTTP (Prod2) | 32983 | 192.168.20.11 | 32983 | TCP |

Same rule as the original Step 5 applies: **do not create these forwards
until Prod2 is actually running and ready to take traffic** — an early,
unused forward is dead weight at best, and this is a live network with a
real, currently-connected player base on Prod1 that must not be disrupted
by this change.

## What Is NOT Yet Verified — Read This Before Relying On Any Of The Above

Per issue #42, it is **explicitly unconfirmed** whether Funcom's FLS
backend and the game client actually honor a non-default
`RMQ_GAME_PORT`/`RMQ_GAME_HTTP_PORT` end-to-end, or whether they silently
assume the well-known default (31982/31983) regardless of what the
`GatewayDeclareFarmStatus` API call declares
(`start-server-gateway.sh:82`, `--RMQGameHostname="$SERVER_IP"`). The
container will happily bind to and advertise a non-standard port — that
only proves the self-hosting kit's own code path works, not that Funcom's
closed-source backend actually routes real player connections there.

This is the identical failure pattern (not just a similar one) to the
command-auth-token incident: assuming a self-hosting-kit-exposed override
is honored by Funcom's backend without end-to-end verification, which
caused two real, confirmed production outages the first two times it
happened with a different specific value.

**Before building a real two-public-battlegroup plan around this:**

1. Stand up Prod2 as a genuinely disposable, non-critical test instance
   first — not a real second production battlegroup with real players
   depending on it.
2. Set the non-default `RMQ_GAME_PORT`/`RMQ_GAME_HTTP_PORT` per this
   document's procedure.
3. Confirm via `docker logs dune-server-gateway` that the
   `GatewayDeclareFarmStatus` log line reports the correct non-default
   `GameRmqAddress`/`GameRmqHttpAddress`.
4. Attempt an actual client connection **from outside your LAN** (real
   WAN path, not just internal reachability) and confirm it successfully
   connects through the non-standard port — not just that the container
   is listening.
5. Only after step 4 succeeds should this be considered validated enough
   to plan a real Prod2 rollout around.

If step 4 fails, the port-remapping approach in this document does not
work for a publicly-reachable battlegroup, and a different approach
(e.g., separate WAN IPs, if your ISP/UCG-Max setup supports it) would be
needed instead — do not fall back to assuming the default ports "probably
still work anyway" without testing, since that assumption is exactly what
this document exists to avoid repeating.

## Related

- [Issue #42](https://github.com/yacketrj/r740-dune-deployment-kit/issues/42) —
  original finding and open verification question this document is based on.
- `docs/02-network-setup.md` Step 5 — the existing single-battlegroup WAN
  port-forward setup this document extends.
- `dune-awakening-selfhost-docker/docs/security/command-auth-token-vulnerability-and-failed-remediation.md` —
  the prior incident this document's core caution is modeled on.
