#!/usr/bin/env bash
# Validate every successful matrix artifact and combine it for one serialized R2
# publication. Failed matrix entries have no artifact and therefore cannot block
# successful packages from reaching the repository.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOWNLOAD_DIR=${1:?usage: ci/collect-built-packages.sh <downloads> <policies> <packages> <policy> <versions>}
POLICY_DIR=${2:?usage: ci/collect-built-packages.sh <downloads> <policies> <packages> <policy> <versions>}
PACKAGE_DIR=${3:?usage: ci/collect-built-packages.sh <downloads> <policies> <packages> <policy> <versions>}
EXPECTED_FILE=${4:?usage: ci/collect-built-packages.sh <downloads> <policies> <packages> <policy> <versions>}
VERSIONS_FILE=${5:?usage: ci/collect-built-packages.sh <downloads> <policies> <packages> <policy> <versions>}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
[ -d "$DOWNLOAD_DIR" ] || die "artifact download directory is missing"
[ -d "$POLICY_DIR" ] || die "independent artifact-policy directory is missing"
mkdir -p "$PACKAGE_DIR"
if find "$PACKAGE_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  die "combined package directory is not empty: $PACKAGE_DIR"
fi
: > "$EXPECTED_FILE"
: > "$VERSIONS_FILE"

count=0
while IFS= read -r -d '' bundle; do
  artifact_name=${bundle##*/}
  package=${artifact_name#built-}
  [[ $package =~ ^[[:alnum:]@._+-]+$ ]] || die "unsafe matrix artifact name: $artifact_name"
  policy="$POLICY_DIR/policy-$package"
  [ -d "$bundle/packages" ] || die "matrix artifact has no packages directory: ${bundle##*/}"
  if find "$bundle" -mindepth 1 -maxdepth 1 ! -name packages -print -quit | grep -q .; then
    die "matrix artifact contains data outside its package directory: $artifact_name"
  fi
  [ -f "$policy/expected-packages.tsv" ] && [ ! -L "$policy/expected-packages.tsv" ] \
    || die "independent artifact policy is missing for $package"
  [ -f "$policy/published-versions.tsv" ] && [ ! -L "$policy/published-versions.tsv" ] \
    || die "independent version record is missing for $package"

  "$ROOT/ci/publish.sh" --verify-only \
    "$bundle/packages" "$policy/expected-packages.tsv"
  while IFS= read -r -d '' archive; do
    base=${archive##*/}
    [ "$base" = package-manifest.sha256 ] && continue
    [ ! -e "$PACKAGE_DIR/$base" ] || die "duplicate package artifact: $base"
    install -m0644 "$archive" "$PACKAGE_DIR/$base"
  done < <(find "$bundle/packages" -mindepth 1 -maxdepth 1 -type f -print0)
  cat "$policy/expected-packages.tsv" >> "$EXPECTED_FILE"
  cat "$policy/published-versions.tsv" >> "$VERSIONS_FILE"
  count=$((count + 1))
done < <(find "$DOWNLOAD_DIR" -mindepth 1 -maxdepth 1 -type d -name 'built-*' -print0 | LC_ALL=C sort -z)

[ "$count" -gt 0 ] || die "no successful package artifacts were downloaded"
LC_ALL=C sort -u -o "$EXPECTED_FILE" "$EXPECTED_FILE"
LC_ALL=C sort -u -o "$VERSIONS_FILE" "$VERSIONS_FILE"
(
  cd "$PACKAGE_DIR"
  mapfile -d '' -t archives < <(find . -mindepth 1 -maxdepth 1 -type f -name '*.pkg.tar.zst' -printf '%f\0' | LC_ALL=C sort -z)
  [ ${#archives[@]} -gt 0 ] || exit 4
  sha256sum -- "${archives[@]}" > package-manifest.sha256
) || die "could not create combined package manifest"

printf 'collected %s successful package build(s) for one publication\n' "$count"
