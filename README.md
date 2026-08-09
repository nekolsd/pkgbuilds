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

`build.sh` handles vendor-driven version checks and builds; run it with no arguments
for the full list of subcommands. This path does not depend on AUR, so an AUR outage
or push freeze cannot stop package updates.

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

`aur-watch.sh` is a separate, read-only observer. `aur-seen.lock` records the last
reviewed AUR commit for each package, and any later commit opens a Draft PR with the
complete tree-level change list (file modes and blob IDs) plus a text diff. The
watcher never checks out or materializes candidate files in the package tree; it
reads them only as objects in a temporary bare Git repository and never sources,
builds, or executes them.
Merging one of those PRs acknowledges the new AUR position even when no local change
is adopted; useful recipe changes must be ported to the local package explicitly.
Any reviewed file change inside a package directory then rebuilds that package after
it reaches `main`; when the upstream version is unchanged, increment `pkgrel` so
clients see the replacement as an upgrade. Closing a PR without merging deliberately
keeps the old position, so the watcher will continue to report that unacknowledged
commit.

`SETUP-CI.md` documents the CI and R2 setup.
