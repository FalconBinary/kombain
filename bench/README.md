# bench: real measurements of this machine

Before anything here is called faster, lighter or quieter, it is measured on the GF63 as it
is used: a build with the desktop open, a game, the boot, an hour on battery. Not a synthetic
score. `kombain-bench` takes those measurements and keeps them as CSV rows, with a label for
what was running (by default the kernel and PID 1, like `6.18.59_1/runit`), so that a change
is compared against the rows before it.

```sh
doas kombain-bench boot             # this boot's stages: firmware, kernel, initramfs and LUKS, stage 1, services to the desktop
doas kombain-bench idle             # 60 s at rest: interrupts and context switches per second, CPU busy, memory, PSS, package watts, battery watts
kombain-bench jitter                # 30 s: how late a 144 Hz task wakes with nothing else running
doas kombain-bench build            # make -j12 of fdash, 3 runs after a warm-up: seconds, joules, and the desktop's jitter under it
                                    # (root reads the joules; make still runs as the tree's owner)
kombain-bench game ~/mangohud.csv   # frame times of a game: average fps, 1 % low, p50, p99, the worst frame
kombain-bench battery --minutes 10  # watts from the battery while you use the machine as you mean to measure it
doas kombain-bench sched            # schedulers in turns, 5 rounds: jitter and build under each (a sched_ext kernel: see below)
kombain-bench summary               # medians and p95 of every row so far, per label
```

The rows go to `/var/tmp/kombain-bench/*.csv` (`KOMBAIN_BENCH_DIR` moves them): root makes the
directory everyone's, as `/tmp` is, and its files writable by all; a user who still cannot write
there writes to `~/.local/share/kombain-bench`, and `summary` reads both. `--label NAME` names a
variant yourself: `stock`, `vh-kernel`, `scx_lavd`. When a measurement's columns change, the old
file is moved aside, never mixed.

## The method

Borrowed from UniVoidDistro's rules, which are the honest ones:

- the metrics are fixed before measuring, and listed here;
- variants are compared on the same machine, alternating, with the first run of each
  discarded as its warm-up (`build` does that itself);
- at least 5 runs of a long measurement and at least 10 boots per variant; the summary shows
  medians and p95, never a single number;
- "faster" means the medians differ by 3 % or more, in the direction claimed, with the p95 not
  worse. A smaller difference is noise until more runs say otherwise;
- on the GF63: plugged in unless battery is what is measured, the same `noise` and `epp`
  settings, cooled below 50 C before a `build` run (zcool shows the temperature), the same
  brightness for `battery`;
- nothing is tuned while a run goes.

## What each measurement means

| Measurement | What is read | Why it is the real thing |
|---|---|---|
| `boot` | the ACPI FPDT (firmware time), `dmesg` ("Run /init as init process": the kernel until the initramfs), stage 1 markers that `/etc/runit/core-services` write, the tty login from utmp (`utmpdump`), a marker the session writes at login and one when the panel is up | the time from the power button to a usable desktop, by stage: a faster init shows in stage 1 and in stage 2 until the login, a smaller kernel in the kernel's own time, the session's own cost between the login and the panel. The initramfs stage includes typing the LUKS passphrase: compare it with care. On the GF63 the first boot measured 10.4 s of firmware, 3.4 s of kernel, 2.3 s of stage 1 and 19 s from stage 1 to the desktop: the last is where a boot is won, not in PID 1 |
| `idle` | `/proc/stat` interrupts and context switches per second, CPU busy %, `MemAvailable`, the PSS of every process (root), the CPU package's RAPL watts (root), the battery's watts when discharging | what the system costs while doing nothing: the daemons' wakeups, the memory they hold, the watts |
| `jitter` | `zjitter`: a task that wants to wake 144 times a second, how late each wake came (p50, p99, the worst), and how many came a whole frame late | a game's frame loop, the compositor and audio live on this; a scheduler is judged by it under load, not on throughput alone |
| `build` | `make -j N` of fdash (gcc, a real C program), wall seconds, joules of the CPU package (root), and `zjitter` at 144 Hz beside it: the desktop's frames while every core compiles | the developer's own workload, and whether the desktop stays smooth through it (ztune's SCHED_BATCH, the scheduler, the power limit) |
| `game` | a MangoHud CSV log (`MANGOHUD_CONFIG=output_folder=DIR`, F2 in the game starts and stops it): average fps, the 1 % low, p50 and p99 frame times, the worst frame | the player's experience: the 1 % low and p99 are what stutter is |
| `battery` | the battery's watts every 5 s for N minutes, the median and p95, the brightness, the hours left at that rate | the only number that matters on battery |
| `sched` | `jitter` and `build` under each scheduler in turn, the kernel's own and sched_ext ones, round after round, cooled below 50 C before each | a scheduler is judged where it shows: how late the desktop wakes beside a build, and what the build cost in seconds and joules; the rows are the same jitter and build rows, labelled kernel/variant |

## Schedulers

The kernel's own scheduler (EEVDF) against sched_ext ones, on a kernel that has sched_ext:
kombain's (`kernel/README.md`; `/sys/kernel/sched_ext` exists on it). The stock Void kernel has
none, and `sched` says so. Void packages the scx schedulers: `xbps-install -S scx` brings
`scx_lavd`, `scx_bpfland`, `scx_flash`, `scx_rusty`, `scx_p2dq`, `scx_cosmos` and the others of
its release, with `scxtop`. UniVoidDistro's `vh-sched` runs the same way, as a command.

```sh
doas kombain-bench sched                                       # stock, scx_lavd, scx_bpfland, scx_flash: 5 rounds
doas kombain-bench sched --rounds 3 --with 'stock,scx_lavd,lavd-perf=scx_lavd --performance,vh-sched=vh-sched run'
```

Every round goes through the variants in turn, starting one variant later each round, so that
no variant always follows the same one. For each: the scheduler is started (a bare name is a
program on PATH; `NAME=COMMAND` is any command; it runs as root until SIGTERM, which every
sched_ext scheduler takes as "unload and leave") and the kernel is asked whether it runs it
(`/sys/kernel/sched_ext/state` and `root/ops`); the package cools below 50 C (`--cool C`, `off`
to skip, as a VM has no temperature); `jitter` runs for 30 s with nothing else; `build` makes
its warm-up and one build (`--runs N` for more); the scheduler is stopped and the kernel is back
on its own before the next. Everything a variant needs is checked before the first measurement,
not an hour in. The rows are the ordinary `jitter.csv` and `build.csv` rows, labelled by kernel
and variant: `6.18.62-kombain_1/stock`, `6.18.62-kombain_1/scx_lavd`; each scheduler's own output
is kept as `sched-NAME.log` beside them. The summary at the end puts the variants side by side.
The method's rule decides, and UniVoidDistro's criterion for a scheduler is the honest one: it may
lose no more than 2 % of the build's time against EEVDF and must win the desktop's p99 under that
build. Ctrl-C stops the run and the scheduler with it. A scheduler the kernel throws out mid-run
ends the run and says so, since what was measured after that ran under the kernel's own. Nothing
is installed: which scheduler runs in which mode is decided after the numbers, not before. Game
rows come by hand: `doas scx_lavd` in a terminal, the game with MangoHud, then
`kombain-bench game FILE.csv --label 6.18.62-kombain_1/scx_lavd`, and Ctrl-C in that terminal.

## Markers

`install.sh` puts `01-kombain-bench.sh` and `99-zz-kombain-bench.sh` into
`/etc/runit/core-services`: they write the uptime when stage 1 begins and ends to
`/run/kombain-bench/`. The session marks itself: `kombain-bench mark session-start` in
`~/.profile` before mango starts, and `exec_once=kombain-bench mark desktop-ready` in mango's
config once the panel is up (both are in `config/`; an existing home keeps its own files, so
add the two lines there yourself). `boot` reads them from `/run/user/UID/`.

## zjitter

A 16 KiB Zig program without libc (`bench/src/jitter.zig`): it sleeps on the monotonic clock with
absolute deadlines (`clock_nanosleep`), so its own work never shifts the schedule, records how
late every wake came in microseconds, and reports p50, p99, the worst, and how many wakes came
a whole frame or more late (every skipped deadline counts). SIGTERM ends it with its report.

```sh
zjitter --hz 144 --seconds 30        # a sentence
zjitter --hz 144 --seconds 30 --csv  # hz,seconds,wakes,misses,p50_us,p99_us,max_us
```

## Checks

```sh
cd bench && zig build -Doptimize=ReleaseSafe && zig build test
sh tests/bench.sh                    # the parsers against fixtures (a dmesg, an FPDT, markers, a MangoHud log), the summary math, zjitter for real
```
