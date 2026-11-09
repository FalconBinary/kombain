# ztune

The rest of the system tuned to what it does now. [zcool](../zcool/) has the CPU and the
GPUs: their clocks, power, turbo, energy preference and fans. ztune has how devices sleep, how
memory is reclaimed, when the disk is written, and how a build shares the CPU with the
desktop, on mains and on battery, while a game or a build runs. It finds games and builds by
their processes, and every value it changes goes back when it stops, however it stops.

Pure Zig with no libc: a 57 KiB binary that wakes every 3 s. Then it reads `/proc/loadavg`,
one line, and looks at every process only when the kernel has handed out a pid since the last
look (no new process, no new game or build) or 30 s have passed; a build or a game is watched at
every tick. At rest with 150 processes that is 0.3 wakeups and about 0.1 ms of CPU a second.

## What it sets

| Setting | Battery | Mains | Build | Game | Why |
|---|---|---|---|---|---|
| PCIe link power (ASPM) | powersupersave | the firmware's | as the source | performance | Links that sleep deep save watts on battery; a game wants none waking late. |
| Wi-Fi power saving (nl80211) | on | off | as the source | off | A card that dozes between beacons saves watts and makes a ping wait up to 100 ms. |
| Writeback, dirty pages expire | 60 s, 60 s | 15 s, 30 s | as the source | 15 s, 30 s | On battery the disk wakes once a minute. |
| Dirty memory before writers wait | 256 MiB, 64 in the background | same | 1 GiB, 256 MiB | 256 MiB, 64 | The kernel's 20% of memory is 6 GiB on 32: a flush that size stalls the desktop. A build writes many objects. |
| Transparent huge pages | madvise | madvise | always | madvise | A compiler gains from huge pages; the rest only those that ask. |
| A build's processes | | | SCHED_BATCH | | Never preempting the desktop on waking: it stays smooth while every core builds. |

And once, whatever the source and the mode:

| Setting | Value | Why |
|---|---|---|
| NMI watchdog | off | A hardware counter and wakeups nobody here uses. |
| MGLRU `min_ttl_ms` | 1000 | Out of memory, the kernel ends a process instead of grinding its swap for minutes: the working set of the last second is kept. |
| kswapd watermark | 1.25% | Reclaim starts early, so an allocation rarely waits for it. |
| Huge page defrag | defer+madvise | Never compacting memory in the path of an allocation. |
| I/O scheduler | none for NVMe and a VM's disk, BFQ for a disk that spins, mq-deadline for a SATA SSD | NVMe queues in hardware and a host schedules for its VMs; BFQ keeps reads coming to the desktop while something writes. |

What zcool sets, ztune leaves alone. So are USB autosuspend (a mouse that stutters, a disk
that drops) and the integrated GPU's clocks (the desktop's animations), each a trade nobody
should get by surprise.

## Games and builds

A game runs while `gamescope`, Steam's `reaper` (it lives exactly as long as a game Steam
started), Wine's processes or any `.exe` runs; Wine names are kept to 15 characters, so
`Cyberpunk2077.e` is one too. A build runs while compilers, linkers and build tools (make,
ninja, cc1, rustc, cargo, clang, mold, zig, go's compile and more) keep half a core busy, and
stays one for 15 s after, through the pauses between its steps. A game outranks a build.
`game.add` and `build.add` name more.

In a build, ztune moves its processes and their threads from SCHED_OTHER to SCHED_BATCH, so
what they start inherits it, and back when the build ends or ztune stops. Nothing real-time
or idle is touched.

## How many jobs a build should run

`doas ztune calibrate`, plugged in, about two minutes: it runs a load shaped like a compiler's
(hashing, branches, scattered reads over 192 KiB, within a core's own cache as most of a
compiler's working set is) on all the CPUs, three quarters, half, a quarter and one, from the
top after a warm-up, so every step is measured on a machine as warm and as power-trimmed as a
long build keeps it. It takes the fewest jobs within 3% of the fastest, and never fewer than
there are cores. A laptop held at its temperature limit may build as fast on nine jobs as on
twelve, and the last three only add heat and noise. The result goes to `/etc/profile.d/ztune.sh`:

```sh
: "${MAKEFLAGS:=-j9}"
: "${CARGO_BUILD_JOBS:=9}"
: "${CMAKE_BUILD_PARALLEL_LEVEL:=9}"
```

A value set before that file is read wins. ninja and `zig build` choose their own and are left
to it. `jobs = 9` in the config writes that number without measuring.

## Use it

```sh
ztune check               # what it would set now and why, beside what is set
doas ztune run --dry-run  # says what it would do, writes nothing
doas ztune calibrate      # once, plugged in: the jobs builds run fastest with
doas ln -s /etc/sv/ztune /etc/runit/runsvdir/default/
```

For the gaming mode from the install guide, also link it into `runsvdir/gaming`. Logs go to
`/var/log/ztune/current`: one line when the mode or the source changes, one per setting that
moves with it.

`/etc/ztune.conf` turns any part off: `aspm`, `wifi`, `memory`, `disk`, `nmi_watchdog`,
`build`, `game`, each `= no`. See `ztune.conf.example`.

## Safety

- **Everything changed is journaled first,** in `/run/ztune/state`, and only paths under
  `/sys` and `/proc/sys` are ever written back. A clean stop, a crash and `kill -9` all end in
  the originals: the last through the runit `finish` script, or at the next start.
- **dirty_bytes and dirty_ratio are one setting**: writing one zeroes the other. While the
  ratio held, the ratio is what goes back.
- **After setup it is sandboxed** with Landlock: it reads `/proc` and its own state, writes
  `/sys`, `/proc/sys` and its journal, and nothing else, though it runs as root.
- **A setting the kernel refuses is left as it was** and said once: ASPM on a board whose
  firmware keeps it, a scheduler a disk does not offer.
- **Wi-Fi power saving and the builds' scheduling go back on a stop**, not through the
  journal: after `kill -9` a card keeps what it was set to until the next power source change
  or reboot, and a build keeps SCHED_BATCH until it ends.

## Checks

```sh
zig build test                              # the decisions, without system calls
zig build -Doptimize=ReleaseSafe
python3 tests/run.py zig-out/bin/ztune      # the real binary against a fake /sys, /proc/sys and /proc
```

Each power source and mode and what it sets, a build's real processes moved to SCHED_BATCH
and back when it ends and when ztune stops, a game found by gamescope and by a Wine name on
battery, everything back after SIGTERM, `kill -9` with `ztune restore` and the next start, a
config that leaves parts alone, `check` saying what and why and changing nothing, a dry run
writing nothing, and calibration measuring jobs on the real CPUs and writing them for shells.
In a VM with the real kernel: `ztune check` reads it, and a dry run starts with Landlock on.
It proves the logic and what each file gets. It proves nothing about how a real kernel and
real devices take these values: ASPM above all differs from board to board.
