#!/bin/sh
# Checks kombain-bench against fixtures, and zjitter for real. Runs anywhere with sh, awk and
# sort; the measurements that read live kernel files are not run here.
#
#   sh tests/bench.sh [ZJITTER]      ZJITTER defaults to bench/zig-out/bin/zjitter
set -u

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bench=$repo/bench/kombain-bench
zjitter=${1:-$repo/bench/zig-out/bin/zjitter}
work=$(mktemp -d)
export KOMBAIN_BENCH_DIR=$work/results ZJITTER=$zjitter
failed=0
passed=0

check() {
	if [ "$3" = "$2" ]; then
		passed=$((passed + 1))
		printf 'ok    %-52s %s\n' "$1" "$3"
	else
		failed=$((failed + 1))
		printf 'FAIL  %-52s wanted %s, got %s\n' "$1" "$2" "$3"
	fi
}

out=$("$bench" boot --from "$repo/tests/bench/boot" --label test 2>&1)
check "boot: the firmware's time from the FPDT" "8.50 s" "$(printf '%s\n' "$out" | sed -n 's/.*(ACPI FPDT, reset to the loader) *\([0-9.]* s\).*/\1/p')"
check "boot: the kernel until the initramfs ran" "2.345678 s" "$(printf '%s\n' "$out" | sed -n 's/.*ran the initramfs *\([0-9.]* s\).*/\1/p')"
check "boot: initramfs and LUKS" "11.85 s" "$(printf '%s\n' "$out" | sed -n 's/.*your passphrase *\([0-9.]* s\).*/\1/p')"
check "boot: stage 1" "0.90 s" "$(printf '%s\n' "$out" | sed -n 's/.*core-services) *\([0-9.]* s\).*/\1/p')"
check "boot: services to the desktop" "4.20 s" "$(printf '%s\n' "$out" | sed -n 's/.*services to the desktop *\([0-9.]* s\).*/\1/p')"
check "boot: the CSV row carries the label and the kernel" "test,yes" "$(tail -1 "$work/results/boot.csv" | awk -F, '{ print $1 "," ($3 != "" ? "yes" : "no") }')"
check "boot: the CSV values" "8.50,2.345678,11.85,0.90,4.20,19.30" "$(tail -1 "$work/results/boot.csv" | cut -d, -f7-)"
check "boot: the header once" "1" "$(grep -c '^label,' "$work/results/boot.csv")"

out=$("$bench" game "$repo/tests/bench/mangohud.csv" --label test 2>&1)
check "game: frames, fps, 1% low, p50, p99, max" "200,96.2,20.0,10.00,10.00,50.00" "$(printf '%s\n' "$out" | sed -n 's/.*max_ms = //p')"

out=$("$bench" summary "$repo/tests/bench/summary.csv" 2>&1)
check "summary: median and p95 of A's seconds" "median 3          p95 5          n 5" "$(printf '%s\n' "$out" | awk '/seconds/ && /median/ { sub(/^ *seconds *( )*/, ""); print; exit }' | sed 's/^seconds *//')"
check "summary: B's joules is no number" "" "$(printf '%s\n' "$out" | awk '/^  B/ { b = 1; next } b && /joules/ { print; exit }')"

if [ -x "$zjitter" ]; then
	line=$("$zjitter" --hz 100 --seconds 1 --csv)
	check "zjitter: seven fields" "7" "$(echo "$line" | awk -F, '{ print NF }')"
	wakes=$(echo "$line" | cut -d, -f3)
	check "zjitter: about 100 wakes in a second at 100 Hz" "yes" "$([ "$wakes" -ge 95 ] && [ "$wakes" -le 101 ] && echo yes || echo "$wakes")"
	check "zjitter: a wake is reported in microseconds" "yes" "$([ "$(echo "$line" | cut -d, -f5)" -lt 1000000 ] && echo yes || echo no)"
	"$zjitter" --hz 100 --seconds 60 --csv > "$work/jit" &
	pid=$!
	sleep 1
	kill -TERM $pid
	wait $pid
	check "zjitter: SIGTERM ends it with its report" "100,1" "$(cut -d, -f1-2 "$work/jit" | sed 's/\.[0-9]*$//')"
	check "zjitter: refuses nonsense" "2" "$("$zjitter" --hz 0 >/dev/null 2>&1; echo $?)"
else
	echo "skip  zjitter: $zjitter is not built (zig build in bench/)"
fi

rm -rf "${work:?}"
echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
