#!/usr/bin/env bash
#
# Verifies the Linux distribution flow in a throwaway Debian container:
#
#   1. build the release tarball and check its SHA256
#   2. prove the unpacked release is self-contained (runs its own test suite)
#   3. install from the release, run it, uninstall
#   4. build the Debian source + binary package with dpkg-buildpackage
#   5. run lintian over the result
#   6. serve the package from a local apt repository and install it with
#      apt-get, then remove it again
#   7. run the autopkgtest script against the installed package
#
# Copyright (C) 2026 Angelos Panagiotakis
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage:  packaging/check-linux.sh [debian:stable-slim]

set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
IMAGE="${1:-debian:stable-slim}"

command -v docker >/dev/null 2>&1 || {
    echo "docker not found; this check needs a Linux container." >&2
    exit 1
}

echo "== running the distribution check in $IMAGE =="

# The repo is mounted read-only and copied inside the container, so nothing
# here is ever written as root into the working tree. -i matters: the container
# script is delivered on stdin.
docker run --rm -i -v "$REPO":/src:ro "$IMAGE" bash -s <<'CONTAINER_SCRIPT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "--- container ---"
bash --version | head -1
grep PRETTY_NAME /etc/os-release

echo "installing build tooling (make, debhelper, devscripts, lintian, man-db)..."
apt-get update -qq >/dev/null
apt-get install -y -qq -o Dpkg::Use-Pty=0 --no-install-recommends \
    make build-essential debhelper devscripts lintian fakeroot man-db >/dev/null 2>&1

WORK=/tmp/check
REL=/tmp/rel
rm -rf "$WORK" "$REL" /tmp/stage
mkdir -p "$WORK/tests" "$WORK/debian" "$REL"
cp /src/maze.sh /src/LICENSE /src/README.md /src/Makefile /src/maze.1 "$WORK/"
cp /src/tests/smoke_test.sh "$WORK/tests/"
cp -a /src/debian/. "$WORK/debian/"
cd "$WORK"

strip_ansi() { sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g'; }

echo
echo "--- 1. build the release tarball ---"
make dist | tail -2
( cd build && sha256sum -c maze-1.0.0.tar.gz.sha256 )

echo
echo "--- 2. the unpacked release must be self-contained ---"
tar -xzf build/maze-1.0.0.tar.gz -C "$REL"
cd "$REL"/maze-*/
make test 2>&1 | tail -2

echo
echo "--- 3. install from the release, run it, uninstall ---"
make install DESTDIR=/tmp/stage PREFIX=/usr >/dev/null
ls -l /tmp/stage/usr/bin/maze /tmp/stage/usr/share/man/man1/maze.1
/tmp/stage/usr/bin/maze --version | head -2
echo "usage line: $(/tmp/stage/usr/bin/maze --help | sed -n '3p')"

SOLUTION=$(/tmp/stage/usr/bin/maze --print-solution --seed 5 --ascii --no-color)
printf '%sq' "$SOLUTION" | /tmp/stage/usr/bin/maze --ascii --no-color --seed 5 \
    | strip_ansi | grep -o 'Level 1 cleared in [0-9]* moves' | head -1
make uninstall DESTDIR=/tmp/stage PREFIX=/usr >/dev/null
if [[ -e /tmp/stage/usr/bin/maze || -e /tmp/stage/usr/share/man/man1/maze.1 ]]; then
    echo "FAIL: uninstall left files behind" >&2
    exit 1
fi
echo "uninstall removed the program and the man page"

echo
echo "--- 3b. man page renders without warnings ---"
if man --warnings -l "$WORK"/maze.1 >/dev/null 2>/tmp/manwarn; then
    if [[ -s /tmp/manwarn ]]; then
        echo "man --warnings reported:"; cat /tmp/manwarn
    else
        echo "man page: no warnings"
    fi
else
    echo "man --warnings failed:"; cat /tmp/manwarn
fi

echo
echo "--- 4. build the Debian source + binary package ---"
cd "$WORK"
make deb 2>&1 | tail -14
DEB=$(ls "$WORK"/build/pkg/*.deb | head -1)
echo "binary: $DEB"
echo "source: $(ls "$WORK"/build/pkg/*.dsc | head -1)"
dpkg-deb -I "$DEB" | sed -n '1,14p'

echo
echo "--- 5. lintian ---"
LINTIAN_RC=0
lintian --pedantic "$WORK"/build/pkg/*.changes || LINTIAN_RC=$?
echo "lintian exit: $LINTIAN_RC"

echo
echo "--- 6. apt-get install from a local repository ---"
APTREPO=/srv/aptrepo
rm -rf "$APTREPO"; mkdir -p "$APTREPO"
cp "$WORK"/build/pkg/*.deb "$APTREPO"/
( cd "$APTREPO" && dpkg-scanpackages -m . /dev/null > Packages && gzip -kf Packages )
echo "deb [trusted=yes] file:$APTREPO ./" > /etc/apt/sources.list.d/maze-local.list
apt-get update -qq >/dev/null
apt-get install -y -qq maze >/dev/null
echo "installed via apt-get: $(dpkg-query -W -f='${Package} ${Version} ${Status}' maze)"
MAZE=/usr/games/maze
echo "installed at: $MAZE"
ls -l "$MAZE"
"$MAZE" --version | head -1
SOLUTION=$("$MAZE" --print-solution --seed 5 --ascii --no-color)
printf '%sq' "$SOLUTION" | "$MAZE" --ascii --no-color --seed 5 \
    | strip_ansi | grep -o 'Level 1 cleared in [0-9]* moves' | head -1
# /usr/games is on the default login PATH, so a plain `maze` must work for users.
echo "PATH for a login shell: $(env -i bash -lc 'echo $PATH')"
echo "files shipped by the package:"
dpkg -L maze | grep -v '^/$' | sed 's/^/  /'

echo
echo "--- 7. autopkgtest script against the installed package ---"
bash "$WORK"/debian/tests/smoke && echo "autopkgtest smoke: passed"

echo
echo "--- removing the package ---"
apt-get remove -y -qq maze >/dev/null
if [[ -e /usr/games/maze ]]; then
    echo "FAIL: apt-get remove left maze installed" >&2
    exit 1
fi
echo "apt-get remove cleaned up"

echo
echo "ALL LINUX DISTRIBUTION CHECKS PASSED"
CONTAINER_SCRIPT
