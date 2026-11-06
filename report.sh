#!/bin/sh
# What a real machine says about itself, in one file to send back: its hardware, which GPU
# each program draws on, what sleeps, power and wakeups at rest, temperatures and fans,
# undervolting, Secure Boot.
#
#   kombain-report [--seconds N] [--after N] [--out FILE|-]
#
# As root it sees everything; as any other user it leaves out what needs root and says so.
# It changes nothing, apart from loading the msr module and zcool's 1 mV undervolt probe.
# No serial numbers, MAC addresses, UUIDs or network names go into the file.
set -u

seconds=30
after=0
out=

usage() {
	sed -n '6p' "$0" 2>/dev/null | sed 's/^# *//'
	exit "$1"
}

while [ $# -gt 0 ]; do
	case $1 in
	--seconds) [ $# -ge 2 ] || usage 2; seconds=$2; shift ;;
	--after) [ $# -ge 2 ] || usage 2; after=$2; shift ;;
	--out) [ $# -ge 2 ] || usage 2; out=$2; shift ;;
	-h|--help) usage 0 ;;
	*) echo "unknown option: $1" >&2; usage 2 ;;
	esac
	shift
done
for n in "$seconds" "$after"; do
	case $n in ''|*[!0-9]*) echo "--seconds and --after take whole seconds" >&2; exit 2 ;; esac
done
[ "$seconds" -ge 2 ] || seconds=2

root=0
[ "$(id -u)" -eq 0 ] && root=1
case " $(cat /proc/cmdline) " in *" gaming "*) mode=gaming ;; *) mode=dev ;; esac
[ -n "$out" ] || out=$PWD/kombain-report-$mode-$(date +%Y%m%d-%H%M).txt
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
trap 'exit 1' INT TERM HUP
# progress goes to the terminal, the report to the file
exec 3>&2

have() { command -v "$1" >/dev/null 2>&1; }
# a file's first line, or -
val() { v=$(head -n 1 "$1" 2>/dev/null) || v=; printf '%s' "${v:--}"; }
section() {
	printf '\n== %s\n' "$1"
	printf '  %s\n' "$1" >&3
}
# a reading in thousandths as a whole number, or - when it is not a number
thousandths() {
	case $1 in ''|-|*[!0-9-]*) printf '-' ;; *) printf '%s' $(($1 / 1000)) ;; esac
}
needs_root() { [ "$root" -eq 1 ] || { echo "(needs root)"; return 1; }; }

# PCI address of /dev/dri/cardN or renderDN
dri_gpu() {
	l=$(readlink -f "/sys/class/drm/${1##*/}/device" 2>/dev/null) && printf '%s' "${l##*/}"
}

# PCI address of /dev/nvidiaN, from the driver's own list of its GPUs
nvidia_gpu() {
	for i in /proc/driver/nvidia/gpus/*/information; do
		[ -r "$i" ] || continue
		m=$(sed -n 's/^Device Minor:[[:space:]]*//p' "$i")
		[ "$m" = "${1#/dev/nvidia}" ] && { d=${i%/information}; printf '%s' "${d##*/}"; return; }
	done
	printf 'NVIDIA'
}

gpu_states() {
	for d in /sys/bus/pci/devices/*; do
		case $(val "$d/class") in 0x03*) ;; *) continue ;; esac
		printf '%s %s:%s driver=%s boot_vga=%s control=%s now=%s\n' "${d##*/}" \
			"$(val "$d/vendor")" "$(val "$d/device")" "$(basename "$(readlink "$d/driver" 2>/dev/null || echo -)")" \
			"$(val "$d/boot_vga")" "$(val "$d/power/control")" "$(val "$d/power/runtime_status")"
	done
	for p in /proc/driver/nvidia/gpus/*/power; do
		[ -r "$p" ] && grep -E 'Runtime D3 status|Video Memory' "$p" | sed "s|^|${p%/power}: |; s|/proc/driver/nvidia/gpus/||"
	done
}

machine() {
	section "machine"
	date -u '+%Y-%m-%d %H:%M UTC'
	for f in sys_vendor product_name product_version board_name bios_vendor bios_version bios_date; do
		printf '%-16s %s\n' "$f" "$(val "/sys/class/dmi/id/$f")"
	done
	printf '%-16s %s\n' cpu "$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -n 1)"
	printf '%-16s %s\n' threads "$(grep -c '^processor' /proc/cpuinfo)"
	printf '%-16s %s\n' microcode "$(sed -n 's/^microcode[[:space:]]*: //p' /proc/cpuinfo | head -n 1)"
	printf '%-16s %s\n' memory "$(awk '/^MemTotal/ {printf "%d MiB", $2 / 1024}' /proc/meminfo)"
	printf '%-16s %s\n' kernel "$(uname -r)"
	printf '%-16s %s\n' mode "$mode"
	printf '%-16s %s\n' user "$([ "$root" -eq 1 ] && echo root || echo "not root: what needs root is left out")"
	printf '%-16s %s\n' cmdline "$(cat /proc/cmdline)"
	printf '%-16s %s\n' lockdown "$(val /sys/kernel/security/lockdown)"
	for e in SecureBoot SetupMode; do
		f=/sys/firmware/efi/efivars/$e-8be4df61-93ca-11d2-aa0d-00e098032b8c
		printf '%-16s %s\n' "$e" "$( [ -r "$f" ] && od -An -tu1 "$f" | awk '{print $NF}' || echo -)"
	done
	printf '%-16s %s\n' uptime "$(awk '{printf "%d min", $1 / 60}' /proc/uptime)"
	if have sbctl && [ "$root" -eq 1 ]; then
		sbctl status 2>&1 | sed 's/^/sbctl: /'
	fi
	if have xbps-query; then
		echo "packages:"
		xbps-query -l 2>/dev/null | awk '{print $2}' | grep -E '^(linux[0-9.]*|linux-firmware[a-z-]*|intel-ucode|nvidia[0-9]*|nvidia[0-9]*-(libs|libs-32bit|dkms)|mesa|mesa-dri|mesa-vulkan-[a-z]*|vulkan-loader|gamescope|mangowc|flatpak|pipewire|wireplumber|iwd|limine|sbctl|elogind)-[0-9]' | sed 's/^/  /'
	fi
	echo "modprobe.d:"
	grep -hv '^[[:space:]]*#' /etc/modprobe.d/*.conf 2>/dev/null | grep . | sed 's/^/  /'
}

# Where the last boot's time went: the firmware's own record of it, then the kernel's log and
# when the first programs started, all in seconds since the kernel started.
boot() {
	section "boot"
	f=/sys/firmware/acpi/fpdt/boot
	if [ -r "$f/bootloader_load_ns" ]; then
		awk -v r="$(val $f/firmware_start_ns)" -v l="$(val $f/bootloader_load_ns)" -v s="$(val $f/bootloader_launch_ns)" \
			-v e="$(val $f/exitbootservice_start_ns)" -v x="$(val $f/exitbootservice_end_ns)" 'BEGIN {
			printf "firmware, from power on to loading the boot loader: %.2f s\n", l / 1e9
			printf "boot loader, its menu included, until the kernel takes over: %.2f s\n", (x - s) / 1e9
			printf "(raw: reset end %d, loader load %d, launch %d, exit boot services %d to %d ns)\n", r, l, s, e, x
		}'
	else
		echo "firmware: no performance record (ACPI FPDT) here"
	fi
	if needs_root; then
		dmesg | sed -nE 's/^\[ *([0-9]+\.[0-9]+)\] (Run \/init as init process|.*: Ending clean mount|EXT4-fs .*: mounted .*|raid6: .*|xor: .*)$/\1 \2/p' | head -n 12
	fi
	hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
	for p in /proc/[0-9]*; do
		c=$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null | cut -c1-60)
		case $c in runsvdir*|runsv\ *tty1*|login*|mango*|netline*|gamescope*|*game-session*|pipewire\ *|pipewire) ;; *) continue ;; esac
		echo "$(sed 's/.*) //' "$p/stat" | cut -d' ' -f20) $c"
	done | sort -n | awk -v hz="$hz" '{t = $1 / hz; $1 = ""; printf "%7.2f %s\n", t, $0}'
	echo "initramfs: $(ls -l /boot/initramfs-* 2>/dev/null | awk '{printf "%s %d KiB ", $NF, $5 / 1024}')"
	if needs_root && have lsinitrd; then
		img=$(ls /boot/initramfs-*.img | head -n 1)
		lsinitrd -m "$img" 2>/dev/null | awk '/^dracut modules:/ {on = 1; next} /^=+$/ {on = 0} on {printf "%s ", $0} END {print ""}' | sed 's/^/dracut modules: /'
		lsinitrd "$img" 2>/dev/null | awk '$1 ~ /^-/ && $5 ~ /^[0-9]+$/ {split($9, p, "/"); s[p[1] "/" p[2] "/" p[3] "/" p[4]] += $5} END {for (d in s) printf "%d KiB %s\n", s[d] / 1024, d}' | sort -rn | head -n 10 | sed 's/^/  /'
	fi
	echo "modules loaded at boot for a fixed device file:"
	kmod static-nodes -f devname 2>/dev/null | while read -r m n x; do
		u=$(echo "$m" | tr - _)
		awk -v m="$u" -v n="$n" '$1 == m {printf "  %s for /dev/%s, %d KiB\n", m, n, $2 / 1024}' /proc/modules
	done
}

devices() {
	section "devices"
	if have lspci; then
		lspci -nnk
	else
		for d in /sys/bus/pci/devices/*; do
			printf '%s class=%s %s:%s driver=%s\n' "${d##*/}" "$(val "$d/class")" "$(val "$d/vendor")" "$(val "$d/device")" \
				"$(basename "$(readlink "$d/driver" 2>/dev/null || echo -)")"
		done
	fi
	echo
	if have lsusb; then
		lsusb
	else
		for d in /sys/bus/usb/devices/*; do
			[ -r "$d/idVendor" ] && printf '%s %s:%s %s\n' "${d##*/}" "$(val "$d/idVendor")" "$(val "$d/idProduct")" "$(val "$d/product")"
		done
	fi
	printf '\nmodules: '
	cut -d' ' -f1 /proc/modules | grep -E '^(nvidia[a-z_]*|nouveau|i915|xe|amdgpu|radeon|msr|msi_ec|msi_wmi|intel_rapl[a-z_]*|coretemp|iwlwifi|iwlmvm|btintel|btusb|r8169|snd_hda_intel|snd_sof[a-z_]*|test_power)$' | sort | tr '\n' ' '
	echo
}

graphics() {
	section "graphics"
	gpu_states
	for d in /sys/bus/pci/devices/*; do
		case $(val "$d/class") in 0x03*) ;; *) continue ;; esac
		for c in "$d"/drm/card*/card*-*; do
			[ -r "$c/status" ] && printf '%s %s: %s\n' "${d##*/}" "${c##*/}" "$(val "$c/status")"
		done
	done
	[ -r /proc/driver/nvidia/version ] && head -n 1 /proc/driver/nvidia/version
	grep -E 'DynamicPowerManagement' /proc/driver/nvidia/params 2>/dev/null
	for p in modeset fbdev; do
		[ -r "/sys/module/nvidia_drm/parameters/$p" ] && echo "nvidia_drm.$p=$(val "/sys/module/nvidia_drm/parameters/$p")"
	done
	echo "vulkan drivers: $(ls /usr/share/vulkan/icd.d /etc/vulkan/icd.d 2>/dev/null | grep '\.json$' | tr '\n' ' ')"
	echo "flatpak:"
	for f in /var/lib/flatpak /home/*/.local/share/flatpak; do
		for k in runtime app; do
			[ -d "$f/$k" ] || continue
			(cd "$f/$k" && ls -d -- */*/* 2>/dev/null) | grep -iE 'steam|GL\.|Platform' | sed "s|^|  ${f%/.local/share/flatpak} |"
		done
	done

	echo
	echo "who draws on which GPU:"
	for p in /proc/[0-9]*; do
		files=$(ls -l "$p/fd" 2>/dev/null | grep -oE '/dev/(dri/(card|renderD)[0-9]+|nvidia[0-9]+)' | sort -u)
		[ -n "$files" ] || continue
		line="$(val "$p/comm") ${p#/proc/}:"
		for f in $files; do
			case $f in
			/dev/dri/*) line="$line ${f#/dev/dri/}=$(dri_gpu "$f")" ;;
			*) line="$line ${f#/dev/}=$(nvidia_gpu "$f")" ;;
			esac
		done
		# only the variables that pick a GPU, nothing else from the environment
		vars=$(tr '\0' '\n' <"$p/environ" 2>/dev/null | grep -E '^(WLR_DRM_DEVICES|WLR_RENDERER|DRI_PRIME|__NV_PRIME_RENDER_OFFLOAD|__GLX_VENDOR_LIBRARY_NAME|__VK_LAYER_NV_optimus|VK_ICD_FILENAMES|VK_DRIVER_FILES|MESA_VK_DEVICE_SELECT)=' | tr '\n' ' ')
		echo "  $line${vars:+  [$vars]}"
	done
}

# energy counters, battery, wakeups and C-states over $seconds with whatever is running now
rest() {
	section "$seconds s with whatever is running now"
	for z in /sys/class/powercap/intel-rapl:*; do
		[ -r "$z/energy_uj" ] && printf '%s %s %s %s\n' "${z##*/}" "$(val "$z/name")" "$(val "$z/energy_uj")" "$(val "$z/max_energy_range_uj")"
	done >"$work/rapl0"
	bat=
	for s in /sys/class/power_supply/*; do
		[ "$(val "$s/type")" = Battery ] && { bat=$s; break; }
	done
	awk '/^ctxt/ {print "ctxt", $2} /^intr/ {print "intr", $2}' /proc/stat >"$work/stat0"
	irqs >"$work/irq0"
	idle >"$work/idle0"
	watts=
	i=0
	while [ "$i" -lt "$seconds" ]; do
		sleep 2
		i=$((i + 2))
		[ -n "$bat" ] && watts="$watts $(battery_uw "$bat")"
	done
	awk '/^ctxt/ {print "ctxt", $2} /^intr/ {print "intr", $2}' /proc/stat >"$work/stat1"
	irqs >"$work/irq1"
	idle >"$work/idle1"
	for z in /sys/class/powercap/intel-rapl:*; do
		[ -r "$z/energy_uj" ] && printf '%s %s %s %s\n' "${z##*/}" "$(val "$z/name")" "$(val "$z/energy_uj")" "$(val "$z/max_energy_range_uj")"
	done >"$work/rapl1"

	awk -v s="$i" 'NR == FNR {a[$1] = $2; next} {printf "%s per second: %d\n", $1 == "ctxt" ? "context switches" : "interrupts", ($2 - a[$1]) / s}' "$work/stat0" "$work/stat1"
	if [ -s "$work/rapl1" ]; then
		awk -v s="$i" 'NR == FNR {a[$1] = $3; next} {d = $3 - a[$1]; if (d < 0) d += $4; printf "power %s (%s): %.2f W\n", $2, $1, d / s / 1e6}' "$work/rapl0" "$work/rapl1"
	elif [ "$root" -eq 0 ]; then
		echo "power from the CPU's counters: (needs root)"
	else
		echo "power from the CPU's counters: none here"
	fi
	if [ -n "$bat" ]; then
		echo "battery: $(val "$bat/status"), $(val "$bat/capacity")%"
		echo "$watts" | awk '{n = 0; t = 0; for (i = 1; i <= NF; i++) if ($i > 0) {n++; t += $i} if (n) printf "battery draw: %.2f W, from %d readings\n", t / n / 1e6, n; else print "battery draw: not reported"}'
	else
		echo "battery: none"
	fi
	echo "busiest interrupts:"
	awk 'NR == FNR {a[$1] = $2; next} {d = $2 - a[$1]; if (d > 0) {$2 = ""; print d, $0}}' "$work/irq0" "$work/irq1" | sort -rn | head -n 8 | sed 's/^/  /'
	echo "time in each idle state, all CPUs:"
	awk -v s="$i" 'NR == FNR {a[$1] = $2; next} {printf "  %-8s %5.1f%%\n", $1, ($2 - a[$1]) / ($3 * s * 1e6) * 100}' "$work/idle0" "$work/idle1"
	awk '/^MemTotal/ {t = $2} /^MemAvailable/ {a = $2} END {printf "memory in use: %d MiB\n", (t - a) / 1024}' /proc/meminfo
	echo "processes: $(ls -d /proc/[0-9]* | wc -l)"
	echo "largest:"
	ps -eo rss=,comm= --sort=-rss 2>/dev/null | head -n 12 | awk '{printf "  %6.1f MiB %s\n", $1 / 1024, $2}'
	f=/sys/devices/system/cpu/cpu0/cpufreq
	echo "cpu: governor $(val $f/scaling_governor), preference $(val $f/energy_performance_preference), driver $(val $f/scaling_driver), pstate $(val /sys/devices/system/cpu/intel_pstate/status), no_turbo $(val /sys/devices/system/cpu/intel_pstate/no_turbo)"
	echo "awake PCI devices:"
	for d in /sys/bus/pci/devices/*; do
		[ "$(val "$d/power/runtime_status")" = active ] || continue
		printf '  %s class=%s driver=%s control=%s\n' "${d##*/}" "$(val "$d/class")" "$(basename "$(readlink "$d/driver" 2>/dev/null || echo -)")" "$(val "$d/power/control")"
	done
}

battery_uw() {
	p=$(val "$1/power_now")
	if [ "$p" = - ]; then
		# some batteries report the current as negative while they discharge
		c=$(val "$1/current_now")
		c=${c#-}
		v=$(val "$1/voltage_now")
		case $c:$v in :*|*:|*[!0-9:]*) p=0 ;; *) p=$((c / 1000 * v / 1000)) ;; esac
	fi
	p=${p#-}
	case $p in ''|*[!0-9]*) p=0 ;; esac
	printf '%s' "$p"
}

# IRQ, total count over all CPUs, what it is
irqs() {
	awk 'NR > 1 {s = 0; d = ""; for (i = 2; i <= NF; i++) if (d == "" && $i ~ /^[0-9]+$/) s += $i; else d = d " " $i; print $1, s, d}' /proc/interrupts
}

# idle state name, microseconds in it summed over CPUs, number of CPUs
idle() {
	for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
		[ -d "$s" ] || continue
		n=${s##*/}
		cat /sys/devices/system/cpu/cpu[0-9]*/cpuidle/"$n"/time 2>/dev/null |
			awk -v name="$(val "$s/name")" '{t += $1; c++} END {print name, t, c}'
	done
}

cooling() {
	section "temperatures and fans"
	for h in /sys/class/hwmon/hwmon*; do
		[ -d "$h" ] || continue
		line="$(val "$h/name"):"
		for t in "$h"/temp*_input; do
			[ -r "$t" ] || continue
			l=$(val "${t%_input}_label")
			[ "$l" = - ] && l=${t##*/} && l=${l%_input}
			line="$line $l=$(thousandths "$(val "$t")")"
		done
		for f in "$h"/fan*_input; do
			[ -r "$f" ] && { n=${f##*/}; line="$line ${n%_input}=$(val "$f")rpm"; }
		done
		for p in "$h"/pwm[0-9]; do
			[ -e "$p" ] && line="$line ${p##*/}=$(val "$p")/enable=$(val "${p}_enable")"
		done
		echo "$line"
	done
	for z in /sys/class/thermal/thermal_zone*; do
		[ -r "$z/temp" ] && printf '%s %s %s\n' "${z##*/}" "$(val "$z/type")" "$(thousandths "$(val "$z/temp")")"
	done
	echo "platform profile: $(val /sys/firmware/acpi/platform_profile) of $(val /sys/firmware/acpi/platform_profile_choices)"
	echo "msi-ec: $([ -d /sys/devices/platform/msi-ec ] && echo present || echo absent)"

	section "zcool"
	if ! have zcool; then
		echo "not installed"
		return
	fi
	if [ -r /etc/zcool.conf ]; then
		echo "/etc/zcool.conf:"
		grep -v '^[[:space:]]*#' /etc/zcool.conf | grep . | sed 's/^/  /'
	fi
	[ "$root" -eq 1 ] && echo "service: $(sv status zcool 2>&1)"
	echo
	zcool list 2>&1
	echo
	echo "undervolt:"
	if needs_root; then
		if [ ! -e /dev/cpu/0/msr ] && modprobe msr 2>/dev/null; then
			echo "  (loaded the msr module for this)"
		fi
		zcool undervolt 2>&1 | sed 's/^/  /'
		echo "probe: $(zcool undervolt probe 2>&1)"
	fi
	echo
	echo "zcool run --dry-run, $seconds s:"
	zcool run --dry-run >"$work/dry" 2>&1 &
	z=$!
	sleep "$seconds"
	kill "$z" 2>/dev/null
	wait "$z" 2>/dev/null
	tail -n 60 "$work/dry"
}

network() {
	section "network, sound, battery, screen"
	for n in /sys/class/net/*; do
		[ "${n##*/}" = lo ] && continue
		w=wired
		[ -d "$n/wireless" ] || [ -e "$n/phy80211" ] && w=wireless
		printf '%s %s %s driver=%s\n' "${n##*/}" "$w" "$(val "$n/operstate")" "$(basename "$(readlink "$n/device/driver" 2>/dev/null || echo -)")"
	done
	for r in /sys/class/rfkill/rfkill*; do
		[ -d "$r" ] && printf 'rfkill %s %s soft=%s hard=%s\n' "$(val "$r/type")" "$(val "$r/name")" "$(val "$r/soft")" "$(val "$r/hard")"
	done
	echo "bluetooth: $(ls /sys/class/bluetooth 2>/dev/null | tr '\n' ' ')"
	echo "sound cards:"
	sed 's/^/  /' /proc/asound/cards 2>/dev/null
	echo "sound daemons: $(ps -eo comm= | grep -E '^(pipewire|wireplumber|pipewire-pulse)$' | sort | uniq -c | awk '{printf "%s x%s ", $2, $1}')"
	for s in /sys/class/power_supply/*; do
		[ -d "$s" ] || continue
		line="${s##*/} $(val "$s/type") $(val "$s/status")"
		for k in capacity energy_full energy_full_design charge_full charge_full_design cycle_count manufacturer model_name technology; do
			[ -r "$s/$k" ] && line="$line $k=$(val "$s/$k")"
		done
		echo "$line"
	done
	for b in /sys/class/backlight/*; do
		[ -d "$b" ] && printf 'backlight %s %s %s/%s\n' "${b##*/}" "$(val "$b/type")" "$(val "$b/brightness")" "$(val "$b/max_brightness")"
	done
}

system() {
	section "disk and services"
	lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null
	for n in /sys/class/nvme/nvme*; do
		[ -d "$n" ] && printf '%s %s firmware %s\n' "${n##*/}" "$(val "$n/model" | sed 's/ *$//')" "$(val "$n/firmware_rev")"
	done
	echo "/: $(findmnt -no SOURCE,FSTYPE,OPTIONS / 2>/dev/null)"
	echo "swap:"
	sed 's/^/  /' /proc/swaps
	echo "runlevel $(basename "$(readlink -f /etc/runit/runsvdir/current)"): $(ls /var/service 2>/dev/null | tr '\n' ' ')"
	echo "running programs:"
	ps -eo comm= | sort | uniq -c | sort -rn | awk '{printf "  %s x%s\n", $2, $1}'

	section "kernel messages"
	if needs_root; then
		echo "errors and warnings:"
		dmesg --level=err,warn 2>&1 | tail -n 80
		echo
		echo "drivers that matter here:"
		dmesg 2>&1 | grep -iE 'nvidia|i915|xe |iwlwifi|bluetooth|thermal|throttl|msr|lockdown|secure ?boot|firmware|ACPI (BIOS )?Error|rapl' | tail -n 80
	fi
}

report() {
	echo "kombain-report: $mode, $(date '+%Y-%m-%d %H:%M')"
	machine
	boot
	section "GPUs before anything else touches them"
	gpu_states
	rest
	graphics
	devices
	network
	system
	cooling
	section "GPUs at the end"
	gpu_states
}

# MAC addresses, UUIDs, and serial numbers out of everything
redact() {
	sed -E 's/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/xx:xx:xx:xx:xx:xx/g
		s/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/UUID/g
		s/([Ss]erial[ _]?([Nn]umber)?[:=] *)[^ ,]+/\1-/g'
}

if [ "$after" -gt 0 ]; then
	echo "starting in $after s" >&3
	sleep "$after"
fi
echo "kombain-report, about $((seconds * 2 + 10)) s:" >&3
if [ "$out" = - ]; then
	report 2>&1 | redact
else
	report 2>&1 | redact >"$out" || exit 1
	echo "written to $out" >&3
	echo "Read it before sending it on. Nothing in it should identify you beyond the machine's model." >&3
fi
