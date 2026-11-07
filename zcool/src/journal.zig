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

/// Remembers a value already read, so the journal holds exactly what the caller saw.
pub fn rememberInt(path: [:0]const u8, value: i64) bool {
    var value_buf: [24]u8 = undefined;
    return rememberValue(path, std.fmt.bufPrint(&value_buf, "{d}", .{value}) catch return false);
}

pub fn rememberValue(path: [:0]const u8, value: []const u8) bool {
    var line_buf: [400]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{s}\t{s}\n", .{ path, value }) catch return false;
    return sys.appendFile(journalPath(), line);
}

/// Remembers one byte of a binary file such as the EC's, or with `bit` one bit of it: the
/// rest of that byte belongs to the firmware and is not put back.
pub fn rememberByte(path: [:0]const u8, offset: u8, bit: ?u3, value: u8) bool {
    var line_buf: [400]u8 = undefined;
    const line = (if (bit) |b|
        std.fmt.bufPrint(&line_buf, "{s}@{d}:{d}\t{d}\n", .{ path, offset, b, value })
    else
        std.fmt.bufPrint(&line_buf, "{s}@{d}\t{d}\n", .{ path, offset, value })) catch return false;
    return sys.appendFile(journalPath(), line);
}

const ByteTarget = struct { path: []const u8, offset: u8, bit: ?u3 };

/// `path@offset` or `path@offset:bit`, as rememberByte writes it.
fn byteTarget(key: []const u8) ?ByteTarget {
    const at = std.mem.lastIndexOfScalar(u8, key, '@') orelse return null;
    const spec = key[at + 1 ..];
    const colon = std.mem.indexOfScalar(u8, spec, ':');
    const offset = std.fmt.parseInt(u8, spec[0 .. colon orelse spec.len], 10) catch return null;
    const bit: ?u3 = if (colon) |c| (std.fmt.parseInt(u3, spec[c + 1 ..], 10) catch return null) else null;
    return .{ .path = key[0..at], .offset = offset, .bit = bit };
}

fn restoreByte(t: ByteTarget, text: []const u8) bool {
    const value = std.fmt.parseInt(u8, text, 10) catch return false;
    var target_buf: [300]u8 = undefined;
    const fd = sys.openReadWrite(sys.join(&target_buf, &.{t.path})) orelse return false;
    defer sys.close(fd);
    var byte: [1]u8 = .{value};
    if (t.bit) |bit| {
        if ((sys.pread(fd, &byte, t.offset) orelse 0) != 1) return false;
        const mask = @as(u8, 1) << bit;
        byte[0] = if (value != 0) byte[0] | mask else byte[0] & ~mask;
    }
    return (sys.pwrite(fd, &byte, t.offset) orelse 0) == 1;
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
        if (byteTarget(line[0..tab])) |t| {
            if (restoreByte(t, line[tab + 1 ..])) restored += 1;
            continue;
        }
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

test "a byte or a bit of a binary file is named in the journal" {
    const byte = byteTarget("/sys/kernel/debug/ec/ec0/io@242").?;
    try std.testing.expectEqualStrings("/sys/kernel/debug/ec/ec0/io", byte.path);
    try std.testing.expectEqual(@as(u8, 242), byte.offset);
    try std.testing.expect(byte.bit == null);
    const bit = byteTarget("/sys/kernel/debug/ec/ec0/io@152:7").?;
    try std.testing.expectEqual(@as(u8, 152), bit.offset);
    try std.testing.expectEqual(@as(u3, 7), bit.bit.?);
    try std.testing.expect(byteTarget("/sys/class/hwmon/hwmon1/pwm1") == null);
    try std.testing.expect(byteTarget("/sys/x@300") == null);
    try std.testing.expect(byteTarget("/sys/x@1:9") == null);
}
