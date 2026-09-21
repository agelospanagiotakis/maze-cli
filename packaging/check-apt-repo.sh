#!/usr/bin/env bash
#
# check-apt-repo.sh - verify build-apt-repo.sh inside a throwaway container.
#
# Builds the .deb, assembles a SIGNED apt repository with a throwaway key, and
# then, in the same container:
#
#   1. installs maze from it with apt, signature verification ON
#   2. proves that verification is real: without the right key, apt must refuse
#   3. installs from an UNSIGNED repository using [trusted=yes]
#   4. checks the published layout (index.html, .nojekyll, pool paths)
#
# A throwaway key is used, so nothing of yours is involved and nothing is
# uploaded anywhere.
#
# Copyright (C) 2026 Angelos Panagiotakis
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage:  packaging/check-apt-repo.sh [debian:stable-slim]

set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
IMAGE="${1:-debian:stable-slim}"

command -v docker >/dev/null 2>&1 || {
    echo "docker not found; this check needs a Linux container." >&2
    exit 1
}

echo "== verifying the apt repository flow in $IMAGE =="

docker run --rm -i -v "$REPO":/src:ro "$IMAGE" bash -s <<'CONTAINER_SCRIPT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "installing tooling..."
apt-get update -qq >/dev/null
apt-get install -y -qq -o Dpkg::Use-Pty=0 --no-install-recommends \
    make build-essential debhelper devscripts dpkg-dev apt-utils \
    gnupg pinentry-curses ca-certificates git >/dev/null 2>&1

WORK=/w
mkdir -p "$WORK" && cd "$WORK"
cp -a /src/maze.sh /src/maze.1 /src/Makefile /src/LICENSE /src/README.md \
      /src/tests /src/debian /src/packaging .

echo "generating a throwaway signing key..."
gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key "Repo Test <repo@example.invalid>" rsa2048 sign 1d >/dev/null 2>&1
FPR=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')
[[ -n $FPR ]] || fail "no test key generated"

echo "building the .deb..."
make deb >/tmp/build.log 2>&1 || { tail -20 /tmp/build.log; fail "make deb"; }

echo
echo "--- 1. assemble a signed repository ---"
packaging/build-apt-repo.sh --key "$FPR" --out /repo \
    --url https://example.invalid/maze-cli | sed 's/^/   /'

echo
echo "--- 2. published layout ---"
( cd /repo && find . -type f | sort | sed 's/^/   /' )
for f in dists/stable/Release dists/stable/InRelease dists/stable/Release.gpg \
         dists/stable/main/binary-all/Packages \
         dists/stable/main/binary-all/Packages.gz index.html .nojekyll maze.gpg; do
    [[ -f /repo/$f ]] || fail "missing from the repository: $f"
done
grep -q '^Architectures: all' /repo/dists/stable/Release || fail "Release lacks Architectures"
# Release lists index paths relative to dists/<dist>/ .
grep -qE 'main/binary-all/Packages(\.gz)?$' /repo/dists/stable/Release \
    || fail "Release does not checksum the Packages index"
# Release -> Packages -> .deb is the integrity chain apt walks.
grep -q '^SHA256:' /repo/dists/stable/main/binary-all/Packages \
    || fail "Packages index has no SHA256 field"
grep -qE '^Filename: pool/main/m/maze/.*\.deb$' /repo/dists/stable/main/binary-all/Packages \
    || fail "Packages index does not point at the pool .deb"
echo "   layout ok; Release checksums the index, index checksums the .deb"

echo
echo "--- 3. apt install with signature verification ON ---"
mkdir -p /etc/apt/keyrings
cp /repo/maze.gpg /etc/apt/keyrings/maze.gpg
echo "deb [signed-by=/etc/apt/keyrings/maze.gpg] file:/repo stable main" \
    > /etc/apt/sources.list.d/maze.list
apt-get update -qq || fail "apt-get update against the signed repository"
apt-get install -y -qq maze >/dev/null || fail "apt-get install from the signed repository"
echo "   installed: $(dpkg-query -W -f='${Package} ${Version} ${Status}' maze)"
[[ -x /usr/games/maze ]] || fail "maze not installed to /usr/games"
/usr/games/maze --version | head -1 | sed 's/^/   /'
apt-get remove -y -qq maze >/dev/null

echo
echo "--- 4. negative test: verification must actually be enforced ---"
rm -f /etc/apt/keyrings/maze.gpg                       # key no longer available
rm -rf /var/lib/apt/lists/*
if apt-get update -qq >/tmp/nokey.log 2>&1; then
    if apt-get install -y -qq maze >/tmp/nokey-install.log 2>&1; then
        fail "apt installed a package it could not verify - the repository is not really protected"
    fi
fi
echo "   apt refused without the key (as it must):"
grep -oiE 'no_pubkey[^ ]*|signatures? (were|was) invalid[^.]*|is not signed[^.]*' /tmp/nokey.log | head -2 | sed 's/^/     /'
rm -f /etc/apt/sources.list.d/maze.list

echo
echo "--- 5. unsigned repository with [trusted=yes] ---"
rm -f /repo/dists/stable/InRelease /repo/dists/stable/Release.gpg
echo "deb [trusted=yes] file:/repo stable main" > /etc/apt/sources.list.d/maze.list
rm -rf /var/lib/apt/lists/*
apt-get update -qq || fail "apt-get update against the unsigned repository"
apt-get install -y -qq maze >/dev/null || fail "apt-get install from the unsigned repository"
echo "   installed without a signature: $(dpkg-query -W -f='${Version}' maze)"

echo
echo "--- 6. publish mechanics (against a local bare repo, not GitHub) ---"
git init -q -b main "$WORK"
git -C "$WORK" add -A
git -C "$WORK" -c user.name=t -c user.email=t@example.invalid commit -qm "test"
git init -q --bare /tmp/origin.git
git -C "$WORK" remote add origin /tmp/origin.git
# Exactly the documented macOS flow: build+sign where the tooling is, publish
# where the git credentials are. Here both happen in this container.
packaging/build-apt-repo.sh --publish-only --out /repo \
    --url https://example.invalid/maze-cli 2>&1 | sed 's/^/   /' | grep -E 'publish|identity|pushed' | sed 's/^/   /'
git --git-dir=/tmp/origin.git rev-parse --verify -q gh-pages >/dev/null \
    || fail "--publish-only did not create a gh-pages branch"
echo "   gh-pages branch created with:"
git --git-dir=/tmp/origin.git ls-tree -r --name-only gh-pages | sed 's/^/     /'

echo
echo "ALL APT REPOSITORY CHECKS PASSED"
CONTAINER_SCRIPT
