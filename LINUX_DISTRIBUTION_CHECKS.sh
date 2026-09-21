#!/usr/bin/env bash
#
# LINUX_DISTRIBUTION_CHECKS.sh - run every check that matters before shipping.
#
#   ./LINUX_DISTRIBUTION_CHECKS.sh              everything (needs Docker)
#   ./LINUX_DISTRIBUTION_CHECKS.sh --quick      skip the Docker half
#   ./LINUX_DISTRIBUTION_CHECKS.sh --verbose    also stream the full logs
#   ./LINUX_DISTRIBUTION_CHECKS.sh --image debian:stable-slim
#
# What it runs, in order:
#   1. syntax and version consistency          (make check)
#   2. the game's own test suite               (make test)
#   3. the Linux distribution gate in Docker   (make check-linux), which builds
#      the release tarball and verifies its SHA256, tests the unpacked release,
#      installs and uninstalls it, builds the Debian source and binary packages,
#      runs lintian --pedantic, uscan and autopkgtest, and installs the package
#      from a local apt repository with apt-get.
#   4. the published apt repository path          (make check-apt-repo), which
#      assembles and signs a repository, installs from it with verification on,
#      and proves apt refuses a repository it cannot verify.
#
# Exit status: 0 = everything passed, 1 = something failed,
#              2 = incomplete (Docker unavailable, so step 3 could not run).
#
# Copyright (C) 2026 Angelos Panagiotakis
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
cd "$REPO"

QUICK=0
VERBOSE=0
INCOMPLETE=0
IMAGE="debian:stable-slim"

while (( $# )); do
    case "$1" in
        --quick|-q) QUICK=1; shift ;;
        --verbose|-v) VERBOSE=1; shift ;;
        --image) IMAGE="${2:?--image needs a value}"; shift 2 ;;
        --image=*) IMAGE="${1#*=}"; shift ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
done

LOGDIR="$REPO/build/logs"
mkdir -p "$LOGDIR"

if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    DIM=$'\033[90m'; OFF=$'\033[0m'
else
    BOLD=""; RED=""; GREEN=""; YELLOW=""; DIM=""; OFF=""
fi

NAMES=(); RESULTS=(); TIMES=()
FAILED=0

# step <name> <logfile> <command...>
step() {
    local name=$1 log=$2
    shift 2
    printf '%s==> %s%s\n' "$BOLD" "$name" "$OFF"
    local start=$SECONDS rc=0
    if (( VERBOSE )); then
        "$@" 2>&1 | tee "$log"
        rc=${PIPESTATUS[0]}
    else
        "$@" >"$log" 2>&1 || rc=$?
    fi
    local elapsed=$(( SECONDS - start ))
    NAMES+=("$name"); TIMES+=("${elapsed}s")
    if (( rc == 0 )); then
        RESULTS+=("pass")
        printf '    %spass%s in %ss  %s(log: %s)%s\n' "$GREEN" "$OFF" "$elapsed" "$DIM" "$log" "$OFF"
    else
        RESULTS+=("FAIL"); FAILED=1
        printf '    %sFAILED%s in %ss  log: %s\n' "$RED" "$OFF" "$elapsed" "$log"
        if (( ! VERBOSE )); then
            printf '%s' "$DIM"
            tail -15 "$log" | sed 's/^/    | /'
            printf '%s' "$OFF"
        fi
    fi
    return $rc
}

# skip <name> <reason>
skip() {
    NAMES+=("$1"); RESULTS+=("skip"); TIMES+=("-")
    printf '%s==> %s%s\n    %sskipped: %s%s\n' "$BOLD" "$1" "$OFF" "$YELLOW" "$2" "$OFF"
    INCOMPLETE=1
}

echo "${BOLD}maze - Linux distribution checks${OFF}"
echo "${DIM}repo:  $REPO"
echo "image: $IMAGE"
echo "quick: $([[ $QUICK == 1 ]] && echo 'yes (Docker step skipped)' || echo no)${OFF}"
echo

step "1/4 syntax and version consistency (make check)" \
     "$LOGDIR/01-check.log" \
     make check

step "2/4 the game's own test suite (make test)" \
     "$LOGDIR/02-test.log" \
     make test

if (( QUICK )); then
    skip "3/4 Linux distribution gate (Docker)" "--quick given"
elif ! command -v docker >/dev/null 2>&1; then
    skip "3/4 Linux distribution gate (Docker)" "docker is not installed"
elif ! docker info >/dev/null 2>&1; then
    skip "3/4 Linux distribution gate (Docker)" \
         "the Docker daemon is not running - start Docker Desktop and re-run"
else
    step "3/4 Linux distribution gate (Docker, $IMAGE)" \
         "$LOGDIR/03-linux-distribution.log" \
         make check-linux IMAGE="$IMAGE"

    # The packaged .deb is also what the GitHub Pages apt repository serves, so
    # verify that whole path too: assemble, sign, install, and prove apt refuses
    # an unverifiable repository.
    step "4/4 apt repository (Docker, $IMAGE)" \
         "$LOGDIR/04-apt-repository.log" \
         make check-apt-repo IMAGE="$IMAGE"
fi

echo
echo "${BOLD}summary${OFF}"
for i in "${!NAMES[@]}"; do
    case "${RESULTS[$i]}" in
        pass) mark="${GREEN}pass${OFF}" ;;
        FAIL) mark="${RED}FAIL${OFF}" ;;
        *)    mark="${YELLOW}skip${OFF}" ;;
    esac
    printf '  %-56s %s  %s\n' "${NAMES[$i]}" "$mark" "${TIMES[$i]}"
done

if (( FAILED )); then
    echo
    echo "${RED}${BOLD}FAILED${OFF} - see the logs in $LOGDIR"
    exit 1
fi

if (( INCOMPLETE )); then
    echo
    echo "${YELLOW}${BOLD}INCOMPLETE${OFF} - the packaging checks did not run; nothing failed."
    exit 2
fi

echo
echo "${GREEN}${BOLD}ALL CHECKS PASSED${OFF}"
