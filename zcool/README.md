# zcool

Keeps every chip under the temperature you set, and gives up as little speed as it
can: the CPU, every GPU, NVMe. It learns how much power the cooler carries, and next time
goes straight there. On battery it can lower the limits, turn turbo off, make the CPU
prefer efficient clocks and the fans quiet. A GPU that shows nothing is let sleep when
idle. On MSI laptops it also drives the embedded controller: its fans at the speed the heat
needs, Cooler Boost past that, the battery charge limit, the EC's power profiles and its
silent fan curve while everything is cool.
Under work heavier than the machine can do, it keeps the desktop answering: jobs yield the
CPU to it, and a process about to starve memory is ended before the system stalls.
`zcool menu` shows every setting on one screen.
Pure Zig with no libc: a 269 KiB binary (x86_64) that uses under 200 KiB of memory. NVIDIA's own
driver needs one more, small program, see below.

It runs on an MSI GF63 Thin 10SC, whose logs found the burst and the slow trim described
below. Everything else was checked against a thermal simulator. Start with `--dry-run`,
which writes nothing.

## What it can and cannot promise

Heat has to go somewhere. If a cooler can carry 180 W and the chip draws 280 W, no
software keeps it at your limit at full speed. So the order is:

1. **Forecast.** It reacts to where the temperature is heading, not where it is, but at most
   8 C ahead of it: a CPU's die jumps 20 C within a second when work starts and levels off as
   soon, and following that slope further took power at 65 C on a real laptop.
2. **Fans first.** They rise before the limit and reach full speed at it; under a steady
   heat they settle it 2 C under the limit, no faster than it needs. Speed is not touched.
   A GPU's own fans go first; the case fans join once those are at full.
3. **Then a little power,** only when the fans have nothing left, and only as much as needed.
   Once zcool has learned what the cooler carries, the power goes straight there. Over the
   limit it takes more, as a die follows its power at once: back within seconds, not a minute.
4. **Give it back** as soon as there is room, and while the fans still have some. With every
   fan at full, all of it only 3 C under the limit: full power lets a CPU burst at once, and
   on the GF63 that took it from 68 C to 72 within a second.

In quiet mode 2 and 3 swap places for the first 15% of power: see below.

Below your limit it costs nothing. At your limit it costs what the cooler lacks. In
the simulator that beat leaving it to the hardware throttle, which slams power down:

| 320 W against a weak cooler | Peak | Speed | In PROCHOT |
|---|---|---|---|
| Hardware only | 100.3 C | 67% | 21 s of 40 s |
| zcool, limit 92 C | 91.7 C | 84% | never |

The chip's own protection (PROCHOT, thermal shutdown) stays in hardware. zcool cannot
turn it off, and it keeps working if zcool is gone.

## Use it

```sh
zcool list                # chips, limits, fans, GPUs and what keeps them awake
doas zcool run --dry-run  # says what it would do, writes nothing
doas zcool menu           # every setting, with what it does; s saves and restarts the service
doas ln -s /etc/sv/zcool /etc/runit/runsvdir/default/
```

For the gaming mode from the install guide, also link it into `runsvdir/gaming`.
Logs go to `/var/log/zcool/current`.

```ini
cpu0.max = 85
gpu0.max = 80
nvme0.max = 65
fan.exclude = nct6798/pwm3
battery.max = 80      # stop charging at 80%: the battery lives longer
mode.battery = eco    # an MSI EC's power profile on battery, see below
turbo.battery = no    # what follows the power source, see below
```

Each chip gets its own limit. One you set above the chip's critical point minus 5 C
is lowered, with a message.

## How the fans run

The fans start 8 C under the limit and reach full speed at it, rising with the forecast, so
a heat that is still climbing finds them already turning. Once the heat holds steady they
find the speed it needs: a little less while the chip stays well under the fan point, 2 C
under the limit, a little more while it stays over. So it settles at the fan point instead
of wherever the band happens to balance it lower down: the same heat for less fan, 9% less
in the model at 90 W. Within a degree of the fan point nothing changes, as fans that chase
every tenth of a degree are heard doing it. New work that climbs gets the band back at once,
and the last degree and a half before the limit gets every fan. Fans go up at once and down
slowly, so they do not pump.

## It learns the cooler

While it holds a chip at its limit with the fans at full or close to it, zcool learns how
much power the cooler carries there: the power it settles at, moved to the limit itself.
That goes to `/var/lib/zcool/learned` and `zcool list` shows it. The next time the heat
builds up and the fans have given all, the power limit goes straight there instead of
feeling its way down from full power: in the simulator the first limit after learning was
168 W against 275 W cold, for a cooler that carries 181 W. It keeps learning, so dust, a
warm room or a new paste move it. A limit moved by the power source scales what it learned
as the cooler would carry it. `learn = no` turns it off.

## What follows the power source

Each of these takes `.ac` or `.battery` after its name. Left out, the firmware's own stays,
and zcool puts back what it changed when it stops, like everything else.

| Setting | Values | What it does |
|---|---|---|
| `epp` | `performance`, `balance_performance`, `balance_power`, `power`, `default` | The CPU's energy preference (intel_pstate, amd-pstate): how readily it climbs to high clocks. On battery `balance_power` or `power` saves a lot for a little speed. |
| `turbo` | `yes`, `no` | Clocks above the base clock. Off on battery: a cool, quiet laptop that lasts much longer, and a slower one. |
| `noise` | `normal`, `quiet` | Quiet: a chip first gives up to 15% of its power before its fans go past the firmware's curve or Cooler Boost comes on. If that is not enough the fans join, and stay until the heat is gone for 30 s, so they do not come and go. |
| `limits` | `0` to `-30` | Every chip's limit moves by this: `limits.battery = -10` keeps a laptop on battery 10 C cooler. |
| `mode` | `eco`, `comfort`, `sport`, `turbo` | An MSI EC's own power profile, see below. |

```ini
epp.ac = balance_performance
epp.battery = balance_power
turbo.battery = no
noise.battery = quiet
limits.battery = -10
```

`zcool menu` has three presets for all of these at once: quiet, balanced and fast.

## The CPU's power limits, and its own throttle

An Intel package has two power limits: a long-term one (PL1), which is an average over a
window of about 28 s, and a short-term one (PL2) it may burst to until that average reaches
PL1. Lowering PL1 alone does nothing for those 28 s: on the GF63 the temperature went on
rising and frequency limits had to step in every time. So zcool lowers PL2 with it and the
power drops at once; both go back together. If a package still draws well above its limit,
frequency limits hold it from then on, alone, since two levers that act at different speeds
swing a chip between full power and cut.

A laptop CPU's die can climb 7 C in a quarter of a second, faster than any program reads it.
The CPU's own thermal throttle (TCC) acts in microseconds, at TjMax (usually 100 C) unless
told otherwise: zcool moves it to 3 C above the limit, through MSR 0x1a2, before its sandbox
closes, journaled and put back when it stops, `kill -9` included. It only throttles earlier,
which cannot harm a chip; firmware that ignores the offset is noticed and left alone, and
`zcool list` shows where it acts. Intel only, the `msr` module (the service loads it) and no
kernel lockdown; `tcc = no` leaves it at TjMax. Unlike undervolting, firmware rarely locks it.

## Under heavy work

Heat is one way a machine stops answering; a CPU that every job wants at once, and memory
that runs out, are the others. zcool reads the kernel's pressure figures (`/proc/pressure`)
once a second, on wakeups it has anyway, and looks at the processes only while there is
pressure.

- **The CPU.** When tasks waited for it 40% of the last 10 s, the jobs that kept at least half
  a core busy since the last look yield it: nice 10 and the lowest I/O priority, for their whole
  process group, so `make -j16` and every compiler it starts later. The compositor, Xwayland,
  gamescope, the panel and the sound server get nice -5. A program drawing on the GPU, a game,
  keeps its share; one the user set a nice for is left as it is. All of it goes back when zcool stops.
- **Memory.** When 4% of it is left and swap is full or absent, or the kernel stalls every task
  on memory while 10% is left, the process with the highest OOM score is asked to end, and
  killed 3 s later if it has not. Never the session: mango, the panel, the terminal, the shell,
  sound, login, sshd, runit. The kernel's own OOM killer comes only after minutes of a frozen
  machine.

`guard.cpu = no` and `guard.memory = no` turn either off.

## What it controls

| Chip | Reads | Acts through |
|---|---|---|
| Intel CPU | `coretemp`, RAPL energy | fans, RAPL power limits (long- and short-term), then frequency; its own throttle (TCC) just above the limit |
| AMD CPU | `k10temp`, `zenpower` | fans, then frequency; RAPL if the firmware honors it |
| AMD GPU | `amdgpu` | its own fan, then case fans, `power1_cap` |
| Intel discrete GPU | `xe`, `i915` | case fans, `power1_max` |
| Intel integrated GPU | in the CPU package | the CPU's package power limit |
| NVIDIA GPU, NVIDIA's driver | `zcool-nvidia` | its own fans, then case fans, its power limit, or a clock limit where it takes none |
| NVIDIA GPU, nouveau | `nouveau` | its own fan if the driver offers one; no power control |
| NVMe | `nvme`, every 5 s | case fans only |
| MSI laptop | its EC, through `ec_sys` | Cooler Boost as the board's fan; the GPU temperature where NVIDIA's library reads none |
| Anything else in hwmon | watched | case fans, once you set a limit for it |

In a laptop the fans belong to the board, so they cool the CPU and the GPU together and
answer to whichever is hotter.

### NVIDIA's driver

It puts no sensors in `/sys`. Its library, `libnvidia-ml.so.1`, is the usual way to read
such a GPU or set its limits, and loading it needs libc. So that part lives in
`zcool-nvidia`, which zcool starts only when that driver is loaded, before its own sandbox
closes, and talks to over a pipe, one line per request. It opens the library without
touching any GPU, reaches a GPU only when zcool asks, and zcool does not ask while the GPU
sleeps. It sandboxes itself too. A desktop card usually takes a power limit; most laptop
GPUs take none, and get a clock limit instead. Measured against a stand-in for the library
it uses 1.7 MiB; NVIDIA's real library is larger.

The library is opened without attaching any GPU, so as not to wake one. If it then reads
nothing from a GPU, zcool-nvidia attaches and asks again, and keeps attaching. If it still
reads nothing, the log and `zcool list` show what the library answered, with its error
number, and on an MSI laptop the EC's GPU temperature stands in: the fans then work for the
GPU, though it gets no clock limit.

## Sleep

A GPU that does not show the boot screen, a laptop's discrete GPU for one, can be powered
off by the kernel while nothing uses it. zcool sets that up (`power/control` to `auto`) for
every such GPU and puts the old value back when it stops; `gpu.sleep = no` turns that off.

Every read of a sensor keeps a GPU awake, so an idle one is read less and less often, up
to once in 10 s, and NVIDIA's library is let go of between reads. Asleep, it is not read
at all. When it wakes, for a game say, it is read at once and every second while busy.

What can still keep it awake, `zcool list` shows: the processes that hold it open, and on
NVIDIA's driver whether that driver allows it. Turing cards (GTX 16xx, RTX 20xx) sleep only
with `options nvidia NVreg_DynamicPowerManagement=0x02` in `/etc/modprobe.d`, and on boards
that support it.

## MSI laptops: the embedded controller

On many MSI laptops Linux cannot turn the fans: they belong to the EC, and the kernel's
`msi-ec` knows only some firmware. zcool talks to the EC itself, through the kernel's
`ec_sys`, which goes through the kernel's own EC driver, so the two never race. What it does:

- **The fans at any speed.** MSI's "advanced" fan mode runs each fan by a curve held in the
  EC. When the heat needs more than the firmware's curve gives, zcool writes a curve of its
  own: one speed, the one it wants, up to 8 C over the highest limit, and every fan at full
  from there. So the EC goes on answering the heat by itself if zcool ever stops answering.
  It starts from the speed the firmware ran, never below it, and changes only the speed byte
  while it runs, by 2% or more. The EC drops back to its own curve when the charger comes or
  goes: zcool notices and writes its own again. Once the heat is gone the EC's curve and mode
  go back as they were. A fan set past half that does not turn is reported. Addresses from
  [isw](https://github.com/YoyPa/isw), the same for every MSI laptop of this kind.
- **Cooler Boost past full.** Once zcool's curve is at full, Cooler Boost; off again only
  once the fans have come well down, so it does not switch back and forth. With Cooler Boost
  on, the fans count as at full whatever the curve says, so power is not given back while
  they have nothing left: on the GF63 it was, and the chip went over its limit. With Cooler
  Boost alone the same holds once it has been on 2 s, time for the fans to spin up. A boost
  you turned on with the key stays on. `fan.curve = no` leaves only Cooler Boost: the firmware's
  curve, or both fans at full.
- **The GPU's temperature,** when NVIDIA's library reads none.
- **`battery.max`:** a charge limit, from 10 to 100%. Unlike everything else it stays when
  zcool stops, so that it holds while the laptop is off and plugged in; `battery.max = 100`
  takes it away. Where the kernel has its own setting (`charge_control_end_threshold`:
  ThinkPads, ASUS, Dell and others), that is used instead, on any laptop.
- **The silent fan curve.** The firmware has a quieter fan curve of its own. zcool takes it while
  every chip has been 25 C below its limit for 20 s, and gives the normal curve back as soon as
  one comes within 18 C, before Cooler Boost and before any power. The firmware keeps its own
  protection on either curve. A curve chosen in MSI's tools (advanced) is left alone, zcool
  keeps to Cooler Boost then, and `fan.silent = no` keeps the normal one.
- **`mode.ac` and `mode.battery`:** the EC's own power profiles, `eco`, `comfort`, `sport`
  or `turbo`, switched when the power source changes. Left out, the firmware's own stays;
  with one of the two set, the other source gets the firmware's own back.

It needs debugfs (the kernel must not be booted with `debugfs=off`) and `ec_sys` loaded with
`write_support=1`. The runit service mounts debugfs and loads `ec_sys` that way on an MSI
machine. `zcool list` shows the EC, what it reads, and why zcool does or does not use it.

Only firmware whose addresses the [msi-ec](https://github.com/BeardOverflow/msi-ec) project
lists is touched: today the GF63 Thin 8RC, 9SC, 10SC, 10U and GF65 Thin 9S, 10S, 10U
(firmware 16R1, 16R3, 16R4, 16R5, 16W1, 16W2). Any other EC is only named in `zcool list`
and left alone, and so is one without write support. Of the byte that holds Cooler Boost
only its bit is changed; the rest belongs to the firmware. `ec = no` keeps zcool away from
the EC, `fan.exclude = ec/fans` from its fans (Cooler Boost alone is used then), and
`fan.exclude = ec/cooler_boost` from Cooler Boost too.

## Safety

- **Fans never go below what the firmware had set,** so a pump on a fan header keeps running.
- **Everything changed is journaled first,** in `/run/zcool/state`. A clean stop, a
  crash, a panic and `kill -9` all end in the originals: the last one through the
  runit `finish` script, or at the next start.
- **Lost sensors hand everything back.** The daemon exits and runit restarts it.
- **The EC goes back too:** its fan mode, both fan curves, Cooler Boost and the power profile
  are journaled like the rest.
  The charge limit is the one setting that stays, see above.
- **NVIDIA's settings go back however zcool ends.** When zcool goes, `zcool-nvidia`'s input
  ends and it gives back every limit and fan it set. If both are killed, the GPUs it changed
  are listed in `/run/zcool/nvidia`, and `zcool restore` (the runit `finish` script) puts them back.
- **A chip is never pushed below 30% of its power.** Below that the hardware's own protection takes over.
- **A power limit is not trusted:** if the package draws well above it while the temperature
  stays over the limit, the power limits go back and frequency limits hold the chip instead.
- **A sleeping GPU is not woken** to read its temperature or to give anything back.
- **Sandboxed:** after setup Landlock confines it to `/sys` (the EC's file included), `/run/zcool` and `/var/lib/zcool`.
  `zcool-nvidia` is confined to reading the system, the NVIDIA device files and `/run/zcool`.

Other thermal daemons (`thermald`, `tlp`, `fancontrol`) would fight with it. Run one.

## Undervolting

Off unless you set it. **The BIOS is the better place:** Curve Optimizer on AMD, a
voltage offset on Intel. That survives updates, does not conflict with kernel
lockdown, and is the only way on AMD and on many recent Intel CPUs.

Many laptops cannot undervolt at all: since the Plundervolt fix (2019-2020) firmware often
locks the register, the MSI GF63 Thin 10SC among them. There the same thing, less heat for
the same work, comes from the power source settings above: `epp` and `turbo` on battery,
and a learned power limit under long loads.

`undervolt.core` and `undervolt.cache` set Intel's MSR 0x150, and:

- It refuses with kernel lockdown on. The install guide turns lockdown on, so choose one.
- It refuses on AMD, below -125 mV, and on a CPU whose firmware locked this (the Plundervolt fix).
- It records the attempt on disk before the write. If the machine does not come back
  cleanly within 10 minutes, the next start skips the offset until `zcool undervolt reset`.
- **It does not search for a stable value on its own.** A wrong offset cannot burn a
  chip, but it can crash the machine and corrupt what was being written. Test your own
  value under load, in steps, with backups.

Writing to the register has only been tested against a model of it, never on a CPU.
`zcool undervolt probe` tells whether firmware lets offsets through. It moves the core
offset by 1 mV, reads it back, and puts back what was there.

## Checks

```sh
zig build test                                # the control logic against a model
zig build -Doptimize=ReleaseSafe
zig build fake-nvml                           # a stand-in for NVIDIA's library
python3 tests/sim.py zig-out/bin/zcool        # the real binaries against a fake /sys
```

The simulator covers overload, sudden load, recovery, crashes, `kill -9`, dead and
bogus sensors, stalled and excluded fans, a fan that misses a read, power limits that are refused or ignored, a
sleeping GPU, and a config with mistakes. For GPUs: a laptop's NVIDIA GPU on the shared
fan and a clock limit, a desktop one with its own fan, the case fan and its power limit,
an Intel GPU's power1_max, an idle GPU read rarely enough to sleep, one asleep never
reached, and NVIDIA's settings given back after `kill -9` of zcool and of both. A NVIDIA
library that reads only an attached GPU, and one that reads nothing, read through the EC.
For an MSI EC: its fans held part way through zcool's curve for a heat that needs part of
them, then at full, then Cooler Boost, then power, and the EC's own curve and mode back after
the heat, SIGTERM and `kill -9`; the EC dropping zcool's curve and getting it back; a fan
that stands still reported. Cooler Boost alone before any power is taken and off after the heat, the
firmware's bits left as they were, everything back after SIGTERM and `kill -9`, a boost
turned on by hand left on, the charge limit (and the kernel's own where there is one), the
profile following the power source, and an unknown or read-only EC never written. The
energy preference, turbo and limits following the power source and coming back after
`kill -9`; quiet mode taking power before Cooler Boost, and no boost at all where a little
power is enough; the cooler learned, kept on disk and used on the next run; and the menu,
driven through a terminal, saving what it changed and restarting the service. The silent fan
curve while cool and the normal one back before Cooler Boost; a package that bursts to its
short-term limit for the long one's 28 s window, held by power alone once both go down, and
held without swinging where only the long one exists; a die that follows its power at once
at a 70 C limit with every fan at full, held without going over and without power coming
back near the limit, by Cooler Boost alone and by zcool's curve; the TCC offset set, put back after
SIGTERM and `kill -9`, and left alone on AMD, under lockdown or with `tcc = no`; a job yielding under CPU pressure
while a game and the desktop keep theirs; a memory hog ended and the session spared. It proves
the logic. It proves nothing about any real driver or NVIDIA's real library, and a real
chip's numbers will differ.

On arm64 with a fake `/sys`: 188 KiB of memory. Real sensors are slower to read than
files, so expect more CPU time than the simulator shows.
