# /etc/runit/core-services/01-kombain-bench.sh: when stage 1 began, for `kombain-bench boot`.
# Sourced by /etc/runit/1 right after the pseudo file systems are mounted.
mkdir -p /run/kombain-bench && cut -d' ' -f1 /proc/uptime > /run/kombain-bench/stage1-start
