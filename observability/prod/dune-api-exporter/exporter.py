#!/usr/bin/env python3
"""Prometheus adapter for the Dune console HTTP API (meta#99).

Polls a few read-only JSON endpoints with a read-scoped API key and serves
/metrics. The key is read from a file and never logged. Standard library only.
"""
import json
import os
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

BASE = os.environ.get("CONSOLE_URL", "http://host.docker.internal:8088")
KEY_FILE = os.environ.get("KEY_FILE", "/run/secrets/console-api-key")
INTERVAL = float(os.environ.get("POLL_SECONDS", "10"))
LISTEN = int(os.environ.get("LISTEN_PORT", "9300"))

lock = threading.Lock()
body = "dune_api_up 0\n"

# partition id -> the name players see. The map status call only has the database label, which
# keeps its old value after a Sietch is renamed.
names = {}
names_at = 0.0
NAMES_EVERY = 60.0
NAMED_MAPS = ("Survival_1", "DeepDesert_1")  # the maps with several instances to tell apart


def refresh_names(get, key, maps, now):
    global names_at
    if now - names_at < NAMES_EVERY:
        return
    names_at = now
    for m in maps:
        try:
            rows = get("/api/maps/combat-state?map=" + urllib.parse.quote(m), key).get("partitions", [])
        except Exception as e:  # keep the last known names; the rest of the poll still counts
            print("name lookup failed: %s" % type(e).__name__, flush=True)
            continue
        for r in rows:
            if r.get("serverDisplayName"):
                names[str(r.get("partitionId"))] = r["serverDisplayName"]


def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def get(path, key):
    req = urllib.request.Request(BASE + path, headers={"Authorization": "Bearer " + key})
    with urllib.request.urlopen(req, timeout=8) as r:
        return json.load(r)


def read_key():
    with open(KEY_FILE) as f:
        return f.read().strip()


def collect(get=get, key=None, now=None):
    key = read_key() if key is None else key
    now = time.time() if now is None else now
    out, add = [], lambda n, v, **lab: out.append(
        "%s%s %s" % (n, ("{" + ",".join('%s="%s"' % (k, esc(x)) for k, x in lab.items()) + "}") if lab else "", v))
    t0 = time.time()
    st = get("/api/server/status?raw=0", key)["data"]
    ms = get("/api/map/status?raw=0", key)["data"]
    mem = get("/api/maps/memory/live", key)
    pl = get("/api/players/online?pageSize=1", key)
    s = st["summary"]
    add("dune_server_ready", 1 if s.get("overall") == "READY" else 0, overall=s.get("overall", ""))
    add("dune_population_current", s["population"]["current"])
    add("dune_population_capacity", s["population"]["capacity"])
    add("dune_players_online", pl.get("totalCount", 0))
    add("dune_players_known", pl.get("totalPlayers", 0))
    for g in st.get("gameServers", []):
        add("dune_gameserver_ready", 1 if g.get("status") == "READY" else 0, map=g.get("map", ""))
    for k, v in (st.get("fls") or {}).items():
        add("dune_fls_ok", 1 if v == "OK" else 0, check=k)
    add("dune_autoscaler_running", 1 if (ms.get("autoscaler") or {}).get("state") == "running" else 0)
    parts = ms.get("partitions", [])
    refresh_names(get, key, sorted({p["map"] for p in parts if p.get("ready") and p.get("map") in NAMED_MAPS}), now)
    for p in parts:
        lab = dict(map=p.get("map", ""), partition=p.get("partitionId", ""), label=p.get("label", ""))
        add("dune_partition_ready", 1 if p.get("ready") else 0, **lab)
        add("dune_partition_alive", 1 if p.get("alive") else 0, **lab)
        pid = str(lab["partition"])
        add("dune_partition_info", 1, map=lab["map"], partition=pid, name=names.get(pid) or lab["label"])
    for r in mem.get("rows", []):
        lab = dict(container=r.get("container", ""), map=r.get("map", ""))
        add("dune_map_memory_used_bytes", r.get("usedBytes", 0), **lab)
        add("dune_map_memory_limit_bytes", r.get("limitBytes", 0), **lab)
        add("dune_map_swap_used_bytes", r.get("swapUsedBytes", 0), **lab)
    add("dune_api_poll_seconds", round(time.time() - t0, 3))
    add("dune_api_up", 1)
    return "\n".join(out) + "\n"


def poll():
    global body
    while True:
        try:
            text = collect()
        except Exception as e:  # keep serving; report down, never log the key
            text = "dune_api_up 0\n"
            print("poll failed: %s" % type(e).__name__, flush=True)
        with lock:
            body = text
        time.sleep(INTERVAL)


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        with lock:
            data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    threading.Thread(target=poll, daemon=True).start()
    HTTPServer(("0.0.0.0", LISTEN), H).serve_forever()
