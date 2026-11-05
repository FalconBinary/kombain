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


def put(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(f"{value}\n")


def get(path):
    with open(path) as f:
        return f.read().strip()


class Chip:
    """One chip with a heat load, a thermal mass and a conductance that depends on its fan."""

    def __init__(self, load=0, g_min=0.8, g_max=4.0, mass=25, temp=40, ambient=30):
        self.load, self.g_min, self.g_max, self.mass = load, g_min, g_max, mass
        self.temp, self.ambient = temp, ambient
        self.work = 0.0
        self.time = 0.0
        self.peak = temp
        self.prochot = False
        self.prochot_time = 0.0
        self.over = 0.0
        self.power = 0.0

    def step(self, dt, allowed_power, speed, duty, limit):
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
        g = self.g_min + (self.g_max - self.g_min) * duty / 255
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


class Machine:
    def __init__(self, cpu=None, gpu=None, rapl=True, rapl_enforced=True, rapl_writable=True, freq=True, cpu_fan=True, pump=False, config="",
                 cores=4, nvme_temp=None, bogus_sensor=False):
        self.root = tempfile.mkdtemp(prefix="zcool-")
        self.cpu, self.gpu = cpu, gpu
        self.rapl, self.rapl_enforced, self.cpu_fan, self.pump = rapl, rapl_enforced, cpu_fan, pump
        self.energy = 0.0
        self.freq, self.cores = freq, cores
        self.proc = None
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
        if gpu:
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
        put(f"{r}/etc/zcool.conf", config)
        os.makedirs(f"{r}/var/lib", exist_ok=True)
        self.publish()

    def _write_temp(self, path, value):
        fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o644)
        os.pwrite(fd, f"{int(value * 1000):>8}\n".encode(), 0)
        os.close(fd)

    def _write_energy(self, path, value):
        fd = os.open(path, os.O_WRONLY)
        os.pwrite(fd, f"{int(value):>18}\n".encode(), 0)
        os.close(fd)

    def publish(self):
        if self.cpu:
            self._write_temp(f"{self.cpu_dir}/temp1_input", self.cpu.temp)
            self._write_temp(f"{self.cpu_dir}/temp2_input", self.cpu.temp + 1)
        if self.gpu:
            self._write_temp(f"{self.gpu_dir}/temp1_input", self.gpu.temp)

    def duty(self, directory, index, curve_base):
        pwm, enable = f"{directory}/pwm{index}", f"{directory}/pwm{index}_enable"
        if not os.path.exists(pwm):
            return 0
        if get(enable) != "1":
            # firmware's own curve, deliberately lazy
            temp = self.gpu.temp if directory == self.gpu_dir and self.gpu else (self.cpu.temp if self.cpu else 40)
            duty = min(255, max(curve_base, curve_base + (temp - 50) * 1.5))
            put(pwm, int(duty))
            return duty
        try:
            return int(get(pwm))
        except ValueError:
            return 0

    def advance(self, seconds, limit_cpu=None, limit_gpu=None, tick=0.05):
        end = time.time() + seconds
        last = time.time()
        while time.time() < end:
            time.sleep(tick)
            now = time.time()
            dt, last = now - last, now
            if self.cpu:
                cap = 1e9
                speed = 1.0
                if self.rapl and self.rapl_enforced:
                    try:
                        cap = int(get(self.rapl_path)) / 1e6
                    except ValueError:
                        pass
                if self.freq:
                    try:
                        speed = min(int(get(f"{self.root}/sys/devices/system/cpu/cpufreq/policy{i}/scaling_max_freq")) for i in range(self.cores)) / 5000000
                    except ValueError:
                        pass
                duty = self.duty(self.board_dir, 1, 70) if self.cpu_fan else 0
                if self.pump and get(f"{self.board_dir}/pwm2_enable") != "1":
                    put(f"{self.board_dir}/pwm2", 200)
                self.cpu.step(dt, cap, speed, duty, limit_cpu)
                if self.rapl:
                    self.energy += self.cpu.power * dt * 1e6
                    self._write_energy(f"{self.root}/sys/class/powercap/intel-rapl:0/energy_uj", self.energy)
            if self.gpu:
                cap = 1e9
                try:
                    cap = int(get(f"{self.gpu_dir}/power1_cap")) / 1e6
                except ValueError:
                    pass
                self.gpu.step(dt, cap, 1.0, self.duty(self.gpu_dir, 1, 80), limit_gpu)
                self._write_energy(f"{self.gpu_dir}/power1_average", self.gpu.power * 1e6)
            self.publish()

    def start(self, *args):
        self.logf = open(self.log, "ab")
        self.proc = subprocess.Popen([ZCOOL, "run", "--root", self.root, *args], stdout=self.logf, stderr=subprocess.STDOUT)

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
        return subprocess.run([ZCOOL, *args, "--root", self.root], capture_output=True, text=True, timeout=10)

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
    r.check(get(m.rapl_path) == "300000000", f"power limit touched: {get(m.rapl_path)}")
    r.check(m.cpu.perf > 0.995, f"perf {m.cpu.perf:.3f}")
    r.check(get(f"{m.board_dir}/pwm1_enable") == "1", "fan should be managed")
    r.check("trimming power" not in m.text(), "should not have throttled")
    r.note(f"peak {m.cpu.peak:.1f} C, speed {m.cpu.perf * 100:.1f}%")
    m.stop()
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
    r.check(float(get(m.rapl_path)) < 300e6, "should cap power")
    r.check(swing < 3, f"temperature hunts by {swing:.1f} C")
    r.check(max(temps) <= 86 and min(temps) >= 80, f"settled at {min(temps):.1f}..{max(temps):.1f}, limit 85")
    r.note(f"settled within {swing:.1f} C ({min(temps):.1f}..{max(temps):.1f})")
    r.note(f"peak {m.cpu.peak:.1f} C, settled {m.cpu.temp:.1f} C, speed {m.cpu.perf * 100:.1f}%, cap {int(get(m.rapl_path)) / 1e6:.0f} W")
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
def everything_returns_when_the_load_ends(r):
    m = Machine(cpu=Chip(load=280, g_max=3.4), config=CONFIG)
    m.start()
    m.advance(25, limit_cpu=85)
    r.check(float(get(m.rapl_path)) < 300e6, "should have capped")
    m.cpu.load = 10
    m.advance(40)
    r.check(get(m.rapl_path) == "300000000", f"cap not back: {get(m.rapl_path)}")
    r.check(get(f"{m.board_dir}/pwm1_enable") == "2", "fan not back to firmware")
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
    r.check(float(get(m.rapl_path)) < 300e6, "should have capped first")
    r.check(get(f"{m.board_dir}/pwm1_enable") == "1", "should be manual first")
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
    for _ in range(40):
        m.advance(0.5, limit_cpu=85)
        if get(f"{m.board_dir}/pwm2_enable") == "1":
            lowest = min(lowest, int(get(f"{m.board_dir}/pwm2")))
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
    r.check(get(f"{m.board_dir}/pwm2_enable") == "2", "touched an excluded fan")
    r.check(get(f"{m.board_dir}/pwm1_enable") == "1", "should manage the other one")
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
    r.check(get(f"{m.board_dir}/pwm1_enable") == "2", "a dead 127 C input took the fans")
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
    freq = int(get(f"{m.root}/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq"))
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
    freq = int(get(f"{m.root}/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq"))
    r.check(freq < 5000000, "should limit frequency")
    m.stop()
    m.close()


@scenario
def a_limit_starts_from_real_power_not_the_rating(r):
    # a 300 W rating, a chip drawing 120 W: a cap at 90 percent of the rating would do nothing
    m = Machine(cpu=Chip(load=120, g_min=1.2, g_max=1.2), cpu_fan=False, config=CONFIG)
    m.start()
    m.advance(40, limit_cpu=85)
    cap = int(get(m.rapl_path)) / 1e6
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
    r.check(get(m.rapl_path) == "300000000", "a hot GPU must not throttle the CPU")
    r.check(get(f"{m.board_dir}/pwm1_enable") == "2", "a GPU with its own fan must not spin the case fan")
    r.check(int(get(f"{m.gpu_dir}/power1_cap")) < 200000000, "should cap the GPU")
    r.check(int(get(f"{m.gpu_dir}/power1_cap")) >= 60000000, "cap below the driver minimum")
    r.note(f"gpu at 75: peak {m.gpu.peak:.1f} C, cap {int(get(f'{m.gpu_dir}/power1_cap')) / 1e6:.0f} W; cpu untouched")
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
    r.check(get(f"{m.gpu_dir}/pwm1_enable") == "1", "should be managing the GPU fan")
    # asleep the sensor is frozen at its last hot value, and must not keep the fan up
    put(f"{m.gpu_dir}/device/power/runtime_status", "suspended")
    m.gpu = None
    m.advance(28)
    r.check(get(f"{m.gpu_dir}/pwm1_enable") == "2", "a sleeping GPU kept its fan managed")
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
    r.check(get(f"{m.gpu_dir}/pwm1_enable") == "2", "reacted to a chip that sleeps")
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
