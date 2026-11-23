#!/usr/bin/env python3
"""Prometheus exporter for the UniFi gateway's internet (WAN) port. Read-only (GET only), standard library only.

Why: the VM and the host's network card cannot see what limits players, the internet link. The gateway keeps
that port's counters, latency and speed-test results; this turns them into metrics (meta#99).

Reads ONE endpoint, /proxy/network/api/s/default/stat/device (fast, 0.07 s; stat/health takes about 15 s, so it
is not used). The API token comes from a systemd credential ($CREDENTIALS_DIRECTORY/unifi-token) or the file
named by UNIFI_TOKEN_FILE, and is never logged or exposed. The gateway address defaults to this host's default
route (UNIFI_HOST overrides it). The gateway's certificate is self-signed, so TLS is not verified; the exporter
only ever talks to that one address. Listens on 127.0.0.1 only.

  unifi_exporter.py                 # serve /metrics (LISTEN=127.0.0.1:9291)
  unifi_exporter.py --selftest      # offline check of the metric rendering, no network
"""
import json
import os
import ssl
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

CACHE_S = float(os.environ.get("UNIFI_CACHE_S", "10"))
TIMEOUT_S = float(os.environ.get("UNIFI_TIMEOUT_S", "15"))
PATH = "/proxy/network/api/s/default/stat/device"


def read_token():
    cred = os.environ.get("CREDENTIALS_DIRECTORY")
    path = os.path.join(cred, "unifi-token") if cred else os.environ.get("UNIFI_TOKEN_FILE", "")
    with open(path) as fh:
        return fh.read().strip()


def default_gateway():
    with open("/proc/net/route") as fh:
        for line in fh.read().splitlines()[1:]:
            f = line.split()
            if len(f) > 2 and f[1] == "00000000":
                g = f[2]
                return ".".join(str(int(g[i:i + 2], 16)) for i in (6, 4, 2, 0))
    raise RuntimeError("no default route")


def fetch_devices():
    host = os.environ.get("UNIFI_HOST") or default_gateway()
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    req = urllib.request.Request("https://%s%s" % (host, PATH), headers={"X-API-KEY": read_token(), "Accept": "application/json"}, method="GET")
    with urllib.request.urlopen(req, timeout=TIMEOUT_S, context=ctx) as r:
        return json.load(r)["data"]


def num(v):
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def render(devices, ok=True, duration=0.0, last_ok=0.0):
    """Metrics text from the device list. The gateway is the device that has a wan1 block."""
    lines = []

    def metric(name, kind, help_, value):
        if value is None:
            return
        lines.append("# HELP %s %s" % (name, help_))
        lines.append("# TYPE %s %s" % (name, kind))
        lines.append("%s %s" % (name, repr(float(value))))

    gw = next((d for d in devices or [] if isinstance(d.get("wan1"), dict)), None)
    metric("unifi_exporter_scrape_success", "gauge", "1 when the last read of the gateway worked.", 1 if (ok and gw) else 0)
    metric("unifi_exporter_scrape_duration_seconds", "gauge", "How long the last read of the gateway took.", duration)
    metric("unifi_exporter_last_success_timestamp_seconds", "gauge", "Unix time of the last good read.", last_ok or None)
    if gw:
        w = gw["wan1"]
        metric("unifi_wan_up", "gauge", "1 when the internet port is up.", 1 if w.get("up") is True else 0)
        metric("unifi_wan_link_speed_mbps", "gauge", "Negotiated speed of the internet port, Mbit/s.", num(w.get("speed")))
        metric("unifi_wan_max_speed_mbps", "gauge", "Maximum speed of the internet port, Mbit/s.", num(w.get("max_speed")))
        metric("unifi_wan_latency_ms", "gauge", "Latency from the gateway to the internet as the gateway measures it, ms.", num(w.get("latency")))
        metric("unifi_wan_availability_percent", "gauge", "Internet availability as the gateway measures it.", num(w.get("availability")))
        for key, name, help_ in (("rx_bytes", "unifi_wan_receive_bytes_total", "Bytes received on the internet port."),
                                 ("tx_bytes", "unifi_wan_transmit_bytes_total", "Bytes sent on the internet port."),
                                 ("rx_packets", "unifi_wan_receive_packets_total", "Packets received on the internet port."),
                                 ("tx_packets", "unifi_wan_transmit_packets_total", "Packets sent on the internet port."),
                                 ("rx_errors", "unifi_wan_receive_errors_total", "Receive errors on the internet port."),
                                 ("tx_errors", "unifi_wan_transmit_errors_total", "Transmit errors on the internet port."),
                                 ("rx_dropped", "unifi_wan_receive_dropped_total", "Packets dropped on receive on the internet port."),
                                 ("tx_dropped", "unifi_wan_transmit_dropped_total", "Packets dropped on transmit on the internet port.")):
            metric(name, "counter", help_, num(w.get(key)))
        st = gw.get("speedtest-status")
        if isinstance(st, dict):
            metric("unifi_wan_speedtest_download_mbps", "gauge", "Download speed of the gateway's last speed test, Mbit/s.", num(st.get("xput_download")))
            metric("unifi_wan_speedtest_upload_mbps", "gauge", "Upload speed of the gateway's last speed test, Mbit/s.", num(st.get("xput_upload")))
            metric("unifi_wan_speedtest_latency_ms", "gauge", "Latency of the gateway's last speed test, ms.", num(st.get("latency")))
            metric("unifi_wan_speedtest_timestamp_seconds", "gauge", "Unix time of the gateway's last speed test.", num(st.get("rundate")))
    return "\n".join(lines) + "\n"


_lock = threading.Lock()
_cache = {"at": 0.0, "text": render([], ok=False), "last_ok": 0.0}


def scrape():
    with _lock:
        now = time.time()
        if now - _cache["at"] < CACHE_S:
            return _cache["text"]
        t0 = time.time()
        try:
            devices, ok = fetch_devices(), True
            _cache["last_ok"] = time.time()
        except Exception as error:  # never print the address or token; the class name is enough
            devices, ok = [], False
            sys.stderr.write("unifi read failed: %s\n" % error.__class__.__name__)
        _cache["text"] = render(devices, ok=ok, duration=time.time() - t0, last_ok=_cache["last_ok"])
        _cache["at"] = now
        return _cache["text"]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?")[0] != "/metrics":
            self.send_response(404); self.end_headers(); return
        body = scrape().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):  # no access log: nothing here is worth keeping
        pass


def selftest():
    sample = [{"name": "ap"}, {"wan1": {"up": True, "speed": 2500, "max_speed": 2500, "latency": 3, "availability": 100,
                                        "rx_bytes": 10, "tx_bytes": 20, "rx_errors": 0, "tx_dropped": 1},
                               "speedtest-status": {"xput_download": 1792.0, "xput_upload": 2112.0, "latency": 3, "rundate": 1795351531}}]
    out = render(sample, ok=True, duration=0.07, last_ok=1.0)
    for want in ("unifi_wan_up 1.0", "unifi_wan_link_speed_mbps 2500.0", "unifi_wan_receive_bytes_total 10.0",
                 "unifi_wan_speedtest_download_mbps 1792.0", "unifi_exporter_scrape_success 1.0"):
        assert want in out, want
    down = render([], ok=False)
    assert "unifi_exporter_scrape_success 0.0" in down and "unifi_wan_up" not in down
    print("selftest ok")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    else:
        host, _, port = os.environ.get("LISTEN", "127.0.0.1:9291").rpartition(":")
        HTTPServer((host, int(port)), Handler).serve_forever()
