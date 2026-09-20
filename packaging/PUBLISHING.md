# Publishing maze so users can `apt-get install` it

`debian/` contains a complete, lintian-clean Debian source package. This file
explains how to get it in front of users, and what each route actually costs.

Everything below assumes the tooling:

```sh
sudo apt-get install -y build-essential debhelper devscripts lintian fakeroot
```

## Build and check the package

```sh
make deb      # builds ../build/pkg/maze_1.0.0-1_all.deb + .dsc + .changes
make lint     # lintian --pedantic over the .changes
```

`make deb` produces a **source** package (`.dsc`, `.orig.tar.gz`,
`.debian.tar.xz`) as well as the `.deb`, because every repository — Debian, a
PPA, or your own — uploads the source package and builds the binary from it.

## Route 1 — your own apt repository (hours, full control)

Nobody has to approve anything and users still type `apt install maze`.

```sh
# On a host that serves HTTPS (GitHub Pages works):
mkdir -p /srv/aptrepo && cp build/pkg/*.deb /srv/aptrepo/
cd /srv/aptrepo
dpkg-scanpackages -m . /dev/null > Packages
gzip -kf Packages
```

Then on the user's machine:

```sh
echo "deb [trusted=yes] https://example.org/aptrepo ./" | sudo tee /etc/apt/sources.list.d/maze.list
sudo apt-get update && sudo apt-get install maze
```

`[trusted=yes]` skips signature checking. That is fine for a single maintainer
over HTTPS but it is not what distributions or cautious users want — sign the
repository instead (GPG key, `Release` file, `InRelease`, and users importing
your key), or publish through a PPA (route 2), which does the signing for you.

`make check-linux` performs exactly this route inside a container: it builds the
package, serves it from a local repo and installs it with `apt-get`.

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
and it is a social process as much as a technical one:

1. **File an ITP** (Intent To Package) bug against `wnpp`:
   `reportbug wnpp` → "ITP: maze -- simple auto-generated maze game for the terminal".
   This is a public claim on the name; without it a sponsor will not look at you.
2. **Register on <https://mentors.debian.net>** and upload the *signed* source
   package there (`debsign` with your GPG key, then `dput mentors <changes>`).
   Mentors checks your package automatically and hosts it for review.
3. **Request sponsorship (RFS)**: take the RFS template from your Mentors package
   page and file it as a bug against `sponsorship-requests`.
4. **A Debian Developer reviews and sponsors** the upload. Expect review comments
   about naming, the description, the man page, the copyright file and so on.
5. **The upload goes to the NEW queue** where an archive admin checks the name,
   the licence and file conflicts — this is where a clashing `/usr/bin/maze`
   would be caught. Then it lands in `unstable`, migrates to `testing` after the
   usual delay, and Ubuntu syncs it from Debian.

Useful facts already handled in this tree: the package is `Architecture: all`,
`Rules-Requires-Root: no`, has a DEP-5 `debian/copyright`, a `debian/watch`, an
autopkgtest under `debian/tests/`, a section 6 manual page and a clean
`lintian --pedantic`. The one remaining lintian warning is
`initial-upload-closes-no-bugs`, which disappears as soon as the changelog
closes the ITP bug.

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
make test && make check-linux
make deb && make lint

# 4. tag and publish the release with the tarball and checksum
git tag -a v1.1.0 -m "maze 1.1.0" && git push origin v1.1.0
make dist
gh release create v1.1.0 --verify-tag --title "maze 1.1.0" \
  --notes-file NOTES.md build/maze-1.1.0.tar.gz build/maze-1.1.0.tar.gz.sha256
```
