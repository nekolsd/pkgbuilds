#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "ci" / "advance-published.py"


class AdvancePublishedTests(unittest.TestCase):
    def test_advances_only_named_version_and_preserves_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "old.json"
            versions = Path(directory) / "versions.tsv"
            state.write_text(
                json.dumps(
                    {
                        "version": 2,
                        "data": {
                            "example": {
                                "version": "1.0.0",
                                "url": "https://vendor.example/1.0.0",
                            },
                            "untouched": {"version": "7"},
                        },
                    }
                ),
                encoding="utf-8",
            )
            versions.write_text("example\t1.1.0\n", encoding="utf-8")
            subprocess.run(["python3", str(TOOL), str(state), str(versions)], check=True)
            result = json.loads(state.read_text(encoding="utf-8"))
            self.assertEqual(result["data"]["example"]["version"], "1.1.0")
            self.assertEqual(
                result["data"]["example"]["url"],
                "https://vendor.example/1.0.0",
            )
            self.assertEqual(result["data"]["untouched"]["version"], "7")

    def test_rejects_unknown_package(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "old.json"
            versions = Path(directory) / "versions.tsv"
            state.write_text('{"version": 2, "data": {}}\n', encoding="utf-8")
            versions.write_text("unknown\t1.0\n", encoding="utf-8")
            result = subprocess.run(
                ["python3", str(TOOL), str(state), str(versions)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("absent from nvchecker state", result.stderr)


if __name__ == "__main__":
    unittest.main()
