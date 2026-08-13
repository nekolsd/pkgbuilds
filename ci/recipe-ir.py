#!/usr/bin/env python3
"""Conservatively compare PKGBUILDs through shfmt's Bash syntax tree.

The comparator never evaluates shell.  It masks only the release fields and
remote checksum slots declared in update-policy.json, then compares the rest of
the parsed IR.  Anything unsupported is reported as unknown and therefore needs
human review.
"""

from __future__ import annotations

import argparse
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_POLICY = ROOT / "update-policy.json"
POSITION_KEYS = {"Offset", "Line", "Col"}
CHECKSUM_LENGTHS = {
    "md5sums": 32,
    "sha1sums": 40,
    "sha224sums": 56,
    "sha256sums": 64,
    "sha384sums": 96,
    "sha512sums": 128,
    "b2sums": 128,
}


class UnknownIR(ValueError):
    """The input is valid shell but outside the deliberately small policy."""


def load_policy(path: Path) -> dict[str, dict[str, Any]]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"could not read update policy {path}: {error}") from error
    if raw.get("schema") != 1 or not isinstance(raw.get("packages"), dict):
        raise SystemExit(f"unsupported update policy schema in {path}")

    packages: dict[str, dict[str, Any]] = raw["packages"]
    for package, rule in packages.items():
        if not re.fullmatch(r"[a-z0-9][a-z0-9@._+-]*", package):
            raise SystemExit(f"invalid package name in update policy: {package}")
        if not isinstance(rule, dict):
            raise SystemExit(f"{package}: update policy must be an object")
        version_fields = rule.get("version_fields")
        release_fields = rule.get("release_fields")
        checksums = rule.get("remote_checksums", {})
        if not isinstance(rule.get("automerge"), bool):
            raise SystemExit(f"{package}: automerge must be true or false")
        if not isinstance(version_fields, list) or not version_fields:
            raise SystemExit(f"{package}: version_fields must be a non-empty list")
        if not isinstance(release_fields, list) or not release_fields:
            raise SystemExit(f"{package}: release_fields must be a non-empty list")
        if not set(version_fields).issubset(release_fields):
            raise SystemExit(f"{package}: version_fields must be included in release_fields")
        for field in [*version_fields, *release_fields]:
            if not isinstance(field, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", field):
                raise SystemExit(f"{package}: invalid release field: {field!r}")
        if len(set(release_fields)) != len(release_fields):
            raise SystemExit(f"{package}: duplicate release field")
        if not isinstance(checksums, dict):
            raise SystemExit(f"{package}: remote_checksums must be an object")
        for variable, indices in checksums.items():
            base = re.sub(r"_[A-Za-z0-9_]+$", "", variable)
            if base not in CHECKSUM_LENGTHS:
                raise SystemExit(f"{package}: unsupported checksum variable: {variable}")
            if (
                not isinstance(indices, list)
                or not indices
                or any(not isinstance(index, int) or isinstance(index, bool) or index < 0 for index in indices)
                or len(set(indices)) != len(indices)
            ):
                raise SystemExit(f"{package}: invalid checksum indices for {variable}")
    return packages


def parse_shell(path: Path) -> dict[str, Any]:
    shfmt = os.environ.get("SHFMT", "shfmt")
    try:
        source = path.read_bytes()
    except OSError as error:
        raise UnknownIR(f"cannot read {path}: {error}") from error
    try:
        result = subprocess.run(
            [shfmt, "-ln=bash", "--to-json"],
            input=source,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as error:
        raise SystemExit(f"could not execute the required Bash parser {shfmt!r}: {error}") from error
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise UnknownIR(f"Bash parser rejected {path}: {detail}")
    try:
        tree = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise UnknownIR(f"Bash parser returned malformed JSON for {path}") from error
    if tree.get("Type") != "File":
        raise UnknownIR(f"Bash parser returned an unexpected root for {path}")
    return tree


def is_position(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and set(value) == POSITION_KEYS
        and all(isinstance(value[key], int) for key in POSITION_KEYS)
    )


def canonical(value: Any) -> Any:
    """Drop source positions and comments, while retaining executable syntax."""
    if isinstance(value, list):
        return [canonical(item) for item in value]
    if not isinstance(value, dict):
        return value
    normalized: dict[str, Any] = {}
    for key, item in value.items():
        if key == "Comments" or is_position(item):
            continue
        normalized[key] = canonical(item)
    return normalized


def top_assignments(tree: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    assignments: dict[str, list[dict[str, Any]]] = {}
    for statement in tree.get("Stmts", []):
        command = statement.get("Cmd", {})
        if command.get("Type") != "CallExpr":
            continue
        for assignment in command.get("Assigns", []):
            name = assignment.get("Name", {}).get("Value")
            if isinstance(name, str):
                assignments.setdefault(name, []).append(
                    {"assignment": assignment, "command": command}
                )
    return assignments


def one_assignment(
    assignments: dict[str, list[dict[str, Any]]], name: str
) -> dict[str, Any]:
    occurrences = assignments.get(name, [])
    if len(occurrences) != 1:
        raise UnknownIR(f"{name} must have exactly one top-level assignment")
    occurrence = occurrences[0]
    command = occurrence["command"]
    if command.get("Args") or command.get("Redirs"):
        raise UnknownIR(f"{name} is attached to a command instead of a plain assignment")
    assignment = occurrence["assignment"]
    if assignment.get("Append") or assignment.get("Naked"):
        raise UnknownIR(f"{name} uses an unsupported assignment form")
    return assignment


def simple_word(word: Any) -> str | None:
    if not isinstance(word, dict):
        return None
    parts = word.get("Parts")
    if not isinstance(parts, list) or len(parts) != 1:
        return None
    part = parts[0]
    if not isinstance(part, dict):
        return None
    kind = part.get("Type")
    if kind in {"Lit", "SglQuoted"} and isinstance(part.get("Value"), str):
        return part["Value"]
    if kind == "DblQuoted":
        quoted = part.get("Parts", [])
        if all(item.get("Type") == "Lit" and isinstance(item.get("Value"), str) for item in quoted):
            return "".join(item["Value"] for item in quoted)
    return None


def scalar_value(assignment: dict[str, Any], name: str) -> str:
    if "Array" in assignment or "Value" not in assignment:
        raise UnknownIR(f"{name} must be a simple scalar assignment")
    value = simple_word(assignment["Value"])
    if value is None or not value or not re.fullmatch(r"[A-Za-z0-9.+_-]+", value):
        raise UnknownIR(f"{name} must contain one static release token")
    return value


def checksum_value(variable: str, element: dict[str, Any]) -> str:
    if element.get("Index") is not None:
        raise UnknownIR(f"{variable} uses an associative array index")
    value = simple_word(element.get("Value"))
    if value is None:
        raise UnknownIR(f"{variable} contains a dynamic checksum")
    base = re.sub(r"_[A-Za-z0-9_]+$", "", variable)
    length = CHECKSUM_LENGTHS[base]
    if value == "SKIP":
        return value
    if not re.fullmatch(rf"[0-9a-fA-F]{{{length}}}", value):
        raise UnknownIR(f"{variable} contains a checksum with the wrong format")
    return value.lower()


def assignment_changes(old_tree: dict[str, Any], new_tree: dict[str, Any]) -> list[str]:
    old = top_assignments(old_tree)
    new = top_assignments(new_tree)
    changed: list[str] = []
    for name in sorted(set(old) | set(new)):
        old_nodes = [canonical(item["assignment"]) for item in old.get(name, [])]
        new_nodes = [canonical(item["assignment"]) for item in new.get(name, [])]
        if old_nodes != new_nodes:
            changed.append(name)
    return changed


def compare_trees(
    package: str,
    old_tree: dict[str, Any],
    new_tree: dict[str, Any],
    rule: dict[str, Any],
) -> dict[str, Any]:
    if canonical(old_tree) == canonical(new_tree):
        return {
            "package": package,
            "classification": "metadata-only",
            "safe": True,
            "changed_version_fields": [],
            "reason": "parsed shell IR is unchanged after ignoring comments and positions",
        }

    old_assignments = top_assignments(old_tree)
    new_assignments = top_assignments(new_tree)
    version_changes: list[str] = []
    for name in rule["version_fields"]:
        old_value = scalar_value(one_assignment(old_assignments, name), name)
        new_value = scalar_value(one_assignment(new_assignments, name), name)
        if old_value != new_value:
            version_changes.append(name)
    if not version_changes:
        changed = assignment_changes(old_tree, new_tree)
        detail = f" changed assignments: {', '.join(changed)}" if changed else ""
        return {
            "package": package,
            "classification": "review",
            "safe": False,
            "changed_version_fields": [],
            "reason": "shell IR changed without a configured version change;" + detail,
        }

    old_masked = copy.deepcopy(old_tree)
    new_masked = copy.deepcopy(new_tree)
    old_masked_assignments = top_assignments(old_masked)
    new_masked_assignments = top_assignments(new_masked)

    for name in rule["release_fields"]:
        old_assignment = one_assignment(old_masked_assignments, name)
        new_assignment = one_assignment(new_masked_assignments, name)
        scalar_value(old_assignment, name)
        scalar_value(new_assignment, name)
        old_assignment["Value"] = {"Type": "MaskedReleaseValue", "Name": name}
        new_assignment["Value"] = {"Type": "MaskedReleaseValue", "Name": name}

    for variable, indices in rule.get("remote_checksums", {}).items():
        old_assignment = one_assignment(old_masked_assignments, variable)
        new_assignment = one_assignment(new_masked_assignments, variable)
        old_elements = old_assignment.get("Array", {}).get("Elems")
        new_elements = new_assignment.get("Array", {}).get("Elems")
        if not isinstance(old_elements, list) or not isinstance(new_elements, list):
            raise UnknownIR(f"{variable} must be an indexed array")
        for index in indices:
            if index >= len(old_elements) or index >= len(new_elements):
                raise UnknownIR(f"{variable}[{index}] is missing")
            old_value = checksum_value(variable, old_elements[index])
            new_value = checksum_value(variable, new_elements[index])
            if (old_value == "SKIP") != (new_value == "SKIP"):
                raise UnknownIR(f"{variable}[{index}] changed to or from SKIP")
            old_elements[index]["Value"] = {
                "Type": "MaskedRemoteChecksum",
                "Variable": variable,
                "Index": index,
            }
            new_elements[index]["Value"] = {
                "Type": "MaskedRemoteChecksum",
                "Variable": variable,
                "Index": index,
            }

    if canonical(old_masked) == canonical(new_masked):
        return {
            "package": package,
            "classification": "release-only",
            "safe": True,
            "changed_version_fields": version_changes,
            "reason": "only declared release fields and remote checksum slots changed",
        }

    changed = assignment_changes(old_masked, new_masked)
    detail = f" changed assignments: {', '.join(changed)}" if changed else " functions or other statements changed"
    return {
        "package": package,
        "classification": "review",
        "safe": False,
        "changed_version_fields": version_changes,
        "reason": "normalized shell IR still differs;" + detail,
    }


def compare_files(
    package: str, old_path: Path, new_path: Path, policies: dict[str, dict[str, Any]]
) -> dict[str, Any]:
    if package not in policies:
        return {
            "package": package,
            "classification": "unknown",
            "safe": False,
            "changed_version_fields": [],
            "reason": "package has no update policy",
        }
    try:
        return compare_trees(package, parse_shell(old_path), parse_shell(new_path), policies[package])
    except UnknownIR as error:
        return {
            "package": package,
            "classification": "unknown",
            "safe": False,
            "changed_version_fields": [],
            "reason": str(error),
        }


def validate_current(policies: dict[str, dict[str, Any]]) -> None:
    package_dirs = {
        path.parent.name
        for path in ROOT.glob("*/PKGBUILD")
        if path.is_file()
    }
    configured = set(policies)
    missing = sorted(package_dirs - configured)
    stale = sorted(configured - package_dirs)
    if missing or stale:
        parts = []
        if missing:
            parts.append("missing policies: " + ", ".join(missing))
        if stale:
            parts.append("stale policies: " + ", ".join(stale))
        raise SystemExit("; ".join(parts))

    for package in sorted(package_dirs):
        tree = parse_shell(ROOT / package / "PKGBUILD")
        assignments = top_assignments(tree)
        rule = policies[package]
        for name in rule["release_fields"]:
            scalar_value(one_assignment(assignments, name), name)
        for variable, indices in rule.get("remote_checksums", {}).items():
            assignment = one_assignment(assignments, variable)
            elements = assignment.get("Array", {}).get("Elems")
            if not isinstance(elements, list):
                raise UnknownIR(f"{package}: {variable} must be an indexed array")
            for index in indices:
                if index >= len(elements):
                    raise UnknownIR(f"{package}: {variable}[{index}] is missing")
                checksum_value(variable, elements[index])
    print(f"validated {len(package_dirs)} PKGBUILD update policies")


def render_result(result: dict[str, Any], output_format: str) -> None:
    if output_format == "json":
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    elif output_format == "tsv":
        reason = result["reason"].replace("\t", " ").replace("\n", " ")
        print(f"{result['classification']}\t{str(result['safe']).lower()}\t{reason}")
    else:
        print(f"{result['package']}: {result['classification']}: {result['reason']}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    subparsers = parser.add_subparsers(dest="command", required=True)

    compare_parser = subparsers.add_parser("compare", help="compare two PKGBUILD files")
    compare_parser.add_argument("package")
    compare_parser.add_argument("old", type=Path)
    compare_parser.add_argument("new", type=Path)
    compare_parser.add_argument("--format", choices=("human", "json", "tsv"), default="human")

    subparsers.add_parser("validate", help="validate every current PKGBUILD policy")
    args = parser.parse_args()
    policies = load_policy(args.policy)
    if args.command == "validate":
        try:
            validate_current(policies)
        except UnknownIR as error:
            raise SystemExit(f"update policy validation failed: {error}") from error
        return
    result = compare_files(args.package, args.old, args.new, policies)
    render_result(result, args.format)


if __name__ == "__main__":
    main()
