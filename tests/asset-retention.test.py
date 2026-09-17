"""Offline regression cases; invented fixtures are not live scoring proof."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess

spec = importlib.util.spec_from_file_location("census", Path(__file__).resolve().parents[1] / "lib/pi-packet/asset-census.py")
census = importlib.util.module_from_spec(spec)
spec.loader.exec_module(census)


class RetentionTest(unittest.TestCase):
    def test_retention_command_exists(self):
        self.assertTrue(hasattr(census, "cmd_retention"), "missing advisory retention command")

    def test_metadata_only_and_no_symlinks(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            root = home / ".local/state/pi-issues"
            root.mkdir(parents=True)
            item = root / "fleet-ops-7438.out"
            item.write_text("DO NOT READ CONTENT")
            (root / "linked.out").symlink_to(item)
            (root / "unknown.db").write_text("excluded")
            classes = census.retention_classes(home, 2000000000)
            row = next(c for c in classes if c["class"] == "issue-outputs")
            self.assertEqual(row["count"], 1)
            self.assertEqual(row["bytes"], item.stat().st_size)
            self.assertIsNone(row["last_read"])
            self.assertIn(str(item), row["record_paths"])
            self.assertNotIn("DO NOT READ CONTENT", json.dumps(classes))
            self.assertEqual(item.read_text(), "DO NOT READ CONTENT")

    def test_rollback_does_not_call_helper(self):
        with patch.dict(os.environ, {"FLEET_RETENTION_ENABLED": "0"}), patch.object(census.subprocess, "run") as run:
            self.assertEqual(census.main(["retention-report"]), 0)
            run.assert_not_called()

    def test_end_to_end_report_and_failure_no_overwrite(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {"HOME": tmp, "FLEET_RETENTION_ENABLED": "1"}):
            home = Path(tmp)
            for directory, names in {"pi-issues": ["record.in", "record.out", "record.err"], "pi-packet": ["watch.log", "watch.log.1"]}.items():
                root = home / ".local/state" / directory
                root.mkdir(parents=True)
                for name in names:
                    (root / name).write_text("fixture")
            output = home / "report.json"
            response = {"answers": {"value": {"score": 3}, "action": {"choice": "keep"}}}
            with patch.object(census.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps(response), "")) as run:
                self.assertEqual(census.main(["retention-report", "--output-json", str(output)]), 0)
                self.assertEqual(run.call_count, 5)
                for call in run.call_args_list:
                    self.assertEqual(call.args[0][-2:], ["--cap-usd", "1"])
                    payload = json.loads(call.kwargs["input"])
                    self.assertEqual(len(payload["questions"]["value"]["criteria"]), 5)
                    self.assertIn("per_file_consumers", payload["state"]["class"]["refs"])
            report = json.loads(output.read_text())
            self.assertEqual(report["proposed_drop_gb"], 0)
            self.assertEqual(report["deleted_bytes"], 0)
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            before = output.read_bytes()
            with patch.object(census.subprocess, "run", return_value=subprocess.CompletedProcess([], 3, "", "cap")):
                self.assertEqual(census.main(["retention-report", "--output-json", str(output)]), 2)
            self.assertEqual(output.read_bytes(), before)

    def test_missing_roots_report_unknown(self):
        with tempfile.TemporaryDirectory() as tmp:
            rows = census.retention_classes(Path(tmp), 2000000000)
            self.assertTrue(all(r["errors"] and r["count"] == 0 for r in rows))

    def test_malformed_score_rejected(self):
        for score in [float("nan"), -1, 5, True, "2"]:
            with self.subTest(score=score), self.assertRaises(ValueError):
                census.retention_verdict({"value": {"score": score}, "action": {"choice": "keep"}})
        self.assertEqual(census.retention_verdict({"value": {"score": 2.5}, "action": {"choice": "review-drop"}}), (2.5, "review-drop"))


if __name__ == "__main__":
    unittest.main()
