#!/usr/bin/env python3
"""Installs Void Linux in a VM with the commands from docs/void-install-guide.md, then checks it.

The script types the guide's own bash blocks into a serial console, as a person would,
answering the prompts for LUKS passphrases and passwords. It then boots both modes and
checks what the guide promises. A disk is emulated as NVMe so its device names match the guide.

Test-only differences from a real install, all marked `test only` below: a serial console so
this script can see the machine, `sfdisk` instead of `cfdisk`, and a stable network name.

  python3 tests/vm/install.py --iso void-live-x86_64-20250202-base.iso --stage all

With --flow setup it installs through setup.sh instead, answering its questions like a person,
with wrong answers first, on a disk with other device names, and then makes the same checks
plus the sizes and names it was given:

  python3 tests/vm/install.py --iso ... --flow setup --disk-bus virtio --disk-size 200G

With --flow stock it installs plain Void instead (base-system, with what void-installer enables),
only to measure it: the numbers the rest are compared to. Every flow measures what the machine uses
while nothing is happening: see MEASURE.
"""
import argparse
import os
import re
import socket
import struct
import subprocess
import sys
import threading
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
GUIDE = os.path.join(HERE, "..", "..", "docs", "void-install-guide.md")

LIVE_ARGS = (
    "root=live:CDLABEL=VOID_LIVE ro init=/sbin/init rd.luks=0 rd.md=0 rd.dm=0 loglevel=4 gpt add_efi_memmap "
    "vconsole.unicode=1 vconsole.keymap=us locale.LANG=en_US.UTF-8 rd.live.overlay.overlayfs=1 "
    "console=tty0 console=ttyS0,115200"
)
# None of these protect anything: they exist only inside this throwaway VM.
ROOT_PASSPHRASE = "test-root-passphrase"
DEV_PASSPHRASE = "test-dev-passphrase"
PASSWORD = "test-password"
PROMPT = "KOMBAIN# "
# What the setup.sh run answers.
SETUP_USER = "alice"
SETUP_ROOT_MIB = 40 * 1024
SETUP_GAMER_MIB = 60 * 1024
SETUP_DEV_MIB = 90 * 1024
SETUP_HOST = "kombain-vm"
SETUP_ZONE = "Europe/Berlin"

SYSCTL_SETTINGS = sum(1 for line in open(os.path.join(HERE, "..", "..", "config", "sysctl.conf")) if re.match(r"[a-z]", line))

# Firmware that can enforce Secure Boot, starting in setup mode: no keys until step 12 enrolls them.
SECURE_FIRMWARE = ("/usr/share/OVMF/OVMF_CODE_4M.secboot.fd", "/usr/share/OVMF/OVMF_VARS_4M.fd")
WIFI_SSID = "kombain-wifi"
WIFI_PASSPHRASE = "test-wifi-passphrase"

FIRMWARE = [
    ("/usr/share/OVMF/OVMF_CODE_4M.fd", "/usr/share/OVMF/OVMF_VARS_4M.fd"),
    ("/usr/share/OVMF/OVMF_CODE.fd", "/usr/share/OVMF/OVMF_VARS.fd"),
    ("/opt/homebrew/share/qemu/edk2-x86_64-code.fd", "/opt/homebrew/share/qemu/edk2-i386-vars.fd"),
]


# What an idle machine uses. It says nothing about the speed of real work, and a VM has no real
# GPU, Wi-Fi or sensors, but the difference between two installs on the same VM is real.
MEASURE = r"""
disk=$(lsblk -dnpo NAME,TYPE | awk '$2=="disk" {print $1; exit}')
dev=${disk##*/}
stat_line() { awk -v d="$dev" '/^cpu / {busy=$2+$3+$4+$7+$8+$9; all=busy+$5+$6} /^ctxt/ {c=$2} /^intr/ {i=$2} END {print busy, all, c, i}' /proc/stat; }
written() { awk -v d="$dev" '$3==d {print $10}' /proc/diskstats; }
a=$(stat_line); wa=$(written)
sleep 30
b=$(stat_line); wb=$(written)
echo "$a $b" | awk '{printf "metric cpu_busy_pct %.2f\nmetric context_switches_per_s %.0f\nmetric interrupts_per_s %.0f\n", ($5-$1)*100/($6-$2), ($7-$3)/30, ($8-$4)/30}'
echo "metric disk_written_kib_30s $(( (wb-wa)/2 ))"
sync; echo 3 > /proc/sys/vm/drop_caches
awk '/^MemTotal/ {t=$2} /^MemAvailable/ {a=$2} /^Shmem:/ {s=$2} /^Slab:/ {l=$2} /^Buffers/ {b=$2} /^Cached/ {c=$2} /^KernelStack/ {k=$2} /^PageTables/ {p=$2}
 END {printf "metric mem_used_mib %d\nmetric mem_cached_mib %d\nmetric mem_shmem_mib %d\nmetric mem_slab_mib %d\nmetric mem_kernel_stacks_tables_mib %d\n", (t-a)/1024, (b+c)/1024, s/1024, l/1024, (k+p)/1024}' /proc/meminfo
ps -eo ppid=,pid=,rss= | awk '$1!=2 && $2!=2 {n++; r+=$3} END {printf "metric processes %d\nmetric rss_sum_mib %d\n", n, r/1024}'
echo "metric root_content_mib $(du -sxm / | cut -f1)"
for d in /usr/lib/firmware /usr/lib/modules /usr/share/locale /usr/lib/locale /usr/share/doc /usr/share/man /usr/share/icons /var/cache/xbps /usr/lib/gcc /usr/include; do
 [ -d "$d" ] && echo "metric du$(echo "$d" | tr / _)_mib $(du -sxm "$d" | cut -f1)"
done
echo "metric packages $(xbps-query -l | wc -l)"
echo "--- largest processes (RSS KiB)"
ps -eo rss=,comm= --sort=-rss | awk '$1>0' | head -24
echo "--- services"
ls /etc/runit/runsvdir/current/ | tr '\n' ' '
echo
"""

# Test only, for one boot: a kernel log line before each step of runit's stage 1, so the log times them.
BOOT_MARKS = r"""
[ -e /etc/runit/1.timeless ] || cp -p /etc/runit/1 /etc/runit/1.timeless
cp -p /etc/runit/1.timeless /etc/runit/1
sed -i '/\. "\{0,1\}\$f/i echo "kombain-boot $f" >/dev/kmsg 2>/dev/null' /etc/runit/1
echo 'echo "kombain-boot end" >/dev/kmsg 2>/dev/null' >> /etc/runit/1
grep -c kombain-boot /etc/runit/1
"""

# Times since the kernel started: kernel log lines, and when each process started. Then what the
# initramfs holds, and the modules Void's stage 1 loads for their fixed device files. No tabs: the
# serial console's bash would take them for completion.
BOOT_TIMELINE = r"""
echo "hz $(getconf CLK_TCK)"
dmesg | sed -nE 's/^\[ *([0-9]+\.[0-9]+)\] (Run \/init as init process|kombain-boot .*|XFS \(.*\): Ending clean mount|Freeing unused kernel image.*|raid6: .*|xor: .*)$/mark \1 \2/p'
for p in /proc/[0-9]*; do
 c=$(tr '\0' ' ' <$p/cmdline 2>/dev/null | cut -c1-70)
 [ -n "$c" ] || continue
 echo "proc $(sed 's/.*) //' $p/stat | cut -d' ' -f20) $(cat $p/comm) $c"
done | sort -k2,2n
for f in /sys/firmware/acpi/fpdt/boot/*_ns; do [ -r "$f" ] && echo "fpdt ${f##*/} $(cat $f)"; done
ls -l /boot | awk '/vmlinuz|initramfs/ {printf "file %s %d KiB\n", $NF, $5 / 1024}'
img=$(ls /boot/initramfs-*.img | head -n 1)
echo "initramfs magic $(/usr/lib/dracut/skipcpio $img 2>/dev/null | head -c 4 | od -An -tx1 | tr -d ' ')"
lsinitrd $img 2>/dev/null | grep -m1 '^Arguments:' | sed 's/^/initramfs /'
lsinitrd -m $img 2>/dev/null | awk '/^dracut modules:/ {on = 1; next} /^=+$/ {on = 0} on {printf "%s ", $0} END {print ""}' | sed 's/^/initramfs dracut /'
lsinitrd $img 2>/dev/null | awk '$1 ~ /^-/ && $5 ~ /^[0-9]+$/ {t += $5; n++} END {printf "initramfs total %d files, %d KiB unpacked\n", n, t / 1024}'
lsinitrd $img 2>/dev/null | awk '$1 ~ /^-/ && $5 ~ /^[0-9]+$/ {split($9, p, "/"); s[p[1] "/" p[2] "/" p[3] "/" p[4]] += $5} END {for (d in s) printf "%d %s\n", s[d] / 1024, d}' | sort -rn | head -n 12 | sed 's/^/initramfs dir KiB /'
lsinitrd $img 2>/dev/null | awk '$1 ~ /^-/ && $5 ~ /^[0-9]+$/ {print int($5 / 1024), $9}' | sort -rn | head -n 12 | sed 's/^/initramfs file KiB /'
kmod static-nodes -f devname 2>/dev/null | while read -r m n s; do
 u=$(echo $m | tr - _)
 echo "static $m /dev/$n $(awk -v m=$u '$1 == m {print $2 " bytes, used by " $3}' /proc/modules)"
done
for d in $(blkid -t TYPE=crypto_LUKS -o device); do
 echo "luks $d $(cryptsetup luksDump $d | awk '/PBKDF:/ {k=$2} /Time cost:/ {t=$3} /Memory:/ {m=$2} /Threads:/ {n=$2} END {print k, "time=" t, "memory_kib=" m, "threads=" n}')"
done
"""

# What each module Void's stage 1 loads for a fixed device file costs: unloaded, then loaded again, timed.
STATIC_COST = r"""
for m in $(kmod static-nodes -f devname 2>/dev/null | cut -d' ' -f1 | sort -u); do
 u=$(echo $m | tr - _)
 grep -q "^$u " /proc/modules || { echo "cost $m not loaded"; continue; }
 modprobe -r $m 2>/dev/null || { echo "cost $m in use"; continue; }
 a=$(date +%s%N); modprobe -b $m; b=$(date +%s%N)
 echo "cost $m $(( (b - a) / 1000000 )) ms"
done
dmesg | grep -E 'raid6|xor' | tail -n 6
"""


class Failed(Exception):
    pass


class VM:
    """QEMU with its serial port on a pipe, plus a small expect."""

    def __init__(self, args, log_path):
        self.log = open(log_path, "ab")
        self.proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.buf = ""
        self.pos = 0
        self.lock = threading.Lock()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        while True:
            data = os.read(self.proc.stdout.fileno(), 65536)
            if not data:
                return
            self.log.write(data)
            self.log.flush()
            with self.lock:
                self.buf += data.decode("utf-8", "replace")

    def send(self, text):
        data = text.encode()
        for i in range(0, len(data), 128):
            self.proc.stdin.write(data[i:i + 128])
            self.proc.stdin.flush()
            time.sleep(0.02)

    def wait(self, patterns, timeout):
        """Returns (index of the pattern that matched, match) and moves past it."""
        compiled = [re.compile(p) for p in patterns]
        end = time.time() + timeout
        while time.time() < end:
            with self.lock:
                text = self.buf[self.pos:]
                best = None
                for index, pattern in enumerate(compiled):
                    m = pattern.search(text)
                    if m and (best is None or m.start() < best[1].start()):
                        best = (index, m)
                if best:
                    self.pos += best[1].end()
                    return best
            if self.proc.poll() is not None and not self.reader.is_alive():
                raise Failed(f"the VM exited while waiting for {patterns}\n{self.tail()}")
            time.sleep(0.1)
        raise Failed(f"timed out after {timeout} s waiting for {patterns}\n{self.tail()}")

    def tail(self, chars=1500):
        with self.lock:
            return re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", self.buf[-chars:])

    def wait_exit(self, timeout):
        self.proc.wait(timeout=timeout)
        self.reader.join(timeout=5)

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()


def guide_blocks():
    blocks, body, inside = [], [], False
    for line in open(GUIDE, encoding="utf-8").read().splitlines():
        if line == "```bash":
            inside, body = True, []
        elif line == "```" and inside:
            inside = False
            blocks.append("\n".join(body))
        elif inside:
            body.append(line)
    return blocks


def block(start):
    """The guide's block whose first line starts like this. A rewritten guide fails here, on purpose."""
    found = [b for b in guide_blocks() if b.startswith(start)]
    if len(found) != 1:
        raise Failed(f"expected one guide block starting with {start!r}, found {len(found)}")
    # Before the locale exists, bash takes these bytes for Meta keys and eats the next line.
    if not found[0].isascii():
        raise Failed(f"the guide block starting with {start!r} must be plain ASCII")
    return found[0]


class Run:
    def __init__(self, opts):
        self.o = opts
        self.results = []
        self.vm = None
        self.luks = {}
        os.makedirs(opts.work, exist_ok=True)
        self.disk = os.path.join(opts.work, "disk.qcow2")
        self.vars = os.path.join(opts.work, "vars.fd")
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            self.monitor = probe.getsockname()[1]
        self.log_path = os.path.join(opts.work, "serial.log")
        self.user = SETUP_USER if opts.flow == "setup" else "dev"
        self.disk_dev = "/dev/vda" if opts.disk_bus == "virtio" else "/dev/nvme0n1"
        self.setup_output = ""
        self.metrics = {}
        self.boot_times = {}
        self.live_radio = False

    def part(self, n):
        return f"{self.disk_dev}{'p' if self.disk_dev[-1].isdigit() else ''}{n}"

    # ------------------------------------------------------------ machine

    def firmware(self):
        if self.o.secure_boot:
            if not all(os.path.exists(f) for f in SECURE_FIRMWARE):
                raise Failed("no Secure Boot firmware found")
            return SECURE_FIRMWARE
        for code, varsfile in FIRMWARE:
            if os.path.exists(code) and os.path.exists(varsfile):
                return code, varsfile
        raise Failed("no UEFI firmware found")

    def qemu(self, live):
        code, varsfile = self.firmware()
        if not os.path.exists(self.vars):
            with open(varsfile, "rb") as src, open(self.vars, "wb") as dst:
                dst.write(src.read())
        if not os.path.exists(self.disk):
            subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", self.disk, self.o.disk_size], check=True)
        kvm = os.access("/dev/kvm", os.R_OK | os.W_OK)
        args = [
            "qemu-system-x86_64", "-machine", "q35,vmport=off" + (",smm=on" if self.o.secure_boot else ""), "-m", str(self.o.memory), "-smp", str(self.o.cpus),
            "-accel", "kvm" if kvm else "tcg", "-cpu", "host" if kvm else "max",
            "-display", "none", "-serial", "stdio", "-no-reboot",
            "-monitor", f"tcp:127.0.0.1:{self.monitor},server=on,wait=off",
            "-drive", f"if=pflash,format=raw,readonly=on,file={code}",
            "-drive", f"if=pflash,format=raw,file={self.vars}",
            "-drive", f"file={self.disk},if=none,id=disk0,format=qcow2,discard=unmap",
            "-device", "nvme,drive=disk0,serial=kombain" if self.o.disk_bus == "nvme" else "virtio-blk-pci,drive=disk0",
            "-device", "virtio-vga",
            "-nic", "user,model=virtio-net-pci",
            "-device", "virtio-rng-pci",
        ]
        if self.o.secure_boot:
            # the firmware's variables, keys among them, must be out of the guest's reach outside SMM
            args += ["-global", "driver=cfi.pflash01,property=secure,value=on"]
        if live:
            kernel, initrd = self.extract_boot()
            args += ["-kernel", kernel, "-initrd", initrd, "-append", LIVE_ARGS, "-cdrom", self.o.iso]
        self.vm = VM(args, self.log_path)
        print(f"VM started ({'kvm' if kvm else 'tcg'}, {'live ISO' if live else 'installed disk'})", flush=True)

    def extract_boot(self):
        out = os.path.join(self.o.work, "boot")
        kernel, initrd = os.path.join(out, "vmlinuz"), os.path.join(out, "initrd")
        if not os.path.exists(kernel):
            os.makedirs(self.o.work, exist_ok=True)
            subprocess.run(["bsdtar" if subprocess.run(["which", "bsdtar"], capture_output=True).returncode == 0 else "tar",
                            "-xf", self.o.iso, "-C", self.o.work, "boot/vmlinuz", "boot/initrd"], check=True)
        return kernel, initrd

    def monitor_cmd(self, command):
        s = socket.create_connection(("127.0.0.1", self.monitor))
        s.settimeout(5)
        try:
            s.recv(4096)
            s.sendall(command.encode() + b"\n")
            time.sleep(1)
            s.recv(65536)
        finally:
            s.close()

    def screenshot(self, name):
        ppm = os.path.join(self.o.work, name + ".ppm")
        self.monitor_cmd(f"screendump {ppm}")
        time.sleep(1)
        png = os.path.join(self.o.work, name + ".png")
        rows = write_png(ppm, png)
        os.unlink(ppm)
        print(f"screenshot: {png}", flush=True)
        return rows

    # ------------------------------------------------------------ shell

    def answer(self, text, m):
        """Answers what a person would type at a prompt."""
        if re.search(r"\[Y/n\]", text):
            return "y\n"
        if "capital letters" in text:
            return "YES\n"
        if "password:" in text.lower():
            return PASSWORD + "\n"
        return None

    def login(self, timeout):
        index, _ = self.vm.wait([r"login: ", r"[#$] $"], timeout)
        if index == 0:
            self.vm.send("root\n")
            self.vm.wait([r"Password: "], 60)
            self.vm.send(self.o.root_password + "\n")
        self.adopt_shell()

    def adopt_shell(self):
        time.sleep(1)
        self.vm.send(f"export PS1='{PROMPT}' TERM=dumb PAGER=cat GIT_PAGER=cat; stty cols 200; echo ADOPT$((40+2))\n")
        self.vm.wait([r"ADOPT42"], 120)
        self.vm.wait([re.escape(PROMPT)], 60)

    def sh(self, text, timeout=900, check=True, what=None):
        """Runs a block in a subshell with `set -e`, so a failure anywhere in it is seen. Returns its output."""
        vm = self.vm
        if self.user != "dev":  # the same checks for another user's name
            text = text.replace("su - dev", f"su - {self.user}").replace("/home/dev", f"/home/{self.user}").replace("--autologin dev", f"--autologin {self.user}")
        marker = f"K{int(time.time() * 1000)}"
        vm.send(f"cat > /tmp/step <<'{marker}'\n{text}\n{marker}\n")
        vm.wait([re.escape(PROMPT)], 120)
        vm.send(f"( set -e; DISK={self.disk_dev}; . /tmp/step ) 2>&1; echo \"{marker}=$((0+$?))=\"\n")
        # move past the echo of the command itself: the shell prints a literal $? in it
        vm.wait([re.escape(f'{marker}=$((0+$?))=') + r'"\r?\n'], 60)
        start = vm.pos
        patterns = [rf"{marker}=(\d+)=", r"\[Y/n\]", r"capital letters\):", r"[Ee]nter passphrase for ([^:\s]+):",
                    r"Verify passphrase:", r"(New|Retype new) password:"]
        last_passphrase = ROOT_PASSPHRASE
        while True:
            index, m = vm.wait(patterns, timeout)
            if index == 0:
                output = vm.buf[start:vm.pos - len(m.group(0))]
                rc = int(m.group(1))
                vm.wait([re.escape(PROMPT)], 60)
                if rc != 0 and check:
                    raise Failed(f"{what or text.splitlines()[0]} failed with {rc}\n{clean(output)[-1500:]}")
                return clean(output)
            if index == 1:
                vm.send("y\n")
            elif index == 2:
                vm.send("YES\n")
            elif index == 3:
                last_passphrase = DEV_PASSPHRASE if m.group(1).endswith("p3") else ROOT_PASSPHRASE
                vm.send(last_passphrase + "\n")
            elif index == 4:
                vm.send(last_passphrase + "\n")
            else:
                vm.send(PASSWORD + "\n")

    def out(self, command):
        return self.sh(command, check=False, timeout=120).strip()

    def expect(self, name, ok, detail=""):
        self.results.append((bool(ok), name, str(detail)[:300]))
        print(f"{'ok  ' if ok else 'FAIL'}  {name}" + (f"  [{str(detail)[:160]}]" if not ok else ""), flush=True)

    # ------------------------------------------------------------ the guide

    def boot_live(self):
        self.qemu(live=True)
        self.o.root_password = "voidlinux"
        self.login(self.o.boot_timeout)
        self.expect("the live ISO boots to a shell over serial", True)
        print(self.out("uname -m; uname -r; cat /sys/class/net/*/operstate | tr '\\n' ' '; ls /sys/firmware/efi >/dev/null && echo uefi; lsblk -d -o NAME,SIZE | tail -3"), flush=True)
        self.expect("the live ISO has a working network", self.wait_network())

    def wait_network(self, seconds=90):
        """Real name resolution: xbps-install -S exits 0 without a network. Says why when it fails."""
        start = time.time()
        while time.time() - start < seconds:
            if "net-yes" in self.out("getent hosts github.com >/dev/null && echo net-yes || echo net-no"):
                print(f"network ready after {time.time() - start:.0f} s", flush=True)
                return True
            time.sleep(3)
        print(self.out("ls -l /etc/resolv.conf; cat /etc/resolv.conf; ip -br addr; ip route; for s in dhcpcd dhcpcd-eth0; do sv status /etc/sv/$s 2>&1; done; "
                       "ps -eo comm | grep -E 'dhcpcd|iwd|resolvconf' | sort -u; ls /etc/runit/runsvdir/current/ | tr '\\n' ' '; nft list ruleset | head -30"), flush=True)
        return False

    def install(self):
        self.sh(block("sv down sshd"))
        # Wi-Fi lines skipped: this VM is wired
        self.sh("xbps-install -Sy xbps", what="guide step 1: update xbps")

        # test only: cfdisk is interactive; this makes the same three partitions
        step2 = block("DISK=/dev/nvme0n1\ncfdisk")
        step2 = step2.replace('cfdisk -z "$DISK"', "printf 'label: gpt\\nsize=1G, type=U\\nsize=520G, type=L\\ntype=L\\n' | sfdisk \"$DISK\"")
        self.sh(step2, what="guide step 2: disk")

        step3 = block("REPO=https://").splitlines()
        if step3[-1] != "xchroot /mnt /bin/bash":
            raise Failed("guide step 3 no longer ends by entering the chroot")
        self.sh("\n".join(step3[:-1]), timeout=2400, what="guide step 3: base system")
        self.vm.send("xchroot /mnt /bin/bash\n")
        self.adopt_shell()
        self.expect("guide step 3: base system installed, chroot entered", "base-system" in self.out("xbps-query -l | grep -o 'base-system' | head -1"))

        self.sh(block("DISK=/dev/nvme0n1\necho voidbox"), timeout=1200, what="guide step 4: system settings")
        self.sh(block("xbps-install -y mesa-dri").splitlines()[0], timeout=1200, what="guide step 4: graphics driver")
        self.sh(block("cat > /etc/fstab"), what="guide step 4: fstab")
        self.sh('sed -i "s/XXXX-XXXX/$(blkid -s UUID -o value "${DISK}p1")/" /etc/fstab')
        self.sh(block("mkdir -p /etc/dracut.conf.d"), what="guide step 4: dracut")

        hook = block("mkdir -p /etc/kernel.d/post-install")
        # test only: lets this script see the boot, and gives the wired interface a known name
        console = "console=tty0 console=ttyS0,115200 net.ifnames=0"
        if "rw quiet loglevel=3" not in hook:
            raise Failed("guide step 5 changed the kernel command line")
        hook = hook.replace("rw quiet loglevel=3", f"rw quiet loglevel=3 {console}")
        self.sh(hook, what="guide step 5: Limine")

        self.sh(block("mkdir -p /etc/iwd"), what="guide step 6: iwd")
        self.sh(block("IF=enp3s0").replace("IF=enp3s0", "IF=eth1"), what="guide step 6: wired service")
        self.sh(block("mkdir -p /etc/sysctl.d"), what="guide step 7: sysctl")
        self.sh(block("cat > /etc/nftables.conf"), what="guide step 7: firewall and boot services")
        self.sh(block("cat > /etc/modprobe.d/kombain.conf"), what="guide step 7: power saving and unused modules")
        self.sh(block("mkdir -p /etc/sv/game-tune"), what="guide step 8: runlevels")
        # test only: a login for this script, and the wired network the VM has instead of Wi-Fi
        self.sh("for r in default gaming; do ln -sfn /etc/sv/agetty-ttyS0 /etc/runit/runsvdir/$r/; ln -sfn /etc/sv/dhcpcd-eth0 /etc/runit/runsvdir/$r/; done")
        self.sh(block("useradd -m -G wheel"), what="guide step 9: users and sessions")
        self.sh(block("xbps-reconfigure -fa"), timeout=1200, what="guide step 10: initramfs and Limine config")

        conf = self.out("cat /boot/limine.conf")
        entries = re.split(r"^/", conf, flags=re.M)[1:]
        dev = next((e for e in entries if e.startswith("Void Dev\n")), "")
        gaming = next((e for e in entries if e.startswith("Void Gaming\n")), "")
        self.expect("Limine: placeholders are gone", "ROOT-UUID" not in conf and "DEV-UUID" not in conf, conf[:200])
        self.expect("Limine: Dev unlocks two volumes", dev.count("rd.luks.uuid=") == 2, dev[:300])
        self.expect("Limine: Gaming unlocks one", gaming.count("rd.luks.uuid=") == 1 and " gaming " in gaming, gaming[:300])
        self.expect("kernel and initramfs are on the ESP", "vmlinuz" in self.out("ls /boot") and "initramfs" in self.out("ls /boot"))
        self.expect("Limine is in the UEFI boot order", "Limine" in self.out("efibootmgr"))
        self.luks = {
            "root": self.out('blkid -s UUID -o value "${DISK}p2"').splitlines()[-1],
            "dev": self.out('blkid -s UUID -o value "${DISK}p3"').splitlines()[-1],
        }

        self.vm.send("exit\n")
        self.adopt_shell()
        last = [l for l in block("exit\n").splitlines() if not l.startswith("#")]
        if last[0] != "exit" or last[-1] != "reboot":
            raise Failed("the guide's step 11 block changed")
        self.sh("\n".join(last[1:-1]), what="guide step 11: leaving the new system")
        self.vm.send(last[-1] + "\n")
        self.vm.wait_exit(180)
        self.vm = None
        self.expect("guide steps 1 to 11: installed and rebooted", True)

    def install_with_setup(self):
        """setup.sh from the live ISO, answering like a person, including the mistakes people make."""
        lines = block("xbps-install -Sy xbps git").splitlines()
        if lines[-1] != "./setup.sh":
            raise Failed("the guide's setup.sh block changed")
        self.sh(lines[0], what="guide: tools for setup.sh")
        # test only: a radio, so setup.sh asks for a Wi-Fi network and saves it for the installed system.
        # virt_wifi puts a wireless device on top of the wired one, and a wireless device is all setup.sh
        # looks for; nothing connects through it here, so the wired network goes on working.
        radio = self.out("modprobe virt_wifi && for d in /sys/class/net/*; do [ -e $d/device ] && ip link add link ${d##*/} name wlan0 type virt_wifi && break; done; "
                         "[ -e /sys/class/net/wlan0/wireless ] && echo radio-ready; true")
        self.live_radio = radio.splitlines()[-1:] == ["radio-ready"]
        print(f"radio in the live system: {self.live_radio}", flush=True)
        self.sh(f"cd /root; rm -rf kombain; git clone -q {self.o.repo} kombain; cd kombain; git checkout -q {self.o.ref}; git log -1 --format=%h", what="clone kombain")

        vm = self.vm
        vm.send("cd /root/kombain && ./setup.sh --serial; echo SETUP-EXIT=$((0+$?))=\n")

        def say(pattern, answer=None, timeout=120):
            index, m = vm.wait([pattern, r"(?m)^setup\.sh: [^\n]*", r"SETUP-EXIT=(\d+)="], timeout)
            if index != 0:
                raise Failed(f"setup.sh stopped while waiting for {pattern!r}: {m.group(0)}\n{vm.tail()}")
            if answer is not None:
                vm.send(answer + "\n")
            return m

        say(r"Install on disk number \[1\]: ", "9")
        say(r"That is not on the list")
        say(r"Install on disk number \[1\]: ", "")
        say(r"User name \[dev\]: ", "Bad Name")
        say(r"Lowercase letters")
        say(r"User name \[dev\]: ", self.user)
        say(r"Size of / \(the system and programs\) \[[^]]*\]: ", "banana")
        say(r"Not a size")
        say(r"Size of / \(the system and programs\) \[[^]]*\]: ", "5G")
        say(r"At least 20 GiB")
        say(r"Size of / \(the system and programs\) \[[^]]*\]: ", "9T")
        say(r"That does not fit")
        say(r"Size of / \(the system and programs\) \[[^]]*\]: ", f"{SETUP_ROOT_MIB // 1024}G")
        say(r"Size of /home/gamer \(games\) \[[^]]*\]: ", "9T")
        say(r"That does not fit")
        say(r"Size of /home/gamer \(games\) \[[^]]*\]: ", f"{SETUP_GAMER_MIB // 1024}G")
        say(rf"Size of /home/{self.user} \(your files\) \[[^]]*\]: ", "1M")
        say(r"At least 1 GiB")
        say(rf"Size of /home/{self.user} \(your files\) \[[^]]*\]: ", f"{SETUP_DEV_MIB // 1024}G")
        say(r"Is this right\? \[Y/n\]: ", "n")
        # asked again, the last answers are the defaults
        say(rf"Size of / \(the system and programs\) \[{SETUP_ROOT_MIB // 1024} GiB\]: ", "")
        say(rf"Size of /home/gamer \(games\) \[{SETUP_GAMER_MIB // 1024} GiB\]: ", "")
        say(rf"Size of /home/{self.user} \(your files\) \[{SETUP_DEV_MIB // 1024} GiB\]: ", "")
        say(r"Is this right\? \[Y/n\]: ", "y")
        say(r"Host name \[voidbox\]: ", "bad/name")
        say(r"Letters, digits")
        say(r"Host name \[voidbox\]: ", SETUP_HOST)
        say(r"Time zone \[Europe/Moscow\]: ", "../../etc/passwd")
        say(r"No such time zone")
        say(r"Time zone \[Europe/Moscow\]: ", SETUP_ZONE)
        say(r"for several \[[^]]*\]: ", "7")
        say(r"Numbers from 1 to 5")
        say(r"for several \[[^]]*\]: ", "")
        wired = say(r"Use the wired network on (\S+) in the installed system\? \[Y/n\]: ", "n" if self.o.no_cable else "").group(1)
        print(f"wired interface: {wired}", flush=True)
        if self.o.no_cable:
            say(r"Without a cable dhcpcd is removed")
        if self.live_radio:
            say(r"Wi-Fi network to join at first boot \(empty: none\): ", WIFI_SSID)
            say(r"Its password: ", WIFI_PASSPHRASE)
        say(r"Install the desktop and tools[^\n]*\[Y/n\]: ", "")
        name = os.path.basename(self.disk_dev)
        say(rf"Type {name} to erase it, or stop to quit: ", "yes")
        say(r"Nothing was erased")
        self.expect("setup.sh: nothing is touched before the disk's name is typed", self.disk_untouched())
        say(rf"Type {name} to erase it, or stop to quit: ", name)
        self.expect("setup.sh: every wrong answer was refused, and asked again", True)

        start = vm.pos
        patterns = [r"Remove the installation stick and press Enter to reboot: ", r"(?m)^setup\.sh: [^\n]*", r"SETUP-EXIT=(\d+)=",
                    r"[Ee]nter passphrase for ([^:\s]+):", r"Verify passphrase:", r"New password:", r"Retype new password:"]
        mistyped_passphrase = mistyped_password = False
        last_passphrase = ROOT_PASSPHRASE
        while True:
            index, m = vm.wait(patterns, 3000)
            if index == 0:
                break
            if index in (1, 2):
                raise Failed(f"setup.sh stopped: {m.group(0)}\n{vm.tail()}")
            if index == 3:
                last_passphrase = DEV_PASSPHRASE if m.group(1).endswith("3") else ROOT_PASSPHRASE
                vm.send(last_passphrase + "\n")
            elif index == 4:
                if not mistyped_passphrase:
                    mistyped_passphrase = True
                    vm.send("a mistake\n")
                else:
                    vm.send(last_passphrase + "\n")
            elif index == 5:
                vm.send(PASSWORD + "\n")
            else:
                if not mistyped_password:
                    mistyped_password = True
                    vm.send("a mistake\n")
                else:
                    vm.send(PASSWORD + "\n")
        self.setup_output = clean(vm.buf[start:vm.pos])
        self.expect("setup.sh: a mistyped passphrase and password are asked again, and it goes on", mistyped_passphrase and mistyped_password)
        self.expect("setup.sh: it finishes", True)
        found = re.search(r"LUKS UUID (\S+)\s+the system and games", self.setup_output), re.search(r"LUKS UUID (\S+)\s+your files", self.setup_output)
        if not all(found):
            raise Failed("setup.sh did not report the volumes")
        self.luks = {"root": found[0].group(1), "dev": found[1].group(1)}
        vm.send("\n")
        vm.wait_exit(180)
        self.vm = None

    def disk_untouched(self):
        """The VM's disk file is checked from outside: nothing has written to it yet."""
        info = subprocess.run(["qemu-img", "info", "-U", "--output=json", self.disk], capture_output=True, text=True)
        return '"actual-size"' in info.stdout and int(re.search(r'"actual-size": (\d+)', info.stdout)[1]) < 1024 * 1024

    def check_answers(self):
        """What setup.sh was told is what the machine has."""
        lvs = self.out("lvs --noheadings --nosuffix --units m -o lv_name,lv_size vg0")
        sizes = {w[0]: float(w[1]) for w in (line.split() for line in lvs.splitlines()) if len(w) == 2}
        print(self.out(f"lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT {self.disk_dev}; df -h / /home/gamer /home/{self.user} /boot; vgs vg0"), flush=True)
        self.expect("setup.sh: / has the size asked for", sizes.get("root") == SETUP_ROOT_MIB, sizes)
        self.expect("setup.sh: /home/gamer has the size asked for", sizes.get("gamer") == SETUP_GAMER_MIB, sizes)
        self.expect(f"setup.sh: /home/{self.user} has at least the size asked for",
                    int(self.out(f"lsblk -bdno SIZE {self.part(3)}")) // 1048576 >= SETUP_DEV_MIB, self.out(f"lsblk -bdno SIZE {self.part(3)}"))
        free = float(self.out("vgs --noheadings --nosuffix --units m -o vg_free vg0").strip())
        total = int(self.out(f"lsblk -bdno SIZE {self.disk_dev}")) // 1048576
        wanted = total - 1024 - 2 * 64 - SETUP_ROOT_MIB - SETUP_GAMER_MIB - SETUP_DEV_MIB
        self.expect("setup.sh: the rest stays free in vg0", abs(free - wanted) < 128, (free, wanted))
        self.expect("setup.sh: the disk's names are right", self.out(f"findmnt -n -o SOURCE /boot") == self.part(1))
        self.expect("setup.sh: the user", self.user in self.out(f"id {self.user}") and "wheel" in self.out(f"id {self.user}"))
        self.expect("setup.sh: the user's home is theirs", self.out(f"stat -c %U /home/{self.user}") == self.user)
        self.expect("setup.sh: the host name", self.out("cat /etc/hostname") == SETUP_HOST)
        self.expect("setup.sh: the time zone", SETUP_ZONE in self.out("readlink /etc/localtime"))
        if self.o.no_cable:
            self.expect("setup.sh: no cable, so no dhcpcd", self.out("xbps-query dhcpcd >/dev/null && echo installed || echo gone") == "gone")
            # without the ignore, base-system would bring it back and xbps-pkgdb would call it missing
            again = self.out("xbps-install -Sn -f base-system 2>&1; xbps-pkgdb base-system 2>&1; echo pkgdb=$?")
            self.expect("setup.sh: and updates leave it out", "dhcpcd" not in again and again.endswith("pkgdb=0"), again[-300:])
        else:
            wired = self.out("ls /etc/runit/runsvdir/default /etc/runit/runsvdir/gaming | grep -c dhcpcd-")
            self.expect("setup.sh: the wired network, in both modes", wired == "2", wired)
        self.expect("setup.sh: no installation leftovers", self.out("ls /tmp/kombain-step 2>/dev/null; true") == "")
        self.expect("setup.sh: no firmware for hardware it doesn't have", "linux-firmware-nvidia" not in self.out("xbps-query -l | grep linux-firmware; true"))
        if self.live_radio:
            saved = self.out(f"ls /var/lib/iwd; stat -c '%a %U' '/var/lib/iwd/{WIFI_SSID}.psk'")
            self.expect("setup.sh: the Wi-Fi network is saved for iwd, readable by root alone", f"{WIFI_SSID}.psk" in saved and "600 root" in saved, saved)
            self.expect("setup.sh: iwd is kept with a radio", "iwd" in self.out("ls /etc/runit/runsvdir/default"))
        else:
            self.expect("setup.sh: no iwd without Wi-Fi", "iwd" not in self.out("ls /etc/runit/runsvdir/default /etc/runit/runsvdir/gaming"))
        self.expect("setup.sh: no package cache", int(self.out("du -sxm /var/cache/xbps | cut -f1")) < 5)

    def measure(self, label, settle=40):
        """What the machine uses while nothing is happening, for the summary and to compare runs."""
        time.sleep(settle)
        text = self.sh(MEASURE, check=False, timeout=240)
        numbers = dict(re.findall(r"^metric (\S+) (\S+)", text, flags=re.M))
        numbers.update(self.boot_times)
        self.metrics[label] = numbers
        print(f"=== {label}\n{text}", flush=True)
        with open(os.path.join(self.o.work, "metrics.txt"), "a") as f:
            f.write(f"=== {label}\n{text}\n")

    def install_stock(self):
        """Plain Void: base-system, what void-installer enables, no encryption. Only to be measured."""
        self.sh("sv down sshd; xbps-install -Sy xbps", what="tools")
        self.sh(
            "printf 'label: gpt\\nsize=1G, type=U\\ntype=L\\n' | sfdisk \"$DISK\"; udevadm settle; "
            "p=$DISK; case $DISK in *[0-9]) p=${DISK}p ;; esac; "
            "mkfs.vfat -F32 -n EFI ${p}1; mkfs.xfs -L root ${p}2; mount ${p}2 /mnt; mkdir -p /mnt/boot; mount ${p}1 /mnt/boot; "
            "mkdir -p /mnt/var/db/xbps/keys; cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/; "
            "XBPS_ARCH=x86_64 xbps-install -Sy -r /mnt -R https://repo-default.voidlinux.org/current base-system limine efibootmgr; "
            "cp /etc/resolv.conf /mnt/etc/",
            timeout=2400, what="stock: base system")
        self.vm.send("xchroot /mnt /bin/bash\n")
        self.adopt_shell()
        self.sh("echo stock > /etc/hostname; sed -i -e 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/default/libc-locales; xbps-reconfigure -f glibc-locales; "
                "passwd; "
                "p=$DISK; case $DISK in *[0-9]) p=${DISK}p ;; esac; "
                "printf '%s\\n' \"LABEL=root / xfs defaults 0 1\" \"UUID=$(blkid -s UUID -o value ${p}1) /boot vfat defaults 0 2\" \"tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0\" > /etc/fstab; "
                "for s in dhcpcd sshd agetty-ttyS0; do ln -sfn /etc/sv/$s /etc/runit/runsvdir/default/; done; "
                "xbps-reconfigure -fa; "
                "v=$(ls /boot/vmlinuz-* | sed 's|.*/vmlinuz-||' | head -1); "
                "printf 'timeout: 0\\n\\n/Void\\n    protocol: linux\\n    path: boot():/vmlinuz-%s\\n    cmdline: root=LABEL=root rw quiet loglevel=3 console=tty0 console=ttyS0,115200\\n    module_path: boot():/initramfs-%s.img\\n' $v $v > /boot/limine.conf; "
                "mountpoint -q /sys/firmware/efi/efivars || mount -t efivarfs none /sys/firmware/efi/efivars; "
                "mkdir -p /boot/EFI/BOOT; cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/; "
                "efibootmgr --create --disk $DISK --part 1 --label Limine --loader '\\EFI\\BOOT\\BOOTX64.EFI'",
                timeout=1200, what="stock: settings")
        self.vm.send("exit\n")
        self.adopt_shell()
        self.sh("umount -R /mnt", what="stock: unmount")
        self.vm.send("reboot\n")
        self.vm.wait_exit(180)
        self.vm = None
        self.expect("stock: installed", True)

    def check_stock(self):
        prompts = self.boot_disk()
        self.expect("stock: boots with no passphrase", prompts == 0, prompts)
        self.measure("stock-console")
        self.sh(BOOT_MARKS, what="test only: boot marks")
        self.vm.send("reboot\n")
        self.vm.wait_exit(180)
        self.vm = None
        self.boot_disk()
        time.sleep(10)
        self.boot_timeline("boot-stock")
        self.static_cost("boot-stock")
        self.vm.send("poweroff\n")
        try:
            self.vm.wait_exit(120)
        except subprocess.TimeoutExpired:
            self.vm.kill()
        self.vm = None

    def boot_disk(self):
        """Boots the installed system, answering LUKS prompts. Returns how many it saw."""
        self.qemu(live=False)
        self.o.root_password = PASSWORD
        count = 0
        started = time.time()
        answered = None
        self.boot_events = [("start", started)]
        while True:
            index, m = self.vm.wait([r"(?:[Ee]nter passphrase for|Password \(?)[^\n:]*: *$|assphrase[^\n]*: *$", r"login: "], self.o.boot_timeout)
            if index == 1:
                now = time.time()
                self.boot_events.append(("login", now))
                self.boot_times = {"boot_to_prompt_s": f"{(answered or now) - started:.1f}", "last_passphrase_to_login_s": f"{now - (answered or started):.1f}"}
                break
            count += 1
            self.boot_events.append(("prompt", time.time()))
            prompt = m.group(0)
            word = DEV_PASSPHRASE if self.luks.get("dev", "?") in prompt or self.part(3) in prompt else ROOT_PASSPHRASE
            # cryptsetup prints the prompt before it turns echo off and flushes the input: an answer
            # sent at once can be shown on the console and then thrown away
            time.sleep(1)
            self.vm.send(word + "\n")
            answered = time.time()
            self.boot_events.append(("answer", answered))
            print(f"answered a LUKS prompt: {prompt.strip()[:80]}", flush=True)
        self.vm.send("root\n")
        self.vm.wait([r"Password: "], 60)
        self.vm.send(PASSWORD + "\n")
        self.adopt_shell()
        if self.o.no_cable:
            self.test_network()
        return count

    def boot_timeline(self, label):
        """Where the last boot's time went, from QEMU's start. The time a prompt waited for its
        passphrase is left out: it is the person's, not the machine's."""
        try:
            # the kernel's start on this host's clock: the quickest of three readings is the least late
            kernel = min(time.time() - float(self.out("cut -d' ' -f1 /proc/uptime")) for _ in range(3))
            text = self.out(BOOT_TIMELINE)
            print(f"=== boot timeline: {label}\n{text}", flush=True)
            hz = int(re.search(r"^hz (\d+)", text, re.M).group(1))
            marks = [(float(t), what) for t, what in re.findall(r"^mark (\S+) (.*)$", text, re.M)]
            procs = [(int(t) / hz, comm, cmd) for t, comm, cmd in re.findall(r"^proc (\d+) (\S+) (.*)$", text, re.M)]
            events = self.boot_events
            start = events[0][1]
            prompts = [t - kernel for kind, t in events if kind == "prompt"]
            answers = [t - kernel for kind, t in events if kind == "answer"]
            waiting = sum(a - p for p, a in zip(prompts, answers))

            def mark(pattern):
                return next((t for t, what in marks if re.search(pattern, what)), None)

            def started_at(comm=None, arg=""):
                found = [t for t, c, cmd in procs if (comm is None or c == comm) and arg in cmd]
                return min(found) if found else None

            n = {"firmware_and_loader_s": kernel - start}
            init = mark(r"^Run /init")
            root = mark(r"Ending clean mount")
            n["kernel_s"] = init
            if prompts and init is not None and root is not None:
                n["initramfs_to_first_prompt_s"] = prompts[0] - init
                # from each answer to the next prompt, and from the last one to the root file system
                n["unlock_each_s"] = " + ".join(f"{b - a:.2f}" for a, b in zip(answers, prompts[1:] + [root]))
            elif init is not None and root is not None:
                n["initramfs_s"] = root - init
            stage1 = [(t, what.split(" ", 1)[1]) for t, what in marks if what.startswith("kombain-boot ")]
            if len(stage1) > 2 and root is not None:
                n["root_to_stage1_s"] = stage1[0][0] - root
                n["stage1_s"] = stage1[-1][0] - stage1[0][0]
                steps = sorted(((b[0] - a[0], os.path.basename(a[1])) for a, b in zip(stage1, stage1[1:])), reverse=True)
                n["stage1_slowest"] = ", ".join(f"{name} {d:.2f}" for d, name in steps[:5])
            else:
                print("boot timeline: runit's stage 1 was not marked", flush=True)
            runsvdir = started_at("runsvdir")
            tty1 = started_at("runsv", "tty1")
            if runsvdir is not None and tty1 is not None:
                if stage1:
                    n["stage1_end_to_stage2_s"] = runsvdir - stage1[-1][0]
                n["stage2_to_tty1_s"] = tty1 - runsvdir
                n["machine_time_to_tty1_s"] = tty1 + (kernel - start) - waiting
            n["waiting_for_passphrases_s"] = waiting
            # dev or gamer logged in by itself on tty1
            for name, comm, arg in (("mango", "mango", ""), ("netline", "netline", ""), ("game_session", None, "game-session")):
                t = started_at(comm, arg)
                if t is not None and tty1 is not None:
                    n[f"tty1_to_{name}_s"] = t - tty1
            self.metrics[label] = {k: f"{v:.2f}" if isinstance(v, float) else v for k, v in n.items()}
            for line in re.findall(r"^(?:file|luks|fpdt|initramfs (?:magic|total)) .*$", text, re.M):
                key, rest = line.split(" ", 1)
                self.metrics[label][f"{key} {rest.split(' ', 1)[0]}"] = rest.split(" ", 1)[1]
            print("\n".join(f"{k}: {v}" for k, v in self.metrics[label].items()), flush=True)
        except (Failed, AttributeError, ValueError, IndexError, TypeError) as e:
            print(f"boot timeline {label}: {e!r}", flush=True)

    def static_cost(self, label):
        text = self.out(STATIC_COST)
        print(f"=== static-node modules: {label}\n{text}", flush=True)
        costs = re.findall(r"^cost (\S+) (\d+) ms$", text, re.M)
        if costs:
            self.metrics.setdefault(label, {})["static_node_modules_ms"] = ", ".join(f"{m} {ms}" for m, ms in sorted(costs, key=lambda c: -int(c[1])))

    def unlock_cost(self):
        """How long each LUKS volume's key derivation takes on this CPU, with nothing else running."""
        for part, word in ((2, ROOT_PASSPHRASE), (3, DEV_PASSPHRASE)):
            took = self.out(f"a=$(cut -d' ' -f1 /proc/uptime); printf '%s' '{word}' | cryptsetup open --test-passphrase --key-file=- {self.part(part)} && "
                            "b=$(cut -d' ' -f1 /proc/uptime) && echo \"$a $b\" | awk '{printf \"%.2f\", $2 - $1}'; true")
            self.metrics.setdefault("boot-dev", {})[f"unlock_p{part}_alone_s"] = took

    def check_boot_time(self):
        """One more Dev boot, with runit's stage 1 marked and dev logged in by itself, to see where the time goes."""
        self.sh(BOOT_MARKS, what="test only: boot marks")
        self.desktop_login(True)
        self.vm.send("reboot\n")
        self.vm.wait_exit(180)
        self.vm = None
        self.boot_disk()
        time.sleep(20)
        self.boot_timeline("boot-dev")
        print(self.out("k=$(uname -r); for v in 'sloppy:--hostonly-mode sloppy' 'strict without drm:--omit drm'; do "
                       "dracut -q --force $(echo ${v#*:}) /tmp/variant.img $k 2>/dev/null; "
                       "echo \"initramfs variant ${v%%:*}: $(($(stat -c %s /tmp/variant.img) / 1024)) KiB, $(lsinitrd /tmp/variant.img | grep -c '^-') files\"; done; rm -f /tmp/variant.img"), flush=True)
        self.unlock_cost()
        self.static_cost("boot-dev")
        self.sh("mv /etc/runit/1.timeless /etc/runit/1")
        self.desktop_login(False)

    def test_network(self):
        """This system has no DHCP client, as chosen. The test still needs the internet, so the VM's
        card gets QEMU's fixed address by hand, for this boot only."""
        self.sh("n=$(for d in /sys/class/net/*; do [ -e $d/device ] && [ ! -e $d/wireless ] && echo ${d##*/} && break; done); "
                "ip link set $n up; ip addr add 10.0.2.15/24 dev $n 2>/dev/null || true; ip route replace default via 10.0.2.2; "
                "printf 'nameserver 10.0.2.3\\n' | resolvconf -a $n.test", what="test only: the VM's network by hand")

    def check_dev(self):
        prompts = self.boot_disk()
        self.expect("Dev: boots from the disk through Limine", True)
        self.expect("Dev: asks for two LUKS passphrases", prompts == 2, prompts)
        print(self.out("uname -r; cat /proc/cmdline; lsblk -o NAME,TYPE,FSTYPE,MOUNTPOINT | cut -c1-70"), flush=True)
        self.expect("Dev: /home/dev is mounted", self.out("findmnt -n -o TARGET /home/dev; true") != "")
        self.expect("Dev: / is XFS", self.out("findmnt -n -o FSTYPE /") == "xfs")
        self.expect("Dev: default runlevel", "default" in self.out("readlink -f /etc/runit/runsvdir/current"))
        lockdown = self.out("cat /sys/kernel/security/lockdown")
        self.expect("Dev: kernel lockdown is on", "[integrity]" in lockdown, lockdown)
        ruleset = self.out("nft list ruleset")
        self.expect("Dev: firewall loaded with a drop policy", ruleset.count("policy drop") == 2, ruleset[:200])
        self.expect("Dev: zram swap is on", "zram" in self.out("swapon --show"))
        wrong = self.out(
            "grep -E '^[a-z]' /etc/sysctl.d/90-local.conf | while IFS== read -r key want; do "
            "for f in /proc/sys/$(echo \"$key\" | tr . /); do "
            "have=$(cat \"$f\" 2>&1); [ \"$have\" = \"$want\" ] || echo \"$f wanted $want got $have\"; done; done"
        )
        self.expect("Dev: every sysctl setting is in effect", not wrong, wrong)
        self.expect("Dev: the sysctl file is complete", self.out("grep -cE '^[a-z]' /etc/sysctl.d/90-local.conf") == str(SYSCTL_SETTINGS))
        services = self.out("for s in /etc/runit/runsvdir/current/*; do sv status \"$s\" | cut -d: -f1,2 | head -1; done")
        down = [l for l in services.splitlines() if l and not l.startswith("run:")]
        self.expect("Dev: every enabled service is running", not down, down)
        self.expect("Dev: network is up", self.wait_network())
        # with a file it did not write, resolvconf refuses every update and DNS stays as it was at install
        head = self.out("head -1 /etc/resolv.conf")
        self.expect("Dev: resolvconf writes resolv.conf, so DNS follows the network", head == "# Generated by resolvconf", head)
        self.expect("Dev: no kernel oops or module refusals", not re.search(r"Oops|BUG:|Lockdown:.*module|module verification failed", self.out("dmesg")))
        cmdline = self.out("cat /proc/cmdline")
        for word in ("init_on_free=1", "ia32_emulation=0", "nowatchdog", "kfence.sample_interval=0", "debugfs=off"):
            self.expect(f"Dev: the kernel runs with {word}", word in cmdline, cmdline)
        self.expect("Dev: no debugfs", "debugfs" not in self.out("findmnt -n -t debugfs; true"))
        interfaces = self.out("ls /sys/class/net | grep -v lo; true").split()
        for name in interfaces:
            self.expect(f"Dev: redirects are off on {name} itself", self.out(f"cat /proc/sys/net/ipv4/conf/{name}/accept_redirects") == "0")
        consoles = self.out("ls /etc/runit/runsvdir/current/ | grep -c '^agetty-tty[3-6]'; true")
        self.expect("Dev: no spare consoles", consoles == "0", consoles)
        self.expect("Dev: rtkit is gone", "rtkit" not in self.out("ls /etc/runit/runsvdir/current/"))
        sleepers = self.out("for d in /sys/bus/pci/devices/*; do echo $(cat $d/class) $(cat $d/power/control); done")
        print(sleepers, flush=True)
        self.expect("Dev: idle PCI devices may sleep", any(l.endswith(" auto") for l in sleepers.splitlines()), sleepers[:200])
        self.expect("Dev: not the GPU", all(l.endswith(" on") for l in sleepers.splitlines() if l.startswith("0x03")), sleepers[:200])
        loaded = self.out("cut -d' ' -f1 /proc/modules | grep -xE 'btrfs|raid6_pq|hci_vhci|cuse|nvram|userio'; dmesg | grep -m1 'raid6:'; true")
        self.expect("Dev: no btrfs, RAID6 benchmark or test devices loaded at boot", loaded == "", loaded)
        initramfs = self.out("lsinitrd -m /boot/initramfs-*.img | grep -xE 'virtfs|btrfs'; lsinitrd /boot/initramfs-*.img | grep -cE 'firmware/cxgb4|kernel/drivers/usb/storage'; true")
        self.expect("Dev: the initramfs holds this machine's drivers only", initramfs == "0", initramfs)
        self.expect("Dev: the package locales stay out", self.out("ls /usr/share/locale | wc -l").isdigit() and int(self.out("du -sxm /usr/share/locale | cut -f1")) < 60, self.out("du -sxm /usr/share/locale"))
        self.measure("dev-console")

    def install_kombain(self):
        clone = block("git clone https://github.com/FalconBinary/kombain").splitlines()
        if clone[-1] != "doas chsh -s /usr/local/bin/fdash dev":
            raise Failed("the guide's kombain block changed")
        ref = self.o.ref
        self.sh(f"cd /root; rm -rf kombain; git clone -q {self.o.repo} kombain; cd kombain; git checkout -q {ref}; git log -1 --format=%h", what="clone kombain")
        output = self.sh("cd /root/kombain; ./install.sh --user dev", timeout=1800, what="guide step 11: install.sh")
        print(output[-800:], flush=True)
        self.sh("chsh -s /usr/local/bin/fdash dev")
        self.sh(block("doas sh -c").replace("doas ", ""), what="guide step 11: package cache")
        self.expect("kombain: install.sh finishes inside the real system", True)
        self.check_kombain(output)

    def check_kombain(self, output):
        self.expect("kombain: fdash, netline and zcool are installed", all(c in self.out("ls /usr/local/bin") for c in ("fdash", "netline", "zrun", "zcool")))
        self.expect("kombain: the login shell works", self.out("su - dev -c 'echo shell-$0'").startswith("shell-"))
        self.expect("kombain: sysctl applied without errors", "could not be applied" not in output, output[-300:])
        self.expect("kombain: gconv cache built", "gconv-modules.cache" in self.out("ls /usr/lib/gconv/"))
        listing = self.out("zcool list")
        print(listing, flush=True)
        self.expect("zcool: list runs on the real kernel", "chip" in listing, listing[:200])
        dry = self.out("timeout 5 zcool run --dry-run; true")
        print(dry, flush=True)
        self.expect("zcool: dry run on the real kernel, Landlock active", "sandbox: active" in dry, dry[:200])

    def check_mango(self):
        """mango on a real DRM device (virtio-gpu with software rendering) through the guide's own login."""
        # a sound card and a battery for the panel: the kernel's own test modules, so real device events
        print(self.out("modprobe snd_dummy 2>&1; modprobe test_power 2>&1; ls /proc/asound /sys/class/power_supply; true"), flush=True)
        self.desktop_login(True)
        time.sleep(25)
        procs = self.out("ps -eo user,comm | grep -E 'mango|netline|zbg|foot' | sort -u")
        print(procs, flush=True)
        self.expect("mango: starts from the login on tty1", "mango" in procs, procs)
        self.expect("netline: running under mango", "netline" in procs, procs)
        hidden = self.screenshot("mango-desktop")
        # the panel's body, clear of its items
        body = lambda rows: [row[300 * 3:450 * 3] for row in rows[8:38]]
        self.monitor_cmd("mouse_move 0 -3000")
        time.sleep(2)
        shown = self.screenshot("mango-panel")
        self.expect("netline: hidden, it slides out at the screen edge", body(hidden) != body(shown))
        self.monitor_cmd("sendkey alt-ret")
        time.sleep(5)
        terms = self.out("ps -eo user,comm | grep -E 'foot|fdash' | sort -u")
        print(terms, flush=True)
        self.expect("mango: Alt+Return opens a terminal with fdash", "fdash" in terms, terms)
        self.screenshot("mango-terminal")
        # Tags 3 and 4 are both empty, so only netline can make these two frames differ
        self.monitor_cmd("sendkey ctrl-3")
        time.sleep(3)
        tag3 = self.screenshot("mango-tag3")
        self.monitor_cmd("sendkey ctrl-4")
        time.sleep(3)
        tag4 = self.screenshot("mango-tag4")
        strip = lambda rows: [row[40 * 3:210 * 3] for row in rows[12:34]]
        self.expect("netline: follows the tag mango switched to", strip(tag3) != strip(tag4))
        self.check_panel_modules(body, tag4)
        self.check_report()
        self.desktop_login(False)

    def check_report(self):
        """The guide's step 14 on the running desktop: what it names must be what is really here."""
        command = block("doas kombain-report")
        self.sh(f"cd /root; rm -f kombain-report-*.txt; {command.replace('doas ', '')}", timeout=300, what="guide step 14: kombain-report")
        path = self.out("ls /root/kombain-report-dev-*.txt")
        print(self.out(f"wc -l {path}; grep -E '^(mode|lockdown|probe:)|^  mango |draw|^test_battery|per second|^power' {path}"), flush=True)
        self.expect("report: no shell errors", self.out(f"grep -c 'kombain-report: [0-9]*:' {path}; true") == "0")
        # by PCI class: the card number depends on whether the firmware's framebuffer came first
        gpu = self.out("for d in /sys/bus/pci/devices/*; do grep -q '^0x03' $d/class && basename $d; done; true")
        mango = self.out(f"grep '^  mango [0-9]*:' {path}; true")
        self.expect("report: names the GPU mango draws on", f"={gpu}" in mango, (gpu, mango))
        self.expect("report: sees the battery", self.out(f"grep -c '^test_battery Battery' {path}; true") == "1")
        # CI runners are Intel or AMD: either way the probe must stop before writing anything
        stop = "lockdown" if self.out("grep -c GenuineIntel /proc/cpuinfo; true") != "0" else "only Intel"
        probe = self.out(f"grep '^probe:' {path}; true")
        self.expect("report: sees lockdown, and the undervolt probe stops before any write", "[integrity]" in self.out(f"grep '^lockdown' {path}") and stop in probe, probe)
        leaks = self.out(f"for v in $(cat /sys/class/net/*/address | grep -v '^00:00:00:00:00:00$') $(blkid -s UUID -o value); do grep -qiF \"$v\" {path} && echo \"$v\"; done; true")
        self.expect("report: no MAC address or UUID of this machine in it", leaks == "", leaks)
        mine = self.out("su - dev -c 'kombain-report --seconds 2 --out /tmp/report-dev.txt' >/dev/null 2>&1; echo $?; grep -c 'needs root' /tmp/report-dev.txt; grep '^  mango [0-9]*:' /tmp/report-dev.txt; true").splitlines()
        self.expect("report: runs without root, and still sees its own user's GPU files", len(mine) == 3 and mine[0] == "0" and mine[1] != "0" and f"={gpu}" in mine[2], mine)

    def desktop_login(self, on):
        """dev logged in on tty1 by itself, so mango starts the way the guide's own login starts it."""
        if on:
            self.sh(
                "[ -d /etc/sv/agetty-autologin-dev-tty1 ] || { cp -R /etc/sv/agetty-tty1 /etc/sv/agetty-autologin-dev-tty1; rm -f /etc/sv/agetty-autologin-dev-tty1/supervise; "
                "echo 'GETTY_ARGS=\"--autologin dev --noclear\"' >> /etc/sv/agetty-autologin-dev-tty1/conf; }; "
                "rm -f /etc/runit/runsvdir/default/agetty-tty1; ln -sf /etc/sv/agetty-autologin-dev-tty1 /etc/runit/runsvdir/default/"
            )
        else:
            self.sh("rm -f /etc/runit/runsvdir/default/agetty-autologin-dev-tty1; ln -sf /etc/sv/agetty-tty1 /etc/runit/runsvdir/default/")

    def cursor(self):
        """Where mango says the pointer is. foot runs under mango, so it has mango's address."""
        return self.out("su - dev -c 'export XDG_RUNTIME_DIR=/run/user/$(id -u); MANGO_INSTANCE_SIGNATURE=$(tr \"\\0\" \"\\n\" </proc/$(pgrep -o -x foot)/environ | sed -n s/^MANGO_INSTANCE_SIGNATURE=//p) mmsg get cursorpos 2>&1' 2>&1; true")

    def zctl(self, *words):
        return self.out("su - dev -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) zctl " + " ".join(words) + "' 2>&1; true")

    def check_panel_modules(self, body, hidden_from):
        items = lambda rows: [row[800 * 3:1270 * 3] for row in rows[8:38]]
        status = self.zctl("status")
        print(status, flush=True)
        self.expect("zctl: finds the sound server mango started", "sound " in status, status)

        before = self.screenshot("mango-modules")
        self.zctl("vol", "30")
        time.sleep(0.5)
        volume = self.out("su - dev -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) wpctl get-volume @DEFAULT_AUDIO_SINK@' 2>&1; true")
        self.expect("zctl: sets the volume in PipeWire", "0.30" in volume, volume)
        self.zctl("mute")
        # software rendering in a busy VM can be seconds behind, so one frame proves nothing
        for _ in range(5):
            muted = self.screenshot("mango-muted")
            if items(before) != items(muted):
                break
        self.expect("netline: shows mute from the server's event", items(before) != items(muted))
        self.zctl("mute")
        # A screen that has not caught up makes the next check meaningless: this one has run 25 s
        # behind. Wait until it no longer shows the speaker muted.
        speaker = lambda rows: [row[1060 * 3:1090 * 3] for row in rows[8:38]]
        current = False
        started = time.time()
        while time.time() - started < 40:
            if speaker(self.screenshot("mango-unmuted")) != speaker(muted):
                current = True
                break
            time.sleep(1)
        print(f"the screen caught up after {time.time() - started:.0f} s: {current}", flush=True)

        self.expect("zctl: finds the battery", "battery 50 " in status, status)
        # A change in the kernel, through the real udevd and the panel's filter on its broadcast.
        # Only the battery's own pixels count: the level bar next to it comes and goes by itself.
        battery = lambda rows: [row[1085 * 3:1160 * 3] for row in rows[8:38]]
        time.sleep(2)  # the level bar from the volume change above is gone by now
        self.sh("(timeout 60 udevadm monitor --kernel --udev --property --subsystem-match=power_supply > /tmp/udev.log 2>&1 &)")
        time.sleep(1)
        before = self.screenshot("mango-battery-before")
        # Apart from the screen: an idle netline reads nothing, and the event makes it read its
        # socket and the battery's files. That shows whether it woke, however slow the screen is.
        def reads():
            text = self.out("awk '/^syscr/ {print $2}' /proc/$(pgrep -o -x netline)/io")
            return int(text) if text.isdigit() else -1

        idle_from = reads()
        time.sleep(2)
        idle = reads() - idle_from
        start = reads()
        self.sh("echo 12 > /sys/module/test_power/parameters/battery_capacity")
        time.sleep(1)
        woke = reads() - start
        print(f"netline's reads: {idle} in 2 s idle, {woke} in the second after the event", flush=True)
        self.expect("netline: wakes up for a real battery event", woke >= 3 and woke > idle, (idle, woke))
        changed = False
        started = time.time()
        while time.time() - started < 40:
            if battery(before) != battery(self.screenshot("mango-battery-after")):
                changed = True
                break
        print(f"the icon changed after {time.time() - started:.0f} s: {changed}", flush=True)
        print(self.out("cat /tmp/udev.log | grep -E '^(KERNEL|UDEV)|SUBSYSTEM|CAPACITY=' | head -20"), flush=True)
        self.expect("netline: a real battery event reaches the icon", changed)
        self.expect("zctl: reads the new charge", "battery 12 " in self.zctl("status"), self.zctl("status"))

        # the menu on mango: it comes out from under the panel by cropping, and takes the keyboard
        card = lambda rows: [row[1000 * 3:1260 * 3] for row in rows[60:140]]
        closed = self.screenshot("mango-before-menu")
        self.monitor_cmd("sendkey meta_l-a")
        time.sleep(1.5)
        self.expect("zctl: the menu opens from a hotkey", self.out("pgrep -x zctl; true") != "")
        opened = self.screenshot("mango-menu")
        self.expect("zctl: the card is on screen, below the panel", card(closed) != card(opened))
        self.expect("zctl: no dimming around the card", closed[400][100 * 3:600 * 3] == opened[400][100 * 3:600 * 3])
        self.monitor_cmd("sendkey up")
        time.sleep(0.5)
        raised = self.out("su - dev -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) wpctl get-volume @DEFAULT_AUDIO_SINK@' 2>&1; true")
        self.expect("zctl: arrow up raises the volume", "0.35" in raised, raised)
        self.monitor_cmd("sendkey esc")
        time.sleep(1.5)
        self.expect("zctl: Esc closes it", self.out("pgrep -x zctl; true") == "")
        self.expect("zctl: the card is gone", card(self.screenshot("mango-menu-closed")) == card(closed))

        print("pointer on the panel:", self.cursor(), flush=True)
        for _ in range(6):
            self.monitor_cmd("mouse_move 0 100")
            print("pointer moved down:", self.cursor(), flush=True)
        time.sleep(2.5)
        gone = self.screenshot("mango-panel-gone")
        self.expect("netline: goes back when the pointer leaves", body(gone) != body(hidden_from))
        self.zctl("vol", "45")
        time.sleep(0.6)
        peek = self.screenshot("mango-level")
        self.expect("netline: comes out for a volume change", body(peek) != body(gone))
        time.sleep(2.5)
        self.expect("netline: and goes back", body(self.screenshot("mango-after-peek")) == body(gone))
        procs = self.out("ps -eo comm=")
        self.expect("idle: no Xwayland without X11 programs", "Xwayland" not in procs)
        self.expect("idle: no polkitd", "polkitd" not in procs)
        self.expect("idle: no rtkit", "rtkit" not in procs)
        threads = self.out("ps -eLo cls=,comm= | grep -E 'data-loop|pipewire' | sort -u")
        print(threads, flush=True)
        self.expect("sound still runs in real time, without rtkit", re.search(r"^\s*(RR|FF)\s", threads, flags=re.M), threads)
        self.measure("dev-desktop")

    def check_wifi(self):
        """A WPA2 network from the kernel's radio simulator, its access point in a network namespace of its
        own, so iwd here sees only the client side. The guide's way to join is iwctl; setup.sh's is the file
        it saved.

        Void builds its kernel without the simulator, so it is built here from the kernel's own source for
        the running version: a test tool, like the access point. It is unsigned, and the guide's
        lockdown=integrity refuses unsigned modules, so this one boot of Dev goes without lockdown. All of
        it is put back afterwards."""
        kernel = self.out("uname -r")
        series = re.match(r"\d+\.\d+", kernel).group(0)
        source = f"https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/net/wireless/virtual/{{}}?h=v{kernel.split('_')[0]}"
        packages = "xbps-query -l | awk '{print $2}' | sed 's/-[^-]*$//' | sort"
        self.sh(f"du -sxm / | cut -f1 > /root/size-before; {packages} > /root/packages-before; need=; for p in gcc make libelf linux{series}-headers hostapd dnsmasq; do xbps-query $p >/dev/null || need=\"$need $p\"; done; "
                "[ -z \"$need\" ] || xbps-install -Sy $need >/dev/null", timeout=900, what="test only: tools for a simulated radio and an access point")
        try:
            self.sh(
                "mkdir -p /root/hwsim; cd /root/hwsim; "
                + "".join(f"xbps-fetch -o {f} '{source.format(f)}' >/dev/null; " for f in ("mac80211_hwsim.c", "mac80211_hwsim.h"))
                + "echo 'obj-m := mac80211_hwsim.o' > Kbuild; "
                f"make -s -C /lib/modules/{kernel}/build M=/root/hwsim modules 2>&1 | tail -5; "
                f"install -D -m 644 mac80211_hwsim.ko /lib/modules/{kernel}/extra/mac80211_hwsim.ko; depmod {kernel}; "
                "echo mac80211_hwsim > /etc/modules-load.d/test-radio.conf; echo 'options mac80211_hwsim radios=2' > /etc/modprobe.d/test-radio.conf; "
                "cp /boot/limine.conf /root/limine.conf.saved; sed -i 's/ lockdown=integrity//' /boot/limine.conf",
                timeout=900, what="test only: the radio simulator, built from the kernel's source")
            self.vm.send("reboot\n")
            self.vm.wait_exit(180)
            self.vm = None
            self.boot_disk()
            print(self.out("cat /sys/kernel/security/lockdown"), flush=True)
            # logged in once the system is up, as a person would be, not racing the services at boot
            self.desktop_login(True)
            self.join_wifi()
        finally:
            if self.vm:
                self.sh(
                    "pkill -x hostapd || true; pkill -x dnsmasq || true; ip netns del ap 2>/dev/null || true; "
                    f"rm -f /etc/modules-load.d/test-radio.conf /etc/modprobe.d/test-radio.conf /lib/modules/{kernel}/extra/mac80211_hwsim.ko; depmod {kernel}; "
                    "rm -rf /root/hwsim; [ ! -e /root/limine.conf.saved ] || mv /root/limine.conf.saved /boot/limine.conf; "
                    f"{packages} > /root/packages-after; new=$(comm -13 /root/packages-before /root/packages-after); "
                    "[ -z \"$new\" ] || xbps-remove -y $new >/dev/null; rm -f /root/packages-before /root/packages-after /var/cache/xbps/*; "
                    # Void's kernel packages keep their files on removal (preserve=yes), the headers too
                    f"! echo \"$new\" | grep -qx 'linux{series}-headers' || rm -rf /usr/src/kernel-headers-{kernel}",
                    timeout=600, what="test only: everything put back")
                self.desktop_login(False)
                size = self.out("echo $(cat /root/size-before) $(du -sxm / | cut -f1); rm -f /root/size-before").split()
                self.expect("Wi-Fi test: leaves nothing behind on the disk", len(size) == 2 and int(size[1]) - int(size[0]) <= 3, size)
                self.expect("Wi-Fi test: lockdown is back for the next boot", "lockdown=integrity" in self.out("cat /boot/limine.conf"))

    def join_wifi(self):
        phys = self.out("ls /sys/class/ieee80211").split()
        print(f"radios: {phys}", flush=True)
        if len(phys) < 2:
            self.expect("Wi-Fi: the simulated radios are there", False, self.out("dmesg | grep -iE 'hwsim|lockdown' | tail -5; true"))
            return
        procs = ""
        for _ in range(30):
            procs = self.out("pgrep -x netline; true")
            if procs:
                break
            time.sleep(3)
        self.expect("Wi-Fi test: the desktop is back after the reboot", procs != "")
        if not procs:
            print(self.out("ps -eo user,tty,stat,comm | awk '$2 != \"?\"'; sv status /var/service/agetty-*; tr -s ' ' </dev/vcs1 | tail -c 600; true"), flush=True)
        time.sleep(5)
        # the panel stays out while the pointer is against the top edge, so its items can be seen
        body = lambda rows: [row[300 * 3:450 * 3] for row in rows[8:38]]
        hidden = self.screenshot("wifi-desktop")
        self.monitor_cmd("mouse_move 0 -3000")
        before = hidden
        for _ in range(5):
            time.sleep(2)
            before = self.screenshot("wifi-before")
            if body(before) != body(hidden):
                break
        icon = lambda rows: [row[1150 * 3:1186 * 3] for row in rows[8:38]]
        self.sh(
            f"ip netns add ap; iw phy {phys[-1]} set netns name ap; sleep 1; "
            "dev=$(ip netns exec ap ls /sys/class/net | grep -v lo | head -1); "
            "ip netns exec ap ip link set lo up; ip netns exec ap ip addr add 10.42.0.1/24 dev $dev; "
            f"printf 'interface=%s\\ndriver=nl80211\\nssid={WIFI_SSID}\\nhw_mode=g\\nchannel=6\\nwpa=2\\nwpa_key_mgmt=WPA-PSK\\nrsn_pairwise=CCMP\\nwpa_passphrase={WIFI_PASSPHRASE}\\n' $dev > /tmp/ap.conf; "
            "ip netns exec ap hostapd -B /tmp/ap.conf >/tmp/hostapd.log 2>&1; "
            "ip netns exec ap dnsmasq --interface=$dev --bind-interfaces --dhcp-range=10.42.0.10,10.42.0.50 --no-resolv --dhcp-leasefile=/tmp/dnsmasq.leases --pid-file=/tmp/dnsmasq.pid",
            what="test only: the access point")
        dev = self.out("for d in /sys/class/net/*; do [ -e $d/phy80211 ] && basename $d; done | head -1")
        print(f"iwd's device: {dev}", flush=True)
        if self.o.flow == "guide":
            # what the guide tells a person to type after the first boot
            self.sh(f"iwctl station {dev} scan; sleep 4; iwctl station {dev} get-networks; iwctl --passphrase '{WIFI_PASSPHRASE}' station {dev} connect {WIFI_SSID}; true")
        state = ""
        # on its own, iwd finds a network at its next periodic scan, and their interval grows to 5 minutes
        for _ in range(170):
            state = self.out(f"iw dev {dev} link; true")
            if f"SSID: {WIFI_SSID}" in state:
                break
            time.sleep(2)
        print(state, flush=True)
        how = "with iwctl, as the guide says" if self.o.flow == "guide" else "on its own, with what setup.sh saved"
        self.expect(f"Wi-Fi: iwd connects {how}", f"SSID: {WIFI_SSID}" in state, state)
        address = ""
        for _ in range(15):
            address = self.out(f"ip -4 -o addr show {dev} | awk '{{print $4}}'; true")
            if address.startswith("10.42.0."):
                break
            time.sleep(2)
        self.expect("Wi-Fi: iwd gets an address on its own", address.startswith("10.42.0."), address)
        self.expect("Wi-Fi: the network answers", "1 received" in self.out("ping -c1 -W3 10.42.0.1; true"))
        dns = self.out("cat /etc/resolv.conf")
        self.expect("Wi-Fi: the network's DNS server reaches resolv.conf", "nameserver 10.42.0.1" in dns, dns)
        after = before
        for _ in range(5):
            after = self.screenshot("wifi-connected")
            if icon(before) != icon(after):
                break
        self.expect("netline: the Wi-Fi icon shows the connection", icon(before) != icon(after))

    def try_unsigned_loader(self):
        """Boots once from a copy of Limine that nobody signed. Returns whether it was what booted."""
        self.sh("mkdir -p /boot/EFI/test; cp /usr/share/limine/BOOTX64.EFI /boot/EFI/test/unsigned.efi; "
                "efibootmgr | grep -q ' unsigned' || "
                f"efibootmgr --create --disk {self.disk_dev} --part 1 --label unsigned --loader '\\EFI\\test\\unsigned.efi' >/dev/null; "
                "n=$(efibootmgr | awk '/ unsigned/ {print substr($1, 5, 4); exit}'); efibootmgr --bootnext $n >/dev/null; efibootmgr | head -4")
        self.vm.send("reboot\n")
        self.vm.wait_exit(180)
        self.vm = None
        self.boot_disk()
        booted = self.out("efibootmgr | grep -E 'BootCurrent|unsigned|Limine'")
        print(booted, flush=True)
        current = re.search(r"BootCurrent: (\w+)", booted)
        unsigned = re.search(r"Boot(\w+)\*? unsigned", booted)
        return bool(current and unsigned and current.group(1) == unsigned.group(1))

    def check_secure_boot(self):
        """Step 12 of the guide, in a firmware that enforces Secure Boot once it has keys, then two ways
        an attacker with the disk would try: a bootloader of their own, and a changed kernel."""
        self.boot_disk()
        # a person does step 12 from Dev: the Gaming default from check_gaming goes
        self.sh("sed -i '/^default_entry:/d' /boot/limine.conf")
        # the control: before step 12 this unsigned copy boots, so the entry itself is fine
        self.expect("Secure Boot off: an unsigned bootloader still boots (the entry works)", self.try_unsigned_loader())
        self.expect("Secure Boot: Dev has a network for step 12", self.wait_network())
        status = self.out("sbctl status 2>&1; true")
        print(status, flush=True)
        lines = block("doas xbps-install -Sy sbctl").splitlines()
        self.sh("\n".join(line.replace("doas ", "", 1) for line in lines), timeout=900, what="guide step 12: Secure Boot keys")
        conf = self.out("cat /boot/limine.conf")
        self.expect("Secure Boot: the boot menu holds hashes of the kernel and initramfs", conf.count("#") >= 4, conf[:300])
        self.vm.send("reboot\n")
        self.vm.wait_exit(180)
        self.vm = None

        prompts = self.boot_disk()
        status = self.out("sbctl status 2>&1; true")
        print(status, flush=True)
        self.expect("Secure Boot: on after the guide's step 12", re.search(r"Secure Boot:\s+\S*\s*Enabled", status), status)
        self.expect("Secure Boot: Dev still asks for two passphrases", prompts == 2, prompts)
        self.expect("Secure Boot: the kernel knows", "secure boot enabled" in self.out("dmesg | grep -i 'secure boot'; true").lower())

        # The same unsigned copy, now: the firmware must refuse it and go on to the signed Limine.
        self.expect("Secure Boot: an unsigned bootloader is refused, and the signed Limine boots instead", not self.try_unsigned_loader())

        # The kernel changed by one byte: Limine checks it against the hash in its signed config.
        self.sh("for k in /boot/vmlinuz-*; do printf x >> $k; done")
        self.vm.send("reboot\n")
        self.vm.wait_exit(180)
        self.vm = None
        self.qemu(live=False)
        try:
            index, _ = self.vm.wait([r"(?:[Ee]nter passphrase for|Password \(?)", r"login: "], 120)
            refused = False
        except Failed:
            refused = True
        self.screenshot("secure-boot-changed-kernel")
        self.expect("Secure Boot: a kernel changed by one byte does not boot", refused)
        self.vm.kill()
        self.vm = None

    def check_gaming(self):
        self.sh(BOOT_MARKS, what="test only: boot marks")
        self.sh("sed -i 's/^timeout: .*/&\\ndefault_entry: 2/' /boot/limine.conf; grep -n default_entry /boot/limine.conf")
        self.vm.send("reboot\n")
        self.vm.wait_exit(180)
        self.vm = None
        prompts = self.boot_disk()
        self.expect("Gaming: boots", True)
        self.expect("Gaming: asks for one LUKS passphrase", prompts == 1, prompts)
        print(self.out("cat /proc/cmdline; lsblk -o NAME,TYPE,FSTYPE,MOUNTPOINT | cut -c1-70"), flush=True)
        self.expect("Gaming: /home/dev is not mounted", self.out("findmnt -n -o TARGET /home/dev; true") == "")
        devices = self.out(f"lsblk -n -o NAME,TYPE {self.part(3)}")
        self.expect("Gaming: the Dev volume stays locked", "crypt" not in devices, devices)
        self.expect("Gaming: gaming runlevel", "gaming" in self.out("readlink -f /etc/runit/runsvdir/current"))
        self.expect("Gaming: tuning service is up", self.out("sv status /etc/sv/game-tune").startswith("run:"))
        self.expect("Gaming: firewall loaded", self.out("nft list ruleset").count("policy drop") == 2)
        self.measure("gaming-console")
        mode = self.out("su - gamer -s /bin/sh -c 'kombain-report --seconds 2 --out -' 2>/dev/null | grep '^mode'; true")
        self.expect("report: runs as gamer in Gaming", mode.split() == ["mode", "gaming"], mode)
        self.expect("Gaming: dev's home is not reachable by gamer", "denied" in self.out("su - gamer -s /bin/sh -c 'ls /home/dev' 2>&1; true") or self.out("ls -A /home/dev | wc -l") == "0")
        # This VM has no Vulkan device, so gamescope cannot start. A real install gets the
        # same with a missing driver, or before Steam is installed.
        time.sleep(15)
        session = self.out("pgrep -u gamer -f game-session; true")
        self.expect("Gaming: autologin for gamer", session != "", session)
        self.boot_timeline("boot-gaming")
        self.sh("mv /etc/runit/1.timeless /etc/runit/1")
        self.expect("Gaming: a session that cannot start says so", self.out("grep -ac 'Press Enter' /dev/vcs1; true") == "1")
        self.screenshot("gaming")
        time.sleep(10)
        same = self.out("pgrep -u gamer -f game-session; true")
        self.expect("Gaming: it waits instead of restarting", same == session, (session, same))
        daemons = self.out("pgrep -u gamer 'pipewire|wireplumber'; true").split()
        self.monitor_cmd("sendkey ret")
        time.sleep(10)
        again = self.out("pgrep -u gamer -f game-session; true")
        self.expect("Gaming: Enter tries again", again not in ("", session), (session, again))
        newer = self.out("pgrep -u gamer 'pipewire|wireplumber'; true").split()
        self.expect("Gaming: audio daemons end with the session", bool(daemons and newer) and not set(daemons) & set(newer), (daemons, newer))
        self.vm.send("poweroff\n")
        try:
            self.vm.wait_exit(120)
        except subprocess.TimeoutExpired:
            self.vm.kill()
        self.vm = None

    def go(self):
        code = 0
        try:
            self.boot_live()
            if self.o.flow == "stock":
                self.install_stock()
                self.check_stock()
            elif self.o.stage != "live":
                if self.o.flow == "setup":
                    self.install_with_setup()
                    self.check_dev()
                    self.check_answers()
                    # (its sysctl message is about the live kernel: the check above is about the real one)
                    self.check_kombain("")
                else:
                    self.install()
                    self.check_dev()
                    self.install_kombain()
                self.check_mango()
                self.check_boot_time()
                self.check_wifi()
                self.check_gaming()
                if self.o.secure_boot:
                    self.check_secure_boot()
        except Failed as e:
            self.expect("the run reached its end", False, e)
            print(str(e), flush=True)
        finally:
            if self.vm:
                try:
                    self.screenshot("last-screen")
                except OSError:
                    pass
                self.vm.kill()
        failed = [r for r in self.results if not r[0]]
        summary = [f"# Install in a VM: {len(self.results) - len(failed)} passed, {len(failed)} failed", ""]
        summary += [f"- {'pass' if ok else '**FAIL**'}: {name}" + (f" (`{detail[:120]}`)" if not ok and detail else "") for ok, name, detail in self.results]
        for label, numbers in self.metrics.items():
            summary += ["", f"## {label}", ""] + [f"- {k}: {v}" for k, v in numbers.items()]
        text = "\n".join(summary) + "\n"
        print("\n" + text, flush=True)
        with open(os.path.join(self.o.work, "summary.md"), "w") as f:
            f.write(text)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
                f.write(text)
        return 1 if failed else code


def clean(text):
    return re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text).replace("\r", "")


def write_png(ppm_path, png_path):
    data = open(ppm_path, "rb").read()
    fields, pos = [], 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        fields.append(data[pos:end])
        pos = end
    pos += 1
    width, height = int(fields[1]), int(fields[2])
    rows = [data[pos + y * width * 3:pos + (y + 1) * width * 3] for y in range(height)]
    raw = b"".join(b"\0" + row for row in rows)

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    with open(png_path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))
    return rows


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--iso", required=True)
    p.add_argument("--work", default="vm-work")
    p.add_argument("--stage", choices=["live", "all"], default="all")
    p.add_argument("--flow", choices=["guide", "setup", "stock"], default="guide")
    p.add_argument("--disk-bus", choices=["nvme", "virtio"], default="nvme")
    p.add_argument("--secure-boot", action="store_true", help="firmware that enforces Secure Boot, and step 12 at the end")
    p.add_argument("--no-cable", action="store_true", help="setup.sh flow: no to the wired network, so the system has Wi-Fi alone")
    p.add_argument("--memory", type=int, default=6144)
    p.add_argument("--cpus", type=int, default=4)
    p.add_argument("--disk-size", default="600G")
    p.add_argument("--boot-timeout", type=int, default=600)
    p.add_argument("--repo", default="https://github.com/FalconBinary/kombain")
    p.add_argument("--ref", default="main")
    opts = p.parse_args()
    sys.exit(Run(opts).go())


if __name__ == "__main__":
    main()
