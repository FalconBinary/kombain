// SPDX-License-Identifier: GPL-3.0-or-later

//! `ztune calibrate`: how many jobs a build should run on this machine.
//!
//! A laptop held at its temperature limit may build as fast on fewer jobs as on all: past
//! a point the jobs only share the same watts, and the heat and the noise go up. So it runs a
//! load shaped like a compiler's on all the CPUs, three quarters, half, a quarter and one,
//! from the top so that every step is measured on a machine as warm as a long build keeps it,
//! and takes the fewest jobs within 3% of the fastest, never fewer than there are cores.
//! MAKEFLAGS, CARGO_BUILD_JOBS and CMAKE_BUILD_PARALLEL_LEVEL get that number, unless a
//! shell sets them itself.
//!
//! The first load here walked 4 MiB per job at random: one job fit the GF63's 12 MiB of
//! cache, three filled it, and from there every job waited on memory and twelve ran no
//! faster than one. It said 3 jobs, and a shell built three times slower than it could. A
//! compiler's working set mostly fits a core's own cache; so does this one's now.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

pub const Point = struct { jobs: u16, rate: f32, watts: f32 = 0 };
pub const max_points = 5;

/// The job counts it tries, all the CPUs first and each once.
pub fn steps(cpus: u16, out: *[max_points]u16) []const u16 {
    var n: usize = 0;
    const tries = [_]u16{ cpus, cpus * 3 / 4, cpus / 2, cpus / 4, 1 };
    for (tries) |t| {
        if (t == 0) continue;
        if (n > 0 and out[n - 1] <= t) continue;
        out[n] = t;
        n += 1;
    }
    return out[0..n];
}

/// The fewest jobs within 3% of the fastest, and never fewer than `floor`: a job per core at
/// least, whatever a measurement says.
pub fn best(points: []const Point, floor: u16) u16 {
    var fastest: f32 = 0;
    var most: u16 = 1;
    for (points) |p| {
        fastest = @max(fastest, p.rate);
        most = @max(most, p.jobs);
    }
    var fewest = most;
    for (points) |p| {
        if (p.rate >= fastest * 0.97) fewest = @min(fewest, p.jobs);
    }
    return @min(@max(fewest, floor), most);
}

/// The cores under the CPUs, from which CPUs are siblings: 6 on a CPU with 12 threads. Read
/// from the real /sys whatever the root, as the load runs on the real CPUs.
pub fn physicalCores(cpus: u16) u16 {
    var cores: u16 = 0;
    var i: u16 = 0;
    while (i < cpus) : (i += 1) {
        var num: [8]u8 = undefined;
        var path_buf: [128]u8 = undefined;
        var text: [256]u8 = undefined;
        const digits = std.fmt.bufPrint(&num, "{d}", .{i}) catch break;
        const list = sys.readFile(sys.join(&path_buf, &.{ "/sys/devices/system/cpu/cpu", digits, "/topology/thread_siblings_list" }), &text) orelse break;
        // the first CPU of a core's list is the core
        var first = std.mem.tokenizeAny(u8, list, ",-\n");
        const head = std.fmt.parseInt(u16, first.next() orelse break, 10) catch break;
        if (head == i) cores += 1;
    }
    return if (cores > 0) cores else @max(cpus / 2, 1);
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

    /// Workers up to `n`, or down to it: the counters of those stopped stay where they were.
    pub fn set(self: *Load, n: usize) void {
        while (self.n > n) {
            self.n -= 1;
            sys.kill(self.pids[self.n], .KILL);
            _ = sys.reap(self.pids[self.n], 1000);
        }
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
        self.set(0);
    }
};

/// Shaped like a compiler's work: hashing, branches and scattered reads and writes over
/// 192 KiB, within a core's own cache as most of a compiler's working set is, so that the
/// jobs share the cores and the watts, not the memory bus. It counts rounds of 4096.
fn work(counter: *volatile u64) noreturn {
    const size = 48 * 1024;
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

test "the job counts it tries, from the top" {
    var buf: [max_points]u16 = undefined;
    try std.testing.expectEqualSlices(u16, &.{ 12, 9, 6, 3, 1 }, steps(12, &buf));
    try std.testing.expectEqualSlices(u16, &.{ 2, 1 }, steps(2, &buf));
    try std.testing.expectEqualSlices(u16, &.{1}, steps(1, &buf));
    try std.testing.expectEqualSlices(u16, &.{ 4, 3, 2, 1 }, steps(4, &buf));
}

test "the fewest jobs within 3% of the fastest, a job per core at least" {
    // held at its limit, nine jobs build as fast as twelve
    const points = [_]Point{ .{ .jobs = 12, .rate = 600 }, .{ .jobs = 9, .rate = 590 }, .{ .jobs = 6, .rate = 500 }, .{ .jobs = 3, .rate = 280 }, .{ .jobs = 1, .rate = 100 } };
    try std.testing.expectEqual(@as(u16, 9), best(&points, 6));
    const scaling = [_]Point{ .{ .jobs = 2, .rate = 200 }, .{ .jobs = 1, .rate = 100 } };
    try std.testing.expectEqual(@as(u16, 2), best(&scaling, 1));
    // what the GF63 measured with the memory-bound load: three said enough, six cores say no
    const memory_bound = [_]Point{ .{ .jobs = 12, .rate = 90 }, .{ .jobs = 9, .rate = 100 }, .{ .jobs = 6, .rate = 100 }, .{ .jobs = 3, .rate = 140 }, .{ .jobs = 1, .rate = 100 } };
    try std.testing.expectEqual(@as(u16, 6), best(&memory_bound, 6));
    // never more than was measured
    try std.testing.expectEqual(@as(u16, 2), best(&scaling, 8));
}

test "the profile script leaves a value set before it alone" {
    var buf: [512]u8 = undefined;
    const text = script(9, &buf);
    try std.testing.expect(std.mem.indexOf(u8, text, ": \"${MAKEFLAGS:=-j9}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ": \"${CARGO_BUILD_JOBS:=9}\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "CMAKE_BUILD_PARALLEL_LEVEL\n"));
}
