#!/usr/bin/env python3
"""Measures what fdash costs next to other shells, on this machine.

Keep every binary on the same local disk: run from a mount shared with another
machine, a binary looks several times slower than it is.
"""
import json
import os
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import time

if os.geteuid() == 0:
    os.setgid(65534)
    os.setuid(65534)
STOCK = sys.argv[2] if len(sys.argv) > 2 else None
SHELLS = [("fdash", os.path.abspath(sys.argv[1]))]
if STOCK:
    SHELLS.append(("dash (same version, unmodified)", STOCK))
for name in ("dash", "bash", "zsh", "fish"):
    path = shutil.which(name)
    if path:
        SHELLS.append((name + " (distro)", path))


def hyperfine(cmd):
    out = tempfile.mktemp(suffix=".json")
    subprocess.run(["hyperfine", "-N", "--warmup", "50", "--runs", "300", "--export-json", out, cmd],
                   capture_output=True, check=True)
    r = json.load(open(out))["results"][0]
    os.unlink(out)
    return r["median"] * 1000, r["stddev"] * 1000


LOOP = "i=0; while [ $i -lt 200000 ]; do i=$((i+1)); done"


def first_prompt(path, home, needle):
    """Time until the shell has printed its prompt and is waiting, and its memory then."""
    env = {"HOME": home, "TERM": "xterm-256color", "LANG": "C.UTF-8", "PATH": "/usr/bin:/bin", "USER": "t"}
    start = time.perf_counter()
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.chdir(home)
            os.execve(path, [path], env)
        finally:
            os._exit(127)
    buf = b""
    while needle not in buf and time.perf_counter() - start < 10:
        r, _, _ = select.select([fd], [], [], 5)
        if not r:
            break
        buf += os.read(fd, 65536)
    took = (time.perf_counter() - start) * 1000
    # the prompt can be drawn before setup is done: wait for it to settle
    while select.select([fd], [], [], 0.25)[0]:
        try:
            os.read(fd, 65536)
        except OSError:
            break
    rss = 0
    for line in open(f"/proc/{pid}/status"):
        if line.startswith("VmRSS"):
            rss = int(line.split()[1])
    return took, rss, pid, fd


def key_latency(fd, n=200):
    """Time from a key press to the redraw, with highlighting and suggestions on."""
    times = []
    for i in range(n):
        key = b"abcdefgh"[i % 8:i % 8 + 1]
        t = time.perf_counter()
        os.write(fd, key)
        select.select([fd], [], [], 1)
        times.append((time.perf_counter() - t) * 1000)
        time.sleep(0.002)
        while select.select([fd], [], [], 0)[0]:
            os.read(fd, 65536)
        if i % 30 == 29:
            os.write(fd, b"\x03")
            time.sleep(0.01)
            while select.select([fd], [], [], 0.005)[0]:
                os.read(fd, 65536)
    times.sort()
    return times[len(times) // 2], times[int(len(times) * 0.99)]


print("| shell | size | `-c true` | 200k loop |")
print("|---|---|---|---|")
for name, path in SHELLS:
    size = os.path.getsize(os.path.realpath(path)) // 1024
    a = hyperfine(f"{path} -c true")
    t = time.perf_counter()
    posix = subprocess.run([path, "-c", LOOP], capture_output=True).returncode == 0
    loop = (time.perf_counter() - t) * 1000
    print(f"| {name} | {size} KiB | {a[0]:.2f} ms | {f'{loop:.0f} ms' if posix else 'not POSIX'} |")

fdash = SHELLS[0][1]
print("\n| interactive | first prompt | RSS at prompt |")
print("|---|---|---|")
for label, path, needle in (("fdash, empty history", fdash, b">"), ("bash", shutil.which("bash"), b"$"),
                            ("zsh", shutil.which("zsh"), b"%"), ("fish", shutil.which("fish"), b">")):
    if not path:
        continue
    best = None
    for _ in range(15):
        home = tempfile.mkdtemp()
        open(home + "/.zshrc", "w").close()
        took, rss, pid, fd = first_prompt(path, home, needle)
        os.kill(pid, 9)
        os.waitpid(pid, 0)
        os.close(fd)
        shutil.rmtree(home, ignore_errors=True)
        best = min(best or (took, rss), (took, rss))
    print(f"| {label} | {best[0]:.1f} ms | {best[1]} KiB |")

home = tempfile.mkdtemp()
os.makedirs(home + "/.local/share/fdash")
with open(home + "/.local/share/fdash/history", "w") as f:
    for i in range(10000):
        f.write(f"git commit -m 'change number {i}' --author someone{i % 50}\n")
best = None
for _ in range(15):
    took, rss, pid, fd = first_prompt(fdash, home, b">")
    if _ < 14:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
        os.close(fd)
    best = min(best or (took, rss), (took, rss))
print(f"| fdash, 10000 history lines | {best[0]:.1f} ms | {best[1]} KiB |")
med, p99 = key_latency(fd)
print(f"\nKey press to redraw with 10000 history lines: median {med:.2f} ms, p99 {p99:.2f} ms")
os.kill(pid, 9)
