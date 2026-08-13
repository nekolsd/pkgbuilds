# nekolsd

A personal Arch Linux package repository.

The recipes started as a snapshot of their AUR counterparts. Updates are found by
asking each vendor directly (Google's version API, GitHub releases, npm, ...), built
and signed by GitHub Actions, and published to Cloudflare R2. AUR is not part of the
build path.

## Using it

```ini
# /etc/pacman.conf
[nekolsd]
SigLevel = Required DatabaseRequired
Server = https://repo.lsd.moe/archlinux/$arch
```

```bash
sudo pacman-key --recv-keys CEFA64B7B1308F2ECB404D423D02D08ED532F9C7
sudo pacman-key --lsign-key CEFA64B7B1308F2ECB404D423D02D08ED532F9C7
```

## Packages

`1password` · `64gram-desktop-bin` · `claude-code` · `google-chrome` ·
`helium-browser-bin` · `pac-pacman-aliases` · `protonplus` · `speedtest-go` ·
`vicinae-bin` · `visual-studio-code-bin` · `wemeet-bin`

## Maintenance

Official vendor endpoints and the local recipes have separate responsibilities:

- At **02:00 Asia/Singapore**, `autobump.yml` asks nvchecker only for official
  vendor versions. Each outdated package gets its own `autobump/<package>` PR.
- The updater changes the configured version field, resets `pkgrel`, downloads the
  local recipe's official sources, and recalculates checksums. `shfmt` parses the
  old and new PKGBUILDs; `update-policy.json` declares exactly which release fields
  and remote checksum slots may differ.
- Every candidate is built without repository, signing, or R2 credentials. The PR
  is merged manually at first; `automerge` is deliberately disabled per package.
- A merge builds only the affected package. Builds run as an independent matrix,
  so one failure does not prevent successful packages from being signed and
  published. `nvchecker-old.json` advances only after R2 publication succeeds.

`build.sh` remains the local build utility; run it with no arguments for its
subcommands. AUR is never part of official version discovery or checksum creation.

### Importing a new AUR package

Open **Actions → Import a new package from AUR → Run workflow**, then enter the
exact AUR package base name. The workflow copies every tracked file from the
current AUR `master` into a new package directory, records that commit in
`aur-seen.lock`, and opens a Draft PR. Nothing from the candidate tree is sourced,
built, or executed during the import.

The PR is deliberately not merge-ready. Review every source URL and function in
`PKGBUILD`, all install scripts and pacman hooks, every executable/symlink, and any
binary blob. Before merging, remove unneeded AUR-only files, add an official-vendor
source to `nvchecker.toml`, seed the same version in `nvchecker-old.json`, and make
the accepted commit signed. If no vendor endpoint is available, document the
manual update plan instead of silently making AUR the update source.

At **18:00 Asia/Singapore**, `aur-watch.sh` is a separate, read-only observer.
`aur-seen.lock` records the previous AUR commit. The watcher compares that AUR tree
with the new AUR tree -- not the permanently customized local recipe -- and never
checks out, sources, builds, or executes AUR content.

The same parsed-IR policy removes comments/positions and masks only configured
release values. `source` templates, checksum-array shape, local patch checksum
slots, dependencies, functions, auxiliary files, symlinks, and modes remain part of
the comparison:

- A release-only or semantic-no-op change advances `aur-seen.lock` automatically
  and appears only in the Actions summary.
- A packaging change or an unparseable/unsupported construct opens one Draft Review
  PR for that package with the complete tree-level object list and text diff.
- A matching AUR Review PR keeps an official autobump PR in Draft. Port any useful
  packaging change by hand, rebuild, then merge the review baseline. AUR versions
  never upgrade or downgrade the local recipe automatically.

When packaging changes without `pkgver` changing, increment `pkgrel` so clients see
the rebuilt package as an upgrade.

`SETUP-CI.md` documents the CI and R2 setup.
