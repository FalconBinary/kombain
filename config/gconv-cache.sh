# /etc/runit/core-services/86-gconv-cache.sh
# Void's glibc ships no gconv cache, so every program under a UTF-8 locale would
# parse the gconv text files when it starts. Building the cache takes about 2 ms.
# It runs at every boot because a glibc update leaves the old cache in place, and
# package timestamps are build dates, so they cannot tell that it went stale.
iconvconfig || msg_warn "could not build the gconv cache, programs will start slower"
