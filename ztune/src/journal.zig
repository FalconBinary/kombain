// SPDX-License-Identifier: GPL-3.0-or-later

//! Every value ztune is about to change is written here first, on tmpfs, so that whatever
//! ends the daemon, `ztune restore` can put the system back. The same idea as zcool's.

const std = @import("std");
const sys = @import("sys.zig");

var path_buf: [256]u8 = undefined;

fn journalPath() [:0]const u8 {
    return sys.join(&path_buf, &.{ sys.root, "/run/ztune/state" });
}

pub fn prepare() void {
    var dir: [256]u8 = undefined;
    var parent: [256]u8 = undefined;
    sys.mkdir(sys.join(&parent, &.{ sys.root, "/run" }));
    sys.mkdir(sys.join(&dir, &.{ sys.root, "/run/ztune" }));
}

/// Remembers `value`, what `path` held before ztune's first change to it.
pub fn remember(path: [:0]const u8, value: []const u8) bool {
    var line_buf: [400]u8 = undefined;
    if (path.len + value.len + 2 > line_buf.len) return false;
    @memcpy(line_buf[0..path.len], path);
    line_buf[path.len] = '\t';
    @memcpy(line_buf[path.len + 1 ..][0..value.len], value);
    line_buf[path.len + 1 + value.len] = '\n';
    return sys.appendFile(journalPath(), line_buf[0 .. path.len + value.len + 2]);
}

/// Writes everything back, newest first, so a value changed twice ends at its original.
/// Safe to run at any moment and more than once.
pub fn restore() u32 {
    var buf: [32768]u8 = undefined;
    const path = journalPath();
    const fd = sys.openRead(path) orelse return 0;
    const n = sys.pread(fd, &buf, 0) orelse 0;
    sys.close(fd);
    var restored: u32 = 0;
    var end = n;
    while (end > 0) {
        var start = end - 1;
        while (start > 0 and buf[start - 1] != '\n') start -= 1;
        const line = std.mem.trimEnd(u8, buf[start..end], "\n");
        end = start;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        if (!allowed(line[0..tab])) continue;
        var target_buf: [300]u8 = undefined;
        if (sys.writeFile(sys.join(&target_buf, &.{line[0..tab]}), line[tab + 1 ..])) restored += 1;
    }
    sys.unlink(path);
    return restored;
}

/// The journal is root's, but it only ever needs to reach /sys and /proc/sys.
pub fn allowed(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, "..") != null) return false;
    for ([_][]const u8{ "/sys/", "/proc/sys/" }) |under| {
        var prefix_buf: [256]u8 = undefined;
        const prefix = sys.join(&prefix_buf, &.{ sys.root, under });
        if (std.mem.startsWith(u8, path, prefix)) return true;
    }
    return false;
}

test "only /sys and /proc/sys are ever written back" {
    try std.testing.expect(allowed("/sys/kernel/mm/transparent_hugepage/enabled"));
    try std.testing.expect(allowed("/proc/sys/vm/dirty_bytes"));
    try std.testing.expect(!allowed("/etc/shadow"));
    try std.testing.expect(!allowed("/proc/sys/../../etc/shadow"));
    try std.testing.expect(!allowed("/proc/1/mem"));
}
