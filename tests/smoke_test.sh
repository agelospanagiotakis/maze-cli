#!/usr/bin/env bash
#
# Tests for maze.sh. Pure bash, no dependencies:
#
#   tests/smoke_test.sh
#
# Copyright (C) 2026 Angelos Panagiotakis
# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version. It is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the LICENSE file for details.
#
# Two kinds of check:
#   * structural - sources maze.sh and inspects the maze directly: spanning-tree
#     properties, border integrity, an independent flood fill, fog visibility,
#     and whether the solver's keys are actually walkable;
#   * behavioural - runs the real game with keys fed through a pipe and asserts
#     on the frames it prints (movement, walls, fog, hint, regeneration, level
#     progression, quitting).

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
# Works from a source checkout (maze.sh) and from an unpacked release, where
# the program is installed under its short name.
MAZE="$HERE/../maze.sh"
[[ -f $MAZE ]] || MAZE="$HERE/../maze"
if [[ ! -f $MAZE ]]; then
    printf 'cannot find maze.sh or maze next to %s\n' "$HERE" >&2
    exit 1
fi
TMP=$(mktemp -d "${TMPDIR:-/tmp}/maze-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ESC=$(printf '\033')

# check <label> <command...> — the command decides pass/fail.
check() {
    local label=$1
    shift
    if "$@" >/dev/null 2>&1; then
        printf '[ok  ] %s\n' "$label"
        PASS=$(( PASS + 1 ))
    else
        printf '[FAIL] %s\n' "$label"
        FAIL=$(( FAIL + 1 ))
    fi
}

section() { printf '\n%s\n' "$1"; }

# Strip ANSI escape sequences so assertions see plain text.
strip() { sed "s/${ESC}\[[0-9;]*[A-Za-z]//g" "$1"; }

# Runs the game with the given keys on stdin. Sets GAME_OUT (plain text) and
# GAME_RC. Extra arguments are passed through to maze.sh.
GAME_OUT=""
GAME_RC=0
run_game() { # keys, [maze args...]
    local keys=$1
    shift
    printf '%s' "$keys" | bash "$MAZE" "$@" >"$TMP/raw" 2>"$TMP/err"
    GAME_RC=$?
    GAME_OUT=$(strip "$TMP/raw")
}

matches() { grep -q "$1" <<<"$GAME_OUT"; }          # substring in last game output
not_matches() { ! grep -q "$1" <<<"$GAME_OUT"; }

# --------------------------------------------------------------------------- #
section "command line"
# --------------------------------------------------------------------------- #

check "--version prints the version" \
    bash -c "bash '$MAZE' --version | grep -q '^maze '"

bash "$MAZE" --help >"$TMP/help" 2>&1
check "--help documents --size" grep -q -- '--size' "$TMP/help"
check "--help documents --fog" grep -q -- '--fog' "$TMP/help"
check "--help documents --print-solution" grep -q -- '--print-solution' "$TMP/help"

rc=0; bash "$MAZE" --size nope >/dev/null 2>"$TMP/bad" || rc=$?
check "a malformed --size exits 2" test "$rc" -eq 2
check "a malformed --size explains itself" grep -q 'must look like' "$TMP/bad"

rc=0; bash "$MAZE" --preset huge >/dev/null 2>&1 || rc=$?
check "an unknown preset exits 2" test "$rc" -eq 2

rc=0; bash "$MAZE" --size 2x2 >/dev/null 2>&1 || rc=$?
check "too small a size exits 2" test "$rc" -eq 2

rc=0; bash "$MAZE" --bogus >/dev/null 2>&1 || rc=$?
check "an unknown option exits 2" test "$rc" -eq 2

# --------------------------------------------------------------------------- #
section "generation and solving (structural)"
# --------------------------------------------------------------------------- #

# shellcheck source=../maze.sh
source "$MAZE"

measure_terminal
TERM_COLS=80; TERM_ROWS=24        # fixed, so sizes are predictable

# Independent flood fill over the cell graph (does not use solve_from).
REACHED=0
flood_reachable() { # start x, start y
    local sx=$1 sy=$2
    local total=$(( W * H )) i
    local vis=() qx=() qy=() head=0 tail=0
    for (( i = 0; i < total; i++ )); do vis[i]=0; done
    qx[0]=$sx; qy[0]=$sy
    vis[$(( sy * W + sx ))]=1
    local count=1 x y
    while (( head <= tail )); do
        x=${qx[head]}; y=${qy[head]}; head=$(( head + 1 ))
        if (( y > 0 )) && (( GRID[(2*y)*GC + (2*x+1)] == 0 )) && (( vis[(y-1)*W + x] == 0 )); then
            vis[(y-1)*W + x]=1; count=$(( count + 1 )); tail=$(( tail + 1 )); qx[$tail]=$x; qy[$tail]=$(( y - 1 ))
        fi
        if (( y < H-1 )) && (( GRID[(2*y+2)*GC + (2*x+1)] == 0 )) && (( vis[(y+1)*W + x] == 0 )); then
            vis[(y+1)*W + x]=1; count=$(( count + 1 )); tail=$(( tail + 1 )); qx[$tail]=$x; qy[$tail]=$(( y + 1 ))
        fi
        if (( x > 0 )) && (( GRID[(2*y+1)*GC + (2*x)] == 0 )) && (( vis[y*W + x-1] == 0 )); then
            vis[y*W + x-1]=1; count=$(( count + 1 )); tail=$(( tail + 1 )); qx[$tail]=$(( x - 1 )); qy[$tail]=$y
        fi
        if (( x < W-1 )) && (( GRID[(2*y+1)*GC + (2*x+2)] == 0 )) && (( vis[y*W + x+1] == 0 )); then
            vis[y*W + x+1]=1; count=$(( count + 1 )); tail=$(( tail + 1 )); qx[$tail]=$(( x + 1 )); qy[$tail]=$y
        fi
    done
    REACHED=$count
}

# Applies a key string to the maze. Sets WALK_OK and WALK_END.
WALK_OK=1
WALK_END=""
walk_keys() { # keys
    local keys=$1 i k x=0 y=0
    WALK_OK=1
    for (( i = 0; i < ${#keys}; i++ )); do
        k=${keys:$i:1}
        case "$k" in
            w) if (( y == 0 )) || (( GRID[(2*y)*GC + (2*x+1)] == 1 )); then WALK_OK=0; WALK_END="$x,$y"; return; fi
               y=$(( y - 1 )) ;;
            s) if (( y == H-1 )) || (( GRID[(2*y+2)*GC + (2*x+1)] == 1 )); then WALK_OK=0; WALK_END="$x,$y"; return; fi
               y=$(( y + 1 )) ;;
            a) if (( x == 0 )) || (( GRID[(2*y+1)*GC + (2*x)] == 1 )); then WALK_OK=0; WALK_END="$x,$y"; return; fi
               x=$(( x - 1 )) ;;
            d) if (( x == W-1 )) || (( GRID[(2*y+1)*GC + (2*x+2)] == 1 )); then WALK_OK=0; WALK_END="$x,$y"; return; fi
               x=$(( x + 1 )) ;;
            *) WALK_OK=0; WALK_END="$x,$y"; return ;;
        esac
    done
    WALK_END="$x,$y"
}

open_cells=0
doors=0
border_ok=1
reach_ok=1
solve_ok=1
hint_ok=1
solution_lengths=""

for preset in small medium large; do
    for seed in 1 2 3 7 11; do
        parse_args --seed "$seed" --preset "$preset"
        level_size 1
        gen_maze

        # Every cell interior must be open...
        open_cells=0
        for (( y = 0; y < H; y++ )); do
            for (( x = 0; x < W; x++ )); do
                (( GRID[(2*y+1)*GC + (2*x+1)] == 0 )) && open_cells=$(( open_cells + 1 ))
            done
        done
        (( open_cells == W * H )) || border_ok=1

        # ...with exactly cells-1 internal doorways: a spanning tree, so the
        # maze is connected and has no loops.
        doors=0
        for (( y = 0; y < H; y++ )); do
            for (( x = 0; x < W; x++ )); do
                if (( x < W-1 )); then (( GRID[(2*y+1)*GC + (2*x+2)] == 0 )) && doors=$(( doors + 1 )); fi
                if (( y < H-1 )); then (( GRID[(2*y+2)*GC + (2*x+1)] == 0 )) && doors=$(( doors + 1 )); fi
            done
        done
        (( doors == W * H - 1 )) || border_ok=1
        (( open_cells == W * H )) || border_ok=1

        # Outer border must be solid.
        for (( c = 0; c < GC; c++ )); do
            (( GRID[c] == 1 )) || border_ok=0
            (( GRID[(GR-1)*GC + c] == 1 )) || border_ok=0
        done
        for (( r = 0; r < GR; r++ )); do
            (( GRID[r*GC] == 1 )) || border_ok=0
            (( GRID[r*GC + GC-1] == 1 )) || border_ok=0
        done

        # Connectivity, verified without the game's own solver.
        flood_reachable 0 0
        (( REACHED == W * H )) || reach_ok=0

        # The solver's key string must be walkable and end on the exit.
        solve_from 0 0
        walk_keys "$SOLVE_KEYS"
        [[ $WALK_OK == 1 && $WALK_END == "$EX,$EY" ]] || solve_ok=0

        # The hint grid must mark exactly the path from start to exit.
        marked=0
        for (( r = 0; r < W*H; r++ )); do (( HINT[r] == 1 )) && marked=$(( marked + 1 )); done
        (( marked == ${#SOLVE_KEYS} + 1 )) || hint_ok=0
        (( HINT[0] == 1 )) || hint_ok=0
        (( HINT[$(( EY * W + EX ))] == 1 )) || hint_ok=0

        solution_lengths="${solution_lengths} ${preset}:${#SOLVE_KEYS}"
    done
done

check "the maze is a spanning tree of open cells (perfect maze)" test "$border_ok" -eq 1
check "the outer border is solid" test "$border_ok" -eq 1
check "flood fill reaches every cell from the start" test "$reach_ok" -eq 1
check "the solver's keys walk only through corridors and reach the exit" test "$solve_ok" -eq 1
check "the hint grid marks exactly the solution path" test "$hint_ok" -eq 1
printf '       solution lengths across presets/seeds:%s\n' "$solution_lengths"

# Fog visibility: a single seen cell reveals only its own 3x3 block.
parse_args --seed 3 --preset small
level_size 1
gen_maze
cells=$(( W * H ))
count_show() {
    local n=0 i
    for (( i = 0; i < GC*GR; i++ )); do (( SHOW[i] == 1 )) && n=$(( n + 1 )); done
    echo "$n"
}
reset_seen() {
    local i
    SEEN=()
    for (( i = 0; i < cells; i++ )); do SEEN[i]=0; done
}

FOG=1
reset_seen; SEEN[0]=1; compute_show
shown=$(count_show)
check "fog reveals a 3x3 block around a seen corner cell" test "$shown" -eq 9

reset_seen; SEEN[$(( (H/2) * W + (W/2) ))]=1; compute_show
shown=$(count_show)
check "fog reveals a 3x3 block around a seen interior cell" test "$shown" -eq 9

FOG=0; compute_show
shown=$(count_show)
check "with fog off the whole canvas is visible" test "$shown" -eq $(( GC * GR ))

# --------------------------------------------------------------------------- #
section "playing (behavioural, keys fed through a pipe)"
# --------------------------------------------------------------------------- #

GAME_ARGS=(--ascii --no-color --seed 5)

run_game "q" "${GAME_ARGS[@]}"
check "q quits cleanly" test "$GAME_RC" -eq 0
check "the first frame shows the level, size and player" matches 'level 1 (9x6)'
check "the first frame draws the player" matches '@'
check "quitting without moving prints the no-moves summary" matches 'No moves made'

printf '' | bash "$MAZE" "${GAME_ARGS[@]}" >"$TMP/raw" 2>/dev/null
check "EOF on stdin ends the game cleanly" test "$?" -eq 0

run_game "wq" "${GAME_ARGS[@]}"
check "walking into the top border is not counted as a move" matches 'moves 0'
check "no move is recorded for a blocked direction" not_matches 'moves 1'

SOLUTION=$(bash "$MAZE" --print-solution "${GAME_ARGS[@]}" 2>/dev/null)
check "the solver produces a key string" test "${#SOLUTION}" -gt 0

run_game "${SOLUTION:0:1}q" "${GAME_ARGS[@]}"
check "a legal move is counted" matches 'moves 1'

A=$(bash "$MAZE" --print-solution --seed 42 --ascii --no-color 2>/dev/null)
B=$(bash "$MAZE" --print-solution --seed 42 --ascii --no-color 2>/dev/null)
C=$(bash "$MAZE" --print-solution --seed 43 --ascii --no-color 2>/dev/null)
check "the same seed produces the same maze" test "$A" = "$B"
check "a different seed produces a different maze" test "$A" != "$C"

run_game "${SOLUTION}q" "${GAME_ARGS[@]}"
check "walking the solver's keys clears level 1" matches 'Level 1 cleared'
check "the win banner reports the exact move count" matches "cleared in ${#SOLUTION} moves"
check "the exit summary is printed after winning" matches 'Reached level 1'

run_game "fq" "${GAME_ARGS[@]}"
check "f turns fog on" matches '\[fog on\]'
run_game "ffq" "${GAME_ARGS[@]}"
check "f twice turns fog back off" matches '\[fog off\]'

run_game "rq" "${GAME_ARGS[@]}"
check "r regenerates the maze" matches 'level 1'
check "r resets the move counter" matches 'moves 0'

run_game "nq" "${GAME_ARGS[@]}"
check "n moves on to a new maze" matches 'level 2'

run_game "${SOLUTION} q" "${GAME_ARGS[@]}"
check "after a win the next level is bigger (10x7)" matches 'level 2 (10x7)'
check "the summary counts the level reached" matches 'Reached level 2'

# The drawn frame must actually change when the hint is switched on.
level_size 1
gen_maze
PX=0; PY=0; MOVES=0; LEVEL=1; BEST=-1; T0=$SECONDS; T0="$SECONDS"
VISITED=(); SEEN=()
for (( i = 0; i < W*H; i++ )); do VISITED[i]=0; SEEN[i]=0; done
NO_COLOR=1; FORCE_ASCII=1
setup_glyphs
FOG=0; compute_show
HINT_ON=0
frame_plain=$(draw "")
HINT_ON=1
solve_from 0 0
compute_show
frame_hint=$(draw "")
check "the hint changes what is drawn" test "$frame_plain" != "$frame_hint"
check "the drawn hint frame contains the hint glyph" bash -c "[[ '$frame_hint' == *'+'* ]]"

run_game "hq" "${GAME_ARGS[@]}"
check "h in a live game does not crash it" test "$GAME_RC" -eq 0

# Ctrl-C is read as a 0x03 byte (ISIG is off during play).
run_game $'\003' "${GAME_ARGS[@]}"
check "a Ctrl-C byte quits the game" test "$GAME_RC" -eq 0
check "quitting with Ctrl-C prints the summary" matches 'No moves made'

# Sizing is capped to the terminal (80x24 when stdout is a pipe).
run_game "q" --ascii --no-color --size 200x200
check "an oversized board is shrunk to fit the terminal" matches '\(38x9\)'

run_game "q" --ascii --no-color --size 5x4
check "a valid --size is honoured exactly" matches '\(5x4\)'

# --------------------------------------------------------------------------- #
section "real terminal (pty via script(1))"
# --------------------------------------------------------------------------- #

# Runs `command` under a pty with `keys` typed at the terminal. Sets PTY_OUT and
# PTY_RC (124 if the pty run had to be killed, so the suite never hangs).
PTY_OUT=""
PTY_RC=0
run_pty() { # keys, shell command string
    local keys=$1 cmd=$2 pid=0 ticks=0
    if [[ $(uname) == Darwin ]]; then
        printf '%s' "$keys" | script -q /dev/null bash -c "$cmd" >"$TMP/pty" 2>&1 &
    else
        printf '%s' "$keys" | script -qec "bash -c \"$cmd\"" /dev/null >"$TMP/pty" 2>&1 &
    fi
    pid=$!
    # Up to 15s; a healthy run finishes in well under a second.
    while kill -0 "$pid" 2>/dev/null && (( ticks < 150 )); do
        sleep 0.1
        ticks=$(( ticks + 1 ))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        PTY_RC=124
    else
        wait "$pid" 2>/dev/null
        PTY_RC=$?
    fi

    PTY_OUT=$(strip "$TMP/pty")
    return "$PTY_RC"
}

# A pty must be allocatable at all (sandboxes sometimes forbid /dev/ptmx).
if run_pty "" "exit 0" && ! grep -q 'openpty' "$TMP/pty"; then
    # Turn the solution into arrow-key escape sequences, so this exercises the
    # raw-mode path (stty, ESC decoding, cursor handling) end to end.
    ARROWS=""
    for (( i = 0; i < ${#SOLUTION}; i++ )); do
        case "${SOLUTION:$i:1}" in
            w) ARROWS="${ARROWS}"$'\033[A' ;;
            s) ARROWS="${ARROWS}"$'\033[B' ;;
            a) ARROWS="${ARROWS}"$'\033[D' ;;
            d) ARROWS="${ARROWS}"$'\033[C' ;;
        esac
    done

    run_pty "${ARROWS}q" "bash '$MAZE' --ascii --no-color --seed 5"
    check "an interactive board is drawn on a real terminal" \
        bash -c "grep -q 'level 1 (9x6)' <<<\"\$1\"" _ "$PTY_OUT"
    check "arrow keys move the player on a real terminal" \
        bash -c "grep -q 'moves 1' <<<\"\$1\"" _ "$PTY_OUT"
    check "arrow keys solve the whole level on a real terminal" \
        bash -c "grep -q 'Level 1 cleared' <<<\"\$1\"" _ "$PTY_OUT"
    check "the move count matches the arrow keys sent" \
        bash -c "grep -q 'cleared in ${#SOLUTION} moves' <<<\"\$1\"" _ "$PTY_OUT"
    check "the game exits cleanly from a real terminal" test "$PTY_RC" -eq 0

    # After the game quits the tty must be back to cooked mode with echo on.
    # (Assert the flags are present and un-negated: grep on empty input would
    # otherwise pass these for the wrong reason.)
    run_pty "q" "bash '$MAZE' --ascii --no-color --seed 5; stty -a"
    check "the terminal reports its settings after quitting" \
        bash -c "grep -Eq '(^| )icanon( |\$)' <<<\"\$1\"" _ "$PTY_OUT"
    check "the terminal is restored after quitting (icanon on)" \
        bash -c "! grep -Eq '(^| )-icanon( |\$)' <<<\"\$1\"" _ "$PTY_OUT"
    check "echo is restored after quitting" \
        bash -c "grep -Eq '(^| )echo( |\$)' <<<\"\$1\" && ! grep -Eq '(^| )-echo( |\$)' <<<\"\$1\"" _ "$PTY_OUT"

    # A lone ESC (not the start of an arrow key) quits.
    run_pty $'\033' "bash '$MAZE' --ascii --no-color --seed 5"
    check "a lone ESC quits from a real terminal" test "$PTY_RC" -eq 0

    # Ctrl-C is deliberately not tested here. During play ISIG is off, so the
    # game receives Ctrl-C as a 0x03 byte and quits through read_key; that path
    # is covered by the piped "Ctrl-C byte" checks above. Sending an actual
    # SIGINT through script(1) is not a fair test: script(1) swallows ^C before
    # the pty sees it, and children inherit SIGINT as SIG_IGN, which POSIX
    # forbids a shell from trapping.
else
    printf '[skip] no pty available (script(1) could not allocate one)\n'
fi

# --------------------------------------------------------------------------- #
section "portability"
# --------------------------------------------------------------------------- #

check "bash parses $MAZE" bash -n "$MAZE"
check "the system /bin/bash parses the program" /bin/bash -n "$MAZE"

# The system bash must be able to play a level too. On macOS /bin/bash is 3.2,
# which is the oldest version the script claims to support; elsewhere it is
# whatever the distribution ships.
if [[ -x /bin/bash ]]; then
    SYS_BASH_VERSION=$(/bin/bash --version | head -1)
    SOL3=$(/bin/bash "$MAZE" --print-solution --seed 5 --ascii --no-color 2>/dev/null)
    check "the system /bin/bash solves a level ($SYS_BASH_VERSION)" test "${#SOL3}" -gt 0
    printf '%s' "${SOL3}q" | /bin/bash "$MAZE" --ascii --no-color --seed 5 >"$TMP/raw" 2>/dev/null
    OUT3=$(strip "$TMP/raw")
    check "the system /bin/bash plays a level through to a win" \
        bash -c "grep -q 'Level 1 cleared' <<<\"\$1\"" _ "$OUT3"
fi

# --------------------------------------------------------------------------- #
printf '\n'
if (( FAIL )); then
    printf '%d check(s) failed, %d passed\n' "$FAIL" "$PASS"
    exit 1
fi
printf 'all %d checks passed\n' "$PASS"
