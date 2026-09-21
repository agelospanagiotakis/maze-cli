#!/usr/bin/env bash
#
# Runs INSIDE the Debian container: builds the source upload, signs it and sends
# it to mentors.debian.net. It refuses to run with an empty keyring instead of
# letting debsign fail with "No secret key".
#
# Usage (inside the container):
#   packaging/sign-and-upload.sh B1BA023B35947F8DD1A21EBD952F2FF96C4DE741 [keyfile]
#
# The keyfile argument defaults to /key.asc and is imported if the keyring does
# not already have the key.
#
# Copyright (C) 2026 Angelos Panagiotakis
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

FPR="${1:?usage: sign-and-upload.sh B1BA023B35947F8DD1A21EBD952F2FF96C4DE741 [keyfile]}"
KEYFILE="${2:-/key.asc}"

for tool in dpkg-buildpackage debsign dput gpg; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "missing $tool: apt-get install -y devscripts dpkg-dev make gnupg pinentry-curses" >&2
        exit 1
    }
done

if ! gpg --list-secret-keys "$FPR" >/dev/null 2>&1; then
    echo "secret key $FPR is not in this container's keyring"
    if [[ -f $KEYFILE ]]; then
        echo "importing it from $KEYFILE ..."
        gpg --import "$KEYFILE"
    else
        cat >&2 <<EOF
and no key file at $KEYFILE.

A container started with 'docker run --rm' has an empty keyring, so the key has
to be imported in every new container. From the host:

    gpg --export-secret-keys --armor $FPR > /tmp/maze-key.asc
    docker cp /tmp/maze-key.asc \$CONTAINER:/key.asc
    # or start the container with: -v /tmp/maze-key.asc:/key.asc:ro

Then delete the export from the host when you are done:
    shred -u /tmp/maze-key.asc     # or: rm -P /tmp/maze-key.asc
EOF
        exit 1
    fi
fi

VERSION=$(sed -n '1s/.*(\(.*\)).*/\1/p' debian/changelog)
echo "== building source upload for $VERSION =="
make source

CHANGES="build/pkg/maze_${VERSION}_source.changes"
[[ -f $CHANGES ]] || { echo "expected $CHANGES, not found" >&2; exit 1; }

echo
echo "== signing $CHANGES =="
debsign -k"$FPR" "$CHANGES"

echo
echo "== uploading to mentors =="
dput mentors "$CHANGES"

echo
echo "done: https://mentors.debian.net/package/maze/"
