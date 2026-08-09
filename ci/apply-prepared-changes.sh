#!/usr/bin/env bash
# Apply only the recipe/baseline patch emitted by the credential-free prepare
# job. This is the sole artifact consumed by the job with GitHub write access.
set -euo pipefail

PATCH_FILE=${1:?usage: ci/apply-prepared-changes.sh <recipe.patch>}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -f "$PATCH_FILE" ] && [ ! -L "$PATCH_FILE" ] || die "recipe patch is not a regular file"
[ -s "$PATCH_FILE" ] || exit 0
git diff --quiet && git diff --cached --quiet || die "refusing to apply a patch to a dirty checkout"

# Parse once to catch a malformed patch before collecting its NUL-delimited paths.
git apply --numstat -z -- "$PATCH_FILE" >/dev/null
mapfile -d '' -t records < <(git apply --numstat -z -- "$PATCH_FILE")
[ ${#records[@]} -gt 0 ] || die "recipe patch changes no files"

for record in "${records[@]}"; do
  IFS=$'\t' read -r added deleted path <<< "$record"
  [[ $added =~ ^[0-9]+$ ]] && [[ $deleted =~ ^[0-9]+$ ]] \
    || die "binary or malformed recipe patch is not allowed"
  if [ "$path" = nvchecker-old.json ] \
     || [[ $path =~ ^[[:alnum:]@._+-]+/PKGBUILD$ ]]; then
    continue
  fi
  die "recipe patch tries to modify a disallowed path: $path"
done

git apply --check -- "$PATCH_FILE"
git apply --index -- "$PATCH_FILE"

while IFS= read -r -d '' path; do
  if [ "$path" = nvchecker-old.json ] \
     || [[ $path =~ ^[[:alnum:]@._+-]+/PKGBUILD$ ]]; then
    mode=$(git ls-files -s -- "$path")
    mode=${mode%% *}
    [ "$mode" = 100644 ] || die "prepared file has an unexpected git mode: $path ($mode)"
    continue
  fi
  die "staged a disallowed path after applying recipe patch: $path"
done < <(git diff --cached --name-only -z --)

python3 -m json.tool nvchecker-old.json >/dev/null
