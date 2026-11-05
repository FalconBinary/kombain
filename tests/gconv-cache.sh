#!/bin/sh
# Checks the gconv cache and its boot service. Run as root on Void Linux in a
# throwaway container: it replaces the system's gconv cache and adds a test alias.
#
#   docker run --rm --init --memory=1500m --memory-swap=1500m --pids-limit=400 --cpus=2 \
#     -v "$PWD":/w:ro -w /w ghcr.io/void-linux/void-glibc-full:latest \
#     sh -c 'xbps-install -Syu xbps; xbps-install -Sy runit-void; tests/gconv-cache.sh'
set -u

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cache=/usr/lib/gconv/gconv-modules.cache
alias_conf=/usr/lib/gconv/gconv-modules.d/zz-kombain-test.conf
failed=0
passed=0

check() {
	if [ "$3" = "$2" ]; then
		passed=$((passed + 1))
		printf 'ok    %-44s %s\n' "$1" "$3"
	else
		failed=$((failed + 1))
		printf 'FAIL  %-44s wanted %s, got %s\n' "$1" "$2" "$3"
	fi
}

# Runs the core service the way /etc/runit/1 does: sourced, with its helpers loaded.
boot_service() {
	sh -c '. /etc/runit/functions; . "$1"; echo service-finished' sh "$repo/config/gconv-cache.sh" 2>&1
}

roundtrip() {
	printf 'привет' | iconv -f UTF-8 -t KOI8-R | iconv -f KOI8-R -t UTF-8
}

converts_via_alias() {
	printf 'x' | iconv -f KOMBAINTEST -t UTF-8 >/dev/null 2>&1 && echo yes || echo no
}

echo "--- no cache yet"
rm -f "$cache"
check "control: no cache file" no "$([ -e "$cache" ] && echo yes || echo no)"
check "control: conversion works" привет "$(roundtrip)"

echo "--- boot service builds it"
check "service finishes" service-finished "$(boot_service)"
check "cache exists" yes "$([ -s "$cache" ] && echo yes || echo no)"
check "owned by root, world readable" "root 644" "$(stat -c '%U %a' "$cache")"
check "conversion works with the cache" привет "$(roundtrip)"
check "no temporary files left" 0 "$(find /usr/lib/gconv -maxdepth 1 -name 'gconv-modules.cache.*' | wc -l)"

echo "--- a glibc update changes the modules while the old cache stays"
echo 'alias	KOMBAINTEST//	KOI8-R//' >"$alias_conf"
check "stale cache misses the new alias" no "$(converts_via_alias)"
boot_service >/dev/null
check "next boot picks it up" yes "$(converts_via_alias)"
rm -f "$alias_conf"
boot_service >/dev/null
check "and forgets it when it goes away" no "$(converts_via_alias)"

echo "--- a damaged cache must not break programs"
good=$(stat -c %s "$cache")
head -c 100 /dev/urandom >"$cache"
check "ls still runs under UTF-8" 0 "$(LANG=C.UTF-8 ls / >/dev/null 2>&1; echo $?)"
check "next boot repairs the cache" "$good" "$(boot_service >/dev/null; stat -c %s "$cache")"
check "conversion works again" привет "$(roundtrip)"

echo "--- iconvconfig unavailable: boot goes on and says so"
out=$(PATH=/nonexistent; . /etc/runit/functions; . "$repo/config/gconv-cache.sh" 2>&1; echo service-finished)
case $out in
	*"could not build the gconv cache"*service-finished*) check "warns and continues" yes yes ;;
	*) check "warns and continues" yes "$out" ;;
esac
check "old cache stays usable" "$good" "$(stat -c %s "$cache")"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
