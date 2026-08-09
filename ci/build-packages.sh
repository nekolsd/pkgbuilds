#!/usr/bin/env bash
# Build unsigned package artifacts. This script is intentionally usable without
# repository, signing, R2, or GitHub credentials.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES_FILE=${1:?usage: ci/build-packages.sh <packages-file> <expected-packages.tsv> <output-directory>}
EXPECTED_FILE=${2:?usage: ci/build-packages.sh <packages-file> <expected-packages.tsv> <output-directory>}
OUTPUT_DIR=${3:?usage: ci/build-packages.sh <packages-file> <expected-packages.tsv> <output-directory>}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -f "$PACKAGES_FILE" ] || die "package list not found: $PACKAGES_FILE"
[ -f "$EXPECTED_FILE" ] && [ ! -L "$EXPECTED_FILE" ] \
  || die "artifact policy is not a regular file: $EXPECTED_FILE"
mkdir -p "$OUTPUT_DIR"
if find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  die "artifact output directory is not empty: $OUTPUT_DIR"
fi

declare -A allowed_files=()
declare -A allowed_names=()
declare -A required_names=()
declare -A expected_versions=()
while IFS=$'\t' read -r kind value version extra || [ -n "${kind:-}" ]; do
  [ -z "${extra:-}" ] || die "malformed artifact policy line"
  case "$kind" in
    file)
      [ -z "${version:-}" ] || die "malformed file policy entry"
      [[ $value =~ ^[[:alnum:]@._+:-]+\.pkg\.tar\.zst$ ]] \
        || die "unsafe predicted package filename: $value"
      [ -z "${allowed_files[$value]+present}" ] || die "duplicate file policy: $value"
      allowed_files["$value"]=1
      ;;
    required|optional)
      [[ $value =~ ^[[:alnum:]@._+-]+$ ]] || die "unsafe package name in artifact policy: $value"
      [[ $version =~ ^[[:alnum:].+_:-]+$ ]] || die "unsafe version in artifact policy: $version"
      if [ -n "${expected_versions[$value]+present}" ] \
         && [ "${expected_versions[$value]}" != "$version" ]; then
        die "conflicting expected versions for $value"
      fi
      allowed_names["$value"]=1
      expected_versions["$value"]=$version
      [ "$kind" = optional ] || required_names["$value"]=1
      ;;
    *) die "unknown artifact policy entry: $kind" ;;
  esac
done < "$EXPECTED_FILE"
[ ${#allowed_files[@]} -gt 0 ] && [ ${#required_names[@]} -gt 0 ] \
  || die "artifact policy is empty"

count=0
while IFS= read -r package || [ -n "$package" ]; do
  [ -n "$package" ] || continue
  [[ $package =~ ^[[:alnum:]@._+-]+$ ]] || die "unsafe package name: $package"
  [ -f "$ROOT/$package/PKGBUILD" ] || die "no PKGBUILD for selected package: $package"

  BUILD_BACKEND=makepkg \
  PACKAGE_OUTPUT_DIR="$OUTPUT_DIR" \
  SIGN_KEY= \
    "$ROOT/build.sh" "$package"
  count=$((count + 1))
done < "$PACKAGES_FILE"
[ "$count" -gt 0 ] || die "package list is empty"

declare -a basenames=()
declare -A found_names=()
while IFS= read -r -d '' entry; do
  base=${entry##*/}
  [ -f "$entry" ] && [ ! -L "$entry" ] || die "artifact is not a regular file: $base"
  [[ $base =~ ^[[:alnum:]@._+:-]+\.pkg\.tar\.zst$ ]] \
    || die "unexpected artifact name: $base"
  [ -n "${allowed_files[$base]+present}" ] || die "package was not predicted by makepkg: $base"
  query=$(pacman -Qp -- "$entry") || die "invalid Arch package artifact: $base"
  actual_name=${query%% *}
  actual_version=${query#* }
  [ -n "${allowed_names[$actual_name]+present}" ] \
    || die "artifact declares an unexpected package name: $actual_name"
  [ "$actual_version" = "${expected_versions[$actual_name]}" ] \
    || die "$actual_name: artifact version $actual_version does not match ${expected_versions[$actual_name]}"
  found_names["$actual_name"]=1
  basenames+=("$base")
done < <(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print0 | LC_ALL=C sort -z)
[ ${#basenames[@]} -gt 0 ] || die "no package artifacts were produced"

for name in "${!required_names[@]}"; do
  [ -n "${found_names[$name]+present}" ] \
    || die "required package artifact was not produced: $name"
done

(
  cd "$OUTPUT_DIR"
  sha256sum -- "${basenames[@]}" > package-manifest.sha256
)
printf 'built %s package archive(s) from %s recipe(s)\n' "${#basenames[@]}" "$count"
