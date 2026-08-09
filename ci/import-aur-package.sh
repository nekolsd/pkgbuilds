#!/usr/bin/env bash
# Copy one AUR package's current tracked source tree into this repository.
# Candidate files are archived as data only; nothing from the package is sourced,
# built, or executed here. The caller is responsible for reviewing the Git diff.
set -euo pipefail

PACKAGE=${1:?usage: ci/import-aur-package.sh <aur-package-name>}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
AUR_BASE_URL=${AUR_BASE_URL:-https://aur.archlinux.org}

temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
aur_repository="$temporary/aur.git"

git clone --bare --depth=1 --no-tags --quiet \
  "${AUR_BASE_URL%/}/$PACKAGE.git" "$aur_repository"
commit=$(git -C "$aur_repository" rev-parse HEAD)

mkdir -- "$ROOT/$PACKAGE"
git -C "$aur_repository" archive --format=tar "$commit" \
  | tar -xf - -C "$ROOT/$PACKAGE"

printf '%s\t%s\n' "$PACKAGE" "$commit" >> "$ROOT/aur-seen.lock"
git -C "$ROOT" add -f -- "$PACKAGE" aur-seen.lock

printf '%s\n' "$commit"
