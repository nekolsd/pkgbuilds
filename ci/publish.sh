#!/usr/bin/env bash
# Verify unsigned artifacts, then sign and publish them from a fresh job. Artifact
# verification can also run by itself before any publishing secret is exposed.
set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

declare -a PACKAGE_NAMES=()

verify_artifacts() {
  local dir=$1 policy=$2 manifest="$1/package-manifest.sha256"
  local entry base line expected name kind value version extra query actual_name actual_version
  local -A listed=() allowed_files=() allowed_names=() required_names=() expected_versions=() found_names=()
  local -a actual=()

  [ -d "$dir" ] || die "artifact directory not found: $dir"
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || die "regular checksum manifest is missing"
  [ -f "$policy" ] && [ ! -L "$policy" ] || die "artifact policy is not a regular file"

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
  done < "$policy"
  [ ${#allowed_files[@]} -gt 0 ] && [ ${#required_names[@]} -gt 0 ] \
    || die "artifact policy is empty"

  while IFS= read -r -d '' entry; do
    base=${entry##*/}
    [ -f "$entry" ] && [ ! -L "$entry" ] || die "artifact is not a regular file: $base"
    if [ "$base" = package-manifest.sha256 ]; then
      continue
    fi
    [[ $base =~ ^[[:alnum:]@._+:-]+\.pkg\.tar\.zst$ ]] \
      || die "unexpected file in package artifact: $base"
    [ -n "${allowed_files[$base]+present}" ] || die "package was not predicted by the prepare job: $base"
    actual+=("$base")
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 | LC_ALL=C sort -z)
  [ ${#actual[@]} -gt 0 ] || die "artifact contains no packages"

  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line =~ ^([0-9a-f]{64})\ \ ([[:alnum:]@._+:-]+\.pkg\.tar\.zst)$ ]] \
      || die "malformed checksum manifest line"
    expected=${BASH_REMATCH[1]}
    name=${BASH_REMATCH[2]}
    [ -z "${listed[$name]+present}" ] || die "duplicate package in checksum manifest: $name"
    listed["$name"]=$expected
  done < "$manifest"

  [ ${#listed[@]} -eq ${#actual[@]} ] || die "checksum manifest does not match the artifact file set"
  for name in "${actual[@]}"; do
    [ -n "${listed[$name]+present}" ] || die "package missing from checksum manifest: $name"
  done

  (cd "$dir" && sha256sum --check --strict package-manifest.sha256)
  for name in "${actual[@]}"; do
    query=$(pacman -Qp -- "$dir/$name") || die "invalid Arch package archive: $name"
    actual_name=${query%% *}
    actual_version=${query#* }
    [ -n "${allowed_names[$actual_name]+present}" ] \
      || die "artifact declares an unexpected package name: $actual_name"
    [ "$actual_version" = "${expected_versions[$actual_name]}" ] \
      || die "$actual_name: artifact version $actual_version does not match ${expected_versions[$actual_name]}"
    found_names["$actual_name"]=1
  done
  for name in "${!required_names[@]}"; do
    [ -n "${found_names[$name]+present}" ] \
      || die "required package artifact was not produced: $name"
  done
  PACKAGE_NAMES=("${actual[@]}")
  printf 'verified %s unsigned package archive(s)\n' "${#PACKAGE_NAMES[@]}"
}

if [ "${1:-}" = --verify-only ]; then
  ARTIFACT_DIR=${2:-}
  EXPECTED_FILE=${3:-}
else
  ARTIFACT_DIR=${1:-}
  EXPECTED_FILE=${2:-}
fi
[ -n "$ARTIFACT_DIR" ] && [ -n "$EXPECTED_FILE" ] \
  || die "usage: ci/publish.sh [--verify-only] <artifact-directory> <expected-packages.tsv> [repository-directory]"
verify_artifacts "$ARTIFACT_DIR" "$EXPECTED_FILE"

if [ "${1:-}" = --verify-only ]; then
  exit 0
fi

REPO_DIR=${3:?usage: ci/publish.sh <artifact-directory> <expected-packages.tsv> <repository-directory>}
: "${GNUPGHOME:?GNUPGHOME is required}"
: "${R2_ACCOUNT_ID:?R2_ACCOUNT_ID is required}"
: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is required}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is required}"
: "${R2_BUCKET:?R2_BUCKET is required}"
: "${GPG_SIGNING_KEY:?GPG_SIGNING_KEY is required}"
: "${SIGN_KEY:?SIGN_KEY is required}"

R2_PREFIX=${R2_PREFIX:-archlinux}
REPO_NAME=${REPO_NAME:-nekolsd}
GPG_PASSPHRASE=${GPG_PASSPHRASE:-}

[[ $R2_BUCKET =~ ^[[:alnum:]._-]+$ ]] || die "unsafe R2 bucket name"
[[ $R2_PREFIX =~ ^[[:alnum:]./_-]+$ ]] && [[ /$R2_PREFIX/ != */../* ]] \
  || die "unsafe R2 prefix"
[[ $REPO_NAME =~ ^[[:alnum:]._-]+$ ]] || die "unsafe repository name"
[[ $SIGN_KEY =~ ^[[:xdigit:]]{8,40}$ ]] || die "SIGN_KEY must be a GPG key ID or fingerprint"

export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID=$R2_ACCESS_KEY_ID
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=$R2_SECRET_ACCESS_KEY
export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
export RCLONE_CONFIG_R2_ACL=private
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true

install -d -m0700 "$GNUPGHOME"
printf 'pinentry-mode loopback\n' > "$GNUPGHOME/gpg.conf"
printf 'allow-loopback-pinentry\n' > "$GNUPGHOME/gpg-agent.conf"
if [ -n "$GPG_PASSPHRASE" ]; then
  printf 'passphrase %s\n' "$GPG_PASSPHRASE" >> "$GNUPGHOME/gpg.conf"
fi
chmod 0600 "$GNUPGHOME/gpg.conf" "$GNUPGHOME/gpg-agent.conf"
printf '%s' "$GPG_SIGNING_KEY" | gpg --batch --import

install -d -m0755 "$REPO_DIR"
remote="r2:${R2_BUCKET}/${R2_PREFIX}/x86_64"
rclone sync "$remote" "$REPO_DIR" --transfers 8 --checkers 16 --fast-list
printf 'pulled %s existing packages\n' \
  "$(find "$REPO_DIR" -maxdepth 1 -type f -name '*.pkg.tar.zst' | wc -l)"

declare -a repo_packages=()
for name in "${PACKAGE_NAMES[@]}"; do
  install -m0644 "$ARTIFACT_DIR/$name" "$REPO_DIR/$name"
  gpg --batch --yes --no-armor --detach-sign --local-user "$SIGN_KEY" \
    --output "$REPO_DIR/$name.sig" "$REPO_DIR/$name"
  repo_packages+=("$REPO_DIR/$name")
done

repo-add -R -s -v -k "$SIGN_KEY" \
  "$REPO_DIR/$REPO_NAME.db.tar.zst" "${repo_packages[@]}"

# Keep the old database live until every package it will reference is present.
rclone copy --copy-links "$REPO_DIR" "$remote" \
  --exclude '*.db*' --exclude '*.files*' --transfers 8 --fast-list
rclone copy --copy-links "$REPO_DIR" "$remote" \
  --include '*.db*' --include '*.files*'
rclone sync --copy-links "$REPO_DIR" "$remote" --transfers 8 --fast-list
printf 'published %s package archive(s) to %s\n' "${#PACKAGE_NAMES[@]}" "$remote"
