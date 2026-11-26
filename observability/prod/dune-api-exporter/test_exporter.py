#!/usr/bin/env python3
"""Tests for the partition display names. Run: python3 -m unittest discover -s observability/prod/dune-api-exporter"""
import unittest

import exporter

PARTS = [
    {"partitionId": 1, "map": "Survival_1", "label": "OldOne", "ready": True, "alive": True},
    {"partitionId": 2, "map": "Overmap", "label": "Overland", "ready": True, "alive": True},
]


def fake_get(names):
    def get(path, key):
        if path.startswith("/api/maps/combat-state?map="):
            if names is None:
                raise OSError("unavailable")
            m = path.split("=", 1)[1]
            return {"partitions": [{"partitionId": p, "serverDisplayName": n}
                                   for (mm, p), n in names.items() if mm == m]}
        return {
            "/api/server/status?raw=0": {"data": {"summary": {"overall": "READY", "population": {"current": 0, "capacity": 1}}}},
            "/api/map/status?raw=0": {"data": {"partitions": PARTS}},
            "/api/maps/memory/live": {"rows": []},
            "/api/players/online?pageSize=1": {},
        }[path]
    return get


class DisplayNames(unittest.TestCase):
    def setUp(self):
        exporter.names.clear()
        exporter.names_at = 0.0

    def collect(self, names, now):
        return exporter.collect(get=fake_get(names), key="k", now=now)

    def test_uses_the_server_display_name(self):
        out = self.collect({("Survival_1", "1"): "Sietch Example", ("Overmap", "2"): None}, 1000.0)
        self.assertIn('dune_partition_info{map="Survival_1",partition="1",name="Sietch Example"} 1', out)

    def test_falls_back_to_the_database_label(self):
        out = self.collect({("Overmap", "2"): None}, 1000.0)
        self.assertIn('dune_partition_info{map="Overmap",partition="2",name="Overland"} 1', out)

    def test_keeps_the_last_known_name_when_the_lookup_fails(self):
        self.collect({("Survival_1", "1"): "Sietch Example"}, 1000.0)
        out = self.collect(None, 2000.0)
        self.assertIn('name="Sietch Example"', out)
        self.assertIn("dune_api_up 1", out)

    def test_looks_names_up_at_most_once_a_minute(self):
        self.collect({("Survival_1", "1"): "First"}, 1000.0)
        self.assertIn('name="First"', self.collect({("Survival_1", "1"): "Second"}, 1030.0))
        self.assertIn('name="Second"', self.collect({("Survival_1", "1"): "Second"}, 1061.0))

    def test_existing_series_keep_their_labels(self):
        out = self.collect({("Survival_1", "1"): "Sietch Example"}, 1000.0)
        self.assertIn('dune_partition_ready{map="Survival_1",partition="1",label="OldOne"} 1', out)


if __name__ == "__main__":
    unittest.main()
