#!/usr/bin/env python3
"""Runs the real ztune binary against a fake /sys, /proc/sys and /proc.

The fake tree holds what the kernel shows: sysfs choices in brackets, sysctl numbers,
processes in /proc/PID/stat. It proves which value ztune sets for each power source and
mode, that it finds games and builds, and that everything goes back however it stops. It
proves nothing about how a real kernel takes these values. Build processes are real
children of this script, so SCHED_BATCH is checked on real processes.
"""
import concurrent.futures
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ZTUNE = os.path.abspath(sys.argv[1])
ONLY = sys.argv[2] if len(sys.argv) > 2 else None
SCHED_OTHER, SCHED_BATCH = 0, 3


def put(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(f"{value}\n")


def get(path):
    with open(path) as f:
        return f.read().strip()


def chosen(text):
    """The word in brackets, as the kernel shows a choice; a file of one word is that word."""
    return text[text.index("[") + 1:text.index("]")] if "[" in text else text


ORIGINAL = {
    "sys/module/pcie_aspm/parameters/policy": "[default] performance powersave powersupersave",
    "proc/sys/kernel/nmi_watchdog": "1",
    "sys/kernel/mm/lru_gen/enabled": "0x0007",
    "sys/kernel/mm/lru_gen/min_ttl_ms": "0",
    "proc/sys/vm/watermark_scale_factor": "10",
    "sys/kernel/mm/transparent_hugepage/enabled": "always [madvise] never",
    "sys/kernel/mm/transparent_hugepage/defrag": "always defer defer+madvise [madvise] never",
    "proc/sys/vm/dirty_writeback_centisecs": "500",
    "proc/sys/vm/dirty_expire_centisecs": "3000",
    "proc/sys/vm/dirty_ratio": "20",
    "proc/sys/vm/dirty_background_ratio": "10",
    "proc/sys/vm/dirty_bytes": "0",
    "proc/sys/vm/dirty_background_bytes": "0",
    # NVMe with the wrong scheduler, a spinning disk, and zram that is left alone
    "sys/block/nvme0n1/queue/scheduler": "none [mq-deadline] kyber bfq",
    "sys/block/nvme0n1/queue/rotational": "0",
    "sys/block/sda/queue/scheduler": "[mq-deadline] kyber bfq none",
    "sys/block/sda/queue/rotational": "1",
    "sys/block/zram0/queue/scheduler": "[none]",
    "sys/block/zram0/queue/rotational": "0",
    "sys/class/power_supply/ADP1/type": "Mains",
    "sys/class/net/wlan0/ifindex": "3",
    # the kernel's last pid: ztune looks at every process only when it moved
    "proc/loadavg": "0.10 0.08 0.05 1/412 449",
}


class Machine:
    def __init__(self, config="", mains=True):
        self.root = tempfile.mkdtemp(prefix="ztune-")
        for path, value in ORIGINAL.items():
            put(f"{self.root}/{path}", value)
        os.makedirs(f"{self.root}/sys/class/net/wlan0/phy80211")
        put(f"{self.root}/sys/class/power_supply/ADP1/online", int(mains))
        put(f"{self.root}/etc/ztune.conf", config)
        self.proc = None
        self.children = []
        self.log = os.path.join(self.root, "log")

    def path(self, rel):
        return f"{self.root}/{rel}"

    def value(self, rel):
        return chosen(get(self.path(rel)))

    def fake(self, pid, comm, ticks=0, start=1000, announce=True):
        """A process as /proc/PID/stat shows it: utime and stime are the 14th and 15th fields,
        the start time the 22nd. A new process moves the kernel's last pid in /proc/loadavg,
        unless the test wants to see what happens when it did not."""
        fields = ["S"] + ["0"] * 10 + [str(ticks), "0"] + ["0"] * 6 + [str(start)] + ["0"] * 5
        put(self.path(f"proc/{pid}/stat"), f"{pid} ({comm}) " + " ".join(fields))
        if announce:
            put(self.path("proc/loadavg"), f"0.10 0.08 0.05 1/412 {pid}")

    def unfake(self, pid):
        shutil.rmtree(self.path(f"proc/{pid}"), ignore_errors=True)

    def child(self):
        """A real process for a build's to stand for: its scheduling policy is real."""
        p = subprocess.Popen(["sleep", "300"])
        self.children.append(p)
        return p.pid

    def start(self, *args):
        self.logf = open(self.log, "ab")
        self.proc = subprocess.Popen([ZTUNE, "run", "--root", self.root, *args], stdout=self.logf, stderr=subprocess.STDOUT)

    def stop(self, sig=signal.SIGTERM):
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(sig)
            self.proc.wait(timeout=10)
        code = self.proc.returncode if self.proc else None
        self.proc = None
        return code

    def text(self):
        self.logf.flush()
        return open(self.log).read()

    def cmd(self, *args, timeout=60):
        return subprocess.run([ZTUNE, *args, "--root", self.root], capture_output=True, text=True, timeout=timeout)

    def close(self):
        if self.proc and self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        for p in self.children:
            p.kill()
            p.wait()
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


def everything_back(r, m, how):
    for rel, value in ORIGINAL.items():
        if rel.startswith("sys/class") or rel.endswith("rotational") or rel.endswith("lru_gen/enabled") or rel == "proc/loadavg":
            continue
        # dirty_bytes is the kernel's to zero when dirty_ratio is written back
        if rel.endswith("dirty_bytes") or rel.endswith("dirty_background_bytes"):
            continue
        r.check(m.value(rel) == chosen(value), f"{how}: {rel} is {m.value(rel)}, was {chosen(value)}")
    r.check(not os.path.exists(m.path("run/ztune/state")), f"{how}: the journal should be gone")


@scenario
def on_mains_the_desktop_and_everything_back(r):
    m = Machine()
    m.start()
    time.sleep(4)
    r.check(m.value("proc/sys/kernel/nmi_watchdog") == "0", "the NMI watchdog should be off")
    r.check(m.value("sys/kernel/mm/lru_gen/min_ttl_ms") == "1000", "MGLRU should keep a second's working set")
    r.check(m.value("proc/sys/vm/watermark_scale_factor") == "125", "kswapd's watermark")
    r.check(m.value("sys/kernel/mm/transparent_hugepage/defrag") == "defer+madvise", "huge page defrag")
    r.check(m.value("sys/kernel/mm/transparent_hugepage/enabled") == "madvise", "huge pages for those that ask")
    r.check(m.value("proc/sys/vm/dirty_writeback_centisecs") == "1500", "writeback every 15 s")
    r.check(m.value("proc/sys/vm/dirty_bytes") == str(256 << 20), f"dirty bytes {m.value('proc/sys/vm/dirty_bytes')}")
    r.check(m.value("proc/sys/vm/dirty_background_bytes") == str(64 << 20), "background dirty bytes")
    r.check(m.value("sys/module/pcie_aspm/parameters/policy") == "default", "ASPM as the firmware has it")
    r.check(m.value("sys/block/nvme0n1/queue/scheduler") == "none", "NVMe without a scheduler")
    r.check(m.value("sys/block/sda/queue/scheduler") == "bfq", "a spinning disk on BFQ")
    r.check(m.value("sys/block/zram0/queue/scheduler") == "none", "zram left alone")
    log = m.text()
    r.check("now: desktop on mains" in log and "sandbox: " in log, log[-400:])
    r.check(m.stop() == 0, "a clean exit")
    everything_back(r, m, "SIGTERM")
    m.close()


@scenario
def on_battery_links_and_disk_sleep_longer(r):
    m = Machine(mains=False)
    m.start()
    time.sleep(4)
    r.check(m.value("sys/module/pcie_aspm/parameters/policy") == "powersupersave", "deep link sleep on battery")
    r.check(m.value("proc/sys/vm/dirty_writeback_centisecs") == "6000", "the disk wakes once a minute on battery")
    r.check(m.value("proc/sys/vm/dirty_expire_centisecs") == "6000", "dirty pages may wait a minute on battery")
    put(m.path("sys/class/power_supply/ADP1/online"), 1)
    time.sleep(4)
    r.check(m.value("sys/module/pcie_aspm/parameters/policy") == "default", "back on mains")
    r.check(m.value("proc/sys/vm/dirty_writeback_centisecs") == "1500", "back on mains, writeback")
    r.check("now: desktop on battery" in m.text() and "now: desktop on mains" in m.text(), m.text()[-400:])
    m.stop()
    m.close()


@scenario
def a_build_runs_as_batch_and_the_desktop_comes_back(r):
    m = Machine()
    pid = m.child()
    m.start()
    time.sleep(4)
    r.check(os.sched_getscheduler(pid) == SCHED_OTHER, "nothing builds yet")
    # cc1 keeps more than a core busy: 120 ticks a second
    ticks = 0
    for _ in range(14):
        ticks += 60
        m.fake(pid, "cc1", ticks)
        time.sleep(0.5)
    log = m.text()
    r.check("now: build on mains, cc1 builds" in log, log[-400:])
    r.check(os.sched_getscheduler(pid) == SCHED_BATCH, f"the compiler should run as SCHED_BATCH, is {os.sched_getscheduler(pid)}")
    r.check(m.value("sys/kernel/mm/transparent_hugepage/enabled") == "always", "huge pages for a build")
    r.check(m.value("proc/sys/vm/dirty_bytes") == str(1024 << 20), "more may wait to be written in a build")
    # the build pauses: it stays a build for 15 s, then the desktop comes back
    time.sleep(6)
    r.check("now: desktop" not in m.text().split("now: build")[-1], "a pause is not the end of a build")
    time.sleep(16)
    log = m.text()
    r.check("now: desktop on mains" in log.split("now: build")[-1], log[-400:])
    r.check(os.sched_getscheduler(pid) == SCHED_OTHER, "the compiler back to SCHED_OTHER")
    r.check(m.value("sys/kernel/mm/transparent_hugepage/enabled") == "madvise", "huge pages back for those that ask")
    m.stop()
    m.close()


@scenario
def stopped_in_a_build_the_compiler_gets_its_scheduling_back(r):
    m = Machine()
    pid = m.child()
    m.start()
    ticks = 0
    for _ in range(14):
        ticks += 60
        m.fake(pid, "rustc", ticks)
        time.sleep(0.5)
    r.check(os.sched_getscheduler(pid) == SCHED_BATCH, "rustc should run as SCHED_BATCH")
    m.stop()
    r.check(os.sched_getscheduler(pid) == SCHED_OTHER, "back to SCHED_OTHER when ztune stops")
    everything_back(r, m, "SIGTERM in a build")
    m.close()


@scenario
def a_game_gets_links_awake_on_battery_too(r):
    m = Machine(mains=False)
    m.fake(4000, "gamescope")
    m.start()
    time.sleep(4)
    log = m.text()
    r.check("now: game on battery, gamescope runs" in log, log[-400:])
    r.check(m.value("sys/module/pcie_aspm/parameters/policy") == "performance", "links never asleep in a game")
    r.check(m.value("proc/sys/vm/dirty_writeback_centisecs") == "1500", "writeback as on mains in a game")
    m.unfake(4000)
    m.fake(4001, "Witcher3.exe")
    time.sleep(4)
    r.check(m.value("sys/module/pcie_aspm/parameters/policy") == "performance", "a Wine game is a game")
    m.unfake(4001)
    time.sleep(4)
    r.check(m.value("sys/module/pcie_aspm/parameters/policy") == "powersupersave", "the game is over")
    m.stop()
    m.close()


@scenario
def processes_are_looked_at_only_when_a_pid_was_handed_out(r):
    m = Machine(mains=False)
    m.start()
    time.sleep(4)
    # a game appears without the kernel's last pid moving: ztune has no reason to look yet
    m.fake(4000, "gamescope", announce=False)
    time.sleep(7)
    r.check("now: game" not in m.text(), "no new pid, no look at the processes")
    # the pid moves: the next look finds it
    put(m.path("proc/loadavg"), "0.10 0.08 0.05 1/412 4000")
    time.sleep(4)
    r.check("now: game on battery, gamescope runs" in m.text(), m.text()[-300:])
    # in a game nothing new has to start for ztune to notice its end
    m.unfake(4000)
    time.sleep(4)
    r.check("now: desktop on battery" in m.text().split("now: game")[-1], m.text()[-300:])
    m.stop()
    m.close()


@scenario
def kill_nine_is_undone_by_restore(r):
    m = Machine(mains=False)
    m.start()
    time.sleep(4)
    m.stop(signal.SIGKILL)
    r.check(m.value("proc/sys/kernel/nmi_watchdog") == "0", "kill -9 cannot put anything back by itself")
    out = m.cmd("restore")
    r.check("restored" in out.stdout, out.stdout)
    everything_back(r, m, "kill -9 and restore")
    # and the next start does it too
    m.start()
    time.sleep(1)
    m.stop(signal.SIGKILL)
    m.start()
    time.sleep(2)
    r.check("left by an earlier run" in m.text(), m.text()[-300:])
    m.stop()
    everything_back(r, m, "kill -9 and the next start")
    m.close()


@scenario
def the_config_leaves_alone_what_it_says(r):
    m = Machine(config="aspm = no\nnmi_watchdog = no\nmemory = no\ngame = no\ngame.add = mygame\n", mains=False)
    m.fake(4000, "gamescope")
    m.start()
    time.sleep(4)
    r.check(m.value("sys/module/pcie_aspm/parameters/policy") == "default", "aspm = no")
    r.check(m.value("proc/sys/kernel/nmi_watchdog") == "1", "nmi_watchdog = no")
    r.check(m.value("sys/kernel/mm/lru_gen/min_ttl_ms") == "0", "memory = no")
    r.check("now: desktop on battery" in m.text(), "game = no: a game runs and it is still the desktop")
    r.check(m.value("proc/sys/vm/dirty_writeback_centisecs") == "6000", "the disk is still its own")
    m.stop()
    m.close()


@scenario
def check_says_what_it_would_set_and_why(r):
    m = Machine(mains=False)
    out = m.cmd("check").stdout
    r.check("ztune: desktop on battery" in out, out)
    r.check("pcie link power" in out and "-> powersupersave" in out and "links sleep deep on battery" in out, out)
    r.check("nvme0n1 scheduler" in out and "-> none" in out, out)
    r.check("not calibrated" in out, out)
    # it changed nothing
    r.check(m.value("sys/module/pcie_aspm/parameters/policy") == "default", "check must change nothing")
    m.close()


@scenario
def a_dry_run_changes_nothing(r):
    m = Machine(mains=False)
    before = {rel: get(m.path(rel)) for rel in ORIGINAL}
    m.start("--dry-run")
    time.sleep(4)
    after = {rel: get(m.path(rel)) for rel in ORIGINAL}
    r.check(before == after, "a dry run wrote something")
    r.check("would set powersupersave" in m.text(), m.text()[-400:])
    r.check(not os.path.exists(m.path("run/ztune/state")), "a dry run wrote a journal")
    m.stop()
    m.close()


@scenario
def calibration_finds_the_jobs_and_writes_them_for_shells(r):
    m = Machine()
    out = m.cmd("calibrate", timeout=200)
    r.check(out.returncode == 0, out.stdout + out.stderr)
    jobs = get(m.path("var/lib/ztune/jobs")) if os.path.exists(m.path("var/lib/ztune/jobs")) else ""
    cpus = len(os.sched_getaffinity(0))
    cores = physical_cores(cpus)
    r.check(jobs.isdigit() and cores <= int(jobs) <= cpus, f"jobs {jobs!r} on {cpus} CPUs, {cores} cores")
    r.check(" rounds/s" in out.stdout and "fastest with the fewest jobs" in out.stdout, out.stdout)
    script = get(m.path("etc/profile.d/ztune.sh")) if os.path.exists(m.path("etc/profile.d/ztune.sh")) else ""
    r.check(f': "${{MAKEFLAGS:=-j{jobs}}}"' in script, script)
    # a shell reads it, and a value set before wins
    sh = subprocess.run(["sh", "-c", f". {m.path('etc/profile.d/ztune.sh')}; echo $MAKEFLAGS $CARGO_BUILD_JOBS"],
                        capture_output=True, text=True, env=dict(os.environ, CARGO_BUILD_JOBS="3"))
    r.check(sh.stdout.split() == [f"-j{jobs}", "3"], sh.stdout)
    r.note(out.stdout.strip().replace("\n", " | "))
    # jobs set by hand: written as it is, nothing measured
    m2 = Machine(config="jobs = 8\n")
    out = m2.cmd("calibrate")
    r.check(get(m2.path("var/lib/ztune/jobs")) == "8" and "-j8" in get(m2.path("etc/profile.d/ztune.sh")), out.stdout)
    out = m2.cmd("check").stdout
    r.check("builds run 8 jobs" in out, out)
    m2.close()
    m.close()


def physical_cores(cpus):
    """CPUs that head their core's sibling list, as ztune counts them."""
    cores = 0
    for i in range(cpus):
        try:
            with open(f"/sys/devices/system/cpu/cpu{i}/topology/thread_siblings_list") as f:
                head = f.read().replace("-", ",").split(",")[0].strip()
        except OSError:
            return max(cpus // 2, 1)
        cores += int(head) == i
    return cores or max(cpus // 2, 1)


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
    chosen_ones = [fn for fn in scenarios if not ONLY or ONLY in fn.__name__]
    failed = 0
    with concurrent.futures.ProcessPoolExecutor(max_workers=3) as pool:
        for name, problems, notes in pool.map(run_one, chosen_ones):
            print(f"{'FAIL' if problems else 'ok  '}  {name}", flush=True)
            for note in notes:
                print(f"        {note}", flush=True)
            for problem in problems:
                print(f"     !  {problem}"[:300], flush=True)
            failed += bool(problems)
    print(f"\n{len(chosen_ones) - failed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
