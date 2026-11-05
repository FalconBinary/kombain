# zcool

Keeps every chip under the temperature you set, and gives up as little speed as it
can. Pure Zig with no libc: a 90 KiB binary that uses 156 KiB of memory.

**It has not run on real hardware yet.** Everything below was checked against a
thermal simulator. Start with `--dry-run`, which writes nothing.

## What it can and cannot promise

Heat has to go somewhere. If a cooler can carry 180 W and the chip draws 280 W, no
software keeps it at your limit at full speed. So the order is:

1. **Forecast.** It reacts to where the temperature is heading, not where it is.
2. **Fans first.** They rise before the limit and reach full speed at it. Speed is not touched.
3. **Then a little power,** only when the fans have nothing left, and only as much as needed.
4. **Give it back** as soon as there is room.

Below your limit it costs nothing. At your limit it costs what the cooler lacks. In
the simulator that beat leaving it to the hardware throttle, which slams power down:

| 320 W against a weak cooler | Peak | Speed | In PROCHOT |
|---|---|---|---|
| Hardware only | 100.3 C | 67% | 21 s of 40 s |
| zcool, limit 92 C | 90.0 C | 82% | never |

The chip's own protection (PROCHOT, thermal shutdown) stays in hardware. zcool cannot
turn it off, and it keeps working if zcool is gone.

## Use it

```sh
zcool list                # chips, limits, fans, what can be controlled
doas zcool run --dry-run  # says what it would do, writes nothing
doas vi /etc/zcool.conf   # your limits
doas ln -s /etc/sv/zcool /etc/runit/runsvdir/default/
```

For the gaming mode from the install guide, also link it into `runsvdir/gaming`.
Logs go to `/var/log/zcool/current`.

```ini
cpu0.max = 85
gpu0.max = 80
nvme0.max = 65
fan.exclude = nct6798/pwm3
```

Each chip gets its own limit. One you set above the chip's critical point minus 5 C
is lowered, with a message.

## What it controls

| Chip | Reads | Acts through |
|---|---|---|
| Intel CPU | `coretemp`, RAPL energy | fans, RAPL power limit, then frequency |
| AMD CPU | `k10temp`, `zenpower` | fans, then frequency; RAPL if the firmware honors it |
| AMD GPU | `amdgpu` | its own fan, `power1_cap` |
| NVMe | `nvme`, every 5 s | case fans only |
| Anything else in hwmon | watched | case fans, once you set a limit for it |

**Not covered:** NVIDIA's proprietary driver has no sensors in `/sys`, and `zcool list`
says so when it is loaded. Intel GPUs are watched, with no power control.

## Safety

- **Fans never go below what the firmware had set,** so a pump on a fan header keeps running.
- **Everything changed is journaled first,** in `/run/zcool/state`. A clean stop, a
  crash, a panic and `kill -9` all end in the originals: the last one through the
  runit `finish` script, or at the next start.
- **Lost sensors hand everything back.** The daemon exits and runit restarts it.
- **A chip is never pushed below 30% of its power.** Below that the hardware's own protection takes over.
- **A power limit is not trusted:** if the temperature stays over the limit anyway,
  frequency limits join in.
- **A sleeping GPU is not woken** to read its temperature.
- **Sandboxed:** after setup Landlock confines it to `/sys`, `/run/zcool` and `/var/lib/zcool`.

Other thermal daemons (`thermald`, `tlp`, `fancontrol`) would fight with it. Run one.

## Undervolting

Off unless you set it. **The BIOS is the better place:** Curve Optimizer on AMD, a
voltage offset on Intel. That survives updates, does not conflict with kernel
lockdown, and is the only way on AMD and on many recent Intel CPUs.

`undervolt.core` and `undervolt.cache` set Intel's MSR 0x150, and:

- It refuses with kernel lockdown on. The install guide turns lockdown on, so choose one.
- It refuses on AMD, below -125 mV, and on a CPU whose firmware locked this (the Plundervolt fix).
- It records the attempt on disk before the write. If the machine does not come back
  cleanly within 10 minutes, the next start skips the offset until `zcool undervolt reset`.
- **It does not search for a stable value on its own.** A wrong offset cannot burn a
  chip, but it can crash the machine and corrupt what was being written. Test your own
  value under load, in steps, with backups.

Writing to the register has only been tested against a model of it, never on a CPU.

## Checks

```sh
zig build test                                # the control logic against a model
zig build -Doptimize=ReleaseSafe
python3 tests/sim.py zig-out/bin/zcool        # the real binary against a fake /sys
```

The simulator covers overload, sudden load, recovery, crashes, `kill -9`, dead and
bogus sensors, stalled and excluded fans, power limits that are refused or ignored, a
sleeping GPU, and a config with mistakes. It proves the logic. It proves nothing
about any real driver, and a real chip's numbers will differ.

On arm64 with a fake `/sys`: 156 KiB of memory, 0.067% of a CPU while limiting. Real
sensors are slower to read than files, so expect more CPU time than that.
