# Publishing maze so users can `apt-get install` it

`debian/` contains a complete, lintian-clean Debian source package. This file
explains how to get it in front of users, and what each route actually costs.

Everything below runs inside a Debian toolchain container. Build that image
once — `packaging/Dockerfile` carries debhelper, devscripts, dput, lintian,
gnupg, git and friends — and every later container starts instantly instead of
reinstalling a hundred packages:

```sh
make docker-image      # once
packaging/devenv.sh    # a shell with the toolchain, repo mounted at /w
```

On a Debian or Ubuntu host you can skip all of that and just install the tools:

```sh
sudo apt-get install -y build-essential debhelper devscripts dput lintian fakeroot
```

## Build and check the package

```sh
make deb      # build/pkg/maze_1.0.0-3_all.deb + .dsc + .changes
make lint     # lintian --pedantic over the .changes
```

`make deb` produces a **source** package (`.dsc`, `.orig.tar.gz`,
`.debian.tar.xz`) as well as the `.deb`, because every repository — Debian, a
PPA, or your own — uploads the source package and builds the binary from it.

## Route 1 — your own apt repository on GitHub Pages (hours, full control)

Nobody has to approve anything and users still type `apt install maze`. The
repository is built by `packaging/build-apt-repo.sh` and served from the
`gh-pages` branch.

**Build and sign it** — inside the toolchain container (`packaging/devenv.sh`),
since the dpkg tooling is not on macOS. The key must be in that container's
keyring (`gpg --import /key.asc`; the named volume keeps it):

```sh
make apt-repo GPG_KEY=B1BA023B35947F8DD1A21EBD952F2FF96C4DE741
```

That writes `build/aptrepo/` and asks for your passphrase once, to sign
`dists/stable/InRelease` and `Release.gpg`.

**Publish it** — on the host, where your git credentials live (the container has
no SSH key):

```sh
make apt-publish
```

This force-pushes the tree to an orphan `gh-pages` branch. Then enable Pages
once:

```sh
gh api --method POST repos/agelospanagiotakis/maze-cli/pages \
    -f 'source[branch]=gh-pages' -f 'source[path]=/'
# if Pages already exists, use --method PUT instead of POST
```

**Users then install with** (signed — no `[trusted=yes]` needed):

```sh
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://agelospanagiotakis.github.io/maze-cli/maze.gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/maze.gpg
echo "deb [signed-by=/etc/apt/keyrings/maze.gpg] https://agelospanagiotakis.github.io/maze-cli stable main" \
    | sudo tee /etc/apt/sources.list.d/maze.list
sudo apt-get update && sudo apt-get install maze
```

Skipping the key and writing `deb [trusted=yes] ...` also works, and the build
prints both variants, but it disables exactly the protection that makes an apt
repository trustworthy — prefer the signed form.

`make check-apt-repo` verifies this whole path in a container: it assembles and
signs a repository, installs from it with verification **on**, proves apt
*refuses* the same repository without the key (so the signature check is really
enforced), checks the unsigned `[trusted=yes]` path, and exercises the
`--publish-only` push against a local bare repository.

## Route 2 — Ubuntu PPA (days, the usual answer for "apt-get install")

Launchpad builds and signs the package for every Ubuntu release you target, and
users get it with two commands. Requires a Launchpad account and a GPG key
registered with it.

```sh
# The changelog distribution must be a series Launchpad knows. `unstable` is
# for Debian; use the Ubuntu series you are targeting, e.g. noble.
dch --distribution noble --force-distribution -m "Build for Ubuntu"

debuild -S -sa            # source package, signed with your GPG key
dput ppa:agelospanagiotakis/maze ../maze_1.0.0-1_source.changes
```

Then users do:

```sh
sudo add-apt-repository ppa:agelospanagiotakis/maze
sudo apt-get update && sudo apt-get install maze
```

Watch the build at `https://launchpad.net/~agelospanagiotakis/+archive/ubuntu/maze`.
Launchpad rejects uploads whose changelog distribution is not present in Ubuntu,
so keep `unstable` only for Debian uploads.

## Route 3 — Debian itself (weeks to months, needs a sponsor)

This is what puts `maze` in Debian proper, from where it also flows into Ubuntu,
and it is a social process as much as a technical one. The ordered version:

**0. Create a GPG key.** Mentors and the archive require signed uploads, and the
key's address must match the changelog's `Maintainer:` field.

```sh
gpg --quick-generate-key "Angelos Panagiotakis <agelospanagiotakis@gmail.com>" rsa4096 sign 2y
gpg --list-secret-keys --keyid-format=long     # note the fingerprint
```

**1. File an ITP** (Intent To Package) against `wnpp`. This is a public claim on
the name, and without it a sponsor will not look at you. `reportbug` is a Debian
tool, so from macOS send it as plain mail — ready-to-send body in
`packaging/submission/itp-bug.txt`:

```
To:      submit@bugs.debian.org
Subject: ITP: maze -- simple auto-generated maze game for the terminal
Body:    the contents of packaging/submission/itp-bug.txt
```

Debbugs reads the pseudo-headers (`Package: wnpp`, `Severity: wishlist`,
`Owner:`) at the top of the body. You get the bug number by return mail.

**2. Register on <https://mentors.debian.net>** and add that GPG fingerprint to
your profile there.

**3. Close the ITP in the changelog**, which also clears the last lintian
warning, and rebuild:

```sh
dch --closes NNNNNN          # the bug number from step 1
./LINUX_DISTRIBUTION_CHECKS.sh
make source                  # source-only upload set: .dsc + .debian.tar.xz + .orig
```

**4. Sign and upload the source package.** `debsign` and `dput` are Linux tools,
so on macOS do this in the toolchain container. Build that image **once** and
every later container starts instantly — no more reinstalling debhelper and
friends on each attempt:

```sh
# once, on the host:
gpg --export-secret-keys --armor B1BA023B35947F8DD1A21EBD952F2FF96C4DE741 > /tmp/maze-key.asc

# once (or let devenv.sh do it automatically):
make docker-image

# every time after that:
packaging/devenv.sh
```

`devenv.sh` mounts the repository at `/w` and keeps GnuPG in a named volume, and
it gets the signing key in there for you: if the key file is missing it exports
your secret key from the host keyring (asking for the passphrase once, on the
host), and if the volume does not have the key yet it imports it. So the shell
opens with the key already usable:

```sh
packaging/devenv.sh
gpg --list-secret-keys                                  # already present
packaging/sign-and-upload.sh B1BA023B35947F8DD1A21EBD952F2FF96C4DE741
dput mentors build/pkg/maze_1.0.0-3_source.changes       # or by hand
```

If a container was started some other way (`docker run --rm -it ... debian:stable`)
it has an empty keyring and `debsign` fails with `No secret key`. Either copy the
key in, or just use `devenv.sh` next time:

```sh
gpg --export-secret-keys --armor B1BA023B35947F8DD1A21EBD952F2FF96C4DE741 > /tmp/maze-key.asc
docker cp /tmp/maze-key.asc <container>:/key.asc         # on the host
gpg --import /key.asc                                    # inside the container
```

Use `make source`, not `make deb`, for the mentors upload. `make deb` builds
binary **and** source, which names the upload `maze_1.0.0-3_<arch>.changes` and
drags a locally built `.deb` along with it. Mentors is a *source* repository and
builds the binary itself, so the file you sign and upload is
`..._source.changes`.

Both `make deb` and `make source` rebuild `build/pkg` from scratch, so the other
one's artifacts disappear when you switch. `make apt-repo` therefore depends on
`make deb` and rebuilds the `.deb` if needed rather than failing.

Pass the full fingerprint to `debsign`, not the 16-character key id: with a key
id it prints "long key IDs are discouraged".

Note on the key: mounting `~/.gnupg` into a container running as root often
fights with the host's `gpg-agent`. Exporting the secret key to a temporary
file, importing it inside the container and deleting the file afterwards is
more reliable — but it does put the private key on disk for that moment, so
prefer a Linux box or VM if you have one, and never commit that file.

Mentors runs lintian and other checks automatically and hosts the result at
`https://mentors.debian.net/package/maze/`.

Before uploading, publish the public half of your key so that mentors and any
sponsor can verify the signature:

```sh
gpg --keyserver hkps://keys.openpgp.org --send-keys B1BA023B35947F8DD1A21EBD952F2FF96C4DE741
gpg --keyserver hkps://keyserver.ubuntu.com --send-keys B1BA023B35947F8DD1A21EBD952F2FF96C4DE741
```

`keys.openpgp.org` mails you a confirmation link and only publishes the uid once
you click it; `keyserver.ubuntu.com` publishes immediately and cannot retract,
so send it deliberately. Uploading to both means a verifier finds you either way.

**4. Request sponsorship (RFS).** Take the template from your Mentors package
page and file it against `sponsorship-requests`; a filled-in version is in
`packaging/submission/rfs-bug.txt`. The [Debian Games
team](https://wiki.debian.org/Games/Team) is a sensible place to ask, since this
is a game.

**5. A Debian Developer reviews and sponsors** the upload. Expect questions
about the description, the man page, the copyright file, and about whether the
game belongs in Debian at all. Answer them on the bug.

**6. The upload goes to the NEW queue**, where an archive admin checks the name,
the licence and file conflicts. Then it lands in `unstable`, migrates to
`testing` after the usual delay, and Ubuntu syncs it from Debian.

### What a reviewer will run, and what it says today

> **The mentors QA page is the authority, not your container.** Two traps, both
> hit in practice:
>
> * A **stable** container is the wrong yardstick — it ships `debian-policy`
>   4.7.2.0 and debhelper 13, while unstable has 4.7.4.1 and 14. Validate with
>   `./LINUX_DISTRIBUTION_CHECKS.sh --image debian:sid`.
> * Even sid's lintian is **not identical to mentors'**. Mentors runs a newer
>   lintian: it reported `W recommended-field ... Priority` for a control file
>   that sid's lintian called `redundant-priority-optional-field`. When the two
>   disagree, satisfy mentors — the sponsor reads that page.
>
> `packaging/check-linux.sh` passes `--display-experimental` so that X tags
> mentors shows (`debian-watch-does-not-check-openpgp-signature`) also appear
> locally instead of being invisible.

Verified against **sid** (`debian-policy` 4.7.4.1, debhelper 14.5):

| Check | Result |
| --- | --- |
| `dput`/archive name collision | no `maze` source or binary package in Debian; no package ships `/usr/games/maze` or `/usr/bin/maze` (checked against the `stable/main` contents index) |
| `lintian --pedantic --display-experimental` | exit 0. Tags: `package-uses-old-debhelper-compat-version 13` (kept deliberately — stable and Ubuntu ship debhelper 13), `redundant-priority-optional-field`, `debian-watch-does-not-check-openpgp-signature`. The Priority field stays anyway, because mentors' newer lintian warns when it is missing |
| `Standards-Version` | 4.7.4.1, matching sid's `debian-policy` |
| `uscan --no-download` | watch file resolves `refs/tags/v1.0.0`; "package is up to date" |
| `autopkgtest <deb> -- null` | `smoke PASS` |
| `dpkg-buildpackage` | builds binary **and** source package; the upstream suite (58 checks) runs via `dh_auto_test` during the build |
| `man --warnings` | no warnings |
| `apt-get install` from a repo | installs `/usr/games/maze` + `man6/maze.6.gz` + docs; plays a level |

The remaining `X` tag means `debian/watch` does not verify an upstream OpenPGP
signature. It can only be cleared by signing release tags (`git tag -s`) and
switching the watch file to `pgpmode=auto` from the next release onwards;
`pgpmode=none` is correct while the existing tags are unsigned.

Be aware of the policy reality: Debian is not a showcase for personal projects.
A tiny game may be declined on the grounds that it does not need to be in
Debian, so routes 1 and 2 are the practical ones — and if the game does get
sponsored later, nothing here has to change.

## Checklist before publishing a new version

```sh
# 1. bump the version in maze.sh, then the changelog
dch -v 1.1.0-1 "New upstream release."

# 2. the Makefile refuses to build when these disagree, but check anyway
make check

# 3. full verification, including the Debian packaging path
./LINUX_DISTRIBUTION_CHECKS.sh      # runs: make check, make test, make check-linux
make source && make lint     # source upload set + lintian

# 4. tag and publish the release with the tarball and checksum
git tag -a v1.1.0 -m "maze 1.1.0" && git push origin v1.1.0
make dist
gh release create v1.1.0 --verify-tag --title "maze 1.1.0" \
  --notes-file NOTES.md build/maze-1.1.0.tar.gz build/maze-1.1.0.tar.gz.sha256

# 5. for a Debian upload, sign and push to mentors
debsign -kB1BA023B35947F8DD1A21EBD952F2FF96C4DE741 build/pkg/maze_1.1.0-1_source.changes
dput mentors build/pkg/maze_1.1.0-1_source.changes
```

Note the version dance: `maze.sh`'s `VERSION` and `debian/changelog`'s upstream
version must always agree (the Makefile enforces this), and `debian/changelog`
carries the `-1` Debian revision on top.
