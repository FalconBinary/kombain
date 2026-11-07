#!/bin/sh
# setup.sh without a disk: its arithmetic and checks, and whole dialogs in --dry-run, with fake
# commands that fail the test if anything that changes a disk is ever called.
# Needs no root and touches nothing. tests/vm/install.py --flow setup runs it for real.
set -u

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pass=0
fail=0

ok() {
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		echo "FAIL  $1: expected [$3], got [$2]"
	fi
}

yes_() { # name, command...
	n=$1
	shift
	if "$@"; then pass=$((pass + 1)); else
		fail=$((fail + 1))
		echo "FAIL  $n"
	fi
}

no_() {
	n=$1
	shift
	if "$@"; then
		fail=$((fail + 1))
		echo "FAIL  $n"
	else pass=$((pass + 1)); fi
}

KOMBAIN_SETUP_LIB=1
# shellcheck disable=SC1091
. "$repo/setup.sh"
set +e
set -u

# ---------------------------------------------------------------- sizes

ok "a number is GiB" "$(parse_size 80)" 81920
ok "G" "$(parse_size 80G)" 81920
ok "g" "$(parse_size 80g)" 81920
ok "GB" "$(parse_size 80GB)" 81920
ok "GiB" "$(parse_size '80 GiB')" 81920
ok "M" "$(parse_size 512M)" 512
ok "T" "$(parse_size 2T)" 2097152
ok "fractions" "$(parse_size 1.5T)" 1572864
ok "fractions of GiB" "$(parse_size 0.5G)" 512
no_ "words are not a size" parse_size banana
no_ "nor empty" parse_size ''
no_ "nor negative" parse_size -5G
no_ "nor two numbers" parse_size '1 2'
no_ "nor another unit" parse_size 5K
no_ "nor a command" parse_size '$(reboot)'

ok "shows GiB" "$(fmt_size 81920)" "80 GiB"
ok "shows MiB" "$(fmt_size 512)" "512 MiB"
ok "shows fractions" "$(fmt_size 1536)" "1.5 GiB"
ok "shows TiB" "$(fmt_size 2097152)" "2.0 TiB"

# ---------------------------------------------------------------- defaults fit any disk

for gib in 33 40 64 120 128 256 480 500 512 1000 1024 2000 4000 8000 16000; do
	u=$((gib * 1024 - BOOT_MIB - 2 * OVERHEAD_MIB))
	r=$(default_root "$u")
	g=$(default_gamer "$u" "$r")
	d=$(default_dev "$u" "$r" "$g")
	yes_ "$gib GiB: / is big enough" [ "$r" -ge "$MIN_ROOT" ]
	yes_ "$gib GiB: games are big enough" [ "$g" -ge "$MIN_GAMER" ]
	yes_ "$gib GiB: files are big enough" [ "$d" -ge "$MIN_DEV" ]
	yes_ "$gib GiB: it all fits" [ $((r + g + d)) -le "$u" ]
	yes_ "$gib GiB: the free space is not huge" [ $((u - r - g - d)) -le 51200 ]
done
# a typical disk comes out sensible
u=$((1000 * 1024 - BOOT_MIB - 2 * OVERHEAD_MIB))
ok "1 TB: /" "$(default_root "$u")" 81920

# ---------------------------------------------------------------- names

ok "NVMe partitions" "$(part_suffix /dev/nvme0n1)" p
ok "SD card partitions" "$(part_suffix /dev/mmcblk0)" p
ok "SATA partitions" "$(part_suffix /dev/sda)" ""
ok "virtio partitions" "$(part_suffix /dev/vda)" ""

yes_ "a plain user" valid_user alice
yes_ "with digits and dash" valid_user dev-2
no_ "root is taken" valid_user root
no_ "gamer is taken" valid_user gamer
no_ "capitals" valid_user Alice
no_ "spaces" valid_user "al ice"
no_ "a path" valid_user ../etc
no_ "a command" valid_user 'a;reboot'
no_ "too long" valid_user aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
yes_ "a host name" valid_hostname my-box2
no_ "a host name with a dot" valid_hostname a.b
no_ "a host name with a slash" valid_hostname a/b
no_ "a zone climbing out" valid_timezone ../../etc/passwd
no_ "a zone with a space" valid_timezone 'Europe/ Berlin'

ok "plain SSID" "$(iwd_file_name 'My Home-5G')" "My Home-5G.psk"
ok "SSID with other characters is hex" "$(iwd_file_name "a'b")" "=612762.psk"
ok "non-ASCII SSID is hex" "$(iwd_file_name 'дом')" "=d0b4d0bed0bc.psk"

mirror_is() {
	(set_mirror "$1" 2>/dev/null && echo "$mirror")
}
ok "a mirror" "$(mirror_is https://mirror.yandex.ru/mirrors/voidlinux)" https://mirror.yandex.ru/mirrors/voidlinux
ok "its slash at the end goes" "$(mirror_is https://mirror.yandex.ru/mirrors/voidlinux/)" https://mirror.yandex.ru/mirrors/voidlinux
ok "a port" "$(mirror_is https://void.example.org:8443/void)" https://void.example.org:8443/void
ok "no plain http: the package lists are not signed" "$(mirror_is http://ftp.debian.ru/mirrors/voidlinux)" ""
ok "nothing a shell would read" "$(mirror_is 'https://a.org/x;reboot')" ""
ok "no spaces" "$(mirror_is 'https://a.org/x y')" ""
ok "no quotes" "$(mirror_is "https://a.org/x'y")" ""
ok "no substitutions" "$(mirror_is 'https://a.org/$(reboot)')" ""
ok "not empty" "$(mirror_is '')" ""
for m in $MIRRORS_TIER1 $MIRRORS_TIER2; do
	ok "the list's $m is a mirror setup.sh takes" "$(mirror_is "$m")" "$m"
done

# ---------------------------------------------------------------- the guide

guide=$repo/docs/void-install-guide.md
for start in 'DISK=/dev/nvme0n1|cfdisk' 'REPO=https://' 'DISK=/dev/nvme0n1|echo voidbox' 'xbps-install -y intel-ucode' \
	'xbps-install -y mesa-dri' 'cat > /etc/fstab' 'mkdir -p /etc/dracut.conf.d' 'mkdir -p /etc/kernel.d/post-install' \
	'mkdir -p /etc/iwd' 'IF=enp3s0' "printf 'ignorepkg=dhcpcd" "echo 'options nvidia NVreg_DynamicPowerManagement" 'mkdir -p /etc/sysctl.d' 'cat > /etc/nftables.conf' 'mkdir -p /etc/sv/game-tune' \
	'useradd -m -G wheel' 'xbps-reconfigure -fa' 'cat > /etc/modprobe.d/kombain.conf' 'doas sh -c'; do
	first=${start%%|*}
	second=
	case $start in *'|'*) second=${start#*|} ;; esac
	(block "$first" "$second" >/dev/null) 2>/dev/null
	ok "the guide has one block: $start" $? 0
done

# ---------------------------------------------------------------- whole dialogs, for real but dry

mkdir -p "$work/bin" "$work/net/eth9/device" "$work/pci/gpu"
echo up >"$work/net/eth9/operstate"
echo 0x030000 >"$work/pci/gpu/class"
echo 0x10de >"$work/pci/gpu/vendor"
echo 'vendor_id : GenuineIntel' >"$work/cpuinfo"
for c in sfdisk cryptsetup pvcreate vgcreate lvcreate mkfs.xfs mkfs.vfat wipefs mount umount xchroot xbps-install reboot chroot blockdev dd; do
	cat >"$work/bin/$c" <<EOF
#!/bin/sh
echo "$c \$*" >>"$work/called"
exit 1
EOF
	chmod +x "$work/bin/$c"
done
cat >"$work/bin/lsblk" <<EOF
#!/bin/sh
case "\$*" in
*-dnbp*)
	# the stick the system runs from, a too-small disk is fine to list, and the target
	echo "/dev/sdb 16000000000 disk USB Stick"
	echo "/dev/sr0 1000000000 rom QEMU DVD"
	echo "/dev/nvme0n1 1000204886016 disk Samsung SSD 980 1TB"
	echo "/dev/sda 500107862016 disk WDC WD5000"
	;;
*-nlo*MOUNTPOINT*/dev/sdb*) echo /run/initramfs/live ;;
*-nlo*MOUNTPOINT*) ;;
esac
EOF
chmod +x "$work/bin/lsblk"
# test only: the package list comes at once from FAKE_FAST, a moment later from the rest, never from
# FAKE_DEAD, as an error page from FAKE_PAGE, and a month old from FAKE_OLD
cat >"$work/bin/xbps-fetch" <<'EOF'
#!/bin/sh
for dead in ${FAKE_DEAD:-}; do case $1 in *"$dead"*) exit 1 ;; esac; done
case $1 in *"${FAKE_FAST:-repo-de.voidlinux.org}"*) ;; *) sleep 0.2 ;; esac
case $1 in
*"${FAKE_PAGE:-none}"*) head -c 3000 /dev/zero >"${1##*/}" ;;
*) head -c 2200000 /dev/zero >"${1##*/}" ;;
esac
case $1 in *"${FAKE_OLD:-none}"*) touch -d '30 days ago' "${1##*/}" ;; esac
EOF
chmod +x "$work/bin/xbps-fetch"

dialog() { # output file, answers...
	out=$1
	shift
	printf '%s\n' "$@" | PATH="$work/bin:$PATH" KOMBAIN_NET="$work/net" KOMBAIN_PCI="$work/pci" KOMBAIN_CPUINFO="$work/cpuinfo" sh "$repo/setup.sh" --dry-run >"$out" 2>&1
}

# ------ a full run with every kind of wrong answer first
dialog "$work/run1" \
	9 banana 2 \
	'Bad Name' alice \
	banana 5G 9T 40G \
	9T 60G \
	'' \
	n \
	'' '' 100G \
	y \
	my-box \
	Europe/Berlin \
	7 2 \
	y \
	n
ok "the dialog finishes" $? 0
cat "$work/run1" >"$work/r"
[ "${KOMBAIN_SHOW:-0}" = 0 ] || cat "$work/r"
has() { grep -qF -- "$2" "$work/r" || {
	fail=$((fail + 1))
	echo "FAIL  $1: no [$2] in the output"
	return
}; pass=$((pass + 1)); }
hasnt() { if grep -qF -- "$2" "$work/r"; then
	fail=$((fail + 1))
	echo "FAIL  $1: [$2] in the output"
else pass=$((pass + 1)); fi; }

has "a disk in use is not offered" "1) /dev/nvme0n1"
hasnt "the stick is not offered" "/dev/sdb "
hasnt "a DVD is not offered" "/dev/sr0"
has "a wrong number is refused" "That is not on the list."
has "words as a size are refused" "Not a size."
has "too small is refused" "At least 20 GiB"
has "too big is refused" "That does not fit"
has "a bad user is refused" "Lowercase letters"
has "a wrong driver number is refused" "Numbers from 1 to 5."
has "asked again, the last answer is the default" "Size of / (the system and programs) [40 GiB]"
has "SATA names, no p" "/dev/sda1  1 GiB, /boot"
has "the sizes the user chose" "lvcreate -y -L 40960M -n root vg0"
has "the sizes the user chose" "lvcreate -y -L 61440M -n gamer vg0"
# /dev/sda is 476940 MiB. What /home/alice doesn't take stays free in the second partition.
free=$((476940 - BOOT_MIB - 2 * OVERHEAD_MIB - 40960 - 61440 - 102400))
has "the second partition's size" "size=$((40960 + 61440 + free + OVERHEAD_MIB))M"
has "the wipe" "sfdisk --wipe always --wipe-partitions always"
has "the user's home is mounted" "mount /dev/mapper/cryptdev /mnt/home/alice"
has "the user is created" "useradd -m -G wheel,audio,video alice"
has "their password" "until passwd alice; do"
has "root's password" "until passwd; do"
has "ownership" "chown -R alice:alice /home/alice"
has "fstab" "LABEL=devhome   /home/alice"
has "the boot service" "grep -qw gaming /proc/cmdline || mount /home/alice"
hasnt "no dev left in a path" "/home/dev"
hasnt "no nvme left in a command" "DISK=/dev/nvme0n1"
hasnt "no ${DISK:-DISK}p left" '${DISK}p'
has "the host" "echo my-box > /etc/hostname"
has "the zone" "/usr/share/zoneinfo/Europe/Berlin"
has "the Intel driver" "mesa-vulkan-intel"
hasnt "no AMD driver" "mesa-vulkan-radeon"
hasnt "no NVIDIA sleep setting without NVIDIA" "NVreg_DynamicPowerManagement"
has "lockdown stays on without NVIDIA" "lockdown=integrity"
has "wired network" "IF=eth9"
has "in Dev" "ln -sfn /etc/sv/dhcpcd-eth9 /etc/runit/runsvdir/default/"
has "in Gaming" "ln -sfn /etc/sv/dhcpcd-eth9 /etc/runit/runsvdir/gaming/"
hasnt "a cable keeps dhcpcd" "xbps-remove -Ry dhcpcd"
hasnt "no serial login unasked" "agetty-ttyS0"
has "the hook's partitions" 'blkid -s UUID -o value "${DISK}2"'
has "power saving" "/etc/runit/core-services/91-power-save.sh"
has "the package cache goes" "sh -c 'rm -f /var/cache/xbps/*'"
hasnt "no doas in the live system's chroot" "doas sh -c"
has "no Wi-Fi here, so no iwd" "rm -f /etc/runit/runsvdir/default/iwd"
has "no AMD here, in the CPU or the GPU" "linux-firmware-amd"
hasnt "an Intel CPU keeps its firmware" "linux-firmware-intel"
has "and gets its microcode" "xbps-install -y intel-ucode"
has "the desktop is skipped when refused" "That was a dry run"
hasnt "the desktop was refused" "install.sh --user"
ok "a dry run calls nothing that changes a disk" "$(cat "$work/called" 2>/dev/null)" ""

# ------ defaults, on NVMe, with NVIDIA found on the bus
dialog "$work/run2" 1 '' '' '' '' y '' '' '' y y
ok "defaults are accepted" $? 0
cat "$work/run2" >"$work/r"
has "NVMe names" "/dev/nvme0n1p1  1 GiB, /boot"
has "the default user" "useradd -m -G wheel,audio,video dev"
has "the default /" "lvcreate -y -L 81920M -n root vg0"
has "the NVIDIA card was found" "[3]:"
has "NVIDIA is told about lockdown" "kernel lockdown stays off"
has "the NVIDIA driver" "nvidia"
has "it may sleep when idle" "options nvidia NVreg_DynamicPowerManagement=0x02"
has "lockdown is replaced" "nvidia_drm.modeset=1"
has "NVIDIA stays out of the initramfs" 'omit_drivers+=" nouveau nova_core nova_drm nvidia '
has "the desktop" "./install.sh --user dev"
has "fdash" "chsh -s /usr/local/bin/fdash dev"
hasnt "the NVIDIA card keeps its firmware" "linux-firmware-nvidia"
has "NVMe partitions in commands" 'cryptsetup luksFormat --batch-mode --verify-passphrase --type luks2 "${DISK}p2"'
ok "again nothing was called" "$(cat "$work/called" 2>/dev/null)" ""

has "the mirrors are timed" "Timing the mirrors"
has "the fastest is taken" "Packages from https://repo-de.voidlinux.org."
has "into step 3" "REPO=https://repo-de.voidlinux.org/current"
has "kept for updates" "/mnt/etc/xbps.d/00-repository-main.conf"
has "nonfree too" "/mnt/etc/xbps.d/10-repository-nonfree.conf"

# ------ another mirror
printf '%s\n' 1 '' '' '' '' y '' '' '' y y | PATH="$work/bin:$PATH" KOMBAIN_NET="$work/net" KOMBAIN_PCI="$work/pci" KOMBAIN_CPUINFO="$work/cpuinfo" \
	sh "$repo/setup.sh" --dry-run --mirror https://mirror.yandex.ru/mirrors/voidlinux/ >"$work/run7" 2>&1
ok "the dialog with a mirror finishes" $? 0
cat "$work/run7" >"$work/r"
has "step 3 takes it" "REPO=https://mirror.yandex.ru/mirrors/voidlinux/current"
hasnt "and nothing else" "repo-de.voidlinux.org"
has "and keeps it for updates" "/mnt/etc/xbps.d/00-repository-main.conf"
sh "$repo/setup.sh" --dry-run --mirror 'https://a.org/x;reboot' </dev/null >"$work/run8" 2>&1
yes_ "a mirror a shell would read is refused" [ $? -ne 0 ]
grep -q "takes an https address" "$work/run8"
ok "with an example" $? 0
sh "$repo/setup.sh" --dry-run --mirror </dev/null >"$work/run8" 2>&1
yes_ "--mirror without an address is refused" [ $? -ne 0 ]

# ------ the fastest, not the first
export FAKE_FAST=repo-fi.voidlinux.org
dialog "$work/run9" 1 '' '' '' '' y '' '' '' y y
ok "the dialog finishes" $? 0
cat "$work/run9" >"$work/r"
has "the fastest tier 1 mirror" "REPO=https://repo-fi.voidlinux.org/current"

# ------ an error page or a mirror that stopped syncing is passed over
export FAKE_PAGE=repo-fi.voidlinux.org FAKE_OLD=repo-de.voidlinux.org
dialog "$work/run9" 1 '' '' '' '' y '' '' '' y y
cat "$work/run9" >"$work/r"
hasnt "not an error page" "REPO=https://repo-fi.voidlinux.org/current"
hasnt "not an old list" "REPO=https://repo-de.voidlinux.org/current"
has "but another tier 1 mirror" "REPO=https://"
unset FAKE_PAGE FAKE_OLD

# ------ no tier 1 mirror answers: the others are timed
export FAKE_DEAD="voidlinux.org summithq.com" FAKE_FAST=mirror.yandex.ru
dialog "$work/run9" 1 '' '' '' '' y '' '' '' y y
ok "the dialog with tier 1 down finishes" $? 0
cat "$work/run9" >"$work/r"
has "it says so" "None of Void's tier 1 mirrors answered"
has "and takes the fastest of the rest" "REPO=https://mirror.yandex.ru/mirrors/voidlinux/current"

# ------ none answers: it stops before any question
export FAKE_DEAD=https
dialog "$work/run9" 1 '' '' '' '' y '' '' '' y y
yes_ "no mirror stops it" [ $? -ne 0 ]
cat "$work/run9" >"$work/r"
has "and says what to do" "no mirror sent the package list in time"
hasnt "before the disk is asked" "Install on disk number"

# ------ a mirror given is not timed
sh "$repo/setup.sh" --dry-run --mirror https://mirror.yandex.ru/mirrors/voidlinux </dev/null >"$work/run9" 2>&1
cat "$work/run9" >"$work/r"
hasnt "a given mirror is not timed" "Timing the mirrors"
unset FAKE_DEAD FAKE_FAST

# ------ no cable: dhcpcd goes, as the guide's step 6 says
dialog "$work/run6" 1 '' '' '' '' y '' '' '' n y
ok "the dialog without a cable finishes" $? 0
cat "$work/run6" >"$work/r"
has "it says so" "Without a cable dhcpcd is removed"
has "updates leave dhcpcd out" "ignorepkg=dhcpcd"
has "and it is removed" "xbps-remove -Ry dhcpcd"
hasnt "no dhcpcd service" "/etc/sv/dhcpcd-"
ok "and nothing was called" "$(cat "$work/called" 2>/dev/null)" ""

# ------ running out of answers ends it, instead of asking forever
dialog "$work/run3" 1
yes_ "out of answers it stops" [ $? -ne 0 ]
grep -q "no more input" "$work/run3"
ok "and says so" $? 0

# ------ a disk too small is refused before any question about it
cat >"$work/bin/lsblk" <<EOF
#!/bin/sh
case "\$*" in
*-dnbp*) echo "/dev/sda 16000000000 disk Tiny" ;;
esac
EOF
dialog "$work/run4" ''
yes_ "too small a disk stops it" [ $? -ne 0 ]
grep -q "too small" "$work/run4"
ok "and says so" $? 0

# ------ a guide that changed stops it before anything could be touched
sed 's/lvcreate -L 80G/lvcreate --size 80G/' "$repo/docs/void-install-guide.md" >"$work/guide-changed.md"
mkdir -p "$work/repo/docs"
cp "$repo/setup.sh" "$work/repo/setup.sh"
cp "$work/guide-changed.md" "$work/repo/docs/void-install-guide.md"
cat >"$work/bin/lsblk" <<EOF
#!/bin/sh
case "\$*" in
*-dnbp*) echo "/dev/sda 500107862016 disk WDC" ;;
esac
EOF
printf '%s\n' '' '' '' '' '' y '' '' '' y y | PATH="$work/bin:$PATH" KOMBAIN_NET="$work/net" KOMBAIN_PCI="$work/pci" sh "$work/repo/setup.sh" --dry-run >"$work/run5" 2>&1
yes_ "a changed guide stops it" [ $? -ne 0 ]
grep -q "the guide no longer has" "$work/run5"
ok "and says what changed" $? 0

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
