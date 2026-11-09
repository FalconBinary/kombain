// SPDX-License-Identifier: GPL-3.0-or-later

//! zjitter: how late a task that wants to run 144 times a second wakes up, while the machine
//! does whatever else it does. That is what a game's frame loop, a compositor and an audio
//! thread live on: a wake that comes a whole frame late is a frame dropped. No libc; it sleeps
//! on the monotonic clock with absolute deadlines, so its own work never shifts the schedule.
//!
//!   zjitter [--hz N] [--seconds N] [--csv]
//!
//! SIGTERM or SIGINT end it early and it reports what it has: kombain-bench runs it for the
//! length of a build. The CSV line is hz,seconds,wakes,misses,p50_us,p99_us,max_us.

const std = @import("std");
const linux = std.os.linux;

/// The default panic handler prints a symbolised stack trace and brings most of std.debug with
/// it: a third of zcool's size, measured. A bench tool reports its panic in one line.
pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .signal_stack_size = null,
};

pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(msg: []const u8, _: ?usize) noreturn {
    @branchHint(.cold);
    _ = linux.write(2, "zjitter: internal error: ".ptr, 25);
    _ = linux.write(2, msg.ptr, msg.len);
    _ = linux.write(2, "\n".ptr, 1);
    linux.exit_group(134);
}

/// ten minutes at 144 Hz, in .bss
const max_samples = 144 * 600;
var samples: [max_samples]u32 = undefined;
var stop: bool = false;

fn onSignal(_: linux.SIG) callconv(.c) void {
    stop = true;
}

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn print(text: []const u8) void {
    var off: usize = 0;
    while (off < text.len) {
        const rc = linux.write(1, text[off..].ptr, text.len - off);
        const signed: isize = @bitCast(rc);
        if (signed <= 0) return;
        off += rc;
    }
}

/// Decimal digits of `v` appended to `buf` at `n`: std.fmt would be most of this program.
fn num(buf: []u8, n: usize, v: u64) usize {
    var digits: [20]u8 = undefined;
    var i: usize = digits.len;
    var x = v;
    while (true) {
        i -= 1;
        digits[i] = @intCast('0' + x % 10);
        x /= 10;
        if (x == 0) break;
    }
    const len = digits.len - i;
    @memcpy(buf[n..][0..len], digits[i..]);
    return n + len;
}

fn str(buf: []u8, n: usize, s: []const u8) usize {
    @memcpy(buf[n..][0..s.len], s);
    return n + s.len;
}

/// Microseconds sorted by their bytes, four passes of a counting sort: no comparison sort's
/// generic code, and 86 400 samples take a millisecond.
fn sortU32(a: []u32) void {
    var tmp: [max_samples]u32 = undefined;
    var src = a;
    var dst: []u32 = tmp[0..a.len];
    var shift: u5 = 0;
    while (true) : (shift += 8) {
        var counts: [257]usize = @splat(0);
        for (src) |v| counts[((v >> shift) & 0xff) + 1] += 1;
        for (1..257) |i| counts[i] += counts[i - 1];
        for (src) |v| {
            const b = (v >> shift) & 0xff;
            dst[counts[b]] = v;
            counts[b] += 1;
        }
        const t = src;
        src = dst;
        dst = t;
        if (shift == 24) break;
    }
    // four passes: the result is back in `a`
}

/// The value at rank ceil(p * n) of the sorted samples, 1-based: p99 of 200 is the 198th.
pub fn percentile(sorted: []const u32, p: f64) u32 {
    if (sorted.len == 0) return 0;
    const rank: usize = @intFromFloat(@ceil(p * @as(f64, @floatFromInt(sorted.len))));
    return sorted[@min(@max(rank, 1), sorted.len) - 1];
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    var hz: u64 = 144;
    var seconds: u64 = 30;
    var csv = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "--csv")) {
            csv = true;
        } else if (std.mem.eql(u8, arg, "--hz") and i + 1 < argv.len) {
            i += 1;
            hz = std.fmt.parseInt(u64, std.mem.span(argv[i]), 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--seconds") and i + 1 < argv.len) {
            i += 1;
            seconds = std.fmt.parseInt(u64, std.mem.span(argv[i]), 10) catch 0;
        } else {
            print("zjitter [--hz N] [--seconds N] [--csv]: how late a periodic task wakes\n");
            return 2;
        }
    }
    if (hz < 1 or hz > 1000 or seconds < 1) {
        print("zjitter: hz from 1 to 1000, seconds from 1\n");
        return 2;
    }
    var act = linux.Sigaction{ .handler = .{ .handler = onSignal }, .mask = linux.sigemptyset(), .flags = 0 };
    for ([_]linux.SIG{ .TERM, .INT, .HUP }) |signal| _ = linux.sigaction(signal, &act, null);

    const period: u64 = 1_000_000_000 / hz;
    const wanted: usize = @intCast(@min(hz * seconds, max_samples));
    const start = nowNs();
    var next = start + period;
    var count: usize = 0;
    var misses: u64 = 0;
    while (!stop and count < wanted) {
        const ts = linux.timespec{ .sec = @intCast(next / 1_000_000_000), .nsec = @intCast(next % 1_000_000_000) };
        _ = linux.clock_nanosleep(.MONOTONIC, .{ .ABSTIME = true }, &ts, null);
        if (stop) break;
        const t = nowNs();
        const late = if (t > next) t - next else 0;
        samples[count] = @intCast(@min(late / 1000, std.math.maxInt(u32)));
        count += 1;
        if (late >= period) {
            // a whole frame or more: this one and every deadline already past are missed
            const skipped = late / period;
            misses += skipped;
            next += period * (skipped + 1);
        } else {
            next += period;
        }
    }
    const elapsed = nowNs() - start;
    const sorted = samples[0..count];
    sortU32(sorted);
    const p50 = percentile(sorted, 0.50);
    const p99 = percentile(sorted, 0.99);
    const max = if (count > 0) sorted[count - 1] else 0;
    const tenths = elapsed / 100_000_000;
    var line: [256]u8 = undefined;
    var n: usize = 0;
    if (csv) {
        n = num(&line, n, hz);
        n = str(&line, n, ",");
        n = num(&line, n, tenths / 10);
        n = str(&line, n, ".");
        n = num(&line, n, tenths % 10);
        for ([_]u64{ count, misses, p50, p99, max }) |v| {
            n = str(&line, n, ",");
            n = num(&line, n, v);
        }
    } else {
        n = str(&line, n, "zjitter: ");
        n = num(&line, n, hz);
        n = str(&line, n, " Hz for ");
        n = num(&line, n, tenths / 10);
        n = str(&line, n, ".");
        n = num(&line, n, tenths % 10);
        n = str(&line, n, " s: ");
        n = num(&line, n, count);
        n = str(&line, n, " wakes, late ");
        n = num(&line, n, p50);
        n = str(&line, n, " us at p50, ");
        n = num(&line, n, p99);
        n = str(&line, n, " us at p99, ");
        n = num(&line, n, max);
        n = str(&line, n, " us at most; ");
        n = num(&line, n, misses);
        n = str(&line, n, " missed a frame (late by ");
        n = num(&line, n, period / 1000);
        n = str(&line, n, " us or more)");
    }
    n = str(&line, n, "\n");
    print(line[0..n]);
    return 0;
}

test "percentiles by rank" {
    const s = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    try std.testing.expectEqual(@as(u32, 5), percentile(&s, 0.50));
    try std.testing.expectEqual(@as(u32, 10), percentile(&s, 0.99));
    try std.testing.expectEqual(@as(u32, 10), percentile(&s, 0.95));
    try std.testing.expectEqual(@as(u32, 1), percentile(&s, 0.0));
    try std.testing.expectEqual(@as(u32, 0), percentile(&.{}, 0.5));
}

test "the counting sort sorts" {
    var a = [_]u32{ 300000, 5, 70000, 0, 256, 255, 70000, 1 << 31, 42 };
    sortU32(&a);
    try std.testing.expectEqualSlices(u32, &.{ 0, 5, 42, 255, 256, 70000, 70000, 300000, 1 << 31 }, &a);
    var line: [32]u8 = undefined;
    const n = num(&line, 0, 1234567890123);
    try std.testing.expectEqualStrings("1234567890123", line[0..n]);
    try std.testing.expectEqualStrings("0", line[0..num(&line, 0, 0)]);
}
