#!/usr/bin/env python3
"""Server tick rate per map, derived from the game's own log (meta#99).

Every Unreal log line starts with [timestamp][frame counter mod 1000]. Between two
lines 1 to 25 s apart the frame difference (mod 1000) divided by the time difference
is the server tick rate. The game targets 20 Hz. We export counters so Prometheus
computes rates over any window:

  dune_game_frames_total{server}            frames counted
  dune_game_frame_seconds_total{server}     seconds those frames cover
  dune_game_slow_seconds_total{server}      seconds spent below SLOW_HZ (default 18)
  dune_game_physics_throttled_total{server} vehicle-physics catch-up events (log line)

  tick rate (Hz) = rate(frames_total[w]) / rate(frame_seconds_total[w])

Only parses the prefix of each line; never stores or prints line contents (game logs
can contain tokens). Only logs written in the last ACTIVE_S seconds are followed.
Standard library only, read-only mount.
"""
import glob
import os
import re
import threading
import time
from calendar import timegm
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = os.environ.get("GAME_ROOT", "/game")
ACTIVE_S = float(os.environ.get("ACTIVE_S", "600"))
SLOW_HZ = float(os.environ.get("SLOW_HZ", "18"))
LISTEN = int(os.environ.get("LISTEN_PORT", "9301"))
SCAN_S = 30
POLL_S = 5

RX = re.compile(rb"^\[(\d{4})\.(\d\d)\.(\d\d)-(\d\d)\.(\d\d)\.(\d\d):(\d{3})\]\[\s*(\d+)\]")
PHYS = b"Exceeded MaxNumStepsThrottled"

lock = threading.Lock()
state = {}   # path -> dict(server, inode, off, anchor, partial)
totals = {}  # server -> dict of counters


def server_of(path):
    return path.split("/Saved/Logs/")[0].rstrip("/").split("/")[-1]


def tot(server):
    return totals.setdefault(server, {"frames": 0.0, "secs": 0.0, "slow": 0.0, "phys": 0})


def process(st, chunk):
    server = st["server"]
    data = st["partial"] + chunk
    lines = data.split(b"\n")
    st["partial"] = lines.pop()  # incomplete tail
    t = tot(server)
    for ln in lines:
        if PHYS in ln:
            t["phys"] += 1
        m = RX.match(ln)
        if not m:
            continue
        y, mo, d, h, mi, s, ms, fr = (int(x) for x in m.groups())
        ts = timegm((y, mo, d, h, mi, s)) + ms / 1000.0
        a = st["anchor"]
        if a is None or ts < a[0]:
            st["anchor"] = (ts, fr)
            continue
        dt = ts - a[0]
        if dt < 1.0:
            continue
        if dt <= 25.0:
            df = (fr - a[1]) % 1000
            rate = df / dt
            if rate <= 40.0:  # reordered lines give absurd rates; skip them
                t["frames"] += df
                t["secs"] += dt
                if rate < SLOW_HZ:
                    t["slow"] += dt
        st["anchor"] = (ts, fr)


def scan():
    now = time.time()
    found = set()
    for p in glob.glob(ROOT + "/*/Saved/Logs/DuneSandbox_PIDX-*.log"):
        if "backup" in p:
            continue
        try:
            if now - os.stat(p).st_mtime <= ACTIVE_S:
                found.add(p)
        except OSError:
            pass
    with lock:
        for p in found:
            if p not in state:
                try:
                    st = os.stat(p)
                except OSError:
                    continue
                # start tailing from now; no history backfill
                state[p] = {"server": server_of(p), "inode": st.st_ino, "off": st.st_size,
                            "anchor": None, "partial": b""}
                tot(server_of(p))
        for p in [p for p in state if p not in found]:
            del state[p]


def poll():
    with lock:
        paths = list(state)
    for p in paths:
        try:
            st = os.stat(p)
            with lock:
                s = state.get(p)
                if not s:
                    continue
                if st.st_ino != s["inode"] or st.st_size < s["off"]:
                    s.update(inode=st.st_ino, off=0, anchor=None, partial=b"")
                if st.st_size > s["off"]:
                    with open(p, "rb") as f:
                        f.seek(s["off"])
                        chunk = f.read(min(st.st_size - s["off"], 4 * 1024 * 1024))
                    s["off"] += len(chunk)
                    process(s, chunk)
        except OSError:
            pass


def loop():
    last_scan = 0
    while True:
        if time.time() - last_scan > SCAN_S:
            scan()
            last_scan = time.time()
        poll()
        time.sleep(POLL_S)


def render():
    out = []
    with lock:
        for server, t in sorted(totals.items()):
            lab = '{server="%s"}' % server
            out.append("dune_game_frames_total%s %.0f" % (lab, t["frames"]))
            out.append("dune_game_frame_seconds_total%s %.3f" % (lab, t["secs"]))
            out.append("dune_game_slow_seconds_total%s %.3f" % (lab, t["slow"]))
            out.append("dune_game_physics_throttled_total%s %d" % (lab, t["phys"]))
        out.append("dune_game_log_files_followed %d" % len(state))
    return "\n".join(out) + "\n"


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        data = render().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    threading.Thread(target=loop, daemon=True).start()
    HTTPServer(("0.0.0.0", LISTEN), H).serve_forever()
