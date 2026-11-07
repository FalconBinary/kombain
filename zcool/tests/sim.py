#!/usr/bin/env python3
"""Runs the real zcool binary against a fake /sys with a thermal model of the chips.

The model answers what real hardware would: temperature follows power and fan speed,
firmware runs its own fan curve in auto mode, PROCHOT cuts power hard at 100 C. It proves
the control logic and the safety paths. It proves nothing about any real driver.
"""
import concurrent.futures
import os
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time

ZCOOL = os.path.abspath(sys.argv[1])
ONLY = sys.argv[2] if len(sys.argv) > 2 else None
# `zig build fake-nvml` puts the stand-in for NVIDIA's library next to zig-out/bin
FAKE_LIB = os.path.abspath(os.path.join(os.path.dirname(ZCOOL), "..", "fake-nvml"))


def put(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(f"{value}\n")


def get(path):
    with open(path) as f:
        return f.read().strip()


class Chip:
    """One chip with a heat load, a thermal mass and a conductance that depends on its fan,
    and for a GPU in a case a little on the case fan too."""

    def __init__(self, load=0, g_min=0.8, g_max=4.0, mass=25, temp=40, ambient=30, g_case=0.0):
        self.load, self.g_min, self.g_max, self.mass, self.g_case = load, g_min, g_max, mass, g_case
        self.temp, self.ambient = temp, ambient
        self.work = 0.0
        self.time = 0.0
        self.peak = temp
        self.prochot = False
        self.prochot_time = 0.0
        self.over = 0.0
        self.power = 0.0

    def step(self, dt, allowed_power, speed, duty, limit, case_duty=0):
        if self.temp >= 100:
            self.prochot = True
        elif self.temp < 95:
            self.prochot = False
        power = min(self.load, allowed_power)
        perf = speed * (power / self.load) ** 0.4 if self.load > 0 else 1
        if self.prochot:
            power *= 0.16
            perf *= 0.4
            self.prochot_time += dt
        g = self.g_min + (self.g_max - self.g_min) * duty / 255 + self.g_case * case_duty / 255
        self.power = power * speed ** 2.5
        self.temp += (self.power - (self.temp - self.ambient) * g) * dt / self.mass
        self.work += perf * dt
        self.time += dt
        self.peak = max(self.peak, self.temp)
        if limit and self.temp > limit:
            self.over += dt

    @property
    def perf(self):
        return self.work / self.time if self.time else 1


class Nvidia:
    """A GPU on NVIDIA's own driver, as the fake library shows it to zcool-nvidia. With no fans
    of its own it is a laptop's, cooled by the board fan with the CPU. `limit` is the driver's
    power limit range, (min, max, default) in mW, or None where it takes none."""

    def __init__(self, chip, fans=0, limit=None, clocks=True, boot=False, control="on", status="active",
                 d3="Enabled (fine-grained)", util=None, slowdown=98, gpumax=87, maxclock=1600):
        self.chip, self.fans, self.limit, self.clocks, self.boot = chip, fans, limit, clocks, boot
        self.control, self.status, self.d3, self.util = control, status, d3, util
        self.slowdown, self.gpumax, self.maxclock = slowdown, gpumax, maxclock
        self.bus = "0000:01:00.0"


class Ec:
    """An MSI laptop's embedded controller as ec_sys shows it: 256 bytes with the firmware version
    at 0xa0. Cooler Boost (0x98, bit 7) runs both fans at full; off, the firmware's curve runs them.
    The other bits of 0x98 are the firmware's own and must survive."""

    BOOST, PROFILE, CHARGE, CPU_TEMP, GPU_TEMP = 0x98, 0xf2, 0xef, 0x68, 0x80

    def __init__(self, firmware="16R5EMS1.102", writable=True, boost=0x05, profile=0xc1, charge=0x80, mains=True):
        self.firmware, self.writable, self.mains = firmware, writable, mains
        self.initial = {self.BOOST: boost, self.PROFILE: profile, self.CHARGE: charge}


class Machine:
    def __init__(self, cpu=None, gpu=None, rapl=True, rapl_enforced=True, rapl_writable=True, freq=True, cpu_fan=True, pump=False, config="",
                 cores=4, nvme_temp=None, bogus_sensor=False, nvidia=None, gpu_driver="amdgpu", ec=None,
                 epp=None, turbo=None, mains=None):
        self.root = tempfile.mkdtemp(prefix="zcool-")
        self.cpu, self.gpu, self.nv, self.gpu_driver, self.ec = cpu, gpu, nvidia, gpu_driver, ec
        self.first_case = self.first_own_full = self.first_boost = self.first_trim = self.first_cap = None
        self.env = dict(os.environ, LD_LIBRARY_PATH=FAKE_LIB, FAKE_NVML=f"{self.root}/dev/nvml", FAKE_NVML_SYS=self.root)
        self.rapl, self.rapl_enforced, self.cpu_fan, self.pump = rapl, rapl_enforced, cpu_fan, pump
        self.energy = 0.0
        self.freq, self.cores = freq, cores
        self.proc = None
        self.seen = {}
        self.log = os.path.join(self.root, "log")
        r = self.root
        self.cpu_dir = f"{r}/sys/class/hwmon/hwmon0"
        self.board_dir = f"{r}/sys/class/hwmon/hwmon1"
        self.gpu_dir = f"{r}/sys/class/hwmon/hwmon2"
        self.nvme_dir = f"{r}/sys/class/hwmon/hwmon3"
        put(f"{self.cpu_dir}/name", "coretemp")
        put(f"{self.cpu_dir}/temp1_label", "Package id 0")
        put(f"{self.cpu_dir}/temp1_crit", 100000)
        put(f"{self.cpu_dir}/temp2_label", "Core 0")
        put(f"{self.cpu_dir}/temp2_crit", 100000)
        put(f"{self.board_dir}/name", "nct6798")
        put(f"{self.board_dir}/temp1_input", 127000 if bogus_sensor else 35000)
        if cpu_fan:
            put(f"{self.board_dir}/pwm1", 70)
            put(f"{self.board_dir}/pwm1_enable", 2)
            put(f"{self.board_dir}/fan1_input", 900)
        if pump:
            put(f"{self.board_dir}/pwm2", 200)
            put(f"{self.board_dir}/pwm2_enable", 2)
        if gpu and gpu_driver == "xe":
            # Intel's discrete GPU: a power limit called power1_max, no fan of its own
            put(f"{self.gpu_dir}/name", "xe")
            put(f"{self.gpu_dir}/temp1_label", "pkg")
            put(f"{self.gpu_dir}/temp1_crit", 105000)
            put(f"{self.gpu_dir}/power1_max", 150000000)
            put(f"{self.gpu_dir}/device/power/runtime_status", "active")
        elif gpu:
            put(f"{self.gpu_dir}/name", "amdgpu")
            put(f"{self.gpu_dir}/temp1_label", "edge")
            put(f"{self.gpu_dir}/temp1_crit", 100000)
            put(f"{self.gpu_dir}/pwm1", 80)
            put(f"{self.gpu_dir}/pwm1_enable", 2)
            put(f"{self.gpu_dir}/fan1_input", 1200)
            put(f"{self.gpu_dir}/power1_cap", 200000000)
            put(f"{self.gpu_dir}/power1_cap_min", 60000000)
            put(f"{self.gpu_dir}/power1_average", 0)
            put(f"{self.gpu_dir}/device/power/runtime_status", "active")
        if nvme_temp is not None:
            put(f"{self.nvme_dir}/name", "nvme")
            put(f"{self.nvme_dir}/temp1_label", "Composite")
            put(f"{self.nvme_dir}/temp1_crit", 84000)
            put(f"{self.nvme_dir}/temp1_input", nvme_temp * 1000)
        self.rapl_path = f"{r}/sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw"
        if rapl:
            put(self.rapl_path, 300000000)
            put(f"{r}/sys/class/powercap/intel-rapl:0/constraint_0_max_power_uw", 300000000)
            put(f"{r}/sys/class/powercap/intel-rapl:0/energy_uj", 0)
            if not rapl_writable:
                os.chmod(self.rapl_path, 0o444)
        for i in range(cores if freq else 0):
            base = f"{r}/sys/devices/system/cpu/cpufreq/policy{i}"
            put(f"{base}/scaling_max_freq", 5000000)
            put(f"{base}/cpuinfo_max_freq", 5000000)
            put(f"{base}/cpuinfo_min_freq", 800000)
            if epp is not None:
                put(f"{base}/energy_performance_preference", epp)
        if turbo is not None:
            put(f"{r}/sys/devices/system/cpu/intel_pstate/no_turbo", 0 if turbo else 1)
        if mains is not None and not ec:
            put(f"{r}/sys/class/power_supply/ADP1/type", "Mains")
            put(f"{r}/sys/class/power_supply/ADP1/online", int(mains))
        if ec:
            self.ec_path = f"{r}/sys/kernel/debug/ec/ec0/io"
            data = bytearray(256)
            data[0xa0:0xa0 + len(ec.firmware)] = ec.firmware.encode()
            for addr, value in ec.initial.items():
                data[addr] = value
            os.makedirs(os.path.dirname(self.ec_path), exist_ok=True)
            with open(self.ec_path, "wb") as f:
                f.write(data)
            put(f"{r}/sys/module/ec_sys/parameters/write_support", "Y" if ec.writable else "N")
            put(f"{r}/sys/class/dmi/id/sys_vendor", "Micro-Star International Co., Ltd.")
            put(f"{r}/sys/class/power_supply/ADP1/type", "Mains")
            put(f"{r}/sys/class/power_supply/ADP1/online", int(ec.mains))
            put(f"{r}/sys/class/power_supply/BAT1/type", "Battery")
        put(f"{r}/etc/zcool.conf", config)
        os.makedirs(f"{r}/var/lib", exist_ok=True)
        if nvidia:
            self.pci(nvidia.bus, "0x030000" if nvidia.boot else "0x030200", "0x10de", nvidia.boot, "nvidia", nvidia.control, nvidia.status)
            if not nvidia.boot:
                self.pci("0000:00:02.0", "0x030000", "0x8086", True, "i915", "on", "active")
            p = f"{r}/proc/driver/nvidia"
            put(f"{p}/version", "NVRM version: fake")
            put(f"{p}/gpus/{nvidia.bus}/information", "Model:           GeForce GTX 1650\nDevice Minor:    0\n")
            put(f"{p}/gpus/{nvidia.bus}/power", f"Runtime D3 status:          {nvidia.d3}\nVideo Memory:               Active\n")
            self.nvml = f"{r}/dev/nvml"
            self.nv_dir = n = f"{self.nvml}/{nvidia.bus}"
            for name, value in (("slowdown", nvidia.slowdown), ("gpumax", nvidia.gpumax), ("maxclock", nvidia.maxclock),
                                ("clocks_ok", int(nvidia.clocks)), ("locked", 0), ("limit_ok", int(bool(nvidia.limit))),
                                ("fans", nvidia.fans), ("temp", 0), ("power", 0), ("util", 0)):
                put(f"{n}/{name}", value)
            if nvidia.limit:
                low, high, default = nvidia.limit
                for name, value in (("lmin", low), ("lmax", high), ("ldef", default), ("limit", default)):
                    put(f"{n}/{name}", value)
            for i in range(nvidia.fans):
                put(f"{n}/fan{i}", 30)
                put(f"{n}/fan{i}_mode", "auto")
        self.publish()

    def pci(self, bus, cls, vendor, boot, driver, control, status):
        d = f"{self.root}/sys/bus/pci/devices/{bus}"
        put(f"{d}/class", cls)
        put(f"{d}/vendor", vendor)
        put(f"{d}/boot_vga", int(boot))
        put(f"{d}/power/control", control)
        put(f"{d}/power/runtime_status", status)
        os.makedirs(f"{self.root}/sys/bus/pci/drivers/{driver}", exist_ok=True)
        os.symlink(f"../../../../bus/pci/drivers/{driver}", f"{d}/driver")

    def ec_byte(self, addr):
        with open(self.ec_path, "rb") as f:
            f.seek(addr)
            return f.read(1)[0]

    def ec_set(self, addr, value):
        fd = os.open(self.ec_path, os.O_WRONLY)
        os.pwrite(fd, bytes([value]), addr)
        os.close(fd)

    def boost(self):
        return bool(self.ec_byte(Ec.BOOST) & 0x80)

    def ec_duty(self):
        """Both fans at full with Cooler Boost, else the firmware's own curve for the hotter chip."""
        if self.boost():
            return 255
        temp = self.cpu.temp if self.cpu else 40
        if self.nv and self.nv.chip:
            temp = max(temp, self.nv.chip.temp)
        return min(255, max(70, 70 + (temp - 50) * 1.5))

    def nv_status(self, value=None):
        path = f"{self.root}/sys/bus/pci/devices/{self.nv.bus}/power/runtime_status"
        if value:
            put(path, value)
        return get(path)

    def nv_reads(self):
        path = f"{self.nv_dir}/reads"
        return [int(x) for x in open(path).read().split()] if os.path.exists(path) else []

    def helper_pid(self):
        for d in os.listdir("/proc"):
            if not d.isdigit():
                continue
            try:
                stat = open(f"/proc/{d}/stat").read()
            except OSError:
                continue
            # the name can hold spaces, the fields after it cannot
            if int(stat[stat.rindex(")") + 2:].split()[1]) == self.proc.pid:
                return int(d)
        return None

    def _write_temp(self, path, value):
        fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o644)
        os.pwrite(fd, f"{int(value * 1000):>8}\n".encode(), 0)
        os.close(fd)

    def _write_energy(self, path, value):
        fd = os.open(path, os.O_WRONLY)
        os.pwrite(fd, f"{int(value):>18}\n".encode(), 0)
        os.close(fd)

    def _write_duty(self, path, value):
        # one write over the old value, as sysfs: put() truncates first, and zcool could read that empty file
        fd = os.open(path, os.O_WRONLY)
        os.pwrite(fd, f"{int(value):>8}\n".encode(), 0)
        os.close(fd)

    def read(self, path):
        """Reads a file zcool may be writing as sysfs shows it: the old value or the new, never the
        empty file between its truncate and write. Only while zcool runs: after that an empty file is a fault."""
        # a file read for the first time has no older value to fall back on: wait for the new one
        for _ in range(100):
            value = get(path)
            if value:
                self.seen[path] = value
                return value
            if path in self.seen:
                return self.seen[path]
            time.sleep(0.001)
        return value

    def publish(self):
        if self.ec:
            if self.cpu:
                self.ec_set(Ec.CPU_TEMP, int(self.cpu.temp))
            if self.nv and self.nv.chip:
                self.ec_set(Ec.GPU_TEMP, int(self.nv.chip.temp))
        if self.cpu:
            self._write_temp(f"{self.cpu_dir}/temp1_input", self.cpu.temp)
            self._write_temp(f"{self.cpu_dir}/temp2_input", self.cpu.temp + 1)
        if self.gpu:
            self._write_temp(f"{self.gpu_dir}/temp1_input", self.gpu.temp)
        if self.nv and self.nv.chip and self.nv_status() != "suspended":
            c, n = self.nv.chip, self.nv_dir
            util = self.nv.util if self.nv.util is not None else (90 if c.load > 0 else 0)
            for name, value in (("temp", round(c.temp)), ("power", int(c.power * 1000)), ("util", util)):
                self._write_duty(f"{n}/{name}", value)

    def duty(self, directory, index, curve_base):
        pwm, enable = f"{directory}/pwm{index}", f"{directory}/pwm{index}_enable"
        if not os.path.exists(pwm):
            return 0
        if self.read(enable) != "1":
            # firmware's own curve, deliberately lazy
            temp = self.gpu.temp if directory == self.gpu_dir and self.gpu else (self.cpu.temp if self.cpu else 40)
            if directory == self.board_dir:
                # a laptop's fan cools the GPU with the CPU, and its firmware watches both
                if self.nv and not self.nv.fans and self.nv.chip:
                    temp = max(temp, self.nv.chip.temp)
                if self.gpu and self.gpu_driver == "xe":
                    temp = max(temp, self.gpu.temp)
            duty = min(255, max(curve_base, curve_base + (temp - 50) * 1.5))
            self._write_duty(pwm, duty)
            return duty
        try:
            return int(self.read(pwm))
        except ValueError:
            return 0

    def advance(self, seconds, limit_cpu=None, limit_gpu=None, tick=0.05):
        end = time.time() + seconds
        last = time.time()
        while time.time() < end:
            time.sleep(tick)
            now = time.time()
            dt, last = now - last, now
            board = self.duty(self.board_dir, 1, 70) if self.cpu_fan else 0
            if self.ec:
                board = self.ec_duty()
                if board == 255 and self.first_boost is None and self.boost():
                    self.first_boost = now
            if self.cpu_fan and self.first_case is None and self.read(f"{self.board_dir}/pwm1_enable") == "1":
                self.first_case = now
            if self.cpu:
                cap = 1e9
                speed = 1.0
                if self.rapl and self.rapl_enforced:
                    try:
                        cap = int(self.read(self.rapl_path)) / 1e6
                    except ValueError:
                        pass
                    if cap < 300 and self.first_trim is None:
                        self.first_trim = now
                        self.first_cap = cap
                if self.freq:
                    try:
                        speed = min(int(self.read(f"{self.root}/sys/devices/system/cpu/cpufreq/policy{i}/scaling_max_freq")) for i in range(self.cores)) / 5000000
                    except ValueError:
                        pass
                duty = board
                if self.pump and self.read(f"{self.board_dir}/pwm2_enable") != "1":
                    self._write_duty(f"{self.board_dir}/pwm2", 200)
                self.cpu.step(dt, cap, speed, duty, limit_cpu)
                if self.rapl:
                    self.energy += self.cpu.power * dt * 1e6
                    self._write_energy(f"{self.root}/sys/class/powercap/intel-rapl:0/energy_uj", self.energy)
            if self.gpu and self.gpu_driver == "xe":
                cap = 1e9
                try:
                    cap = int(self.read(f"{self.gpu_dir}/power1_max")) / 1e6
                except ValueError:
                    pass
                self.gpu.step(dt, cap, 1.0, board, limit_gpu)
            elif self.gpu:
                cap = 1e9
                try:
                    cap = int(self.read(f"{self.gpu_dir}/power1_cap")) / 1e6
                except ValueError:
                    pass
                own = self.duty(self.gpu_dir, 1, 80)
                if self.first_own_full is None and own >= 250:
                    self.first_own_full = now
                self.gpu.step(dt, cap, 1.0, own, limit_gpu, case_duty=board)
                self._write_energy(f"{self.gpu_dir}/power1_average", self.gpu.power * 1e6)
            if self.nv and self.nv.chip and self.nv_status() != "suspended":
                self.step_nvidia(dt, board, limit_gpu, now)
            self.publish()

    def step_nvidia(self, dt, board, limit, now):
        nv, n = self.nv, self.nv_dir
        cap, speed = 1e9, 1.0
        try:
            if nv.limit:
                cap = int(self.read(f"{n}/limit")) / 1000
            locked = int(self.read(f"{n}/locked"))
            if locked > 0:
                speed = min(1.0, locked / nv.maxclock)
        except ValueError:
            pass
        duty = board
        if nv.fans:
            if self.read(f"{n}/fan0_mode") == "manual":
                percent = int(self.read(f"{n}/fan0") or 30)
            else:
                percent = min(100, max(30, 30 + (nv.chip.temp - 50) * 1.2))
                self._write_duty(f"{n}/fan0", percent)
            duty = percent * 255 / 100
            if self.first_own_full is None and percent >= 98:
                self.first_own_full = now
        nv.chip.step(dt, cap, speed, duty, limit, case_duty=board)

    def start(self, *args):
        self.logf = open(self.log, "ab")
        self.proc = subprocess.Popen([ZCOOL, "run", "--root", self.root, *args], stdout=self.logf, stderr=subprocess.STDOUT, env=self.env)

    def stop(self, sig=signal.SIGTERM):
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(sig)
            self.proc.wait(timeout=5)
        code = self.proc.returncode if self.proc else None
        self.proc = None
        return code

    def text(self):
        self.logf.flush()
        return open(self.log).read() if os.path.exists(self.log) else ""

    def cmd(self, *args):
        return subprocess.run([ZCOOL, *args, "--root", self.root], capture_output=True, text=True, timeout=20, env=self.env)

    def close(self):
        if self.proc and self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        shutil.rmtree(self.root, ignore_errors=True)


class Result:
    def __init__(self):
        self.failed, self.notes = [], []

    def check(self, cond, what):
        if not cond:
            self.failed.append(what)

    def note(self, text):
        self.notes.append(text)


scenarios = []


def scenario(fn):
    scenarios.append(fn)
    return fn


CONFIG = "cpu0.max = 85\n"


@scenario
def strong_cooling_never_slows_down(r):
    m = Machine(cpu=Chip(load=180, g_max=4.0), config=CONFIG)
    m.start()
    m.advance(35, limit_cpu=85)
    r.check(m.cpu.peak <= 85.5, f"peak {m.cpu.peak:.1f}")
    r.check(m.read(m.rapl_path) == "300000000", f"power limit touched: {m.read(m.rapl_path)}")
    r.check(m.cpu.perf > 0.995, f"perf {m.cpu.perf:.3f}")
    r.check(m.read(f"{m.board_dir}/pwm1_enable") == "1", "fan should be managed")
    r.check("trimming power" not in m.text(), "should not have throttled")
    r.note(f"peak {m.cpu.peak:.1f} C, speed {m.cpu.perf * 100:.1f}%")
    m.stop()
    m.close()


@scenario
def a_fan_that_misses_a_read_is_taken_on_the_next(r):
    # a driver can fail a read and answer the next one: that must not cost the fan, or speed in its place
    m = Machine(cpu=Chip(load=180, g_max=4.0, temp=80), config=CONFIG)
    pwm = f"{m.board_dir}/pwm1"
    os.chmod(pwm, 0o200)  # the firmware still writes it, reads fail
    m.start()
    deadline = time.time() + 10
    while "did not answer" not in m.text() and time.time() < deadline:
        m.advance(0.05, limit_cpu=85)
    os.chmod(pwm, 0o644)
    m.advance(10, limit_cpu=85)
    r.check("did not answer" in m.text(), "the first read should have failed")
    r.check(m.read(f"{m.board_dir}/pwm1_enable") == "1", "fan should be managed")
    r.check("cannot be controlled" not in m.text(), "gave the fan up")
    r.check("trimming power" not in m.text(), "should not have throttled")
    r.check(m.read(m.rapl_path) == "300000000", f"power limit touched: {m.read(m.rapl_path)}")
    r.note(f"peak {m.cpu.peak:.1f} C, speed {m.cpu.perf * 100:.1f}%")
    m.stop()
    r.check(get(f"{m.board_dir}/pwm1_enable") == "2", "fan not returned")
    m.close()


@scenario
def weak_cooling_gives_up_only_what_it_must(r):
    # 280 W against 3.4 W/K settles at 112 C without control
    m = Machine(cpu=Chip(load=280, g_max=3.4), config=CONFIG)
    m.start()
    m.advance(30, limit_cpu=85)
    # once settled the temperature must hold still, not hunt up and down
    temps = []
    for _ in range(30):
        m.advance(0.5, limit_cpu=85)
        temps.append(m.cpu.temp)
    swing = max(temps) - min(temps)
    code = m.proc.poll()
    r.check(code is None, f"daemon exited {code}")
    r.check(m.cpu.peak <= 88, f"peak {m.cpu.peak:.1f}")
    r.check(m.cpu.prochot_time == 0, "hit PROCHOT")
    r.check(float(m.read(m.rapl_path)) < 300e6, "should cap power")
    r.check(swing < 3, f"temperature hunts by {swing:.1f} C")
    r.check(max(temps) <= 86 and min(temps) >= 80, f"settled at {min(temps):.1f}..{max(temps):.1f}, limit 85")
    r.note(f"settled within {swing:.1f} C ({min(temps):.1f}..{max(temps):.1f})")
    r.note(f"peak {m.cpu.peak:.1f} C, settled {m.cpu.temp:.1f} C, speed {m.cpu.perf * 100:.1f}%, cap {int(m.read(m.rapl_path)) / 1e6:.0f} W")
    m.stop()
    r.check(get(m.rapl_path) == "300000000", "cap not restored on stop")
    m.close()


@scenario
def beats_the_hardware_throttle(r):
    # the same overload with and without zcool, limit just below the hardware's own point
    a = Machine(cpu=Chip(load=320, g_max=3.2), config="cpu0.max = 92\n")
    a.advance(40, limit_cpu=92)
    b = Machine(cpu=Chip(load=320, g_max=3.2), config="cpu0.max = 92\n")
    b.start()
    b.advance(40, limit_cpu=92)
    r.note(f"hardware only: peak {a.cpu.peak:.1f} C, speed {a.cpu.perf * 100:.1f}%, in PROCHOT {a.cpu.prochot_time:.1f} s")
    r.note(f"with zcool:    peak {b.cpu.peak:.1f} C, speed {b.cpu.perf * 100:.1f}%, in PROCHOT {b.cpu.prochot_time:.1f} s")
    r.check(b.cpu.perf > a.cpu.perf, f"{b.cpu.perf:.3f} vs {a.cpu.perf:.3f}")
    r.check(b.cpu.prochot_time == 0, "hit PROCHOT")
    b.stop()
    a.close()
    b.close()


@scenario
def sudden_load_is_caught_in_time(r):
    m = Machine(cpu=Chip(load=0, g_max=3.4, temp=45), config=CONFIG)
    m.start()
    m.advance(4, limit_cpu=85)
    m.cpu.load = 300
    m.advance(25, limit_cpu=85)
    r.check(m.cpu.peak <= 90, f"peak {m.cpu.peak:.1f}")
    r.note(f"idle to 300 W at once: peak {m.cpu.peak:.1f} C with limit 85")
    m.stop()
    m.close()


@scenario
def a_short_burst_takes_no_power(r):
    # a laptop CPU's die: little mass, so 45 to 70 C within a second or two when work starts,
    # and back as soon as it ends. Seen on a GF63 with no fan to turn: power was trimmed at 65 C.
    m = Machine(cpu=Chip(load=0, g_min=0.8, mass=2, temp=45), cpu_fan=False, config=CONFIG)
    m.start()
    m.advance(3, limit_cpu=85)
    for _ in range(3):
        m.cpu.load = 55
        m.advance(1.6, limit_cpu=85)
        m.cpu.load = 0
        m.advance(3, limit_cpu=85)
    log = m.text()
    r.check("trimming power" not in log, log[-400:])
    r.check(m.read(m.rapl_path) == "300000000", f"power limit touched: {m.read(m.rapl_path)}")
    r.note(f"bursts to {m.cpu.peak:.1f} C with limit 85: no power taken")
    m.stop()
    m.close()


@scenario
def everything_returns_when_the_load_ends(r):
    m = Machine(cpu=Chip(load=280, g_max=3.4), config=CONFIG)
    m.start()
    m.advance(25, limit_cpu=85)
    r.check(float(m.read(m.rapl_path)) < 300e6, "should have capped")
    m.cpu.load = 10
    m.advance(40)
    r.check(m.read(m.rapl_path) == "300000000", f"cap not back: {m.read(m.rapl_path)}")
    r.check(m.read(f"{m.board_dir}/pwm1_enable") == "2", "fan not back to firmware")
    r.check("full power again" in m.text(), "no log line")
    m.stop()
    m.close()


@scenario
def sigterm_restores_at_once(r):
    m = Machine(cpu=Chip(load=280, g_max=3.4, temp=80), config=CONFIG)
    m.start()
    m.advance(15, limit_cpu=85)
    code = m.stop()
    r.check(code == 0, f"exit {code}")
    r.check(get(f"{m.board_dir}/pwm1_enable") == "2", "fan")
    r.check(get(m.rapl_path) == "300000000", "cap")
    r.check(not os.path.exists(f"{m.root}/run/zcool/state"), "journal left")
    m.close()


@scenario
def kill_nine_is_undone_by_restore(r):
    m = Machine(cpu=Chip(load=280, g_max=3.4, temp=80), config=CONFIG)
    m.start()
    m.advance(15, limit_cpu=85)
    r.check(float(m.read(m.rapl_path)) < 300e6, "should have capped first")
    r.check(m.read(f"{m.board_dir}/pwm1_enable") == "1", "should be manual first")
    m.proc.kill()
    m.proc.wait()
    r.check(os.path.exists(f"{m.root}/run/zcool/state"), "journal must survive")
    out = m.cmd("restore")
    r.check(get(f"{m.board_dir}/pwm1_enable") == "2", "fan")
    r.check(get(m.rapl_path) == "300000000", "cap")
    r.check(out.returncode == 0, out.stderr)
    m.close()


@scenario
def restart_after_a_crash_reads_true_originals(r):
    m = Machine(cpu=Chip(load=280, g_max=3.4, temp=80), config=CONFIG)
    m.start()
    m.advance(12, limit_cpu=85)
    m.proc.kill()
    m.proc.wait()
    # no finish script ran: the next start must not mistake the throttled value for the original
    m.start()
    time.sleep(1)
    m.stop()
    r.check(get(m.rapl_path) == "300000000", f"cap {get(m.rapl_path)}")
    r.check(get(f"{m.board_dir}/pwm1_enable") == "2", "fan")
    r.check("left by an earlier run" in m.text(), "should say so")
    m.close()


@scenario
def fans_never_drop_below_firmware(r):
    m = Machine(cpu=Chip(load=200, g_max=4.0, temp=80), pump=True, config=CONFIG)
    m.start()
    lowest = 255
    taken = False
    for _ in range(40):
        m.advance(0.5, limit_cpu=85)
        if m.read(f"{m.board_dir}/pwm2_enable") == "1":
            taken = True
            lowest = min(lowest, int(m.read(f"{m.board_dir}/pwm2")))
    r.check(taken, "pump never taken over, so nothing was tested")
    r.check(lowest >= 200, f"pump went to {lowest}")
    r.note(f"pump stayed at {lowest}/255 or above")
    m.stop()
    r.check(get(f"{m.board_dir}/pwm2_enable") == "2", "pump not returned")
    r.check(get(f"{m.board_dir}/pwm2") == "200", "pump value not returned")
    m.close()


@scenario
def excluded_fans_are_left_alone(r):
    m = Machine(cpu=Chip(load=280, g_max=3.4, temp=80), pump=True, config=CONFIG + "fan.exclude = nct6798/pwm2\n")
    m.start()
    m.advance(10, limit_cpu=85)
    r.check(m.read(f"{m.board_dir}/pwm2_enable") == "2", "touched an excluded fan")
    r.check(m.read(f"{m.board_dir}/pwm1_enable") == "1", "should manage the other one")
    m.stop()
    m.close()


@scenario
def sensor_failure_hands_everything_back(r):
    m = Machine(cpu=Chip(load=280, g_max=3.4, temp=80), config=CONFIG)
    m.start()
    m.advance(10, limit_cpu=85)
    m.cpu = None  # stop publishing
    for name in ("temp1_input", "temp2_input"):
        put(f"{m.cpu_dir}/{name}", "garbage")
    deadline = time.time() + 10
    while m.proc.poll() is None and time.time() < deadline:
        time.sleep(0.1)
    r.check(m.proc.poll() == 1, f"exit {m.proc.poll()}")
    r.check(get(f"{m.board_dir}/pwm1_enable") == "2", "fan")
    r.check(get(m.rapl_path) == "300000000", "cap")
    m.close()


@scenario
def bogus_sensors_do_not_spin_fans(r):
    m = Machine(cpu=Chip(load=5, temp=45), bogus_sensor=True, config=CONFIG)
    m.start()
    m.advance(6, limit_cpu=85)
    r.check(m.read(f"{m.board_dir}/pwm1_enable") == "2", "a dead 127 C input took the fans")
    m.stop()
    m.close()


@scenario
def no_fans_power_alone_holds_the_limit(r):
    m = Machine(cpu=Chip(load=120, g_min=1.5, g_max=1.5), cpu_fan=False, config=CONFIG)
    m.start()
    m.advance(45, limit_cpu=85)
    r.check(m.cpu.peak <= 88, f"peak {m.cpu.peak:.1f}")
    r.check(m.cpu.prochot_time == 0, "hit PROCHOT")
    r.note(f"laptop without fan control: peak {m.cpu.peak:.1f} C, speed {m.cpu.perf * 100:.1f}%")
    m.stop()
    m.close()


@scenario
def a_power_limit_with_no_effect_is_noticed(r):
    # the file takes the value and the chip ignores it, as firmware can do
    m = Machine(cpu=Chip(load=280, g_max=3.4, temp=70), rapl_enforced=False, config=CONFIG)
    m.start()
    m.advance(35, limit_cpu=85)
    r.check("also limiting frequency" in m.text(), "should notice")
    freq = int(m.read(f"{m.root}/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq"))
    r.check(freq < 5000000, "should limit frequency")
    r.check(m.cpu.prochot_time == 0, f"reached PROCHOT, peak {m.cpu.peak:.1f}")
    r.note(f"limit ignored by the chip: peak {m.cpu.peak:.1f} C, settled {m.cpu.temp:.1f} C, {freq / 1e6:.2f} GHz, speed {m.cpu.perf * 100:.1f}%")
    m.stop()
    r.check(get(f"{m.root}/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq") == "5000000", "frequency not restored")
    r.check(get(m.rapl_path) == "300000000", "limit not restored")
    m.close()


@scenario
def a_refused_power_limit_falls_back_at_once(r):
    m = Machine(cpu=Chip(load=280, g_max=3.4, temp=70), rapl_writable=False, config=CONFIG)
    m.start()
    m.advance(30, limit_cpu=85)
    r.check("does not stick" in m.text(), "should notice")
    r.check(m.cpu.peak <= 89, f"peak {m.cpu.peak:.1f}")
    freq = int(m.read(f"{m.root}/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq"))
    r.check(freq < 5000000, "should limit frequency")
    m.stop()
    m.close()


@scenario
def a_limit_starts_from_real_power_not_the_rating(r):
    # a 300 W rating, a chip drawing 120 W: a cap at 90 percent of the rating would do nothing
    m = Machine(cpu=Chip(load=120, g_min=1.2, g_max=1.2), cpu_fan=False, config=CONFIG)
    m.start()
    m.advance(40, limit_cpu=85)
    cap = int(m.read(m.rapl_path)) / 1e6
    r.check(cap < 120, f"cap {cap:.0f} W should be below the real 120 W")
    r.check(m.cpu.peak <= 88.5, f"peak {m.cpu.peak:.1f}")
    r.check(m.cpu.prochot_time == 0, "hit PROCHOT")
    r.note(f"300 W rating, 120 W real: cap {cap:.0f} W, peak {m.cpu.peak:.1f} C, speed {m.cpu.perf * 100:.1f}%")
    m.stop()
    m.close()


@scenario
def only_cpufreq_also_works(r):
    m = Machine(cpu=Chip(load=280, g_max=3.4, temp=70), rapl=False, config=CONFIG)
    m.start()
    m.advance(30, limit_cpu=85)
    r.check(m.cpu.peak <= 89, f"peak {m.cpu.peak:.1f}")
    m.stop()
    for i in range(4):
        r.check(get(f"{m.root}/sys/devices/system/cpu/cpufreq/policy{i}/scaling_max_freq") == "5000000", f"policy{i}")
    m.close()


@scenario
def each_chip_has_its_own_limit(r):
    m = Machine(cpu=Chip(load=60, g_max=4.0), gpu=Chip(load=300, g_max=3.5), config="cpu0.max = 85\ngpu0.max = 75\n")
    m.start()
    m.advance(30, limit_cpu=85, limit_gpu=75)
    # this model heats at 10 C per second, so one look at the sensors is worth up to 5 C
    r.check(m.gpu.peak <= 80, f"gpu peak {m.gpu.peak:.1f}")
    r.check(m.gpu.prochot_time == 0, "hit PROCHOT")
    # without its fan the cap alone holds the limit, lower and later: the peak check above can miss that
    r.check(m.read(f"{m.gpu_dir}/pwm1_enable") == "1", "the GPU fan should be managed")
    r.check(m.read(m.rapl_path) == "300000000", "a hot GPU must not throttle the CPU")
    # the case fan may help, but only once the GPU's own fan has nothing left
    r.check(m.first_case is None or (m.first_own_full is not None and m.first_case >= m.first_own_full - 0.3),
            "the case fan joined before the GPU's own fan was at full")
    r.check(int(m.read(f"{m.gpu_dir}/power1_cap")) < 200000000, "should cap the GPU")
    r.check(int(m.read(f"{m.gpu_dir}/power1_cap")) >= 60000000, "cap below the driver minimum")
    r.note(f"gpu at 75: peak {m.gpu.peak:.1f} C, cap {int(m.read(f'{m.gpu_dir}/power1_cap')) / 1e6:.0f} W; cpu untouched")
    m.stop()
    r.check(get(f"{m.gpu_dir}/power1_cap") == "200000000", "gpu cap not restored")
    m.close()


@scenario
def a_chip_that_never_reads_is_ignored_not_fatal(r):
    m = Machine(cpu=Chip(load=5, temp=45), gpu=Chip(load=0, temp=45), config=CONFIG)
    m.gpu = None
    put(f"{m.gpu_dir}/temp1_input", 0)
    m.start()
    m.advance(5, limit_cpu=85)
    r.check(m.proc.poll() is None, "must not restart forever over one dead sensor")
    r.check("no usable readings" in m.text(), m.text())
    m.stop()
    m.close()


@scenario
def a_gpu_going_to_sleep_stops_counting(r):
    m = Machine(cpu=Chip(load=5, temp=45), gpu=Chip(load=300, g_max=3.5, temp=70), config="cpu0.max = 85\ngpu0.max = 75\n")
    m.start()
    m.advance(8, limit_gpu=75)
    r.check(m.read(f"{m.gpu_dir}/pwm1_enable") == "1", "should be managing the GPU fan")
    # asleep the sensor is frozen at its last hot value, and must not keep the fan up
    put(f"{m.gpu_dir}/device/power/runtime_status", "suspended")
    m.gpu = None
    m.advance(28)
    r.check(m.read(f"{m.gpu_dir}/pwm1_enable") == "2", "a sleeping GPU kept its fan managed")
    m.stop()
    m.close()


@scenario
def a_sleeping_gpu_is_not_woken(r):
    m = Machine(cpu=Chip(load=5, temp=45), gpu=Chip(load=0, temp=45), config=CONFIG)
    put(f"{m.gpu_dir}/device/power/runtime_status", "suspended")
    os.chmod(f"{m.gpu_dir}/temp1_input", 0o644)
    put(f"{m.gpu_dir}/temp1_input", 95000)
    m.gpu = None
    m.start()
    m.advance(6, limit_cpu=85)
    r.check(m.read(f"{m.gpu_dir}/pwm1_enable") == "2", "reacted to a chip that sleeps")
    r.check(m.proc.poll() is None, "should keep running")
    m.stop()
    m.close()


@scenario
def limits_cannot_be_set_above_safety(r):
    m = Machine(cpu=Chip(load=5, temp=45), nvme_temp=40, config="cpu0.max = 150\nnvme0.max = 60\nbroken line\nundervolt.core = 50\n")
    out = m.cmd("list").stdout
    r.check("cpu0" in out and "95" in out, f"limit should clamp to 95:\n{out}")
    r.check("outside the safe range" in out, f"should warn:\n{out}")
    r.check("skipped 2 line" in out, f"should count bad lines:\n{out}")
    r.check("nvme0" in out and "60" in out, f"nvme limit:\n{out}")
    r.check("nct6798/pwm1" in out, f"fans:\n{out}")
    m.close()


@scenario
def dry_run_changes_nothing(r):
    m = Machine(cpu=Chip(load=320, g_max=2.0, temp=88), pump=True, config=CONFIG)
    def snapshot():
        out = {}
        for d, _, files in os.walk(f"{m.root}/sys"):
            for f in files:
                if f.startswith("temp") and f.endswith("_input"):
                    continue
                if f in ("pwm1", "pwm2", "fan1_input", "energy_uj", "power1_average"):
                    continue  # the simulated hardware moves these itself
                out[os.path.join(d, f)] = get(os.path.join(d, f))
        return out
    before = snapshot()
    m.start("--dry-run")
    m.advance(8)
    r.check(snapshot() == before, "dry run wrote something")
    r.check(not os.path.exists(f"{m.root}/run/zcool/state"), "dry run wrote a journal")
    r.check("taking over" in m.text() or "trimming" in m.text(), "should say what it would do")
    m.stop()
    m.close()


@scenario
def sandbox_blocks_the_rest_of_the_system(r):
    m = Machine(cpu=Chip(load=5, temp=45), config=CONFIG)
    out = subprocess.run([ZCOOL, "run", "--selftest-sandbox", "--root", m.root], capture_output=True, text=True, timeout=10).stdout
    r.note(" | ".join(l for l in out.splitlines() if "sandbox" in l or "selftest" in l))
    r.check("sandbox: active" in out, out)
    r.check("/etc/passwd blocked" in out, out)
    m.close()


GPU_CONFIG = "cpu0.max = 85\ngpu0.max = 80\n"


@scenario
def a_laptop_gpu_shares_the_fan_then_gives_up_clocks(r):
    # a laptop's GTX 1650: no fan of its own, no power limit from the driver, a clock limit it takes
    nv = Nvidia(Chip(load=90, g_min=0.5, g_max=1.6, mass=15, temp=60))
    m = Machine(cpu=Chip(load=15, g_max=2.0), nvidia=nv, config=GPU_CONFIG)
    m.start()
    m.advance(40, limit_cpu=85, limit_gpu=80)
    log = m.text()
    locked = int(m.read(f"{m.nv_dir}/locked"))
    r.check("NVIDIA at 0000:01:00.0" in log, log[-400:])
    r.check(m.read(f"{m.board_dir}/pwm1_enable") == "1", "the shared fan should work for the GPU")
    r.check(0 < locked < nv.maxclock, f"locked at {locked}")
    r.check("a clock limit" in log, "should say how it holds the GPU")
    r.check(nv.chip.peak <= 85, f"gpu peak {nv.chip.peak:.1f}")
    r.check(m.read(m.rapl_path) == "300000000", "a hot GPU must not throttle the CPU")
    r.note(f"gpu at 80: peak {nv.chip.peak:.1f} C, clocks {locked} of {nv.maxclock} MHz, speed {nv.chip.perf * 100:.1f}%")
    m.stop()
    r.check(get(f"{m.nv_dir}/locked") == "0", "clocks not given back")
    r.check(get(f"{m.board_dir}/pwm1_enable") == "2", "fan not given back")
    m.close()


@scenario
def a_desktop_gpu_uses_its_own_fan_then_the_case_fan_then_power(r):
    nv = Nvidia(Chip(load=320, g_min=0.8, g_max=3.4, g_case=0.5, temp=60), fans=1, limit=(150000, 350000, 300000), boot=True)
    m = Machine(cpu=Chip(load=40, g_max=3.0), nvidia=nv, config=GPU_CONFIG)
    m.start()
    m.advance(40, limit_cpu=85, limit_gpu=80)
    log = m.text()
    limit = int(m.read(f"{m.nv_dir}/limit"))
    r.check(m.read(f"{m.nv_dir}/fan0_mode") == "manual", "its own fan should be managed")
    r.check(m.first_case is not None, "the case fan should join once the GPU's fan is at full")
    r.check(m.first_case is None or (m.first_own_full is not None and m.first_case >= m.first_own_full - 0.3),
            "the case fan joined before the GPU's own fan was at full")
    r.check(limit < 300000, "should lower the power limit")
    r.check("its power limit" in log, log[-400:])
    r.check(nv.chip.peak <= 86, f"gpu peak {nv.chip.peak:.1f}")
    r.note(f"gpu at 80: peak {nv.chip.peak:.1f} C, its fan, then the case fan, then {limit / 1000:.0f} of 300 W")
    m.stop()
    r.check(get(f"{m.nv_dir}/fan0_mode") == "auto", "fan not given back")
    r.check(get(f"{m.nv_dir}/limit") == "300000", f"limit not given back: {get(f'{m.nv_dir}/limit')}")
    m.close()


@scenario
def a_sleeping_nvidia_gpu_is_never_touched(r):
    nv = Nvidia(Chip(load=0, temp=45), control="auto", status="suspended")
    m = Machine(cpu=Chip(load=5, temp=45), nvidia=nv, config=CONFIG)
    # a frozen hot value: acting on it would mean the GPU was read
    put(f"{m.nv_dir}/temp", 99)
    m.start()
    m.advance(6, limit_cpu=85)
    out = m.cmd("list").stdout
    r.check(not os.path.exists(f"{m.nv_dir}/woken"), "a sleeping GPU was reached")
    r.check(not m.nv_reads(), "a sleeping GPU was read")
    r.check(m.proc.poll() is None, "should keep running")
    r.check("asleep" in out, out)
    m.stop()
    m.close()


@scenario
def an_idle_gpu_is_read_rarely_so_it_can_sleep(r):
    nv = Nvidia(Chip(load=0, temp=45, g_max=1.6), control="auto")
    m = Machine(cpu=Chip(load=5, temp=45), nvidia=nv, config=CONFIG)
    m.start()
    m.advance(26)
    reads = m.nv_reads()
    gaps = [b - a for a, b in zip(reads, reads[1:])]
    r.check(len(reads) <= 8, f"{len(reads)} reads in 26 s of nothing")
    r.check(bool(gaps) and gaps[-1] >= 8000, f"gaps {gaps}")
    r.check(os.path.exists(f"{m.nvml}/shutdowns"), "NVIDIA's library was never let go of")
    # asleep, then awake again for a game: looked at at once, and often while busy
    m.nv_status("suspended")
    m.advance(3)
    before = len(m.nv_reads())
    m.nv_status("active")
    nv.chip.load = 90
    m.advance(1.5)
    r.check(len(m.nv_reads()) > before, "not read after waking")
    m.advance(6)
    busy = m.nv_reads()[-4:]
    r.check(len(busy) == 4 and max(b - a for a, b in zip(busy, busy[1:])) <= 1500, f"a busy GPU read too rarely: {busy}")
    r.note(f"idle: {len(reads)} reads in 26 s, the last {gaps[-1] / 1000 if gaps else 0:.0f} s apart; busy: every second")
    m.stop()
    m.close()


@scenario
def gpus_that_show_nothing_may_sleep_and_get_their_setting_back(r):
    nv = Nvidia(Chip(load=0, temp=45), d3="Disabled by default")
    m = Machine(cpu=Chip(load=5, temp=45), nvidia=nv, config=CONFIG)
    dgpu = f"{m.root}/sys/bus/pci/devices/{nv.bus}/power/control"
    igpu = f"{m.root}/sys/bus/pci/devices/0000:00:02.0/power/control"
    m.start()
    m.advance(2)
    r.check(get(dgpu) == "auto", f"the GPU that shows nothing should may sleep: {get(dgpu)}")
    r.check(get(igpu) == "on", "the GPU with the boot screen must stay as it was")
    r.check("NVreg_DynamicPowerManagement=0x02" in m.text(), "should say what NVIDIA's driver needs")
    m.stop()
    r.check(get(dgpu) == "on", "setting not given back")
    m.close()

    m = Machine(cpu=Chip(load=5, temp=45), nvidia=Nvidia(Chip(load=0, temp=45)), config=CONFIG + "gpu.sleep = no\n")
    m.start()
    m.advance(2)
    r.check(get(f"{m.root}/sys/bus/pci/devices/0000:01:00.0/power/control") == "on", "gpu.sleep = no was ignored")
    m.stop()
    m.close()


@scenario
def nvidia_settings_go_back_however_zcool_ends(r):
    def hot():
        nv = Nvidia(Chip(load=320, g_min=0.8, g_max=3.0, temp=78), fans=1, limit=(150000, 350000, 300000), boot=True)
        m = Machine(cpu=Chip(load=20), nvidia=nv, config=GPU_CONFIG)
        m.start()
        m.advance(15, limit_gpu=80)
        r.check(m.read(f"{m.nv_dir}/fan0_mode") == "manual" and int(m.read(f"{m.nv_dir}/limit")) < 300000,
                "should have changed the fan and the limit first")
        return m

    m = hot()
    m.proc.kill()
    m.proc.wait()
    time.sleep(3)
    r.check(get(f"{m.nv_dir}/fan0_mode") == "auto", "zcool-nvidia did not give the fan back when zcool died")
    r.check(get(f"{m.nv_dir}/limit") == "300000", "zcool-nvidia did not give the limit back when zcool died")
    m.close()

    # both killed: the list in /run/zcool/nvidia is what `zcool restore` goes by
    m = hot()
    helper = m.helper_pid()
    r.check(helper is not None, "no zcool-nvidia found")
    if helper:
        os.kill(helper, signal.SIGKILL)
    m.proc.kill()
    m.proc.wait()
    out = m.cmd("restore")
    r.check(get(f"{m.nv_dir}/fan0_mode") == "auto" and get(f"{m.nv_dir}/limit") == "300000", out.stdout + out.stderr)
    r.check("put back on 1 GPU" in out.stdout, out.stdout)
    m.close()


@scenario
def list_shows_each_gpu_and_what_keeps_it_awake(r):
    nv = Nvidia(Chip(load=0, temp=50), control="auto", d3="Disabled by default")
    m = Machine(cpu=Chip(load=5, temp=45), nvidia=nv, config=CONFIG)
    put(f"{m.root}/proc/4242/comm", "mango")
    os.makedirs(f"{m.root}/proc/4242/fd")
    os.symlink("/dev/nvidia0", f"{m.root}/proc/4242/fd/7")
    out = m.cmd("list").stdout
    r.check("0000:01:00.0" in out and "when idle" in out, out)
    r.check("held open by mango (4242)" in out, out)
    r.check("NVreg_DynamicPowerManagement=0x02" in out, out)
    r.check("CPU's package power limit" in out, out)
    r.check("gpu0" in out and "clocks" in out, out)
    m.close()


@scenario
def an_intel_gpu_is_held_by_its_power_limit(r):
    m = Machine(cpu=Chip(load=10, g_max=2.0), gpu=Chip(load=150, g_min=0.5, g_max=2.0, temp=70), gpu_driver="xe", config=GPU_CONFIG)
    m.start()
    m.advance(30, limit_gpu=80)
    limit = int(m.read(f"{m.gpu_dir}/power1_max"))
    r.check(m.read(f"{m.board_dir}/pwm1_enable") == "1", "the shared fan should work for the GPU first")
    r.check(limit < 150000000, "should lower power1_max")
    r.check(m.gpu.peak <= 85, f"gpu peak {m.gpu.peak:.1f}")
    r.note(f"gpu at 80: peak {m.gpu.peak:.1f} C, {limit / 1e6:.0f} of 150 W")
    m.stop()
    r.check(get(f"{m.gpu_dir}/power1_max") == "150000000", "power1_max not given back")
    m.close()


def undervolt_machine(cpuinfo="GenuineIntel", lockdown="[none] integrity confidentiality", config="undervolt.core = -50\n"):
    m = Machine(cpu=Chip(load=5, temp=45), config=config)
    put(f"{m.root}/proc/cpuinfo", f"vendor_id : {cpuinfo}\n")
    put(f"{m.root}/sys/kernel/security/lockdown", lockdown)
    os.makedirs(f"{m.root}/dev/cpu/0")
    with open(f"{m.root}/dev/cpu/0/msr", "wb") as f:
        f.write(b"\0" * 0x200)
    return m


def msr_value(m):
    with open(f"{m.root}/dev/cpu/0/msr", "rb") as f:
        f.seek(0x150)
        return struct.unpack("<Q", f.read(8))[0]


@scenario
def undervolt_refuses_when_it_should(r):
    m = undervolt_machine(lockdown="none [integrity] confidentiality")
    m.start()
    time.sleep(1)
    r.check("lockdown blocks" in m.text(), m.text())
    r.check(msr_value(m) == 0, "wrote despite lockdown")
    r.check(m.proc.poll() is None, "cooling must keep running")
    m.stop()
    m.close()

    m = undervolt_machine(cpuinfo="AuthenticAMD")
    m.start()
    time.sleep(1)
    r.check("Curve Optimizer" in m.text(), m.text())
    r.check(msr_value(m) == 0, "wrote on AMD")
    m.stop()
    m.close()

    m = undervolt_machine(config="undervolt.core = -200\n")
    m.start()
    time.sleep(1)
    r.check("below -125" in m.text(), m.text())
    r.check(msr_value(m) == 0, "wrote an extreme offset")
    m.stop()
    m.close()

    m = undervolt_machine(config="cpu0.max = 85\n")
    m.start()
    time.sleep(1)
    r.check(msr_value(m) == 0, "touched the MSR without being asked")
    r.check("undervolt" not in m.text(), m.text())
    m.stop()
    m.close()


@scenario
def undervolt_detects_a_cpu_that_ignores_it(r):
    # a plain file answers a read request with the request itself, offset 0: like a locked CPU
    m = undervolt_machine()
    m.start()
    time.sleep(1)
    r.check("locked undervolting" in m.text(), m.text())
    value = msr_value(m)
    r.check(value >> 63 == 1 and (value >> 36) & 1 == 1, f"{value:#x}")
    r.check(not os.path.exists(f"{m.root}/var/lib/zcool/undervolt-pending"), "pending left after a refusal")
    r.check(m.proc.poll() is None, "cooling must keep running")
    m.stop()
    m.close()


@scenario
def undervolt_is_skipped_after_a_crash(r):
    m = undervolt_machine()
    put(f"{m.root}/var/lib/zcool/undervolt-pending", "applied")
    m.start()
    time.sleep(1)
    r.check("did not end cleanly" in m.text(), m.text())
    r.check(msr_value(m) == 0, "applied again after a crash")
    m.stop()
    out = m.cmd("undervolt", "reset")
    r.check(out.returncode == 0, out.stderr)
    r.check(not os.path.exists(f"{m.root}/var/lib/zcool/undervolt-pending"), "reset should clear it")
    m.close()


EC_CONFIG = "cpu0.max = 85\n"


@scenario
def an_msi_laptop_boosts_its_fans_before_taking_power(r):
    # no fan in hwmon: only the EC's Cooler Boost, and more heat than the fans can carry
    m = Machine(cpu=Chip(load=220, g_min=0.8, g_max=3.0), cpu_fan=False, ec=Ec(), config=EC_CONFIG)
    m.start()
    m.advance(40, limit_cpu=85)
    log = m.text()
    r.check("ec/cooler_boost: on, both fans at full" in log, log[-500:])
    r.check(m.first_boost is not None and (m.first_trim is None or m.first_boost < m.first_trim),
            f"boost at {m.first_boost}, power trimmed at {m.first_trim}")
    r.check(m.ec_byte(Ec.BOOST) == 0x85, f"0x98 is {m.ec_byte(Ec.BOOST):#x}: only bit 7 should change")
    r.check(m.cpu.peak <= 87, f"peak {m.cpu.peak:.1f}")
    r.note(f"peak {m.cpu.peak:.1f} C, speed {m.cpu.perf * 100:.1f}%")
    m.cpu.load = 10
    m.advance(55, limit_cpu=85)
    log = m.text()
    # off by itself as the fans come down, or handed back with the rest once there is nothing to do
    r.check("ec/cooler_boost: off" in log or "ec/cooler_boost: back to the firmware" in log, log[-500:])
    r.check(m.ec_byte(Ec.BOOST) == 0x05, f"0x98 is {m.ec_byte(Ec.BOOST):#x} after the heat")
    m.stop()
    m.close()


@scenario
def cooler_boost_goes_back_however_zcool_ends(r):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        m = Machine(cpu=Chip(load=220, g_min=0.8, g_max=3.0), cpu_fan=False, ec=Ec(), config=EC_CONFIG)
        m.start()
        m.advance(25, limit_cpu=85)
        r.check(m.boost(), f"{sig.name}: boost never came on")
        # the firmware changes its own bits meanwhile: they must stay as it left them
        m.ec_set(Ec.BOOST, m.ec_byte(Ec.BOOST) | 0x02)
        m.stop(sig)
        if sig == signal.SIGKILL:
            r.check(m.boost(), "kill -9 cannot put anything back by itself")
            m.cmd("restore")
        r.check(m.ec_byte(Ec.BOOST) == 0x07, f"{sig.name}: 0x98 is {m.ec_byte(Ec.BOOST):#x}, should be 0x07")
        r.check(get(m.rapl_path) == "300000000", f"{sig.name}: power not given back")
        m.close()


@scenario
def a_boost_the_user_turned_on_stays_on(r):
    m = Machine(cpu=Chip(load=220, g_min=0.8, g_max=3.0), cpu_fan=False, ec=Ec(boost=0x85), config=EC_CONFIG)
    m.start()
    m.advance(25, limit_cpu=85)
    m.cpu.load = 10
    m.advance(35, limit_cpu=85)
    r.check(m.boost(), "the boost the user turned on was turned off")
    m.stop()
    r.check(m.boost(), "the boost the user turned on was turned off at the end")
    m.close()


@scenario
def the_charge_limit_is_set_and_stays(r):
    m = Machine(cpu=Chip(load=10), cpu_fan=False, ec=Ec(), config="battery.max = 80\n")
    m.start()
    m.advance(3)
    r.check(m.ec_byte(Ec.CHARGE) == 0x80 | 80, f"0xef is {m.ec_byte(Ec.CHARGE):#x}")
    r.check("charges up to 80%" in m.text(), m.text()[-300:])
    m.stop()
    r.check(m.ec_byte(Ec.CHARGE) == 0x80 | 80, "the limit must hold while the laptop is off")
    m.close()
    # an EC without one is left alone; the kernel's own setting wins where there is one
    m = Machine(cpu=Chip(load=10), cpu_fan=False, ec=Ec(charge=0x00), config="battery.max = 80\n")
    m.start()
    m.advance(2)
    r.check(m.ec_byte(Ec.CHARGE) == 0x00, "an EC that takes no limit was written")
    r.check("takes no charge limit" in m.text(), m.text()[-300:])
    m.stop()
    m.close()
    m = Machine(cpu=Chip(load=10), cpu_fan=False, ec=Ec(), config="battery.max = 60\n")
    put(f"{m.root}/sys/class/power_supply/BAT1/charge_control_end_threshold", 100)
    m.start()
    m.advance(2)
    r.check(get(f"{m.root}/sys/class/power_supply/BAT1/charge_control_end_threshold") == "60", "the kernel's limit was not set")
    r.check(m.ec_byte(Ec.CHARGE) == 0x80, "the EC was written next to the kernel's setting")
    m.stop()
    m.close()


@scenario
def the_ec_profile_follows_the_power_source(r):
    m = Machine(cpu=Chip(load=10), cpu_fan=False, ec=Ec(), config="mode.ac = sport\nmode.battery = eco\n")
    m.start()
    m.advance(3)
    r.check(m.ec_byte(Ec.PROFILE) == 0xc0, f"on mains: {m.ec_byte(Ec.PROFILE):#x}")
    put(f"{m.root}/sys/class/power_supply/ADP1/online", 0)
    m.advance(4)
    r.check(m.ec_byte(Ec.PROFILE) == 0xc2, f"on battery: {m.ec_byte(Ec.PROFILE):#x}")
    r.check("ec: profile eco on battery" in m.text(), m.text()[-300:])
    m.stop()
    r.check(m.ec_byte(Ec.PROFILE) == 0xc1, f"the original profile should come back: {m.ec_byte(Ec.PROFILE):#x}")
    m.close()
    # only one source named: the other gets the firmware's own profile back
    m = Machine(cpu=Chip(load=10), cpu_fan=False, ec=Ec(mains=False), config="mode.battery = eco\n")
    m.start()
    m.advance(3)
    r.check(m.ec_byte(Ec.PROFILE) == 0xc2, f"on battery: {m.ec_byte(Ec.PROFILE):#x}")
    put(f"{m.root}/sys/class/power_supply/ADP1/online", 1)
    m.advance(4)
    r.check(m.ec_byte(Ec.PROFILE) == 0xc1, f"back on mains: {m.ec_byte(Ec.PROFILE):#x}")
    m.stop()
    m.close()


@scenario
def an_ec_zcool_does_not_know_or_cannot_write_is_left_alone(r):
    for ec, said in ((Ec(firmware="16R5EMS1.999"), "not one zcool knows"), (Ec(writable=False), "read only")):
        m = Machine(cpu=Chip(load=220, g_min=0.8, g_max=3.0), cpu_fan=False, ec=ec,
                    config=EC_CONFIG + "battery.max = 80\nmode.ac = sport\n")
        before = open(m.ec_path, "rb").read()
        out = m.cmd("list").stdout
        r.check(said in out, out)
        m.start()
        m.advance(15, limit_cpu=85)
        m.stop()
        after = open(m.ec_path, "rb").read()
        changed = [hex(i) for i in range(256) if before[i] != after[i] and i not in (Ec.CPU_TEMP, Ec.GPU_TEMP)]
        r.check(not changed, f"{ec.firmware}: written at {changed}")
        m.close()


@scenario
def list_shows_the_ec(r):
    # 0x80: no program has set a profile, as on a GF63 that never ran MSI's own tools
    m = Machine(cpu=Chip(load=10, temp=55), cpu_fan=False, ec=Ec(charge=0x80 | 80, profile=0x80))
    m.ec_set(0x71, 45)
    out = m.cmd("list").stdout
    r.check("ec: 16R5EMS1.102, GF63/GF65 Thin" in out, out)
    r.check("cooler boost off, profile the firmware's own, charge limit 80%" in out, out)
    r.check("ec/cooler_boost" in out and "auto" in out, out)
    r.check("cpu 55C, fan 45%" in out, out)
    m.close()


@scenario
def list_says_what_keeps_zcool_from_the_ec(r):
    m = Machine(cpu=Chip(load=10))
    put(f"{m.root}/sys/class/dmi/id/sys_vendor", "Micro-Star International Co., Ltd.")
    out = m.cmd("list").stdout
    # the simulator never runs as root, and only root can see debugfs
    r.check("only root reaches it: doas zcool list" in out, out)
    m.close()


@scenario
def nvidia_its_library_cannot_read_is_read_through_the_ec(r):
    nv = Nvidia(Chip(load=90, g_min=0.5, g_max=1.6, mass=15, temp=60))
    m = Machine(cpu=Chip(load=15, g_max=2.0), cpu_fan=False, nvidia=nv, ec=Ec(), config=GPU_CONFIG)
    put(f"{m.nv_dir}/no_temp", 1)
    m.start()
    m.advance(30, limit_cpu=85, limit_gpu=80)
    log = m.text()
    r.check("NVIDIA's library answers \"err no temperature" in log, log[-500:])
    r.check("gpu0: read through the EC instead, limit 80C" in log, log[-500:])
    r.check(m.first_boost is not None, "the hot GPU should have brought Cooler Boost on")
    out = m.cmd("list").stdout
    r.check("ec, fans" in out, out)
    m.stop()
    r.check(not m.boost(), "boost not given back")
    m.close()


@scenario
def nvidia_that_reads_only_attached_is_attached(r):
    nv = Nvidia(Chip(load=90, g_min=0.5, g_max=1.6, mass=15, temp=60))
    m = Machine(cpu=Chip(load=15, g_max=2.0), nvidia=nv, config=GPU_CONFIG)
    put(f"{m.nv_dir}/needs_attach", 1)
    out = m.cmd("list").stdout
    r.check("gpu0" in out and "clocks" in out, out)
    m.start()
    m.advance(20, limit_cpu=85, limit_gpu=80)
    r.check("NVIDIA at 0000:01:00.0" in m.text(), m.text()[-400:])
    m.stop()
    m.close()


def epp_of(m):
    return {get(f"{m.root}/sys/devices/system/cpu/cpufreq/policy{i}/energy_performance_preference") for i in range(m.cores)}


@scenario
def the_power_source_sets_the_cpus_preference_turbo_and_limits(r):
    config = "cpu0.max = 85\nepp.ac = balance_performance\nepp.battery = power\nturbo.battery = no\nlimits.battery = -10\n"
    online = None
    no_turbo = None
    for sig in (signal.SIGTERM, signal.SIGKILL):
        m = Machine(cpu=Chip(load=10), epp="balance_power", turbo=True, mains=True, config=config)
        online = f"{m.root}/sys/class/power_supply/ADP1/online"
        no_turbo = f"{m.root}/sys/devices/system/cpu/intel_pstate/no_turbo"
        m.start()
        m.advance(3)
        r.check(epp_of(m) == {"balance_performance"}, f"on mains: {epp_of(m)}")
        r.check(get(no_turbo) == "0", "turbo should stay on, on mains")
        put(online, 0)
        m.advance(4)
        r.check(epp_of(m) == {"power"}, f"on battery: {epp_of(m)}")
        r.check(get(no_turbo) == "1", "turbo should be off on battery")
        r.check("power: on battery: limits 10C lower, energy preference power, turbo off" in m.text(), m.text()[-400:])
        if sig == signal.SIGTERM:
            put(online, 1)
            m.advance(4)
            r.check(epp_of(m) == {"balance_performance"}, f"back on mains: {epp_of(m)}")
            r.check(get(no_turbo) == "0", "turbo.ac is not set: the original comes back on mains")
        m.stop(sig)
        if sig == signal.SIGKILL:
            m.cmd("restore")
        r.check(epp_of(m) == {"balance_power"}, f"originals after {sig.name}: {epp_of(m)}")
        r.check(get(no_turbo) == "0", f"turbo after {sig.name}: {get(no_turbo)}")
        m.close()


@scenario
def on_battery_every_limit_is_lower(r):
    m = Machine(cpu=Chip(load=280, g_max=3.4), mains=False, config="cpu0.max = 85\nlimits.battery = -10\n")
    m.start()
    m.advance(30, limit_cpu=75)
    temps = []
    for _ in range(16):
        m.advance(0.5, limit_cpu=75)
        temps.append(m.cpu.temp)
    r.check(m.cpu.peak <= 79, f"peak {m.cpu.peak:.1f} on battery, limit 75")
    r.check(max(temps) <= 76.5, f"settled at {min(temps):.1f}..{max(temps):.1f}, limit 75")
    battery = m.cpu.perf
    put(f"{m.root}/sys/class/power_supply/ADP1/online", 1)
    m.advance(25, limit_cpu=85)
    r.check(m.cpu.temp > 80, f"on mains it may go to 85 again: {m.cpu.temp:.1f}")
    r.note(f"on battery: settled {min(temps):.1f}..{max(temps):.1f} C at speed {battery * 100:.0f}%; on mains {m.cpu.temp:.1f} C")
    m.stop()
    m.close()


@scenario
def quiet_gives_a_little_power_before_cooler_boost(r):
    # the firmware's curve carries about 100 W at 85 C, Cooler Boost 165 W
    m = Machine(cpu=Chip(load=110, g_min=0.8, g_max=3.0), cpu_fan=False, ec=Ec(), config="cpu0.max = 85\nnoise.ac = quiet\n")
    m.start()
    m.advance(40, limit_cpu=85)
    log = m.text()
    r.check(m.first_boost is None, "a little power was enough here, Cooler Boost should stay off")
    r.check("quiet: a little power before louder fans" in log, log[-400:])
    r.check(m.cpu.peak <= 87, f"peak {m.cpu.peak:.1f}")
    r.check(m.cpu.perf > 0.9, f"speed {m.cpu.perf:.3f}")
    r.note(f"110 W: no boost, peak {m.cpu.peak:.1f} C, speed {m.cpu.perf * 100:.1f}%")
    m.stop()
    m.close()
    # more than a little power can cover: then Cooler Boost comes, after the power
    m = Machine(cpu=Chip(load=160, g_min=0.8, g_max=3.0), cpu_fan=False, ec=Ec(), config="cpu0.max = 85\nnoise.ac = quiet\n")
    m.start()
    m.advance(50, limit_cpu=85)
    log = m.text()
    r.check(m.first_trim is not None and m.first_boost is not None and m.first_trim < m.first_boost,
            f"power trimmed at {m.first_trim}, boost at {m.first_boost}")
    r.check("the fans join in" in log, log[-400:])
    r.check(m.cpu.peak <= 87, f"peak {m.cpu.peak:.1f}")
    # with the boost on it gets its power back, and the boost stays while the load does
    r.check(m.boost(), "the boost should stay on while the load lasts")
    r.check(float(m.read(m.rapl_path)) >= 290e6 or "full power again" in log, f"cap {m.read(m.rapl_path)}")
    r.note(f"160 W: power first, then the boost; peak {m.cpu.peak:.1f} C, speed {m.cpu.perf * 100:.1f}%")
    m.stop()
    m.close()


@scenario
def the_cooler_is_learned_and_power_starts_there_next_time(r):
    m = Machine(cpu=Chip(load=280, g_max=3.4), config=CONFIG)
    m.start()
    deadline = time.time() + 70
    while "learned that the cooler carries" not in m.text() and time.time() < deadline:
        m.advance(1, limit_cpu=85)
    r.check("learned that the cooler carries" in m.text(), m.text()[-400:])
    first = m.first_cap
    m.stop()
    path = f"{m.root}/var/lib/zcool/learned"
    learned = get(path) if os.path.exists(path) else ""
    r.check(learned.startswith("cpu0 "), f"learned file: {learned!r}")
    if not learned.startswith("cpu0 "):
        m.close()
        return
    watts = float(learned.split()[1])
    # 55 K over ambient at 3.4 W/K, with the fan at full
    r.check(165 < watts < 205, f"learned {watts} W")
    listed = m.cmd("list").stdout
    r.check("learned:" in listed and "cpu0" in listed.split("learned:")[1], listed[-300:])
    # cool again, then the same load: the first power limit is near what the cooler carries
    m.cpu.temp, m.cpu.peak = 45.0, 45.0
    m.first_trim = m.first_cap = None
    m.start()
    m.advance(25, limit_cpu=85)
    r.check(m.first_cap is not None and m.first_cap < watts * 1.05 and m.first_cap > watts * 0.8,
            f"first limit {m.first_cap} W, learned {watts} W (cold start began at {first} W)")
    r.note(f"learned {watts:.0f} W; first limit {first:.0f} W cold, {m.first_cap or 0:.0f} W after learning")
    m.stop()
    m.close()


@scenario
def the_menu_changes_settings_and_saves_them(r):
    import fcntl
    import pty
    import select
    import struct
    import termios
    m = Machine(cpu=Chip(load=10), ec=Ec(), config="# The most each chip may reach.\n# cpu0.max = 85\nfan.exclude = nct6798/pwm1\n")
    # a running service, as runit shows one: its supervisor reads what goes into control
    sv = f"{m.root}/etc/sv/zcool/supervise"
    os.makedirs(sv)
    put(f"{sv}/stat", "run")
    os.mkfifo(f"{sv}/control")
    control = os.open(f"{sv}/control", os.O_RDONLY | os.O_NONBLOCK)
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(ZCOOL, [ZCOOL, "menu", "--root", m.root], m.env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 110, 0, 0))

    def screen(wait=0.8):
        out, end = b"", time.time() + wait
        while time.time() < end:
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                try:
                    out += os.read(fd, 65536)
                except OSError:
                    break
        return out.decode(errors="replace")

    def keys(data, wait=0.5):
        os.write(fd, data)
        return screen(wait)

    out = screen(1.5)
    r.check("Limits" in out and "cpu0" in out and "90 C, the default" in out, out[-600:])
    r.check("nct6798/pwm1" in out and "no, left alone" in out, "the excluded fan should be listed")
    keys(b"\x1b[C")
    out = keys(b"s", 1.0)
    conf = get(f"{m.root}/etc/zcool.conf")
    r.check("cpu0.max = 91" in conf.splitlines(), conf)
    r.check(conf.startswith("# The most each chip may reach.\ncpu0.max = 91\n"), f"the commented line should be taken back: {conf!r}")
    try:
        said = os.read(control, 16)
    except BlockingIOError:
        said = b""
    r.check(said == b"t", f"the service should be told to restart: {said!r}")
    r.check("zcool restarted" in out, out[-300:])
    # the balanced preset, and the excluded fan taken back
    keys(b"2")
    keys(b"\x1b[B" * 12)
    keys(b"\x1b[C")
    keys(b"s", 1.0)
    conf = get(f"{m.root}/etc/zcool.conf")
    c = conf.splitlines()
    r.check("epp.battery = balance_power" in c and "turbo.battery = no" in c and "noise.battery = quiet" in c, conf)
    r.check("mode.ac = comfort" in c and "mode.battery = eco" in c, conf)
    r.check("fan.exclude = nct6798/pwm1" not in c and "# fan.exclude = nct6798/pwm1" in c, conf)
    listed = m.cmd("list").stdout
    r.check("skipped" not in listed, "the daemon should read every line the menu wrote")
    # a change, then q: it asks first; q again leaves without saving
    keys(b"\x1b[C")
    out = keys(b"q")
    r.check("not saved" in out, out[-300:])
    out = keys(b"q", 1.0)
    _, code = os.waitpid(pid, 0)
    r.check(os.WIFEXITED(code) and os.WEXITSTATUS(code) == 0, f"exit {code}")
    r.check("\x1b[?1049l" in out, "the terminal should be given back")
    r.check(get(f"{m.root}/etc/zcool.conf") == conf, "q twice should leave the file as saved")
    os.close(fd)
    os.close(control)
    m.close()


def run_one(fn):
    r = Result()
    try:
        fn(r)
    except Exception as e:
        r.failed.append(f"{type(e).__name__}: {e}")
    return fn.__name__, r.failed, r.notes


def main():
    if os.geteuid() == 0:
        os.setgid(65534)
        os.setuid(65534)
    chosen = [fn for fn in scenarios if not ONLY or ONLY in fn.__name__]
    failed = 0
    with concurrent.futures.ProcessPoolExecutor(max_workers=3) as pool:
        for name, problems, notes in pool.map(run_one, chosen):
            print(f"{'FAIL' if problems else 'ok  '}  {name}", flush=True)
            for note in notes:
                print(f"        {note}", flush=True)
            for problem in problems:
                print(f"     !  {problem}"[:300], flush=True)
            failed += bool(problems)
    print(f"\n{len(chosen) - failed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
