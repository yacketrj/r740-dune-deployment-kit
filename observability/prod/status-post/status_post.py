#!/usr/bin/env python3
"""Live status message for a Discord channel (meta#99).

Reads a few series from Prometheus and keeps ONE webhook message up to date by
editing it in place (no channel spam). Player-facing: shows only health, load and
counts; no addresses, host names, temperatures or player names. Standard library only.
The webhook URL is read from a file and never printed.

  python status_post.py --dry-run     # print what would be sent, send nothing

Two ways to deliver, chosen by environment:
  RELAY_URL set     -> push {state, headline, fields} to the Mentat bot (/api/status/relay), which writes the
                       post in Sahir Venn's voice and keeps one live message up to date (mentat#469).
  RELAY_URL unset   -> the original webhook mode (the webhook URL file), kept as a one-setting rollback.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

PROM = os.environ.get("PROM_URL", "http://dune-prometheus:9090")
HOOK_FILE = os.environ.get("WEBHOOK_FILE", "/run/secrets/discord-webhook")
RELAY_URL = os.environ.get("RELAY_URL", "")
RELAY_TOKEN_FILE = os.environ.get("RELAY_TOKEN_FILE", "/run/secrets/status-relay-token")
STATE_FILE = os.environ.get("STATE_FILE", "/state/message.json")
TITLE = os.environ.get("STATUS_TITLE", "Server status")
USERNAME = os.environ.get("STATUS_USERNAME", "Server Status")
INTERVAL = float(os.environ.get("STATUS_INTERVAL", "300"))
UA = "DiscordBot (https://example.invalid, 1.0) status-poster"
GREEN, AMBER, RED = 0x2ECC71, 0xF1C40F, 0xE74C3C


def q(expr):
    url = PROM + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    with urllib.request.urlopen(url, timeout=8) as r:
        res = json.load(r)["data"]["result"]
    return float(res[0]["value"][1]) if res else None


def fmt_pct(v):
    return "n/a" if v is None else "%.0f%%" % (v * 100)


def fmt_dur(sec):
    if sec is None:
        return "n/a"
    d, rem = divmod(int(sec), 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    return ("%dd %dh" % (d, h)) if d else ("%dh %dm" % (h, m))


def fmt_network(rx_bits, tx_bits):
    """One field, one unit: the game server VM's traffic in Mbit/s (down = to the server, up = from it)."""
    if rx_bits is None or tx_bits is None:
        return "n/a"
    return "\u2193 %.2f \u00b7 \u2191 %.2f Mbit/s" % (rx_bits / 1e6, tx_bits / 1e6)


def build():
    up = q("dune_api_up")
    ready = q("dune_server_ready")
    fls_bad = q("count(dune_fls_ok == 0) or vector(0)")
    players = q("dune_players_online")
    cap = q("dune_population_capacity")
    maps_up = q("count(dune_gameserver_ready == 1) or vector(0)")
    maps_all = q("count(dune_gameserver_ready) or vector(0)")
    cpu = q('avg(dune:vcpu_busy:ratio)')
    mem = q('1 - node_memory_MemAvailable_bytes{job="dune-node"}/node_memory_MemTotal_bytes{job="dune-node"}')
    disk = q('1 - node_filesystem_avail_bytes{job="dune-node",device=~"/dev/mapper/.*"}'
             '/node_filesystem_size_bytes{job="dune-node",device=~"/dev/mapper/.*"}')
    rx = q('sum(rate(node_network_receive_bytes_total{job="dune-node",device="eth0"}[1m]))*8')
    tx = q('sum(rate(node_network_transmit_bytes_total{job="dune-node",device="eth0"}[1m]))*8')
    main = q("max(max_over_time(dune:map_main_thread:cores[5m]))")
    spikes = q("sum(changes(dune:map_main_thread_hot[1h]))/2")
    steal = q("max_over_time(dune:cpu_steal:ratio[5m])")
    uptime = q('time()-node_boot_time_seconds{job="dune-node"}')

    if up != 1 or ready is None:
        state, color, icon = "Status unavailable", AMBER, "\U0001F7E1"
    elif ready != 1:
        state, color, icon = "Offline or starting", RED, "\U0001F534"
    elif (fls_bad or 0) > 0:
        state, color, icon = "Online (login services degraded)", AMBER, "\U0001F7E1"
    else:
        state, color, icon = "Online", GREEN, "\U0001F7E2"

    tick = q("min(avg_over_time(dune:game_tick_rate:hz[5m]))")
    if main is None:
        perf = "n/a"
    elif main < 0.6:
        perf = "Smooth"
    elif main < 0.9:
        perf = "Busy"
    else:
        perf = "Heavy load"
    if tick is not None:  # a low tick rate overrides the CPU-based rating
        if tick < 18:
            perf = "Heavy load"
        elif tick < 19.5 and perf == "Smooth":
            perf = "Busy"
    perf_extra = ""
    if tick is not None:
        perf_extra += "\nServer tick: **%.1f Hz** (target 20)" % tick
    if spikes is not None:
        perf_extra += "\nLag spikes in the last hour: **%d**" % round(spikes)

    def f(name, value, inline=True):
        return {"name": name, "value": value, "inline": inline}

    fields = [
        f("Status", "%s %s" % (icon, state)),
        f("Players", "%s / %s" % ("n/a" if players is None else int(players), "n/a" if cap is None else int(cap))),
        f("Maps online", "%d of %d" % (maps_up or 0, maps_all or 0)),
        f("Game performance", "**%s**%s" % (perf, perf_extra), inline=False),
        f("Server CPU", fmt_pct(cpu)),
        f("Memory", fmt_pct(mem)),
        f("Disk", fmt_pct(disk)),
        f("Network", fmt_network(rx, tx)),
        f("Server uptime", fmt_dur(uptime)),
    ]
    if steal is not None and steal > 0.10:
        fields.append(f("Host contention", "Elevated (%s)" % fmt_pct(steal)))
    return {
        "username": USERNAME,
        "allowed_mentions": {"parse": []},
        "embeds": [{
            "title": TITLE,
            "color": color,
            "description": "Last updated <t:%d:R> (<t:%d:t>)" % (int(time.time()), int(time.time())),
            "fields": fields,
            "footer": {"text": "Updates every %d minutes" % round(INTERVAL / 60)},
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }],
    }


STATE_FOR_BOT = {"Online": "ok", "Online (login services degraded)": "degraded",
                 "Offline or starting": "down", "Status unavailable": "unknown"}


def relay_payload(embed_payload):
    """The same numbers as the webhook embed, as plain data; the bot owns the title, voice and quote."""
    embed = embed_payload["embeds"][0]
    fields = embed["fields"]
    status = next(f for f in fields if f["name"] == "Status")["value"]
    text = status.split(" ", 1)[1] if " " in status else status  # drop the colour dot
    return {"state": STATE_FOR_BOT.get(text, "unknown"), "headline": text,
            "fields": [{"name": f["name"], "value": f["value"].replace("**", ""), "inline": f["inline"]}
                       for f in fields if f["name"] != "Status"]}


def relay_push(embed_payload):
    with open(RELAY_TOKEN_FILE) as fh:
        token = fh.read().strip()
    req = urllib.request.Request(RELAY_URL, data=json.dumps(relay_payload(embed_payload)).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": "Bearer " + token,
                                          "User-Agent": "mentat-status-push/1.0"})
    with urllib.request.urlopen(req, timeout=20) as r:
        body = json.load(r)
    return "pushed (edited)" if body.get("edited") else "pushed (posted)"


def read_hook():
    with open(HOOK_FILE) as fh:
        return fh.read().strip()


def call(method, url, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Content-Type": "application/json", "User-Agent": UA})
    with urllib.request.urlopen(req, timeout=15) as r:
        body = r.read()
    return json.loads(body) if body else {}


def load_state():
    try:
        with open(STATE_FILE) as fh:
            return json.load(fh).get("id")
    except (OSError, ValueError):
        return None


def save_state(mid):
    with open(STATE_FILE, "w") as fh:
        json.dump({"id": mid}, fh)


def publish(payload):
    hook = read_hook()
    mid = load_state()
    if mid:
        try:
            call("PATCH", "%s/messages/%s" % (hook, mid), {"embeds": payload["embeds"]})
            return "edited"
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
    res = call("POST", hook + "?wait=true", payload)
    save_state(res["id"])
    return "posted"


def main():
    if "--dry-run" in sys.argv:
        built = build()
        print(json.dumps(relay_payload(built) if RELAY_URL else built, indent=2))
        return
    while True:
        try:
            print(relay_push(build()) if RELAY_URL else publish(build()), flush=True)
        except Exception as e:  # never print the URL
            print("update failed: %s %s" % (type(e).__name__, getattr(e, "code", "")), flush=True)
        if "--once" in sys.argv:
            return
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
