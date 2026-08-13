#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import hashlib
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "ci" / "collect-built-packages.sh"


class CollectBuiltPackagesTests(unittest.TestCase):
    def make_package(self, root: Path, name: str, version: str = "1.0-1") -> None:
        content = root / f"content-{name}"
        content.mkdir()
        (content / ".PKGINFO").write_text(
            "\n".join(
                [
                    f"pkgname = {name}",
                    f"pkgbase = {name}",
                    f"pkgver = {version}",
                    "pkgdesc = artifact layout test",
                    "url = https://example.invalid",
                    "builddate = 1",
                    "packager = Test Runner",
                    "size = 0",
                    "arch = any",
                    "license = MIT",
                    "",
                ]
            ),
            encoding="utf-8",
        )

        bundle = root / "downloads" / f"built-{name}" / "packages"
        bundle.mkdir(parents=True)
        archive_name = f"{name}-{version}-any.pkg.tar.zst"
        archive = bundle / archive_name
        subprocess.run(
            ["bsdtar", "--zstd", "-cf", str(archive), ".PKGINFO"],
            cwd=content,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        (bundle / "package-manifest.sha256").write_text(
            f"{digest}  {archive_name}\n", encoding="utf-8"
        )

        policy = root / "policies" / f"policy-{name}"
        policy.mkdir(parents=True)
        (policy / "expected-packages.tsv").write_text(
            "\n".join(
                [
                    f"file\t{archive_name}",
                    f"required\t{name}\t{version}",
                    f"optional\t{name}-debug\t{version}",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        (policy / "published-versions.tsv").write_text(
            f"{name}\t{version.removesuffix('-1')}\n", encoding="utf-8"
        )

    def collect(self, package_names: list[str]) -> tuple[set[str], list[str]]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for package_name in package_names:
                self.make_package(root, package_name)
            combined = root / "combined"
            expected = root / "expected.tsv"
            versions = root / "versions.tsv"
            subprocess.run(
                [
                    "bash",
                    str(TOOL),
                    str(root / "downloads"),
                    str(root / "policies"),
                    str(combined),
                    str(expected),
                    str(versions),
                ],
                cwd=ROOT,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            files = {path.name for path in combined.iterdir()}
            version_rows = versions.read_text(encoding="utf-8").splitlines()
            return files, version_rows

    def test_collects_one_flattened_download(self) -> None:
        files, versions = self.collect(["alpha"])
        self.assertEqual(
            files,
            {"alpha-1.0-1-any.pkg.tar.zst", "package-manifest.sha256"},
        )
        self.assertEqual(versions, ["alpha\t1.0"])

    def test_collects_multiple_merged_downloads(self) -> None:
        files, versions = self.collect(["alpha", "beta"])
        self.assertEqual(
            files,
            {
                "alpha-1.0-1-any.pkg.tar.zst",
                "beta-1.0-1-any.pkg.tar.zst",
                "package-manifest.sha256",
            },
        )
        self.assertEqual(versions, ["alpha\t1.0", "beta\t1.0"])


if __name__ == "__main__":
    unittest.main()
