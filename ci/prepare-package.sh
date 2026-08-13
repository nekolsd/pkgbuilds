#!/usr/bin/env bash
# Derive the expected artifacts for exactly one recipe. This runs without any
# publishing or repository-write credential.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE=${1:?usage: ci/prepare-package.sh <package> <output-directory>}
OUTPUT_DIR=${2:?usage: ci/prepare-package.sh <package> <output-directory>}
PACKAGES_FILE="$OUTPUT_DIR/packages.txt"
EXPECTED_FILE="$OUTPUT_DIR/expected-packages.tsv"
VERSIONS_FILE="$OUTPUT_DIR/published-versions.tsv"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
[[ $PACKAGE =~ ^[[:alnum:]@._+-]+$ ]] || die "unsafe package name: $PACKAGE"
[ -f "$ROOT/$PACKAGE/PKGBUILD" ] || die "package has no PKGBUILD: $PACKAGE"

mkdir -p "$OUTPUT_DIR"
printf '%s\n' "$PACKAGE" > "$PACKAGES_FILE"
: > "$EXPECTED_FILE"
: > "$VERSIONS_FILE"

if ! expected_output=$(cd "$ROOT/$PACKAGE" && makepkg --packagelist); then
  die "$PACKAGE: could not determine expected package files"
fi
mapfile -t expected_paths <<< "$expected_output"
[ ${#expected_paths[@]} -gt 0 ] && [ -n "${expected_paths[0]}" ] \
  || die "$PACKAGE: makepkg predicted no package files"
for path in "${expected_paths[@]}"; do
  base=${path##*/}
  [[ $base =~ ^[[:alnum:]@._+:-]+\.pkg\.tar\.zst$ ]] \
    || die "$PACKAGE: unsafe predicted package filename: $base"
  printf 'file\t%s\n' "$base" >> "$EXPECTED_FILE"
done

if ! metadata=$(cd "$ROOT/$PACKAGE" && CARCH=x86_64; source ./PKGBUILD >/dev/null 2>&1
    package_base=${pkgbase:-${pkgname[0]}}
    package_version=${epoch:+$epoch:}$pkgver-$pkgrel
    printf '%s\t%s\t%s\n' "$package_base" "$package_version" "$pkgver"
    printf '%s\n' "${pkgname[@]}"); then
  die "$PACKAGE: could not read declared package metadata"
fi
IFS=$'\t' read -r package_base package_version vendor_version <<< "${metadata%%$'\n'*}"
mapfile -t declared_names <<< "${metadata#*$'\n'}"
[[ $package_base =~ ^[[:alnum:]@._+-]+$ ]] \
  || die "$PACKAGE: unsafe package base: $package_base"
[[ $package_version =~ ^[[:alnum:].+_:-]+$ ]] \
  || die "$PACKAGE: unsafe package version: $package_version"
[[ $vendor_version =~ ^[[:alnum:]][[:alnum:].+_]*$ ]] \
  || die "$PACKAGE: unsafe pkgver: $vendor_version"
[ ${#declared_names[@]} -gt 0 ] && [ -n "${declared_names[0]}" ] \
  || die "$PACKAGE: PKGBUILD declares no package names"
for name in "${declared_names[@]}"; do
  [[ $name =~ ^[[:alnum:]@._+-]+$ ]] || die "$PACKAGE: unsafe package name: $name"
  printf 'required\t%s\t%s\n' "$name" "$package_version" >> "$EXPECTED_FILE"
done
printf 'optional\t%s-debug\t%s\n' "$package_base" "$package_version" >> "$EXPECTED_FILE"
printf '%s\t%s\n' "$PACKAGE" "$vendor_version" > "$VERSIONS_FILE"
LC_ALL=C sort -u -o "$EXPECTED_FILE" "$EXPECTED_FILE"

printf 'prepared artifact policy for %s at %s\n' "$PACKAGE" "$package_version"
