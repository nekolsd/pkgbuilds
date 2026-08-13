#!/usr/bin/env bash
# Packaging pipeline: bump version -> build in a clean chroot -> add to the repo.
#
#   ./build.sh <pkg> [version]    build one package; bumps first if a version is given
#   ./build.sh --outdated         build everything nvchecker reports as behind
#   ./build.sh --prepare-outdated <file>
#                                  update recipes/checksums only; write package names
#   ./build.sh --prepare-one <pkg> <version>
#                                  update one recipe/checksums without advancing state
#   ./build.sh --check            run nvchecker only, list what is behind
#   ./build.sh --clean-src [pkg]  drop downloaded sources and build leftovers
set -euo pipefail

# Where built packages live. Deliberately outside the git checkout so a stray
# `git clean -xdf` cannot wipe the packages and the database, and on a pure ASCII
# path -- pacman.conf's Server is a URL, and whether a non-ASCII path needs
# percent-encoding is ambiguous. Owned by the current user, so building and
# publishing never needs root.
REPO_DIR="${REPO_DIR:-/var/cache/pkgrepo}"

# Build backend:
#   chroot   local default. devtools clean chroot, strongest isolation.
#   makepkg  for CI. A GitHub Actions runner is already a throwaway container;
#            nesting a chroot inside it would need privileged mode and buys nothing.
BUILD_BACKEND="${BUILD_BACKEND:-chroot}"

# When set, sign both packages and the repo database. A local file:// repo can go
# unsigned (there is no man in the middle), but network distribution must be signed:
# otherwise anyone who can intercept the connection can hand you arbitrary packages
# and pacman installs them as root.
SIGN_KEY="${SIGN_KEY:-}"
REPO_NAME="${REPO_NAME:-nekolsd}"
# When this is set, build unsigned packages into this directory and stop before
# signing or touching a repository database. CI uses it in its untrusted build
# job; the directory is uploaded as an artifact for a separate publisher job.
PACKAGE_OUTPUT_DIR="${PACKAGE_OUTPUT_DIR:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Print the leading comment block up to the first non-comment line, so adding a
# subcommand does not mean coming back here to fix line numbers.
usage() { awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 1; }

validate_package_name() {
  [[ $1 =~ ^[[:alnum:]@._+-]+$ ]] || die "invalid package name: $1"
}

validate_version() {
  # pkgver may contain letters, numbers, periods, underscores and plus signs,
  # but not whitespace, slashes, colons or hyphens. Apart from matching Arch's
  # rules, this keeps an untrusted vendor response out of sed syntax and paths.
  [[ $1 =~ ^[[:alnum:]][[:alnum:].+_]*$ ]] \
    || die "invalid vendor version for an Arch pkgver: $1"
}

# Set the version in a PKGBUILD to $2 and reset pkgrel to 1.
bump_version() {
  local d=$1 v=$2 var
  validate_version "$v"
  if grep -q '^pkgver=\$' "$d/PKGBUILD"; then
    # pkgver is derived from an underscore variable (1password uses _tarver);
    # the source variable is what has to change.
    var=$(grep -oP '^pkgver=\$\{?\K_[a-zA-Z_]+' "$d/PKGBUILD") \
      || die "$(basename "$d"): pkgver is derived but its source variable was not found, edit the PKGBUILD by hand"
    sed -i -E "s|^${var}=.*|${var}=${v}|" "$d/PKGBUILD"
    info "set \$${var} = ${v}"
  else
    # handles pkgver=1.2.3 / pkgver='1.2.3' / pkgver="1.2.3"
    sed -i -E "s|^pkgver=.*|pkgver=${v}|" "$d/PKGBUILD"
  fi
  sed -i -E "s|^pkgrel=.*|pkgrel=1|" "$d/PKGBUILD"
}

# Update one recipe without executing prepare(), build(), check() or package().
# updpkgsums downloads the declared sources and hashes them; this is safe to run
# in the credential-free preparation job. Restore the exact previous file if it
# cannot finish, so a new version is never paired with old checksums.
prepare_one() {
  local pkg=$1 newver=$2 d backup
  validate_package_name "$pkg"
  validate_version "$newver"
  d="$ROOT/$pkg"
  [ -f "$d/PKGBUILD" ] || die "no PKGBUILD for package: $pkg"

  backup=$(mktemp) || die "$pkg: could not create a PKGBUILD backup"
  cp -p -- "$d/PKGBUILD" "$backup" || { rm -f "$backup"; die "$pkg: could not back up PKGBUILD"; }

  if ! bump_version "$d" "$newver"; then
    cp -p -- "$backup" "$d/PKGBUILD"
    rm -f "$backup"
    die "$pkg: failed to set the version; PKGBUILD restored"
  fi

  info "$pkg: regenerating checksums (downloads sources, does not build them)..."
  if ! (cd "$d" && updpkgsums); then
    cp -p -- "$backup" "$d/PKGBUILD"
    rm -f "$backup"
    die "$pkg: source download failed; PKGBUILD restored"
  fi
  rm -f "$backup"
}

# Make sure the upstream signing keys a PKGBUILD declares are in the local keyring,
# otherwise signature verification inside the chroot fails.
ensure_pgp_keys() {
  local d=$1 keys=() k
  mapfile -t keys < <(cd "$d" && CARCH=x86_64; source ./PKGBUILD >/dev/null 2>&1
                      printf '%s\n' "${validpgpkeys[@]:-}")
  for k in "${keys[@]}"; do
    [ -z "$k" ] && continue
    if ! gpg --list-keys "$k" &>/dev/null; then
      info "importing upstream signing key $k"
      gpg --recv-keys "$k" || warn "failed to import key $k, signature checks may fail"
    fi
  done
}

# Remove downloaded sources and build leftovers from the package directories.
#
# Deliberately not `git clean`: that would rely on .gitignore patterns to guess
# which files are downloads, and claude-code's binary is called
# claude-2.1.226-x86_64 with no extension at all -- no pattern covers that well.
# Instead each PKGBUILD's own source arrays are parsed, and only what they declare
# is removed. Anything you dropped into a package directory by hand is left alone.
clean_src() {
  local pkgs=("$@") p d f s arch freed=0 sz
  if [ ${#pkgs[@]} -eq 0 ]; then
    mapfile -t pkgs < <(cd "$ROOT" && for x in */; do [ -f "${x}PKGBUILD" ] && echo "${x%/}"; done)
  fi

  for p in "${pkgs[@]}"; do
    d="$ROOT/$p"; [ -f "$d/PKGBUILD" ] || continue
    local -a targets=()

    # Resolve every source_* array, per architecture, into local file names.
    for arch in x86_64 aarch64 armv7h i686; do
      mapfile -t -O "${#targets[@]}" targets < <(
        cd "$d" && CARCH=$arch
        source ./PKGBUILD >/dev/null 2>&1 || exit 0
        for s in "${source[@]:-}" "${source_x86_64[@]:-}" "${source_aarch64[@]:-}" \
                 "${source_armv7h[@]:-}" "${source_i686[@]:-}"; do
          [ -z "$s" ] && continue
          case "$s" in *://*) ;; *) continue ;; esac      # leave local files alone
          if [[ $s == *::* ]]; then echo "${s%%::*}"; else echo "${s##*/}"; fi
        done)
    done

    sz=0
    for f in $(printf '%s\n' "${targets[@]:-}" | sort -u); do
      [ -n "$f" ] && [ -f "$d/$f" ] || continue
      sz=$(( sz + $(stat -c%s "$d/$f") ))
      rm -f "$d/$f" "$d/$f.part"
    done
    # makepkg's work directories and logs
    for extra in "$d"/src "$d"/pkg; do
      [ -d "$extra" ] && { sz=$(( sz + $(du -sb "$extra" | cut -f1) )); rm -rf "$extra"; }
    done
    rm -f "$d"/*.log

    if [ "$sz" -gt 0 ]; then
      # awk rather than bc for the float formatting: bc is not part of a base
      # system and cannot be assumed present.
      awk -v p="$p" -v n="$sz" 'BEGIN{printf "  %-26s freed %7.1f MB\n", p, n/1048576}'
      freed=$(( freed + sz ))
    fi
  done
  awk -v n="$freed" 'BEGIN{printf "\n\033[1;36m==>\033[0m freed %.2f GB total\n", n/1073741824}'
}

build_one() {
  # These have to be separate statements: bash expands every argument to `local`
  # before running it, so on one line the $pkg inside "$ROOT/$pkg" is still unset
  # and set -u calls it unbound.
  local pkg=$1
  local newver=${2:-}
  local d="$ROOT/$pkg"

  validate_package_name "$pkg"
  [ -f "$d/PKGBUILD" ] || die "no such package here: $pkg"

  if [ -n "$PACKAGE_OUTPUT_DIR" ] && [ -n "$SIGN_KEY" ]; then
    die "$pkg: PACKAGE_OUTPUT_DIR and SIGN_KEY are mutually exclusive; artifact builds must be unsigned"
  fi

  # Checked before anything else: an unsigned build into a signed repo silently
  # invalidates the database signature -- repo-add rewrites the database while the
  # .sig stays on the old contents, and nothing notices until some later operation
  # runs with -v. Has to be caught before the build, or a whole download-and-compile
  # cycle is wasted before it fails.
  if [ -z "$PACKAGE_OUTPUT_DIR" ] && [ -z "$SIGN_KEY" ] \
     && [ -f "$REPO_DIR/$REPO_NAME.db.tar.zst.sig" ]; then
    die "$pkg: repo $REPO_DIR is signed but SIGN_KEY is unset for this build.
     Continuing would invalidate the database signature. Either set SIGN_KEY=<key id>,
     or delete $REPO_NAME.db.tar.zst.sig to give up signing explicitly."
  fi
  cd "$d"

  # Note: every step below writes an explicit `|| die` rather than relying on set -e.
  # --outdated isolates failures with `if ( build_one ... )`, and bash disables
  # errexit throughout a compound command used as an if condition -- which once let
  # a failed updpkgsums carry on into the build, pairing a new version with stale
  # checksums until the integrity check blew up.
  if [ -n "$newver" ]; then
    local cur
    cur=$(CARCH=x86_64; source ./PKGBUILD >/dev/null 2>&1; echo "$pkgver")
    info "$pkg: $cur → $newver"
    prepare_one "$pkg" "$newver"
  fi

  ensure_pgp_keys "$d"

  local mkpkg_args=()
  [ -n "$SIGN_KEY" ] && mkpkg_args+=(--sign --key "$SIGN_KEY")

  if [ "$BUILD_BACKEND" = makepkg ]; then
    # CI path: the container is the isolation. No --nocheck; checkdepends still run.
    info "$pkg: building with makepkg (backend=makepkg)..."
    makepkg --syncdeps --noconfirm --needed --clean "${mkpkg_args[@]}" \
      || die "$pkg: makepkg build failed"
  else
    # About -c: archbuild hardcodes makechrootpkg_args=(-c -n -C), so whether or not
    # -c is passed here, every package's working copy is re-synced from the base --
    # isolation always holds and dependencies are always installed fresh.
    # extra-x86_64-build's own -c only decides whether the *base* chroot is
    # pacstrapped from scratch, which means re-downloading close to 1G of
    # base+base-devel. Leaving it off lets the base update incrementally instead.
    # CLEAN_CHROOT=1 is for when the base itself is broken and needs rebuilding.
    if [ -n "${CLEAN_CHROOT:-}" ]; then
      info "$pkg: rebuilding the base chroot, then building..."
      extra-x86_64-build -c || die "$pkg: chroot build failed"
    else
      info "$pkg: building in chroot..."
      extra-x86_64-build || die "$pkg: chroot build failed"
    fi
    # chroot builds do not sign; do it here.
    if [ -n "$SIGN_KEY" ]; then
      shopt -s nullglob
      for f in *.pkg.tar.zst; do
        gpg --detach-sign --use-agent --no-armor -u "$SIGN_KEY" --yes "$f" \
          || die "$pkg: signing failed"
      done
      shopt -u nullglob
    fi
  fi

  shopt -s nullglob
  local built=(*.pkg.tar.zst)
  shopt -u nullglob
  [ ${#built[@]} -gt 0 ] || die "$pkg: no package was produced"

  if [ -n "$PACKAGE_OUTPUT_DIR" ]; then
    mkdir -p "$PACKAGE_OUTPUT_DIR"
    local artifacts=()
    for f in "${built[@]}"; do
      [ ! -e "$f.sig" ] || die "$pkg: artifact build unexpectedly produced a signature"
      [ ! -e "$PACKAGE_OUTPUT_DIR/$(basename "$f")" ] \
        || die "$pkg: duplicate artifact name: $(basename "$f")"
      mv -- "$f" "$PACKAGE_OUTPUT_DIR/"
      artifacts+=("$PACKAGE_OUTPUT_DIR/$(basename "$f")")
    done
    info "$pkg: unsigned artifact(s) ready → ${artifacts[*]##*/}"
    return 0
  fi

  mkdir -p "$REPO_DIR"
  local moved=()
  for f in "${built[@]}"; do
    mv -f "$f" "$REPO_DIR/"
    [ -f "$f.sig" ] && mv -f "$f.sig" "$REPO_DIR/"
    moved+=("$REPO_DIR/$(basename "$f")")
  done

  local repoadd_args=(-R)
  # -s signs the database itself; -v verifies the existing signature, which is what
  # catches a database that was rewritten without being re-signed.
  [ -n "$SIGN_KEY" ] && repoadd_args+=(-s -v -k "$SIGN_KEY")
  repo-add "${repoadd_args[@]}" "$REPO_DIR/$REPO_NAME.db.tar.zst" "${moved[@]}"
  info "$pkg: added to the repo → ${moved[*]##*/}"

  if [ -n "$newver" ]; then
    git -C "$ROOT" add "$pkg/PKGBUILD"
    git -C "$ROOT" commit -qm "$pkg: update to $newver" && info "committed the recipe change"
  fi
}

advance_baseline() {
  [ "$#" -gt 0 ] || return 0
  python3 - "$ROOT/nvchecker-new.json" "$ROOT/nvchecker-old.json" "$@" <<'PY'
import json
import os
import sys
import tempfile

new_path, old_path, *packages = sys.argv[1:]
with open(new_path, encoding="utf-8") as stream:
    new = json.load(stream)["data"]
with open(old_path, encoding="utf-8") as stream:
    old = json.load(stream)

for package in packages:
    if package not in new:
        raise SystemExit(f"nvchecker produced no data for {package}")
    old["data"][package] = new[package]

fd, temporary = tempfile.mkstemp(prefix=".nvchecker-old.", dir=os.path.dirname(old_path))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(old, stream, indent=2, ensure_ascii=False)
        stream.write("\n")
    os.chmod(temporary, os.stat(old_path).st_mode & 0o777)
    os.replace(temporary, old_path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

prepare_outdated() {
  local output_file=$1 row p v
  local -a rows=() ok=() failed=()

  [ -n "$output_file" ] || die "--prepare-outdated needs an output file"
  mkdir -p "$(dirname "$output_file")"
  : > "$output_file"

  cd "$ROOT"
  nvchecker -c nvchecker.toml >/dev/null 2>&1
  mapfile -t rows < <(nvcmp -c nvchecker.toml)
  [ ${#rows[@]} -gt 0 ] || { info "everything is up to date"; return 0; }
  info "${#rows[@]} recipe(s) to prepare:"; printf '    %s\n' "${rows[@]}"

  for row in "${rows[@]}"; do
    # nvcmp prints: <name> <old version> -> <new version>
    p=$(awk '{print $1}' <<<"$row")
    v=$(awk '{print $NF}' <<<"$row")
    info "$p: preparing vendor update to $v"
    if (prepare_one "$p" "$v"); then
      ok+=("$p")
    else
      failed+=("$p")
      warn "$p: preparation failed"
    fi
  done

  if [ ${#ok[@]} -gt 0 ]; then
    advance_baseline "${ok[@]}"
    printf '%s\n' "${ok[@]}" > "$output_file"
  fi

  if [ ${#failed[@]} -gt 0 ]; then
    warn "${#failed[@]} preparation(s) failed: ${failed[*]}"
    return 1
  fi
  info "prepared ${#ok[@]} update(s): ${ok[*]}"
}

case "${1:-}" in
  ''|-h|--help) usage ;;

  --check)
    cd "$ROOT" && nvchecker -c nvchecker.toml >/dev/null 2>&1
    nvcmp -c nvchecker.toml
    ;;

  --clean-src)
    shift
    info "removing downloaded sources and build leftovers (re-downloadable from the PKGBUILDs)"
    clean_src "$@"
    ;;

  --prepare-outdated)
    [ "$#" -eq 2 ] || die "usage: ./build.sh --prepare-outdated <packages-file>"
    prepare_outdated "$2"
    ;;

  --prepare-one)
    [ "$#" -eq 3 ] || die "usage: ./build.sh --prepare-one <package> <version>"
    prepare_one "$2" "$3"
    ;;

  --outdated)
    cd "$ROOT"
    nvchecker -c nvchecker.toml >/dev/null 2>&1
    mapfile -t rows < <(nvcmp -c nvchecker.toml)
    [ ${#rows[@]} -gt 0 ] || { info "everything is up to date"; exit 0; }
    info "${#rows[@]} to build:"; printf '    %s\n' "${rows[@]}"

    ok=(); failed=()
    for row in "${rows[@]}"; do
      # nvcmp prints: <name> <old version> -> <new version>
      p=$(awk '{print $1}' <<<"$row"); v=$(awk '{print $NF}' <<<"$row")
      # Subshell, so one package blowing up does not take the rest down with set -e.
      if ( build_one "$p" "$v" ); then ok+=("$p"); else failed+=("$p"); warn "$p failed, skipping"; fi
    done

    # Only advance the baseline for packages that built; the failures stay listed
    # by the next --check.
    if [ ${#ok[@]} -gt 0 ]; then
      advance_baseline "${ok[@]}"
      git add nvchecker-old.json && git commit -qm "advance version baseline: ${ok[*]}" || true
    fi

    echo
    info "${#ok[@]} succeeded: ${ok[*]:-none}"
    # Has to be an if, not `[ cond ] && warn`: that would be the last statement in
    # this branch, so its exit status becomes the script's -- with no failures
    # [ 0 -gt 0 ] returns 1 and the success/failure signal is exactly inverted
    # (in CI that looked like every build succeeding and the step reporting exit 1).
    if [ ${#failed[@]} -gt 0 ]; then
      warn "${#failed[@]} failed: ${failed[*]}"
      exit 1
    fi
    ;;

  *) build_one "$1" "${2:-}" ;;
esac
