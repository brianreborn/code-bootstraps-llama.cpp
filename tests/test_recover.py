#!/usr/bin/env python3
"""The reload decision, without a server."""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
from recover import allow_retry, should_reload


class RecoverTest(unittest.TestCase):
    def test_signal_death_reloads(self):
        self.assertTrue(should_reload({"id": "coder", "status": {"value": "unloaded", "failed": True, "exit_code": 1}}))

    def test_clean_stop_stays_down(self):
        self.assertFalse(should_reload({"id": "general", "status": {"value": "unloaded", "failed": False, "exit_code": 0}}))

    def test_loaded_is_left_alone(self):
        self.assertFalse(should_reload({"id": "coder", "status": {"value": "loaded"}}))

    def test_backoff(self):
        deaths = {}
        self.assertTrue(allow_retry(deaths, "coder", 100))
        self.assertTrue(allow_retry(deaths, "coder", 110))
        self.assertTrue(allow_retry(deaths, "coder", 120))
        self.assertFalse(allow_retry(deaths, "coder", 130))


if __name__ == "__main__":
    unittest.main()
