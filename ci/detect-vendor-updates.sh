#!/usr/bin/env bash
# Query only configured official vendor sources and split results into new recipe
# bumps versus already-merged versions whose publication needs retrying.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR=${1:?usage: ci/detect-vendor-updates.sh <output-directory> [packages]}
FILTER=${2:-}
BUMPS_FILE="$OUTPUT_DIR/bumps.tsv"
PENDING_FILE="$OUTPUT_DIR/pending.txt"
MATRIX_FILE="$OUTPUT_DIR/matrix.json"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
mkdir -p "$OUTPUT_DIR"
: > "$BUMPS_FILE"
: > "$PENDING_FILE"
cd "$ROOT"

declare -A requested=()
if [ -n "$FILTER" ]; then
  read -r -a names <<< "$FILTER"
  for package in "${names[@]}"; do
    [[ $package =~ ^[[:alnum:]@._+-]+$ ]] || die "unsafe requested package: $package"
    [ -f "$package/PKGBUILD" ] || die "requested package has no PKGBUILD: $package"
    python3 - "$ROOT/nvchecker.toml" "$package" <<'PY'
import sys
import tomllib
with open(sys.argv[1], "rb") as stream:
    config = tomllib.load(stream)
if sys.argv[2] not in config:
    raise SystemExit(f"package has no official vendor checker: {sys.argv[2]}")
PY
    requested["$package"]=1
  done
fi

# nvchecker reports endpoint failures but, without --failures, still writes all
# successful results. A broken vendor endpoint therefore cannot hide other bumps.
nvchecker -c nvchecker.toml
nvcmp -c nvchecker.toml -j -n > "$OUTPUT_DIR/outdated.json"
python3 - "$OUTPUT_DIR/outdated.json" <<'PY' > "$OUTPUT_DIR/outdated.tsv"
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    rows = json.load(stream)
for row in rows:
    print(f"{row['name']}\t{row['oldver']}\t{row['newver']}")
PY

while IFS=$'\t' read -r package old_version new_version; do
  [ -n "$package" ] || continue
  [[ $package =~ ^[[:alnum:]@._+-]+$ ]] || die "nvchecker returned an unsafe package name"
  [[ $new_version =~ ^[[:alnum:]][[:alnum:].+_]*$ ]] || die "$package: unsafe vendor version"
  if [ ${#requested[@]} -gt 0 ] && [ -z "${requested[$package]+present}" ]; then
    continue
  fi
  [ -f "$package/PKGBUILD" ] || die "$package: configured vendor source has no local PKGBUILD"
  if ! local_version=$(cd "$package" && CARCH=x86_64; source ./PKGBUILD >/dev/null 2>&1; printf '%s' "$pkgver"); then
    die "$package: could not read local pkgver"
  fi
  comparison=$(vercmp "$local_version" "$new_version")
  if [ "$comparison" -eq 0 ]; then
    printf '%s\n' "$package" >> "$PENDING_FILE"
  elif [ "$comparison" -lt 0 ]; then
    printf '%s\t%s\t%s\t%s\n' \
      "$package" "$local_version" "$new_version" "$old_version" >> "$BUMPS_FILE"
  else
    printf 'warning: %s local version %s is newer than vendor result %s; refusing to downgrade\n' \
      "$package" "$local_version" "$new_version" >&2
  fi
done < "$OUTPUT_DIR/outdated.tsv"

LC_ALL=C sort -u -o "$PENDING_FILE" "$PENDING_FILE"
python3 - "$BUMPS_FILE" "$MATRIX_FILE" <<'PY'
import json
import sys
bumps_path, matrix_path = sys.argv[1:]
include = []
with open(bumps_path, encoding="utf-8") as stream:
    for line in stream:
        package, local, vendor, published = line.rstrip("\n").split("\t")
        include.append({
            "package": package,
            "local_version": local,
            "vendor_version": vendor,
            "published_version": published,
        })
with open(matrix_path, "w", encoding="utf-8") as stream:
    json.dump({"include": include}, stream, separators=(",", ":"))
    stream.write("\n")
PY

printf 'detected %s autobump(s) and %s publication retry candidate(s)\n' \
  "$(wc -l < "$BUMPS_FILE")" "$(wc -l < "$PENDING_FILE")"
