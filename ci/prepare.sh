#!/usr/bin/env bash
# Select packages for this run and, for vendor updates, prepare a reviewable
# recipe patch without executing any downloaded source code.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR=${1:?usage: ci/prepare.sh <output-directory>}
PACKAGES_FILE="$OUTPUT_DIR/packages.txt"
PATCH_FILE="$OUTPUT_DIR/recipe.patch"
EXPECTED_FILE="$OUTPUT_DIR/expected-packages.tsv"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

valid_package() {
  [[ $1 =~ ^[[:alnum:]@._+-]+$ ]]
}

mkdir -p "$OUTPUT_DIR"
: > "$PACKAGES_FILE"
: > "$PATCH_FILE"
: > "$EXPECTED_FILE"
cd "$ROOT"

event_name=${EVENT_NAME:-workflow_dispatch}
current_sha=${CURRENT_SHA:-${GITHUB_SHA:-HEAD}}
force_packages=${FORCE_PACKAGES:-}
declare -a packages=()
declare -A seen=()

if [ -n "$force_packages" ]; then
  read -r -a requested_packages <<< "$force_packages"
  [ ${#requested_packages[@]} -gt 0 ] || die "forced package list is empty"
  for package in "${requested_packages[@]}"; do
    valid_package "$package" || die "unsafe forced package name: $package"
    [ -f "$package/PKGBUILD" ] || die "forced package has no PKGBUILD: $package"
    [ -z "${seen[$package]+present}" ] || die "duplicate forced package: $package"
    seen["$package"]=1
    packages+=("$package")
  done
  printf 'forced package rebuild selected: %s\n' "${packages[*]}"
elif [ "$event_name" = push ]; then
  before_sha=${BEFORE_SHA:-}
  if [ -n "$before_sha" ] \
     && [[ ! $before_sha =~ ^0+$ ]] \
     && git cat-file -e "${before_sha}^{commit}" 2>/dev/null; then
    diff_command=(git diff --name-only -z "$before_sha" "$current_sha" --)
  else
    # New branches and rewritten histories may not have an accessible `before`.
    diff_command=(git diff-tree --root --no-commit-id --name-only -r -z "$current_sha" --)
  fi

  while IFS= read -r -d '' path; do
    [[ $path == */* ]] || continue
    package=${path%%/*}
    valid_package "$package" || die "unsafe package directory in git diff: $package"
    [ -f "$package/PKGBUILD" ] || continue
    [ -z "${seen[$package]+present}" ] || continue
    seen["$package"]=1
    packages+=("$package")
  done < <("${diff_command[@]}")
fi

if [ ${#packages[@]} -gt 0 ]; then
  printf '%s\n' "${packages[@]}" | LC_ALL=C sort -u > "$PACKAGES_FILE"
  printf 'reviewed package changes selected: %s\n' "${packages[*]}"
else
  # Schedules, manual runs, and pushes that only changed CI tooling query vendor
  # endpoints. This command only bumps versions, downloads sources and hashes
  # them; prepare/build/check/package functions are not called.
  "$ROOT/build.sh" --prepare-outdated "$PACKAGES_FILE"

  while IFS= read -r -d '' path; do
    if [ "$path" = nvchecker-old.json ] \
       || [[ $path =~ ^[[:alnum:]@._+-]+/PKGBUILD$ ]]; then
      continue
    fi
    die "preparation unexpectedly changed a disallowed path: $path"
  done < <(git diff --name-only -z --)

  git diff --binary --full-index -- \
    ':(glob)*/PKGBUILD' nvchecker-old.json > "$PATCH_FILE"
fi

while IFS= read -r package || [ -n "$package" ]; do
  [ -n "$package" ] || continue
  valid_package "$package" || die "unsafe package name in output: $package"
  [ -f "$package/PKGBUILD" ] || die "selected package has no PKGBUILD: $package"

  if ! expected_output=$(cd "$package" && makepkg --packagelist); then
    die "$package: could not determine the expected package files"
  fi
  mapfile -t expected_paths <<< "$expected_output"
  [ ${#expected_paths[@]} -gt 0 ] && [ -n "${expected_paths[0]}" ] \
    || die "$package: makepkg predicted no package files"
  for path in "${expected_paths[@]}"; do
    base=${path##*/}
    [[ $base =~ ^[[:alnum:]@._+:-]+\.pkg\.tar\.zst$ ]] \
      || die "$package: unsafe predicted package filename: $base"
    printf 'file\t%s\n' "$base" >> "$EXPECTED_FILE"
  done

  if ! metadata=$(cd "$package" && CARCH=x86_64; source ./PKGBUILD >/dev/null 2>&1
      package_base=${pkgbase:-${pkgname[0]}}
      package_version=${epoch:+$epoch:}$pkgver-$pkgrel
      printf '%s\t%s\n' "$package_base" "$package_version"
      printf '%s\n' "${pkgname[@]}"); then
    die "$package: could not read declared package metadata"
  fi
  IFS=$'\t' read -r package_base package_version <<< "${metadata%%$'\n'*}"
  mapfile -t declared_names <<< "${metadata#*$'\n'}"
  [[ $package_base =~ ^[[:alnum:]@._+-]+$ ]] \
    || die "$package: unsafe package base: $package_base"
  [[ $package_version =~ ^[[:alnum:].+_:-]+$ ]] \
    || die "$package: unsafe package version: $package_version"
  [ ${#declared_names[@]} -gt 0 ] && [ -n "${declared_names[0]}" ] \
    || die "$package: PKGBUILD declares no package names"
  for name in "${declared_names[@]}"; do
    valid_package "$name" || die "$package: unsafe declared package name: $name"
    printf 'required\t%s\t%s\n' "$name" "$package_version" >> "$EXPECTED_FILE"
  done
  printf 'optional\t%s-debug\t%s\n' "$package_base" "$package_version" >> "$EXPECTED_FILE"
done < "$PACKAGES_FILE"

LC_ALL=C sort -u -o "$EXPECTED_FILE" "$EXPECTED_FILE"

printf 'prepared %s package(s), %s artifact policy entries; recipe patch size: %s bytes\n' \
  "$(wc -l < "$PACKAGES_FILE")" "$(wc -l < "$EXPECTED_FILE")" "$(wc -c < "$PATCH_FILE")"
