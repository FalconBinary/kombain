#!/bin/sh
# Builds fdash and an unmodified dash of the same version, then runs the tests.
set -e
cd "$(dirname "$0")/.."
make >/dev/null 2>&1
mkdir -p /tmp/stock
cd /tmp/stock
"$OLDPWD/dash/configure" --without-libedit --enable-fnmatch CFLAGS='-O2 -flto -D_GNU_SOURCE' >/dev/null 2>&1
make -j4 >/dev/null 2>&1
cd "$OLDPWD"
python3 tests/run.py ./fdash /tmp/stock/src/dash "$@"
