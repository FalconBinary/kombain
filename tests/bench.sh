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
check "boot: stage 2 until the login" "0.90 s" "$(printf '%s\n' "$out" | sed -n 's/.*until the login on tty1 *\([0-9.]* s\).*/\1/p')"
check "boot: login until the session" "1.80 s" "$(printf '%s\n' "$out" | sed -n 's/.*until the session started *\([0-9.]* s\).*/\1/p')"
check "boot: the session until the panel" "1.50 s" "$(printf '%s\n' "$out" | sed -n 's/.*until the panel was up *\([0-9.]* s\).*/\1/p')"
check "boot: the CSV row carries the label and the kernel" "test,yes" "$(tail -1 "$work/results/boot.csv" | awk -F, '{ print $1 "," ($3 != "" ? "yes" : "no") }')"
check "boot: the CSV values" "8.50,2.345678,11.85,0.90,0.90,1.80,1.50,19.30" "$(tail -1 "$work/results/boot.csv" | cut -d, -f7-)"
# an older file with other columns is moved aside, not mixed
printf 'label,utc,kernel,init,mode,source,old_column\nx,t,k,i,dev,mains,1\n' > "$work/results/boot.csv"
mkdir -p "$work/nolog2/markers"
"$bench" boot --from "$work/nolog2" --label test >/dev/null 2>&1
check "row: a file with other columns is moved aside" "1" "$(ls "$work/results"/boot.csv.old-* 2>/dev/null | wc -l | tr -d ' ')"
check "row: and the new file starts with the new header" "label,utc,kernel,init,mode,source,firmware_s" "$(head -1 "$work/results/boot.csv" | cut -d, -f1-7)"
check "boot: the header once" "1" "$(grep -c '^label,' "$work/results/boot.csv")"

mkdir -p "$work/initrd/markers" && printf '[    0.000000] Linux version 6.18.62_1\n[    1.500000] Run /init as init process\n' > "$work/initrd/dmesg.txt"
out=$("$bench" boot --from "$work/initrd" --label test 2>&1)
check "boot: the kernel's time with an initramfs (Run /init)" "1.500000 s" "$(printf '%s\n' "$out" | sed -n 's/.*ran the initramfs *\([0-9.]* s\).*/\1/p')"

mkdir -p "$work/nolog/markers"
out=$("$bench" boot --from "$work/nolog" --label test 2>&1); code=$?
check "boot: without a kernel log it still reports and exits 0" "0" "$code"
check "boot: says the kernel log is missing" "1" "$(printf '%s\n' "$out" | grep -c 'no kernel log')"
check "boot: and that the markers come with the next boot" "1" "$(printf '%s\n' "$out" | grep -c 'next boot')"

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

	# sched: the turns, the switching and the stop, against a fake scheduler and a fake /sys/kernel/sched_ext
	mkdir -p "$work/scx/root" "$work/tree"
	echo disabled > "$work/scx/state"
	cat > "$work/fake-sched" <<-'EOF'
	#!/bin/sh
	# a sched_ext scheduler in a few lines: tells the kernel's files it runs, leaves on SIGTERM;
	# with a second argument it dies after that many seconds, as a scheduler the kernel threw out
	d=$1
	trap 'echo disabled > "$d/state"; rm -f "$d/root/ops"; exit 0' TERM INT
	echo fake > "$d/root/ops"; echo enabled > "$d/state"
	if [ -n "${2:-}" ]; then sleep "$2"; echo disabled > "$d/state"; rm -f "$d/root/ops"; exit 1; fi
	while :; do sleep 1; done
	EOF
	printf 'all:\n\t@sleep 1\nclean:\n\t@true\n' > "$work/tree/Makefile"
	out=$(KOMBAIN_SCHED_EXT=$work/scx "$bench" sched --with "stock,fake=sh $work/fake-sched $work/scx" --rounds 2 --seconds 1 --cool off --tree "$work/tree" --jobs 2 2>&1); code=$?
	check "sched: two rounds under stock and a fake scheduler, exit 0" "0" "$code"
	check "sched: the kernel ran the fake one in each round" "2" "$(printf '%s\n' "$out" | grep -c 'the kernel runs fake')"
	check "sched: the turns rotate: stock, fake, then fake, stock" "stock fake fake stock" "$(printf '%s\n' "$out" | sed -n 's/^round [0-9]*, \(.*\):$/\1/p' | paste -sd' ' -)"
	check "sched: a jitter row per variant and round" "2 2" "$(awk -F, -v k="$(uname -r)" 'NR > 1 { n[$1]++ } END { printf "%d %d", n[k "/fake"], n[k "/stock"] }' "$work/results/jitter.csv")"
	check "sched: a build row per variant and round" "2 2" "$(awk -F, -v k="$(uname -r)" 'NR > 1 { n[$1]++ } END { printf "%d %d", n[k "/fake"], n[k "/stock"] }' "$work/results/build.csv")"
	check "sched: the scheduler is off at the end" "disabled" "$(cat "$work/scx/state")"
	check "sched: its log is kept with the results" "yes" "$([ -e "$work/results/sched-fake.log" ] && echo yes || echo no)"
	check "sched: the summary closes it" "1" "$(printf '%s\n' "$out" | grep -c '^build:')"
	out=$(KOMBAIN_SCHED_EXT=$work/scx "$bench" sched --with "dies=sh $work/fake-sched $work/scx 2" --rounds 1 --seconds 1 --cool off --tree "$work/tree" 2>&1); code=$?
	check "sched: a scheduler the kernel threw out ends the run" "1" "$code"
	check "sched: and says the rows under it are not its" "1" "$(printf '%s\n' "$out" | grep -c 'dies stopped during the run')"
	echo enabled > "$work/scx/state"; echo other > "$work/scx/root/ops"
	out=$(KOMBAIN_SCHED_EXT=$work/scx "$bench" sched --with stock --rounds 1 --seconds 1 --cool off --tree "$work/tree" 2>&1); code=$?
	check "sched: refuses while a scheduler already runs" "1" "$code"
	check "sched: and names it" "1" "$(printf '%s\n' "$out" | grep -c 'already running (other)')"
	echo disabled > "$work/scx/state"; rm -f "$work/scx/root/ops"
	out=$(KOMBAIN_SCHED_EXT=$work/scx "$bench" sched --with stock,scx_nowhere --tree "$work/tree" 2>&1); code=$?
	check "sched: refuses a scheduler that is not installed, before anything runs" "1" "$code"
	check "sched: and says which" "1" "$(printf '%s\n' "$out" | grep -c 'scx_nowhere is not installed')"
else
	echo "skip  zjitter: $zjitter is not built (zig build in bench/)"
fi

rm -rf "${work:?}"
echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
