#!/bin/sh
# Installs Void Linux with the kombain stack, from the Void live ISO. Asks for the disk, the
# sizes, the user and so on, erases the disk only after you type its name, and then runs
# the commands of docs/void-install-guide.md with your answers. Run as root from the repository:
#
#   ./setup.sh [--dry-run] [--serial]
#
#   --dry-run  ask everything, print the commands, change nothing
#   --serial   also a console and a login on the first serial port
#
# The commands live in the guide alone, so the two cannot drift apart. If the guide is rewritten
# in a way this script doesn't recognize, it stops before touching the disk.
#
# The questions are in plain ASCII: the console of the live ISO has no Cyrillic font.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
guide=$here/docs/void-install-guide.md

# Sizes are in MiB everywhere in this script.
BOOT_MIB=1024
OVERHEAD_MIB=64 # for each encrypted partition: LUKS header, LVM metadata, alignment
MIN_ROOT=20480
MIN_GAMER=10240
MIN_DEV=1024

dry_run=0
serial=0

# The answers
disk= suffix= disk_mib=0 disk_model=
root_mib=0 gamer_mib=0 dev_mib=0 free_mib=0
user=dev hostname=voidbox timezone=Europe/Moscow
gpus= wired= wifi_ssid= wifi_pass= desktop=1

die() {
	echo "setup.sh: $*" >&2
	exit 1
}

# Everything typed goes through here: without a terminal, asking again would never end.
ask() {
	printf '%s' "$1" >&2
	IFS= read -r answer || die "no more input"
	printf '%s\n' "$answer"
}

ask_yes() { # question, default y or n
	case $2 in y) hint='[Y/n]' ;; *) hint='[y/N]' ;; esac
	while :; do
		a=$(ask "$1 $hint: ")
		case ${a:-$2} in
		[yY]*) return 0 ;;
		[nN]*) return 1 ;;
		esac
		echo "Please answer y or n." >&2
	done
}

# ---------------------------------------------------------------- sizes

# "80", "80G", "80 GiB", "1.5T", "500M": a number without a unit is GiB. Prints MiB.
parse_size() {
	printf '%s\n' "$1" | awk '
		!/^[0-9]+(\.[0-9]+)?[ ]*([MmGgTt]([Ii]?[Bb])?)?$/ { exit 1 }
		{
			n = $0 + 0
			u = $0
			gsub(/[^MmGgTt]/, "", u)
			m = (u ~ /[Mm]/) ? 1 : (u ~ /[Tt]/) ? 1048576 : 1024
			printf "%.0f\n", int(n * m)
		}'
}

fmt_size() {
	awk -v m="$1" 'BEGIN {
		if (m >= 1048576) printf "%.1f TiB", m / 1048576
		else if (m >= 1024) { g = m / 1024; if (g == int(g)) printf "%d GiB", g; else printf "%.1f GiB", g }
		else printf "%d MiB", m
	}'
}

ask_size() { # prompt, default, min, max
	d=$2
	[ "$d" -le "$4" ] || d=$4
	while :; do
		a=$(ask "$1 [$(fmt_size "$d")]: ")
		if [ -z "$a" ]; then
			echo "$d"
			return
		fi
		if ! v=$(parse_size "$a") || [ -z "$v" ]; then
			echo "Not a size. Examples: 80G, 500M, 1.5T." >&2
		elif [ "$v" -lt "$3" ]; then
			echo "At least $(fmt_size "$3") here." >&2
		elif [ "$v" -gt "$4" ]; then
			echo "That does not fit: at most $(fmt_size "$4") here." >&2
		else
			echo "$v"
			return
		fi
	done
}

whole_gib() {
	echo $(($1 / 1024 * 1024))
}

usable_mib() {
	echo $((disk_mib - BOOT_MIB - 2 * OVERHEAD_MIB))
}

# Room to grow later: XFS can be enlarged but never shrunk.
default_free() {
	f=$(($1 / 50))
	[ "$f" -ge 1024 ] || f=1024
	[ "$f" -le 51200 ] || f=51200
	echo "$f"
}

default_root() {
	r=$(($1 / 10))
	[ "$r" -ge 30720 ] || r=30720
	[ "$r" -le 81920 ] || r=81920
	# a small disk: the other two need their share
	max=$(($1 - MIN_GAMER - MIN_DEV))
	[ "$r" -le "$max" ] || r=$max
	whole_gib "$r"
}

default_gamer() { # usable, root
	g=$((($1 - $2 - $(default_free "$1")) / 2))
	[ "$g" -ge "$MIN_GAMER" ] || g=$MIN_GAMER
	whole_gib "$g"
}

default_dev() { # usable, root, gamer
	d=$(($1 - $2 - $3 - $(default_free "$1")))
	[ "$d" -ge "$MIN_DEV" ] || d=$MIN_DEV
	max=$(($1 - $2 - $3))
	[ "$d" -le "$max" ] || d=$max
	echo "$d"
}

ask_sizes() {
	usable=$(usable_mib)
	echo
	echo "$disk has $(fmt_size "$disk_mib"). 1 GiB goes to /boot, the rest is yours."
	# asked again, the last answers are the defaults
	d_root=$root_mib d_gamer=$gamer_mib d_dev=$dev_mib
	[ "$d_root" -gt 0 ] || d_root=$(default_root "$usable")
	root_mib=$(ask_size "Size of / (the system and programs)" "$d_root" "$MIN_ROOT" $((usable - MIN_GAMER - MIN_DEV)))
	[ "$d_gamer" -gt 0 ] || d_gamer=$(default_gamer "$usable" "$root_mib")
	gamer_mib=$(ask_size "Size of /home/gamer (games)" "$d_gamer" "$MIN_GAMER" $((usable - root_mib - MIN_DEV)))
	[ "$d_dev" -gt 0 ] || d_dev=$(default_dev "$usable" "$root_mib" "$gamer_mib")
	dev_mib=$(ask_size "Size of /home/$user (your files)" "$d_dev" "$MIN_DEV" $((usable - root_mib - gamer_mib)))
	free_mib=$((usable - root_mib - gamer_mib - dev_mib))
}

# The second partition: everything in LVM, and the free space stays there to grow into later.
system_part_mib() {
	echo $((root_mib + gamer_mib + free_mib + OVERHEAD_MIB))
}

show_layout() {
	echo
	echo "Disk $disk, $(fmt_size "$disk_mib")${disk_model:+, $disk_model}:"
	echo "  ${disk}${suffix}1  1 GiB, /boot"
	echo "  ${disk}${suffix}2  encrypted, unlocked in both modes:"
	echo "      /            $(fmt_size "$root_mib")"
	echo "      /home/gamer  $(fmt_size "$gamer_mib")"
	echo "      free         $(fmt_size "$free_mib"), to enlarge either of them later (XFS can't shrink)"
	echo "  ${disk}${suffix}3  encrypted with its own passphrase, locked in Gaming mode:"
	echo "      /home/$user  $(fmt_size "$dev_mib")"
	echo
}

# ---------------------------------------------------------------- the disk

# A disk's partitions are diskp1 if its name ends in a digit (nvme0n1p1, mmcblk0p1), else disk1 (sda1).
part_suffix() {
	case $1 in
	*[0-9]) echo p ;;
	*) echo "" ;;
	esac
}

# Disks that can be installed on: "name size-in-bytes model". Anything in use is left out, and
# that covers the stick this system runs from.
list_disks() {
	lsblk -dnbp -o NAME,SIZE,TYPE,MODEL | while read -r name bytes type model; do
		[ "$type" = disk ] || continue
		case $name in /dev/zram* | /dev/ram*) continue ;; esac
		[ -z "$(lsblk -nlo MOUNTPOINT "$name" 2>/dev/null | tr -d '[:space:]')" ] || continue
		echo "$name $bytes $model"
	done
}

ask_disk() {
	disks=$(list_disks)
	[ -n "$disks" ] || die "no disk to install on: every disk here is in use"
	count=$(printf '%s\n' "$disks" | wc -l | tr -d ' ')
	echo
	echo "Disks:"
	i=0
	printf '%s\n' "$disks" | while read -r name bytes model; do
		i=$((i + 1))
		echo "  $i) $name  $(fmt_size $((bytes / 1048576)))  $model"
	done
	default=
	[ "$count" -gt 1 ] || default=1
	while :; do
		n=$(ask "Install on disk number${default:+ [$default]}: ")
		n=${n:-$default}
		case $n in
		'' | *[!0-9]*) n=0 ;;
		esac
		if [ "$n" -ge 1 ] && [ "$n" -le "$count" ]; then
			break
		fi
		echo "That is not on the list." >&2
	done
	line=$(printf '%s\n' "$disks" | sed -n "${n}p")
	disk=${line%% *}
	rest=${line#* }
	disk_mib=$((${rest%% *} / 1048576))
	case $rest in
	*' '*) disk_model=${rest#* } ;;
	*) disk_model= ;;
	esac
	suffix=$(part_suffix "$disk")
	if [ "$(usable_mib)" -lt $((MIN_ROOT + MIN_GAMER + MIN_DEV)) ]; then
		die "$disk is too small: at least $(fmt_size $((MIN_ROOT + MIN_GAMER + MIN_DEV + BOOT_MIB + 2 * OVERHEAD_MIB))) is needed"
	fi
}

# ---------------------------------------------------------------- the rest of the answers

valid_user() {
	case $1 in
	root | gamer | nobody) return 1 ;;
	esac
	printf '%s\n' "$1" | grep -Eq '^[a-z_][a-z0-9_-]{0,30}$'
}

ask_user() {
	while :; do
		a=$(ask "User name [$user]: ")
		a=${a:-$user}
		if valid_user "$a"; then
			user=$a
			return
		fi
		echo "Lowercase letters, digits, - and _, not root or gamer." >&2
	done
}

valid_hostname() {
	printf '%s\n' "$1" | grep -Eq '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'
}

ask_hostname() {
	while :; do
		a=$(ask "Host name [$hostname]: ")
		a=${a:-$hostname}
		if valid_hostname "$a"; then
			hostname=$a
			return
		fi
		echo "Letters, digits and -." >&2
	done
}

# A path below the zoneinfo folder, nothing that could climb out of it.
valid_timezone() {
	printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$' || return 1
	if [ -d /usr/share/zoneinfo ]; then
		[ -f "/usr/share/zoneinfo/$1" ]
	fi
}

ask_timezone() {
	while :; do
		a=$(ask "Time zone [$timezone]: ")
		a=${a:-$timezone}
		if valid_timezone "$a"; then
			timezone=$a
			return
		fi
		echo "No such time zone. Examples: Europe/Berlin, Asia/Tokyo, UTC." >&2
	done
}

# What the PCI bus has: amd, intel, nvidia. The numbers are the driver menu's.
detected_gpus() {
	found=
	for dev in "${KOMBAIN_PCI:-/sys/bus/pci/devices}"/*; do
		[ -e "$dev/class" ] || continue
		case $(cat "$dev/class") in
		0x03*) ;;
		*) continue ;;
		esac
		case $(cat "$dev/vendor") in
		0x1002) found="$found 1" ;;
		0x8086) found="$found 2" ;;
		0x10de) found="$found 3" ;;
		esac
	done
	echo "${found# }"
}

ask_gpus() {
	default=$(detected_gpus)
	echo
	echo "Graphics drivers:"
	echo "  1) AMD"
	echo "  2) Intel"
	echo "  3) NVIDIA, Turing and newer (GTX 16xx, RTX 20xx and up)"
	echo "  4) NVIDIA, older: Maxwell, Pascal, Volta"
	echo "  5) None of these: only the basic drivers"
	default=${default:-5}
	while :; do
		a=$(ask "Numbers, with spaces between them for several [$default]: ")
		a=${a:-$default}
		case $a in
		*[!1-5\ ]* | '') echo "Numbers from 1 to 5." >&2 ;;
		*)
			gpus=$a
			return
			;;
		esac
	done
}

wants_nvidia() {
	case " $gpus " in
	*' 3 '* | *' 4 '*) return 0 ;;
	esac
	return 1
}

# The wired interface that is up right now, if any.
wired_interface() {
	for dev in "${KOMBAIN_NET:-/sys/class/net}"/*; do
		[ -e "$dev/device" ] || continue
		[ ! -e "$dev/wireless" ] || continue
		if [ "$(cat "$dev/operstate" 2>/dev/null)" = up ]; then
			basename "$dev"
			return
		fi
	done
}

has_wifi() {
	for dev in "${KOMBAIN_NET:-/sys/class/net}"/*; do
		[ -e "$dev/wireless" ] && return 0
	done
	return 1
}

ask_network() {
	echo
	iface=$(wired_interface)
	if [ -n "$iface" ] && ask_yes "Use the wired network on $iface in the installed system?" y; then
		wired=$iface
	fi
	if has_wifi; then
		wifi_ssid=$(ask "Wi-Fi network to join at first boot (empty: none): ")
		if [ -n "$wifi_ssid" ]; then
			stty -echo 2>/dev/null || true
			wifi_pass=$(ask "Its password: ")
			stty echo 2>/dev/null || true
			echo >&2
		fi
	fi
}

# iwd names a network's file after its SSID, or =hex if the SSID has anything else in it.
iwd_file_name() {
	if printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9_ -]+$'; then
		printf '%s.psk' "$1"
	else
		printf '=%s.psk' "$(printf '%s' "$1" | od -An -tx1 | tr -d ' \n')"
	fi
}

# ---------------------------------------------------------------- the guide's commands

# The guide's block whose first line starts with $1 (and second with $2, if given). It must be
# exactly one: a rewritten guide stops the script here, before anything is touched.
block() {
	awk -v first="$1" -v second="${2:-}" '
		function done_block() {
			if (n >= 1 && index(lines[1], first) == 1 && (second == "" || index(lines[2], second) == 1)) {
				found++
				if (found == 1) for (i = 1; i <= n; i++) out = out lines[i] "\n"
			}
		}
		/^```bash$/ && !inside { inside = 1; n = 0; next }
		/^```$/ && inside { inside = 0; done_block(); next }
		inside { lines[++n] = $0 }
		END {
			if (found != 1) { printf "%d", found > "/dev/stderr"; exit 3 }
			printf "%s", out
		}' "$guide" 2>/dev/null || die "the guide has no single block starting with: $1"
}

# Replaces text that must be there: if it isn't, the guide changed and this script must too.
swap() { # text, old, new (fixed strings)
	case $1 in
	*"$2"*) ;;
	*) die "the guide no longer has: $2" ;;
	esac
	printf '%s' "$1" | awk -v old="$2" -v new="$3" '
		BEGIN {
			# awk would read backslashes in a -v value as escapes; these values have none
			RS = "\001"
		}
		{
			out = ""
			rest = $0
			while ((i = index(rest, old)) > 0) {
				out = out substr(rest, 1, i - 1) new
				rest = substr(rest, i + length(old))
			}
			printf "%s%s", out, rest
		}'
}

# What every block with a disk or a user in it needs.
adapt() {
	t=$1
	case $t in
	*'${DISK}p'*) t=$(swap "$t" '${DISK}p' "\${DISK}$suffix") ;;
	esac
	case $t in
	*'/home/dev'*) t=$(swap "$t" /home/dev "/home/$user") ;;
	esac
	printf '%s\n' "$t"
}

step_disk() {
	t=$(adapt "$(block DISK=/dev/nvme0n1 cfdisk)")
	t=$(swap "$t" DISK=/dev/nvme0n1 "DISK=$disk")
	t=$(swap "$t" 'cfdisk -z "$DISK"' "printf 'label: gpt\\nsize=1G, type=U\\nsize=$(system_part_mib)M, type=L\\ntype=L\\n' | sfdisk --wipe always --wipe-partitions always \"\$DISK\"
udevadm settle
for i in 1 2 3 4 5 6 7 8 9 10; do [ -b \"\${DISK}${suffix}3\" ] && break; sleep 1; done")
	# A mistyped confirmation of a new passphrase asks again, instead of ending the installation.
	t=$(swap "$t" "cryptsetup luksFormat --type luks2 \"\${DISK}${suffix}2\"" "echo
echo 'The passphrase for the system and games: you type it at every boot.'
until cryptsetup luksFormat --batch-mode --verify-passphrase --type luks2 \"\${DISK}${suffix}2\"; do echo 'Again:'; done")
	t=$(swap "$t" "cryptsetup luksFormat --type luks2 \"\${DISK}${suffix}3\"   # a different passphrase" "echo
echo 'A DIFFERENT passphrase for your files: only Dev mode asks for it.'
until cryptsetup luksFormat --batch-mode --verify-passphrase --type luks2 \"\${DISK}${suffix}3\"; do echo 'Again:'; done
echo
echo 'Now both passphrases once more, to open them:'")
	t=$(swap "$t" 'lvcreate -L 80G -n root vg0' "lvcreate -y -L ${root_mib}M -n root vg0")
	t=$(swap "$t" 'lvcreate -L 400G -n gamer vg0' "lvcreate -y -L ${gamer_mib}M -n gamer vg0")
	printf '%s\n' "$t"
}

step_base() {
	t=$(block REPO=https://)
	case $t in
	*'xchroot /mnt /bin/bash') ;;
	*) die "the guide's step 3 no longer ends by entering the chroot" ;;
	esac
	t=$(printf '%s\n' "$t" | sed '$d')
	t=$(swap "$t" 'xbps-install -S -r /mnt' 'xbps-install -Sy -r /mnt')
	printf '%s\n' "$t"
}

# A mistyped new password asks again.
retry_passwd() {
	printf '%s\n' "$1" | sed -E 's/^passwd( .*)?$/until passwd\1; do echo Again:; done/'
}

step_settings() {
	t=$(adapt "$(block DISK=/dev/nvme0n1 'echo voidbox')")
	t=$(swap "$t" DISK=/dev/nvme0n1 "DISK=$disk")
	t=$(swap "$t" 'echo voidbox' "echo $hostname")
	t=$(swap "$t" Europe/Moscow "$timezone")
	# the live ISO may have no zoneinfo to check the answer against
	t=$(swap "$t" "/etc/localtime
" "/etc/localtime
[ -e /etc/localtime ] || { echo 'Unknown time zone, using UTC.'; ln -sf /usr/share/zoneinfo/UTC /etc/localtime; }
")
	retry_passwd "$t"
}

step_microcode() {
	cpu_is GenuineIntel || return 0
	block 'xbps-install -y intel-ucode'
}

# Firmware for hardware this machine doesn't have: hundreds of MiB that nothing would ever load.
has_vendor() { # PCI vendor of a display adapter
	for dev in "${KOMBAIN_PCI:-/sys/bus/pci/devices}"/*; do
		[ -e "$dev/class" ] || continue
		case $(cat "$dev/class") in 0x03*) ;; *) continue ;; esac
		[ "$(cat "$dev/vendor")" = "$1" ] && return 0
	done
	return 1
}

cpu_is() {
	grep -q "$1" "${KOMBAIN_CPUINFO:-/proc/cpuinfo}" 2>/dev/null
}

step_firmware() {
	drop=
	has_vendor 0x10de || drop="$drop linux-firmware-nvidia"
	has_vendor 0x1002 || cpu_is AuthenticAMD || drop="$drop linux-firmware-amd"
	has_vendor 0x8086 || cpu_is GenuineIntel || drop="$drop linux-firmware-intel"
	[ -n "$drop" ] || return 0
	echo "printf 'ignorepkg=%s\\n'$drop > /etc/xbps.d/11-firmware.conf"
	echo "xbps-remove -Ry$drop"
}

step_gpu() {
	lines=$(block 'xbps-install -y mesa-dri')
	echo 'xbps-install -y mesa-dri vulkan-loader'
	for g in $gpus; do
		case $g in
		1) pat='# AMD' ;;
		2) pat='# Intel' ;;
		3) pat='# NVIDIA Turing' ;;
		4) pat='# NVIDIA Maxwell' ;;
		*) continue ;;
		esac
		line=$(printf '%s\n' "$lines" | grep -F "$pat") || die "the guide has no driver line for: $pat"
		printf '%s\n' "$line"
	done
}

step_fstab() {
	adapt "$(block 'cat > /etc/fstab')"
	# shellcheck disable=SC2016 # expanded in the chroot
	printf '%s\n' "sed -i \"s/XXXX-XXXX/\$(blkid -s UUID -o value \"${disk}${suffix}1\")/\" /etc/fstab"
}

step_hook() {
	t=$(adapt "$(block 'mkdir -p /etc/kernel.d/post-install')")
	t=$(printf 'DISK=%s\n%s' "$disk" "$t")
	if [ "$serial" -eq 1 ]; then
		t=$(swap "$t" 'rw quiet loglevel=3' 'rw quiet loglevel=3 console=tty0 console=ttyS0,115200')
	fi
	if wants_nvidia; then
		# the guide's step 5: NVIDIA's modules are unsigned, and lockdown would refuse them
		t=$(swap "$t" 'lockdown=integrity' 'nvidia_drm.modeset=1')
	fi
	printf '%s\n' "$t"
}

step_wired() {
	# (dhcpcd-eth0 is the service the guide's commands copy, and it comes with the system)
	[ -n "$wired" ] && [ "$wired" != eth0 ] || return 0
	t=$(block IF=enp3s0)
	swap "$t" IF=enp3s0 "IF=$wired"
	echo
}

step_links() {
	for r in default gaming; do
		[ -z "$wired" ] || echo "ln -sfn /etc/sv/dhcpcd-$wired /etc/runit/runsvdir/$r/"
		[ "$serial" -eq 0 ] || echo "ln -sfn /etc/sv/agetty-ttyS0 /etc/runit/runsvdir/$r/"
		# (iwd only handles Wi-Fi)
		has_wifi || echo "rm -f /etc/runit/runsvdir/$r/iwd"
	done
	echo :
}

step_users() {
	t=$(adapt "$(block 'useradd -m -G wheel')")
	t=$(swap "$t" 'wheel,audio,video dev' "wheel,audio,video $user")
	t=$(swap "$t" 'passwd dev' "passwd $user")
	t=$(swap "$t" 'dev:dev' "$user:$user")
	t=$(printf "echo\necho 'Passwords for the two users:'\n%s" "$t")
	retry_passwd "$t"
}

# The guide's own list of what must be true before leaving the chroot: a wrong config here
# would be an unbootable machine and a confusing evening.
step_verify() {
	cat <<'EOF'
ls /boot/vmlinuz-* /boot/initramfs-* /boot/limine.conf /boot/EFI/BOOT/BOOTX64.EFI
if grep -qE 'ROOT-UUID|DEV-UUID' /boot/limine.conf; then echo 'limine.conf still has placeholders'; exit 1; fi
awk '/^\/Void Dev$/ { d = 1; g = 0 } /^\/Void Gaming$/ { g = 1; d = 0 } /cmdline/ {
	n = gsub(/rd\.luks\.uuid=/, "&")
	if (d && n != 2) { print "Void Dev must unlock two volumes"; bad = 1 }
	if (g && n != 1) { print "Void Gaming must unlock one"; bad = 1 }
	d = g = 0
} END { exit bad }' /boot/limine.conf
efibootmgr | grep -q Limine
EOF
}

# The file iwd would write itself after `iwctl station ... connect`. It is on the encrypted disk,
# and only root can read it.
step_wifi() {
	[ -n "$wifi_ssid" ] || return 0
	file=$(iwd_file_name "$wifi_ssid")
	pass=$wifi_pass
	[ "$dry_run" -eq 0 ] || pass='(the password)'
	printf 'install -d -m 700 /var/lib/iwd\n'
	printf "cat > '/var/lib/iwd/%s' <<'KOMBAIN_EOF'\n[Security]\nPassphrase=%s\nKOMBAIN_EOF\n" "$file" "$pass"
	printf "chmod 600 '/var/lib/iwd/%s'\n" "$file"
}

step_desktop() {
	[ "$desktop" -eq 1 ] || return 0
	cat <<EOF
cd /root/kombain
./install.sh --user $user
chsh -s /usr/local/bin/fdash $user
EOF
}

# Builds every step before anything runs, so a guide this script no longer understands
# stops it while the disk is still untouched.
prepare_steps() {
	s_disk=$(step_disk)
	s_base=$(step_base)
	s_settings=$(step_settings)
	s_firmware=$(step_firmware)
	s_microcode=$(step_microcode)
	s_gpu=$(step_gpu)
	s_fstab=$(step_fstab)
	s_dracut=$(block 'mkdir -p /etc/dracut.conf.d')
	s_hook=$(step_hook)
	s_iwd=$(block 'mkdir -p /etc/iwd')
	s_wired=$(step_wired)
	s_sysctl=$(block 'mkdir -p /etc/sysctl.d')
	s_firewall=$(adapt "$(block 'cat > /etc/nftables.conf')")
	s_power=$(block 'cat > /etc/modprobe.d/kombain.conf')
	s_runlevels=$(block 'mkdir -p /etc/sv/game-tune')
	s_links=$(step_links)
	s_users=$(step_users)
	s_wifi=$(step_wifi)
	s_boot=$(block 'xbps-reconfigure -fa')
	s_verify=$(step_verify)
	s_desktop=$(step_desktop)
	s_clean=$(block 'doas sh -c')
	s_clean=${s_clean#doas }
}

live() { # name, commands
	echo
	echo "==> $1"
	if [ "$dry_run" -eq 1 ]; then
		printf '%s\n' "$2"
		return
	fi
	sh -e -c "$2"
}

chrooted() { # name, commands
	[ -n "$2" ] || return 0
	echo
	echo "==> $1"
	if [ "$dry_run" -eq 1 ]; then
		printf '%s\n' "$2"
		return
	fi
	(umask 077 && printf '%s\n' "$2" >/mnt/tmp/kombain-step)
	xchroot /mnt /bin/bash -e /tmp/kombain-step
	rm -f /mnt/tmp/kombain-step
}

# ---------------------------------------------------------------- before anything is erased

# What an interrupted run leaves behind. Only this script's own names are touched.
clean_previous() {
	grep -q ' /mnt[ /]' /proc/mounts || [ -e /dev/mapper/cryptroot ] || [ -e /dev/mapper/cryptdev ] || return 0
	echo
	echo "An earlier attempt left /mnt mounted or its volumes open."
	ask_yes "Close them and start over?" y || die "stopped: close them yourself"
	umount -R /mnt 2>/dev/null || true
	vgchange -an vg0 >/dev/null 2>&1 || true
	for m in cryptroot cryptdev; do
		[ ! -e "/dev/mapper/$m" ] || cryptsetup close "$m"
	done
}

check_system() {
	[ "$(id -u)" -eq 0 ] || die "run as root"
	[ -d /run/initramfs/live ] || die "run this from the Void live ISO: it erases a whole disk"
	[ -d /sys/firmware/efi ] || die "the machine booted in BIOS mode: enable UEFI and boot the ISO again"
	[ "$(uname -m)" = x86_64 ] || die "this is for x86_64"
	# Known to everyone, so it goes first: the ISO's SSH accepts root with the password voidlinux.
	sv down sshd >/dev/null 2>&1 || true
	getent hosts repo-default.voidlinux.org >/dev/null || die "no network. See step 1 of the guide for Wi-Fi."
}

check_vg() {
	if vgs vg0 >/dev/null 2>&1; then
		die "a volume group vg0 already exists on this machine. Remove the other disk, or that group, first."
	fi
}

confirm_erase() {
	name=${disk##*/}
	show_layout
	echo "User $user, host $hostname, time zone $timezone, graphics $gpus."
	echo
	lsblk -o NAME,SIZE,FSTYPE,LABEL "$disk" 2>/dev/null || true
	echo
	echo "EVERYTHING on $disk will be erased. Nothing has been touched so far."
	while :; do
		a=$(ask "Type $name to erase it, or stop to quit: ")
		case $a in
		"$name") return ;;
		stop) die "stopped. Nothing was erased." ;;
		esac
		echo "That is not the disk's name. Nothing was erased." >&2
	done
}

# ---------------------------------------------------------------- main

install_system() {
	live "Disk: partitions, encryption, file systems (guide, step 2)" "$s_disk"
	live "Base system (step 3)" "$s_base"
	if [ "$dry_run" -eq 0 ] && [ "$desktop" -eq 1 ]; then
		cp -R "$here" /mnt/root/kombain
	fi
	chrooted "System settings (step 4); now a password for root" "$s_settings"
	chrooted "Firmware for hardware this machine doesn't have" "$s_firmware"
	chrooted "CPU microcode" "$s_microcode"
	chrooted "Graphics drivers" "$s_gpu"
	chrooted "fstab" "$s_fstab"
	chrooted "initramfs settings" "$s_dracut"
	chrooted "Limine (step 5)" "$s_hook"
	chrooted "iwd (step 6)" "$s_iwd"
	chrooted "Wired network" "$s_wired"
	chrooted "Kernel settings (step 7)" "$s_sysctl"
	chrooted "Firewall and boot services" "$s_firewall"
	chrooted "Power saving and unused modules" "$s_power"
	chrooted "The two modes (step 8)" "$s_runlevels"
	chrooted "Services for this machine" "$s_links"
	chrooted "Users (step 9)" "$s_users"
	chrooted "Wi-Fi" "$s_wifi"
	chrooted "Kernel and boot menu (step 10)" "$s_boot"
	chrooted "Checking that it will boot" "$s_verify"
	chrooted "Desktop and tools: install.sh (several minutes)" "$s_desktop"
	chrooted "Removing the package cache" "$s_clean"
}

finish() {
	if [ "$dry_run" -eq 1 ]; then
		echo
		echo "That was a dry run: nothing was changed."
		return
	fi
	root_uuid=$(blkid -s UUID -o value "${disk}${suffix}2")
	dev_uuid=$(blkid -s UUID -o value "${disk}${suffix}3")
	umount -R /mnt
	cat <<EOF

Done. In the boot menu, Void Dev asks for two passphrases and Void Gaming for one.
  ${disk}${suffix}2  LUKS UUID $root_uuid  the system and games
  ${disk}${suffix}3  LUKS UUID $dev_uuid  your files

After the first boot, see step 11 of the guide for Steam and for zcool, and step 12 for
Secure Boot: until then, someone with access to the machine could replace the kernel on /boot.
EOF
	ask "Remove the installation stick and press Enter to reboot: " >/dev/null
	reboot
}

main() {
	while [ $# -gt 0 ]; do
		case $1 in
		--dry-run) dry_run=1 ;;
		--serial) serial=1 ;;
		-h | --help)
			sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*) die "unknown option: $1" ;;
		esac
		shift
	done
	[ -r "$guide" ] || die "run this from the kombain repository: no $guide"

	[ "$dry_run" -eq 1 ] || check_system
	[ "$dry_run" -eq 1 ] || clean_previous
	[ "$dry_run" -eq 1 ] || check_vg

	ask_disk
	ask_user
	while :; do
		ask_sizes
		show_layout
		ask_yes "Is this right?" y && break
	done
	ask_hostname
	ask_timezone
	ask_gpus
	if wants_nvidia; then
		echo "NVIDIA's modules are unsigned, so kernel lockdown stays off on this machine (guide, step 5)."
	fi
	ask_network
	echo
	ask_yes "Install the desktop and tools (mango, netline, fdash, zcool)?" y || desktop=0

	prepare_steps
	[ "$dry_run" -eq 1 ] || confirm_erase
	install_system
	finish
}

# tests/setup-logic.sh loads the functions without running anything
[ "${KOMBAIN_SETUP_LIB:-0}" = 1 ] || main "$@"
