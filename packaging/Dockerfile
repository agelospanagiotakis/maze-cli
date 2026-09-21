# Toolchain image for building and publishing maze packages.
#
# Build once, reuse forever:
#   ./packaging/devenv.sh            # builds if needed, then opens a shell
#   make docker-image                # just build it
#
# Copyright (C) 2026 Angelos Panagiotakis
# SPDX-License-Identifier: GPL-3.0-or-later

FROM debian:stable-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV LC_ALL=C.UTF-8

# Everything the packaging, signing and publishing scripts need. Building this
# once means no container ever reinstalls it again.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        make \
        build-essential \
        debhelper \
        devscripts \
        dput \
        dpkg-dev \
        apt-utils \
        fakeroot \
        lintian \
        man-db \
        autopkgtest \
        debian-policy \
        gnupg \
        pinentry-curses \
        git \
        ca-certificates \
        curl \
        less \
 && rm -rf /var/lib/apt/lists/*

# A stable place to work; the repository is mounted here at run time.
WORKDIR /w

CMD ["bash"]
