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
kombain-bench build                 # make -j12 of fdash, 3 runs after a warm-up: seconds, joules, and the desktop's jitter under it
kombain-bench game ~/mangohud.csv   # frame times of a game: average fps, 1 % low, p50, p99, the worst frame
kombain-bench battery --minutes 10  # watts from the battery while you use the machine as you mean to measure it
kombain-bench summary               # medians and p95 of every row so far, per label
```

The rows go to `/var/tmp/kombain-bench/*.csv` (`KOMBAIN_BENCH_DIR` moves them). `--label NAME`
names a variant yourself: `stock`, `vh-kernel`, `scx_lavd`.

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
| `boot` | the ACPI FPDT (firmware time), `dmesg` ("Run /sbin/init": the kernel until the initramfs), stage 1 markers that `/etc/runit/core-services` write, a marker the session writes at login and when the panel is up | the time from the power button to a usable desktop, by stage: a faster init shows in stage 1 and services, a smaller kernel in the kernel's own time. The initramfs stage includes typing the LUKS passphrase: compare it with care |
| `idle` | `/proc/stat` interrupts and context switches per second, CPU busy %, `MemAvailable`, the PSS of every process (root), the CPU package's RAPL watts (root), the battery's watts when discharging | what the system costs while doing nothing: the daemons' wakeups, the memory they hold, the watts |
| `jitter` | `zjitter`: a task that wants to wake 144 times a second, how late each wake came (p50, p99, the worst), and how many came a whole frame late | a game's frame loop, the compositor and audio live on this; a scheduler is judged by it under load, not on throughput alone |
| `build` | `make -j N` of fdash (gcc, a real C program), wall seconds, joules of the CPU package (root), and `zjitter` at 144 Hz beside it: the desktop's frames while every core compiles | the developer's own workload, and whether the desktop stays smooth through it (ztune's SCHED_BATCH, the scheduler, the power limit) |
| `game` | a MangoHud CSV log (`MANGOHUD_CONFIG=output_folder=DIR`, F2 in the game starts and stops it): average fps, the 1 % low, p50 and p99 frame times, the worst frame | the player's experience: the 1 % low and p99 are what stutter is |
| `battery` | the battery's watts every 5 s for N minutes, the median and p95, the brightness, the hours left at that rate | the only number that matters on battery |

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
