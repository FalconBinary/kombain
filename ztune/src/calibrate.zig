// SPDX-License-Identifier: GPL-3.0-or-later

//! `ztune calibrate`: how many jobs a build should run on this machine.
//!
//! A laptop held at its temperature limit may build as fast on fewer jobs as on all: past
//! a point the jobs only share the same watts, and the heat and the noise go up. So it runs a
//! load shaped like a compiler's, on 1, a quarter, half, three quarters and all of the CPUs,
//! and takes the fewest jobs within 3% of the fastest. MAKEFLAGS, CARGO_BUILD_JOBS and
//! CMAKE_BUILD_PARALLEL_LEVEL get that number, unless a shell sets them itself.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

pub const Point = struct { jobs: u16, rate: f32, watts: f32 = 0 };
pub const max_points = 5;

/// The job counts it tries, smallest first and each once.
pub fn steps(cpus: u16, out: *[max_points]u16) []const u16 {
    var n: usize = 0;
    const tries = [_]u16{ 1, cpus / 4, cpus / 2, cpus * 3 / 4, cpus };
    for (tries) |t| {
        if (t == 0) continue;
        if (n > 0 and out[n - 1] >= t) continue;
        out[n] = t;
        n += 1;
    }
    return out[0..n];
}

/// The fewest jobs within 3% of the fastest.
pub fn best(points: []const Point) u16 {
    var fastest: f32 = 0;
    for (points) |p| fastest = @max(fastest, p.rate);
    for (points) |p| {
        if (p.rate >= fastest * 0.97) return p.jobs;
    }
    return if (points.len > 0) points[points.len - 1].jobs else 1;
}

/// /etc/profile.d/ztune.sh: what a login shell starts with, unless it says otherwise.
pub fn script(jobs: u16, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf,
        \\# Written by `ztune calibrate`: the build jobs this machine builds fastest with.
        \\# A value set before this file is read wins.
        \\: "${{MAKEFLAGS:=-j{d}}}"
        \\: "${{CARGO_BUILD_JOBS:={d}}}"
        \\: "${{CMAKE_BUILD_PARALLEL_LEVEL:={d}}}"
        \\export MAKEFLAGS CARGO_BUILD_JOBS CMAKE_BUILD_PARALLEL_LEVEL
        \\
    , .{ jobs, jobs, jobs }) catch "";
}

// ---------------------------------------------------------------- the load

/// One counter per worker, each on its own cache line, shared with the workers.
const Counters = [64][8]u64;
pub const max_workers = 64;

pub const Load = struct {
    counters: *volatile Counters,
    pids: [max_workers]i32 = undefined,
    n: usize = 0,

    pub fn init() ?Load {
        const PROT_RW = 3;
        const MAP_SHARED_ANON = 0x01 | 0x20;
        const addr = linux.syscall6(.mmap, 0, @sizeOf(Counters), PROT_RW, MAP_SHARED_ANON, @bitCast(@as(isize, -1)), 0);
        const signed: isize = @bitCast(addr);
        if (signed < 0 and signed > -4096) return null;
        return .{ .counters = @ptrFromInt(addr) };
    }

    pub fn start(self: *Load, n: usize) void {
        while (self.n < @min(n, max_workers)) {
            self.counters[self.n][0] = 0;
            const parent = linux.getpid();
            const rc = linux.fork();
            const signed: isize = @bitCast(rc);
            if (signed < 0) return;
            if (rc == 0) {
                sys.prctl(1, @backingInt(linux.SIG.KILL)); // PR_SET_PDEATHSIG
                if (linux.getppid() != parent) linux.exit_group(0);
                work(&self.counters[self.n][0]);
            }
            self.pids[self.n] = @intCast(rc);
            self.n += 1;
        }
    }

    pub fn total(self: *const Load) u64 {
        var sum: u64 = 0;
        for (0..self.n) |i| sum += self.counters[i][0];
        return sum;
    }

    pub fn stop(self: *Load) void {
        while (self.n > 0) {
            self.n -= 1;
            sys.kill(self.pids[self.n], .KILL);
            _ = sys.reap(self.pids[self.n], 1000);
        }
    }
};

/// Shaped like a compiler's work: hashing, branches and scattered reads and writes over a few
/// MiB, more than a core's own cache holds. It counts rounds of 4096.
fn work(counter: *volatile u64) noreturn {
    const size = 1 << 20;
    var table: [size]u32 = undefined;
    @memset(&table, 0);
    var x: u32 = 2463534242;
    while (true) {
        var i: u32 = 0;
        while (i < 4096) : (i += 1) {
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            const at = x & (size - 1);
            table[at] = if (table[at] & 1 == 0) table[at] +% x else table[at] ^ (x >> 3);
        }
        counter.* +%= 1;
        std.mem.doNotOptimizeAway(&table);
    }
}

test "the job counts it tries" {
    var buf: [max_points]u16 = undefined;
    try std.testing.expectEqualSlices(u16, &.{ 1, 3, 6, 9, 12 }, steps(12, &buf));
    try std.testing.expectEqualSlices(u16, &.{ 1, 2 }, steps(2, &buf));
    try std.testing.expectEqualSlices(u16, &.{1}, steps(1, &buf));
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 3, 4 }, steps(4, &buf));
}

test "the fewest jobs within 3% of the fastest" {
    // held at its limit, nine jobs build as fast as twelve
    const points = [_]Point{ .{ .jobs = 1, .rate = 100 }, .{ .jobs = 3, .rate = 280 }, .{ .jobs = 6, .rate = 500 }, .{ .jobs = 9, .rate = 590 }, .{ .jobs = 12, .rate = 600 } };
    try std.testing.expectEqual(@as(u16, 9), best(&points));
    const scaling = [_]Point{ .{ .jobs = 1, .rate = 100 }, .{ .jobs = 2, .rate = 200 } };
    try std.testing.expectEqual(@as(u16, 2), best(&scaling));
}

test "the profile script leaves a value set before it alone" {
    var buf: [512]u8 = undefined;
    const text = script(9, &buf);
    try std.testing.expect(std.mem.indexOf(u8, text, ": \"${MAKEFLAGS:=-j9}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ": \"${CARGO_BUILD_JOBS:=9}\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "CMAKE_BUILD_PARALLEL_LEVEL\n"));
}
