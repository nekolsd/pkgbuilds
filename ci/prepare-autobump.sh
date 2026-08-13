#!/usr/bin/env bash
# Apply one official version bump and classify its exact change through parsed
# Bash IR. Non-release changes remain visible only in a manually reviewed Draft.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE=${1:?usage: ci/prepare-autobump.sh <package> <version> <output-directory>}
VERSION=${2:?usage: ci/prepare-autobump.sh <package> <version> <output-directory>}
OUTPUT_DIR=${3:?usage: ci/prepare-autobump.sh <package> <version> <output-directory>}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
[[ $PACKAGE =~ ^[[:alnum:]@._+-]+$ ]] || die "unsafe package name: $PACKAGE"
[[ $VERSION =~ ^[[:alnum:]][[:alnum:].+_]*$ ]] || die "unsafe vendor version: $VERSION"
[ -f "$ROOT/$PACKAGE/PKGBUILD" ] || die "package has no PKGBUILD: $PACKAGE"
mkdir -p "$OUTPUT_DIR"
cp -p "$ROOT/$PACKAGE/PKGBUILD" "$OUTPUT_DIR/old.PKGBUILD"

"$ROOT/build.sh" --prepare-one "$PACKAGE" "$VERSION"

mapfile -d '' -t changed < <(git -C "$ROOT" diff --name-only -z --)
[ ${#changed[@]} -eq 1 ] && [ "${changed[0]}" = "$PACKAGE/PKGBUILD" ] \
  || die "$PACKAGE: updater changed paths outside its PKGBUILD"

python3 "$ROOT/ci/recipe-ir.py" compare "$PACKAGE" \
  "$OUTPUT_DIR/old.PKGBUILD" "$ROOT/$PACKAGE/PKGBUILD" --format json \
  > "$OUTPUT_DIR/classification.json"
classification=$(python3 - "$OUTPUT_DIR/classification.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    print(json.load(stream)["classification"])
PY
)
case "$classification" in
  release-only) ;;
  review|unknown)
    printf 'warning: %s requires manual contract review (%s)\n' \
      "$PACKAGE" "$classification" >&2
    ;;
  *) die "$PACKAGE: unexpected parsed update classification: $classification" ;;
esac

git -C "$ROOT" diff --check -- "$PACKAGE/PKGBUILD"
git -C "$ROOT" diff --stat -- "$PACKAGE/PKGBUILD" > "$OUTPUT_DIR/diffstat.txt"
printf 'prepared and IR-classified %s %s as %s\n' "$PACKAGE" "$VERSION" "$classification"
