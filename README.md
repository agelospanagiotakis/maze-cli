# maze

A small auto-generated maze game you play with the keyboard in a Linux or macOS
terminal. It is a single pure-bash script: no dependencies, no interpreter
beyond `bash` itself, and stock macOS `/bin/bash` (3.2) works.

By Angelos Panagiotakis, free software under the
[GNU General Public License v3 or later](#licence).

```
  maze v1.0.0   level 1 (9x6)   moves 0   time 0:00   best —  exit →↓   [fog off]

┌─────┬───────────┐
│@    │           │
├───┐ └─┐ │ ────┐ │
│   │   │ │     │ │
│ │ └─┐ │ ├───┐ └─┤
│ │   │ │ │   │   │
│ ├─┐ │ ├─┘ │ └── │
│ │ │   │   │     │
│ │ └───┘ ┌─┴─┬── │
│ │       │   │   │
│ └──── ┌─┘ ──┘ ──┤
│       │        ★│
└───────┴─────────┘

  arrows / wasd move   h hint   r regenerate   n new maze   f fog   q quit
```

## Run it

```sh
./maze.sh
```

Requires a terminal (a TTY) and `bash` 3.2 or newer. It starts **small** — a
9x6 grid of cells — and the maze grows by one cell in each direction every
level.

## Installing on Linux

The whole program is one bash script, so "distributing" it is mostly a matter
of putting the file somewhere on `PATH` under the name `maze`.

**1. Straight from GitHub** — nothing to build, no clone:

```sh
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/agelospanagiotakis/maze-cli/main/maze.sh \
    -o ~/.local/bin/maze
chmod +x ~/.local/bin/maze
maze                                   # ~/.local/bin must be on your PATH
```

`curl -fsSL` fails loudly on HTTP errors rather than saving an error page, so a
bad download cannot quietly become a broken `maze`. Prefer a pinned, verifiable
download? Use the release tarball (option 3) and check its SHA256.

**2. Straight from the source tree** — no build step at all:

```sh
sudo install -Dm755 maze.sh /usr/local/bin/maze   # or: install -Dm755 maze.sh ~/.local/bin/maze
maze
```

**3. From the release tarball** (includes `LICENSE`, tests and the Makefile):

```sh
# Either build it yourself:
make dist                                  # builds build/maze-1.0.0.tar.gz + .sha256
( cd build && sha256sum -c maze-1.0.0.tar.gz.sha256 )   # maze-1.0.0.tar.gz: OK
# ...or download it from the releases page, then:
tar -xzf maze-1.0.0.tar.gz && cd maze-1.0.0
make test                                  # 58 checks
sudo make install                          # PREFIX=/usr/local by default
make uninstall                             # PREFIX=$HOME/.local also works
```

`DESTDIR` is honoured for staged installs, so packagers can do
`make install DESTDIR=$pkgdir PREFIX=/usr`.

**4. As a Debian/Ubuntu package:**

```sh
sudo apt-get install -y build-essential debhelper devscripts lintian
make deb                                   # .deb + Debian source package (.dsc)
make lint                                  # lintian --pedantic
sudo apt-get install -y ./build/pkg/maze_1.0.0-1_all.deb
```

The package installs into `/usr/games` with a section 6 manual page, following
the Debian convention for games; `/usr/games` is on the default login `PATH`.
`debian/` is a complete, lintian-clean source package, so the same tree can be
uploaded to a PPA or to Debian itself.

**Publishing it for `apt-get` users** — your own apt repository, an Ubuntu PPA,
or getting into Debian proper — is covered step by step in
[`packaging/PUBLISHING.md`](packaging/PUBLISHING.md), including what each route
costs in time and review. `make check-linux` proves the whole packaging path in
a container: build, lintian, a local apt repo, and `apt-get install maze`.

For RPM and other formats, point [nfpm](https://nfpm.goreleaser.com/) at the
same file — a starting point:

```yaml
name: maze
version: 1.0.0
arch: all
contents:
  - src: maze.sh
    dst: /usr/bin/maze
    file_info: { mode: 0755 }
  - src: LICENSE
    dst: /usr/share/licenses/maze/LICENSE
depends: [bash]
```

**Requirements on Linux:** `bash` (any distribution ships 4.x or 5.x, well above
the 3.2 minimum), plus `stty` from coreutils for raw keyboard input. `tput` from
ncurses is used to measure the terminal and is not required — without it the
board falls back to 80x24.

**Licensing when you redistribute.** Under the GPL, anyone you hand a copy to
gets the same freedoms you have, so ship the `LICENSE` file (and the copyright
notice) alongside the script, and if you modify it, mark the changes and license
your version the same way. The script itself is the source, so a copy of
`maze.sh` satisfies the source requirement.

`make check-linux` runs the whole flow above inside `debian:stable-slim` using
Docker — building the tarball, verifying its checksum, testing the unpacked
release, installing and uninstalling it, building the Debian source and binary
packages, running lintian, `uscan` and autopkgtest, and installing the package
from a local apt repository with `apt-get`.

To run every check in one go — syntax, version consistency, the test suite and
the packaging gate — use the single entry point:

```sh
./LINUX_DISTRIBUTION_CHECKS.sh            # everything, needs Docker
./LINUX_DISTRIBUTION_CHECKS.sh --quick    # skip the Docker half
```

It exits 0 when everything passed, 1 when something failed and 2 when the
packaging checks could not run at all (Docker missing), so a green result can
never be mistaken for an incomplete one. Logs land in `build/logs/`.

## Controls

| Key | Action |
| --- | --- |
| arrow keys, `WASD` | move |
| `h` | show/hide a hint path |
| `r` | regenerate the current maze |
| `n` | skip to a fresh maze |
| `f` | toggle fog of war |
| `q`, `Esc`, `Ctrl-C` | quit |

Walk the `@` from the top-left corner to the green `★` without crossing a wall.
The HUD tracks moves, time, your best run and which way the exit lies. Walking
into a wall costs nothing; only real moves are counted.

## Options

```sh
./maze.sh --help
./maze.sh --preset medium        # small (9x6, default) | medium (16x11) | large (25x17)
./maze.sh --size 12x8            # fixed size in cells: columns x rows
./maze.sh --seed 42              # pick the maze (same seed, same maze)
./maze.sh --fog                  # start with fog of war on
./maze.sh --ascii                # plain ASCII instead of box drawing
./maze.sh --no-color             # no ANSI colours
./maze.sh --print-solution       # print the keystrokes that solve level 1, exit
```

Mazes are built with an iterative recursive backtracker, so every maze is a
perfect maze: exactly one route from the start to the exit, always reachable,
and no loops. `--size` is honoured up to what the terminal can show; anything
larger is quietly shrunk to fit rather than breaking the display, and boards are
capped at 40x24 cells.

`--seed` reproduces a maze, but only within one build of bash: `$RANDOM`'s
sequence for a given seed differs between bash 3.2 and bash 5, so the same seed
can give different mazes on different machines.

## Tests

```sh
tests/smoke_test.sh
```

58 checks, all pure bash, in two groups:

* **Structural** — sources the script and inspects generated mazes directly:
  every cell is carved, exactly `cells - 1` doorways (a spanning tree, so no
  loops and no unreachable pockets), a solid outer border, an independent flood
  fill that reaches every cell, fog visibility, and that the solver's key string
  only ever walks through open corridors and ends on the exit.
* **Behavioural** — runs the real game and asserts on what it draws: movement
  and wall blocking, the exact move count, fog toggling, hints, regeneration,
  level progression onto a bigger board, seed determinism, and quitting.

If `script(1)` can allocate a pty, nine more checks play the game on a real
terminal: arrow-key escape sequences through raw mode (`stty`), a lone `Esc`,
and that the terminal is restored (`icanon`, `echo`) on exit. Without a pty
those checks report `[skip]` rather than failing.

Two limits worth stating plainly. `Ctrl-C` is read by the game itself as a
`0x03` byte (ISIG is off during play), so that path is verified through a pipe
rather than a pty, because `script(1)` swallows `^C` before the pty sees it. And
SIGINT-based quitting cannot be tested under `script(1)` at all: children
inherit `SIGINT` as `SIG_IGN`, and POSIX forbids a shell from trapping a signal
that was ignored on entry.

## Licence

Copyright (C) 2026 Angelos Panagiotakis.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but **without
any warranty**; without even the implied warranty of merchantability or fitness
for a particular purpose. See the GNU General Public License for more details.

The full licence text is in [`LICENSE`](LICENSE); a copy also lives at
<https://www.gnu.org/licenses/>. Each source file carries an
`SPDX-License-Identifier: GPL-3.0-or-later` tag, and `./maze.sh --version`
repeats the notice.

