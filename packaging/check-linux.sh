#!/usr/bin/env bash
#
# Verifies the Linux distribution flow in a throwaway Debian container:
# builds the release tarball, proves the tarball is self-contained, installs
# and uninstalls it, then builds, installs and removes a .deb package.
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

echo "--- container ---"
bash --version | head -1
grep PRETTY_NAME /etc/os-release

# The slim image has no make; install just that (dpkg-deb ships with dpkg).
if ! command -v make >/dev/null 2>&1; then
    echo "installing make..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null
    apt-get install -y -qq -o Dpkg::Use-Pty=0 --no-install-recommends make >/dev/null 2>&1
fi

WORK=/tmp/check
REL=/tmp/rel
rm -rf "$WORK" "$REL" /tmp/stage
mkdir -p "$WORK/tests" "$WORK/packaging/deb" "$REL"
cp /src/maze.sh /src/LICENSE /src/README.md /src/Makefile "$WORK/"
cp /src/tests/smoke_test.sh "$WORK/tests/"
cp /src/packaging/deb/control.in "$WORK/packaging/deb/"
cd "$WORK"

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
ls -l /tmp/stage/usr/bin/maze
/tmp/stage/usr/bin/maze --version | head -2
echo "usage line: $(/tmp/stage/usr/bin/maze --help | sed -n '3p')"

strip_ansi() { sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g'; }
SOLUTION=$(/tmp/stage/usr/bin/maze --print-solution --seed 5 --ascii --no-color)
printf '%sq' "$SOLUTION" | /tmp/stage/usr/bin/maze --ascii --no-color --seed 5 \
    | strip_ansi | grep -o 'Level 1 cleared in [0-9]* moves' | head -1
make uninstall DESTDIR=/tmp/stage PREFIX=/usr >/dev/null
if [[ -e /tmp/stage/usr/bin/maze ]]; then
    echo "FAIL: uninstall left the binary behind" >&2
    exit 1
fi
echo "uninstall removed the binary"

echo
echo "--- 4. build and install the .deb ---"
cd "$WORK"
make deb | tail -1
dpkg-deb -I build/maze-1.0.0.deb | sed -n '1,12p'
dpkg -i build/maze-1.0.0.deb >/dev/null
echo "installed at: $(command -v maze)"
maze --version | head -1
printf 'q' | maze --ascii --no-color --seed 5 | strip_ansi | grep -o 'No moves made[^.]*' | head -1
echo "files installed by the package:"
dpkg -L maze | grep -v '^/$' | sed 's/^/  /'
dpkg -r maze >/dev/null
if command -v maze >/dev/null 2>&1; then
    echo "FAIL: package removal left maze installed" >&2
    exit 1
fi
echo "package removal cleaned up"

echo
echo "ALL LINUX DISTRIBUTION CHECKS PASSED"
CONTAINER_SCRIPT
