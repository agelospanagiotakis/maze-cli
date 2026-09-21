#!/usr/bin/env bash
#
# devenv.sh - open a Debian packaging shell without reinstalling anything.
#
#   packaging/devenv.sh                              build the image if needed, then a shell
#   packaging/devenv.sh --rebuild                    rebuild the image first
#   MAZE_DEV_CMD='make test' packaging/devenv.sh     run one command and exit
#
# The image (packaging/Dockerfile) carries debhelper, devscripts, dput, lintian,
# gnupg, git and friends, so `make deb`, `make source`, `make apt-repo` and
# `debsign` all work immediately.
#
# Your GnuPG home lives in a named volume, so the signing key survives between
# containers. This script manages the key for you:
#
#   * if the key file is missing on the host, it exports the secret key there
#     (gpg asks for the passphrase once, on the host)
#   * if the volume does not have the key yet, it imports it into the volume
#   * then the shell starts with the key already usable
#
# Copyright (C) 2026 Angelos Panagiotakis
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=${MAZE_DEV_IMAGE:-maze-devtools:stable}
GNUPG_VOLUME=${MAZE_DEV_GNUPG:-maze-gnupg}
KEYFILE=${MAZE_KEYFILE:-/tmp/maze-key.asc}
FINGERPRINT=${MAZE_FINGERPRINT:-B1BA023B35947F8DD1A21EBD952F2FF96C4DE741}
DEV_CMD=${MAZE_DEV_CMD:-}

command -v docker >/dev/null 2>&1 || { echo "docker not found" >&2; exit 1; }
docker info >/dev/null 2>&1 || {
    echo "the Docker daemon is not running - start Docker Desktop first" >&2
    exit 1
}

if [[ ${1:-} == --rebuild ]]; then
    docker rmi "$IMAGE" >/dev/null 2>&1 || true
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "building $IMAGE (once; later runs start instantly)..."
    docker build -t "$IMAGE" "$REPO/packaging"
fi

# --- make sure the signing key is available inside the container --------------

if ! docker run --rm -v "$GNUPG_VOLUME":/root/.gnupg "$IMAGE" \
        gpg --list-secret-keys "$FINGERPRINT" >/dev/null 2>&1; then

    if [[ ! -f $KEYFILE ]]; then
        echo "no $KEYFILE on the host; exporting the secret key there now"
        echo "(gpg may ask for its passphrase)"
        gpg --export-secret-keys --armor "$FINGERPRINT" > "$KEYFILE"
        chmod 600 "$KEYFILE"
    fi

    # Importing a passphrase-protected secret key needs a real terminal: gpg
    # starts an agent, and without a TTY it fails with "error sending to agent:
    # Inappropriate ioctl for device". Stale agent sockets left in the volume by
    # an earlier container are cleared first, or gpg tries to reuse a dead one.
    IMPORT_SCRIPT='install -d -m 700 /root/.gnupg
        rm -f /root/.gnupg/S.gpg-agent /root/.gnupg/S.gpg-agent.extra \
              /root/.gnupg/S.gpg-agent.browser /root/.gnupg/S.gpg-agent.ssh
        gpgconf --kill gpg-agent 2>/dev/null || true
        gpg --import /key.asc
        gpg --list-secret-keys --with-colons "$0" | grep -q "^sec:"'

    echo "importing $FINGERPRINT into the $GNUPG_VOLUME volume (once)"
    if [[ -t 0 ]]; then
        # No pipe here on purpose. Piping a TTY container's output through sed
        # hides pinentry's passphrase prompt, and the import then waits forever
        # for input that is never shown.
        docker run --rm -it -v "$GNUPG_VOLUME":/root/.gnupg -v "$KEYFILE":/key.asc:ro \
            "$IMAGE" bash -c "$IMPORT_SCRIPT" "$FINGERPRINT" || true
    else
        echo "   no terminal attached; doing a non-interactive import."
        echo "   If it reports 'Inappropriate ioctl for device', run"
        echo "   packaging/devenv.sh from an interactive shell instead."
        docker run --rm -i -v "$GNUPG_VOLUME":/root/.gnupg -v "$KEYFILE":/key.asc:ro \
            "$IMAGE" bash -c "$IMPORT_SCRIPT" "$FINGERPRINT" 2>&1 | sed 's/^/   /' || true
    fi
fi

KEY_STATE=$(docker run --rm -v "$GNUPG_VOLUME":/root/.gnupg "$IMAGE" \
    gpg --list-secret-keys --with-colons "$FINGERPRINT" 2>/dev/null | awk -F: '/^sec:/{print "present"}')

MOUNTS=(-v "$REPO":/w -w /w -v "$GNUPG_VOLUME":/root/.gnupg)
[[ -f $KEYFILE ]] && MOUNTS+=(-v "$KEYFILE":/key.asc:ro)

if [[ -n $DEV_CMD ]]; then
    echo "running in $IMAGE: $DEV_CMD"
    exec docker run --rm -i "${MOUNTS[@]}" "$IMAGE" bash -lc "$DEV_CMD"
fi

cat <<EOF

maze packaging environment ($IMAGE)
  repo:   $REPO  ->  /w
  gnupg:  volume $GNUPG_VOLUME  ->  /root/.gnupg  (persists between runs)
  key:    $FINGERPRINT ${KEY_STATE:-NOT PRESENT}

useful commands:
  make test                                  the game's test suite
  make deb                                   .deb + source package
  make source                                source-only upload set for mentors
  make apt-repo GPG_KEY=$FINGERPRINT         build the apt repository
  packaging/sign-and-upload.sh $FINGERPRINT  build, sign and dput to mentors
  (then run 'make apt-publish' on the host, where your git credentials are)

EOF

if [[ -t 0 ]]; then
    exec docker run --rm -it "${MOUNTS[@]}" "$IMAGE" bash
else
    exec docker run --rm -i "${MOUNTS[@]}" "$IMAGE" bash
fi
