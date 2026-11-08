// SPDX-License-Identifier: GPL-3.0-or-later

//! Keeps the machine usable when the work is more than it can do. Under CPU pressure the jobs
//! that have taken the CPU longest yield it to the desktop, sound and games, which in turn get
//! it first. When memory and swap are all but gone, the process that holds the most is ended
//! before the kernel stalls everything for minutes looking for room.
//!
//! Both read the kernel's pressure figures (/proc/pressure) once a second, on wakeups zcool has
//! anyway. The processes are looked at only while there is pressure.

const std = @import("std");
const sys = @import("sys.zig");

pub var cpu_on = true;
pub var memory_on = true;
pub var dry_run = false;

/// The CPU is short when tasks waited for it this share of the last 10 s.
pub const cpu_pressure: f32 = 40;
/// A job is one that has kept at least half a core busy since the last look.
pub const busy_share: f32 = 0.5;
pub const batch_nice = 10;
pub const desktop_nice = -5;

/// The session: never asked to yield, never ended.
const protected = [_][]const u8{
    "mango",          "Xwayland",     "gamescope", "netline", "zpanel",   "pipewire",
    "pipewire-pulse", "wireplumber",  "foot",      "seatd",   "elogind",  "elogind-daemon",
    "dbus-daemon",    "iwd",          "runit",     "runsv",   "runsvdir", "svlogd",
    "zcool",          "zcool-nvidia", "sshd",      "login",   "agetty",   "udevd",
    "init",           "dhcpcd",       "doas",      "fdash",   "swaylock",
};

/// What the desktop answers through: under pressure these get the CPU first.
const first = [_][]const u8{ "mango", "Xwayland", "gamescope", "netline", "zpanel", "pipewire", "pipewire-pulse", "wireplumber" };

fn isIn(comptime list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

// ---------------------------------------------------------------- what the kernel says

pub const Proc = struct {
    pid: i32 = 0,
    ppid: i32 = 0,
    pgrp: i32 = 0,
    nice: i32 = 0,
    /// user and system time, in clock ticks
    ticks: u64 = 0,
    rss_pages: u64 = 0,
    comm: [16]u8 = undefined,
    comm_len: u8 = 0,

    pub fn name(self: *const Proc) []const u8 {
        return self.comm[0..self.comm_len];
    }

    /// kthreadd and its children: nothing of the user's
    pub fn kernel(self: *const Proc) bool {
        return self.pid == 2 or self.ppid == 2 or self.pid <= 1;
    }
};

/// /proc/PID/stat. The name may hold spaces and parentheses: it ends at the last `)`.
pub fn parseStat(text: []const u8) ?Proc {
    var p = Proc{};
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    if (close < open or close + 2 > text.len) return null;
    p.pid = std.fmt.parseInt(i32, std.mem.trim(u8, text[0..open], " "), 10) catch return null;
    const comm = text[open + 1 .. close];
    p.comm_len = @intCast(@min(comm.len, p.comm.len));
    @memcpy(p.comm[0..p.comm_len], comm[0..p.comm_len]);
    var fields = std.mem.tokenizeScalar(u8, text[close + 2 ..], ' ');
    var i: usize = 0;
    var utime: u64 = 0;
    while (fields.next()) |f| : (i += 1) {
        switch (i) {
            1 => p.ppid = std.fmt.parseInt(i32, f, 10) catch return null,
            2 => p.pgrp = std.fmt.parseInt(i32, f, 10) catch return null,
            11 => utime = std.fmt.parseInt(u64, f, 10) catch return null,
            12 => p.ticks = utime + (std.fmt.parseInt(u64, f, 10) catch return null),
            16 => p.nice = std.fmt.parseInt(i32, f, 10) catch return null,
            21 => {
                p.rss_pages = std.fmt.parseInt(u64, f, 10) catch 0;
                return p;
            },
            else => {},
        }
    }
    return if (i > 16) p else null;
}

/// The avg10 of the `some` or the `full` line of a /proc/pressure file, in percent.
pub fn parsePressure(text: []const u8, full: bool) ?f32 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, if (full) "full " else "some ")) continue;
        const at = std.mem.indexOf(u8, line, "avg10=") orelse return null;
        const rest = line[at + 6 ..];
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        return decimal(rest[0..end]);
    }
    return null;
}

/// "12.34": far smaller than the standard float parser.
fn decimal(text: []const u8) ?f32 {
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse text.len;
    const whole = std.fmt.parseInt(u32, text[0..dot], 10) catch return null;
    var frac: f32 = 0;
    var scale: f32 = 0.1;
    if (dot < text.len) {
        for (text[dot + 1 ..]) |c| {
            if (c < '0' or c > '9') return null;
            frac += @as(f32, @floatFromInt(c - '0')) * scale;
            scale /= 10;
        }
    }
    return @as(f32, @floatFromInt(whole)) + frac;
}

pub const Memory = struct { total: u64 = 0, available: u64 = 0, swap_total: u64 = 0, swap_free: u64 = 0 };

pub fn parseMeminfo(text: []const u8) ?Memory {
    var m = Memory{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        var words = std.mem.tokenizeScalar(u8, line[colon + 1 ..], ' ');
        const kib = std.fmt.parseInt(u64, words.next() orelse continue, 10) catch continue;
        const key = line[0..colon];
        if (std.mem.eql(u8, key, "MemTotal")) m.total = kib;
        if (std.mem.eql(u8, key, "MemAvailable")) m.available = kib;
        if (std.mem.eql(u8, key, "SwapTotal")) m.swap_total = kib;
        if (std.mem.eql(u8, key, "SwapFree")) m.swap_free = kib;
    }
    return if (m.total > 0) m else null;
}

/// Memory is about to run out: almost nothing available and swap, if any, almost full, or the
/// kernel already stalling every task on it while little is left.
pub fn starving(m: Memory, full_pressure: f32) bool {
    const available = m.available * 100 / m.total;
    const swap_spent = m.swap_total == 0 or m.swap_free * 100 / m.swap_total <= 10;
    return (available <= 4 and swap_spent) or (full_pressure >= 40 and available <= 10);
}

// ---------------------------------------------------------------- reading /proc

fn procPath(buf: []u8, pid: i32, file: []const u8) [:0]const u8 {
    var num: [12]u8 = undefined;
    const digits = std.fmt.bufPrint(&num, "{d}", .{pid}) catch "0";
    return sys.join(buf, &.{ sys.root, "/proc/", digits, file });
}

fn readProc(pid: i32) ?Proc {
    var path: [96]u8 = undefined;
    var buf: [1024]u8 = undefined;
    return parseStat(sys.readFile(procPath(&path, pid, "/stat"), &buf) orelse return null);
}

fn pressure(file: []const u8, full: bool) ?f32 {
    var path: [96]u8 = undefined;
    var buf: [256]u8 = undefined;
    const text = sys.readFile(sys.join(&path, &.{ sys.root, "/proc/pressure/", file }), &buf) orelse return null;
    return parsePressure(text, full);
}

fn memory() ?Memory {
    var path: [64]u8 = undefined;
    var buf: [4096]u8 = undefined;
    return parseMeminfo(sys.readFile(sys.join(&path, &.{ sys.root, "/proc/meminfo" }), &buf) orelse return null);
}

/// Every process, one at a time.
const Procs = struct {
    dir: sys.Dir,

    fn open() ?Procs {
        var path: [64]u8 = undefined;
        return .{ .dir = sys.Dir.open(sys.join(&path, &.{ sys.root, "/proc" })) orelse return null };
    }

    fn next(self: *Procs) ?Proc {
        while (self.dir.next()) |entry| {
            const pid = std.fmt.parseInt(i32, entry, 10) catch continue;
            const p = readProc(pid) orelse continue;
            if (p.kernel()) continue;
            return p;
        }
        return null;
    }

    fn close(self: *Procs) void {
        self.dir.close();
    }
};

/// A game or anything else drawing on the GPU: it holds a render node or NVIDIA's device open.
fn drawsOnGpu(pid: i32) bool {
    var path: [96]u8 = undefined;
    var dir = sys.Dir.open(procPath(&path, pid, "/fd")) orelse return false;
    defer dir.close();
    var n: usize = 0;
    while (dir.next()) |fd| : (n += 1) {
        if (n > 4096) break;
        var link_path: [128]u8 = undefined;
        var base: [96]u8 = undefined;
        var target: [64]u8 = undefined;
        const at = sys.join(&link_path, &.{ procPath(&base, pid, "/fd/"), fd });
        const to = sys.readLink(at, &target) orelse continue;
        if (std.mem.startsWith(u8, to, "/dev/dri/") or std.mem.startsWith(u8, to, "/dev/nvidia")) return true;
    }
    return false;
}

// ---------------------------------------------------------------- acting

const prio_process = 0;
const prio_pgrp = 1;
const ioprio_who_process = 1;
const ioprio_who_pgrp = 2;
/// best effort, the lowest of its eight levels
const ioprio_batch = (2 << 13) | 7;

fn setNice(which: usize, who: i32, nice: i32) bool {
    return sys.raw(.setpriority, which, @as(usize, @intCast(who)), @as(usize, @bitCast(@as(isize, nice))), 0) != null;
}

fn setIoprio(who_kind: usize, who: i32, value: usize) void {
    _ = sys.raw(.ioprio_set, who_kind, @as(usize, @intCast(who)), value, 0);
}

/// nice is per thread on Linux: every thread of the process.
fn reniceProcess(pid: i32, nice: i32) bool {
    var path: [96]u8 = undefined;
    var dir = sys.Dir.open(procPath(&path, pid, "/task")) orelse return setNice(prio_process, pid, nice);
    defer dir.close();
    var any = false;
    while (dir.next()) |entry| {
        const tid = std.fmt.parseInt(i32, entry, 10) catch continue;
        if (setNice(prio_process, tid, nice)) any = true;
    }
    return any or setNice(prio_process, pid, nice);
}

// ---------------------------------------------------------------- the CPU

const max_seen = 1024;
const Seen = struct { pid: i32, ticks: u64 };
var seen: [max_seen]Seen = undefined;
var nseen: usize = 0;
var seen_ms: i64 = 0;

var groups: [64]i32 = undefined;
var ngroups: usize = 0;
var lone: [64]i32 = undefined;
var nlone: usize = 0;
var boosted: [32]i32 = undefined;
var nboosted: usize = 0;

fn ticksBefore(pid: i32) ?u64 {
    for (seen[0..nseen]) |s| if (s.pid == pid) return s.ticks;
    return null;
}

fn contains(list: []const i32, v: i32) bool {
    for (list) |x| if (x == v) return true;
    return false;
}

/// Under CPU pressure: the desktop first, the jobs that have taken the CPU longest after it.
fn shareCpu(now: i64) void {
    var procs = Procs.open() orelse return;
    defer procs.close();
    var fresh: [max_seen]Seen = undefined;
    var nfresh: usize = 0;
    var protected_groups: [64]i32 = undefined;
    var nprotected: usize = 0;
    var busy: [32]Proc = undefined;
    var nbusy: usize = 0;
    const seconds = @as(f32, @floatFromInt(now - seen_ms)) / 1000;

    while (procs.next()) |p| {
        if (nfresh < max_seen) {
            fresh[nfresh] = .{ .pid = p.pid, .ticks = p.ticks };
            nfresh += 1;
        }
        if (isIn(&protected, p.name())) {
            if (nprotected < protected_groups.len and !contains(protected_groups[0..nprotected], p.pgrp)) {
                protected_groups[nprotected] = p.pgrp;
                nprotected += 1;
            }
            if (isIn(&first, p.name()) and p.nice == 0 and nboosted < boosted.len and !contains(boosted[0..nboosted], p.pid)) {
                if (dry_run or reniceProcess(p.pid, desktop_nice)) {
                    boosted[nboosted] = p.pid;
                    nboosted += 1;
                    sys.printf("guard: {s} {s} the CPU first, nice {d}\n", .{ p.name(), if (dry_run) "would get" else "gets", desktop_nice });
                }
            }
            continue;
        }
        if (p.nice != 0 or nseen == 0 or seconds <= 0) continue;
        const before = ticksBefore(p.pid) orelse continue;
        const share = @as(f32, @floatFromInt(p.ticks -| before)) / 100 / seconds;
        if (share >= busy_share and nbusy < busy.len) {
            busy[nbusy] = p;
            nbusy += 1;
        }
    }
    @memcpy(seen[0..nfresh], fresh[0..nfresh]);
    nseen = nfresh;
    seen_ms = now;

    for (busy[0..nbusy]) |*p| {
        // a game draws on the GPU: it keeps its share, only the work around it yields
        if (drawsOnGpu(p.pid)) continue;
        if (p.pgrp > 1 and !contains(protected_groups[0..nprotected], p.pgrp)) {
            if (contains(groups[0..ngroups], p.pgrp) or ngroups == groups.len) continue;
            // the whole job: make and every compiler it starts, now and later
            if (!dry_run) {
                if (!setNice(prio_pgrp, p.pgrp, batch_nice)) continue;
                setIoprio(ioprio_who_pgrp, p.pgrp, ioprio_batch);
            }
            groups[ngroups] = p.pgrp;
            ngroups += 1;
            sys.printf("guard: {s} and its job {s} to the desktop, nice {d}\n", .{ p.name(), if (dry_run) "would yield" else "yield", batch_nice });
        } else {
            if (contains(lone[0..nlone], p.pid) or nlone == lone.len) continue;
            if (!dry_run) {
                if (!reniceProcess(p.pid, batch_nice)) continue;
                setIoprio(ioprio_who_process, p.pid, ioprio_batch);
            }
            lone[nlone] = p.pid;
            nlone += 1;
            sys.printf("guard: {s} {s} to the desktop, nice {d}\n", .{ p.name(), if (dry_run) "would yield" else "yields", batch_nice });
        }
    }
}

// ---------------------------------------------------------------- memory

var victim: i32 = 0;
var victim_ms: i64 = 0;
var calm_until: i64 = 0;
var starving_logged = false;

fn alive(pid: i32) bool {
    return sys.raw(.kill, @as(usize, @intCast(pid)), 0, 0, 0) != null;
}

fn oomScore(pid: i32) ?i64 {
    var path: [96]u8 = undefined;
    var buf: [32]u8 = undefined;
    const adj = sys.readFile(procPath(&path, pid, "/oom_score_adj"), &buf);
    if (adj) |a| {
        if (std.mem.eql(u8, std.mem.trim(u8, a, " \n"), "-1000")) return null;
    }
    const text = sys.readFile(procPath(&path, pid, "/oom_score"), &buf) orelse return null;
    return std.fmt.parseInt(i64, std.mem.trim(u8, text, " \n"), 10) catch null;
}

fn guardMemory(now: i64) void {
    const m = memory() orelse return;
    const full = pressure("memory", true) orelse 0;
    if (!starving(m, full)) {
        victim = 0;
        starving_logged = false;
        return;
    }
    // the one asked to end did not: now it is ended
    if (victim != 0) {
        if (!alive(victim)) {
            victim = 0;
        } else if (now - victim_ms >= 3000) {
            if (!dry_run) _ = sys.raw(.kill, @as(usize, @intCast(victim)), 9, 0, 0);
            sys.printf("guard: {d} did not end, killed\n", .{victim});
            victim = 0;
            calm_until = now + 3000;
        }
        return;
    }
    if (now < calm_until) return;
    var procs = Procs.open() orelse return;
    defer procs.close();
    var best: ?Proc = null;
    var best_score: i64 = -1;
    while (procs.next()) |p| {
        if (isIn(&protected, p.name())) continue;
        const score = oomScore(p.pid) orelse continue;
        if (score > best_score) {
            best = p;
            best_score = score;
        }
    }
    const p = best orelse {
        if (!starving_logged) sys.print("guard: memory is all but gone, and nothing outside the session to end\n");
        starving_logged = true;
        return;
    };
    const mib = p.rss_pages * 4096 / (1024 * 1024);
    sys.printf("guard: {d}% of memory left{s}: {s} {s} ({d}, {d} MiB) before the system stalls\n", .{
        m.available * 100 / m.total,
        if (m.swap_total > 0) " and swap full" else "",
        if (dry_run) "would end" else "ending",
        p.name(),
        p.pid,
        mib,
    });
    if (!dry_run) _ = sys.raw(.kill, @as(usize, @intCast(p.pid)), 15, 0, 0);
    victim = if (dry_run) 0 else p.pid;
    victim_ms = now;
    calm_until = now + 5000;
}

// ---------------------------------------------------------------- the loop

var cpu_due: i64 = 0;
var scan_due: i64 = 0;
var memory_due: i64 = 0;

pub fn tick(now: i64) void {
    if (cpu_on and now >= cpu_due) {
        cpu_due = now + 1000;
        const p = pressure("cpu", false) orelse 0;
        if (p >= cpu_pressure and now >= scan_due) {
            scan_due = now + 3000;
            shareCpu(now);
        } else if (p < cpu_pressure) {
            // the next look under pressure starts its own measure
            nseen = 0;
        }
    }
    if (memory_on and now >= memory_due) {
        memory_due = now + 1000;
        guardMemory(now);
    }
}

/// The desktop and the jobs get their nice back. Not journaled: one left behind by a crash
/// costs nothing but a little priority.
pub fn restore() void {
    if (dry_run) return;
    for (boosted[0..nboosted]) |pid| {
        const p = readProc(pid) orelse continue;
        if (p.nice == desktop_nice) _ = reniceProcess(pid, 0);
    }
    for (groups[0..ngroups]) |pgrp| {
        _ = setNice(prio_pgrp, pgrp, 0);
        setIoprio(ioprio_who_pgrp, pgrp, 0);
    }
    for (lone[0..nlone]) |pid| {
        const p = readProc(pid) orelse continue;
        if (p.nice == batch_nice) _ = reniceProcess(pid, 0);
        setIoprio(ioprio_who_process, pid, 0);
    }
    nboosted = 0;
    ngroups = 0;
    nlone = 0;
}

/// For `zcool list`.
pub fn summary(buf: []u8) ?[]const u8 {
    const cpu = pressure("cpu", false);
    const m = memory();
    if (cpu == null and m == null) return null;
    var n: usize = 0;
    if (cpu) |c| n += (std.fmt.bufPrint(buf[n..], "cpu waited {d:.0}% of the last 10 s", .{c}) catch return null).len;
    if (m) |mem| n += (std.fmt.bufPrint(buf[n..], "{s}memory {d}% free", .{ if (n > 0) ", " else "", mem.available * 100 / mem.total }) catch return null).len;
    return buf[0..n];
}

test "a process's stat, a name with spaces and parentheses in it" {
    const p = parseStat("4242 (Web Content (x)) R 100 4242 4242 0 -1 4194304 1 2 3 4 1500 250 0 0 20 5 12 0 999 123456 7890 18446744073709551615").?;
    try std.testing.expectEqual(@as(i32, 4242), p.pid);
    try std.testing.expectEqualStrings("Web Content (x)", p.name());
    try std.testing.expectEqual(@as(i32, 100), p.ppid);
    try std.testing.expectEqual(@as(i32, 4242), p.pgrp);
    try std.testing.expectEqual(@as(u64, 1750), p.ticks);
    try std.testing.expectEqual(@as(i32, 5), p.nice);
    try std.testing.expectEqual(@as(u64, 7890), p.rss_pages);
    try std.testing.expect(!p.kernel());
    try std.testing.expect(parseStat("12 (kworker/0:1) I 2 0 0 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 5 0 0").?.kernel());
    try std.testing.expect(parseStat("garbage") == null);
}

test "pressure and memory figures" {
    const text = "some avg10=42.50 avg60=10.00 avg300=1.00 total=123\nfull avg10=7.25 avg60=0.00 avg300=0.00 total=9\n";
    try std.testing.expectApproxEqAbs(@as(f32, 42.5), parsePressure(text, false).?, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 7.25), parsePressure(text, true).?, 0.01);
    try std.testing.expect(parsePressure("nothing", false) == null);
    const m = parseMeminfo("MemTotal:       32000000 kB\nMemFree:  100 kB\nMemAvailable:    1000000 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n").?;
    try std.testing.expectEqual(@as(u64, 32000000), m.total);
    try std.testing.expectEqual(@as(u64, 1000000), m.available);
    // 3% left and no swap: starving
    try std.testing.expect(starving(m, 0));
    // 20% left: fine, even with pressure
    try std.testing.expect(!starving(.{ .total = 100, .available = 20 }, 80));
    // 8% left with the kernel stalling on it: starving
    try std.testing.expect(starving(.{ .total = 100, .available = 8, .swap_total = 100, .swap_free = 50 }, 45));
    // 3% left but half the swap free: not yet
    try std.testing.expect(!starving(.{ .total = 100, .available = 3, .swap_total = 100, .swap_free = 50 }, 0));
}
