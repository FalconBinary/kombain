#!/usr/bin/env python3
"""Drives a real fdash through a pty and checks what a terminal would show."""
import fcntl
import gzip
import os
import pty
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

import pyte

HERE = os.path.dirname(os.path.abspath(__file__))
FDASH = os.path.abspath(sys.argv[1])
STOCK = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else None
ONLY = sys.argv[3] if len(sys.argv) > 3 else None
UP, DOWN, RIGHT, LEFT = "\x1b[A", "\x1b[B", "\x1b[C", "\x1b[D"
ALT_LEFT, ALT = "\x1b[1;3D", "\x1b"
ALT_RIGHT, CTRL_C, CTRL_D, CTRL_Z, TAB, CR = "\x1b[1;3C", "\x03", "\x04", "\x1a", "\t", "\r"


class Shell:
    def __init__(self, home, cols=100, rows=40, env=None, cwd=None, args=()):
        self.screen = pyte.Screen(cols, rows)
        self.stream = pyte.ByteStream(self.screen)
        self.raw = b""
        e = {"HOME": home, "TERM": "xterm-256color", "LANG": "C.UTF-8", "PATH": "/usr/bin:/bin", "USER": "t"}
        e.update(env or {})
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            try:
                os.chdir(cwd or home)
                os.execve(FDASH, [FDASH, *args], e)
            finally:
                os._exit(127)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.settle()

    def settle(self, quiet=0.06, limit=3.0):
        end = time.time() + limit
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], quiet)
            if not r:
                return
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                return
            if not data:
                return
            self.raw += data
            self.stream.feed(data)

    def send(self, keys, quiet=0.06):
        os.write(self.fd, keys.encode())
        self.settle(quiet)

    def run(self, line, quiet=0.1):
        self.send(line + CR, quiet)

    def text(self):
        return "\n".join(l.rstrip() for l in self.screen.display)

    def row(self):
        return self.screen.display[self.screen.cursor.y].rstrip()

    def color_of(self, needle):
        """Foreground color of the first cell of the last occurrence of needle on screen."""
        for y in range(self.screen.lines - 1, -1, -1):
            x = self.screen.display[y].find(needle)
            if x >= 0:
                return self.screen.buffer[y][x].fg
        raise AssertionError(f"{needle!r} not on screen:\n{self.text()}")

    def underlined(self, needle):
        for y in range(self.screen.lines - 1, -1, -1):
            x = self.screen.display[y].find(needle)
            if x >= 0:
                return self.screen.buffer[y][x].underscore
        raise AssertionError(f"{needle!r} not on screen")

    def alive(self):
        pid, _ = os.waitpid(self.pid, os.WNOHANG)
        return pid == 0

    def wait_exit(self, limit=3.0):
        end = time.time() + limit
        while time.time() < end:
            self.settle(0.02, 0.05)
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                return os.waitstatus_to_exitcode(status)
        raise AssertionError("shell did not exit")

    def close(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        except (ProcessLookupError, ChildProcessError):
            pass
        os.close(self.fd)


def expect(cond, what, sh=None):
    if not cond:
        shown = "\n".join(l[:110] for l in sh.text().splitlines() if l.strip())[-700:] if sh else ""
        raise AssertionError(what + ("\n--- screen ---\n" + shown if sh else ""))


tests = []


def test(fn):
    tests.append(fn)
    return fn


@test
def prompt_shows_user_path_and_status(h):
    s = Shell(h)
    expect("~" in s.row() and s.row().endswith(">"), "fish prompt", s)
    s.run("false")
    expect("[1]" in s.row(), "failed status is shown", s)
    s.run("true")
    expect("[1]" not in s.row(), "status clears", s)
    s.run("echo $status")
    expect("\n0\n" in s.text(), "$status works", s)
    s.close()


@test
def runs_commands(h):
    s = Shell(h)
    s.run("echo hello-world")
    expect("\nhello-world\n" in s.text(), "output", s)
    s.close()


@test
def autosuggestion_from_history(h):
    s = Shell(h)
    s.run("echo unique-xyz")
    s.send("echo un")
    expect("echo unique-xyz" in s.row(), "suggestion shown", s)
    expect(s.color_of("ique-xyz") != "default", "suggestion is dim", s)
    s.send(CR, 0.1)
    expect("\nun\n" in s.text(), "enter runs only what was typed", s)
    s.close()


@test
def suggestion_accepted_with_right_arrow(h):
    s = Shell(h)
    s.run("echo accept-me")
    s.send("echo acc")
    s.send(RIGHT)
    s.send(CR, 0.1)
    expect("\naccept-me\n" in s.text(), "suggestion taken", s)
    s.close()


@test
def suggestion_accepted_word_by_word(h):
    s = Shell(h)
    s.run("echo first second third")
    s.send("echo fi")
    s.send(ALT_RIGHT)
    s.send(" X" + CR, 0.1)
    expect("\nfirst X\n" in s.text(), "only one word taken", s)
    s.close()


@test
def ctrl_right_takes_one_word_too(h):
    s = Shell(h)
    s.run("echo alpha beta gamma")
    s.send("echo al")
    s.send("\x1b[1;5C")
    s.send(" Z" + CR, 0.1)
    expect("\nalpha Z\n" in s.text(), "one word taken", s)
    s.close()


@test
def ctrl_r_searches_anywhere_in_history(h):
    s = Shell(h)
    s.run("echo needle-in-the-middle")
    s.run("echo other")
    s.send("\x12")
    s.send("needle")
    expect("history search" in s.text() and ". echo needle-in-the-middle" in s.text(), "found", s)
    s.send(CR, 0.1)
    s.send(CR, 0.15)
    expect(s.text().count("\nneedle-in-the-middle\n") >= 2, "ran again", s)
    s.close()


@test
def suggestion_returns_after_backspace(h):
    s = Shell(h)
    s.run("echo backspace-case")
    s.send("echo backsz")
    expect("backspace-case" not in s.row(), "no suggestion on mismatch", s)
    s.send("\x7f")
    expect("echo backspace-case" in s.row(), "suggestion back after backspace", s)
    s.close()


@test
def up_arrow_searches_by_prefix(h):
    s = Shell(h)
    s.run("ls /tmp >/dev/null")
    s.run("echo one")
    s.run("echo two")
    s.send("ech" + UP)
    expect("echo two" in s.row(), "newest match", s)
    s.send(UP)
    expect("echo one" in s.row(), "older match", s)
    s.send(UP)
    expect("echo one" in s.row() and "ls" not in s.row().split(">")[-1], "non matching skipped", s)
    s.send(DOWN + DOWN)
    expect(s.row().rstrip().endswith("ech") or "ech" in s.row(), "back to typed text", s)
    s.close()


@test
def history_persists_and_is_private(h):
    s = Shell(h)
    s.run("echo persisted-line")
    s.run("exit")
    s.wait_exit()
    path = os.path.join(h, ".local/share/fdash/history")
    expect(os.stat(path).st_mode & 0o777 == 0o600, "history is 0600")
    expect(os.stat(os.path.dirname(path)).st_mode & 0o777 == 0o700, "history dir is 0700")
    s = Shell(h)
    s.send(UP)
    s.send(UP)
    expect("echo persisted-line" in s.text(), "reloaded", s)
    s.close()


@test
def leading_space_stays_out_of_history(h):
    s = Shell(h)
    s.run(" echo secret-token")
    s.run("echo public")
    s.send(UP)
    expect("echo public" in s.row(), "public kept", s)
    s.send(UP)
    expect("secret-token" not in s.row(), "secret not offered", s)
    data = open(os.path.join(h, ".local/share/fdash/history")).read()
    expect("secret" not in data, "secret not on disk")
    s.close()


@test
def history_is_shared_between_running_shells(h):
    a, b = Shell(h), Shell(h)
    a.run("echo from-shell-a")
    b.run("true")
    b.send("echo from")
    expect("echo from-shell-a" in b.row(), "other shell's line suggested", b)
    b.send(CTRL_C)
    b.run("echo from-shell-b")
    a.run("true")
    a.send("echo from-shell-b"[:12])
    expect("echo from-shell-b" in a.row(), "and back", a)
    a.close(), b.close()
    lines = open(os.path.join(h, ".local/share/fdash/history")).read().splitlines()
    expect("echo from-shell-a" in lines and "echo from-shell-b" in lines, "neither lost")


@test
def highlighting(h):
    os.mkdir(os.path.join(h, "existing"))
    s = Shell(h)
    s.send("echo")
    good = s.color_of("echo")
    expect(good != "default", "valid command colored", s)
    s.send(CTRL_C + "nosuchcmdxyz")
    bad = s.color_of("nosuchcmdxyz")
    expect(bad != good and "red" in bad, "invalid command is red", s)
    s.send(CTRL_C + "echo 'str' $HOME existing -v # note")
    expect("brown" in s.color_of("'str'"), "string", s)
    expect("cyan" in s.color_of("$HOME"), "variable", s)
    expect(s.underlined("existing"), "existing path underlined", s)
    expect(s.color_of("# note") != "default" and "cyan" not in s.color_of("# note"), "comment", s)
    s.send(CTRL_C + "if true; then echo $(nosuchinner); fi")
    expect("magenta" in s.color_of("if"), "keyword", s)
    expect("red" in s.color_of("nosuchinner"), "command substitution is highlighted inside", s)
    s.close()


@test
def tab_completes_commands_and_builtins(h):
    s = Shell(h)
    s.send("histo" + TAB)
    expect("history" in s.row(), "builtin", s)
    s.send(CTRL_C + "ech" + TAB)
    s.send(CR, 0.1)
    s.send(CTRL_C)
    expect("echo" in s.text(), "echo", s)
    s.close()


@test
def tab_completes_files_with_spaces_and_tilde(h):
    os.mkdir(os.path.join(h, "my dir"))
    open(os.path.join(h, "my dir", "inner file"), "w").close()
    s = Shell(h)
    s.send("ls ~/my" + TAB)
    expect("~/my\\ dir/" in s.row(), "tilde and escaped space", s)
    s.send("in" + TAB + CR, 0.1)
    expect("inner file" in s.text(), "ran with the escaped name", s)
    s.close()


@test
def cd_only_offers_directories(h):
    os.mkdir(os.path.join(h, "alpha-dir"))
    open(os.path.join(h, "alpha-file"), "w").close()
    s = Shell(h)
    s.send("cd alp" + TAB)
    expect("alpha-dir/" in s.row() and "alpha-file" not in s.text(), "only the directory", s)
    s.close()


@test
def tab_is_case_insensitive_when_nothing_matches(h):
    os.mkdir(os.path.join(h, "Documents"))
    s = Shell(h)
    s.send("ls doc")
    expect("Documents" not in s.row(), "no wrong suggestion", s)
    s.send(TAB)
    expect("ls Documents/" in s.row(), "fixed by tab", s)
    s.close()


@test
def tab_completes_variables(h):
    s = Shell(h, env={"MY_UNIQUE_VAR": "1"})
    s.send("echo $MY_UN" + TAB + CR, 0.1)
    expect("\n1\n" in s.text(), "variable", s)
    s.close()


@test
def completion_specs(h):
    d = os.path.join(h, ".config/fdash/completions")
    os.makedirs(d)
    open(os.path.join(d, "tool"), "w").write("deploy\tShip it\nbuild\tCompile\ndeploy --now\tRight away\n")
    open("/tmp/tool", "w").close()
    s = Shell(h, env={"PATH": "/usr/bin:/bin"})
    s.send("tool dep" + TAB)
    expect("tool deploy" in s.row(), "subcommand", s)
    s.send(" --n" + TAB)
    expect("tool deploy --now" in s.row(), "nested option", s)
    s.close()


def shipped(h):
    """The completion specs and generators fdash installs, in the test user's config."""
    cfg = os.path.join(h, ".config/fdash")
    shutil.copytree(os.path.join(HERE, "../completions"), cfg + "/completions", dirs_exist_ok=True)
    shutil.copytree(os.path.join(HERE, "../generators"), cfg + "/generators", dirs_exist_ok=True)


@test
def generators_are_cached_until_their_source_changes(h):
    cfg = os.path.join(h, ".config/fdash")
    os.makedirs(cfg + "/completions")
    os.makedirs(cfg + "/generators")
    source = os.path.join(h, "fruit-source")
    open(source, "w").close()
    open(cfg + "/completions/tool", "w").write(
        "!-R|--remote ... @fruits\tFruit\n-R|--remote ... @remote-fruits\n-R\tFrom the remote\n")
    gen = cfg + "/generators/fruits"
    open(gen, "w").write(f"#!/bin/sh\necho run >> {h}/runs\necho '#cache {source}'\n"
                         "printf 'apple\\tRed\\nbanana\\tYellow\\ncherry\\tDark\\n'\n")
    open(cfg + "/generators/remote-fruits", "w").write("#!/bin/sh\nprintf 'kiwi\\tGreen\\n'\n")
    os.chmod(gen, 0o755)
    os.chmod(cfg + "/generators/remote-fruits", 0o755)
    s = Shell(h)
    s.send("tool ap" + TAB)
    expect("tool apple" in s.row(), "candidate from a generator", s)
    s.send(CTRL_C + "tool ba" + TAB)
    expect("tool banana" in s.row(), "second candidate", s)
    runs = lambda: open(f"{h}/runs").read().count("run")
    expect(runs() == 1, f"ran once, then the cache: {runs()} runs", s)
    expect(os.path.exists(os.path.join(h, ".cache/fdash/fruits")), "cache on disk")
    s.send(CTRL_C + "tool ch")
    expect("tool cherry" in s.row(), "a suggestion from the cache", s)
    time.sleep(0.05)
    os.utime(source)
    s.send(CTRL_C + "tool ch")
    expect(runs() == 1, "a suggestion never runs the generator", s)
    s.send(TAB)
    expect(runs() == 2 and "tool cherry" in s.row(), "a changed source runs it again", s)
    s.send(CTRL_C + "tool ki" + TAB)
    expect("kiwi" not in s.row(), "the condition keeps the remote list out", s)
    s.send(CTRL_C + "tool -R ki" + TAB)
    expect("tool -R kiwi" in s.row(), "an option selects the other list", s)
    s.close()


@test
def xbps_packages_complete_from_local_repository_data(h):
    if not shutil.which("xbps-query") or not os.listdir("/var/db/xbps"):
        print("      (skipped: no xbps here)")
        return
    shipped(h)
    s = Shell(h)
    s.send("xbps-install 2048-q" + TAB, 1.0)
    expect("xbps-install 2048-qt" in s.row(), "an available package", s)
    expect(os.path.exists(os.path.join(h, ".cache/fdash/xbps-available")), "kept in the cache")
    s.send(CTRL_C + "xbps-remove base-fil" + TAB, 1.0)
    expect("xbps-remove base-files" in s.row(), "an installed package", s)
    s.send(CTRL_C + "xbps-remove 2048-q" + TAB, 1.0)
    expect("2048-qt" not in s.row(), "only installed ones for xbps-remove", s)
    s.send(CTRL_C + "xbps-query -Rs 2048-q" + TAB, 1.0)
    expect("2048-qt" in s.row(), "-R queries the repository", s)
    s.send(CTRL_C + "xbps-query 2048-q" + TAB, 1.0)
    expect("2048-qt" not in s.row(), "without -R only installed packages", s)
    s.close()


@test
def services_users_hosts_and_processes(h):
    shipped(h)
    sv = os.path.join(h, "service")
    for name in ("netline-x", "sshd-y"):
        os.makedirs(os.path.join(sv, name, "supervise"))
    open(os.path.join(sv, "netline-x/supervise/stat"), "w").write("run\n")
    os.makedirs(os.path.join(h, ".ssh"))
    open(os.path.join(h, ".ssh/config"), "w").write("Host myserver *.wild\n  HostName 10.1.1.1\nHost=other-box\n")
    open(os.path.join(h, ".ssh/known_hosts"), "w").write(
        "[gitbox]:2222,10.0.0.5 ssh-ed25519 AAAA\n|1|abc=|def= ssh-ed25519 AAAA\n")
    s = Shell(h, env={"SVDIR": sv})
    s.send("sv up net" + TAB)
    expect("sv up netline-x" in s.row(), "runit service", s)
    s.send(CTRL_C + "ssh mys" + TAB)
    expect("ssh myserver" in s.row(), "host from ~/.ssh/config", s)
    s.send(CTRL_C + "ssh gitb" + TAB)
    expect("ssh gitbox" in s.row(), "host from known_hosts", s)
    s.send(CTRL_C + "ssh oth" + TAB)
    expect("ssh other-box" in s.row(), "Host=name form", s)
    s.send(CTRL_C + "ssh *" + TAB)
    expect(".wild" not in s.text(), "patterns are not hosts", s)
    s.send(CTRL_C + "su roo" + TAB)
    expect("su root" in s.row(), "user", s)
    s.send(CTRL_C)
    s.run("sleep 100 &")
    s.send("pkill slee" + TAB)
    expect("pkill sleep" in s.row(), "process name", s)
    s.send(CTRL_C + "kill -s KI" + TAB)
    expect("kill -s KILL" in s.row(), "signal name", s)
    s.send(CTRL_C + "kill " + TAB)
    expect("sleep" in s.text().split("kill", 1)[-1], "pids with their names", s)
    s.close()


@test
def git_refs_complete_without_running_git(h):
    shipped(h)
    g = os.path.join(h, "repo/.git")
    os.makedirs(g + "/refs/heads/feature")
    os.makedirs(g + "/refs/remotes/origin")
    os.makedirs(g + "/refs/tags")
    open(g + "/HEAD", "w").write("ref: refs/heads/main\n")
    for ref in ("heads/main", "heads/feature/login", "remotes/origin/main", "tags/v1.0"):
        open(f"{g}/refs/{ref}", "w").write("0" * 40 + "\n")
    open(g + "/packed-refs", "w").write("# pack-refs\n" + "1" * 40 + " refs/heads/packed-one\n")
    open(g + "/config", "w").write('[core]\n\tbare = false\n[remote "upstream"]\n\turl = x\n')
    os.makedirs(g + "/refs/heads/evil")
    open(g + "/refs/heads/evil/x\x1b]0;PWNED\x07", "w").write("0" * 40 + "\n")
    s = Shell(h, cwd=os.path.join(h, "repo"), env={"PATH": "/nonexistent"})
    s.send("git checkout feat" + TAB)
    expect("git checkout feature/login" in s.row(), "loose branch", s)
    s.send(CTRL_C + "git switch pack" + TAB)
    expect("git switch packed-one" in s.row(), "packed branch", s)
    s.send(CTRL_C + "git push up" + TAB)
    expect("git push upstream" in s.row(), "remote from the config", s)
    s.send(CTRL_C + "git push upstream fea" + TAB)
    expect("git push upstream feature/login" in s.row(), "then a branch", s)
    s.send(CTRL_C + "git merge origin/m" + TAB)
    expect("git merge origin/main" in s.row(), "remote branch", s)
    s.send(CTRL_C + "git checkout evil/" + TAB)
    expect(b"\x1b]0;PWNED" not in s.raw, "a hostile ref name stays out of the terminal", s)
    s.close()


@test
def pager_shows_descriptions_in_columns(h):
    d = os.path.join(h, ".config/fdash/completions")
    os.makedirs(d)
    open(os.path.join(d, "tool"), "w").write("".join(f"cmd{i}\tDoes thing {i}\n" for i in range(1, 13)))
    s = Shell(h, cols=100, rows=30)
    s.send("tool cmd" + TAB)
    screen = s.text()
    expect("cmd1  (Does thing 1)" in screen, "candidate with its description", s)
    row = next(l for l in screen.splitlines() if "cmd1 " in l)
    expect(row.count("(Does thing") >= 2, "more than one column", s)
    expect(row.index("cmd7 ") < row.index("cmd10 "), "numbers in order, filled by columns", s)
    s.close()


@test
def pager_is_navigable_and_narrows_as_you_type(h):
    for i in range(1, 31):
        open(os.path.join(h, f"item{i}"), "w").close()
    s = Shell(h, cols=80, rows=30)
    s.send("ls ite" + TAB)
    expect("ls item" in s.row() and "item30" in s.text(), "common part inserted, pager open", s)
    s.send("2")
    lines = [l for l in s.text().splitlines()[1:] if l.strip()]
    expect(any("item2" in l for l in lines) and not any("item13" in l for l in lines), "narrowed to item2*", s)
    s.send(TAB)
    expect(s.row().rstrip().endswith("ls item2"), "tab selects the first", s)
    s.send(DOWN)
    expect(s.row().rstrip().endswith("ls item20"), "down moves on", s)
    s.send(CR)
    expect(s.row().rstrip().endswith("ls item20") and "item21" not in s.text(), "enter takes it, pager closed", s)
    s.send(CR, 0.15)
    expect("\nitem20\n" in s.text(), "then runs", s)
    s.send("ls ite" + TAB + "\x1b", 0.3)
    expect("item30" not in s.text().split("ls ite")[-1] and s.row().rstrip().endswith("ls item"), "escape closes", s)
    s.close()


@test
def pager_folds_long_lists(h):
    for i in range(200):
        open(os.path.join(h, f"f{i:03}"), "w").close()
    s = Shell(h, cols=40, rows=30)
    s.send("ls f" + TAB)
    expect("more rows" in s.text(), "long lists are folded", s)
    s.send(TAB)
    s.send("\x1b[6~")
    expect("rows " in s.text() and " of " in s.text(), "page down scrolls with a position", s)
    s.close()


MAN_PAGE = r""".TH DEMO 1
.SH NAME
demo \- a demo
.SH OPTIONS
.TP
\fB\-a\fR, \fB\-\-all\fR
show all entries, i.e. hidden ones too. Then more text.
.TP
.B \-\-color\fR[=\fIWHEN\fR]
colorize the output
.IP "\fB\-q\fR" 4
be quiet
.SH EXAMPLES
.TP
\fBdemo \-x\fR
not an option of its own
"""

MDOC_PAGE = r""".Dd May 1, 2025
.Dt MDEMO 1
.Sh OPTIONS
.Bl -tag -width x
.It Fl v , Fl -verbose
Print more about
.Ar everything .
.It Fl o Ar file
Write to a file.
.El
"""


@test
def completions_from_man_pages(h):
    man = os.path.join(h, "man/man1")
    os.makedirs(man)
    with gzip.open(os.path.join(man, "demo.1.gz"), "wt") as f:
        f.write(MAN_PAGE)
    open(os.path.join(man, "mdemo.1"), "w").write(MDOC_PAGE)
    open(os.path.join(man, "later.1"), "w").write(MAN_PAGE.replace("\\-\\-all", "\\-\\-later"))
    script = os.path.join(HERE, "../update-completions.sh")
    env = {"HOME": h, "PATH": "/usr/bin:/bin", "MANPATH": os.path.join(h, "man"), "FDASH_DATADIR": h + "/none"}
    r = subprocess.run(["sh", script, "demo", "mdemo"], env=env, capture_output=True, text=True)
    expect(r.returncode == 0, f"generator: {r.stderr}")
    gen = os.path.join(h, ".local/share/fdash/generated_completions")
    demo = open(os.path.join(gen, "demo")).read()
    expect("--all\tShow all entries, i.e. hidden ones too\n" in demo, f"first sentence:\n{demo}")
    expect("-a\t" in demo and "--color\tColorize the output" in demo and "-q\tBe quiet" in demo, f"man(7):\n{demo}")
    expect("-x" not in demo, f"examples are not options:\n{demo}")
    mdemo = open(os.path.join(gen, "mdemo")).read()
    expect("--verbose\tPrint more about everything" in mdemo and "-o\tWrite to a file" in mdemo, f"mdoc:\n{mdemo}")
    bindir = os.path.join(h, "bin")
    os.mkdir(bindir)
    shutil.copy(script, os.path.join(bindir, "fdash-update-completions"))
    s = Shell(h, env={"PATH": bindir + ":/usr/bin:/bin", "MANPATH": env["MANPATH"]})
    s.send("demo --a" + TAB)
    expect("demo --all" in s.row(), "a generated spec completes", s)
    s.send(CTRL_C + "demo -" + TAB)
    expect("(Colorize the output)" in s.text(), "with descriptions", s)
    s.send(CTRL_C + "later --la" + TAB)
    expect("later --later" in s.row(), "a page without a spec is read on the first tab", s)
    s.close()


@test
def directory_history(h):
    for d in ("a", "b", "c"):
        os.mkdir(os.path.join(h, d))
    s = Shell(h)
    s.run("cd a")
    s.run("cd ../b")
    s.run("cd ../c")
    s.run("prevd")
    s.run("pwd")
    expect(f"\n{h}/b\n" in s.text(), "prevd", s)
    s.run("prevd")
    s.run("nextd 2")
    s.run("pwd")
    expect(s.text().rstrip().endswith(f"{h}/c\n" + s.row().rstrip()) or f"\n{h}/c\n" in s.text(), "nextd 2", s)
    s.run("dirh")
    expect(f"{h}/a" in s.text() and f"{h}/b" in s.text(), "dirh lists them", s)
    s.run("false")
    before = len([l for l in s.text().splitlines() if l.strip()])
    s.send(ALT_LEFT, 0.2)
    expect("/b" in s.row() and "[1]" in s.row(), "alt+left on an empty line is prevd, and $? stays", s)
    s.send(ALT_RIGHT, 0.2)
    expect("/c" in s.row(), "alt+right is nextd", s)
    after = len([l for l in s.text().splitlines() if l.strip()])
    expect(after == before, "the prompt is redrawn in place", s)
    s.run("history")
    expect("prevd 2>" not in s.text(), "the keys' commands stay out of the history", s)
    s.send("cdh " + TAB)
    expect(f"{h}/a" in s.text().split("cdh", 1)[-1], "cdh completes visited directories", s)
    s.send(CTRL_C)
    s.run("cdh")
    expect("Directory number" in s.text(), "cdh asks", s)
    s.run("1")
    s.run("pwd")
    expect(s.text().count(f"\n{h}/b\n") >= 1, "cdh went there", s)
    s.close()


@test
def fish_keys(h):
    bindir = os.path.join(h, "bin")
    os.mkdir(bindir)
    for name, body in (("man", 'echo "man-called: $*"'), ("whatis", 'echo "whatis-called: $*"'),
                       ("ed.sh", "echo 'echo edited-line' > \"$1\"")):
        open(os.path.join(bindir, name), "w").write("#!/bin/sh\n" + body + "\n")
        os.chmod(os.path.join(bindir, name), 0o755)
    os.mkdir(os.path.join(h, "listme"))
    open(os.path.join(h, "listme", "inside-file"), "w").close()
    s = Shell(h, env={"PATH": bindir + ":/usr/bin:/bin", "EDITOR": bindir + "/ed.sh"})
    s.send("git commit -m x" + ALT + "h", 0.3)
    expect("man-called: -- git-commit" in s.text(), "alt+h: the man page of the command", s)
    expect(s.row().rstrip().endswith("git commit -m x"), "and the line comes back", s)
    s.send(CTRL_C + "ls -la" + ALT + "w", 0.3)
    expect("whatis-called: -- ls" in s.text(), "alt+w: whatis", s)
    s.send(CTRL_C + "echo hi" + ALT + "s")
    expect(s.row().rstrip().endswith("doas echo hi") or s.row().rstrip().endswith("sudo echo hi"), "alt+s", s)
    s.send(ALT + "s")
    expect(s.row().rstrip().endswith("> echo hi"), "alt+s again takes it off", s)
    s.send(CTRL_C + "echo original" + ALT + "e", 0.4)
    expect(s.row().rstrip().endswith("echo edited-line"), "alt+e: the line from the editor", s)
    s.send(CR, 0.15)
    expect("\nedited-line\n" in s.text(), "and it runs", s)
    s.send("cat listme" + ALT + "l", 0.3)
    expect("inside-file" in s.text() and s.row().rstrip().endswith("cat listme"), "alt+l lists the directory", s)
    s.send(CTRL_C)
    s.run("bind alt-g 'commandline -i inserted'")
    s.send("echo " + ALT + "g", 0.3)
    expect(s.row().rstrip().endswith("echo inserted"), "bind and commandline", s)
    s.close()


@test
def cyrillic_text_and_files(h):
    os.mkdir(os.path.join(h, "документы"))
    s = Shell(h)
    s.run("echo привет-мир")
    expect("привет-мир" in s.text(), "output", s)
    s.send("echo при")
    expect("echo привет-мир" in s.row(), "suggestion", s)
    s.send(RIGHT + CR, 0.1)
    s.send("ls докум" + TAB)
    expect("ls документы/" in s.row(), "file completion", s)
    s.send("\x7f" * 3)
    expect(s.row().rstrip().endswith("докумен") or "докумен" in s.row(), "backspace over letters", s)
    s.close()


@test
def abbreviations(h):
    s = Shell(h)
    s.run("abbr gs git status")
    s.send("gs ")
    expect("git status" in s.row(), "expands on space", s)
    s.send(CTRL_C + "echo gs ")
    expect("echo gs" in s.row() and "git status" not in s.row(), "only as a command", s)
    s.send(CTRL_C)
    s.run("abbr hi echo abbr-worked")
    s.send("hi" + CR, 0.1)
    expect("\nabbr-worked\n" in s.text(), "expands on enter", s)
    s.run("abbr -e hi")
    s.send("hi" + CR, 0.1)
    expect("not found" in s.text(), "erased", s)
    s.close()


@test
def implicit_cd(h):
    os.mkdir(os.path.join(h, "projects"))
    s = Shell(h)
    s.run("projects")
    s.run("pwd")
    expect(f"\n{h}/projects\n" in s.text(), "cd by name", s)
    s.run("-")
    s.run("pwd")
    expect(s.text().rstrip().count(h) >= 1, "cd back", s)
    expect(s.row().rstrip().split()[-2:] != [], "still alive", s)
    s.close()


@test
def implicit_cd_never_shadows_commands(h):
    os.mkdir(os.path.join(h, "echo"))
    s = Shell(h)
    s.run("echo")
    s.run("pwd")
    expect(f"\n{h}\n" in s.text(), "a command wins over a directory", s)
    s.close()


@test
def ctrl_c_and_ctrl_d(h):
    s = Shell(h)
    s.send("echo should-not-run" + CTRL_C, 0.1)
    expect("\nshould-not-run\n" not in s.text(), "ctrl-c cancels", s)
    s.send("abc" + LEFT + LEFT + CTRL_D)
    expect("ac" in s.row(), "ctrl-d deletes mid line", s)
    s.send(CTRL_C)
    s.send(CTRL_D)
    expect(s.wait_exit() == 0, "ctrl-d exits on an empty line")


@test
def multiline_constructs_use_ps2(h):
    s = Shell(h)
    s.run("if true; then")
    expect(s.row().startswith(">"), "PS2 shown", s)
    s.run("echo inside-if")
    s.run("fi")
    expect("\ninside-if\n" in s.text(), "ran", s)
    s.close()


@test
def backslash_continuation_stays_posix(h):
    s = Shell(h)
    s.run("echo con\\")
    s.run("tinued")
    expect("\ncontinued\n" in s.text(), "joined", s)
    s.close()


@test
def heredoc(h):
    s = Shell(h)
    s.run("cat <<END")
    s.run("line in heredoc")
    s.run("END")
    expect("\nline in heredoc\n" in s.text(), "heredoc", s)
    s.close()


@test
def ctrl_c_kills_foreground_job(h):
    s = Shell(h, args=("-m",) if False else ())
    s.run("sleep 100", 0.2)
    s.send(CTRL_C, 0.3)
    expect("[130]" in s.row(), "status 130", s)
    s.close()


@test
def job_control(h):
    s = Shell(h)
    s.run("sleep 100", 0.2)
    s.send(CTRL_Z, 0.3)
    expect("Stopped" in s.text() or "stopped" in s.text(), "stopped", s)
    s.run("jobs", 0.2)
    expect("sleep 100" in s.text(), "listed", s)
    s.run("fg", 0.3)
    s.send(CTRL_C, 0.3)
    expect("[130]" in s.row(), "back in foreground", s)
    s.close()


@test
def background_job_ending_keeps_the_suggestion(h):
    s = Shell(h)
    s.run("echo remember-this")
    s.run("sleep 0.3 &")
    s.send("echo rem")
    expect("echo remember-this" in s.row(), "suggestion", s)
    time.sleep(0.6)
    s.settle()
    expect("echo remember-this" in s.row(), "still drawn after SIGCHLD", s)
    s.send(RIGHT + CR, 0.1)
    expect("\nremember-this\n" in s.text(), "still accepted after SIGCHLD", s)
    s.close()


@test
def typed_ahead_and_pasted_lines_are_kept(h):
    s = Shell(h)
    s.send("sleep 0.3" + CR + "echo typed-ahead" + CR, 0.6)
    expect("\ntyped-ahead\n" in s.text(), "typed while a command ran", s)
    s.send("echo pasted-1" + CR + "echo pasted-2" + CR + "echo pasted-3" + CR, 0.3)
    for n in "123":
        expect(f"\npasted-{n}\n" in s.text(), f"pasted line {n}", s)
    s.close()


@test
def completing_a_variable_leaves_it_intact(h):
    s = Shell(h, env={"MY_KEEP": "kept-value"})
    s.send("echo $MY_K" + TAB)
    s.send(CTRL_C)
    s.run("echo $MY_KEEP")
    expect("\nkept-value\n" in s.text(), "value survives", s)
    s.run("env | grep MY_KEEP")
    expect("\nMY_KEEP=kept-value\n" in s.text(), "exported value survives", s)
    s.close()


@test
def child_gets_a_cooked_terminal(h):
    s = Shell(h)
    s.run("stty -a | tr ' ' '\\n' | grep -E '^-?icanon$|^-?echo$' | tr '\\n' ','")
    expect("icanon,echo," in s.text(), "canonical mode for children", s)
    s.close()


@test
def read_builtin_from_terminal(h):
    s = Shell(h)
    s.run("read x")
    s.run("typed-answer")
    s.run("echo got:$x")
    expect("\ngot:typed-answer\n" in s.text(), "read", s)
    s.close()


@test
def sigint_from_outside_at_prompt(h):
    s = Shell(h)
    s.send("half typed")
    os.kill(s.pid, signal.SIGINT)
    s.settle(0.2)
    expect(s.alive(), "survives", s)
    s.run("")
    s.run("echo still-works")
    expect("\nstill-works\n" in s.text() or "still-works" in s.text(), "usable", s)
    s.close()


@test
def resize_does_not_break_editing(h):
    s = Shell(h)
    s.send("echo resized")
    fcntl.ioctl(s.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 20, 60, 0, 0))
    s.screen.resize(20, 60)
    os.kill(s.pid, signal.SIGWINCH)
    s.settle(0.1)
    s.send("-ok" + CR, 0.1)
    expect("resized-ok" in s.text(), "line intact", s)
    s.close()


@test
def config_file_runs_only_when_interactive(h):
    d = os.path.join(h, ".config/fdash")
    os.makedirs(d)
    open(os.path.join(d, "config.sh"), "w").write("alias hello='echo from-config'\nMARK=loaded\n")
    s = Shell(h)
    s.run("hello")
    expect("\nfrom-config\n" in s.text(), "alias from config", s)
    s.close()
    out = subprocess.run([FDASH, "-c", 'echo "[$MARK]"'], env={"HOME": h, "PATH": "/usr/bin:/bin"},
                         capture_output=True, text=True).stdout
    expect(out == "[]\n", "not loaded by -c")


@test
def login_shell_reads_profile(h):
    open(os.path.join(h, ".profile"), "w").write("PROFILE_MARK=read\n")
    s = Shell(h, args=("-l",))
    s.run("echo mark:$PROFILE_MARK")
    expect("\nmark:read\n" in s.text(), "~/.profile runs at login", s)
    s.close()


@test
def custom_prompts(h):
    s = Shell(h, env={"PS1": "[plain] $ "})
    expect(s.row().startswith("[plain] $"), "PS1 literal with brackets", s)
    s.close()
    s = Shell(h, env={"FDASH_PS1": "[ansi-red]custom[/]> "})
    expect(s.row().startswith("custom>"), "markup prompt", s)
    expect("red" in s.color_of("custom"), f"markup prompt color {s.color_of('custom')}", s)
    s.close()
    s = Shell(h, env={"PS1": "\x1b[31mred\x1b[0m $ "})
    expect(s.row().startswith("red $"), "escapes dropped from PS1", s)
    s.close()


@test
def git_branch_in_prompt_without_git(h):
    os.makedirs(os.path.join(h, "repo/.git"))
    open(os.path.join(h, "repo/.git/HEAD"), "w").write("ref: refs/heads/feature-x\n")
    os.makedirs(os.path.join(h, "repo/sub"))
    s = Shell(h, env={"PATH": "/nonexistent"}, cwd=os.path.join(h, "repo/sub"))
    expect("(feature-x)" in s.row(), "branch read from HEAD", s)
    s.close()


@test
def hostile_names_cannot_inject_terminal_sequences(h):
    os.makedirs(os.path.join(h, "repo/.git"))
    open(os.path.join(h, "repo/.git/HEAD"), "w").write("ref: refs/heads/x\x1b]0;PWNED\x07y\n")
    os.mkdir(os.path.join(h, "evil\x1b[31mdir"))
    s = Shell(h, cwd=os.path.join(h, "repo"))
    expect(b"\x1b]0;PWNED" not in s.raw, "branch name sanitized", s)
    s.close()
    s = Shell(h, cwd=os.path.join(h, "evil\x1b[31mdir"))
    idx = s.raw.rfind(b"]133;A")
    expect(b"evil\x1b[31m" not in s.raw[idx:], "directory name sanitized", s)
    s.close()
    open(os.path.join(h, "zz\x1b]0;PWNED\x07a"), "w").close()
    open(os.path.join(h, "zz\x1b]0;PWNED\x07b"), "w").close()
    s = Shell(h)
    s.send("ls zz" + TAB)
    expect(b"\x1b]0;PWNED" not in s.raw, "completion menu sanitized", s)
    s.close()


def responsive(s, tag="alive-marker"):
    s.send(CTRL_C, 0.1)
    s.run(f"echo {tag}", 0.2)
    deadline = time.time() + 2.5
    while time.time() < deadline:
        if f"\n{tag}\n" in s.text():
            return True
        s.settle(0.1, 0.2)
    return False


@test
def hostile_git_head_cannot_hang_the_prompt(h):
    cases = {
        "fifo": lambda d: os.mkfifo(d + "/.git/HEAD"),
        "tty": lambda d: os.symlink("/dev/tty", d + "/.git/HEAD"),
        "stdin": lambda d: os.symlink("/proc/self/fd/0", d + "/.git/HEAD"),
        "zero": lambda d: os.symlink("/dev/zero", d + "/.git/HEAD"),
    }
    for name, plant in cases.items():
        d = os.path.join(h, name)
        os.makedirs(d + "/.git")
        plant(d)
    # a .git file that points at a directory holding a FIFO
    os.makedirs(h + "/elsewhere")
    os.mkfifo(h + "/elsewhere/HEAD")
    os.makedirs(h + "/gitfile")
    open(h + "/gitfile/.git", "w").write(f"gitdir: {h}/elsewhere\n")
    for name in [*cases, "gitfile"]:
        s = Shell(h)
        s.run(f"cd {name}", 0.3)
        expect(responsive(s, f"alive-in-{name}") and s.alive(), f"{name}: prompt must stay usable", s)
        s.close()


@test
def git_prompt_still_reads_real_repositories(h):
    os.makedirs(h + "/plain/.git")
    open(h + "/plain/.git/HEAD", "w").write("ref: refs/heads/feature/x\n")
    os.makedirs(h + "/worktrees/w1")
    open(h + "/worktrees/w1/HEAD", "w").write("ref: refs/heads/from-worktree\n")
    os.makedirs(h + "/linked")
    open(h + "/linked/.git", "w").write("gitdir: ../worktrees/w1\n")
    os.makedirs(h + "/detached/.git")
    open(h + "/detached/.git/HEAD", "w").write("0123456789abcdef0123456789abcdef01234567\n")
    os.makedirs(h + "/junk/.git")
    open(h + "/junk/.git/HEAD", "w").write("not a head at all\n")
    for cwd, wanted in (("plain", "(feature/x)"), ("linked", "(from-worktree)"), ("detached", "(01234567)")):
        s = Shell(h, cwd=f"{h}/{cwd}")
        expect(wanted in s.row(), f"{cwd}: {wanted}", s)
        s.close()
    s = Shell(h, cwd=f"{h}/junk")
    expect("(" not in s.row(), "junk HEAD shows no branch", s)
    s.close()


@test
def deep_nesting_cannot_crash_the_shell(h):
    for opener in ("$(", '"$(', "$("):
        s = Shell(h, cols=200)
        text = "echo " + opener * 30000
        for i in range(0, len(text), 512):
            s.send(text[i:i + 512], 0.002)
        s.settle(0.3, 6)
        expect(s.alive(), f"survives 30000 nested {opener}", None)
        expect(responsive(s), f"usable after 30000 nested {opener}", None)
        s.close()


def rss_mib(pid):
    for line in open(f"/proc/{pid}/status"):
        if line.startswith("VmRSS"):
            return int(line.split()[1]) // 1024
    return -1


@test
def pasting_does_not_eat_memory(h):
    s = Shell(h, cols=200)
    text = "echo " + "x" * (200 * 1024)
    for i in range(0, len(text), 4096):
        s.send(text[i:i + 4096], 0.001)
    s.settle(0.3, 10)
    used = rss_mib(s.pid)
    expect(s.alive(), "survives a 200 KiB paste", None)
    # ASan keeps up to 256 MiB of freed memory and adds its shadow to RSS. A quadratic
    # undo still goes far over this limit.
    limit = 512 if "ASAN_OPTIONS" in os.environ else 64
    expect(used < limit, f"used {used} MiB for a 200 KiB paste", None)
    expect(responsive(s), "usable afterwards", None)
    s.close()


@test
def undo_still_works(h):
    s = Shell(h)
    s.send("ab", 0.05)
    s.send("c", 0.05)
    s.send(CTRL_Z, 0.05)
    expect(s.row().rstrip().endswith("ab"), "one typed key undone", s)
    s.send(CTRL_C, 0.05)
    s.send("base ", 0.05)
    s.send("pasted words all at once")
    s.send(CTRL_Z, 0.05)
    expect("pasted" not in s.row() and "base" in s.row(), "a paste is one undo step", s)
    s.close()


@test
def readonly_status_does_not_loop(h):
    s = Shell(h)
    s.send("readonly status" + CR, 0.3)
    before = len(s.raw)
    s.settle(0.2, 0.8)
    expect(len(s.raw) - before < 500, f"prompt loop, {len(s.raw) - before} bytes", None)
    expect(responsive(s), "usable", None)
    s.run("false", 0.1)
    expect("[1]" in s.row(), "the prompt still shows the failure", s)
    s.close()


@test
def prompt_goes_to_stderr(h):
    s = Shell(h)
    s.run("exec >/dev/null")
    s.send("echo x")
    expect("echo x" in s.row(), "still drawn with stdout redirected", s)
    s.close()


@test
def long_lines_cross_the_input_buffer(h):
    s = Shell(h, cols=200)
    payload = "x" * 9000
    s.send("printf %s " + payload + " | wc -c" + CR, 0.5)
    deadline = time.time() + 20
    while "9000" not in s.text() and time.time() < deadline:
        s.settle(0.2)
    expect("9000" in s.text(), "9000 bytes survive", s)
    s.close()


def no_tty(args, stdin="", env=None):
    e = {"HOME": "/nonexistent", "PATH": "/usr/bin:/bin"}
    e.update(env or {})
    return subprocess.run([FDASH, *args], input=stdin, env=e, capture_output=True, text=True, timeout=10)


@test
def plain_paths_never_touch_the_editor(h):
    r = no_tty([], "echo from-pipe\n", {"HOME": h})
    expect(r.stdout == "from-pipe\n", "stdin pipe")
    r = no_tty(["-i"], "echo from-i\n", {"HOME": h})
    expect("from-i" in r.stdout, "-i with a pipe")
    expect(not os.path.exists(os.path.join(h, ".local/share/fdash")), "no history for non tty")
    script = os.path.join(h, "s.sh")
    open(script, "w").write("echo script $1\n")
    expect(no_tty([script, "arg"]).stdout == "script arg\n", "script")


CORPUS = r'''
set -u
f() { echo "fn:$#:$*"; return 3; }
f a "b c"; echo "st=$?"
x=$(printf '%s' abc); echo "${#x} ${x%c} ${x#a} ${x:-d}"
for i in 1 2 3; do case $i in 2) continue;; esac; echo i$i; done
n=0; while [ $n -lt 3 ]; do n=$((n+1)); done; echo $n
echo "$((3*(4+5)%7)) $((1<<4)) $((0x10))"
cat <<EOF
here $x $(echo sub)
EOF
cat <<'EOF'
raw $x
EOF
(exit 7); echo "sub=$?"
{ echo grp; } | tr a-z A-Z
trap 'echo trapped' EXIT
set -- p q r; shift; echo "$# $1"
IFS=:; set -- a:b:c; echo "$2"; unset IFS
printf '%05d|%-4s|%x\n' 42 ab 255
test -n "abc" && echo yes || echo no
[ 1 -eq 1 ] && [ abc != def ] && echo ok
alias foo='echo aliased'; eval 'foo'
readonly R=1; (R=2) 2>/dev/null || echo ro
command -v echo; type true
var=v; export var; sh -c 'echo $var'
echo a b  c | { read -r p q; echo "$p/$q"; }
ls /nonexistent-path 2>/dev/null; echo "ls=$?"
echo ${UNSETVAR-dflt} ${x+set}
wait; jobs; times >/dev/null
umask 022; umask
getopts ab: o -a; echo "$o"
'''


@test
def scripts_behave_like_stock_dash_of_the_same_version(h):
    if not STOCK:
        return
    script = os.path.join(h, "corpus.sh")
    open(script, "w").write(CORPUS)
    env = {"HOME": h, "PATH": "/usr/bin:/bin"}
    for args in ([script], ["-c", CORPUS], ["-s"]):
        inp = CORPUS if args == ["-s"] else None
        a = subprocess.run([FDASH, *args], input=inp, env=env, capture_output=True, text=True)
        b = subprocess.run([STOCK, *args], input=inp, env=env, capture_output=True, text=True)
        norm = lambda t: t.replace(FDASH, "SH").replace(STOCK, "SH")
        expect(a.returncode == b.returncode, f"exit code {args[0]}: {a.returncode} vs {b.returncode}")
        expect(norm(a.stdout) == norm(b.stdout), f"stdout {args[0]}:\n{a.stdout}\nvs\n{b.stdout}")
        expect(norm(a.stderr) == norm(b.stderr), f"stderr {args[0]}:\n{a.stderr}\nvs\n{b.stderr}")


def main():
    if not os.access(FDASH, os.X_OK):
        sys.exit(f"{FDASH}: not executable")
    if os.geteuid() == 0:
        os.setgid(65534)
        os.setuid(65534)
    passed = failed = 0
    for fn in tests:
        if ONLY and ONLY not in fn.__name__:
            continue
        home = tempfile.mkdtemp(prefix="fdash-test-")
        try:
            fn(home)
            passed += 1
            print(f"ok    {fn.__name__}")
        except Exception as e:
            failed += 1
            print(f"FAIL  {fn.__name__}: {e}")
        finally:
            shutil.rmtree(home, ignore_errors=True)
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
