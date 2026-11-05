# fdash

The interactive side of fish on top of dash: a 323 KiB POSIX shell with
autosuggestions, syntax highlighting and completion.

`fdash` is dash 0.5.13 plus a line editor (a patched [isocline]). The editor
only starts when the shell is interactive on a terminal. Scripts and `fdash -c`
run the dash code paths, so `/bin/sh` should stay plain dash anyway.

[isocline]: https://github.com/daanx/isocline

## What works like fish

| Feature | How |
|---|---|
| Autosuggestions | Newest matching history line in gray, then a unique completion. `→`, `End`, `Ctrl+F`, `Ctrl+E` accept it, `Alt+→` or `Ctrl+→` accept one word |
| Syntax highlighting | Valid and invalid commands, keywords, strings, variables, options, comments, existing paths. Also inside `$(...)` |
| Completion | Commands, builtins, aliases, functions, files, directories after `cd`, `$VARIABLES`, `~/`. `Tab` falls back to case-insensitive file matches |
| Completion specs | Plain text files for subcommands and options, see below |
| History | Shared between running shells, deduplicated, kept private (mode 0600). `↑` and `↓` search by what you typed, `Ctrl+R` searches anywhere |
| Private lines | A line starting with a space stays out of the history |
| Abbreviations | `abbr gs git status` expands in place on space or enter |
| Implicit cd | A directory name alone changes into it, `-` goes back. A command of the same name wins |
| Prompt | `user@host ~/D/s/void (main) 5s>` with the failed status in red. The git branch comes from `.git/HEAD`, with no fork |
| `$status` | Same as `$?` |
| Config | `~/.config/fdash/config.sh`, interactive shells only |
| Terminal integration | Prompt marks (OSC 133), working directory (OSC 7), window title |

## What does not

fdash is a POSIX shell, so **fish syntax does not run**: no `set -x`,
`function ... end`, `if ... end`, `and`/`or`, or lists. That is the price of
keeping dash's speed and compatibility.

Also missing: universal variables, `funced`, `fish_config`, completions generated
from man pages, `set -o vi` and `fc` (these need libedit, replaced here). `stty`
changes do not survive a prompt, because the editor restores the terminal state it
saved at startup; that also repairs the terminal after a crashed program.

## Measured

On a 4-core arm64 Void Linux container (Apple Silicon, Colima), with a UTF-8 locale
and every binary on the same local disk, so compare the ratios, not the absolute
numbers. Regenerate with `python3 tests/bench.py ./fdash` from a local disk: a mount
shared with another machine makes a binary look several times slower.

| Shell | Binary | `-c true` | 200k loop iterations |
|---|---|---|---|
| fdash | 323 KiB | 0.78 ms | 229 ms |
| dash 0.5.13, unmodified | 152 KiB | 0.77 ms | 224 ms |
| dash 0.5.12, Void package (no locale support) | 130 KiB | 0.24 ms | 230 ms |
| bash | 1507 KiB | 1.05 ms | 652 ms |
| zsh | 857 KiB | 1.25 ms | 395 ms |
| fish | 11147 KiB | 2.64 ms | not POSIX |

The editor costs scripts nothing: fdash starts and loops like dash of the same version.

Void's glibc ships no gconv cache, so any program under a UTF-8 locale parses the
gconv text files at startup. `iconvconfig` creates it, and the kombain `install.sh`
keeps it fresh at every boot:

| `-c true` | Without cache | With cache |
|---|---|---|
| fdash | 0.87 ms | 0.35 ms |
| bash | 1.11 ms | 0.50 ms |
| zsh | 1.28 ms | 0.67 ms |
| fish | 2.41 ms | 1.85 ms |

| Interactive | First prompt | Memory at prompt |
|---|---|---|
| fdash | 2.9 to 5.8 ms | 2.3 MiB |
| fdash, 10 000 history lines | 9.9 ms | 3.0 MiB |
| bash | 3.1 to 3.8 ms | 3.5 MiB |
| zsh | 2.9 to 3.6 ms | 3.7 MiB |
| fish | 12.8 to 23.8 ms | 8.1 MiB |

The first prompt is the fastest of 15 starts; the ranges are the spread between
benchmark runs. A key press takes a median of 0.37 ms to redraw (p99 0.80 ms) with
10 000 history lines.

## Build

Needs a C compiler and make. No autotools, no libraries beyond libc.

```sh
make
make test     # needs python3 and pyte
doas make install
```

## Prompt

Leave `PS1` alone for the prompt above. A `PS1` you set is used as plain text
(color escapes are dropped). `FDASH_PS1` takes isocline markup such as `[ansi-red]text[/]`:

```sh
FDASH_PS1='[ansi-cyan]$PWD[/] > '
```

## Completion specs

`~/.config/fdash/completions/<command>`, then `/usr/local/share/fdash/completions/<command>`.
Each line is `[subcommand ...] word<TAB>description`:

```
commit	Record staged changes
commit --amend	Replace the last commit
```

## Security

- Nothing from a repository or a file name reaches the terminal as a control
  sequence. Prompt, title and menus replace control characters.
- The prompt never runs `git`, so entering a hostile repository runs nothing from it.
  It reads `.git/HEAD` only from a regular file, so a FIFO or a link to the terminal
  planted there cannot hang the shell.
- Nesting is limited while highlighting, so pasted text cannot overrun the stack.
- History is created 0600 in a 0700 directory, and rewritten atomically.

## Changes to upstream

`dash/` is dash 0.5.13 with its changes inside `#ifdef FDASH` (`input.c`,
`parser.c`, `main.c`, `exec.c`, `alias.c`, `builtins.def.in`). `isocline/` is
isocline at 8d6dc1e with changes marked `fdash:`:

- history suggestions, prefix search, and an abbreviation hook
- history appended line by line, shared between shells, loaded in O(n)
- keeps type-ahead (`TCSADRAIN` instead of `TCSAFLUSH`), and pasting no longer redraws per key
- a paste is one undo step and undo is capped at 256 steps; a copy of the line per key made a
  40 KiB paste cost 514 MiB
- installs only its `SIGWINCH` handler, the shell owns every other signal

## Licenses

`src/` and the tests are GPL-3.0-or-later, like the rest of the repository, and so is
the `fdash` binary as a whole. The vendored code keeps its own licenses, which allow
this: `dash/` is BSD-3-Clause (`dash/COPYING`), `isocline/` is MIT (`isocline/LICENSE`).
