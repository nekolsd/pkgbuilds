# CI build and R2 distribution

GitHub Actions proposes vendor updates, builds packages independently, signs
successful artifacts, and pushes them to Cloudflare R2, so the desktop side only
ever runs `pacman -Syu`.

## 1. GPG key

```
primary  CEFA64B7B1308F2ECB404D423D02D08ED532F9C7   ed25519 [C] no expiry
CI key   B72D9AFDD20D3A9C                           ed25519 [S] until 2027-08-08
```

Created with (fish syntax):

```fish
gpg --quick-generate-key "nekolsd <nekolsd@proton.me>" ed25519 cert never
set KEYFP (gpg --list-secret-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')
gpg --quick-add-key $KEYFP ed25519 sign 1y

gpg --export-secret-subkeys --armor 'B72D9AFDD20D3A9C!' > /tmp/ci-subkey.asc   # the ! matters
gpg --export --armor $KEYFP > /tmp/pubkey.asc
```

The primary key can only certify (`cert`), not sign — its whole job is issuing and
revoking subkeys. Packages are signed by the subkey, and a subkey is revocable: if
it ever leaks from GitHub, revoke it with the primary, issue a new one, re-sign, and
the identity itself is untouched.

### Verifying that only the subkey was exported

**Do not use `gpg --show-keys` for this** — reading a file it does not print the `#`
marker, so it cannot tell you whether the primary is in there. Look at the packets:

```fish
gpg --list-packets /tmp/ci-subkey.asc | grep -iE 'gnu-dummy|secret|keyid'
```

A correct export looks like:

```
:secret key packet:
	gnu-dummy, algo: 0             ← primary is a stub, no key material in the file
	keyid: 3D02D08ED532F9C7
:secret sub key packet:
	iter+salt S2K, SHA1 protection ← subkey is present, passphrase-encrypted
	keyid: B72D9AFDD20D3A9C
```

`gnu-dummy` on the primary line is what you want. If it shows real S2K/protect
parameters instead, the primary was exported — delete the file and start over.

## 2. Cloudflare R2

1. R2 → create a bucket
2. bucket → Settings → **Custom Domain** → bind `repo.lsd.moe`
   (not the default `*.r2.dev`, which is rate limited and which Cloudflare says is
   not for production)
3. R2 → **Manage API Tokens** → create a token with **Object Read & Write**,
   scoped to that one bucket. Note the Access Key ID and Secret Access Key.
4. The account ID is on the R2 overview page.

## 3. GitHub secrets

Settings → Secrets and variables → Actions:

| Secret | Value |
|---|---|
| `GPG_SIGNING_KEY` | the **entire** contents of `/tmp/ci-subkey.asc` |
| `GPG_PASSPHRASE` | the passphrase for that key |
| `GPG_KEY_ID` | `B72D9AFDD20D3A9C` |
| `R2_ACCOUNT_ID` | Cloudflare account ID |
| `R2_ACCESS_KEY_ID` | from the R2 token |
| `R2_SECRET_ACCESS_KEY` | from the R2 token |
| `R2_BUCKET` | bucket name |

Also enable Settings → Actions → General → **Read and write permissions** and
**Allow GitHub Actions to create and approve pull requests**, or `autobump.yml`,
`aur-watch.yml`, and `aur-import.yml` cannot create their PRs.

Then `shred -u /tmp/ci-subkey.asc`.

### What those secrets can reach

The vendor update workflow has two trust phases. `detect` queries configured
official endpoints. Each `autobump` matrix job changes one local recipe, downloads
its declared sources, recalculates checksums, and uses shfmt's Bash syntax tree plus
`update-policy.json` to classify the exact change. Checkout credentials are not
persisted and `GH_TOKEN` is exposed only in the final PR-writing step, after source
preparation has finished. An AUR packaging review can only make that PR Draft; AUR
does not supply any written field.

The build workflow first validates every parsed update contract and test. Each
package first gets an independent, unprivileged metadata-policy matrix job, then an
independent credential-free build matrix job. Its expected package names and versions
are uploaded before the build starts. The publisher downloads that original policy
again instead of accepting any policy returned by a build job (whose package code can
invoke `sudo pacman`). A fresh `publish` job downloads only successful matrix
artifacts, validates every file set, SHA-256 manifest, Arch package name, and version,
then combines those successes. Only the subsequent step receives the GPG and R2
secrets. One failed matrix package therefore cannot block successful siblings.

The final `record` job receives no package content and executes no PKGBUILD. It has
`contents: write`, validates a strict package/version TSV, and advances only the
`version` fields in `nvchecker-old.json` after the R2 step succeeds. If publication
fails, the old value remains and the next vendor run dispatches a package-specific
retry. Vendor output is still a trust decision -- checksum verification identifies
bytes but does not make vendor code harmless -- but downloaded code cannot read the
long-lived publishing credentials while it runs.

Autobump branches are built through an explicit `workflow_dispatch`, because
GitHub deliberately suppresses recursive `push`/`pull_request` runs created by
`GITHUB_TOKEN`. The build workflow checks the dispatched branch commit but has a
separate hard gate: signing and R2 publication are possible only for a `push` to
`main` or a manual dispatch whose ref is exactly `refs/heads/main`.

## 4. Seeding R2

The first CI run produces nothing on its own: the nvchecker baseline is already
current, so `--outdated` reports everything up to date while R2 sits empty.

Build the complete signed repository locally once and upload it; CI only does
increments after that.

```fish
rclone sync --copy-links /var/cache/pkgrepo r2:<bucket>/archlinux/x86_64 --progress
```

Local rclone config (`~/.config/rclone/rclone.conf`):

```ini
[r2]
type = s3
provider = Cloudflare
access_key_id = <R2 Access Key ID>
secret_access_key = <R2 Secret>
endpoint = https://<account id>.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
```

`--copy-links` matters: `repo-add` creates `nekolsd.db` as a symlink, object storage
has no symlinks, and rclone skips them by default — while `nekolsd.db` is exactly
what pacman requests.

## 5. Desktop side

```bash
sudo pacman-key --add /tmp/pubkey.asc
sudo pacman-key --lsign-key CEFA64B7B1308F2ECB404D423D02D08ED532F9C7
```

```ini
# /etc/pacman.conf
[nekolsd]
SigLevel = Required DatabaseRequired
Server = https://repo.lsd.moe/archlinux/$arch
```

The `archlinux/` prefix mirrors the object path `<bucket>/archlinux/x86_64/`; the
domain is a generic `repo.`, and the prefix leaves room for other things in the same
bucket later.

`Required DatabaseRequired` demands a trusted signature on both packages and the
database. That is mandatory once distribution goes over the network: the
`Optional TrustAll` that was fine for a local `file://` repo would let anyone who can
intercept the connection hand you arbitrary packages, which pacman then installs as
root.

## 6. The local repository

Once R2 is live, `/var/cache/pkgrepo` is redundant and can be deleted. Keeping the
ability to build locally is still worthwhile though (`build.sh` without
`BUILD_BACKEND` uses the chroot backend) — useful when CI is down or a one-off
patched build is needed.

## Notes

- **The subkey expires 2027-08-08.** Issue a new one with `gpg --quick-add-key`
  before then and update `GPG_SIGNING_KEY` / `GPG_KEY_ID`, or CI signing breaks.
- **Schedule order.** Parsed AUR review runs at 18:00 Asia/Singapore. Official
  vendor detection runs eight hours later at 02:00, giving structural AUR signals
  time to gate only their matching autobump package.
- **Concurrency** is capped: publishers cannot rewrite R2 simultaneously, vendor
  detectors do not race on an autobump branch, and AUR checks do not race while
  updating review baselines. Pull-request builds use separate per-PR groups.
- **Upload order** is packages first, database last, so a failure halfway leaves the
  index pointing at versions that are all still present.
- **AUR is advisory only.** `aur-watch.yml` parses old/new AUR PKGBUILDs from bare
  Git objects. Release-only changes are acknowledged without PRs; additional files,
  structural IR differences, and unknown syntax open Draft reviews. No AUR object
  is checked out, sourced, built, or executed, and AUR failures do not affect the
  vendor workflow.
- **New-package imports are review candidates, not updates.** Run
  **Import a new package from AUR** manually with an exact package base name. Its
  complete tracked AUR tree is copied into a package directory and shown in a
  Draft PR; no candidate file is executed by the importer. Review that tree, then
  configure `nvchecker.toml` and `nvchecker-old.json` from the official vendor and
  sign the final accepted commit before merging.
- **Reviewed local recipe changes rebuild the affected package.** This includes
  install scripts, pacman hooks, patches, wrappers, and nested files as well as
  `PKGBUILD`. Increment `pkgrel` when changing packaging without changing
  `pkgver`, otherwise installed clients have no newer version to upgrade to.
- **Manual update checks.** Run **Check official vendor updates** with an optional
  space-separated package filter. This creates/updates one autobump PR per official
  update and never publishes directly.
- **Manual rebuilds.** In **Build and publish to R2**, set `packages` to a list such
  as `1password pac-pacman-aliases`. It rebuilds those immutable local recipes in
  separate matrix jobs and bypasses version discovery. Leaving it blank retries
  versions already merged to `main` but not yet recorded as successfully published.
