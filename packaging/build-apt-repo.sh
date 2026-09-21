#!/usr/bin/env bash
#
# build-apt-repo.sh - assemble an apt repository from the built .deb.
#
#   packaging/build-apt-repo.sh                          # unsigned repo tree
#   packaging/build-apt-repo.sh --key B1BA023B35947F8DD1A21EBD952F2FF96C4DE741      # signed (InRelease)
#   packaging/build-apt-repo.sh --publish                # build, sign and push
#   packaging/build-apt-repo.sh --publish-only           # push an existing tree
#
# Output goes to build/aptrepo/ with this layout:
#
#   dists/stable/Release[.gpg]        repository metadata (signed if --key)
#   dists/stable/InRelease            clearsigned Release
#   dists/stable/main/binary-all/Packages[.gz]
#   pool/main/m/maze/maze_<ver>_all.deb
#   index.html, .nojekyll             for GitHub Pages
#
# Requires dpkg-scanpackages and apt-ftparchive (dpkg-dev + apt-utils):
#   apt-get install -y dpkg-dev apt-utils
#
# Copyright (C) 2026 Angelos Panagiotakis
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"

NAME=maze
DIST=stable
COMPONENT=main
ARCH=all
OUT="$REPO/build/aptrepo"
URL="https://agelospanagiotakis.github.io/maze-cli"
KEY=""
PUBLISH=0
PUBLISH_ONLY=0
DEB=""

while (( $# )); do
    case "$1" in
        --key) KEY="${2:?--key needs a fingerprint}"; shift 2 ;;
        --key=*) KEY="${1#*=}"; shift ;;
        --deb) DEB="${2:?--deb needs a path}"; shift 2 ;;
        --deb=*) DEB="${1#*=}"; shift ;;
        --url) URL="${2:?--url needs a value}"; shift 2 ;;
        --url=*) URL="${1#*=}"; shift ;;
        --dist) DIST="${2:?--dist needs a value}"; shift 2 ;;
        --out) OUT="${2:?--out needs a value}"; shift 2 ;;
        --publish) PUBLISH=1; shift ;;
        --publish-only) PUBLISH=1; PUBLISH_ONLY=1; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

VERSION=$(sed -n '1s/.*(\(.*\)).*/\1/p' debian/changelog)
UPSTREAM=${VERSION%%-*}
[[ -n $DEB ]] || DEB="$REPO/build/pkg/${NAME}_${VERSION}_${ARCH}.deb"

# --publish-only pushes an already-built tree, so the publishing step can run
# where git credentials live (e.g. your Mac) instead of inside the container
# that has the dpkg tooling but no SSH key.
if (( PUBLISH_ONLY )); then
    [[ -d $OUT/dists/$DIST ]] || {
        echo "nothing to publish: $OUT/dists/$DIST does not exist" >&2
        echo "build it first with: packaging/build-apt-repo.sh --key B1BA023B35947F8DD1A21EBD952F2FF96C4DE741" >&2
        exit 1
    }
    echo "== publishing the existing repository in $OUT =="
else

for tool in dpkg-scanpackages apt-ftparchive; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "$tool not found: apt-get install -y dpkg-dev apt-utils" >&2
        exit 1
    }
done

[[ -f $DEB ]] || {
    echo "no .deb at $DEB" >&2
    echo "build one first:  make deb" >&2
    exit 1
}

echo "== assembling apt repository for $VERSION =="
rm -rf "$OUT"
POOL="$OUT/pool/main/${NAME:0:1}/$NAME"
BINDIR="$OUT/dists/$DIST/$COMPONENT/binary-$ARCH"
mkdir -p "$POOL" "$BINDIR"

install -m 644 "$DEB" "$POOL/"

# Package index, written with paths relative to the repository root.
( cd "$OUT" && dpkg-scanpackages -m "pool/main" /dev/null > "$BINDIR/Packages" 2>/dev/null )
gzip -9c "$BINDIR/Packages" > "$BINDIR/Packages.gz"
echo "   indexed $(grep -c '^Package:' "$BINDIR/Packages") package(s)"

# Repository Release file with checksums of the index. apt-ftparchive resolves
# its directory argument relative to the working directory, so run it from the
# repository root even when --out points somewhere else.
( cd "$OUT" && apt-ftparchive \
    -o "APT::FTPArchive::Release::Origin=$NAME" \
    -o "APT::FTPArchive::Release::Label=$NAME" \
    -o "APT::FTPArchive::Release::Suite=$DIST" \
    -o "APT::FTPArchive::Release::Codename=$DIST" \
    -o "APT::FTPArchive::Release::Architectures=$ARCH" \
    -o "APT::FTPArchive::Release::Components=$COMPONENT" \
    -o "APT::FTPArchive::Release::Description=$NAME - terminal maze game" \
    release "dists/$DIST" > "$OUT/dists/$DIST/Release" )
echo "   wrote dists/$DIST/Release"

SIGNED=0
if [[ -n $KEY ]]; then
    echo "== signing Release with $KEY (your passphrase will be requested) =="
    gpg --yes --default-key "$KEY" --armor --detach-sign \
        -o "$OUT/dists/$DIST/Release.gpg" "$OUT/dists/$DIST/Release"
    gpg --yes --default-key "$KEY" --clearsign \
        -o "$OUT/dists/$DIST/InRelease" "$OUT/dists/$DIST/Release"
    gpg --verify "$OUT/dists/$DIST/InRelease" 2>&1 | grep -i 'good signature' || true
    SIGNED=1
    KEYRING=/etc/apt/keyrings/$NAME.gpg
else
    echo "   (unsigned: users must use [trusted=yes] - see the instructions below)"
    KEYRING=/etc/apt/keyrings/$NAME.gpg
fi

# GitHub Pages helpers: no Jekyll processing, and a page for humans landing here.
touch "$OUT/.nojekyll"
if (( SIGNED )); then
    KEY_STEP="sudo mkdir -p /etc/apt/keyrings
curl -fsSL $URL/$NAME.gpg | sudo gpg --dearmor -o $KEYRING"
    APT_OPTS="signed-by=$KEYRING"
else
    KEY_STEP="# (unsigned repository: no key to import)"
    APT_OPTS="trusted=yes"
fi

cat > "$OUT/index.html" <<HTML
<!doctype html>
<meta charset="utf-8">
<title>$NAME apt repository</title>
<h1>$NAME apt repository</h1>
<p>Debian and Ubuntu packages for <a href="https://github.com/agelospanagiotakis/maze-cli">$NAME</a>.</p>
<h2>Install</h2>
<pre>
$KEY_STEP
echo "deb [$APT_OPTS] $URL $DIST $COMPONENT" | sudo tee /etc/apt/sources.list.d/$NAME.list
sudo apt-get update
sudo apt-get install $NAME
</pre>
<h2>Files</h2>
<ul>
<li><a href="dists/$DIST/Release">dists/$DIST/Release</a></li>
<li><a href="pool/main/${NAME:0:1}/$NAME/">pool/main/${NAME:0:1}/$NAME/</a></li>
</ul>
HTML

if (( SIGNED )); then
    # Publish the public key next to the repository so the curl line above works.
    gpg --armor --export "$KEY" > "$OUT/$NAME.gpg"
    echo "   exported public key to $NAME.gpg"
fi

echo
echo "repository tree: $OUT  ($(du -sh "$OUT" | cut -f1))"
if (( SIGNED )); then
    echo
    echo "Users install with:"
    echo "  sudo mkdir -p /etc/apt/keyrings"
    echo "  curl -fsSL $URL/$NAME.gpg | sudo gpg --dearmor -o $KEYRING"
    echo "  echo \"deb [signed-by=$KEYRING] $URL $DIST $COMPONENT\" | sudo tee /etc/apt/sources.list.d/$NAME.list"
else
    echo
    echo "Users install with (unsigned repository):"
    echo "  echo \"deb [trusted=yes] $URL $DIST $COMPONENT\" | sudo tee /etc/apt/sources.list.d/$NAME.list"
    echo
    echo "To publish a signed repository instead, re-run with --key B1BA023B35947F8DD1A21EBD952F2FF96C4DE741."
fi
echo "  sudo apt-get update && sudo apt-get install $NAME"

fi   # end of the assembly branch (skipped entirely by --publish-only)

if (( PUBLISH )); then
    # Publishing needs git *and* the credentials that go with it. Inside the
    # toolchain container there is no ssh binary and no key, so catch that here
    # rather than letting git fail with "cannot run ssh: No such file or
    # directory" after the commit.
    command -v git >/dev/null 2>&1 || { echo "--publish needs git" >&2; exit 1; }

    ORIGIN=$(git -C "$REPO" remote get-url origin 2>/dev/null || true)
    [[ -n $ORIGIN ]] || { echo "--publish needs a git remote named origin" >&2; exit 1; }

    case "$ORIGIN" in
        *://*) : ;;                                     # https: needs a token helper
        *) command -v ssh >/dev/null 2>&1 || {
               echo "cannot publish over ssh: no ssh client here." >&2
               echo "Run 'make apt-publish' on your host machine, where your git" >&2
               echo "credentials and ssh key live, not inside the container." >&2
               exit 1
           } ;;
    esac

    # git refuses to commit with an empty identity, which is the default state
    # for a throwaway checkout; fall back to the package Maintainer, and only
    # then to a placeholder.
    PUB_NAME=$(git -C "$REPO" config user.name || true)
    PUB_EMAIL=$(git -C "$REPO" config user.email || true)
    [[ -n $PUB_NAME ]] || PUB_NAME=$(sed -n 's/^Maintainer: \(.*\) <.*>/\1/p' "$REPO/debian/control" | head -1)
    [[ -n $PUB_NAME ]] || PUB_NAME="$NAME apt repository"
    [[ -n $PUB_EMAIL ]] || PUB_EMAIL=$(sed -n 's/^Maintainer: .*<\(.*\)>.*/\1/p' "$REPO/debian/control" | head -1)
    [[ -n $PUB_EMAIL ]] || PUB_EMAIL="noreply@example.invalid"

    ORIGIN=$(git -C "$REPO" remote get-url origin 2>/dev/null || true)
    [[ -n $ORIGIN ]] || { echo "--publish needs a git remote named origin" >&2; exit 1; }

    echo
    echo "== publishing to the gh-pages branch of $ORIGIN =="
    echo "   commit identity: $PUB_NAME <$PUB_EMAIL>"
    # Idempotent on purpose: an earlier attempt may already have created the
    # commit (e.g. it succeeded here and then failed to push), and `git commit`
    # on an unchanged tree exits non-zero, which would make every retry fail.
    # symbolic-ref sets the branch without needing `git init --initial-branch`,
    # which warns when the repository already exists.
    ( cd "$OUT" \
      && git init -q \
      && git symbolic-ref HEAD refs/heads/gh-pages \
      && git add -A \
      && if ! git diff --cached --quiet; then \
             git -c user.name="$PUB_NAME" -c user.email="$PUB_EMAIL" \
                 commit -qm "apt repository for $NAME $VERSION"; \
         else \
             echo "   nothing new to commit (already built)"; \
         fi \
      && git push -f -q "$ORIGIN" gh-pages )
    echo "   pushed. Enable Pages once with:"
    echo "   gh api --method POST repos/{owner}/{repo}/pages -f 'source[branch]=gh-pages' -f 'source[path]=/'"
    echo "   (or: gh api --method PUT repos/{owner}/{repo}/pages -f 'source[branch]=gh-pages' -f 'source[path]=/' if already enabled)"
fi
