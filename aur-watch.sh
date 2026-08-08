#!/usr/bin/env bash
# Read-only AUR change watcher.
#
#   ./aur-watch.sh check                       list changed packages as TSV
#   ./aur-watch.sh report <pkg> <old> <new>    render a review body as Markdown
#   ./aur-watch.sh set-seen <pkg> <commit>     advance one entry in aur-seen.lock
#
# AUR repositories are untrusted input. This script fetches them only into a
# temporary bare Git repository: it never checks files out into the package tree,
# sources them, builds them, or executes them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_FILE="${AUR_SEEN_LOCK:-$ROOT/aur-seen.lock}"
PACKAGE_ROOT="${AUR_PACKAGE_ROOT:-$ROOT}"
AUR_BASE_URL="${AUR_BASE_URL:-https://aur.archlinux.org}"
export GIT_TERMINAL_PROMPT=0
export GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT:-1}"
export GIT_HTTP_LOW_SPEED_TIME="${GIT_HTTP_LOW_SPEED_TIME:-30}"

warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,/^set -euo pipefail$/s/^# \{0,1\}//p' "$0"
  exit "${1:-1}"
}

valid_pkg() {
  [[ $1 =~ ^[a-z0-9][a-z0-9@._+-]*$ ]]
}

valid_commit() {
  [[ $1 =~ ^[0-9a-f]{40}$ ]]
}

remote_url() {
  printf '%s/%s.git\n' "${AUR_BASE_URL%/}" "$1"
}

validate_lock() {
  [ -f "$LOCK_FILE" ] || die "missing lock file: $LOCK_FILE"

  local pkg commit extra path local_pkg line=0
  local -A entries=()
  while read -r pkg commit extra; do
    line=$((line + 1))
    [ -z "${pkg:-}" ] && continue
    [[ $pkg == \#* ]] && continue
    valid_pkg "$pkg" || die "$LOCK_FILE:$line: invalid package name: $pkg"
    valid_commit "${commit:-}" || die "$LOCK_FILE:$line: invalid commit for $pkg"
    [ -z "${extra:-}" ] || die "$LOCK_FILE:$line: unexpected extra fields"
    [ -z "${entries[$pkg]+present}" ] || die "$LOCK_FILE:$line: duplicate package: $pkg"
    entries["$pkg"]=1
  done < "$LOCK_FILE"

  # A newly added local package must not silently fall outside AUR monitoring,
  # and a stale lock entry should not keep querying an unrelated package forever.
  for path in "$PACKAGE_ROOT"/*/PKGBUILD; do
    [ -f "$path" ] || continue
    local_pkg=${path%/PKGBUILD}
    local_pkg=${local_pkg##*/}
    [ -n "${entries[$local_pkg]+present}" ] \
      || die "$local_pkg has a PKGBUILD but no entry in $LOCK_FILE"
  done
  for pkg in "${!entries[@]}"; do
    [ -f "$PACKAGE_ROOT/$pkg/PKGBUILD" ] \
      || die "$pkg is in $LOCK_FILE but has no local PKGBUILD"
  done
}

current_commit() {
  local pkg=$1 result commit
  if ! result=$(git ls-remote --exit-code "$(remote_url "$pkg")" refs/heads/master 2>/dev/null); then
    return 1
  fi
  commit=${result%%[[:space:]]*}
  valid_commit "$commit" || return 1
  printf '%s\n' "$commit"
}

check_all() {
  validate_lock

  local pkg seen current failures=0
  while read -r pkg seen _; do
    [ -z "${pkg:-}" ] && continue
    [[ $pkg == \#* ]] && continue

    if ! current=$(current_commit "$pkg"); then
      warn "$pkg: AUR is unavailable or the package does not exist; leaving its baseline unchanged"
      failures=$((failures + 1))
      continue
    fi

    if [ "$current" != "$seen" ]; then
      printf '%s\t%s\t%s\n' "$pkg" "$seen" "$current"
    fi
  done < "$LOCK_FILE"

  if [ "$failures" -gt 0 ]; then
    warn "$failures package(s) could not be checked; this does not affect vendor-driven builds"
  fi
}

html_escape() {
  iconv -f UTF-8 -t UTF-8 -c 2>/dev/null \
    | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Render at most $2 bytes *after* escaping, so a maliciously large AUR diff cannot
# exceed GitHub's PR-body limit. The complete commits remain linked in the report.
render_file() {
  local source=$1 limit=$2 escaped size
  escaped="${source}.html"
  html_escape < "$source" > "$escaped"
  size=$(wc -c < "$escaped")
  if [ "$size" -le "$limit" ]; then
    cat "$escaped"
  else
    head -c "$limit" "$escaped" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null
    printf '\n... output truncated after %s rendered bytes ...\n' "$limit"
  fi
}

report_change() (
  [ $# -eq 3 ] || die "usage: $0 report <pkg> <old-commit> <new-commit>"
  local pkg=$1 old=$2 new=$3
  valid_pkg "$pkg" || die "invalid package name: $pkg"
  valid_commit "$old" || die "invalid baseline commit: $old"
  valid_commit "$new" || die "invalid candidate commit: $new"

  local tmp repo url actual old_tree new_tree base_note history_range
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  repo="$tmp/aur.git"
  url=$(remote_url "$pkg")

  git init --bare -q "$repo"
  # Recent AUR repositories can contain years of history. Fifty commits is ample
  # for a daily watcher and avoids downloading that history merely to render one
  # review. A rewritten/older baseline is fetched by its exact ID below.
  git -C "$repo" fetch -q --no-tags --depth=50 "$url" \
    refs/heads/master:refs/remotes/aur/master \
    || die "$pkg: failed to fetch AUR objects"

  actual=$(git -C "$repo" rev-parse 'refs/remotes/aur/master^{commit}')
  [ "$actual" = "$new" ] \
    || die "$pkg: AUR changed again while preparing the report ($new -> $actual); retry next run"
  new_tree=$(git -C "$repo" rev-parse "$new^{tree}")

  if ! git -C "$repo" cat-file -e "$old^{commit}" 2>/dev/null; then
    git -C "$repo" fetch -q --no-tags --depth=1 "$url" "$old" 2>/dev/null || true
  fi

  if git -C "$repo" cat-file -e "$old^{commit}" 2>/dev/null; then
    old_tree=$(git -C "$repo" rev-parse "$old^{tree}")
    base_note="Compared with the last reviewed AUR tree."
    if git -C "$repo" merge-base --is-ancestor "$old" "$new" 2>/dev/null; then
      history_range="$old..$new"
    else
      base_note="The AUR history was rewritten; the two complete trees are compared directly."
      history_range="$new"
    fi
  else
    old_tree=$(git -C "$repo" mktree </dev/null)
    base_note="The old AUR commit is no longer fetchable; the candidate is shown against an empty tree."
    history_range="$new"
  fi

  git -C "$repo" log -10 --date=iso-strict \
    --format='%H  %ad  %an <%ae>%n    %s' "$history_range" > "$tmp/log" || true
  git -c core.quotepath=true -C "$repo" diff \
    --no-ext-diff --no-textconv --raw --full-index --no-abbrev \
    "$old_tree" "$new_tree" > "$tmp/raw"
  git -c core.quotepath=true -C "$repo" diff \
    --no-ext-diff --no-textconv --stat --summary \
    "$old_tree" "$new_tree" > "$tmp/stat"
  git -c core.quotepath=true -C "$repo" diff \
    --no-ext-diff --no-textconv --find-renames \
    "$old_tree" "$new_tree" > "$tmp/diff"

  # This block expands the fixed variables above. Use <code> for static Markdown
  # code spans; an unescaped backtick in an expanding heredoc is shell syntax.
  cat <<EOF
## AUR source changed: \`$pkg\`

$base_note AUR data was read only as bare Git objects; no candidate file was
checked out into the package tree, sourced, built, or executed.

- Baseline commit: [\`$old\`](https://aur.archlinux.org/cgit/aur.git/commit/?h=$pkg&id=$old)
- Candidate commit: [\`$new\`](https://aur.archlinux.org/cgit/aur.git/commit/?h=$pkg&id=$new)
- Candidate tree: \`$new_tree\`
- [AUR commit history](https://aur.archlinux.org/cgit/aur.git/log/?h=$pkg)

Merging this PR only records that the candidate was reviewed. It does **not** copy
the AUR recipe into this repository or change the vendor-driven package version.
If a recipe change is useful, port that change to the local package explicitly in
this PR before merging.

### Human review gate

- [ ] Inspect every entry under **Changed Git objects**, including dotfiles,
      nested files, symlinks, deletions, and executable-bit changes.
- [ ] Read changes to <code>source</code>, <code>prepare()</code>,
      <code>build()</code>, and <code>package()</code>; a
      checksum identifies bytes but does not make those bytes trustworthy.
- [ ] Treat install scripts and pacman hooks as root-executed code and review every
      changed line, command, path, user, service, and permission.
- [ ] Do not port an unexplained binary blob. Establish its vendor/source
      provenance and verify it independently, or leave the local recipe unchanged.
- [ ] Hand-port only the minimal accepted change. If <code>pkgver</code> is
      unchanged, bump <code>pkgrel</code>, then build only from the reviewed local
      package tree.
- [ ] Merge only when this exact candidate commit may become the new AUR baseline.

### Commits

<pre>
EOF
  render_file "$tmp/log" 6000
  cat <<'EOF'
</pre>

### Changed Git objects

The raw list includes file modes and both blob IDs, so binary, symlink, deletion,
rename, and executable-bit changes remain visible even when no text diff exists.

<pre>
EOF
  render_file "$tmp/raw" 10000
  cat <<'EOF'
</pre>

### Summary

<pre>
EOF
  render_file "$tmp/stat" 6000
  cat <<'EOF'
</pre>

### Text diff

Binary files are reported as binary; their blob IDs are listed above.

<pre>
EOF
  render_file "$tmp/diff" "${AUR_DIFF_MAX_BYTES:-30000}"
  cat <<'EOF'
</pre>

> AUR content is untrusted input. Do not run its PKGBUILD, install scripts,
> hooks, helper programs, or binary blobs as part of this review.
EOF
)

set_seen() {
  [ $# -eq 2 ] || die "usage: $0 set-seen <pkg> <commit>"
  local pkg=$1 commit=$2 tmp
  valid_pkg "$pkg" || die "invalid package name: $pkg"
  valid_commit "$commit" || die "invalid commit: $commit"
  validate_lock

  tmp=$(mktemp "${LOCK_FILE}.tmp.XXXXXX")
  if ! awk -v wanted="$pkg" -v commit="$commit" '
      BEGIN { found = 0 }
      $1 == wanted { print wanted "\t" commit; found = 1; next }
      { print }
      END { if (!found) exit 4 }
    ' "$LOCK_FILE" > "$tmp"; then
    rm -f "$tmp"
    die "$pkg is not present in $LOCK_FILE"
  fi
  mv "$tmp" "$LOCK_FILE"
}

case "${1:-}" in
  check)
    [ $# -eq 1 ] || usage
    check_all
    ;;
  report)
    shift
    report_change "$@"
    ;;
  set-seen)
    shift
    set_seen "$@"
    ;;
  -h|--help)
    usage 0
    ;;
  *)
    usage
    ;;
esac
