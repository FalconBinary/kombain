# fdash

The interactive side of fish on top of dash: a 390 KiB POSIX shell with
autosuggestions, syntax highlighting, completion with a pager, and fish's keys.
From ksh93 it has `[[ ]]`, `${var:1:3}`, `${var//a/b}`, here-strings and
command substitution without a fork; from Nushell, tables in pipelines.

`fdash` is dash 0.5.13 plus a line editor (a patched [isocline]). The editor
only starts when the shell is interactive on a terminal. Scripts and `fdash -c`
run the dash code paths, so `/bin/sh` should stay plain dash anyway.

[isocline]: https://github.com/daanx/isocline

## What works like fish

| Feature | How |
|---|---|
| Autosuggestions | Newest matching history line in gray, then a unique completion. `→`, `End`, `Ctrl+F`, `Ctrl+E` accept it, `Alt+→` or `Ctrl+→` accept one word |
| Syntax highlighting | Valid and invalid commands, keywords, strings, variables, options, comments, existing paths. Also inside `$(...)`. An unclosed quote, `$(` or `${`, and a `fi`, `done`, `esac`, `}` or `)` with nothing open, in red |
| Completion | Commands, builtins, aliases, functions, files, directories after `cd`, `$VARIABLES`, `~/`. `Tab` falls back to case-insensitive file matches |
| Pager | Candidates with their descriptions in columns, in natural order (`file2` before `file10`). `Tab`, `Shift+Tab` and the arrows select and show the selection in the line, typing narrows the list, `Enter` takes the selection, `Esc` closes. Long lists fold to eight rows and `PageDown` scrolls |
| Completion specs | Plain text files for subcommands and options, with conditions on what was typed, see below |
| Dynamic completions | Package names for `xbps-install`, `xbps-query -R` (from the synced repository data, no network) and `xbps-remove`, `xbps-query` (installed ones); runit services for `sv`; git branches, tags and remotes, read without running git; process names for `pkill`, `killall`, `pgrep`; process IDs and signals for `kill`; users and groups; hosts from `~/.ssh/config`, `known_hosts` and `/etc/hosts`. A generator of your own is a program that prints the words, kept in a cache until its sources change |
| Completions from man pages | `fdash-update-completions` writes specs for commands that have none, as `fish_update_completions` does; `install.sh` runs it for every user. A command still without one gets it on the first `Tab` after a `-` |
| History | Shared between running shells, deduplicated, kept private (mode 0600). `↑` and `↓` search by what you typed, `Ctrl+R` searches anywhere |
| Private lines | A line starting with a space stays out of the history |
| Abbreviations | `abbr gs git status` expands in place on space or enter |
| Implicit cd | A directory name alone changes into it, `-` goes back. A command of the same name wins |
| Directory history | `prevd`, `nextd`, `dirh`, and `cdh` to pick a visited directory; `Alt+←` and `Alt+→` on an empty line |
| Keys | `Alt+E` or `Alt+V` edit the line in `$VISUAL` or `$EDITOR`, `Alt+S` puts `doas` in front, `Alt+H` or `F1` open the man page of the command at the cursor (`git-commit` for `git commit`), `Alt+L` lists the directory at the cursor, `Alt+W` shows `whatis`. `bind` adds keys that run commands, `commandline` reads and changes the line from them |
| Universal variables | `universal NAME=value` sets it in every running fdash at its next prompt, and in every later one; `-x` exports, `-e` erases |
| Functions | `functions` lists them or prints one, `funced NAME` edits one in `$EDITOR`, `funcsave NAME` saves it to `~/.config/fdash/functions`, from where it loads on first use |
| Command not found | Names the Void packages that have the command, from `xlocate` (xtools). A function `fdash_command_not_found` takes over |
| Prompt | `user@host ~/D/s/void (main) 5s>` with the failed status in red. The git branch comes from `.git/HEAD`, with no fork. `FDASH_RPROMPT` adds a right prompt |
| `$status` | Same as `$?` |
| Config | `~/.config/fdash/config.sh`, interactive shells only |
| Terminal integration | Prompt marks (OSC 133), working directory (OSC 7), window title |

POSIX kept fish's ideas where they have one: `set -o vi` edits in vi's way (motions,
operators with counts, `v` for `$EDITOR`), `fc` lists, reruns and edits the history, and
`stty` changes stay from one command to the next.

## From ksh93

| Feature | How |
|---|---|
| `${var:offset:length}` | Characters, not bytes, in a UTF-8 locale. A negative offset counts from the end (`${v: -2}`), a negative length stops that far from it. Arithmetic in both |
| `${var/pattern/string}` | The first match; `//` every match, `/#` at the start, `/%` at the end. The longest match, as in ksh93. A `/` that a variable holds never splits it |
| `${var^^}` `${var^}` `${var,,}` `${var,}` | Upper and lower case, all or the first character; Cyrillic too in a UTF-8 locale |
| `[[ ... ]]` | `==` and `!=` match patterns, `=~` extended regular expressions, `<` and `>` compare strings, `-eq` and the rest arithmetic (`[[ $n+1 -gt 5 ]]`), `-f`, `-d` and the other file tests, `-v name`, `!`, `&&`, `\|\|`, `( )`. No word splitting or globbing inside; what is quoted on the right matches itself. Newlines between words, redirections after `]]` |
| `cmd <<< word` | A here-string: the word and a newline on standard input |
| `$(...)` without a fork | `$(echo ...)`, `$(printf ...)`, `$(pwd)`, `$(test ...)`, `$(command -v ...)` and `$(type ...)` run in the shell itself, their output caught in memory: 22 times as fast in a loop of `x=$(printf ...)`. Only where nothing can tell the difference, no function of that name, assignment, redirection, `$((...))`, `${x=...}` or `${x?...}`; an error ends just the substitution, as it would end the subshell |

None of these was valid in dash, so no POSIX script changes meaning: the tests
run a corpus through fdash and dash and compare every byte. Arrays,
`typeset`, `select`, brace expansion and `${ cmd; }` are not here.

## Tables, as in Nushell

```sh
lsx | where size -gt 1mb | sort-by -r modified | first 5
psx | where mem -gt 100mib | pick pid name mem
curl -s api.example.com/items | from json | where price -lt 10 | to csv
```

A table travels as text, tab-separated with the names of the columns on its first
line, so every other program can read and write it. Whichever command writes to a
terminal draws it, as Nushell does: aligned, numbered, numbers to the right, sizes
in KiB and MiB, directories in blue.

| Command | Does |
|---|---|
| `lsx [-a] [dir...]` | name, type, size, modified, mode |
| `psx` | pid, ppid, name, state, threads, mem, user, command |
| `where COLUMN OP VALUE` | keeps the rows that match. OP is `==` `!=` `-lt` `-le` `-gt` `-ge` (or `'<'` and the rest quoted, or the whole condition in one quoted word: `where 'size > 1mb'`), `=~` `!~` for regular expressions, `contains`. Sizes and times take units: `10kb`, `2MiB`, `300ms`, `5min`, `2d` |
| `sort-by [-r] COLUMN...` | numbers as numbers, the rest in natural order |
| `pick COLUMN...`, `reject COLUMN...` | the columns to keep, or to drop (Nushell's `select`, a keyword in ksh) |
| `first [N]`, `last [N]`, `count` | rows from the start or the end, how many |
| `from csv\|json\|ssv\|tsv` | a table from CSV, from JSON (a list of objects, or one object as key and value), or from columns separated by spaces, such as `ps` prints |
| `to csv\|json\|tsv` | and back |
| `table` | draws what comes in, tab-separated or columns of words |

`last`, `reject` and `from` are also programs (util-linux's `last`, CUPS's
`reject`): with nothing piped in, the program runs.

## What does not

fdash is a POSIX shell, so **fish syntax does not run**: no `set -x`,
`function ... end`, `if ... end`, `and`/`or`, or lists. That is the price of
keeping dash's speed and compatibility, and why the fish commands above have
POSIX names (`universal` for `set -U`, `bind alt-x` for `bind \ex`).

Also missing:

- `fish_config` and themes: colors are set in `fdash.c` for now.
- Completion conditions are patterns of what was typed, not fish's arbitrary
  commands, so an option that takes a value counts as a word.
- `funced` and `funcsave` need the text of a function, which fdash keeps for
  those defined in an interactive shell or `config.sh` (exactly as typed,
  comments inside included). One defined by a non-interactive shell exists only
  as dash's parse tree, which cannot be turned back into text.
- A program that leaves the terminal in raw mode gets canonical mode, echo,
  signals and newline translation back at the next prompt, so `stty -echo`
  does not last past it; other `stty` changes do.
- vi mode has no marks, macros, `.`, text objects or visual mode, and Alt
  with a letter counts as Escape and that letter there.

## Completion specs

`~/.config/fdash/completions/<command>`, then `/usr/local/share/fdash/completions/<command>`,
then the specs generated from man pages in `~/.local/share/fdash/generated_completions` and
`/usr/local/share/fdash/generated_completions`. Each line is `[pattern ...] item<TAB>description`:

```
commit	Record staged changes
commit --amend	Replace the last commit
push @git-remotes
push * @git-branches
-R|--repository ... @xbps-available	Package
!-R|--repository ... @xbps-installed	Installed package
```

The pattern matches the words typed after the command, apart from options:
a word (`a|b` for either), `*` for any one word, and a final `...` for any
further words. A pattern word that starts with `-` holds when that option was
typed (`-R` also inside `-Rs`), and `!` turns it around. An option item is
offered after further words too, and only when the word being completed starts
with a dash.

An item `@name` offers what a generator gives. Built in, and reading files only:
`users`, `groups`, `hosts`, `services`, `processes`, `pids`, `signals`,
`git-branches`, `git-tags`, `git-remotes`, `dirh`, `files`, `dirs`, `commands`.
Any other name is a program in `~/.config/fdash/generators/` or
`/usr/local/share/fdash/generators/` that prints `word<TAB>description` lines.
When its first line is `#cache PATH...`, fdash keeps the output in `~/.cache/fdash`
until one of those paths changes (`#cache 300s` keeps it five minutes). A suggestion
only reads a fresh cache, so a key press never starts a program; `Tab` does, with a
5 second limit. The shipped `xbps-available` and `xbps-installed` are of this kind.

## Keys

| Key | Does |
|---|---|
| `Tab` | Complete; again to select in the pager |
| `→`, `End`, `Ctrl+F`, `Ctrl+E` | Take the suggestion |
| `Alt+→`, `Ctrl+→` | Take a word of it; on an empty line `nextd` |
| `Alt+←` | A word back; on an empty line `prevd` |
| `↑`, `↓` | History entries starting with what was typed |
| `Ctrl+R` | Search the history |
| `Alt+E`, `Alt+V` | Edit the line in `$VISUAL` or `$EDITOR` |
| `Alt+S` | `doas` in front, or off again |
| `Alt+H`, `F1` | Man page of the command at the cursor |
| `Alt+L` | List the directory at the cursor, or the current one |
| `Alt+W` | `whatis` for the command at the cursor |
| `Ctrl+Z` | Undo |

Keys that need the shell run their command out of sight: the line leaves the
screen, the command runs as if typed but stays out of the history and keeps
`$?`, and the line comes back. `bind alt-g 'commandline -i "$(git branch --show-current)"'`
makes one of your own; `bind` lists them.

## Measured

On an arm64 Void Linux container (Apple Silicon, Colima, capped at 2 cores), with a
UTF-8 locale and every binary on the same local disk, so compare the ratios, not the
absolute numbers. Regenerate with `python3 tests/bench.py ./fdash` from a local disk: a
mount shared with another machine makes a binary look several times slower.

| Shell | Binary | `-c true` | 200k loop iterations |
|---|---|---|---|
| fdash | 387 KiB | 0.77 ms | 226 ms |
| dash 0.5.13, unmodified | 152 KiB | 0.75 ms | 220 ms |
| dash 0.5.12, Void package (no locale support) | 130 KiB | 0.24 ms | 218 ms |
| bash | 1507 KiB | 1.00 ms | 610 ms |
| zsh | 857 KiB | 1.20 ms | 344 ms |
| fish | 11147 KiB | 2.46 ms | not POSIX |

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
| fdash | 2.0 to 2.2 ms | 2.4 MiB |
| fdash, 10 000 history lines | 7.8 to 9.3 ms | 3.1 MiB |
| bash | 2.8 to 3.4 ms | 3.5 MiB |
| zsh | 2.5 to 3.3 ms | 3.7 MiB |
| fish | 10.5 to 12.6 ms | 8.2 MiB |

The first prompt is the fastest of 15 starts; the ranges are the spread between three
benchmark runs (one run of bash and one of zsh came out at 8.9 and 7.3 ms while the
host was busy). A key press takes a median of 0.5 ms to redraw (p99 0.7 to 1.4 ms) with
10 000 history lines, the same as fdash before the pager, generators and keys when the
two are measured in turns. Loops did not change either: 224 ms against 223 ms, and
218 ms for dash of the same version, median of 15.

## Build

Needs a C compiler and make. No autotools, no libraries beyond libc.

```sh
make
make test     # needs python3 and pyte
doas make install
```

`make install` also puts `fdash-update-completions` next to `fdash`, the completion
specs and generators under `/usr/local/share/fdash`. Run `fdash-update-completions`
after installing programs to pick up their man pages; fdash also does it for a single
command on the first `Tab` after a `-`.

## Prompt

Leave `PS1` alone for the prompt above. A `PS1` you set is used as plain text
(color escapes are dropped). `FDASH_PS1` takes isocline markup such as `[ansi-red]text[/]`:

```sh
FDASH_PS1='[ansi-cyan]$PWD[/] > '
FDASH_RPROMPT='[ansi-darkgray]$(date +%H:%M)[/]'
```

`FDASH_RPROMPT` shows at the right end of the first prompt line while the input
leaves room for it.

## Security

- Nothing from a repository or a file name reaches the terminal as a control
  sequence. Prompt, title and menus replace control characters.
- The prompt never runs `git`, so entering a hostile repository runs nothing from it.
  It reads `.git/HEAD` only from a regular file, so a FIFO or a link to the terminal
  planted there cannot hang the shell.
- Nesting is limited while highlighting, so pasted text cannot overrun the stack.
- History is created 0600 in a 0700 directory, and rewritten atomically.
- Completions never run `git` either: branches, tags and remotes are read from the
  repository's files, and ref names with control characters are left out. Generator
  output, process names and descriptions reach the pager only as plain text.
- Generators run only from `~/.config/fdash/generators` and the installed data
  directory, with stdin from `/dev/null`, in a process group of their own, and are
  stopped after 5 seconds. A suggestion never starts one.
- A saved function loads only from a regular file the user owns, and only in an
  interactive shell. Universal variables and the cache live under the user's own
  directories; the variables file is changed under a lock and replaced atomically.
- Temporary files for `Alt+E`, `funced` and `fc` are made with `mkstemps`.

## Changes to upstream

`dash/` is dash 0.5.13 with its changes inside `#ifdef FDASH` (`input.c`,
`parser.c`, `main.c`, `exec.c`, `eval.c`, `expand.c`, `jobs.c`, `var.c`,
`options.c`, `alias.c`, `builtins.def.in`, and a node type in `nodetypes`):
reading lines through the editor, recording a function's text as it is parsed,
loading saved functions, the command-not-found hook, `set -o vi` turning emacs
off, and the ksh93 features above. `isocline/` is isocline at 8d6dc1e with changes
marked `fdash:`:

- history suggestions, prefix search, and an abbreviation hook
- history appended line by line, shared between shells, loaded in O(n)
- keeps type-ahead (`TCSADRAIN` instead of `TCSAFLUSH`), and pasting no longer redraws per key
- a paste is one undo step and undo is capped at 256 steps; a copy of the line per key made a
  40 KiB paste cost 514 MiB
- installs only its `SIGWINCH` handler, the shell owns every other signal
- a fish-like pager instead of the numbered menu, and completions in natural order
- a key handler for Alt and function keys, which may hand the shell a command, and a
  starting input for the next line
- vi editing (`editline_vi.c`), a right prompt, and the terminal state taken at each
  prompt instead of at startup

## Licenses

`src/` and the tests are GPL-3.0-or-later, like the rest of the repository, and so is
the `fdash` binary as a whole. The vendored code keeps its own licenses, which allow
this: `dash/` is BSD-3-Clause (`dash/COPYING`), `isocline/` is MIT (`isocline/LICENSE`).
