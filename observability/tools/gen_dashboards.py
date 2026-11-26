#!/usr/bin/env python3
"""Generate the Grafana dashboards for the Dune R740 stack (meta#99, fork#1352).

Colors: dataviz reference palette, dark-mode categorical steps, assigned to an entity in
a fixed order (never by rank). Status red is reserved for threshold/critical use.
Usage: gen_dashboards.py <output-dir>
"""
import json
import sys
from pathlib import Path

import dune_theme as theme

DS = {"type": "prometheus", "uid": "prometheus"}
BLUE, ORANGE, AQUA, YELLOW, MAGENTA, GREEN = "#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#0ca30c"
RED = "#e66767"
INTERNET_PLAN_MBIT = 2000  # the operator's fibre plan, Mbit/s each way; used for the share-of-plan panels
VIOLET, MUTED = "#9085e9", "#898781"
MAP_COLORS = {
    "Survival_1_p1": BLUE,
    "Survival_1_p37": ORANGE,
    "DeepDesert_1_p8": AQUA,
    "DeepDesert_1_p36": YELLOW,
    "Overmap_p2": MAGENTA,
    "SH_Arrakeen_p3": VIOLET,
    "SH_Arrakeen_p41": MUTED,
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
            "matcher": {"id": "byRegexp" if name.startswith("/") else "byName", "options": name},
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
        # Grafana rejects duplicate refIds in one panel, so give each target its own letter.
        "targets": [dict(t, refId=chr(65 + i)) for i, t in enumerate(targets)],
    }


def stat(title, desc, expr, x, y, w=4, h=4, unit="none", decimals=None, red_at=None, color=None,
         warn_at=None, steps=None, words=None):
    """A value tile in the Dune look.

    red_at / warn_at: value at which the tile turns red / amber (healthy stays bone-coloured).
    steps: explicit [(from_value, color), ...] thresholds, first entry is the base (use None for -inf).
    words: {value: (text, color)} shows a word instead of a number, so state never rests on colour alone.
    """
    defaults = {"unit": unit, "color": {"mode": "fixed", "fixedColor": color or theme.TEXT}}
    if decimals is not None:
        defaults["decimals"] = decimals
    if steps is not None or red_at is not None or warn_at is not None:
        if steps is None:
            steps = [(None, theme.TEXT)]
            if warn_at is not None:
                steps.append((warn_at, theme.WARN))
            if red_at is not None:
                steps.append((red_at, theme.BAD))
        defaults["color"] = {"mode": "thresholds"}
        defaults["thresholds"] = {"mode": "absolute", "steps": [{"color": c, "value": v} for v, c in steps]}
    if words:
        defaults["mappings"] = [{"type": "value", "options": {
            str(k): {"text": t, "color": c, "index": i} for i, (k, (t, c)) in enumerate(words.items())}}]
    return {
        "id": nid(), "type": "stat", "title": title, "description": desc, "datasource": DS,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "colorMode": "value", "graphMode": "none", "textMode": "value"},
        "targets": [target(expr, instant=False)],
    }


def up_words(up_text="UP", down_text="DOWN"):
    return {1: (up_text, theme.OK), 0: (down_text, theme.BAD)}


def _event(name, color, expr, title):
    return {"datasource": DS, "enable": True, "name": name, "iconColor": color, "expr": expr,
            "step": "5m", "titleFormat": title, "textFormat": "", "tagKeys": "", "useValueForTime": False}


# Lines drawn over every time graph, so a stall can be matched with what happened at that moment.
EVENT_ANNOTATIONS = [
    _event("Map restarts", theme.SPICE,
           'max(changes(namedprocess_namegroup_oldest_start_time_seconds{groupname=~"(Survival_1|Overmap|DeepDesert_1)_p[0-9]+"}[5m])) > 0',
           "Game maps restarted"),
    _event("Backups", theme.SKY,
           'max(changes(node_systemd_timer_last_trigger_seconds{name=~"r740-backup-(weekly|daily).timer"}[5m])) > 0',
           "Backup started"),
    _event("Guest reboots", theme.BAD, 'changes(node_boot_time_seconds{job="dune-node"}[5m]) > 0', "dune-prod rebooted"),
]

ALWAYS_PARTS = 'partition=~"1|2|8|36|37"'  # two Sietches, the Overmap, two Deep Deserts: the maps that are running all the time


def named(expr):
    """Add the name players see (`name`) to per-partition series. The newest name of the last day applies to the whole
    range, so a renamed Sietch keeps one line instead of splitting into an old and a new one. The database label is
    dropped for the same reason: it changes for a moment around some restarts."""
    return ('max by (map, partition) (%s) * on(partition) group_left(name) (0 * topk by (partition) (1, '
            'max_over_time(timestamp(dune_partition_info)[1d:1m] @ end())) + 1)' % expr)


NAV_LINKS = [{"type": "dashboards", "tags": ["dune"], "asDropdown": False, "includeVars": False, "keepTime": True,
              "icon": "dashboard", "title": "Arrakis dashboards", "tooltip": "", "targetBlank": False, "url": ""}]


CONTAINER_COLORS = {"dune-server-survival-1": BLUE, "dune-server-survival-1-37": ORANGE, "dune-server-deepdesert-1-8": AQUA,
                    "dune-server-deepdesert-1-36": YELLOW, "dune-server-overmap": MAGENTA, "dune-server-gateway": VIOLET}
TITLE_COLORS = {
    "Map memory used (share of limit)": CONTAINER_COLORS,
    "Swap used by map containers": CONTAINER_COLORS,
    "Always-on partitions ready": {"/^Survival_1 p1 /": BLUE, "/^Survival_1 p37 /": ORANGE, "/^DeepDesert_1 p8 /": AQUA,
                                   "/^DeepDesert_1 p36 /": YELLOW, "/^Overmap p2 /": MAGENTA},
    "FLS checks": {"directorHeartbeat": BLUE, "gatewayDbMonitoring": ORANGE, "maxCapacityDeclaration": AQUA, "populationDeclaration": YELLOW},
    "Connections by state": {"active": BLUE, "idle": AQUA, "idle in transaction": ORANGE,
                             "idle in transaction (aborted)": theme.BAD, "disabled": MUTED, "fastpath function call": VIOLET},
    "Fan speed (IPMI)": {"Fan1": BLUE, "Fan2": ORANGE, "Fan3": AQUA, "Fan4": YELLOW, "Fan5": MAGENTA, "Fan6": VIOLET},
    "Host NUMA misses per second": {"numa_miss": ORANGE, "numa_foreign": MAGENTA, "numa_other": BLUE},
    "Host core clock": {"slowest": AQUA},
}
# a flat zero line should still get a readable axis: soft maximum per panel title
SOFT_MAX = {"Host network link use": 0.05, "Internet use (share of the plan)": 0.01, "Bursts per interval, by map": 4, "Guest vCPUs above 90% busy": 4, "Players online": 5, "Bursts alongside players": 5,
            "Messages waiting": 10, "Unacknowledged messages": 10, "Swap used by map containers": 1048576,
            "Swap activity": 1048576, "Network errors and drops": 1, "Connections": 20}


def polish(panels):
    for p in panels:
        if p.get("type") != "timeseries":
            continue
        t = p["title"]
        if t in TITLE_COLORS:
            have = {o["matcher"]["options"] for o in p["fieldConfig"]["overrides"]}
            p["fieldConfig"]["overrides"] += [o for o in color_overrides(TITLE_COLORS[t]) if o["matcher"]["options"] not in have]
        if t in SOFT_MAX:
            p["fieldConfig"]["defaults"]["custom"]["axisSoftMax"] = SOFT_MAX[t]
    return panels


def with_rows(panels, rows, banner_h=4):
    """Shift the panels down for the banner, and add a section row before each (original y, title)."""
    rows = sorted(rows or [])
    out, shift = [], banner_h
    pending = list(rows)
    for p in sorted(panels, key=lambda q: (q["gridPos"]["y"], q["gridPos"]["x"])):
        while pending and p["gridPos"]["y"] >= pending[0][0]:
            y0, title = pending.pop(0)
            out.append({"id": nid(), "type": "row", "title": title, "collapsed": False, "panels": [],
                        "gridPos": {"x": 0, "y": y0 + shift, "w": 24, "h": 1}})
            shift += 1
        p["gridPos"]["y"] += shift
        out.append(p)
    return out


def dashboard(uid, title, desc, panels, tags, banner=None, rows=None):
    polish(panels)
    if banner:
        panels = [theme.banner_panel(nid(), banner[0], banner[1])] + with_rows(panels, rows)
    return {
        "uid": uid, "title": title, "description": desc, "tags": tags, "schemaVersion": 39,
        "version": 1, "editable": True, "graphTooltip": 1, "refresh": "10s",
        "time": {"from": "now-6h", "to": "now"}, "timezone": "browser",
        "annotations": {"list": [{
            "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": True,
            "iconColor": theme.SPICE, "name": "Changes",
            "target": {"type": "tags", "tags": ["change"], "limit": 100, "matchAny": False, "queryType": "tags"},
        }] + EVENT_ANNOTATIONS},
        "templating": {"list": []}, "links": NAV_LINKS, "panels": panels,
    }


def bursts():
    p = []
    p += [
        stat("Maps saturated now", "Map main threads at or above 0.9 core right now.",
             "sum(dune:map_main_thread_hot)", 0, 0, red_at=1, decimals=0),
        stat("Busiest map thread", "Highest main-thread CPU of any map (1.0 = one core).",
             "max(dune:map_main_thread:cores)", 4, 0, decimals=2),
        stat("Saturated time", "Total seconds a map main thread was at or above 0.9 core, summed over all maps.",
             "sum(sum_over_time(dune:map_main_thread_hot[$__range]))*5", 8, 0, unit="s", decimals=0),
        stat("Bursts in range", "Number of times any map's main thread crossed 0.9 core (rising edges).",
             "sum(changes(dune:map_main_thread_hot[$__range]))/2", 12, 0, decimals=0),
        stat("vCPUs above 90%", "vCPUs of dune-prod busier than 90% over 15 s.",
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
                   "deepdesert-1-8": AQUA, "deepdesert-1-36": YELLOW, "overmap": MAGENTA}
    p.append(ts("Server tick rate per map",
                "Ticks per second of each map server, from the frame counter in the game's own log. The target is 20; sustained dips below about 18 are what players feel as rubberbanding. Maps with no log activity show no line.",
                [target("dune:game_tick_rate:hz", "{{server}}")],
                0, 28, 16, 8, unit="hertz", mn=10, mx=22, overrides=color_overrides(tick_colors), decimals=1))
    p.append(ts("Time spent below 18 ticks per second",
                "Share of time each map server ran below 18 ticks per second (1 minute window).",
                [target("dune:game_slow_share:ratio", "{{server}}")],
                16, 28, 8, 8, unit="percentunit", mn=0, mx=1, overrides=color_overrides(tick_colors)))
    return dashboard("dune-bursts", "Arrakis \u00b7 Performance",
                     "Single-thread bursts per game map on dune-prod (meta#99, fork#1352). Data from process-exporter and node-exporter at 5 s.",
                     p, ["dune", "rubberbanding"], banner=("ARRAKIS", "Performance: where the game loses time"),
                     rows=[(0, "Right now"), (4, "Main thread and bursts"), (21, "Whole-server load"), (28, "Server tick rate")])


def hostvm():
    p = []
    p += [
        stat("Core clock, average", "Average of all 80 host CPUs.",
             'avg(node_cpu_scaling_frequency_hertz{source="r740-host"})', 0, 0, unit="hertz", decimals=2),
        stat("Core clock, fastest", "Fastest host CPU. Turbo limit is 3.9 GHz.",
             'max(node_cpu_scaling_frequency_hertz{source="r740-host"})', 4, 0, unit="hertz", decimals=2),
        stat("Hottest sensor", "Hottest host temperature sensor.",
             'max(node_hwmon_temp_celsius{source="r740-host"})', 8, 0, unit="celsius", decimals=0),
        stat("Guest memory used", "Share of dune-prod memory in use.",
             '1 - node_memory_MemAvailable_bytes{job="dune-node"}/node_memory_MemTotal_bytes{job="dune-node"}',
             12, 0, unit="percentunit", decimals=0),
        stat("Guest CPU, average", "Average busy share across dune-prod's 60 vCPUs.",
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
    wan_in = "rate(unifi_wan_receive_bytes_total[1m]) * 8"
    wan_out = "rate(unifi_wan_transmit_bytes_total[1m]) * 8"
    p.append(ts("Internet traffic",
                "What crosses the gateway's internet port, in and out (1 min), from the gateway's own counters. This is the link that can limit players.",
                [target(wan_in, "in (download)"), target(wan_out, "out (upload)")],
                0, 53, 8, 8, unit="bps", mn=0, overrides=color_overrides({"in (download)": BLUE, "out (upload)": ORANGE})))
    p.append(ts("Internet use (share of the plan)",
                "The same traffic as a share of the %d Mbit/s plan. Near zero is normal; sustained high values mean the internet link is the limit." % INTERNET_PLAN_MBIT,
                [target("%s / (%d * 1e6)" % (wan_in, INTERNET_PLAN_MBIT), "in (download)"),
                 target("%s / (%d * 1e6)" % (wan_out, INTERNET_PLAN_MBIT), "out (upload)")],
                8, 53, 8, 8, unit="percentunit", mn=0, decimals=2, overrides=color_overrides({"in (download)": BLUE, "out (upload)": ORANGE})))
    p.append(ts("Internet latency and port drops",
                "Latency from the gateway to the internet as the gateway measures it (ms), and packets the internet port dropped or errored per second. Both share one axis; the second should sit at zero and the first stay low and flat.",
                [target("unifi_wan_latency_ms", "latency (ms)"),
                 target("rate(unifi_wan_receive_dropped_total[5m]) + rate(unifi_wan_transmit_dropped_total[5m]) + rate(unifi_wan_receive_errors_total[5m]) + rate(unifi_wan_transmit_errors_total[5m])", "drops and errors per second")],
                16, 53, 8, 8, mn=0, decimals=1, overrides=color_overrides({"latency (ms)": AQUA, "drops and errors per second": RED})))
    g, h = 'job="dune-node"', 'job="host-node"'
    nicsel = 'job="host-node",device="nic0"'
    p.append(ts("Host network link use",
                "Traffic on the host's physical network card as a share of its speed (1 Gbit/s), in and out (1 min). This is the local link, not your internet connection: if it ever runs high, the local network is the limit. The internet upload is the router's port and is not measured here.",
                [target('rate(node_network_receive_bytes_total{%s}[1m]) / node_network_speed_bytes{%s}' % (nicsel, nicsel), "in"),
                 target('rate(node_network_transmit_bytes_total{%s}[1m]) / node_network_speed_bytes{%s}' % (nicsel, nicsel), "out")],
                0, 45, 12, 8, unit="percentunit", mn=0, decimals=2, overrides=color_overrides({"in": BLUE, "out": ORANGE})))
    vm_name = ('label_replace(label_replace(label_replace(%s, "vm", "dune-prod", "device", "tap101i0"), '
               '"vm", "dune-dev", "device", "tap102i0"), "vm", "acp-bot", "device", "tap103i0")')
    p.append(ts("Traffic sent by each VM",
                "What each VM sends out, in bits per second (1 min), seen from the host's virtual network ports. The game server VM (dune-prod) is the one players' traffic leaves through.",
                [target(vm_name % 'rate(node_network_receive_bytes_total{job="host-node",device=~"tap10[123]i0"}[1m]) * 8', "{{vm}}")],
                12, 45, 12, 8, unit="bps", mn=0, overrides=color_overrides(vm_colors)))
    nic = {"guest in": BLUE, "guest out": ORANGE, "host in": AQUA, "host out": YELLOW}
    def bad(side, dev, d):
        return ('sum(rate(node_network_%s_errs_total{%s,device="%s"}[5m]) + rate(node_network_%s_drop_total{%s,device="%s"}[5m]))'
                % (d, side, dev, d, side, dev))
    p.append(ts("Network errors and drops",
                "Packets the NIC reported as errored or dropped, per second: guest eth0 and host nic0, in and out. Should sit at zero; steady non-zero values point at a cable, switch port, driver or full queue.",
                [target(bad(g, "eth0", "receive"), "guest in"), target(bad(g, "eth0", "transmit"), "guest out"),
                 target(bad(h, "nic0", "receive"), "host in"), target(bad(h, "nic0", "transmit"), "host out")],
                0, 61, 12, 8, mn=0, decimals=2, overrides=color_overrides(nic)))
    p.append(ts("TCP retransmits",
                "Share of outgoing TCP segments that had to be sent again (5 min). Rises with packet loss or a congested path; a few tenths of a percent is normal.",
                [target('rate(node_netstat_Tcp_RetransSegs{%s}[5m]) / rate(node_netstat_Tcp_OutSegs{%s}[5m])' % (g, g), "guest"),
                 target('rate(node_netstat_Tcp_RetransSegs{%s}[5m]) / rate(node_netstat_Tcp_OutSegs{%s}[5m])' % (h, h), "host")],
                12, 61, 12, 8, unit="percentunit", mn=0, overrides=color_overrides({"guest": BLUE, "host": AQUA})))
    dsk = {"guest": BLUE, "host": AQUA}
    p.append(ts("Disk busy",
                "Share of time the system disk had I/O in flight (5 min): guest sda and host sda. Near 100% means the disk is the limit.",
                [target('rate(node_disk_io_time_seconds_total{%s,device="sda"}[5m])' % g, "guest"),
                 target('rate(node_disk_io_time_seconds_total{%s,device="sda"}[5m])' % h, "host")],
                0, 69, 8, 8, unit="percentunit", mn=0, mx=1, overrides=color_overrides(dsk)))
    lat = {"guest read": BLUE, "guest write": ORANGE, "host read": AQUA, "host write": YELLOW}
    def lt(side, dev, kind):
        return ('rate(node_disk_%s_time_seconds_total{%s,device="%s"}[5m]) / rate(node_disk_%ss_completed_total{%s,device="%s"}[5m])'
                % (kind, side, dev, kind, side, dev))
    p.append(ts("Disk latency",
                "Average time per completed read and write (5 min). Gaps mean no I/O in the window. Sustained tens of milliseconds is a slow disk.",
                [target(lt(g, "sda", "read"), "guest read"), target(lt(g, "sda", "write"), "guest write"),
                 target(lt(h, "sda", "read"), "host read"), target(lt(h, "sda", "write"), "host write")],
                8, 69, 8, 8, unit="s", mn=0, overrides=color_overrides(lat)))
    p.append(ts("Disk I/O pressure",
                "Share of time tasks were waiting on disk I/O (Linux pressure stall, 1 min). Zero is healthy.",
                [target('rate(node_pressure_io_waiting_seconds_total{%s}[1m])' % g, "guest"),
                 target('rate(node_pressure_io_waiting_seconds_total{%s}[1m])' % h, "host")],
                16, 69, 8, 8, unit="percentunit", mn=0, mx=1, overrides=color_overrides(dsk)))
    p.append(ts("Host storage used",
                "Share used of the Proxmox thin pool that holds the VM disks (local-lvm) and of the host's root storage (local). A full thin pool freezes every VM on it.",
                [target('pve_disk_usage_bytes{id="storage/DA-1/local-lvm"} / pve_disk_size_bytes{id="storage/DA-1/local-lvm"}', "thin pool (local-lvm)"),
                 target('pve_disk_usage_bytes{id="storage/DA-1/local"} / pve_disk_size_bytes{id="storage/DA-1/local"}', "host root (local)")],
                0, 77, 12, 8, unit="percentunit", mn=0, mx=1,
                overrides=color_overrides({"thin pool (local-lvm)": BLUE, "host root (local)": ORANGE})))
    sw = {"guest in": BLUE, "guest out": ORANGE, "host in": AQUA, "host out": YELLOW}
    p.append(ts("Swap activity",
                "Memory moved to and from swap, bytes per second (5 min). In is a page read back from swap, out is a page written. Should be zero; sustained activity means memory pressure.",
                [target('rate(node_vmstat_pswpin{%s}[5m]) * 4096' % g, "guest in"), target('rate(node_vmstat_pswpout{%s}[5m]) * 4096' % g, "guest out"),
                 target('rate(node_vmstat_pswpin{%s}[5m]) * 4096' % h, "host in"), target('rate(node_vmstat_pswpout{%s}[5m]) * 4096' % h, "host out")],
                12, 77, 12, 8, unit="Bps", mn=0, overrides=color_overrides(sw)))
    return dashboard("dune-host", "Arrakis \u00b7 Host and VMs",
                     "R740 host clocks, temperatures and NUMA, dune-prod guest load, and supporting services (meta#99).",
                     p, ["dune", "host"], banner=("ARRAKIS", "The R740, its VMs and services"),
                     rows=[(0, "At a glance"), (4, "CPU, clocks and temperature"), (21, "Services and VMs"),
                           (37, "Board sensors (IPMI)"), (45, "Network traffic"), (53, "Internet (the gateway's port)"), (61, "Network health"), (69, "Disks"), (77, "Storage and swap")])


def game():
    p = []
    always = 'map=~"Survival_1|Overmap|DeepDesert_1"'
    p += [
        stat("Server state", "1 = overall READY according to the console API, 0 = starting or has an issue.",
             "max(dune_server_ready)", 0, 0, decimals=0,
             words={1: ("READY", theme.OK), 0: ("NOT READY", theme.BAD)}),
        stat("Players online", "Players online now (console API).", "dune_players_online", 4, 0, decimals=0),
        stat("Capacity", "Declared population capacity.", "dune_population_capacity", 8, 0, decimals=0),
        stat("FLS checks failing", "Funcom FLS declaration checks that are not OK (0 is healthy).",
             "count(dune_fls_ok == 0) or vector(0)", 12, 0, red_at=1, decimals=0),
        stat("Maps not ready", "Game-server rows not READY (dynamic Deep Desert may be stopped on purpose).",
             "count(dune_gameserver_ready == 0) or vector(0)", 16, 0, decimals=0),
        stat("Console API reachable", "1 when the adapter can read the console API.",
             "dune_api_up", 20, 0, decimals=0, words=up_words("OK", "DOWN")),
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
                [target(named("dune_partition_ready{%s}" % always), "{{map}} p{{partition}} {{name}}")],
                0, 20, 12, 8, mn=0, mx=1.2, decimals=0))
    p.append(ts("FLS checks",
                "1 = OK for each Funcom FLS declaration check. Funcom outages show here.",
                [target("dune_fls_ok", "{{check}}")],
                12, 20, 12, 8, mn=0, mx=1.2, decimals=0))
    tick_colors = {"survival-1": BLUE, "survival-1-37": ORANGE,
                   "deepdesert-1-8": AQUA, "deepdesert-1-36": YELLOW, "overmap": MAGENTA}
    p.append(ts("Server tick rate per map",
                "Ticks per second of each map server, from the frame counter in the game's own log. The target is 20; sustained dips below about 18 are what players feel as rubberbanding. Maps with no log activity show no line.",
                [target("dune:game_tick_rate:hz", "{{server}}")],
                0, 28, 16, 8, unit="hertz", mn=10, mx=22, overrides=color_overrides(tick_colors), decimals=1))
    p.append(ts("Time spent below 18 ticks per second",
                "Share of time each map server ran below 18 ticks per second (1 minute window).",
                [target("dune:game_slow_share:ratio", "{{server}}")],
                16, 28, 8, 8, unit="percentunit", mn=0, mx=1, overrides=color_overrides(tick_colors)))
    return dashboard("dune-game", "Arrakis \u00b7 Game state",
                     "Population, map readiness, memory and FLS health from the console API (meta#99). Private.",
                     p, ["dune", "game"], banner=("ARRAKIS", "Game state, players and the console API"),
                     rows=[(0, "Right now"), (4, "Players and load"), (12, "Memory"), (20, "Readiness"), (28, "Server tick rate")])


def data():
    p = []
    dbq = 'datname="dune"'
    p += [
        stat("Postgres", "Whether the database answers the exporter.", "pg_up", 0, 0, decimals=0, words=up_words()),
        stat("Connections in use", "Open connections to Postgres (all states).", "sum(pg_stat_activity_count)", 4, 0, decimals=0),
        stat("Connection limit", "max_connections setting.", "max(pg_settings_max_connections)", 8, 0, decimals=0),
        stat("Game database size", "Size of the dune database.", "pg_database_size_bytes{%s}" % dbq, 12, 0, unit="bytes", decimals=2),
        stat("Deadlocks, last 24 h", "Deadlocks Postgres had to break (0 is healthy).",
             "sum(increase(pg_stat_database_deadlocks[24h]))", 16, 0, red_at=1, decimals=0),
        stat("Queue backlog", "Ready plus unacknowledged messages across both RabbitMQ brokers (0 is healthy).",
             "sum(rabbitmq_queue_messages)", 20, 0, red_at=1000, decimals=0),
    ]
    p.append(ts("Connections in use and limit",
                "Open Postgres connections against max_connections. Running out of connections stalls the game's saves and the console.",
                [target("sum(pg_stat_activity_count)", "in use"), target("max(pg_settings_max_connections)", "limit")],
                0, 4, 12, 8, decimals=0, overrides=color_overrides({"in use": BLUE, "limit": RED})))
    p.append(ts("Connections by state",
                "idle in transaction for long periods holds locks and blocks cleanup; active is work happening now.",
                [target("sum by (state)(pg_stat_activity_count)", "{{state}}")],
                12, 4, 12, 8, decimals=0, stack=True))
    p.append(ts("Transactions per second",
                "Commits and rollbacks across all databases (1 min).",
                [target("sum(rate(pg_stat_database_xact_commit[1m]))", "commits"),
                 target("sum(rate(pg_stat_database_xact_rollback[1m]))", "rollbacks")],
                0, 12, 8, 8, decimals=1, overrides=color_overrides({"commits": BLUE, "rollbacks": ORANGE})))
    p.append(ts("Cache hit ratio",
                "Share of block reads served from memory instead of disk (5 min). The game database should stay near 100%.",
                [target("sum(rate(pg_stat_database_blks_hit[5m])) / (sum(rate(pg_stat_database_blks_hit[5m])) + sum(rate(pg_stat_database_blks_read[5m])))", "hit ratio")],
                8, 12, 8, 8, unit="percentunit", mn=0.9, mx=1, fixed=BLUE))
    p.append(ts("Rows changed per second",
                "Rows inserted, updated and deleted (1 min). Shows how busy the game's writes are.",
                [target("sum(rate(pg_stat_database_tup_inserted[1m]))", "inserted"),
                 target("sum(rate(pg_stat_database_tup_updated[1m]))", "updated"),
                 target("sum(rate(pg_stat_database_tup_deleted[1m]))", "deleted")],
                16, 12, 8, 8, decimals=1,
                overrides=color_overrides({"inserted": BLUE, "updated": ORANGE, "deleted": AQUA})))
    p.append(ts("Game database size",
                "Size of the dune database over time. Growth should be steady; a sudden jump is worth a look.",
                [target("pg_database_size_bytes{%s}" % dbq, "dune")],
                0, 20, 12, 8, unit="bytes", fixed=BLUE))
    p.append(ts("Rollback share",
                "Share of transactions that rolled back (5 min). Occasional rollbacks are normal; a sustained rise points at failing writes.",
                [target("sum(rate(pg_stat_database_xact_rollback[5m])) / (sum(rate(pg_stat_database_xact_commit[5m])) + sum(rate(pg_stat_database_xact_rollback[5m])))", "rollbacks")],
                12, 20, 12, 8, unit="percentunit", mn=0, fixed=ORANGE))
    br = {"admin": BLUE, "game": ORANGE}
    def rmq(expr):
        return [target(expr % 'job="dune-rabbitmq-admin"', "admin"), target(expr % 'job="dune-rabbitmq-game"', "game")]
    p.append(ts("Messages waiting",
                "Ready messages in queues, per broker. Should sit at or near zero; a growing line means a consumer is stuck or gone.",
                rmq("sum(rabbitmq_queue_messages_ready{%s})"), 0, 28, 8, 8, decimals=0, overrides=color_overrides(br)))
    p.append(ts("Unacknowledged messages",
                "Delivered but not yet acknowledged, per broker. A steady climb means a consumer takes messages and does not finish them.",
                rmq("sum(rabbitmq_queue_messages_unacked{%s})"), 8, 28, 8, 8, decimals=0, overrides=color_overrides(br)))
    p.append(ts("Connections",
                "Open client connections per broker (game servers, gateway, director).",
                rmq("sum(rabbitmq_connections{%s})"), 16, 28, 8, 8, decimals=0, overrides=color_overrides(br)))
    p.append(ts("Messages published per second",
                "Rate of messages published into each broker (1 min).",
                rmq("sum(rate(rabbitmq_channel_messages_published_total{%s}[1m]))"), 0, 36, 8, 8, decimals=1, overrides=color_overrides(br)))
    p.append(ts("Messages delivered per second",
                "Rate of messages delivered to consumers (1 min). Compare with published: delivered well below published means a backlog is forming.",
                rmq("sum(rate(rabbitmq_global_messages_delivered_total{%s}[1m]))"), 8, 36, 8, 8, decimals=1, overrides=color_overrides(br)))
    p.append(ts("Messages dropped as unroutable",
                "Messages published to an exchange with no matching queue, per second (5 min). The admin broker runs at a steady ~75 per second on a healthy stack (the unbound heartbeats exchange); the alert for this is silenced for that reason (fork issue #1356). A change from that baseline is what matters.",
                rmq("sum(rate(rabbitmq_global_messages_unroutable_dropped_total{%s}[5m]))"), 16, 36, 8, 8, decimals=1, overrides=color_overrides(br)))
    p.append(ts("Broker memory used (share of limit)",
                "Resident memory of each broker against its limit. RabbitMQ blocks publishers when it reaches the limit.",
                [target('rabbitmq_process_resident_memory_bytes{job="dune-rabbitmq-admin"} / rabbitmq_resident_memory_limit_bytes{job="dune-rabbitmq-admin"}', "admin"),
                 target('rabbitmq_process_resident_memory_bytes{job="dune-rabbitmq-game"} / rabbitmq_resident_memory_limit_bytes{job="dune-rabbitmq-game"}', "game")],
                0, 44, 12, 8, unit="percentunit", mn=0, mx=1, overrides=color_overrides(br)))
    p.append(ts("Consumers",
                "Consumers attached to queues, per broker. A drop to zero means the services that read the queues are gone.",
                rmq("sum(rabbitmq_consumers{%s})"), 12, 44, 12, 8, decimals=0, overrides=color_overrides(br)))
    return dashboard("dune-data", "Arrakis \u00b7 Database and queues",
                     "Postgres and RabbitMQ health from Core's own exporters (meta#99). Private.",
                     p, ["dune", "data"], banner=("ARRAKIS", "Postgres and RabbitMQ"),
                     rows=[(0, "Right now"), (4, "Postgres: connections"), (12, "Postgres: activity and size"),
                           (28, "RabbitMQ: backlog and connections"), (36, "RabbitMQ: traffic"), (44, "RabbitMQ: health")])


def overview():
    p = []
    thin = 'pve_disk_usage_bytes{id="storage/DA-1/local-lvm"} / pve_disk_size_bytes{id="storage/DA-1/local-lvm"}'
    root = 'pve_disk_usage_bytes{id="storage/DA-1/local"} / pve_disk_size_bytes{id="storage/DA-1/local"}'
    p += [
        stat("Server", "Overall state according to the console API.", "max(dune_server_ready)", 0, 0, decimals=0,
             words={1: ("READY", theme.OK), 0: ("NOT READY", theme.BAD)}),
        stat("Players online", "Players online now (console API).", "dune_players_online", 4, 0, decimals=0),
        stat("Server tick rate", "Slowest map server over 5 minutes, in ticks per second. The target is 20; below 18 players feel rubberbanding.",
             "min(avg_over_time(dune:game_tick_rate:hz[5m]))", 8, 0, unit="hertz", decimals=1,
             steps=[(None, theme.BAD), (18, theme.WARN), (19.5, theme.TEXT)]),
        stat("Busiest map thread", "Highest main-thread CPU of any map (1.0 = one core). Above 0.9 is a burst.",
             "max(dune:map_main_thread:cores)", 12, 0, decimals=2, warn_at=0.6, red_at=0.9),
        stat("Guest CPU", "Average busy share across the 60 vCPUs of the game server VM.",
             "avg(dune:vcpu_busy:ratio)", 16, 0, unit="percentunit", decimals=1, warn_at=0.6, red_at=0.85),
        stat("Guest memory", "Share of the game server VM's memory in use.",
             '1 - node_memory_MemAvailable_bytes{job="dune-node"}/node_memory_MemTotal_bytes{job="dune-node"}',
             20, 0, unit="percentunit", decimals=0, warn_at=0.8, red_at=0.92),
        stat("Hottest sensor", "Hottest host temperature sensor.", 'max(node_hwmon_temp_celsius{source="r740-host"})',
             0, 4, unit="celsius", decimals=0, warn_at=75, red_at=85),
        stat("VM disk pool used", "Share used of the Proxmox thin pool that holds the VM disks. A full pool freezes every VM on it.",
             thin, 4, 4, unit="percentunit", decimals=0, warn_at=0.8, red_at=0.9),
        stat("Host storage used", "Share used of the host's root storage.", root, 8, 4, unit="percentunit", decimals=0,
             warn_at=0.8, red_at=0.9),
        stat("Alerts firing", "Alerts firing now, not counting the two known and silenced ones (cAdvisor and RabbitMQ heartbeats).",
             'count(ALERTS{alertstate="firing",alertname!~"DuneContainerMissing|DuneRabbitMQUnroutableMessages"}) or vector(0)',
             12, 4, decimals=0, red_at=1),
        stat("Maps ready", "Game-server partitions reporting ready (dynamic ones may be stopped on purpose).",
             "count(dune_gameserver_ready == 1) or vector(0)", 16, 4, decimals=0),
        stat("Queue backlog", "Messages waiting in RabbitMQ across both brokers. Zero is healthy.",
             "sum(rabbitmq_queue_messages)", 20, 4, decimals=0, warn_at=100, red_at=1000),
    ]
    # the busier direction, max(a, b) = (a + b + |a - b|) / 2, as a share of the plan (one series each, same labels)
    a, b = "rate(unifi_wan_receive_bytes_total[1m])", "rate(unifi_wan_transmit_bytes_total[1m])"
    share = "((%s + %s + abs(%s - %s)) / 2) * 8 / (%d * 1e6)" % (a, b, a, b, INTERNET_PLAN_MBIT)
    p += [
        stat("Internet down", "Download traffic through the gateway's internet port now (1 min).",
             "sum(rate(unifi_wan_receive_bytes_total[1m])) * 8 / 1e6", 0, 8, unit="suffix: Mbit/s", decimals=2),
        stat("Internet up", "Upload traffic through the gateway's internet port now (1 min). This is the direction game traffic to players uses.",
             "sum(rate(unifi_wan_transmit_bytes_total[1m])) * 8 / 1e6", 4, 8, unit="suffix: Mbit/s", decimals=2),
        stat("Internet use", "The busier direction as a share of the %d Mbit/s plan." % INTERNET_PLAN_MBIT,
             share, 8, 8, unit="percentunit", decimals=2, warn_at=0.5, red_at=0.8),
        stat("Internet latency", "Latency from the gateway to the internet, as the gateway measures it.",
             "unifi_wan_latency_ms", 12, 8, unit="suffix: ms", decimals=0, warn_at=30, red_at=80),
        stat("Internet port", "Whether the gateway's internet port is up.", "unifi_wan_up", 16, 8, decimals=0,
             words=up_words()),
        stat("Last speed test", "Download speed of the gateway's most recent speed test (Mbit/s); the upload result is on the host dashboard's Internet row.",
             "unifi_wan_speedtest_download_mbps", 20, 8, unit="suffix: Mbit/s", decimals=0),
    ]
    tick_colors = {"survival-1": BLUE, "survival-1-37": ORANGE, "deepdesert-1-8": AQUA, "deepdesert-1-36": YELLOW, "overmap": MAGENTA}
    p.append(ts("Server tick rate per map",
                "Ticks per second of each map server, from the game's own log. The target is 20.",
                [target("dune:game_tick_rate:hz", "{{server}}")],
                0, 12, 12, 8, unit="hertz", mn=10, mx=22, overrides=color_overrides(tick_colors), decimals=1))
    p.append(ts("Players online", "Players online now, from the console API.",
                [target("dune_players_online", "players online")], 12, 12, 12, 8, decimals=0, fixed=BLUE))
    p.append(ts("Main thread CPU per map",
                "The game's main thread per map is single-threaded, so this is the limit. 1.0 means one core saturated; the red line is the 0.9 burst threshold.",
                [target("dune:map_main_thread:cores", "{{groupname}}")],
                0, 20, 12, 8, mn=0, mx=1.2, overrides=color_overrides(MAP_COLORS), threshold=0.9, decimals=2))
    p.append(ts("Host temperatures", "Hottest and average host temperature sensor.",
                [target('max(node_hwmon_temp_celsius{source="r740-host"})', "hottest"),
                 target('avg(node_hwmon_temp_celsius{source="r740-host"})', "average")],
                12, 20, 12, 8, unit="celsius", mn=0, overrides=color_overrides({"hottest": ORANGE, "average": BLUE})))
    links = [("dune-wall", "Wall", "One screen: verdict, maps, the day"),
             ("dune-bursts", "Performance", "Main thread, bursts, tick rate"),
             ("dune-game", "Game state", "Players, readiness, memory"),
             ("dune-host", "Host and VMs", "Clocks, temperatures, network, disks"),
             ("dune-data", "Database and queues", "Postgres and RabbitMQ")]
    cells = "".join(
        f'<a href="/d/{u}" style="display:block;flex:1;min-width:200px;padding:10px 14px;margin:0 6px 0 0;'
        f'border:1px solid {theme.HAIR};border-radius:3px;background:{theme.PANEL};text-decoration:none">'
        f'<span style="color:{theme.GOLD};font-size:15px;letter-spacing:.06em;text-transform:uppercase">{t}</span><br>'
        f'<span style="color:{theme.DIM};font-size:12px">{d}</span></a>' for u, t, d in links)
    p.append({"id": nid(), "type": "text", "title": "", "transparent": True,
              "gridPos": {"x": 0, "y": 28, "w": 24, "h": 3},
              "options": {"mode": "html", "content": f'<div style="display:flex;flex-wrap:wrap">{cells}</div>',
                          "code": {"language": "plaintext", "showLineNumbers": False, "showMiniMap": False}}})
    return dashboard("dune-overview", "Arrakis \u00b7 Overview",
                     "The whole server at a glance: state, players, tick rate, load, temperature, storage and alerts (meta#99). Private.",
                     p, ["dune", "overview"], banner=("ARRAKIS", "The server at a glance"),
                     rows=[(0, "Right now"), (8, "Internet"), (12, "Last 6 hours"), (28, "Dashboards")])


def tiles(title, desc, expr, legend, x, y, w, h, unit="none", decimals=None, steps=None, words=None, graph=False,
          show_text=True, solid=False, value_size=None):
    """One tile per series (a stat panel with a coloured background), optionally with a sparkline."""
    defaults = {"unit": unit, "color": {"mode": "thresholds"},
                "thresholds": {"mode": "absolute", "steps": [{"color": c, "value": v} for v, c in steps]}}
    if decimals is not None:
        defaults["decimals"] = decimals
    if words:
        defaults["mappings"] = [{"type": "value", "options": {
            str(k): {"text": t, "color": c, "index": i} for i, (k, (t, c)) in enumerate(words.items())}}]
    opts = {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "colorMode": "background_solid" if solid else "background", "graphMode": "area" if graph else "none",
            "textMode": ("value_and_name" if legend else "value") if show_text else "none", "justifyMode": "center", "orientation": "auto",
            "wideLayout": True}
    if value_size:
        opts["text"] = {"valueSize": value_size, "titleSize": 13}
    return {"id": nid(), "type": "stat", "title": title, "description": desc, "datasource": DS,
            "gridPos": {"x": x, "y": y, "w": w, "h": h},
            "fieldConfig": {"defaults": defaults, "overrides": []}, "options": opts,
            "targets": [target(expr, legend)]}


def ring(title, desc, expr, x, y, w, h, unit="percentunit", mx=1, decimals=0, warn=None, red=None):
    """An arc gauge: the value against its limit, with the warning and critical marks drawn on the arc."""
    steps = [{"color": theme.OK, "value": None}]
    if warn is not None:
        steps.append({"color": theme.WARN, "value": warn})
    if red is not None:
        steps.append({"color": theme.BAD, "value": red})
    return {"id": nid(), "type": "gauge", "title": title, "description": desc, "datasource": DS,
            "gridPos": {"x": x, "y": y, "w": w, "h": h},
            "fieldConfig": {"defaults": {"unit": unit, "min": 0, "max": mx, "decimals": decimals,
                                         "color": {"mode": "thresholds"},
                                         "thresholds": {"mode": "absolute", "steps": steps}}, "overrides": []},
            "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                        "showThresholdMarkers": True, "showThresholdLabels": False, "orientation": "auto",
                        "text": {"valueSize": 34, "titleSize": 13}},
            "targets": [target(expr)]}


def lanes(kind, title, desc, targets, x, y, w, h, steps, mappings=None, unit="none", decimals=None, interval=None):
    """state-timeline (changes of state over time) or status-history (a coloured cell per interval)."""
    defaults = {"unit": unit, "color": {"mode": "thresholds"},
                "thresholds": {"mode": "absolute", "steps": [{"color": c, "value": v} for v, c in steps]},
                "custom": {"fillOpacity": 85, "lineWidth": 0, "hideFrom": {"legend": False, "tooltip": False, "viz": False}}}
    if decimals is not None:
        defaults["decimals"] = decimals
    if mappings:
        defaults["mappings"] = [{"type": "value", "options": {
            str(k): {"text": t, "color": c, "index": i} for i, (k, (t, c)) in enumerate(mappings.items())}}]
    defaults.setdefault("mappings", []).append({"type": "special", "options": {
        "match": "null+nan", "result": {"text": "No data", "color": "#2a2217", "index": 99}}})
    opts = {"showValue": "never", "rowHeight": 0.85, "legend": {"showLegend": False, "displayMode": "list", "placement": "bottom"},
            "tooltip": {"mode": "single", "sort": "none"}}
    if kind == "state-timeline":
        opts.update({"mergeValues": True, "alignValue": "left"})
    else:
        opts.update({"colWidth": 0.96})
    ts_ = [dict(t, refId=chr(65 + i)) for i, t in enumerate(targets)]
    if interval:
        for t in ts_:
            t["interval"] = interval
    return {"id": nid(), "type": kind, "title": title, "description": desc, "datasource": DS,
            "gridPos": {"x": x, "y": y, "w": w, "h": h},
            "fieldConfig": {"defaults": defaults, "overrides": []}, "options": opts, "targets": ts_}


def wall():
    """One screen for a TV or a phone: a verdict, the maps as tiles, pressure rings, the day as lanes, the cores as a grid."""
    p = []
    parts = "dune_partition_ready{%s}" % ALWAYS_PARTS
    # 0 steady, 1 watch (slow ticks), 2 trouble (a map or the server is down, or the API is silent)
    verdict = ("clamp_max(2 * clamp_max(((1 - min(%s)) or vector(1)) + ((1 - max(dune_server_ready)) or vector(1)), 1)"
               " + ((max(dune:game_slow_share:ratio) > bool 0.25) or vector(0)), 2)" % parts)
    p.append(tiles("Verdict", "Steady: every always-on map is ready and ticks are healthy. Watch: a map spent over a quarter of the last minute below 18 ticks per second. Trouble: a map or the server is not ready, or the console API is silent.",
                   verdict, "", 0, 0, 8, 7, decimals=0, graph=False, show_text=True, value_size=64,
                   steps=[(None, theme.OK)],
                   words={0: ("STEADY", theme.OK), 1: ("WATCH", theme.WARN), 2: ("TROUBLE", theme.BAD)}))
    p[-1]["fieldConfig"]["defaults"]["thresholds"]["steps"] = [
        {"color": theme.OK, "value": None}, {"color": theme.WARN, "value": 1}, {"color": theme.BAD, "value": 2}]
    p[-1]["options"]["textMode"] = "value"
    p.append(tiles("Players online", "Players online now (console API).", "dune_players_online", "", 8, 0, 4, 7,
                   decimals=0, steps=[(None, "#2a2217")], value_size=56))
    p.append(tiles("Tick rate", "Slowest map server over 5 minutes, ticks per second. The target is 20; below 18 players feel rubberbanding.",
                   "min(avg_over_time(dune:game_tick_rate:hz[5m]))", "", 12, 0, 4, 7, unit="hertz", decimals=1,
                   steps=[(None, theme.BAD), (18, theme.WARN), (19.5, "#2a2217")], value_size=56))
    p.append(tiles("Internet use", "The busier direction of the internet link as a share of the %d Mbit/s plan." % INTERNET_PLAN_MBIT,
                   "((rate(unifi_wan_receive_bytes_total[1m]) + rate(unifi_wan_transmit_bytes_total[1m]) + abs(rate(unifi_wan_receive_bytes_total[1m]) - rate(unifi_wan_transmit_bytes_total[1m]))) / 2) * 8 / (%d * 1e6)" % INTERNET_PLAN_MBIT,
                   "", 16, 0, 4, 7, unit="percentunit", decimals=1,
                   steps=[(None, "#2a2217"), (0.6, theme.WARN), (0.85, theme.BAD)], value_size=56))
    p.append(tiles("Hottest sensor", "Hottest host temperature sensor.", 'max(node_hwmon_temp_celsius{source="r740-host"})', "",
                   20, 0, 4, 7, unit="celsius", decimals=0,
                   steps=[(None, "#2a2217"), (75, theme.WARN), (85, theme.BAD)], value_size=56))
    p.append(tiles("The world", "Each always-on map: Sietches (Survival_1), the Overmap and the Deep Deserts.",
                   named(parts), "{{name}} \u00b7 {{map}}", 0, 7, 24, 5, decimals=0, graph=False,
                   steps=[(None, theme.BAD), (1, theme.OK)], words={1: ("READY", theme.OK), 0: ("DOWN", theme.BAD)}, value_size=30))
    p.append(tiles("Tick rate by map", "Ticks per second of each map server with its last 6 hours behind it. Target 20; below 18 is rubberbanding. A map that is idle writes nothing to its log and shows no tile.",
                   "dune:game_tick_rate:hz > 0", "{{server}}", 0, 12, 24, 6, unit="hertz", decimals=1,
                   steps=[(None, theme.BAD), (18, theme.WARN), (19.5, "#2a2217")], value_size=30))
    p.append(ring("Guest CPU", "Average busy share across the game server VM's 60 vCPUs.",
                  "avg(dune:vcpu_busy:ratio)", 0, 18, 6, 6, warn=0.6, red=0.85))
    p.append(ring("Guest memory", "Share of the game server VM's memory in use.",
                  '1 - node_memory_MemAvailable_bytes{job="dune-node"}/node_memory_MemTotal_bytes{job="dune-node"}',
                  6, 18, 6, 6, warn=0.8, red=0.92))
    p.append(ring("Busiest map thread", "Highest main-thread CPU of any map (1.0 = one core). Above 0.9 is a burst.",
                  "max(dune:map_main_thread:cores)", 12, 18, 6, 6, unit="none", decimals=2, warn=0.6, red=0.9))
    p.append(ring("VM disk pool", "Share used of the Proxmox thin pool that holds the VM disks. A full pool freezes every VM on it.",
                  'pve_disk_usage_bytes{id="storage/DA-1/local-lvm"} / pve_disk_size_bytes{id="storage/DA-1/local-lvm"}',
                  18, 18, 6, 6, warn=0.8, red=0.9))
    p.append(lanes("state-timeline", "Map state over time", "Green while the map is ready, red while it is down. Orange lines mark map restarts and blue lines backups on every graph.",
                   [target(named(parts), "{{name}} \u00b7 {{map}}")], 0, 24, 24, 7,
                   steps=[(None, theme.BAD), (1, theme.OK)], mappings={1: ("Ready", theme.OK), 0: ("Down", theme.BAD)}))
    p.append(lanes("status-history", "Tick rate through the day",
                   "One row per map, one cell per 10 minutes: green is a healthy 19.5 ticks per second or more, amber 18 to 19.5, red below 18, grey no data (an idle map writes nothing to its log, so grey is not a fault). Set the time range to 24 hours or 7 days to see when stalls cluster.",
                   [target("avg_over_time(dune:game_tick_rate:hz[10m]) > 0", "{{server}}")], 0, 31, 24, 8,
                   steps=[(None, theme.BAD), (18, theme.WARN), (19.5, theme.OK)], unit="hertz", decimals=1, interval="10m"))
    backup_w = 'time() - node_systemd_timer_last_trigger_seconds{name="r740-backup-weekly.timer"}'
    backup_d = 'time() - node_systemd_timer_last_trigger_seconds{name="r740-backup-daily.timer"}'
    up = 'time() - max(namedprocess_namegroup_oldest_start_time_seconds{groupname=~"(Survival_1|Overmap|DeepDesert_1)_p(1|2|8|36|37)"})'
    p.append(tiles("Maps running for", "Time since the game maps last started. They restart daily at 05:00 Pacific.", up, "", 0, 39, 8, 4,
                   unit="dtdurations", graph=False, steps=[(None, "#2a2217")], value_size=34))
    p.append(tiles("Since the weekly backup", "Time since the weekly backup last started. Amber after 8 days, red after 10.", backup_w, "", 8, 39, 8, 4,
                   unit="dtdurations", graph=False, steps=[(None, "#2a2217"), (8 * 86400, theme.WARN), (10 * 86400, theme.BAD)], value_size=34))
    p.append(tiles("Since the daily backup", "Time since the daily backup last started. Amber after 26 hours, red after 50.", backup_d, "", 16, 39, 8, 4,
                   unit="dtdurations", graph=False, steps=[(None, "#2a2217"), (26 * 3600, theme.WARN), (50 * 3600, theme.BAD)], value_size=34))
    pad = 'label_replace(%s, "cpu", "0$1", "cpu", "([0-9])")'
    heat = [(None, "#2a2217"), (0.1, "#4a3b28"), (0.3, "#8a6a3a"), (0.55, theme.SPICE), (0.8, theme.WARN), (0.92, theme.BAD)]
    p.append(tiles("Game cores (0-39)", "The vCPUs the game maps are pinned to, one tile each in order from 00. Darker is idle, orange busy, red saturated.",
                   pad % 'dune:vcpu_busy:ratio{cpu=~"[0-9]|[1-3][0-9]"}', "{{cpu}}", 0, 43, 16, 6, unit="percentunit", decimals=0,
                   steps=heat, graph=False, show_text=False, solid=True))
    p.append(tiles("Monitoring cores (40-59)", "The vCPUs left for monitoring and the rest of the system.",
                   pad % 'dune:vcpu_busy:ratio{cpu=~"[4-5][0-9]"}', "{{cpu}}", 16, 43, 8, 6, unit="percentunit", decimals=0,
                   steps=heat, graph=False, show_text=False, solid=True))
    d = dashboard("dune-wall", "Arrakis \u00b7 Wall",
                  "One screen for a TV or a phone: verdict, maps, pressure, the day and the cores (meta#99). Private.",
                  p, ["dune", "wall"], banner=("ARRAKIS", "I compute; I do not guess. \u2014 Sahir Venn"),
                  rows=[(0, "Right now"), (7, "The world"), (18, "Pressure"), (24, "The day"), (39, "Clocks"), (43, "Cores")])
    d["refresh"] = "30s"
    d["time"] = {"from": "now-24h", "to": "now"}
    return d


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    (out / "dune-bursts.json").write_text(json.dumps(bursts(), indent=2) + "\n")
    (out / "dune-host.json").write_text(json.dumps(hostvm(), indent=2) + "\n")
    (out / "dune-game.json").write_text(json.dumps(game(), indent=2) + "\n")
    (out / "dune-data.json").write_text(json.dumps(data(), indent=2) + "\n")
    (out / "dune-wall.json").write_text(json.dumps(wall(), indent=2) + "\n")
    (out / "dune-overview.json").write_text(json.dumps(overview(), indent=2) + "\n")
    print("wrote", sorted(f.name for f in out.glob("*.json")))


if __name__ == "__main__":
    main()
