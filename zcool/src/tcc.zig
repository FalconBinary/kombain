// SPDX-License-Identifier: GPL-3.0-or-later

//! The CPU's own thermal throttle, moved from TjMax (usually 100 C) to just above zcool's limit.
//! zcool reads the temperature a few times a second; a laptop CPU's die can climb 7 C in a
//! quarter of one. The TCC acts in microseconds, so it catches what comes too fast for any
//! program, and zcool stays in charge of everything slower. It throttles earlier and nothing
//! more: it cannot harm the chip, and it goes back when zcool stops.
//!
//! Intel only: MSR_TEMPERATURE_TARGET (0x1a2), TjMax in bits 23:16 and the offset below it in
//! bits 29:24. Firmware may ignore the offset; then it is left as it was.

const std = @import("std");
const sys = @import("sys.zig");
const journal = @import("journal.zig");

pub const msr: u32 = 0x1a2;
/// above zcool's limit, so the TCC only acts on what zcool cannot catch in time; with a hard
/// ceiling it sits at the limit itself and zcool works a degree under it
pub const above_limit: u8 = 3;

const max_cpus = 64;
var fds: [max_cpus]i32 = undefined;
var cpus: [max_cpus]u16 = undefined;
var originals: [max_cpus]u64 = undefined;
var ncpus: usize = 0;
var applied = false;

pub fn tjmax(value: u64) u8 {
    return @truncate(value >> 16);
}

pub fn offsetOf(value: u64) u8 {
    return @truncate((value >> 24) & 0x3f);
}

/// The register with the offset that puts the throttle at `point`, never below 60 C.
pub fn withPoint(value: u64, point: u8) u64 {
    const max = tjmax(value);
    const at = @max(point, 60);
    const offset: u64 = if (at >= max) 0 else @min(max - at, 63);
    return (value & ~(@as(u64, 0x3f) << 24)) | (offset << 24);
}

fn readMsr(fd: i32) ?u64 {
    var bytes: [8]u8 = undefined;
    if ((sys.pread(fd, &bytes, msr) orelse 0) != 8) return null;
    return std.mem.readInt(u64, &bytes, .little);
}

fn writeMsr(fd: i32, value: u64) bool {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    return (sys.pwrite(fd, &bytes, msr) orelse 0) == 8;
}

fn msrPath(buf: []u8, cpu: []const u8) [:0]const u8 {
    return sys.join(buf, &.{ sys.root, "/dev/cpu/", cpu, "/msr" });
}

/// Before the sandbox: every CPU's register stays open, so it can go back when zcool stops.
/// `above` is how far above the limit the throttle sits: `above_limit`, or 0 for a hard ceiling.
pub fn apply(limit: f32, dry_run: bool, above: u8) void {
    var dir_buf: [128]u8 = undefined;
    var dir = sys.Dir.open(sys.join(&dir_buf, &.{ sys.root, "/dev/cpu" })) orelse {
        sys.print("tcc: /dev/cpu/0/msr is missing, the CPU's own throttle stays at TjMax\n");
        return;
    };
    defer dir.close();
    const point: u8 = @intFromFloat(std.math.clamp(limit, 30, 120) + @as(f32, @floatFromInt(above)));
    while (dir.next()) |entry| {
        if (ncpus == max_cpus) break;
        const cpu = std.fmt.parseInt(u16, entry, 10) catch continue;
        var path_buf: [128]u8 = undefined;
        const fd = (if (dry_run) sys.openRead(msrPath(&path_buf, entry)) else sys.openReadWrite(msrPath(&path_buf, entry))) orelse continue;
        const value = readMsr(fd) orelse {
            sys.close(fd);
            continue;
        };
        fds[ncpus] = fd;
        cpus[ncpus] = cpu;
        originals[ncpus] = value;
        ncpus += 1;
    }
    if (ncpus == 0) {
        sys.print("tcc: no CPU's register can be read, the CPU's own throttle stays at TjMax\n");
        return;
    }
    const first = originals[0];
    const max = tjmax(first);
    if (max < 80 or max > 120) {
        sys.printf("tcc: TjMax reads {d}C, which makes no sense, left alone\n", .{max});
        return close();
    }
    const wanted = withPoint(first, point);
    if (offsetOf(wanted) == offsetOf(first)) return close();
    const at = max - offsetOf(wanted);
    if (dry_run) {
        sys.printf("tcc: would have the CPU throttle itself from {d}C, {s} (TjMax {d}C)\n", .{ at, where(above), max });
        return close();
    }
    for (0..ncpus) |i| {
        var path_buf: [128]u8 = undefined;
        var num: [8]u8 = undefined;
        const name = std.fmt.bufPrint(&num, "{d}", .{cpus[i]}) catch continue;
        if (!journal.rememberMsr(msrPath(&path_buf, name), msr, originals[i])) {
            sys.print("tcc: cannot journal the register, left alone\n");
            return close();
        }
    }
    for (0..ncpus) |i| _ = writeMsr(fds[i], withPoint(originals[i], point));
    applied = true;
    const back = readMsr(fds[0]) orelse 0;
    if (offsetOf(back) != offsetOf(wanted)) {
        sys.print("tcc: the firmware ignores the offset, the CPU's own throttle stays at TjMax\n");
        restore();
        return close();
    }
    sys.printf("tcc: the CPU throttles itself from {d}C, {s} (TjMax {d}C)\n", .{ at, where(above), max });
}

fn where(above: u8) []const u8 {
    return switch (above) {
        0 => "at the limit",
        1 => "1 above the limit",
        2 => "2 above the limit",
        3 => "3 above the limit",
        else => "above the limit",
    };
}

fn close() void {
    for (fds[0..ncpus]) |fd| sys.close(fd);
    ncpus = 0;
}

/// Through the registers kept open: the sandbox lets nothing new be opened. Also from a crash.
pub fn restore() void {
    if (!applied) return;
    applied = false;
    for (0..ncpus) |i| _ = writeMsr(fds[i], originals[i]);
}

/// For `zcool list`: where the CPU throttles itself now.
pub fn describe(buf: []u8) ?[]const u8 {
    var path_buf: [128]u8 = undefined;
    const fd = sys.openRead(msrPath(&path_buf, "0")) orelse return null;
    defer sys.close(fd);
    const value = readMsr(fd) orelse return null;
    const max = tjmax(value);
    if (max < 80 or max > 120) return null;
    return std.fmt.bufPrint(buf, "the CPU throttles itself from {d}C (TjMax {d}C, offset {d})", .{ max - offsetOf(value), max, offsetOf(value) }) catch null;
}

test "the offset puts the throttle just above the limit, within what the register holds" {
    const reg: u64 = (0x0a << 8) | (100 << 16) | (5 << 24) | (1 << 31);
    try std.testing.expectEqual(@as(u8, 100), tjmax(reg));
    try std.testing.expectEqual(@as(u8, 5), offsetOf(reg));
    // 85 + 3: 12 below TjMax, and nothing else in the register changes
    const set = withPoint(reg, 88);
    try std.testing.expectEqual(@as(u8, 12), offsetOf(set));
    try std.testing.expectEqual(reg & ~(@as(u64, 0x3f) << 24), set & ~(@as(u64, 0x3f) << 24));
    // never below 60 C, never more than six bits, never above TjMax
    try std.testing.expectEqual(@as(u8, 40), offsetOf(withPoint(reg, 33)));
    try std.testing.expectEqual(@as(u8, 0), offsetOf(withPoint(reg, 105)));
    const hot: u64 = 125 << 16;
    try std.testing.expectEqual(@as(u8, 63), offsetOf(withPoint(hot, 60)));
}
