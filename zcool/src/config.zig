// SPDX-License-Identifier: GPL-3.0-or-later

//! /etc/zcool.conf: `key = value` lines, `#` starts a comment.
//!
//!     cpu0.max = 85          limit for one chip, in degrees C
//!     fan.exclude = nct6798/pwm3
//!     undervolt.core = -50   millivolts, Intel only, see README
//!     undervolt.cache = -50

const std = @import("std");

pub const max_limits = 16;
pub const max_excludes = 16;

pub const Limit = struct { id: [24]u8 = undefined, len: usize = 0, value: f32 = 0 };
pub const Exclude = struct { id: [40]u8 = undefined, len: usize = 0 };

pub const Config = struct {
    limits: [max_limits]Limit = undefined,
    nlimits: usize = 0,
    excludes: [max_excludes]Exclude = undefined,
    nexcludes: usize = 0,
    undervolt_core: i32 = 0,
    undervolt_cache: i32 = 0,
    bad_lines: u32 = 0,

    pub fn limitFor(self: *const Config, id: []const u8) ?f32 {
        for (self.limits[0..self.nlimits]) |*l| {
            if (std.mem.eql(u8, l.id[0..l.len], id)) return l.value;
        }
        return null;
    }

    pub fn isExcluded(self: *const Config, id: []const u8) bool {
        for (self.excludes[0..self.nexcludes]) |*e| {
            if (std.mem.eql(u8, e.id[0..e.len], id)) return true;
        }
        return false;
    }
};

/// A line that makes no sense is counted and skipped: a typo must not stop the cooling.
pub fn parse(text: []const u8) Config {
    var c = Config{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const hash = std.mem.indexOfScalar(u8, raw, '#') orelse raw.len;
        const line = std.mem.trim(u8, raw[0..hash], " \t\r");
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            c.bad_lines += 1;
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (!apply(&c, key, value)) c.bad_lines += 1;
    }
    return c;
}

fn apply(c: *Config, key: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, key, "fan.exclude")) {
        if (c.nexcludes == max_excludes or value.len == 0 or value.len > 40) return false;
        const e = &c.excludes[c.nexcludes];
        @memcpy(e.id[0..value.len], value);
        e.len = value.len;
        c.nexcludes += 1;
        return true;
    }
    if (std.mem.eql(u8, key, "undervolt.core") or std.mem.eql(u8, key, "undervolt.cache")) {
        const mv = std.fmt.parseInt(i32, value, 10) catch return false;
        if (mv > 0) return false; // this tool only ever lowers a voltage
        if (key[10] == 'c' and key[11] == 'o') c.undervolt_core = mv else c.undervolt_cache = mv;
        return true;
    }
    if (std.mem.endsWith(u8, key, ".max")) {
        const id = key[0 .. key.len - 4];
        if (id.len == 0 or id.len > 24 or c.nlimits == max_limits) return false;
        const degrees = std.fmt.parseInt(i32, value, 10) catch return false;
        if (degrees < 1 or degrees > 200) return false;
        const l = &c.limits[c.nlimits];
        @memcpy(l.id[0..id.len], id);
        l.len = id.len;
        l.value = @floatFromInt(degrees);
        c.nlimits += 1;
        return true;
    }
    return false;
}

test "parses limits, excludes and undervolt, and counts what it cannot read" {
    const c = parse(
        \\# comment
        \\cpu0.max = 85
        \\  gpu0.max=80   # trailing comment
        \\fan.exclude = nct6798/pwm3
        \\undervolt.core = -50
        \\undervolt.cache = -40
        \\nonsense
        \\cpu1.max = hot
        \\undervolt.core = 50
        \\unknown = 1
    );
    try std.testing.expectEqual(@as(f32, 85), c.limitFor("cpu0").?);
    try std.testing.expectEqual(@as(f32, 80), c.limitFor("gpu0").?);
    try std.testing.expect(c.limitFor("nvme0") == null);
    try std.testing.expect(c.isExcluded("nct6798/pwm3"));
    try std.testing.expect(!c.isExcluded("nct6798/pwm2"));
    try std.testing.expectEqual(@as(i32, -50), c.undervolt_core);
    try std.testing.expectEqual(@as(i32, -40), c.undervolt_cache);
    try std.testing.expectEqual(@as(u32, 4), c.bad_lines);
}
