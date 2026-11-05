#!/bin/sh
# Sends real traffic through the firewall between two network namespaces.
# Run as root on Void Linux, where it only touches the namespaces it creates and
# /etc/nftables.conf, so use a throwaway container:
#
#   docker run --rm --init --memory=1500m --memory-swap=1500m --pids-limit=400 --cpus=2 \
#     --cap-add NET_ADMIN --cap-add SYS_ADMIN --security-opt apparmor=unconfined \
#     -v "$PWD":/w:ro -w /w ghcr.io/void-linux/void-glibc-full:latest \
#     sh -c 'xbps-install -Syu xbps; xbps-install -Sy nftables iproute2 iputils runit-void python3; tests/firewall.sh'
set -u

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
probe="python3 -I $repo/tests/firewall_probe.py"
fw="ip netns exec fw"
peer="ip netns exec peer"
failed=0
passed=0

check() {
	if [ "$3" = "$2" ]; then
		passed=$((passed + 1))
		printf 'ok    %-46s %s\n' "$1" "$3"
	else
		failed=$((failed + 1))
		printf 'FAIL  %-46s wanted %s, got %s\n' "$1" "$2" "$3"
	fi
}

ping_from() {
	ip netns exec "$1" ping -c1 -W1 "$2" >/dev/null 2>&1 && echo OPEN || echo dropped
}

clear_rules() {
	$fw nft flush ruleset
}

# Runs the core service the way /etc/runit/1 does: sourced, with its helpers loaded.
boot_service() {
	$fw sh -c '. /etc/runit/functions; . "$1"' sh "$repo/config/firewall.sh" 2>&1
}

ip netns add fw
ip netns add peer
ip link add fw0 type veth peer name peer0
ip link set fw0 netns fw
ip link set peer0 netns peer
$fw ip addr add 10.99.0.1/24 dev fw0
$fw ip addr add fd99::1/64 dev fw0 nodad
$fw ip link set fw0 up
$fw ip link set lo up
$peer ip addr add 10.99.0.2/24 dev peer0
$peer ip addr add fd99::2/64 dev peer0 nodad
$peer ip link set peer0 up
$peer ip link set lo up
sleep 3	# link-local addresses leave duplicate detection

# Left running they would hold stdout open, and `tests/firewall.sh | grep` would never end.
listeners=
listen() {
	"$@" >/dev/null 2>&1 &
	listeners="$listeners $!"
}
trap 'kill $listeners 2>/dev/null' EXIT

# what a game or a dev server would listen on behind the firewall, and the outside world
listen $fw $probe serve-tcp 0.0.0.0 8000
listen $fw $probe serve-tcp :: 8000
listen $fw $probe serve-udp 0.0.0.0 27036
listen $fw $probe serve-udp 0.0.0.0 68
listen $peer $probe serve-tcp 0.0.0.0 443
listen $peer $probe serve-tcp :: 443
listen $peer $probe serve-udp 0.0.0.0 53
sleep 1

inbound_closed() {
	check "$1: TCP in, IPv4" dropped "$($peer $probe tcp 10.99.0.1 8000)"
	check "$1: TCP in, IPv6" dropped "$($peer $probe tcp fd99::1 8000)"
	check "$1: UDP in" dropped "$($peer $probe udp 10.99.0.1 27036)"
	check "$1: closed port stays silent" dropped "$($peer $probe tcp 10.99.0.1 9)"
	check "$1: ping in, IPv4" dropped "$(ping_from peer 10.99.0.1)"
	check "$1: ping in, IPv6" dropped "$(ping_from peer fd99::1)"
	check "$1: fake DHCP from a wrong port" dropped "$($peer $probe udp 10.99.0.1 68 12345)"
}

# Empty neighbor caches, so IPv6 has to pass neighbor discovery through the rules.
flush_neighbors() {
	$fw ip -6 neigh flush all 2>/dev/null
	$peer ip -6 neigh flush all 2>/dev/null
	$fw ip -4 neigh flush all 2>/dev/null
	$peer ip -4 neigh flush all 2>/dev/null
}

still_usable() {
	flush_neighbors
	check "$1: DHCP reply" OPEN "$($peer $probe udp 10.99.0.1 68 67)"
	check "$1: loopback" OPEN "$($fw $probe tcp 127.0.0.1 8000)"
	check "$1: TCP out, IPv4" OPEN "$($fw $probe tcp 10.99.0.2 443)"
	check "$1: TCP out, IPv6" OPEN "$($fw $probe tcp fd99::2 443)"
	check "$1: UDP out and its reply" OPEN "$($fw $probe udp 10.99.0.2 53)"
	check "$1: ping out" OPEN "$(ping_from fw 10.99.0.2)"
}

# Without this control the rest would pass on a broken test bed too.
echo "--- no firewall, the test bed must reach everything"
clear_rules
check "control: TCP in, IPv4" OPEN "$($peer $probe tcp 10.99.0.1 8000)"
check "control: TCP in, IPv6" OPEN "$($peer $probe tcp fd99::1 8000)"
check "control: UDP in" OPEN "$($peer $probe udp 10.99.0.1 27036)"
check "control: closed port answers" refused "$($peer $probe tcp 10.99.0.1 9)"
check "control: ping in, IPv4" OPEN "$(ping_from peer 10.99.0.1)"
check "control: fake DHCP" OPEN "$($peer $probe udp 10.99.0.1 68 12345)"

echo "--- shipped rules through the boot service"
cp "$repo/config/nftables.conf" /etc/nftables.conf
out=$(boot_service)
case $out in
	*WARNING*|*ERROR*) check "good config: no warning" none "$out" ;;
	*) check "good config: no warning" none none ;;
esac
inbound_closed "rules"
still_usable "rules"

echo "--- router advertisements reach the kernel through the rules"
check "no IPv6 default route yet" 0 "$($fw ip -6 route show default | wc -l)"
$peer $probe router-advert peer0
sleep 1
check "router advert accepted" 1 "$($fw ip -6 route show default | wc -l)"
check "that route is the link-local router" yes "$($fw ip -6 route show default | grep -q 'via fe80::' && echo yes || echo no)"
$fw ip -6 route del default 2>/dev/null

echo "--- the same without the ICMPv6 line: the rule is what lets them through"
clear_rules
grep -v 'icmpv6 type' "$repo/config/nftables.conf" | $fw nft -f -
flush_neighbors
$peer $probe router-advert peer0
sleep 1
check "without the rule: router advert blocked" 0 "$($fw ip -6 route show default | wc -l)"
check "without the rule: IPv6 out breaks" dropped "$($fw $probe tcp fd99::2 443 | sed 's/^error.*/dropped/')"
check "without the rule: IPv4 out still works" OPEN "$($fw $probe tcp 10.99.0.2 443)"

echo "--- rules of other programs survive loading the firewall"
clear_rules
$fw nft add table inet other
$fw nft add chain inet other keep
cp "$repo/config/nftables.conf" /etc/nftables.conf
boot_service >/dev/null
boot_service >/dev/null
check "another program's table is still there" 1 "$($fw nft list tables | grep -c 'inet other')"
check "loading twice leaves one table of ours" 1 "$($fw nft list tables | grep -c 'inet kombain')"

echo "--- typo in /etc/nftables.conf"
clear_rules
printf 'table inet filter {\n  chain input { type filter hook input priority 0; polcy drop; }\n}\n' >/etc/nftables.conf
out=$(boot_service)
case $out in
	*"using the built-in rules"*) check "typo: warns at boot" yes yes ;;
	*) check "typo: warns at boot" yes "$out" ;;
esac
inbound_closed "typo"
still_usable "typo"

echo "--- /etc/nftables.conf missing"
clear_rules
mv /etc/nftables.conf /etc/nftables.conf.moved
out=$(boot_service)
case $out in
	*"using the built-in rules"*) check "missing: warns at boot" yes yes ;;
	*) check "missing: warns at boot" yes "$out" ;;
esac
inbound_closed "missing"
still_usable "missing"
mv /etc/nftables.conf.moved /etc/nftables.conf

echo "--- nft itself unavailable: nothing can protect, but it must say so"
clear_rules
out=$($fw sh -c 'PATH=/nonexistent; . /etc/runit/functions; . "$1"' sh "$repo/config/firewall.sh" 2>&1)
case $out in
	*"NO FIREWALL"*) check "no nft: loud error" yes yes ;;
	*) check "no nft: loud error" yes "$out" ;;
esac

echo "--- the guide carries the same files"
guide_block() {
	awk -v start="cat > $1 <<'EOF'" '$0 == start { on = 1; next } on && $0 == "EOF" { exit } on' "$repo/docs/void-install-guide.md"
}
check "guide: nftables.conf matches" same "$(guide_block /etc/nftables.conf | cmp -s - "$repo/config/nftables.conf" && echo same || echo different)"
check "guide: sysctl settings match" same "$(guide_block /etc/sysctl.d/90-local.conf | cmp -s - "$repo/config/sysctl.conf" && echo same || echo different)"
check "guide: boot service matches" same "$(guide_block /etc/runit/core-services/85-firewall.sh | cmp -s - "$repo/config/firewall.sh" && echo same || echo different)"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
