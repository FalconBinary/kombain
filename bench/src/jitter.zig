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

fn printf(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    print(std.fmt.bufPrint(&buf, fmt, args) catch return);
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
    std.mem.sort(u32, sorted, {}, std.sort.asc(u32));
    const p50 = percentile(sorted, 0.50);
    const p99 = percentile(sorted, 0.99);
    const max = if (count > 0) sorted[count - 1] else 0;
    const tenths = elapsed / 100_000_000;
    if (csv) {
        printf("{d},{d}.{d},{d},{d},{d},{d},{d}\n", .{ hz, tenths / 10, tenths % 10, count, misses, p50, p99, max });
    } else {
        printf("zjitter: {d} Hz for {d}.{d} s: {d} wakes, late {d} us at p50, {d} us at p99, {d} us at most; {d} missed a frame (late by {d} us or more)\n", .{ hz, tenths / 10, tenths % 10, count, p50, p99, max, misses, period / 1000 });
    }
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
