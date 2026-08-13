#!/usr/bin/env bash
# Select immutable local recipes for a build. Vendor version discovery and recipe
# mutation happen in autobump.yml; this script never changes a PKGBUILD.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR=${1:?usage: ci/prepare.sh <output-directory>}
PACKAGES_FILE="$OUTPUT_DIR/packages.txt"
MATRIX_FILE="$OUTPUT_DIR/matrix.json"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

valid_package() {
  [[ $1 =~ ^[[:alnum:]@._+-]+$ ]]
}

mkdir -p "$OUTPUT_DIR"
: > "$PACKAGES_FILE"
cd "$ROOT"

event_name=${EVENT_NAME:-workflow_dispatch}
current_sha=${CURRENT_SHA:-${GITHUB_SHA:-HEAD}}
base_sha=${BASE_SHA:-${BEFORE_SHA:-}}
force_packages=${FORCE_PACKAGES:-}
declare -a packages=()
declare -A seen=()

add_package() {
  local package=$1
  valid_package "$package" || die "unsafe package name: $package"
  [ -f "$package/PKGBUILD" ] || die "package has no PKGBUILD: $package"
  [ -z "${seen[$package]+present}" ] || return 0
  seen["$package"]=1
  packages+=("$package")
}

if [ -n "$force_packages" ]; then
  read -r -a requested_packages <<< "$force_packages"
  [ ${#requested_packages[@]} -gt 0 ] || die "forced package list is empty"
  for package in "${requested_packages[@]}"; do
    add_package "$package"
  done
  printf 'manual package rebuild selected: %s\n' "${packages[*]}"
elif [ "$event_name" = push ] || [ "$event_name" = pull_request ]; then
  if [ -n "$base_sha" ] \
     && [[ ! $base_sha =~ ^0+$ ]] \
     && git cat-file -e "${base_sha}^{commit}" 2>/dev/null; then
    diff_command=(git diff --name-only -z "$base_sha" "$current_sha" --)
  else
    diff_command=(git diff-tree --root --no-commit-id --name-only -r -z "$current_sha" --)
  fi

  while IFS= read -r -d '' path; do
    [[ $path == */* ]] || continue
    package=${path%%/*}
    valid_package "$package" || die "unsafe package directory in git diff: $package"
    [ -f "$package/PKGBUILD" ] || continue
    add_package "$package"
  done < <("${diff_command[@]}")
elif [ "$event_name" = workflow_dispatch ]; then
  # With no explicit input, retry vendor versions that are present in main but
  # whose successful-publication baseline has not advanced yet.
  while IFS=$'\t' read -r package published_version; do
    [ -f "$package/PKGBUILD" ] || continue
    if ! local_version=$(cd "$package" && CARCH=x86_64; source ./PKGBUILD >/dev/null 2>&1; printf '%s' "$pkgver"); then
      die "$package: could not read local pkgver"
    fi
    if [ "$local_version" != "$published_version" ]; then
      add_package "$package"
    fi
  done < <(python3 - "$ROOT/nvchecker-old.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)["data"]
for package in sorted(data):
    print(f"{package}\t{data[package]['version']}")
PY
  )
else
  die "unsupported build event: $event_name"
fi

if [ ${#packages[@]} -gt 0 ]; then
  printf '%s\n' "${packages[@]}" | LC_ALL=C sort -u > "$PACKAGES_FILE"
fi

python3 - "$PACKAGES_FILE" "$MATRIX_FILE" <<'PY'
import json
import sys
packages_path, matrix_path = sys.argv[1:]
with open(packages_path, encoding="utf-8") as stream:
    packages = [line.strip() for line in stream if line.strip()]
with open(matrix_path, "w", encoding="utf-8") as stream:
    json.dump({"include": [{"package": package} for package in packages]}, stream)
    stream.write("\n")
PY

printf 'selected %s independent package build(s)\n' "$(wc -l < "$PACKAGES_FILE")"
