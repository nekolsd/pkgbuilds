#!/usr/bin/env python3
"""Advance nvchecker-old.json only for packages successfully published to R2."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import sys
import tempfile


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: ci/advance-published.py <nvchecker-old.json> <versions.tsv>")
    state_path = Path(sys.argv[1])
    versions_path = Path(sys.argv[2])
    versions: dict[str, str] = {}
    with versions_path.open(encoding="utf-8") as stream:
        for number, line in enumerate(stream, 1):
            fields = line.rstrip("\n").split("\t")
            if len(fields) != 2:
                raise SystemExit(f"{versions_path}:{number}: malformed version record")
            package, version = fields
            if not re.fullmatch(r"[A-Za-z0-9@._+-]+", package):
                raise SystemExit(f"{versions_path}:{number}: unsafe package name")
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.+_]*", version):
                raise SystemExit(f"{versions_path}:{number}: unsafe version")
            if package in versions and versions[package] != version:
                raise SystemExit(f"{versions_path}:{number}: conflicting versions for {package}")
            versions[package] = version
    if not versions:
        raise SystemExit("published version record is empty")

    with state_path.open(encoding="utf-8") as stream:
        state = json.load(stream)
    data = state.get("data")
    if state.get("version") != 2 or not isinstance(data, dict):
        raise SystemExit(f"unsupported nvchecker state: {state_path}")
    for package, version in versions.items():
        if package not in data or not isinstance(data[package], dict):
            raise SystemExit(f"published package is absent from nvchecker state: {package}")
        data[package]["version"] = version

    descriptor, temporary_name = tempfile.mkstemp(prefix=".nvchecker-old.", dir=state_path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(state, stream, indent=2, ensure_ascii=False)
            stream.write("\n")
        os.chmod(temporary, state_path.stat().st_mode & 0o777)
        os.replace(temporary, state_path)
    finally:
        if temporary.exists():
            temporary.unlink()
    print(f"advanced successful-publication state for {len(versions)} package(s)")


if __name__ == "__main__":
    main()
