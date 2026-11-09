# /etc/runit/core-services/99-zz-kombain-bench.sh: when stage 1 ended, for `kombain-bench boot`.
# Sourced last by /etc/runit/1; stage 2 (runsvdir and the services) begins right after.
cut -d' ' -f1 /proc/uptime > /run/kombain-bench/stage1-end
