#!/usr/bin/env python3
"""Offline fixtures exercise review decisions and the bounded live collector."""

import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

SCRIPT_DIR = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("gate", SCRIPT_DIR / "verify-coderabbit-review.py")
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


class ReviewGateTests(unittest.TestCase):
    def test_evidence_fixtures(self):
        for path in sorted((SCRIPT_DIR / "fixtures/coderabbit-review").glob("*.json")):
            with self.subTest(fixture=path.name):
                fixture = json.loads(path.read_text())
                result, message = gate.evaluate(fixture["snapshot"])
                self.assertEqual(result, fixture["expected"], message)

    def test_bounded_wait_rejects_missing_evidence(self):
        def api(path):
            return {"head": {"sha": "a" * 40}} if path.startswith("pulls/7") and "/reviews" not in path else []

        with patch.dict(gate.os.environ, {"SHA": "a" * 40, "PR_NUMBER": "7"}), \
                patch.object(gate, "api", side_effect=api), \
                patch.object(gate.time, "sleep") as sleep, \
                patch("builtins.print") as output:
            self.assertEqual(gate.live(), 1)
            self.assertEqual(sleep.call_count, 11)
            self.assertIn("bounded wait", output.call_args.args[0])
            self.assertTrue(all(call.args == (30,) for call in sleep.call_args_list))

    def test_pagination_retains_all_records(self):
        class Response:
            def __init__(self, payload, link=""):
                self.payload = json.dumps(payload)
                self.headers = {"Link": link}

            def read(self):
                return self.payload

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

        responses = [
            Response({"check_runs": [{"id": 1}]}, '<https://api.github.com/page2>; rel="next"'),
            Response({"check_runs": [{"id": 2}]}),
        ]
        with patch.dict(gate.os.environ, {"REPO": "owner/repo", "GH_TOKEN": "fixture-token"}), \
                patch.object(gate.urllib.request, "urlopen", side_effect=responses) as fetch:
            self.assertEqual(gate.api("commits/head/check-runs"), [{"id": 1}, {"id": 2}])
            self.assertEqual(fetch.call_count, 2)


if __name__ == "__main__":
    unittest.main()
