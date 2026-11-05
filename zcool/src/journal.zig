// SPDX-License-Identifier: GPL-3.0-or-later

//! Every value zcool is about to change is written here first, on tmpfs, so that
//! whatever kills the daemon, `zcool restore` can put the hardware back.

const std = @import("std");
const sys = @import("sys.zig");

var path_buf: [256]u8 = undefined;
var log_buf: [64]u8 = undefined;

fn journalPath() [:0]const u8 {
    return sys.join(&path_buf, &.{ sys.root, "/run/zcool/state" });
}

pub fn prepare() void {
    var dir: [256]u8 = undefined;
    var parent: [256]u8 = undefined;
    sys.mkdir(sys.join(&parent, &.{ sys.root, "/run" }));
    sys.mkdir(sys.join(&dir, &.{ sys.root, "/run/zcool" }));
}

/// Remembers the current content of a file before the first change to it.
pub fn remember(path: [:0]const u8) bool {
    var value_buf: [64]u8 = undefined;
    const value = std.mem.trim(u8, sys.readFile(path, &value_buf) orelse return false, " \t\r\n");
    return rememberValue(path, value);
}

pub fn rememberValue(path: [:0]const u8, value: []const u8) bool {
    var line_buf: [400]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{s}\t{s}\n", .{ path, value }) catch return false;
    return sys.appendFile(journalPath(), line);
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
        const target = sys.join(&target_buf, &.{line[0..tab]});
        if (sys.writeFile(target, line[tab + 1 ..])) restored += 1;
    }
    sys.unlink(path);
    return restored;
}

/// The journal is root's, but it only ever needs to reach /sys.
fn allowed(path: []const u8) bool {
    var prefix_buf: [256]u8 = undefined;
    const prefix = sys.join(&prefix_buf, &.{ sys.root, "/sys/" });
    return std.mem.startsWith(u8, path, prefix) and std.mem.indexOf(u8, path, "..") == null;
}
