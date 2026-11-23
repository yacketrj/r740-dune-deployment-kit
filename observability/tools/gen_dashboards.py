#!/usr/bin/env python3
"""Generate the Grafana dashboards for the Dune R740 stack (meta#99, fork#1352).

Colors: dataviz reference palette, dark-mode categorical steps, assigned to an entity in
a fixed order (never by rank). Status red is reserved for threshold/critical use.
Usage: gen_dashboards.py <output-dir>
"""
import json
import sys
from pathlib import Path

DS = {"type": "prometheus", "uid": "prometheus"}
BLUE, ORANGE, AQUA, YELLOW, MAGENTA, GREEN = "#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#0ca30c"
RED = "#e66767"
MAP_COLORS = {
    "Survival_1_p1": BLUE,
    "Survival_1_p37": ORANGE,
    "DeepDesert_1_p8": AQUA,
    "DeepDesert_1_p36": YELLOW,
    "Overmap_p2": MAGENTA,
}
SVC_COLORS = {
    "dockerd": BLUE,
    "containerd": ORANGE,
    "Director": AQUA,
    "beam.smp": YELLOW,
    "postgres": MAGENTA,
    "prometheus": GREEN,
}

_id = 0


def nid():
    global _id
    _id += 1
    return _id


def target(expr, legend="", ref="A", instant=False):
    t = {"datasource": DS, "expr": expr, "legendFormat": legend, "refId": ref}
    if instant:
        t["instant"] = True
    return t


def color_overrides(mapping):
    return [
        {
            "matcher": {"id": "byName", "options": name},
            "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": c}}],
        }
        for name, c in mapping.items()
    ]


def ts(title, desc, targets, x, y, w, h, unit="none", mn=0, mx=None, overrides=None,
       threshold=None, bars=False, stack=False, decimals=None, fixed=None):
    custom = {
        "drawStyle": "bars" if bars else "line",
        "lineWidth": 2,
        "fillOpacity": 60 if bars else 0,
        "showPoints": "never",
        "spanNulls": False,
        "stacking": {"mode": "normal" if stack else "none", "group": "A"},
        "axisBorderShow": False,
        "gradientMode": "none",
    }
    defaults = {"unit": unit, "min": mn, "custom": custom,
                "color": {"mode": "fixed", "fixedColor": fixed} if fixed else {"mode": "palette-classic"}}
    if mx is not None:
        defaults["max"] = mx
    if decimals is not None:
        defaults["decimals"] = decimals
    if threshold is not None:
        custom["thresholdsStyle"] = {"mode": "line"}
        defaults["thresholds"] = {"mode": "absolute", "steps": [
            {"color": "transparent", "value": None}, {"color": RED, "value": threshold}]}
    return {
        "id": nid(), "type": "timeseries", "title": title, "description": desc,
        "datasource": DS, "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "fieldConfig": {"defaults": defaults, "overrides": overrides or []},
        "options": {
            "legend": {"displayMode": "table" if len(targets) > 1 else "list", "placement": "bottom",
                       "calcs": ["max", "lastNotNull"] if len(targets) > 1 else []},
            "tooltip": {"mode": "multi", "sort": "desc"},
        },
        "targets": targets,
    }


def stat(title, desc, expr, x, y, w=4, h=4, unit="none", decimals=None, red_at=None, color=None):
    defaults = {"unit": unit, "color": {"mode": "fixed", "fixedColor": color or "text"}}
    if decimals is not None:
        defaults["decimals"] = decimals
    if red_at is not None:
        defaults["color"] = {"mode": "thresholds"}
        defaults["thresholds"] = {"mode": "absolute", "steps": [
            {"color": "text", "value": None}, {"color": RED, "value": red_at}]}
    return {
        "id": nid(), "type": "stat", "title": title, "description": desc, "datasource": DS,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "colorMode": "value", "graphMode": "none", "textMode": "value"},
        "targets": [target(expr, instant=False)],
    }


def dashboard(uid, title, desc, panels, tags):
    return {
        "uid": uid, "title": title, "description": desc, "tags": tags, "schemaVersion": 39,
        "version": 1, "editable": True, "graphTooltip": 1, "refresh": "10s",
        "time": {"from": "now-6h", "to": "now"}, "timezone": "browser",
        "annotations": {"list": [{
            "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": True,
            "iconColor": MAGENTA, "name": "Changes",
            "target": {"type": "tags", "tags": ["change"], "limit": 100, "matchAny": False, "queryType": "tags"},
        }]},
        "templating": {"list": []}, "links": [], "panels": panels,
    }


def bursts():
    p = []
    p += [
        stat("Maps saturated now", "Map main threads at or above 0.9 core right now.",
             "sum(dune:map_main_thread_hot)", 0, 0, red_at=1, decimals=0),
        stat("Busiest map main thread", "Highest main-thread CPU of any map (1.0 = one core).",
             "max(dune:map_main_thread:cores)", 4, 0, decimals=2),
        stat("Saturated time in range", "Total seconds a map main thread was at or above 0.9 core, summed over all maps.",
             "sum(sum_over_time(dune:map_main_thread_hot[$__range]))*5", 8, 0, unit="s", decimals=0),
        stat("Bursts in range", "Number of times any map's main thread crossed 0.9 core (rising edges).",
             "sum(changes(dune:map_main_thread_hot[$__range]))/2", 12, 0, decimals=0),
        stat("Guest vCPUs above 90%", "vCPUs of dune-prod busier than 90% over 15 s.",
             "dune:vcpu_hot:count", 16, 0, decimals=0),
        stat("Busiest guest vCPU", "Highest single-vCPU busy share of dune-prod over 15 s.",
             "dune:vcpu_busy_max:ratio", 20, 0, unit="percentunit", decimals=0),
    ]
    p.append(ts("Main thread CPU per map",
                "The game's main thread per map is single-threaded, so this is the limit. 1.0 means one core saturated; the red line is the 0.9 burst threshold.",
                [target("dune:map_main_thread:cores", "{{groupname}}")],
                0, 4, 24, 9, mn=0, mx=1.2, overrides=color_overrides(MAP_COLORS), threshold=0.9, decimals=2))
    p.append(ts("Bursts per interval, by map",
                "How often each map's main thread crossed 0.9 core in each interval. Compare before and after the 2026-11-20 BIOS and pinning changes.",
                [target("sum by (groupname)(changes(dune:map_main_thread_hot[$__interval]))/2", "{{groupname}}")],
                0, 13, 12, 8, overrides=color_overrides(MAP_COLORS), bars=True, stack=True, decimals=0))
    p.append(ts("Whole-process CPU per map",
                "All threads of each map server, in cores. Higher than the main thread when worker threads are busy.",
                [target("dune:map_process:cores", "{{groupname}}")],
                12, 13, 12, 8, overrides=color_overrides(MAP_COLORS), decimals=2))
    p.append(ts("Guest vCPUs above 90% busy",
                "Count of dune-prod vCPUs over 90% busy, 15 s window.",
                [target("dune:vcpu_hot:count", "vCPUs above 90%")],
                0, 21, 8, 7, decimals=0, fixed=BLUE))
    p.append(ts("CPU steal",
                "Share of vCPU time stolen by the hypervisor (host contention).",
                [target("dune:cpu_steal:ratio", "steal")],
                8, 21, 8, 7, unit="percentunit", fixed=ORANGE))
    p.append(ts("CPU pressure (waiting)",
                "Share of time tasks waited for a CPU in the guest (PSI).",
                [target("dune:cpu_pressure_waiting:ratio", "waiting")],
                16, 21, 8, 7, unit="percentunit", fixed=AQUA))
    tick_colors = {"survival-1": BLUE, "survival-1-37": ORANGE,
                   "deepdesert-1-8": AQUA, "deepdesert-1-36": YELLOW}
    p.append(ts("Server tick rate per map",
                "Ticks per second of each map server, from the frame counter in the game's own log. The target is 20; sustained dips below about 18 are what players feel as rubberbanding. Maps with no log activity show no line.",
                [target("dune:game_tick_rate:hz", "{{server}}")],
                0, 28, 16, 8, unit="hertz", mn=10, mx=22, overrides=color_overrides(tick_colors), decimals=1))
    p.append(ts("Time spent below 18 ticks per second",
                "Share of time each map server ran below 18 ticks per second (1 minute window).",
                [target("dune:game_slow_share:ratio", "{{server}}")],
                16, 28, 8, 8, unit="percentunit", mn=0, mx=1, overrides=color_overrides(tick_colors)))
    return dashboard("dune-bursts", "Dune - Bursts and maps",
                     "Single-thread bursts per game map on dune-prod (meta#99, fork#1352). Data from process-exporter and node-exporter at 5 s.",
                     p, ["dune", "rubberbanding"])


def hostvm():
    p = []
    p += [
        stat("Host core clock, average", "Average of all 80 host CPUs.",
             'avg(node_cpu_scaling_frequency_hertz{source="r740-host"})', 0, 0, unit="hertz", decimals=2),
        stat("Host core clock, fastest", "Fastest host CPU. Turbo limit is 3.9 GHz.",
             'max(node_cpu_scaling_frequency_hertz{source="r740-host"})', 4, 0, unit="hertz", decimals=2),
        stat("Host hottest sensor", "Hottest host temperature sensor.",
             'max(node_hwmon_temp_celsius{source="r740-host"})', 8, 0, unit="celsius", decimals=0),
        stat("Guest memory used", "Share of dune-prod memory in use.",
             '1 - node_memory_MemAvailable_bytes{job="dune-node"}/node_memory_MemTotal_bytes{job="dune-node"}',
             12, 0, unit="percentunit", decimals=0),
        stat("Guest vCPU busy, average", "Average busy share across dune-prod's 60 vCPUs.",
             "avg(dune:vcpu_busy:ratio)", 16, 0, unit="percentunit", decimals=1),
        stat("Prometheus series", "Active series in dune-prod's Prometheus.",
             "prometheus_tsdb_head_series", 20, 0, decimals=0),
    ]
    p.append(ts("Host core clock",
                "Average, fastest and slowest host CPU. After the BIOS change busy cores should reach about 3.8-3.9 GHz (earlier they peaked near 3.2-3.3 GHz).",
                [target('avg(node_cpu_scaling_frequency_hertz{source="r740-host"})', "average", "A"),
                 target('max(node_cpu_scaling_frequency_hertz{source="r740-host"})', "fastest", "B"),
                 target('min(node_cpu_scaling_frequency_hertz{source="r740-host"})', "slowest", "C")],
                0, 4, 12, 9, unit="hertz", mn=0, overrides=color_overrides(
                    {"average": BLUE, "fastest": ORANGE, "slowest": AQUA})))
    p.append(ts("Host temperatures",
                "Hottest and average host temperature sensor.",
                [target('max(node_hwmon_temp_celsius{source="r740-host"})', "hottest", "A"),
                 target('avg(node_hwmon_temp_celsius{source="r740-host"})', "average", "B")],
                12, 4, 12, 9, unit="celsius", mn=0, overrides=color_overrides({"hottest": ORANGE, "average": BLUE})))
    p.append(ts("Host NUMA misses per second",
                "Memory pages placed on a remote node (numa_miss), skipped (numa_foreign) or allocated for another node (numa_other). Remote access is about 2x slower.",
                [target('rate(node_vmstat_numa_miss{source="r740-host"}[1m])', "numa_miss", "A"),
                 target('rate(node_vmstat_numa_foreign{source="r740-host"}[1m])', "numa_foreign", "B"),
                 target('rate(node_vmstat_numa_other{source="r740-host"}[1m])', "numa_other", "C")],
                0, 13, 12, 8, overrides=color_overrides({"numa_miss": ORANGE, "numa_foreign": BLUE, "numa_other": AQUA}),
                decimals=0))
    p.append(ts("Guest vCPU busy",
                "Average and busiest vCPU of dune-prod over a 15 s window.",
                [target("avg(dune:vcpu_busy:ratio)", "average", "A"),
                 target("dune:vcpu_busy_max:ratio", "busiest", "B")],
                12, 13, 12, 8, unit="percentunit", mn=0, mx=1,
                overrides=color_overrides({"average": BLUE, "busiest": ORANGE})))
    p.append(ts("Service CPU (cores)",
                "Director, RabbitMQ (beam.smp), Postgres, Docker and monitoring, from process-exporter.",
                [target('sum by (groupname)(rate(namedprocess_namegroup_cpu_seconds_total{groupname!~".+_p[0-9]+"}[30s]))', "{{groupname}}")],
                0, 21, 12, 8, overrides=color_overrides(SVC_COLORS), decimals=2))
    p.append(ts("Guest memory",
                "Used share of dune-prod memory.",
                [target('1 - node_memory_MemAvailable_bytes{job="dune-node"}/node_memory_MemTotal_bytes{job="dune-node"}', "used")],
                12, 21, 12, 8, unit="percentunit", mn=0, mx=1, fixed=BLUE))
    vm_colors = {"dune-prod": BLUE, "dune-dev": ORANGE, "acp-bot": AQUA}
    p.append(ts("VM CPU use (share of each VM's vCPUs)",
                "From the Proxmox API (read-only token), per VM. 1.0 means every vCPU of that VM is fully busy.",
                [target('pve_cpu_usage_ratio{id=~"qemu/.*"} * on(id) group_left(name) pve_guest_info', "{{name}}")],
                0, 29, 12, 8, unit="percentunit", mn=0, mx=1, overrides=color_overrides(vm_colors)))
    p.append(ts("VM memory used (share of each VM's RAM)",
                "From the Proxmox API, per VM, as seen by the hypervisor.",
                [target('pve_memory_usage_bytes{id=~"qemu/.*"} / pve_memory_size_bytes{id=~"qemu/.*"} * on(id) group_left(name) pve_guest_info', "{{name}}")],
                12, 29, 12, 8, unit="percentunit", mn=0, mx=1, overrides=color_overrides(vm_colors)))
    temp_q = ('label_replace(label_replace(ipmi_temperature_celsius{source="r740-host"},'
              '"name","CPU1","id","1"),"name","CPU2","id","2")')
    p.append(ts("Board temperatures (IPMI)",
                "CPU packages, air inlet (case intake) and exhaust, from the board's sensors via in-band IPMI (15 s).",
                [target(temp_q, "{{name}}")],
                0, 37, 12, 8, unit="celsius", mn=0,
                overrides=color_overrides({"CPU1": BLUE, "CPU2": ORANGE, "Inlet Temp": AQUA, "Exhaust Temp": YELLOW})))
    p.append(ts("Fan speed (IPMI)",
                "Six chassis fans. A fan dropping or stopping shows here before temperatures rise.",
                [target('ipmi_fan_speed_rpm{source="r740-host"}', "{{name}}")],
                12, 37, 6, 8, unit="rotrpm", mn=0, decimals=0))
    p.append(ts("Server power draw (IPMI)",
                "Whole-server power in watts (DCMI).",
                [target('ipmi_dcmi_power_consumption_watts{source="r740-host"}', "power")],
                18, 37, 6, 8, unit="watt", mn=0, fixed=MAGENTA, decimals=0))
    return dashboard("dune-host", "Dune - Host, VM and services",
                     "R740 host clocks, temperatures and NUMA, dune-prod guest load, and supporting services (meta#99).",
                     p, ["dune", "host"])


def game():
    p = []
    always = 'map=~"Survival_1|Overmap|DeepDesert_1"'
    p += [
        stat("Server state", "1 = overall READY according to the console API.",
             "dune_server_ready", 0, 0, decimals=0),
        stat("Players online", "Players online now (console API).", "dune_players_online", 4, 0, decimals=0),
        stat("Capacity", "Declared population capacity.", "dune_population_capacity", 8, 0, decimals=0),
        stat("FLS checks failing", "Funcom FLS declaration checks that are not OK (0 is healthy).",
             "count(dune_fls_ok == 0) or vector(0)", 12, 0, red_at=1, decimals=0),
        stat("Maps not ready", "Game-server rows not READY (dynamic Deep Desert may be stopped on purpose).",
             "count(dune_gameserver_ready == 0) or vector(0)", 16, 0, decimals=0),
        stat("Console API reachable", "1 when the adapter can read the console API.",
             "dune_api_up", 20, 0, decimals=0),
    ]
    p.append(ts("Players online",
                "Compare with bursts: the main-thread load should rise with players. Population from the console API (10 s).",
                [target("dune_players_online", "players online", "A")],
                0, 4, 12, 8, decimals=0, fixed=BLUE))
    p.append(ts("Bursts alongside players",
                "Bursts per interval (all maps) next to players online, to see whether load or something else drives them.",
                [target("sum(changes(dune:map_main_thread_hot[$__interval]))/2", "bursts", "A"),
                 target("dune_players_online", "players online", "B")],
                12, 4, 12, 8, decimals=0,
                overrides=color_overrides({"bursts": ORANGE, "players online": BLUE})))
    p.append(ts("Map memory used (share of limit)",
                "Per game-server container, from the console API. The limit is 16 GiB per partition.",
                [target("dune_map_memory_used_bytes / dune_map_memory_limit_bytes", "{{container}}")],
                0, 12, 12, 8, unit="percentunit", mn=0, mx=1))
    p.append(ts("Swap used by map containers",
                "Swap use by game-server containers. Should stay at zero.",
                [target("dune_map_swap_used_bytes", "{{container}}")],
                12, 12, 12, 8, unit="bytes", mn=0))
    p.append(ts("Always-on partitions ready",
                "Survival, Overmap and Deep Desert partitions: 1 = ready, 0 = not (dynamic Deep Desert may be stopped on purpose).",
                [target("dune_partition_ready{%s}" % always, "{{map}} p{{partition}} {{label}}")],
                0, 20, 12, 8, mn=0, mx=1.2, decimals=0))
    p.append(ts("FLS checks",
                "1 = OK for each Funcom FLS declaration check. Funcom outages show here.",
                [target("dune_fls_ok", "{{check}}")],
                12, 20, 12, 8, mn=0, mx=1.2, decimals=0))
    tick_colors = {"survival-1": BLUE, "survival-1-37": ORANGE,
                   "deepdesert-1-8": AQUA, "deepdesert-1-36": YELLOW}
    p.append(ts("Server tick rate per map",
                "Ticks per second of each map server, from the frame counter in the game's own log. The target is 20; sustained dips below about 18 are what players feel as rubberbanding. Maps with no log activity show no line.",
                [target("dune:game_tick_rate:hz", "{{server}}")],
                0, 28, 16, 8, unit="hertz", mn=10, mx=22, overrides=color_overrides(tick_colors), decimals=1))
    p.append(ts("Time spent below 18 ticks per second",
                "Share of time each map server ran below 18 ticks per second (1 minute window).",
                [target("dune:game_slow_share:ratio", "{{server}}")],
                16, 28, 8, 8, unit="percentunit", mn=0, mx=1, overrides=color_overrides(tick_colors)))
    return dashboard("dune-game", "Dune - Game state and players",
                     "Population, map readiness, memory and FLS health from the console API (meta#99). Private.",
                     p, ["dune", "game"])


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    (out / "dune-bursts.json").write_text(json.dumps(bursts(), indent=2) + "\n")
    (out / "dune-host.json").write_text(json.dumps(hostvm(), indent=2) + "\n")
    (out / "dune-game.json").write_text(json.dumps(game(), indent=2) + "\n")
    print("wrote", sorted(f.name for f in out.glob("*.json")))


if __name__ == "__main__":
    main()
