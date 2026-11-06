#!/bin/sh
# Installs the kombain stack on Void Linux (glibc). Run as root from the repository:
#
#   ./install.sh --user NAME [--no-gui] [--no-netline] [--no-zcool] [--extras]
#
# Safe to run again. /bin/sh stays plain dash, existing dotfiles are never overwritten.
set -eu

ZIG_VERSION=0.17.1
ZIG_SHA256_X86_64=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a
ZIG_SHA256_AARCH64=a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795
NETLINE_REPO=https://github.com/FalconBinary/netline.git
# Pinned: a build runs code from what it builds. Move this forward on purpose.
NETLINE_COMMIT=f5953b4ac194a1732c5f9350a81138d02356e8a8

user=
gui=1
netline=1
zcool=1
extras=0

usage() {
	sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
	exit "$1"
}

while [ $# -gt 0 ]; do
	case $1 in
	--user) [ $# -ge 2 ] || usage 2; user=$2; shift ;;
	--no-gui) gui=0 ;;
	--no-netline) netline=0 ;;
	--no-zcool) zcool=0 ;;
	--extras) extras=1 ;;
	-h|--help) usage 0 ;;
	*) echo "unknown option: $1" >&2; usage 2 ;;
	esac
	shift
done

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -x /usr/bin/xbps-install ] || { echo "this script is for Void Linux" >&2; exit 1; }
if [ -n "$user" ]; then
	id "$user" >/dev/null 2>&1 || { echo "no such user: $user" >&2; exit 1; }
fi

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

packages() {
	grep -v '^#' "$here/packages/$1.txt" | grep -v '^$'
}

echo "==> packages"
xbps-install -Syu xbps
list=$(packages base)
[ "$gui" -eq 0 ] || list="$list
$(packages gui)"
[ "$extras" -eq 0 ] || list="$list
$(packages extras)"
# shellcheck disable=SC2086
xbps-install -Sy $list

# Everything is built as nobody in a temporary directory: build systems execute code
# from what they build, and this leaves no root-owned files in the repository.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chown nobody:"$(id -g nobody)" "$work"

unprivileged() {
	setpriv --reuid="$(id -u nobody)" --regid="$(id -g nobody)" --clear-groups --no-new-privs \
		env -i HOME="$work" TMPDIR="$work" PATH=/usr/bin:/bin "$@"
}

echo "==> fdash"
tar -C "$here" --exclude='fdash/build*' --exclude='fdash/fdash' --exclude='fdash/fdash-*' -cf - fdash | tar -C "$work" -xf -
chown -R nobody:"$(id -g nobody)" "$work/fdash"
unprivileged make -C "$work/fdash"
make -C "$work/fdash" install
grep -qx /usr/local/bin/fdash /etc/shells 2>/dev/null || echo /usr/local/bin/fdash >>/etc/shells

echo "==> firewall"
if [ -e /etc/nftables.conf ]; then
	echo "kept /etc/nftables.conf"
else
	install -m 644 "$here/config/nftables.conf" /etc/nftables.conf
	echo "created /etc/nftables.conf"
fi
install -m 644 "$here/config/firewall.sh" /etc/runit/core-services/85-firewall.sh
# connections already open keep working, so this is safe over ssh
if nft -f /etc/nftables.conf; then
	echo "rules loaded"
else
	echo "could not load /etc/nftables.conf now; the next boot tries again and falls back to built-in rules" >&2
fi
if [ -e /etc/runit/runsvdir/default/sshd ] && ! grep -v '^[[:space:]]*#' /etc/nftables.conf | grep -q 'dport 22'; then
	echo "WARNING: sshd is enabled, but new ssh connections are now dropped." >&2
	echo "         To allow them, add 'tcp dport 22 accept' to the input chain of /etc/nftables.conf" >&2
fi

echo "==> kernel hardening"
install -d /etc/sysctl.d /etc/modules-load.d
if [ -e /etc/sysctl.d/90-local.conf ]; then
	echo "kept /etc/sysctl.d/90-local.conf"
else
	install -m 644 "$here/config/sysctl.conf" /etc/sysctl.d/90-local.conf
	echo "created /etc/sysctl.d/90-local.conf"
fi
[ -e /etc/modules-load.d/bbr.conf ] || install -m 644 "$here/config/modules-load.conf" /etc/modules-load.d/bbr.conf
sysctl -q -p /etc/sysctl.d/90-local.conf || echo "some settings could not be applied now, the next boot applies them" >&2

echo "==> gconv cache"
install -m 644 "$here/config/gconv-cache.sh" /etc/runit/core-services/86-gconv-cache.sh
iconvconfig || echo "could not build the gconv cache now, the next boot tries again" >&2

if [ "$gui" -eq 1 ]; then
	echo "==> services"
	if [ -d /etc/runit/runsvdir/default ]; then
		for s in dbus elogind; do
			ln -sfn "/etc/sv/$s" "/etc/runit/runsvdir/default/$s"
			echo "enabled $s"
		done
	else
		echo "no default runlevel here, enable dbus and elogind yourself" >&2
	fi

	# PipeWire starts WirePlumber and the PulseAudio socket through these
	mkdir -p /etc/pipewire/pipewire.conf.d
	ln -sfn /usr/share/examples/wireplumber/10-wireplumber.conf /etc/pipewire/pipewire.conf.d/
	ln -sfn /usr/share/examples/pipewire/20-pipewire-pulse.conf /etc/pipewire/pipewire.conf.d/
	mkdir -p /etc/wireplumber/wireplumber.conf.d /etc/security/limits.d
	[ -e /etc/pipewire/pipewire.conf.d/10-kombain.conf ] || install -m 644 "$here/config/pipewire.conf" /etc/pipewire/pipewire.conf.d/10-kombain.conf
	[ -e /etc/wireplumber/wireplumber.conf.d/10-kombain.conf ] || install -m 644 "$here/config/wireplumber.conf" /etc/wireplumber/wireplumber.conf.d/10-kombain.conf
	[ -e /etc/security/limits.d/90-audio.conf ] || install -m 644 "$here/config/audio-limits.conf" /etc/security/limits.d/90-audio.conf
fi

if [ "$zcool" -eq 1 ] || { [ "$gui" -eq 1 ] && [ "$netline" -eq 1 ]; }; then
	echo "==> zig"
	# Void's zig is too old for these, so a checksummed release is used for the build only
	case $(uname -m) in
	x86_64) zig_arch=x86_64; zig_sha=$ZIG_SHA256_X86_64 ;;
	aarch64) zig_arch=aarch64; zig_sha=$ZIG_SHA256_AARCH64 ;;
	*) echo "no zig release known for $(uname -m)" >&2; exit 1 ;;
	esac
	tarball=zig-$zig_arch-linux-$ZIG_VERSION.tar.xz
	unprivileged curl -fsSL "https://ziglang.org/download/$ZIG_VERSION/$tarball" -o "$work/$tarball"
	echo "$zig_sha  $work/$tarball" | sha256sum -c -
	unprivileged tar -xf "$work/$tarball" -C "$work"
	zig="$work/zig-$zig_arch-linux-$ZIG_VERSION/zig"
fi

if [ "$gui" -eq 1 ] && [ "$netline" -eq 1 ]; then
	echo "==> netline"
	unprivileged git init -q "$work/netline"
	unprivileged git -C "$work/netline" fetch -q --depth 1 "$NETLINE_REPO" "$NETLINE_COMMIT"
	unprivileged git -C "$work/netline" checkout -q FETCH_HEAD
	[ "$(unprivileged git -C "$work/netline" rev-parse HEAD)" = "$NETLINE_COMMIT" ] || { echo "netline commit mismatch" >&2; exit 1; }
	echo "netline $NETLINE_COMMIT"
	(
		cd "$work/netline"
		unprivileged env ZIG_LOCAL_CACHE_DIR="$work/cache" ZIG_GLOBAL_CACHE_DIR="$work/global-cache" \
			"$zig" build -Doptimize=ReleaseSafe --prefix "$work/out"
	)
	install -m 755 "$work"/out/bin/* /usr/local/bin/
fi

if [ "$zcool" -eq 1 ]; then
	echo "==> zcool"
	tar -C "$here" --exclude='zcool/.zig-cache' --exclude='zcool/zig-out' -cf - zcool | tar -C "$work" -xf -
	chown -R nobody:"$(id -g nobody)" "$work/zcool"
	(
		cd "$work/zcool"
		unprivileged env ZIG_LOCAL_CACHE_DIR="$work/cache" ZIG_GLOBAL_CACHE_DIR="$work/global-cache" \
			"$zig" build -Doptimize=ReleaseSafe --prefix "$work/out-zcool"
	)
	install -m 755 "$work/out-zcool/bin/zcool" /usr/local/bin/zcool
	# zcool starts it only when NVIDIA's own driver is loaded
	install -m 755 "$work/out-zcool/bin/zcool-nvidia" /usr/local/bin/zcool-nvidia
	install -d /etc/sv/zcool/log
	install -m 755 "$here/zcool/service/run" "$here/zcool/service/finish" /etc/sv/zcool/
	install -m 755 "$here/zcool/service/log/run" /etc/sv/zcool/log/
	if [ -e /etc/zcool.conf ]; then
		echo "kept /etc/zcool.conf"
	else
		install -m 644 "$here/zcool/zcool.conf.example" /etc/zcool.conf
		echo "created /etc/zcool.conf"
	fi
	echo "zcool is installed but not running. Start with: zcool list, then zcool run --dry-run (see zcool/README.md)"
fi

# what a real machine says about itself: the guide's step 14
install -m 755 "$here/report.sh" /usr/local/bin/kombain-report

if [ -n "$user" ]; then
	echo "==> configuration for $user"
	home=$(getent passwd "$user" | cut -d: -f6)
	group=$(id -gn "$user")

	# install SRC DEST: copies only what is not there yet
	install_file() {
		if [ -e "$2" ]; then
			echo "kept $2"
			return
		fi
		install -d -o "$user" -g "$group" "$home/.config" "$(dirname -- "$2")"
		install -o "$user" -g "$group" -m "${3:-644}" "$1" "$2"
		echo "created $2"
	}

	install_file "$here/fdash/config.sh.example" "$home/.config/fdash/config.sh"
	if [ "$gui" -eq 1 ]; then
		install_file "$here/config/mango/config.conf" "$home/.config/mango/config.conf"
		install_file "$here/config/foot/foot.ini" "$home/.config/foot/foot.ini"
		install_file "$here/config/profile" "$home/.profile"
	fi

	if [ "$(getent passwd "$user" | cut -d: -f7)" != /usr/local/bin/fdash ]; then
		echo "login shell left as is; to switch: chsh -s /usr/local/bin/fdash $user"
	fi
fi

if ! grep -q 'lockdown=' /proc/cmdline 2>/dev/null; then
	echo "NOTE: kernel lockdown is off. To turn it on, add lockdown=integrity to the kernel" >&2
	echo "      command line in your bootloader. Leave it off with unsigned DKMS modules, such as NVIDIA's." >&2
fi

echo "==> done"
