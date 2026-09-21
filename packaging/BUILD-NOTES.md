# How the `.deb` and our own apt repository were built

Notes from going "one bash script on GitHub" → "a lintian-clean Debian source
package" → "a signed apt repository that serves `apt install maze`". Written
while it was fresh, including everything that went wrong, because the mistakes
are the useful part.

Companion documents: [`PUBLISHING.md`](PUBLISHING.md) is the how-to for
publishing routes, [`submission/README.md`](submission/README.md) covers the
Debian bug-tracker templates, and the repository root `README.md` documents
installation for users.

---

## What exists now

| Piece | Where | What it is |
| --- | --- | --- |
| The game | `maze.sh` | One bash script, no dependencies |
| Debian source package | `debian/` | What Debian/Ubuntu/PPAs/apt repos consume |
| Man page | `maze.1` | Section 6, `maze(6)` |
| Toolchain image | `packaging/Dockerfile` | debhelper, devscripts, dput, lintian, gnupg, git … |
| Build/publish scripts | `packaging/*.sh` | Repo assembly, verification, signing, publishing |
| Published apt repo | `gh-pages` branch | <https://agelospanagiotakis.github.io/maze-cli> |
| Debian submission | bugs #1148567, #1148569 | ITP filed, uploaded to mentors, RFS filed |

Versions in play: package `maze 1.0.0-3`, signing key
`B1BA023B35947F8DD1A21EBD952F2FF96C4DE741` (rsa4096, sign-only, expires 2028-09-19).

---

## Part 1 — From one script to a Debian source package

### Why a *source* package

Every apt-facing destination (Debian, Ubuntu PPAs, mentors, our own repo that
we build binaries from) takes a **source** package: `.dsc` + `.orig.tar.gz` +
`.debian.tar.xz`. The binary `.deb` is either built by their buildds or by us
locally. So `debian/` is the real deliverable, and `dpkg-buildpackage` gets to
produce both.

### `debian/`, file by file

| File | Purpose | Notes specific to this package |
| --- | --- | --- |
| `control` | Metadata + build deps | `Architecture: all` (no compilation); `Depends: bash (>= 3.2)`; `Section: games`; `Priority: optional` |
| `changelog` | Version history | `1.0.0-3`, `unstable`, `Closes: #1148567` |
| `copyright` | DEP-5 machine-readable | `GPL-3.0-or-later`, pointing at `/usr/share/common-licenses/GPL-3` |
| `rules` | Build recipe | `dh $@` plus an `override_dh_auto_install` that installs the two files |
| `source/format` | Source format | `3.0 (quilt)` — the non-native format |
| `watch` | Upstream tracking | `mode=git` on the GitHub repo, tag pattern `v?(\d[\d.]*)` |
| `tests/` | autopkgtest | `smoke`: runs the installed program and wins level 1 |
| `docs` | Extra docs | `README.md` only — **not** `LICENSE` (see pitfalls) |
| `upstream/metadata` | DEP-12 | Repository/Bug-Submit URLs |

### Layout decisions worth remembering

* **`/usr/games/maze` + section 6 man page.** Debian's convention for games;
  `lintian` complains (`package-section-games-but-contains-no-game`) if a
  `Section: games` package ships nothing in `/usr/games`. `/usr/games` is on the
  default login `PATH` via `ENV_PATH` in `login.defs`, so `maze` still just works.
* **`Architecture: all`.** It is a script. That is also why the repository uses a
  `binary-all` index (see Part 3).
* **debhelper compat 13, not 14.** sid ships 14 and `lintian --pedantic` flags 13
  as old, but stable and Ubuntu ship 13 — keeping 13 means it builds on both. It
  is a style tag, not an error.
* **`Rules-Requires-Root: no` was removed**: current policy makes it the default,
  and lintian called it redundant.

### Building it

```sh
make deb        # binary + source: maze_1.0.0-3_all.deb, .dsc, .debian.tar.xz, .orig.tar.gz
make source     # source-only (-S -sa): maze_1.0.0-3_source.changes  <- for mentors
make lint       # lintian --pedantic
```

`make deb` stages an upstream tree into `build/pkg/maze-1.0.0/`, builds the
`orig.tar.gz` from it, copies `debian/` in, and runs `dpkg-buildpackage` there —
so artifacts land in `build/pkg/` and nothing pollutes the repo root.

Three details that matter:

1. **`make deb` and `make source` both rebuild `build/pkg` from scratch**, so each
   destroys the other's artifacts. `make apt-repo` therefore *depends on* `make deb`
   and rebuilds the `.deb` if needed rather than failing with "no .deb".
2. **`make source`, not `make deb`, for mentors.** A binary+source build names the
   upload `maze_1.0.0-3_arm64.changes` and drags a local `.deb` along; mentors is a
   source repository and builds the binary itself.
3. **The changelog drives the version.** The Makefile reads `DEBVERSION` from
   `debian/changelog` and compares its upstream part with `VERSION` in `maze.sh`,
   so `make check` catches drift and no revision number is hardcoded anywhere.

### What a reviewer checks — and what it says here

| Check | Result |
| --- | --- |
| `lintian --pedantic --display-experimental` | exit 0; tags: debhelper-compat 13 (pedantic), redundant-priority-optional-field (pedantic), `debian-watch-does-not-check-openpgp-signature` (experimental) |
| `uscan --no-download` | watch file resolves `refs/tags/v1.0.0`; "package is up to date" |
| `autopkgtest <deb> -- null` | `smoke PASS` |
| `man --warnings` | no warnings |
| `dpkg-buildpackage` | builds binary + source; upstream's 58 checks run via `dh_auto_test` |
| mentors QA page | `+ Package has lintian experimental tags`, closes ITP, DEP5 copyright |

**Validate against sid, not stable.** Stable ships `debian-policy` 4.7.2.0 and
debhelper 13; unstable has 4.7.4.1 and 14. A package that looks clean on stable
came back from mentors with `out-of-date-standards-version` — that is how
`Standards-Version: 4.7.4.1` was settled on.

**The mentors QA page outranks your local lintian.** Mentors runs a newer
lintian than any image here: it reported `W recommended-field … Priority` for a
control file that sid's own lintian called `redundant-priority-optional-field`.
Removing `Priority` "to be tidy" turned a cosmetic page into a warning. When the
two disagree, satisfy mentors.

---

## Part 2 — Signing and the Debian submission

1. **Key.** `gpg --quick-generate-key "…" rsa4096 sign 2y`. Address must match the
   changelog `Maintainer:`. Publish the public half to `keys.openpgp.org` (click
   the confirmation mail, or the uid is not published) and `keyserver.ubuntu.com`.
2. **ITP** → email to `submit@bugs.debian.org`, body starting with
   `Package: wnpp` (bug #1148567). Templates in `submission/`.
3. **Upload to mentors.** `debsign -k<40-hex fingerprint> …_source.changes` then
   `dput mentors …`. Use the *fingerprint*, not the 16-char id: debsign warns
   "long key IDs are discouraged".
4. **RFS** → `sponsorship-requests` (#1148569), referencing the ITP and the
   uploaded version.

Mentors' own quirks, learned the hard way:

* Its pool only serves the **current** version — older `.dsc` URLs start
  returning 404 once superseded. Not a failure.
* Processing takes minutes (3 min for one upload, ~12 min for another). A 404
  right after upload means "not yet", not "rejected". The email is the verdict.
* The QA page shows **all** uploads, each with its own lintian tags — so a bad
  version stays visible. Superseding it with a better one is the fix.

---

## Part 3 — Our own apt repository

### Anatomy

```
gh-pages/
├── dists/stable/
│   ├── Release            # checksums of the indexes below
│   ├── Release.gpg        # detached signature of Release
│   ├── InRelease          # clearsigned Release (apt prefers this)
│   └── main/binary-all/
│       ├── Packages       # package index (Filename, SHA256, Depends …)
│       └── Packages.gz
├── pool/main/m/maze/maze_1.0.0-3_all.deb
├── maze.gpg               # exported public key, for the curl line
├── index.html             # instructions for humans landing on the URL
└── .nojekyll              # stop GitHub Pages' Jekyll touching it
```

The trust chain is `Release` (signed) → `Packages` (checksummed in Release) →
`.deb` (checksummed in Packages). `[signed-by=/etc/apt/keyrings/maze.gpg]` in the
user's `sources.list` is what makes apt enforce it.

`Architectures: all` with only a `binary-all/` index is correct for an
`Architecture: all` package, and apt resolves it on any host architecture —
verified, not assumed.

### Building it

```sh
make apt-repo GPG_KEY=B1BA023B35947F8DD1A21EBD952F2FF96C4DE741
```

That runs `packaging/build-apt-repo.sh`, which:

1. finds the `.deb` (default `build/pkg/maze_<ver>_all.deb`),
2. lays out `pool/`, `dists/stable/main/binary-all/`,
3. runs `dpkg-scanpackages` from the repository root so paths are relative,
4. runs `apt-ftparchive release` **from the repository root** (`--out` may point
   elsewhere; apt-ftparchive resolves its argument relative to the CWD),
5. with `--key`, produces `Release.gpg` + `InRelease` and exports `maze.gpg`,
6. writes `.nojekyll` and an `index.html` containing the exact user commands.

Without `--key` it still produces a working repository, but then users need
`[trusted=yes]` and the whole point of the signature is gone — prefer signed.

### Publishing

Publishing is deliberately a **separate step on the host**, because the
toolchain container has no ssh client and no credentials:

```sh
# container (dpkg tooling + signing key):
make apt-repo GPG_KEY=…
# host (git + ssh credentials):
make apt-publish
```

`--publish-only` pushes the already-built tree to an orphan `gh-pages` branch.
Then enable Pages once:

```sh
gh api --method POST repos/agelospanagiotakis/maze-cli/pages \
    -f 'source[branch]=gh-pages' -f 'source[path]=/'
```

`build/` is gitignored, so neither the repository tree nor the `.git` it creates
inside it ever touches `main`.

### Client side

```sh
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://agelospanagiotakis.github.io/maze-cli/maze.gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/maze.gpg
echo "deb [signed-by=/etc/apt/keyrings/maze.gpg] https://agelospanagiotakis.github.io/maze-cli stable main" \
    | sudo tee /etc/apt/sources.list.d/maze.list
sudo apt-get update && sudo apt-get install maze
```

Releases are snapshots: after cutting a new version, re-run `make apt-repo` and
`make apt-publish`; users pick it up with `apt update && apt upgrade`. Old debs
stay in the pool (harmless — apt installs the highest version).

---

## Part 4 — Verification we actually ran

Everything below was executed, not assumed.

**`make check-apt-repo`** (container, throwaway key, six steps):

1. builds the `.deb`, assembles a signed repository
2. checks the layout and the integrity chain
3. `apt-get install` with **signature verification on** → `1.0.0-3` installed
4. **negative test:** without the key, apt refuses (`not signed`) — proof the
   signature check is enforced rather than decorative
5. unsigned repository with `[trusted=yes]` also installs
6. `--publish-only` against a local bare repo creates a correct `gh-pages` tree

**The published repository** (clean Debian container, the exact README/index.html
commands, against the real HTTPS URL):

```
key imported            → keyring written: 1211 bytes
apt-get update          → ok
apt-get install maze    → maze 1.0.0-3 install ok installed
                          /usr/games/maze  /usr/share/man/man6/maze.6.gz
plays a level           → Level 1 cleared in 23 moves
without the key         → apt refused: "not signed"
```

All seven published files return HTTP 200.

**`./LINUX_DISTRIBUTION_CHECKS.sh`** — one entry point, four steps: version
consistency, the game's 58-check suite, the Debian packaging gate (tarball →
lintian → uscan → autopkgtest → apt repo), and the apt repository gate. Exit 0
means everything passed; exit 2 means the container steps could not run (missing
Docker), so an incomplete run can never masquerade as a green one.

---

## Part 5 — Everything that bit us

Ordered roughly by how long it cost.

### Debian packaging

* **`debian/docs` contained a literal `README.md\n`.** A `printf 'README.md\n'`
  written through a shell quoting layer produced backslash-n, which would have
  made `dh_installdocs` look for a file with that name. Caught by `od -c`. Always
  verify generated files byte-wise when a heredoc/printf is involved.
* **Shipping `LICENSE` in `debian/docs`** trips lintian's `extra-license-file`.
  The DEP-5 copyright plus `/usr/share/common-licenses/GPL-3` already satisfies
  the GPL, so only `README.md` is shipped.
* **Removing `Priority: optional` made mentors warn** while local sid lintian
  called it redundant (see Part 1). Reverted in `1.0.0-3`.
* **`make source` deleted the `.deb`** that `make apt-repo` needed, and the
  script's clear error was hidden by a `grep` in my own test. Fixed by making
  `apt-repo` depend on `deb`.
* **`dpkg-buildpackage` failing with `unmet build dependencies: debhelper-compat`
  just means debhelper is not installed** — build in the toolchain image.

### Keys, containers and signing

* **`docker run --rm` starts with an empty keyring.** Every fresh container needs
  the key; that is the entire reason `devenv.sh` exists.
* **Importing a passphrase-protected key without a TTY** fails with
  `error sending to agent: Inappropriate ioctl for device`. The import container
  needs `-it`.
* **Stale `S.gpg-agent*` sockets** left in the keyring volume make gpg try to talk
  to a dead agent. `devenv.sh` removes them before importing.
* **Piping a TTY container's output through `sed`** hides `pinentry`'s passphrase
  prompt, and the import then waits forever for input that is never displayed.
  Never pipe a container whose TTY you need.
* **`debsign -k<FINGERPRINT>`** — pasting an angle-bracket placeholder literally
  makes bash read it as an input redirect (`No such file or directory`). All
  placeholders were replaced with the real fingerprint.
* **Publishing inside the container cannot work**: no `ssh`, no credentials →
  `error: cannot run ssh`. `--publish` now detects this and says so instead of
  letting git fail after the commit.
* **`fatal: empty ident name`** when the publishing checkout has no git identity:
  falls back to `debian/control`'s Maintainer, then to a placeholder.
* **Non-idempotent publish**: a first attempt that committed and then failed to
  push left a tree where `git commit` found nothing to commit and exited
  non-zero, so *every retry failed*. Now it commits only when something is
  staged, and uses `git symbolic-ref` instead of `git init --initial-branch`
  (which warned `re-init: ignored --initial-branch=gh-pages`).

### Repository mechanics

* **`apt-ftparchive release dists/stable` failed with "Failed to resolve
  dists/stable"** because it resolves relative to the CWD and `--out` pointed
  elsewhere. Fixed by running it from the repository root.
* **`--publish-only` pushed nothing** because the publish block had ended up
  *inside* the assembly branch. Restructured.
* **`PUBLISH_ONLY: unbound variable`** — `set -u` and a variable that was only
  assigned in one code path.
* **`dput` was missing from the toolchain image** because
  `--no-install-recommends` skips devscripts' Recommends. Added explicitly.
* **Lintian's `Release` paths are relative to `dists/<dist>/`**, e.g.
  `main/binary-all/Packages`, not `dists/stable/main/binary-all/Packages` — my
  first assertion checked the wrong string.

### Environment

* **Docker throwing `Input/output error` mid-unpack, and refusing to start**,
  was not a Dockerfile bug: the host data volume was at **98 %** (14 GB free).
  A nearly full disk makes Docker's VM writes fail and can corrupt its disk
  image. Check `df -h /System/Volumes/Data` and `docker system df` before
  blaming the build; prefer `docker builder prune` over destructive prunes when
  other projects' images are present.
* **mentors' pool 404s for a superseded version**, and processing lag of minutes,
  are both normal.

---

## Command cheat sheet

```sh
# toolchain (once)
make docker-image
packaging/devenv.sh                     # shell with everything, key auto-imported
MAZE_DEV_CMD='make test' packaging/devenv.sh   # one-off command

# build
make check            # syntax + version agreement between maze.sh and debian/changelog
make test             # the game's 58 checks
make deb              # .deb + .dsc + .debian.tar.xz + .orig.tar.gz
make source           # source-only upload set (.changes) for mentors
make lint             # lintian --pedantic

# apt repository
make apt-repo GPG_KEY=B1BA023B35947F8DD1A21EBD952F2FF96C4DE741
make apt-publish                        # on the host: push to gh-pages
make check-apt-repo                     # verify the whole path in a container

# everything
./LINUX_DISTRIBUTION_CHECKS.sh          # 0 = pass, 1 = fail, 2 = container steps skipped
```
