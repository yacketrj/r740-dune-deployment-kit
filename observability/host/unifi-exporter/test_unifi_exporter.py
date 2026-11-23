"""Tests for unifi_exporter.py. Run: python3 -m unittest observability/host/unifi-exporter/test_unifi_exporter.py"""
import io
import os
import sys
import unittest
from contextlib import redirect_stderr

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import unifi_exporter as ue  # noqa: E402

GW = {"wan1": {"up": True, "speed": 2500, "max_speed": 2500, "latency": 3, "availability": 100, "rx_bytes": 1000, "tx_bytes": 2000,
               "rx_packets": 5, "tx_packets": 6, "rx_errors": 0, "tx_errors": 0, "rx_dropped": 0, "tx_dropped": 2},
      "speedtest-status": {"xput_download": 1792.0, "xput_upload": 2112.0, "latency": 3, "rundate": 1795351531}}


class Render(unittest.TestCase):
    def test_gateway_metrics_and_counter_types(self):
        out = ue.render([{"name": "access point"}, GW], ok=True, duration=0.07, last_ok=100.0)
        for want in ("unifi_wan_up 1.0", "unifi_wan_link_speed_mbps 2500.0", "unifi_wan_latency_ms 3.0", "unifi_wan_availability_percent 100.0",
                     "unifi_wan_receive_bytes_total 1000.0", "unifi_wan_transmit_dropped_total 2.0",
                     "unifi_wan_speedtest_download_mbps 1792.0", "unifi_wan_speedtest_upload_mbps 2112.0",
                     "unifi_exporter_scrape_success 1.0", "# TYPE unifi_wan_receive_bytes_total counter", "# TYPE unifi_wan_up gauge"):
            self.assertIn(want, out)

    def test_port_down_is_reported_as_zero(self):
        down = {"wan1": dict(GW["wan1"], up=False)}
        self.assertIn("unifi_wan_up 0.0", ue.render([down], ok=True))

    def test_no_gateway_or_failed_read_says_so_and_emits_no_wan_series(self):
        for devices, ok in (([{"name": "access point"}], True), ([], False)):
            out = ue.render(devices, ok=ok)
            self.assertIn("unifi_exporter_scrape_success 0.0", out)
            self.assertNotIn("unifi_wan_up", out)

    def test_non_numeric_and_bool_values_are_skipped_not_crashed_on(self):
        odd = {"wan1": {"up": True, "speed": "fast", "latency": True, "rx_bytes": None}}
        out = ue.render([odd], ok=True)
        self.assertNotIn("unifi_wan_link_speed_mbps", out)
        self.assertNotIn("unifi_wan_latency_ms", out)
        self.assertNotIn("unifi_wan_receive_bytes_total", out)


class Scrape(unittest.TestCase):
    def setUp(self):
        ue._cache.update({"at": 0.0, "text": "", "last_ok": 0.0})

    def test_a_failed_read_returns_success_zero_and_never_logs_the_token_or_address(self):
        def boom():
            raise RuntimeError("GET https://10.9.8.7/x with X-API-KEY: SECRET-TOKEN failed")
        real, ue.fetch_devices = ue.fetch_devices, boom
        err = io.StringIO()
        try:
            with redirect_stderr(err):
                text = ue.scrape()
        finally:
            ue.fetch_devices = real
        self.assertIn("unifi_exporter_scrape_success 0.0", text)
        self.assertIn("RuntimeError", err.getvalue())
        self.assertNotIn("SECRET-TOKEN", err.getvalue() + text)
        self.assertNotIn("10.9.8.7", err.getvalue() + text)

    def test_reads_are_cached_so_prometheus_cannot_hammer_the_gateway(self):
        calls = []
        real, ue.fetch_devices = ue.fetch_devices, lambda: (calls.append(1) or [GW])
        try:
            first, second = ue.scrape(), ue.scrape()
        finally:
            ue.fetch_devices = real
        self.assertEqual(len(calls), 1)
        self.assertEqual(first, second)
        self.assertIn("unifi_wan_up 1.0", first)


class Config(unittest.TestCase):
    def test_token_comes_from_the_systemd_credential_directory(self):
        import tempfile
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as d:
            with open(os.path.join(d, "unifi-token"), "w") as fh:
                fh.write("abc123\n")
            old = os.environ.get("CREDENTIALS_DIRECTORY")
            os.environ["CREDENTIALS_DIRECTORY"] = d
            try:
                self.assertEqual(ue.read_token(), "abc123")
            finally:
                os.environ.pop("CREDENTIALS_DIRECTORY") if old is None else os.environ.__setitem__("CREDENTIALS_DIRECTORY", old)

    def test_the_module_only_ever_issues_get_requests(self):
        src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "unifi_exporter.py")).read()
        for verb in ("POST", "PUT", "DELETE", "PATCH"):
            self.assertNotIn('method="%s"' % verb, src)


if __name__ == "__main__":
    unittest.main()
