// SPDX-License-Identifier: GPL-3.0-or-later

//! `zcool undervolt find`: the ladder of voltage offsets, what a step leaves on disk before the
//! offset is written, and what the search leaves when it ends. No system calls: main.zig runs it.
//!
//! The only oracle of a stable offset is the machine itself. Each step of the ladder runs work
//! with a known answer on every core at the thermal limit, then single-core bursts out of idle,
//! and watches for three things: an answer that is wrong, a machine check in the kernel's log,
//! and the machine not coming back at all. The last one is read from the state file after a
//! reboot. The search ends two steps above the first offset that failed: a margin of 10 to 20
//! mV to the edge it found. It never applies what it found: the user does, in the BIOS or in
//! /etc/zcool.conf, and only `undervolt.core` and `undervolt.cache` there are ever applied.

const std = @import("std");
const code = @import("undervolt_code.zig");

pub const step_mv: i32 = 10;
pub const default_from: i32 = -50;
pub const floor_mv: i32 = code.max_offset_mv;
/// a step: five minutes at the limit on every core, two of bursts out of idle
pub const default_seconds: u32 = 420;

pub const Why = enum {
    crash,
    mce,
    wrong_answer,
    floor,

    pub fn name(self: Why) []const u8 {
        return switch (self) {
            .crash => "crash",
            .mce => "mce",
            .wrong_answer => "wrong-answer",
            .floor => "floor",
        };
    }

    pub fn parse(text: []const u8) ?Why {
        for ([_]Why{ .crash, .mce, .wrong_answer, .floor }) |w| {
            if (std.mem.eql(u8, text, w.name())) return w;
        }
        return null;
    }
};

/// The next step down, or null past `to`.
pub fn next(mv: i32, to: i32) ?i32 {
    const n = mv - step_mv;
    return if (n < to) null else n;
}

/// Two steps above the first offset that failed: 10 to 20 mV above the edge it found. When nothing
/// failed down to `deepest`, the last step tried, one step above that, since where the edge is
/// nobody knows. Never below zero: a CPU that fails at the first step gets no offset.
pub fn recommend(bad: ?i32, deepest: i32) i32 {
    return @min((bad orelse (deepest - step_mv)) + 2 * step_mv, 0);
}

/// Of a step's two parts, how long the work at the limit runs: the rest is bursts out of idle.
pub fn hotSeconds(seconds: u32) u32 {
    return @max(seconds * 5 / 7, 1);
}

/// A line of the kernel's log that is a machine check, not a thermal note from the same subsystem:
/// `mce: [Hardware Error]: CPU 2: Machine Check: 0 Bank 1: ...`.
pub fn isMachineCheck(text: []const u8) bool {
    return containsIgnoringCase(text, "machine check") or containsIgnoringCase(text, "hardware error");
}

fn containsIgnoringCase(text: []const u8, needle: []const u8) bool {
    if (needle.len > text.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= text.len) : (i += 1) {
        for (needle, 0..) |c, k| {
            if (std.ascii.toLower(text[i + k]) != c) continue :outer;
        }
        return true;
    }
    return false;
}

/// What a step leaves on disk before its offset is written. A search that does not come back is
/// concluded from it at the next start: the step took the machine down.
pub const State = struct {
    step: i32,
    good: ?i32 = null,
    from: i32 = default_from,
    to: i32 = floor_mv,
    seconds: u32 = default_seconds,

    pub fn format(self: *const State, buf: []u8) []const u8 {
        var n: usize = 0;
        n = appendf(buf, n, "step {d}\n", .{self.step});
        if (self.good) |g| n = appendf(buf, n, "good {d}\n", .{g});
        n = appendf(buf, n, "from {d}\nto {d}\nseconds {d}\n", .{ self.from, self.to, self.seconds });
        return buf[0..n];
    }

    pub fn parse(text: []const u8) ?State {
        var s = State{ .step = 1 };
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            const key = f.next() orelse continue;
            const value = std.fmt.parseInt(i32, f.next() orelse continue, 10) catch continue;
            if (std.mem.eql(u8, key, "step")) {
                s.step = value;
            } else if (std.mem.eql(u8, key, "good")) {
                s.good = value;
            } else if (std.mem.eql(u8, key, "from")) {
                s.from = value;
            } else if (std.mem.eql(u8, key, "to")) {
                s.to = value;
            } else if (std.mem.eql(u8, key, "seconds") and value > 0) {
                s.seconds = @intCast(value);
            }
        }
        if (s.step > 0 or s.step < floor_mv) return null;
        return s;
    }
};

/// What a search leaves when it ends, for `zcool list` and the next search to show.
pub const Found = struct {
    /// the recommendation: two steps above `bad`, or one above the floor
    mv: i32,
    /// the deepest step that held every test
    good: ?i32 = null,
    /// the first step that failed, how, and for how long each step ran
    bad: ?i32 = null,
    why: Why,
    seconds: u32 = default_seconds,
    /// Unix time, 0 when unknown
    when: i64 = 0,

    pub fn format(self: *const Found, buf: []u8) []const u8 {
        var n: usize = 0;
        n = appendf(buf, n, "mv {d}\nwhy {s}\nseconds {d}\nwhen {d}\n", .{ self.mv, self.why.name(), self.seconds, self.when });
        if (self.good) |g| n = appendf(buf, n, "good {d}\n", .{g});
        if (self.bad) |b| n = appendf(buf, n, "bad {d}\n", .{b});
        return buf[0..n];
    }

    pub fn parse(text: []const u8) ?Found {
        var f = Found{ .mv = 1, .why = .floor };
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var t = std.mem.tokenizeScalar(u8, line, ' ');
            const key = t.next() orelse continue;
            const value = t.next() orelse continue;
            if (std.mem.eql(u8, key, "why")) {
                f.why = Why.parse(value) orelse return null;
                continue;
            }
            const number = std.fmt.parseInt(i64, value, 10) catch continue;
            if (std.mem.eql(u8, key, "mv")) {
                f.mv = @intCast(std.math.clamp(number, floor_mv, 0));
            } else if (std.mem.eql(u8, key, "good")) {
                f.good = @intCast(std.math.clamp(number, floor_mv, 0));
            } else if (std.mem.eql(u8, key, "bad")) {
                f.bad = @intCast(std.math.clamp(number, floor_mv, 0));
            } else if (std.mem.eql(u8, key, "seconds") and number > 0) {
                f.seconds = @intCast(@min(number, 1_000_000));
            } else if (std.mem.eql(u8, key, "when")) {
                f.when = number;
            }
        }
        if (f.mv > 0) return null;
        return f;
    }
};

fn appendf(buf: []u8, n: usize, comptime fmt: []const u8, args: anytype) usize {
    const written = std.fmt.bufPrint(buf[n..], fmt, args) catch return n;
    return n + written.len;
}

test "the ladder goes down in steps and recommends two above the first failure" {
    try std.testing.expectEqual(@as(?i32, -60), next(-50, floor_mv));
    try std.testing.expectEqual(@as(?i32, null), next(-120, floor_mv));
    try std.testing.expectEqual(@as(?i32, -125), next(-115, floor_mv));
    try std.testing.expectEqual(@as(i32, -80), recommend(-100, -90));
    try std.testing.expectEqual(@as(i32, -30), recommend(-50, -50));
    try std.testing.expectEqual(@as(i32, 0), recommend(-10, -10));
    // nothing failed down to the floor: one step above it; the same for a ladder cut short
    try std.testing.expectEqual(@as(i32, -115), recommend(null, floor_mv));
    try std.testing.expectEqual(@as(i32, -80), recommend(null, -90));
    try std.testing.expectEqual(@as(u32, 300), hotSeconds(420));
    try std.testing.expectEqual(@as(u32, 8), hotSeconds(12));
}

test "a machine check is told from the thermal notes the same subsystem logs" {
    try std.testing.expect(isMachineCheck("4,1,2,-;mce: [Hardware Error]: CPU 2: Machine Check: 0 Bank 1: b200000000000000"));
    try std.testing.expect(isMachineCheck("6,2,3,-;mce: [Hardware Error]: Machine check events logged"));
    try std.testing.expect(isMachineCheck("Some CPU: MACHINE CHECK exception"));
    try std.testing.expect(!isMachineCheck("4,3,4,-;CPU0: Core temperature above threshold, cpu clock throttled (total events = 1)"));
    try std.testing.expect(!isMachineCheck("mce: CPU0: Package temperature/speed normal"));
    try std.testing.expect(!isMachineCheck(""));
}

test "a step's state and a search's result go to disk and come back" {
    var buf: [256]u8 = undefined;
    const s = State{ .step = -100, .good = -90, .from = -50, .to = -125, .seconds = 420 };
    const back = State.parse(s.format(&buf)).?;
    try std.testing.expectEqual(@as(i32, -100), back.step);
    try std.testing.expectEqual(@as(?i32, -90), back.good);
    try std.testing.expectEqual(@as(i32, -125), back.to);
    try std.testing.expectEqual(@as(u32, 420), back.seconds);
    try std.testing.expect(State.parse("step 40\n") == null);
    try std.testing.expect(State.parse("garbage") == null);
    const first = State.parse("step -50\nfrom -50\nto -125\nseconds 12\n").?;
    try std.testing.expect(first.good == null);

    const f = Found{ .mv = -80, .good = -90, .bad = -100, .why = .crash, .seconds = 420, .when = 1762740000 };
    const again = Found.parse(f.format(&buf)).?;
    try std.testing.expectEqual(@as(i32, -80), again.mv);
    try std.testing.expectEqual(@as(?i32, -100), again.bad);
    try std.testing.expectEqual(Why.crash, again.why);
    try std.testing.expectEqual(@as(i64, 1762740000), again.when);
    try std.testing.expect(Found.parse("mv -80\nwhy nonsense\n") == null);
    try std.testing.expect(Found.parse("why floor\n") == null);
    try std.testing.expectEqual(Why.wrong_answer, Why.parse("wrong-answer").?);
}
