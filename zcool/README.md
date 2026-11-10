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
Pure Zig with no libc: a 299 KiB binary (x86_64) with 360 KiB of resident memory. NVIDIA's own
driver needs one more program of 136 KiB, see below.

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
   fan at full, all of it only once the chip has stayed 3 C under the limit for 5 s: full
   power lets a CPU burst at once, and on the GF63 that took it from 68 C to 72 within a
   second. Its die reads cool right after a deep cut while the work goes on, so a moment
   there is not enough.
5. **Then the fans come down,** once power is all back: while it is cut they stay at full.

In quiet mode 2 and 3 swap places for the first 15% of power, or what calibration found
costs at most 5% of the speed: see below.

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
doas zcool calibrate      # once, plugged in: a few minutes of load that teach it the machine
doas zcool dump           # the CPU's registers, clocks, limits, GPUs, EC and sensors, read only
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
slowly, so they do not pump. After `zcool calibrate` they go straight to the speed a steady
heat needs, from what each speed was measured to carry.

## It learns the cooler

While it holds a chip at its limit with the fans at full or close to it, zcool learns how
much power the cooler carries there: the power it settles at, moved to the limit itself.
That goes to `/var/lib/zcool/learned` and `zcool list` shows it. The next time the heat
builds up and the fans have given all, the power limit goes straight there instead of
feeling its way down from full power: in the simulator the first limit after learning was
168 W against 275 W cold, for a cooler that carries 181 W. It keeps learning, so dust, a
warm room or a new paste move it. A limit moved by the power source scales what it learned
as the cooler would carry it. `learn = no` turns it off.

## Calibration

`doas zcool calibrate`, once, plugged in, in 3 to 8 minutes: zcool loads the CPU itself and
measures what it otherwise finds out while the heat comes. It starts cold: every fan at full and
no load until the die is 20 C under its limit, up to ten minutes, since the first phase holds the
die at the limit and on a sink still warm from the last load that measures power cut, not the
CPU's speed (a run right after another on the GF63 read 2500 MHz on six CPUs at 13 W, against
3647 MHz at 33 W from cold).

Set the limit first (`cpu0.max` in `/etc/zcool.conf`; left out, a CPU's is 10 C under its
critical point, 90 C on most Intel laptops): everything below is measured at the limit, and a
changed limit wants a new calibration. A fresh conf after a reinstall put the GF63's second
calibration at 90 C where its first had been at 70.

- **How fast it runs** on one CPU, on half of them and on all, held at its limit: the clocks of
  the CPUs it loads, not of the idle ones.
- **How fast it runs at each power,** from 30% of the firmware's long-term limit (PL1) to all
  of it, every CPU loaded and every fan at full, until the cooler no longer holds the limit.
  Usually the last third of the power buys a few percent of speed: on the GF63 31 W ran at
  3.3 GHz and 26 W at 3.2. Quiet mode then gives up the power that costs at most 5% of the
  speed before the fans get louder, instead of a fixed 15%.
- **What each fan speed carries at the limit:** Cooler Boost, 100%, 80% and 60%, the CPU held
  at its limit at each until it settles. With that the fans go straight to the speed a steady
  heat needs instead of finding it over minutes, and the power limit starts where the cooler
  holds it (it seeds what is learned above).
- **Which fans turn, and whether they follow zcool's curve.** A GF63 Thin has one fan, though
  its EC keeps two curves. If 60% turns them as fast as 100%, the EC ignores the curve, and
  zcool keeps to Cooler Boost from then on.

On the GF63 at 70 C the fan carried 25.7 W at 60% (3621 rpm), 29.0 W at full (5901) and
29.6 W with Cooler Boost (7029): nearly twice the speed, far louder, for an eighth more heat,
and Cooler Boost 2% over full speed, so zcool keeps it for a chip over its limit. Where the firmware bursts far past
what the cooler carries, calibration says so, and suggests a `burst` of twice that.

The service stops while it runs and starts again after. Ctrl-C, or any chip 4 C over its limit,
stops it: nothing is kept and everything is put back. It goes to `/var/lib/zcool/calibration`;
`zcool list` shows it. Calibrate again after cleaning the fans or a new paste.

## A model of the machine's heat

`doas zcool calibrate --long`, plugged in, as long as it takes (up to an hour on a laptop, after
the short calibration's own minutes): zcool measures four things and keeps them in
`/var/lib/zcool/model`:

- how far the die sits above its heat sink per watt: 45 s at a low power, then a step to 90%
  of what the cooler carries, every fan at full, three times; a line through the readings of
  seconds 2 to 7 after each step, where the die's own jump is over and the sink's climb still
  nearly straight, taken back to the step, against the power measured before and after it;
- the sink's own time, from the climb after the last step, which stays at 80% of what the
  cooler carries until it settles: how long the die takes, from 2.5 s in, to cover 63% of the
  way to where it settles. A climb that goes over the limit, sits at it or never settles tells
  nothing, and the steady states below are held 90 s to five minutes;
- what the cooler carries per degree over the room at each fan speed, from the steady state of
  each speed at two powers under what it carries, each held for four of the sink's times (90 s
  at least, ten of them at most) and until the mean of the last 45 s agrees with the mean of the
  45 s before within 0.3 C; the sink's thermal mass comes from how long each settling took. A
  state whose die goes over the limit after its first 15 s, or settles within a degree of it, is
  the CPU's own throttle holding it, not the cooler, and is left out;
- the room's temperature, read with the load off and every fan at full, held as long as a steady
  state; when it comes out warmer than the room the lines through the steady states meet at, the
  sink was still warm, and the lines win.

The fit is kept only when it holds together: a faster fan carries more per degree than a slower
one, and what the model says the fans at full hold at the limit is within 15% of what the short
calibration measured them holding minutes before. Otherwise zcool says which it was, prints the
fit for the record, and keeps nothing: run it again from cold, with nothing else running. The
first long calibration on the GF63 taught all of this: a reading that stood still for ten seconds
had passed for a steady state while the sink, which takes minutes, still climbed (coretemp counts
whole degrees, so a die can sit on one for half a minute), and the fit had the cooler carrying
more at 80% than at full, the room at 38 C off a sink still warm, and the fans at full holding
24 W where they had just carried 30. The second, at 90 C, taught the rest: the kernel hands out
a coretemp reading for a second, so a jump read two ticks after the step came out -18, 0 and 9 C
over the same 30 W; the climb to 95% of a carry measured minutes before, on a sink still warming,
reached the limit, and its "7 s", counted from a reading still from before the jump, had every
steady state held a minute; and three states begun at the limit, the die still coming down from
the phase before, were thrown out as over it before their power had done anything.

With the model zcool knows where the temperature goes, instead of extrapolating where it was
going. It follows the sink's temperature by the model's own account, corrected by the reading:
the die's reading jumps the moment power does, while the power reading is an average over the
last half second, so taken at face value the two would put the sink ten degrees off at every
step. The forecast that moves the fans is the model's, two seconds ahead, the time a fan takes
to spin up: it knows a load's curve bends toward where that power settles. And the CPU's
short-term power limit follows the sink: a burst from a cold machine runs at the firmware's full
limit, because the die has 30 C to spend before the limit, while the same burst from a warm sink
is held to what the sink can absorb in the next three seconds, a degree under the limit. So a
short load is told apart from a long one by where the temperature will be, not by guessing how
long it lasts: a burst of a few seconds from rest costs nothing, a sustained load is met at the
power the cooler holds. `burst.ac` stays the ceiling.

The model keeps learning as zcool runs. A power step of 25 W or more shows on the die within a
tick, or up to a second later and in two pieces where the kernel hands out a reading for a second
(coretemp); its jump, less half a tick of the sink's climb, against the power a second and a
half before it showed and the power a second and a quarter after, teaches the die's offset. Every 15 s of the die holding
level at one fan speed teaches what the cooler carries there, from the power averaged over that
time (it may hunt meanwhile); the other speeds move by the same factor, since dust slows one
cooler at every speed alike, so a cooler that dust has slowed is learned down at every speed.
What moved goes to disk once a minute. In the simulator a model that started wrong by half found
the die's offset and the cooler within a few bursts and one long load. `zcool list` shows the
model, what the cooler holds at the limit, and the burst it would allow this moment.

## What follows the power source

Each of these takes `.ac` or `.battery` after its name. Left out, the firmware's own stays,
and zcool puts back what it changed when it stops, like everything else.

| Setting | Values | What it does |
|---|---|---|
| `epp` | `performance`, `balance_performance`, `balance_power`, `power`, `default` | The CPU's energy preference (intel_pstate, amd-pstate): how readily it climbs to high clocks. On battery `balance_power` or `power` saves a lot for a little speed. |
| `turbo` | `yes`, `no` | Clocks above the base clock. Off on battery: a cool, quiet laptop that lasts much longer, and a slower one. |
| `noise` | `normal`, `quiet` | Quiet: a chip first gives up to 15% of its power, or what calibration found costs at most 5% of the speed, before its fans go past the firmware's curve or Cooler Boost comes on. If that is not enough the fans join, and stay until the heat is gone for 30 s, so they do not come and go. |
| `limits` | `0` to `-30` | Every chip's limit moves by this: `limits.battery = -10` keeps a laptop on battery 10 C cooler. |
| `mode` | `eco`, `comfort`, `sport`, `turbo` | An MSI EC's own power profile, see below. |
| `burst` | `10` to `500` | Watts the CPU may burst to: its short-term power limit (PL2), never above the firmware's. A thin laptop's firmware often allows far more than its cooler carries: the GF63's 107 W against 32, so every burst from idle shoots its die past the limit. Power taken for the heat stays under it as well. `zcool calibrate` suggests twice what the cooler carries. |

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
swing a chip between full power and cut. Only the CPU's packages are taken: psys, the
whole platform's limit next to it on many laptops, would hold the GPU and all with it.

A laptop CPU's die can climb 7 C in a quarter of a second, faster than any program reads it.
The CPU's own thermal throttle (TCC) acts in microseconds, at TjMax (usually 100 C) unless
told otherwise: zcool moves it to 3 C above the limit, through MSR 0x1a2, before its sandbox
closes, journaled and put back when it stops, `kill -9` included. It only throttles earlier,
which cannot harm a chip; firmware that ignores the offset is noticed and left alone, and
`zcool list` shows where it acts. Intel only, the `msr` module (the service loads it) and no
kernel lockdown; `tcc = no` leaves it at TjMax. Unlike undervolting, firmware rarely locks it.

## A hard ceiling

`cpu0.max = 70` is a limit zcool holds with as little speed lost as it can: fans first, then
power, and the CPU's own throttle 3 C above it for what comes too fast for a program. `ceiling =
hard` makes the same number a ceiling the die must not cross:

- the CPU's own throttle (TCC) sits at the limit itself, in hardware, in microseconds;
- zcool works a degree under it, so that the hardware only ever catches spikes;
- no burst goes above the firmware's long-term power limit until a model of the heat
  (`zcool calibrate --long`) says what the sink can take at this moment; with the model, bursts
  follow it, as always.

What it costs: a cooler carries less at a lower temperature (on the GF63 about 22 W at 60 C
against 30 at 70), so long loads run slower; what a ceiling buys and costs is in `kombain-bench`
rows, not here. What it cannot do: a die that jumps 0.2 C per watt within a millisecond and a
sensor that counts whole degrees leave the last degree to the hardware, which is why the TCC is
there; a GPU has no throttle to move, so its ceiling is held by fans and clocks as before.

`limits.gaming = 10` moves every limit while runit's current runlevel is the one named, as the
install guide's Gaming is: 10 C hotter for its frames, or `-10` cooler. zcool reads the link
`/run/runit/runsvdir/current` every two seconds, and `zcool list` says which runlevel it sees.

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
  Boost alone the same holds once it has been on 2 s, time for the fans to spin up. Where
  calibration found it carries less than 5% more than full speed, it comes only for a chip
  over its limit and goes once that chip is back under it: on the GF63 it carried 2% more,
  at 7029 rpm against 5901. A boost you turned on with the key stays on. `fan.curve = no` leaves only Cooler Boost: the firmware's
  curve, or both fans at full.
- **The GPU's temperature,** when NVIDIA's library reads none.
- **`battery.max`:** a charge limit, from 10 to 100%. Unlike everything else it stays when
  zcool stops, so that it holds while the laptop is off and plugged in; `battery.max = 100`
  takes it away. Where the kernel has its own setting (`charge_control_end_threshold`:
  ThinkPads, ASUS, Dell and others), that is used instead, on any laptop.
- **The silent fan curve.** The firmware has a quieter fan curve of its own. zcool takes it while
  every chip has been 25 C below its limit for 20 s, and gives the normal curve back once one
  has stayed within 18 C for 3 s, or at once within 10 C, before Cooler Boost and before any
  power: a desktop's short bursts lift a die that far for a second, and on the GF63 they
  swapped the curves every half minute while it sat idle. The firmware keeps its own
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
locks the register, the MSI GF63 Thin 10SC among them. `zcool dump` shows the lock: the
overclocking lock bit of MSR 0x194. Firmware sets it at every boot before Linux starts, and
only a reboot clears it, so no program can get past it. Changing the hidden BIOS setting
behind it in NVRAM (setup_var and the like) is no flash, but a wrong byte can leave a laptop
that does not boot; zcool does not do it. There the same thing, less heat for the same work,
comes from the power source settings above: `epp` and `turbo` on battery, a learned power
limit under long loads, and the power quiet mode gives up once calibration knows what it
costs.

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

`zcool undervolt find` searches for the deepest offset this CPU holds, the only way it can be
searched for: by trying, with the machine itself as the judge. From -50 mV down to -125 in
steps of 10, core and cache together, each step held for seven minutes: five of work with a
known answer on every core with the die held at its limit, then two of three-second bursts on
one core out of idle, where the single-core turbo and the idle states live and a lowered
voltage fails first. Three things end a step: a worker whose answer differs from the one
computed at the CPU's own voltage (a wrong result comes before a crash does), a machine check
in the kernel's log, and the machine going down, which the next start reads from the step left
on disk before its offset was written. The result is two steps above the first offset that
failed, 10 to 20 mV of margin to the edge it found, or one step above the deepest step when
nothing failed. `zcool list` shows it with the date. It is never applied by itself: put it in
the BIOS, or in `undervolt.core` and `undervolt.cache`. About an hour; keep nothing important
open meanwhile, since a hang is one of the answers. `--seconds N` is a step's length, `--from`
and `--to` the ladder's ends, the same value for both to check one offset. What held for seven
minutes a step is a bound, not a proof: the margin is for that, and a search again after a BIOS
update, or a year on, costs an hour.

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
The long calibration fitting the simulator's own chip (its die offset, the room, the sink's mass
and the cooler at three speeds) from its step responses; a cold burst running at the firmware's
full short-term limit with no power taken and a warm one held under what the sink can absorb;
a model that started wrong learning the die's offset and the cooler as zcool runs; seven load
patterns (bursts of 2, 5 and 15 s, pulses, a ramp, a sustained load, two loads with a rest) all
under the limit, the short ones without a watt taken. Cooler Boost only for a chip over its
limit where calibration found it adds 2%, and as always where it adds 17%. A burst limit held on mains and on battery, under a cut as well, and given back; psys never
taken for the CPU's. Calibration on a GF63-like laptop with one fan: the fans' carry at each speed, the speed at
each power and core count, the service stopped and started again, what was learned seeded, and
everything back after it and after Ctrl-C; refused on battery; a calibration whose fans
ignored the curve keeping zcool to Cooler Boost, and its quiet floor. `zcool dump` decoding
the registers and showing the EC.
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

What it costs at rest, against a fake `/sys` on arm64, 60 s: one wakeup a second, less than
0.1 ms of CPU a second, 360 KiB resident. It reads four times a second while a fan is held or
a chip is within 8 C of its limit, twice while one is within 20 C, once a second further away;
a sudden 300 W load from rest in the simulator peaks at 86.6 C for an 85 C limit, against 86.2
when it read twice a second at rest, and the CPU's own throttle and the burst limit stand
behind that second. Real sensors are slower to read than files, so expect more CPU time than
the simulator shows.
