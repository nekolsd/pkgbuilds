#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "ci" / "recipe-ir.py"


BASE = """\
pkgname=protonplus
pkgver=1.0.0
pkgrel=2
depends=('gtk4')
source=("$pkgname-$pkgver.tar.gz::https://vendor.example/releases/v$pkgver.tar.gz")
sha256sums=('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
build() {
  true
}
"""


class RecipeIRTests(unittest.TestCase):
    def compare(self, old: str, new: str, package: str = "protonplus") -> dict[str, object]:
        with tempfile.TemporaryDirectory() as directory:
            old_path = Path(directory) / "old"
            new_path = Path(directory) / "new"
            old_path.write_text(old, encoding="utf-8")
            new_path.write_text(new, encoding="utf-8")
            result = subprocess.run(
                [
                    os.environ.get("PYTHON", "python3"),
                    str(TOOL),
                    "compare",
                    package,
                    str(old_path),
                    str(new_path),
                    "--format",
                    "json",
                ],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )
            return json.loads(result.stdout)

    def test_release_and_remote_checksum_are_safe(self) -> None:
        new = BASE.replace("pkgver=1.0.0", "pkgver=1.1.0").replace(
            "pkgrel=2", "pkgrel=1"
        ).replace("a" * 64, "b" * 64)
        self.assertEqual(self.compare(BASE, new)["classification"], "release-only")

    def test_dependency_change_requires_review(self) -> None:
        new = BASE.replace("pkgver=1.0.0", "pkgver=1.1.0").replace(
            "'gtk4'", "'gtk4' 'sdl3'"
        ).replace("a" * 64, "b" * 64)
        self.assertEqual(self.compare(BASE, new)["classification"], "review")

    def test_source_template_change_requires_review(self) -> None:
        new = BASE.replace("pkgver=1.0.0", "pkgver=1.1.0").replace(
            "vendor.example", "mirror.example"
        ).replace("a" * 64, "b" * 64)
        self.assertEqual(self.compare(BASE, new)["classification"], "review")

    def test_checksum_only_change_requires_review(self) -> None:
        new = BASE.replace("a" * 64, "b" * 64)
        self.assertEqual(self.compare(BASE, new)["classification"], "review")

    def test_local_file_checksum_is_not_masked(self) -> None:
        old = """\
pkgname=vicinae-bin
pkgver=1.0.0
pkgrel=1
source=("app-$pkgver.tar.gz::https://vendor.example/app.tar.gz" 'vicinae.hook')
sha256sums=('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc')
"""
        new = old.replace("pkgver=1.0.0", "pkgver=1.1.0").replace(
            "a" * 64, "b" * 64
        ).replace("c" * 64, "d" * 64)
        self.assertEqual(
            self.compare(old, new, package="vicinae-bin")["classification"],
            "review",
        )

    def test_bad_checksum_is_unknown(self) -> None:
        new = BASE.replace("pkgver=1.0.0", "pkgver=1.1.0").replace("a" * 64, "abc")
        self.assertEqual(self.compare(BASE, new)["classification"], "unknown")

    def test_dynamic_version_is_unknown(self) -> None:
        new = BASE.replace("pkgver=1.0.0", "pkgver=$(curl https://example.invalid)")
        self.assertEqual(self.compare(BASE, new)["classification"], "unknown")

    def test_comment_only_change_is_metadata_only(self) -> None:
        new = "# new comment\n" + BASE
        self.assertEqual(self.compare(BASE, new)["classification"], "metadata-only")


if __name__ == "__main__":
    unittest.main()
