#!/usr/bin/env bash
#
# maze - a tiny auto-generated maze game for Linux and macOS terminals.
# Copyright (C) 2026 Angelos Panagiotakis
# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
# details: see the LICENSE file, or <https://www.gnu.org/licenses/>.
#
# Pure bash (3.2+, so stock macOS /bin/bash works). No dependencies, no
# external commands on the hot path: only bash builtins are used while playing.
#
# Move with the arrow keys (or WASD) and reach the exit.
# Every level is a freshly generated maze that grows a little each time.
#
# Controls:
#   arrows / wasd          move
#   h                      show/hide a hint path
#   r                      regenerate the current maze
#   n                      jump to a new maze
#   f                      toggle fog of war
#   q, Esc, Ctrl-C         quit

set -u

VERSION="1.0.0"
COPYRIGHT_HOLDER="Angelos Panagiotakis"
COPYRIGHT_YEAR="2026"
LICENSE_NAME="GPL-3.0-or-later"

# --------------------------------------------------------------------------- #
# defaults / options
# --------------------------------------------------------------------------- #

PRESET="small"
SIZE_OPT=""
SEED=""
FOG_START=0
FORCE_ASCII=0
NO_COLOR=0
PRINT_SOLUTION=0

usage() {
    local prog
    prog=$(basename "$0")
    cat <<EOF
Play a simple auto-generated maze in your terminal.

Usage: $prog [options]

  --size CxR          fixed maze size in cells, e.g. --size 12x8
  --preset NAME       small (9x6, default) | medium (16x11) | large (25x17)
  --seed N            seed for reproducible mazes
  --fog               start with fog of war enabled
  --ascii             force plain ASCII glyphs instead of box drawing
  --no-color          disable ANSI colours
  --print-solution    print the keystrokes that solve level 1, then exit
  -h, --help          show this help
  --version           show the version and licence

Move with the arrow keys or WASD. Reach the exit. Press h for a hint path.

maze $VERSION, Copyright (C) $COPYRIGHT_YEAR $COPYRIGHT_HOLDER
Free software under the GNU General Public License, version 3 or later
($LICENSE_NAME). There is NO WARRANTY. See the LICENSE file for details.
EOF
}

parse_args() {
    local re='^([0-9]+)x([0-9]+)$'
    while (( $# )); do
        case "$1" in
            --size)
                [[ $# -ge 2 ]] || { echo "maze: --size needs a value" >&2; exit 2; }
                SIZE_OPT="$2"; shift 2 ;;
            --size=*) SIZE_OPT="${1#*=}"; shift ;;
            --preset)
                [[ $# -ge 2 ]] || { echo "maze: --preset needs a value" >&2; exit 2; }
                PRESET="$2"; shift 2 ;;
            --preset=*) PRESET="${1#*=}"; shift ;;
            --seed)
                [[ $# -ge 2 ]] || { echo "maze: --seed needs a value" >&2; exit 2; }
                SEED="$2"; shift 2 ;;
            --seed=*) SEED="${1#*=}"; shift ;;
            --fog) FOG_START=1; shift ;;
            --ascii) FORCE_ASCII=1; shift ;;
            --no-color) NO_COLOR=1; shift ;;
            --print-solution) PRINT_SOLUTION=1; shift ;;
            -h|--help) usage; exit 0 ;;
            --version)
                echo "maze $VERSION"
                echo "Copyright (C) $COPYRIGHT_YEAR $COPYRIGHT_HOLDER"
                echo "Licence $LICENSE_NAME: GNU GPL v3 or later, with NO WARRANTY."
                echo "This is free software: you are welcome to redistribute it under"
                echo "the terms of the GNU General Public License."
                exit 0 ;;
            *) echo "maze: unknown option: $1" >&2; echo "try: maze.sh --help" >&2; exit 2 ;;
        esac
    done

    case "$PRESET" in
        small)  BASE_W=9;  BASE_H=6 ;;
        medium) BASE_W=16; BASE_H=11 ;;
        large)  BASE_W=25; BASE_H=17 ;;
        *) echo "maze: unknown preset: $PRESET (try small, medium or large)" >&2; exit 2 ;;
    esac

    FIXED_W=0; FIXED_H=0
    if [[ -n $SIZE_OPT ]]; then
        if [[ $SIZE_OPT =~ $re ]]; then
            FIXED_W="${BASH_REMATCH[1]}"
            FIXED_H="${BASH_REMATCH[2]}"
            if (( FIXED_W < 3 || FIXED_H < 3 )); then
                echo "maze: size must be at least 3x3" >&2; exit 2
            fi
        else
            echo "maze: --size must look like 12x8 (columns x rows)" >&2
            exit 2
        fi
    fi

    if [[ -n $SEED ]]; then
        case "$SEED" in
            ''|*[!0-9]*) echo "maze: --seed must be a non-negative integer" >&2; exit 2 ;;
        esac
        RANDOM="$SEED"
    fi
}

# --------------------------------------------------------------------------- #
# glyphs and colours
# --------------------------------------------------------------------------- #

setup_glyphs() {
    local locale_name="${LC_ALL:-${LANG:-}}"
    local fancy=0
    if (( FORCE_ASCII == 0 )); then
        case "$locale_name" in
            *UTF-8*|*utf-8*|*UTF8*|*utf8*) fancy=1 ;;
        esac
        # A UTF-8 locale is only a hint; box drawing is safe on any modern
        # terminal, so also allow it when the locale says nothing at all.
        [[ -z $locale_name ]] && fancy=1
    fi
    if (( fancy )); then
        ASCII_GLYPHS=0
        G_H='─'; G_V='│'
        G_PLAYER='@'; G_EXIT='★'; G_VISITED='·'; G_HINT='+'
        G_ARROW_N='↑'; G_ARROW_S='↓'; G_ARROW_E='→'; G_ARROW_W='←'
    else
        ASCII_GLYPHS=1
        G_H='-'; G_V='|'
        G_PLAYER='@'; G_EXIT='E'; G_VISITED='.'; G_HINT='+'
        G_ARROW_N='N'; G_ARROW_S='S'; G_ARROW_E='E'; G_ARROW_W='W'
    fi

    # Colours are only useful on a terminal.
    if (( NO_COLOR )) || [[ ! -t 1 ]]; then
        COLOR=0
    else
        COLOR=1
    fi
    C_RESET=$'\033[0m'
    C_WALL=$'\033[38;5;245m'
    C_PLAYER=$'\033[1;33m'
    C_EXIT=$'\033[1;32m'
    C_VISITED=$'\033[38;5;240m'
    C_HINT=$'\033[38;5;44m'
    C_HUD=$'\033[36m'
    C_GOOD=$'\033[1;32m'
    C_DIM=$'\033[90m'
    C_FLOOR=''
}

# --------------------------------------------------------------------------- #
# maze generation (iterative recursive backtracker -> perfect maze)
# --------------------------------------------------------------------------- #

gen_maze() {
    local gc=$(( 2 * W + 1 ))
    local gr=$(( 2 * H + 1 ))
    GC=$gc; GR=$gr
    local total=$(( gc * gr ))
    local i

    GRID=()
    for (( i = 0; i < total; i++ )); do GRID[i]=1; done

    local seen=()
    local cells=$(( W * H ))
    for (( i = 0; i < cells; i++ )); do seen[i]=0; done

    # DFS stack
    local sx=() sy=() top=0
    local x=0 y=0
    seen[0]=1
    GRID[$(( 1 * gc + 1 ))]=0
    sx[0]=0; sy[0]=0

    local opts nx ny d
    while (( top >= 0 )); do
        x=${sx[top]}; y=${sy[top]}
        opts=""
        if (( y > 0 ))   && (( seen[(y-1)*W + x] == 0 )); then opts="${opts}N"; fi
        if (( y < H-1 )) && (( seen[(y+1)*W + x] == 0 )); then opts="${opts}S"; fi
        if (( x > 0 ))   && (( seen[y*W + x-1] == 0 )); then opts="${opts}W"; fi
        if (( x < W-1 )) && (( seen[y*W + x+1] == 0 )); then opts="${opts}E"; fi

        if [[ -z $opts ]]; then
            top=$(( top - 1 ))
            continue
        fi

        d="${opts:$(( RANDOM % ${#opts} )):1}"
        case "$d" in
            N) nx=$x; ny=$(( y - 1 )); GRID[$(( (2*y) * gc + (2*x+1) ))]=0 ;;
            S) nx=$x; ny=$(( y + 1 )); GRID[$(( (2*y+2) * gc + (2*x+1) ))]=0 ;;
            W) nx=$(( x - 1 )); ny=$y; GRID[$(( (2*y+1) * gc + (2*x) ))]=0 ;;
            E) nx=$(( x + 1 )); ny=$y; GRID[$(( (2*y+1) * gc + (2*x+2) ))]=0 ;;
        esac
        seen[$(( ny * W + nx ))]=1
        GRID[$(( (2*ny+1) * gc + (2*nx+1) ))]=0
        top=$(( top + 1 ))
        sx[top]=$nx; sy[top]=$ny
    done

    EX=$(( W - 1 )); EY=$(( H - 1 ))
}

# --------------------------------------------------------------------------- #
# solving (BFS over cells); fills SOLVE_KEYS and the HINT grid
# --------------------------------------------------------------------------- #

solve_from() {
    local start_x=$1 start_y=$2
    local cells=$(( W * H ))
    local i
    PARENT=()
    for (( i = 0; i < cells; i++ )); do PARENT[i]=""; done
    HINT=()
    for (( i = 0; i < cells; i++ )); do HINT[i]=0; done

    local qx=() qy=() head=0 tail=0
    qx[0]=$start_x; qy[0]=$start_y
    # "*" marks the start; the directions N/S/E/W mean "reached from the north/
    # south/east/west", so they must not be confused with the start marker.
    PARENT[$(( start_y * W + start_x ))]="*"

    local x y
    while (( head <= tail )); do
        x=${qx[head]}; y=${qy[head]}; head=$(( head + 1 ))
        if (( x == EX && y == EY )); then break; fi

        if (( y > 0 )) && (( GRID[$(( (2*y) * GC + (2*x+1) ))] == 0 )) \
           && [[ -z ${PARENT[$(( (y-1) * W + x ))]} ]]; then
            PARENT[$(( (y-1) * W + x ))]="N"
            tail=$(( tail + 1 )); qx[$tail]=$x; qy[$tail]=$(( y - 1 ))
        fi
        if (( y < H-1 )) && (( GRID[$(( (2*y+2) * GC + (2*x+1) ))] == 0 )) \
           && [[ -z ${PARENT[$(( (y+1) * W + x ))]} ]]; then
            PARENT[$(( (y+1) * W + x ))]="S"
            tail=$(( tail + 1 )); qx[$tail]=$x; qy[$tail]=$(( y + 1 ))
        fi
        if (( x > 0 )) && (( GRID[$(( (2*y+1) * GC + (2*x) ))] == 0 )) \
           && [[ -z ${PARENT[$(( y * W + x-1 ))]} ]]; then
            PARENT[$(( y * W + x-1 ))]="W"
            tail=$(( tail + 1 )); qx[$tail]=$(( x - 1 )); qy[$tail]=$y
        fi
        if (( x < W-1 )) && (( GRID[$(( (2*y+1) * GC + (2*x+2) ))] == 0 )) \
           && [[ -z ${PARENT[$(( y * W + x+1 ))]} ]]; then
            PARENT[$(( y * W + x+1 ))]="E"
            tail=$(( tail + 1 )); qx[$tail]=$(( x + 1 )); qy[$tail]=$y
        fi
    done

    # Walk back from the exit to the start, marking the path and its keys.
    SOLVE_KEYS=""
    local cx=$EX cy=$EY d solved=0
    HINT[$(( start_y * W + start_x ))]=1
    if (( start_x == EX && start_y == EY )); then solved=1; fi
    while (( solved == 0 )); do
        d="${PARENT[$(( cy * W + cx ))]}"
        if [[ -z $d || $d == "*" ]]; then
            echo "maze: internal error: no path to the exit" >&2
            exit 1
        fi
        HINT[$(( cy * W + cx ))]=1
        case "$d" in
            N) SOLVE_KEYS="w${SOLVE_KEYS}"; cy=$(( cy + 1 )) ;;
            S) SOLVE_KEYS="s${SOLVE_KEYS}"; cy=$(( cy - 1 )) ;;
            W) SOLVE_KEYS="a${SOLVE_KEYS}"; cx=$(( cx + 1 )) ;;
            E) SOLVE_KEYS="d${SOLVE_KEYS}"; cx=$(( cx - 1 )) ;;
        esac
        if (( cx == start_x && cy == start_y )); then solved=1; fi
    done
}

# --------------------------------------------------------------------------- #
# sizing
# --------------------------------------------------------------------------- #

measure_terminal() {
    local cols="" rows="" size=""

    if [[ -t 1 ]]; then
        # stty size is authoritative, but a pty with no window size (script(1),
        # some CI runners) reports "0 0", which would shrink the board to
        # nothing, so fall back to tput and then to a sane default.
        size=$(stty size 2>/dev/null) || size=""
        if [[ $size == *" "* ]]; then
            rows="${size%% *}"
            cols="${size##* }"
        fi
        if [[ ! $cols =~ ^[0-9]+$ ]] || (( cols < 10 )); then
            cols=$(tput cols 2>/dev/null) || cols=""
        fi
        if [[ ! $rows =~ ^[0-9]+$ ]] || (( rows < 5 )); then
            rows=$(tput lines 2>/dev/null) || rows=""
        fi
    fi

    if [[ ! $cols =~ ^[0-9]+$ ]] || (( cols < 10 )); then cols=80; fi
    if [[ ! $rows =~ ^[0-9]+$ ]] || (( rows < 5 )); then rows=24; fi

    TERM_COLS=$cols
    TERM_ROWS=$rows
}

# Cells for a level, shrunk to fit the terminal and capped.
level_size() {
    local level=$1
    local max_w=$(( (TERM_COLS - 3) / 2 ))
    local max_h=$(( (TERM_ROWS - 5) / 2 ))
    (( max_w < 3 )) && max_w=3
    (( max_h < 3 )) && max_h=3
    (( max_w > 40 )) && max_w=40
    (( max_h > 24 )) && max_h=24

    if (( FIXED_W > 0 )); then
        W=$FIXED_W; H=$FIXED_H
    else
        W=$(( BASE_W + level - 1 ))
        H=$(( BASE_H + level - 1 ))
    fi
    (( W > max_w )) && W=$max_w
    (( H > max_h )) && H=$max_h
    (( W < 3 )) && W=3
    (( H < 3 )) && H=3
}

# --------------------------------------------------------------------------- #
# terminal setup
# --------------------------------------------------------------------------- #

SAVED_STTY=""

restore_terminal() {
    if [[ -n $SAVED_STTY ]]; then
        stty "$SAVED_STTY" 2>/dev/null || true
        SAVED_STTY=""
    fi
    printf '\033[?25h' 2>/dev/null || true
}

setup_terminal() {
    if [[ -t 0 ]]; then
        SAVED_STTY=$(stty -g 2>/dev/null || true)
        # -isig makes Ctrl-C arrive as a plain 0x03 byte that read_key handles
        # itself, rather than a SIGINT that only reaches us when this process
        # happens to be the pty's foreground process group (it is not, e.g.,
        # when the game is backgrounded). The game restores the terminal before
        # exiting, so the shell gets its normal Ctrl-C back afterwards.
        stty -echo -icanon min 1 time 0 -isig 2>/dev/null || true
        # Also tidy up if a signal is delivered externally (kill -INT).
        trap restore_terminal EXIT
        trap 'exit 130' INT TERM
        printf '\033[?25l'
    fi
}

# --------------------------------------------------------------------------- #
# input
# --------------------------------------------------------------------------- #

# Reads one key. Sets KEY and returns 0, or returns 1 on timeout / 2 on EOF.
# Bare ESC is treated as QUIT.
read_key() {
    local timeout=$1
    local k="" rest="" rc=0
    KEY=""

    IFS= read -rsn1 -t "$timeout" k
    rc=$?
    if (( rc > 128 )); then return 1; fi        # timed out, no key
    if (( rc != 0 )); then return 2; fi         # EOF

    if [[ $k == $'\033' ]]; then
        # Arrow keys arrive as ESC [ A/B/C/D in one burst, so this returns at
        # once for a real arrow key; a lone ESC just waits out the timeout.
        IFS= read -rsn2 -t "$timeout" rest
        rc=$?
        if (( rc != 0 )); then KEY="QUIT"; return 0; fi
        case "$rest" in
            '[A'|'OA') KEY="UP" ;;
            '[B'|'OB') KEY="DOWN" ;;
            '[C'|'OC') KEY="RIGHT" ;;
            '[D'|'OD') KEY="LEFT" ;;
            *) KEY="OTHER" ;;
        esac
        return 0
    fi

    case "$k" in
        $'\003') KEY="QUIT" ;;                # Ctrl-C (ISIG is off)
        w|W) KEY="UP" ;;
        s|S) KEY="DOWN" ;;
        a|A) KEY="LEFT" ;;
        d|D) KEY="RIGHT" ;;
        q|Q) KEY="QUIT" ;;
        r|R) KEY="REGEN" ;;
        n|N) KEY="NEW" ;;
        f|F) KEY="FOG" ;;
        h|H) KEY="HINT" ;;
        *) KEY="OTHER" ;;
    esac
    return 0
}

# --------------------------------------------------------------------------- #
# rendering
# --------------------------------------------------------------------------- #

# Sets JCH to the box-drawing character joining the given directions.
# Args: up down left right (each 0/1)
junction_to_var() {
    local m=$(( $1 * 8 + $2 * 4 + $3 * 2 + $4 ))
    if (( ASCII_GLYPHS )); then
        if (( ($1 || $2) && ($3 || $4) )); then JCH='+'
        elif (( $1 || $2 )); then JCH='|'
        elif (( $3 || $4 )); then JCH='-'
        else JCH=' '; fi
        return
    fi
    case $m in
        15) JCH='┼' ;; 14) JCH='┤' ;; 13) JCH='├' ;; 12) JCH='│' ;;
        11) JCH='┴' ;;  7) JCH='┬' ;; 10) JCH='┘' ;;  9) JCH='└' ;;
         6) JCH='┐' ;;  5) JCH='┌' ;;  8|4) JCH='│' ;; 2|1) JCH='─' ;;
         3) JCH='─' ;;   *) JCH=' ' ;;
    esac
}

# SHOW[i] = 1 when canvas position i may be drawn (fog hides the rest).
compute_show() {
    local total=$(( GC * GR )) i
    if (( FOG == 0 )); then
        for (( i = 0; i < total; i++ )); do SHOW[i]=1; done
        return
    fi
    for (( i = 0; i < total; i++ )); do SHOW[i]=0; done
    local x y r c
    for (( y = 0; y < H; y++ )); do
        for (( x = 0; x < W; x++ )); do
            (( SEEN[y * W + x] == 1 )) || continue
            # A seen cell reveals its own 3x3 block, which also covers every
            # wall and corner post it touches.
            for (( r = 2*y; r <= 2*y + 2; r++ )); do
                (( r < GR )) || continue
                for (( c = 2*x; c <= 2*x + 2; c++ )); do
                    (( c < GC )) || continue
                    SHOW[r * GC + c]=1
                done
            done
        done
    done
}

format_time() {
    local t=$1
    printf '%d:%02d' $(( t / 60 )) $(( t % 60 ))
}

# Sets HUD_LINE for the current state.
build_hud() {
    local elapsed=$(( SECONDS - T0 ))
    local compass="" dx dy
    dx=$(( EX - PX )); dy=$(( EY - PY ))
    if (( dx != 0 || dy != 0 )); then
        compass="  exit "
        if (( dx > 0 )); then compass="${compass}${G_ARROW_E}"
        elif (( dx < 0 )); then compass="${compass}${G_ARROW_W}"; fi
        if (( dy > 0 )); then compass="${compass}${G_ARROW_S}"
        elif (( dy < 0 )); then compass="${compass}${G_ARROW_N}"; fi
    fi
    local best="—"
    (( BEST >= 0 )) && best="$BEST"
    HUD_LINE="  maze v${VERSION}   level ${LEVEL} (${W}x${H})   moves ${MOVES}   time $(format_time "$elapsed")   best ${best}${compass}   [fog $( (( FOG )) && echo on || echo off )]"
}

# Sets HUD_LINE extras; draws the whole frame.
draw() {
    local message="${1:-}"
    build_hud

    local out="" line="" color="" cur="" ch="" idx=0
    out="${C_HUD}${HUD_LINE}${C_RESET}"$'\n\n'

    local r c cx cy cidx u d l rt gap
    for (( r = 0; r < GR; r++ )); do
        line=""
        cur="__none__"
        for (( c = 0; c < GC; c++ )); do
            idx=$(( r * GC + c ))
            ch=""
            color=""

            if (( r % 2 == 1 && c % 2 == 1 )); then
                cx=$(( (c - 1) / 2 )); cy=$(( (r - 1) / 2 ))
                cidx=$(( cy * W + cx ))
                if (( SHOW[idx] == 0 )); then
                    ch=" "; color="$C_FLOOR"
                elif (( cx == PX && cy == PY )); then
                    ch="$G_PLAYER"; color="$C_PLAYER"
                elif (( cx == EX && cy == EY )); then
                    ch="$G_EXIT"; color="$C_EXIT"
                elif (( HINT_ON && HINT[cidx] == 1 )); then
                    ch="$G_HINT"; color="$C_HINT"
                elif (( VISITED[cidx] == 1 )); then
                    ch="$G_VISITED"; color="$C_VISITED"
                else
                    ch=" "; color="$C_FLOOR"
                fi
            elif (( GRID[idx] == 0 )); then
                ch=" "; color="$C_FLOOR"
            elif (( SHOW[idx] == 0 )); then
                ch=" "; color="$C_FLOOR"
            elif (( r % 2 == 0 && c % 2 == 0 )); then
                u=0; d=0; l=0; rt=0
                (( r > 0 ))      && u=${GRID[$(( idx - GC ))]}
                (( r < GR - 1 )) && d=${GRID[$(( idx + GC ))]}
                (( c > 0 ))      && l=${GRID[$(( idx - 1 ))]}
                (( c < GC - 1 )) && rt=${GRID[$(( idx + 1 ))]}
                junction_to_var "$u" "$d" "$l" "$rt"
                ch="$JCH"; color="$C_WALL"
            elif (( r % 2 == 0 )); then
                ch="$G_H"; color="$C_WALL"
            else
                ch="$G_V"; color="$C_WALL"
            fi

            if (( COLOR )) && [[ $color != "$cur" ]]; then
                line="${line}${color}"
                cur="$color"
            fi
            line="${line}${ch}"
        done
        out="${out}${line}"
        (( COLOR )) && out="${out}${C_RESET}"
        out="${out}"$'\033[K'$'\n'
    done

    out="${out}"$'\n'
    if [[ -n $message ]]; then
        out="${out}  ${C_GOOD}${message}${C_RESET}"$'\n'
    else
        out="${out}  ${C_DIM}arrows / wasd move   h hint   r regenerate   n new maze   f fog   q quit${C_RESET}"$'\n'
    fi

    printf '\033[H%s\033[J' "$out"
}

# --------------------------------------------------------------------------- #
# game
# --------------------------------------------------------------------------- #

BEST=-1
LEVEL=1
TOT_MOVES=0
TOT_TIME=0

# Plays one level. Sets PLAY_RESULT to quit|next|regen|new.
play_level() {
    level_size "$LEVEL"
    gen_maze

    PX=0; PY=0
    MOVES=0
    HINT_ON=0
    local cells=$(( W * H )) i
    # HINT is filled in lazily by solve_from, but draw() reads it as soon as
    # hint mode is on, so give it a definite empty state up front.
    VISITED=(); SEEN=(); HINT=()
    for (( i = 0; i < cells; i++ )); do VISITED[i]=0; SEEN[i]=0; HINT[i]=0; done
    VISITED[0]=1; SEEN[0]=1
    FOG=$FOG_START

    T0=$SECONDS
    printf '\033[2J'

    local rc=0
    while :; do
        compute_show
        draw ""

        rc=0
        read_key 1 || rc=$?
        if (( rc == 2 )); then                # EOF / closed input
            PLAY_RESULT="quit"
            return
        fi
        if (( rc == 1 )); then
            # Timed out waiting for a key; loop round to refresh the clock.
            continue
        fi

        case "$KEY" in
            QUIT)  PLAY_RESULT="quit"; return ;;
            REGEN) PLAY_RESULT="regen"; return ;;
            NEW)   PLAY_RESULT="new"; return ;;
            FOG)
                if (( FOG )); then FOG=0; else FOG=1; fi
                continue ;;
            HINT)
                if (( HINT_ON )); then
                    HINT_ON=0
                else
                    HINT_ON=1
                    solve_from "$PX" "$PY"
                fi
                continue ;;
            UP|DOWN|LEFT|RIGHT) ;;
            *) continue ;;
        esac

        # Move, unless a wall (or the border) is in the way.
        case "$KEY" in
            UP)
                (( PY == 0 )) && continue
                (( GRID[$(( (2*PY) * GC + (2*PX+1) ))] == 1 )) && continue
                PY=$(( PY - 1 )) ;;
            DOWN)
                (( PY == H-1 )) && continue
                (( GRID[$(( (2*PY+2) * GC + (2*PX+1) ))] == 1 )) && continue
                PY=$(( PY + 1 )) ;;
            LEFT)
                (( PX == 0 )) && continue
                (( GRID[$(( (2*PY+1) * GC + (2*PX) ))] == 1 )) && continue
                PX=$(( PX - 1 )) ;;
            RIGHT)
                (( PX == W-1 )) && continue
                (( GRID[$(( (2*PY+1) * GC + (2*PX+2) ))] == 1 )) && continue
                PX=$(( PX + 1 )) ;;
        esac
        MOVES=$(( MOVES + 1 ))
        VISITED[$(( PY * W + PX ))]=1

        if (( FOG )); then
            local fx fy
            for (( fy = PY - 2; fy <= PY + 2; fy++ )); do
                (( fy < 0 || fy >= H )) && continue
                for (( fx = PX - 2; fx <= PX + 2; fx++ )); do
                    (( fx < 0 || fx >= W )) && continue
                    SEEN[$(( fy * W + fx ))]=1
                done
            done
        fi

        if (( HINT_ON )); then solve_from "$PX" "$PY"; fi

        if (( PX == EX && PY == EY )); then
            local elapsed=$(( SECONDS - T0 ))
            TOT_MOVES=$(( TOT_MOVES + MOVES ))
            TOT_TIME=$(( TOT_TIME + elapsed ))
            if (( BEST < 0 || MOVES < BEST )); then BEST=$MOVES; fi
            compute_show
            draw "Level ${LEVEL} cleared in ${MOVES} moves, $(format_time "$elapsed").  Press any key to continue."
            # Any key dismisses the banner (Ctrl-C / q / EOF quit).
            local k2
            if IFS= read -rsn1 -t 30 k2; then
                case "$k2" in
                    q|Q) PLAY_RESULT="quit"; return ;;
                esac
            fi
            LEVEL=$(( LEVEL + 1 ))
            PLAY_RESULT="next"
            return
        fi
    done
}

main() {
    parse_args "$@"
    setup_glyphs
    setup_terminal

    if (( PRINT_SOLUTION )); then
        measure_terminal
        level_size 1
        gen_maze
        PX=0; PY=0
        solve_from 0 0
        printf '%s\n' "$SOLVE_KEYS"
        exit 0
    fi

    if [[ ! -t 0 ]]; then
        echo "maze: note: stdin is not a terminal; keys are read from the pipe" >&2
    fi
    if [[ ! -t 1 ]]; then
        echo "maze: note: stdout is not a terminal; drawing anyway" >&2
    fi

    measure_terminal

    local result=""
    while :; do
        play_level
        result="$PLAY_RESULT"
        case "$result" in
            quit) break ;;
            new) LEVEL=$(( LEVEL + 1 )) ;;
            regen) ;;
            next) ;;
        esac
    done

    restore_terminal
    printf '\033[H\033[2J'
    if (( TOT_MOVES > 0 )); then
        printf 'Reached level %d — %d moves, %s total, best level %s moves.\n' \
            "$LEVEL" "$TOT_MOVES" "$(format_time "$TOT_TIME")" "$BEST"
    else
        printf 'No moves made. Thanks for playing.\n'
    fi
}

# Only run when executed, so the file can also be sourced by tests.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
