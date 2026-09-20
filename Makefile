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
#   make deb                      build a .deb (needs dpkg-deb, i.e. Debian/Ubuntu)
#   make uninstall

NAME     := maze
VERSION  := $(shell sed -n 's/^VERSION="\(.*\)"/\1/p' maze.sh)
DISTNAME := $(NAME)-$(VERSION)

PREFIX   ?= /usr/local
BINDIR   ?= $(PREFIX)/bin
DESTDIR  ?=

BUILD    := build
SHA256   := $(shell command -v sha256sum 2>/dev/null || command -v shasum 2>/dev/null)

.PHONY: all help test check check-linux install uninstall dist deb clean

all: help

help:
	@printf '%s\n' \
	  'maze $(VERSION) - install and packaging targets' \
	  '' \
	  '  make install [PREFIX=/usr/local] [DESTDIR=]   install maze(1)' \
	  '  make uninstall [PREFIX=...] [DESTDIR=...]     remove it again' \
	  '  make test                                     run the test suite' \
	  '  make check                                    bash -n / shellcheck' \
	  '  make check-linux                              verify packaging in Docker' \
	  '  make dist                                     release tarball + SHA256' \
	  '  make deb                                      build a .deb package' \
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

check-linux:
	bash packaging/check-linux.sh

# --------------------------------------------------------------------------- #
# install / uninstall
# --------------------------------------------------------------------------- #

install:
	install -d "$(DESTDIR)$(BINDIR)"
	install -m 755 maze.sh "$(DESTDIR)$(BINDIR)/$(NAME)"
	@echo "installed $(DESTDIR)$(BINDIR)/$(NAME) ($(VERSION))"
	@echo "run it with: $(NAME)"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/$(NAME)"
	@echo "removed $(DESTDIR)$(BINDIR)/$(NAME)"

# --------------------------------------------------------------------------- #
# release tarball
# --------------------------------------------------------------------------- #

dist: clean
	install -d "$(BUILD)/$(DISTNAME)/tests"
	install -m 755 maze.sh "$(BUILD)/$(DISTNAME)/maze.sh"
	install -m 644 LICENSE README.md Makefile "$(BUILD)/$(DISTNAME)/"
	install -m 755 tests/smoke_test.sh "$(BUILD)/$(DISTNAME)/tests/"
	tar -C "$(BUILD)" -czf "$(BUILD)/$(DISTNAME).tar.gz" "$(DISTNAME)"
	@cd "$(BUILD)" && { \
	    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$(DISTNAME).tar.gz"; \
	    else shasum -a 256 "$(DISTNAME).tar.gz"; fi; \
	} > "$(DISTNAME).tar.gz.sha256"
	@echo "built $(BUILD)/$(DISTNAME).tar.gz"
	@cat "$(BUILD)/$(DISTNAME).tar.gz.sha256"

# --------------------------------------------------------------------------- #
# deb package (dpkg-deb is only present on Debian-derived systems)
# --------------------------------------------------------------------------- #

deb:
	@command -v dpkg-deb >/dev/null 2>&1 || { \
	    echo "dpkg-deb not found: build the .deb on Debian or Ubuntu," >&2; \
	    echo "or use 'make dist' and package it with nfpm/fpm instead." >&2; \
	    exit 1; }
	rm -rf "$(BUILD)/deb/$(DISTNAME)"
	install -d "$(BUILD)/deb/$(DISTNAME)/DEBIAN" \
	           "$(BUILD)/deb/$(DISTNAME)/usr/bin" \
	           "$(BUILD)/deb/$(DISTNAME)/usr/share/doc/$(NAME)"
	install -m 755 maze.sh "$(BUILD)/deb/$(DISTNAME)/usr/bin/$(NAME)"
	install -m 644 LICENSE "$(BUILD)/deb/$(DISTNAME)/usr/share/doc/$(NAME)/copyright"
	install -m 644 README.md "$(BUILD)/deb/$(DISTNAME)/usr/share/doc/$(NAME)/README.md"
	sed -e 's/@VERSION@/$(VERSION)/' -e 's/@DATE@/$(shell date -u +%Y-%m-%d)/' \
	    packaging/deb/control.in > "$(BUILD)/deb/$(DISTNAME)/DEBIAN/control"
	dpkg-deb --build --root-owner-group "$(BUILD)/deb/$(DISTNAME)" "$(BUILD)/$(DISTNAME).deb"
	@echo "built $(BUILD)/$(DISTNAME).deb"

clean:
	rm -rf "$(BUILD)"
