// SPDX-License-Identifier: GPL-3.0-or-later

//! /etc/zcool.conf: `key = value` lines, `#` starts a comment.
//!
//!     cpu0.max = 85          limit for one chip, in degrees C
//!     fan.exclude = nct6798/pwm3
//!     gpu.sleep = no         keep GPUs that do not show the boot screen awake
//!     undervolt.core = -50   millivolts, Intel only, see README
//!     undervolt.cache = -50
//!     battery.max = 80       stop charging at 80%
//!     mode.ac = comfort      an MSI EC's own power profile on mains
//!     mode.battery = eco     and on battery
//!     ec = no                leave an MSI laptop's EC alone

const std = @import("std");
const ec = @import("ec.zig");

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
    gpu_sleep: bool = true,
    /// percent, 0 when not set
    battery_max: u8 = 0,
    mode_ac: ?ec.Profile = null,
    mode_battery: ?ec.Profile = null,
    use_ec: bool = true,
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
    if (std.mem.eql(u8, key, "gpu.sleep")) {
        c.gpu_sleep = yesNo(value) orelse return false;
        return true;
    }
    if (std.mem.eql(u8, key, "ec")) {
        c.use_ec = yesNo(value) orelse return false;
        return true;
    }
    if (std.mem.eql(u8, key, "battery.max")) {
        const percent = std.fmt.parseInt(u8, value, 10) catch return false;
        if (percent < 10 or percent > 100) return false;
        c.battery_max = percent;
        return true;
    }
    if (std.mem.eql(u8, key, "mode.ac") or std.mem.eql(u8, key, "mode.battery")) {
        const mode = std.meta.stringToEnum(ec.Profile, value) orelse return false;
        if (key[5] == 'a') c.mode_ac = mode else c.mode_battery = mode;
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

fn yesNo(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "yes")) return true;
    if (std.mem.eql(u8, value, "no")) return false;
    return null;
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
        \\gpu.sleep = maybe
    );
    try std.testing.expectEqual(@as(f32, 85), c.limitFor("cpu0").?);
    try std.testing.expectEqual(@as(f32, 80), c.limitFor("gpu0").?);
    try std.testing.expect(c.limitFor("nvme0") == null);
    try std.testing.expect(c.isExcluded("nct6798/pwm3"));
    try std.testing.expect(!c.isExcluded("nct6798/pwm2"));
    try std.testing.expectEqual(@as(i32, -50), c.undervolt_core);
    try std.testing.expectEqual(@as(i32, -40), c.undervolt_cache);
    try std.testing.expectEqual(@as(u32, 5), c.bad_lines);
    try std.testing.expect(c.gpu_sleep);
    try std.testing.expect(!parse("gpu.sleep = no").gpu_sleep);
}

test "the battery, the EC and its modes" {
    const c = parse(
        \\battery.max = 80
        \\mode.ac = sport
        \\mode.battery = eco
        \\ec = no
        \\battery.max = 5
        \\mode.ac = fast
    );
    try std.testing.expectEqual(@as(u8, 80), c.battery_max);
    try std.testing.expectEqual(ec.Profile.sport, c.mode_ac.?);
    try std.testing.expectEqual(ec.Profile.eco, c.mode_battery.?);
    try std.testing.expect(!c.use_ec);
    try std.testing.expectEqual(@as(u32, 2), c.bad_lines);
    const d = parse("");
    try std.testing.expectEqual(@as(u8, 0), d.battery_max);
    try std.testing.expect(d.mode_ac == null and d.use_ec);
}
