# maze - install and packaging rules
# Copyright (C) 2026 Angelos Panagiotakis
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Common use:
#   make install                  install to /usr/local/bin/maze
#   sudo make install             same, system-wide
#   make install PREFIX=$HOME/.local
#   make test                     run the test suite
#   make dist                     build a release tarball + SHA256
#   make deb                      build .deb + Debian source package (.dsc)
#   make lint                     run lintian over the built package
#   make uninstall

NAME     := maze
VERSION  := $(shell sed -n 's/^VERSION="\(.*\)"/\1/p' maze.sh)
DEBREV   := 1
DEBVERSION := $(VERSION)-$(DEBREV)
DISTNAME := $(NAME)-$(VERSION)

PREFIX   ?= /usr/local
BINDIR   ?= $(PREFIX)/bin
MANDIR   ?= $(PREFIX)/share/man/man1
DESTDIR  ?=

BUILD    := build
PKGDIR   := $(BUILD)/pkg
SRCDIR   := $(PKGDIR)/$(NAME)-$(VERSION)
ORIG     := $(PKGDIR)/$(NAME)_$(VERSION).orig.tar.gz

# Container image used by `make check-linux`.
IMAGE    ?= debian:stable-slim

MANUAL   := maze.1

.PHONY: all help test check check-all check-linux install uninstall dist deb source lint orig clean

all: help

help:
	@printf '%s\n' \
	  'maze $(VERSION) - install and packaging targets' \
	  '' \
	  '  make install [PREFIX=/usr/local] [DESTDIR=]   install maze and maze(1)' \
	  '  make uninstall [PREFIX=...] [DESTDIR=...]     remove them again' \
	  '  make test                                     run the test suite' \
	  '  make check                                    bash -n / shellcheck' \
	  '  make check-all                                run every check (incl. Docker)' \
	  '  make check-linux [IMAGE=debian:stable-slim]   verify packaging in Docker' \
	  '  make dist                                     release tarball + SHA256' \
	  '  make deb                                      .deb + source package (.dsc)' \
	  '  make source                                   source-only upload (.changes)' \
	  '  make lint                                     lintian the built package' \
	  '  make clean                                    remove build/'

# --------------------------------------------------------------------------- #
# verification
# --------------------------------------------------------------------------- #

test:
	bash tests/smoke_test.sh

check:
	@if command -v shellcheck >/dev/null 2>&1; then \
	    shellcheck maze.sh tests/smoke_test.sh && echo "shellcheck: clean"; \
	else \
	    echo "shellcheck not installed; syntax-checking instead"; \
	    bash -n maze.sh && echo "maze.sh: syntax ok"; \
	    bash -n tests/smoke_test.sh && echo "tests/smoke_test.sh: syntax ok"; \
	fi
	@printf 'debian/changelog version: '; sed -n '1s/.*(\(.*\)).*/\1/p' debian/changelog
	@printf 'maze.sh VERSION:          %s\n' "$(DEBVERSION)"
	@first=$$(sed -n '1s/.*(\(.*\)).*/\1/p' debian/changelog); \
	if [ "$$first" != "$(DEBVERSION)" ]; then \
	    echo "ERROR: debian/changelog ($$first) and maze.sh ($(DEBVERSION)) disagree" >&2; \
	    exit 1; \
	fi; echo "versions agree"

check-all:
	bash LINUX_DISTRIBUTION_CHECKS.sh

check-linux:
	bash packaging/check-linux.sh "$(IMAGE)"

# --------------------------------------------------------------------------- #
# install / uninstall
# --------------------------------------------------------------------------- #

install:
	install -d "$(DESTDIR)$(BINDIR)" "$(DESTDIR)$(MANDIR)"
	install -m 755 maze.sh "$(DESTDIR)$(BINDIR)/$(NAME)"
	install -m 644 $(MANUAL) "$(DESTDIR)$(MANDIR)/$(NAME).1"
	@echo "installed $(DESTDIR)$(BINDIR)/$(NAME) ($(VERSION))"
	@echo "installed $(DESTDIR)$(MANDIR)/$(NAME).1"
	@echo "run it with: $(NAME)"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/$(NAME)" "$(DESTDIR)$(MANDIR)/$(NAME).1"
	@echo "removed $(DESTDIR)$(BINDIR)/$(NAME) and $(DESTDIR)$(MANDIR)/$(NAME).1"

# --------------------------------------------------------------------------- #
# release tarball
# --------------------------------------------------------------------------- #

dist: clean
	install -d "$(BUILD)/$(DISTNAME)/tests"
	install -m 755 maze.sh "$(BUILD)/$(DISTNAME)/maze.sh"
	install -m 644 LICENSE README.md Makefile $(MANUAL) "$(BUILD)/$(DISTNAME)/"
	install -m 755 tests/smoke_test.sh "$(BUILD)/$(DISTNAME)/tests/"
	tar -C "$(BUILD)" -czf "$(BUILD)/$(DISTNAME).tar.gz" "$(DISTNAME)"
	@cd "$(BUILD)" && { \
	    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$(DISTNAME).tar.gz"; \
	    else shasum -a 256 "$(DISTNAME).tar.gz"; fi; \
	} > "$(DISTNAME).tar.gz.sha256"
	@echo "built $(BUILD)/$(DISTNAME).tar.gz"
	@cat "$(BUILD)/$(DISTNAME).tar.gz.sha256"

# --------------------------------------------------------------------------- #
# Debian packaging
#
# `make deb` builds the *source* package as well as the binary one, because a
# source package (.dsc + .orig.tar.gz + .debian.tar.xz) is what a repository
# such as Debian itself, an Ubuntu PPA or a private apt repo actually accepts.
# dpkg-buildpackage requires dpkg-dev and debhelper:
#   sudo apt-get install -y build-essential debhelper devscripts lintian
# --------------------------------------------------------------------------- #

orig:
	rm -rf "$(PKGDIR)"
	install -d "$(SRCDIR)/tests"
	install -m 755 maze.sh "$(SRCDIR)/maze.sh"
	install -m 644 LICENSE README.md Makefile $(MANUAL) "$(SRCDIR)/"
	install -m 755 tests/smoke_test.sh "$(SRCDIR)/tests/"
	tar -C "$(PKGDIR)" -czf "$(ORIG)" "$(NAME)-$(VERSION)"
	@echo "built $(ORIG)"

deb:
	@command -v dpkg-buildpackage >/dev/null 2>&1 || { \
	    echo "dpkg-buildpackage not found. Install the tooling first:" >&2; \
	    echo "  sudo apt-get install -y build-essential debhelper devscripts lintian" >&2; \
	    exit 1; }
	@first=$$(sed -n '1s/.*(\(.*\)).*/\1/p' debian/changelog); \
	if [ "$$first" != "$(DEBVERSION)" ]; then \
	    echo "ERROR: debian/changelog says $$first but maze.sh says $(DEBVERSION)" >&2; \
	    echo "       bump debian/changelog (dch -v $(DEBVERSION)) first" >&2; \
	    exit 1; \
	fi
	$(MAKE) orig
	cp -a debian "$(SRCDIR)/debian"
	cd "$(SRCDIR)" && dpkg-buildpackage -us -uc
	@echo
	@echo "artifacts in $(PKGDIR):"
	@ls -1 "$(PKGDIR)"/*.deb "$(PKGDIR)"/*.dsc "$(PKGDIR)"/*.changes 2>/dev/null || true

# Source-only build: what gets uploaded to mentors and to the Debian archive,
# which build the binary themselves. Produces maze_<ver>_source.changes, the
# file debsign signs and dput sends. -sa includes the orig tarball, required
# for a first upload.
source:
	@command -v dpkg-buildpackage >/dev/null 2>&1 || { \
	    echo "dpkg-buildpackage not found. Install the tooling first:" >&2; \
	    echo "  sudo apt-get install -y build-essential debhelper devscripts lintian" >&2; \
	    exit 1; }
	@first=$$(sed -n '1s/.*(\(.*\)).*/\1/p' debian/changelog); \
	if [ "$$first" != "$(DEBVERSION)" ]; then \
	    echo "ERROR: debian/changelog says $$first but maze.sh says $(DEBVERSION)" >&2; \
	    exit 1; \
	fi
	$(MAKE) orig
	cp -a debian "$(SRCDIR)/debian"
	cd "$(SRCDIR)" && dpkg-buildpackage -S -sa -us -uc
	@echo
	@echo "source upload artifacts in $(PKGDIR):"
	@ls -1 "$(PKGDIR)"/*_source.changes "$(PKGDIR)"/*.dsc "$(PKGDIR)"/*.debian.tar.* "$(PKGDIR)"/*.orig.tar.* 2>/dev/null || true
	@echo
	@echo "next: debsign -k<FINGERPRINT> $(PKGDIR)/$(NAME)_$(DEBVERSION)_source.changes"
	@echo "      dput mentors $(PKGDIR)/$(NAME)_$(DEBVERSION)_source.changes"

lint:
	@command -v lintian >/dev/null 2>&1 || { \
	    echo "lintian not installed: sudo apt-get install -y lintian" >&2; exit 1; }
	lintian --pedantic $(PKGDIR)/*.changes

clean:
	rm -rf "$(BUILD)"
