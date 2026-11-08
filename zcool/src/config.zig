// SPDX-License-Identifier: GPL-3.0-or-later

//! /etc/zcool.conf: `key = value` lines, `#` starts a comment.
//!
//!     cpu0.max = 85          limit for one chip, in degrees C
//!     fan.exclude = nct6798/pwm3
//!     gpu.sleep = no         keep GPUs that do not show the boot screen awake
//!     undervolt.core = -50   millivolts, Intel only, see README
//!     undervolt.cache = -50
//!     battery.max = 80       stop charging at 80%
//!     learn = no             do not learn what the cooler carries
//!     fan.silent = no        keep an MSI EC's normal fan curve when cool
//!     fan.curve = no         an MSI EC's fans: only Cooler Boost, never zcool's curve
//!     guard.cpu = no         jobs keep their CPU share under pressure
//!     guard.memory = no      never end a process that starves memory
//!     tcc = no               leave the CPU's own throttle at TjMax
//!     ec = no                leave an MSI laptop's EC alone
//!
//! And per power source, with `.ac` or `.battery` after the name:
//!
//!     epp.battery = balance_power   the CPU's energy preference
//!     turbo.battery = no
//!     noise.battery = quiet         a little power before loud fans
//!     limits.battery = -10          every limit 10 C lower
//!     mode.battery = eco            an MSI EC's own power profile

const std = @import("std");
const ec = @import("ec.zig");

pub const max_limits = 16;
pub const max_excludes = 16;

pub const Limit = struct { id: [24]u8 = undefined, len: usize = 0, value: f32 = 0 };
pub const Exclude = struct { id: [40]u8 = undefined, len: usize = 0 };

/// The CPU's energy preference (intel_pstate and amd-pstate): how readily it climbs to high clocks.
pub const Epp = enum { default, performance, balance_performance, balance_power, power };

/// The most a source may lower every limit, in degrees.
pub const max_shift = 30;

/// What changes with the power source. Left out, the firmware's own stays.
pub const Source = struct {
    epp: ?Epp = null,
    turbo: ?bool = null,
    /// gives up a little power before pushing the fans past the firmware's curve
    quiet: bool = false,
    /// every limit moves by this many degrees, 0 or lower
    shift: i8 = 0,
    /// an MSI EC's own power profile
    mode: ?ec.Profile = null,

    pub fn any(self: *const Source) bool {
        return self.epp != null or self.turbo != null or self.quiet or self.shift != 0 or self.mode != null;
    }
};

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
    ac: Source = .{},
    battery: Source = .{},
    use_ec: bool = true,
    learn: bool = true,
    /// an MSI EC's silent fan curve while every chip is cool
    fan_silent: bool = true,
    /// an MSI EC's fans at the speed zcool sets, through a curve of its own
    fan_curve: bool = true,
    /// jobs yield the CPU to the desktop under pressure
    guard_cpu: bool = true,
    /// a memory hog is ended before the system stalls
    guard_memory: bool = true,
    /// Intel: the CPU's own throttle just above the limit
    tcc: bool = true,
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

    pub fn source(self: *const Config, mains: bool) *const Source {
        return if (mains) &self.ac else &self.battery;
    }
};

/// A line that makes no sense is counted and skipped: a typo must not stop the cooling.
pub fn parse(text: []const u8) Config {
    var c = Config{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const kv = keyValue(raw) orelse {
            if (std.mem.trim(u8, stripComment(raw), " \t\r").len > 0) c.bad_lines += 1;
            continue;
        };
        if (!apply(&c, kv.key, kv.value)) c.bad_lines += 1;
    }
    return c;
}

fn stripComment(raw: []const u8) []const u8 {
    return raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len];
}

const KeyValue = struct { key: []const u8, value: []const u8 };

fn keyValue(raw: []const u8) ?KeyValue {
    const line = std.mem.trim(u8, stripComment(raw), " \t\r");
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    return .{ .key = std.mem.trim(u8, line[0..eq], " \t"), .value = std.mem.trim(u8, line[eq + 1 ..], " \t") };
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
    if (std.mem.eql(u8, key, "learn")) {
        c.learn = yesNo(value) orelse return false;
        return true;
    }
    if (std.mem.eql(u8, key, "fan.silent")) {
        c.fan_silent = yesNo(value) orelse return false;
        return true;
    }
    if (std.mem.eql(u8, key, "fan.curve")) {
        c.fan_curve = yesNo(value) orelse return false;
        return true;
    }
    if (std.mem.eql(u8, key, "guard.cpu")) {
        c.guard_cpu = yesNo(value) orelse return false;
        return true;
    }
    if (std.mem.eql(u8, key, "tcc")) {
        c.tcc = yesNo(value) orelse return false;
        return true;
    }
    if (std.mem.eql(u8, key, "guard.memory")) {
        c.guard_memory = yesNo(value) orelse return false;
        return true;
    }
    if (std.mem.eql(u8, key, "battery.max")) {
        const percent = std.fmt.parseInt(u8, value, 10) catch return false;
        if (percent < 10 or percent > 100) return false;
        c.battery_max = percent;
        return true;
    }
    if (std.mem.eql(u8, key, "undervolt.core") or std.mem.eql(u8, key, "undervolt.cache")) {
        const mv = std.fmt.parseInt(i32, value, 10) catch return false;
        if (mv > 0) return false; // this tool only ever lowers a voltage
        if (key[10] == 'c' and key[11] == 'o') c.undervolt_core = mv else c.undervolt_cache = mv;
        return true;
    }
    if (perSource(c, key)) |p| return applySource(p.source, p.name, value);
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

const PerSource = struct { source: *Source, name: []const u8 };

fn perSource(c: *Config, key: []const u8) ?PerSource {
    if (std.mem.endsWith(u8, key, ".ac")) return .{ .source = &c.ac, .name = key[0 .. key.len - 3] };
    if (std.mem.endsWith(u8, key, ".battery")) return .{ .source = &c.battery, .name = key[0 .. key.len - 8] };
    return null;
}

fn applySource(s: *Source, name: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, name, "epp")) {
        s.epp = std.meta.stringToEnum(Epp, value) orelse return false;
    } else if (std.mem.eql(u8, name, "turbo")) {
        s.turbo = yesNo(value) orelse return false;
    } else if (std.mem.eql(u8, name, "noise")) {
        if (std.mem.eql(u8, value, "quiet")) {
            s.quiet = true;
        } else if (std.mem.eql(u8, value, "normal")) {
            s.quiet = false;
        } else return false;
    } else if (std.mem.eql(u8, name, "limits")) {
        const shift = std.fmt.parseInt(i8, value, 10) catch return false;
        if (shift > 0 or shift < -max_shift) return false;
        s.shift = shift;
    } else if (std.mem.eql(u8, name, "mode")) {
        s.mode = std.meta.stringToEnum(ec.Profile, value) orelse return false;
    } else return false;
    return true;
}

fn yesNo(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "yes")) return true;
    if (std.mem.eql(u8, value, "no")) return false;
    return null;
}

// ---------------------------------------------------------------- writing it back

/// Sets one key in the text of a config file and returns the new text in `out`. The first line
/// that sets the key gets the new value and later ones are commented out; with none, a line
/// commented out by the example config is taken back in, or a new line is added at the end.
/// A null value comments the key out, so the default applies. Everything else stays as it was.
/// With `only`, just the line with that value counts: `fan.exclude` has many.
pub fn set(text: []const u8, key: []const u8, value: ?[]const u8, only: ?[]const u8, out: []u8) ?[]const u8 {
    var live = false;
    var commented: ?usize = null;
    var lines = Lines{ .rest = text };
    var index: usize = 0;
    while (lines.next()) |raw| : (index += 1) {
        if (matches(raw, key, only)) live = true;
        if (commented == null and isCommentedKey(raw, key, only)) commented = index;
    }
    const revive = if (!live and value != null) commented else null;
    var w = Writer{ .out = out };
    var placed = false;
    lines = .{ .rest = text };
    index = 0;
    while (lines.next()) |raw| : (index += 1) {
        if (matches(raw, key, only)) {
            if (value != null and !placed) {
                w.line(key, value.?);
                placed = true;
            } else {
                w.put("# ");
                w.put(raw);
            }
        } else if (revive != null and index == revive.?) {
            w.line(key, value.?);
            placed = true;
        } else {
            w.put(raw);
        }
        w.put("\n");
    }
    if (value != null and !placed) {
        w.line(key, value.?);
        w.put("\n");
    }
    return if (w.overflow) null else out[0..w.len];
}

/// Lines of a text; a final newline does not start another one.
const Lines = struct {
    rest: []const u8,

    fn next(self: *Lines) ?[]const u8 {
        if (self.rest.len == 0) return null;
        const nl = std.mem.indexOfScalar(u8, self.rest, '\n') orelse {
            defer self.rest = self.rest[self.rest.len..];
            return self.rest;
        };
        defer self.rest = self.rest[nl + 1 ..];
        return self.rest[0..nl];
    }
};

fn matches(raw: []const u8, key: []const u8, only: ?[]const u8) bool {
    const kv = keyValue(raw) orelse return false;
    if (!std.mem.eql(u8, kv.key, key)) return false;
    return only == null or std.mem.eql(u8, kv.value, only.?);
}

/// `# key = value` as the example config has it, but not prose that mentions the key.
fn isCommentedKey(raw: []const u8, key: []const u8, only: ?[]const u8) bool {
    const line = std.mem.trimStart(u8, raw, " \t");
    if (line.len == 0 or line[0] != '#') return false;
    const rest = std.mem.trimStart(u8, line[1..], " \t");
    if (!std.mem.startsWith(u8, rest, key)) return false;
    const after = std.mem.trimStart(u8, rest[key.len..], " \t");
    if (after.len == 0 or after[0] != '=') return false;
    if (only) |v| {
        const value = std.mem.trim(u8, stripComment(after[1..]), " \t\r");
        return std.mem.eql(u8, value, v);
    }
    return true;
}

const Writer = struct {
    out: []u8,
    len: usize = 0,
    overflow: bool = false,

    fn put(self: *Writer, s: []const u8) void {
        if (self.len + s.len > self.out.len) {
            self.overflow = true;
            return;
        }
        @memcpy(self.out[self.len..][0..s.len], s);
        self.len += s.len;
    }

    fn line(self: *Writer, key: []const u8, value: []const u8) void {
        self.put(key);
        self.put(" = ");
        self.put(value);
    }
};

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
    try std.testing.expectEqual(ec.Profile.sport, c.ac.mode.?);
    try std.testing.expectEqual(ec.Profile.eco, c.battery.mode.?);
    try std.testing.expect(!c.use_ec);
    try std.testing.expectEqual(@as(u32, 2), c.bad_lines);
    const d = parse("");
    try std.testing.expectEqual(@as(u8, 0), d.battery_max);
    try std.testing.expect(d.ac.mode == null and d.use_ec and d.learn);
    try std.testing.expect(!d.ac.any() and !d.battery.any());
}

test "what changes with the power source" {
    const c = parse(
        \\epp.ac = balance_performance
        \\epp.battery = power
        \\turbo.battery = no
        \\noise.battery = quiet
        \\limits.battery = -10
        \\learn = no
        \\limits.ac = 5
        \\limits.ac = -31
        \\epp.ac = fastest
        \\noise.ac = loud
        \\speed.ac = 1
    );
    try std.testing.expectEqual(Epp.balance_performance, c.ac.epp.?);
    try std.testing.expectEqual(Epp.power, c.battery.epp.?);
    try std.testing.expect(c.battery.turbo.? == false and c.ac.turbo == null);
    try std.testing.expect(c.battery.quiet and !c.ac.quiet);
    try std.testing.expectEqual(@as(i8, -10), c.battery.shift);
    try std.testing.expectEqual(@as(i8, 0), c.ac.shift);
    try std.testing.expect(!c.learn);
    try std.testing.expectEqual(@as(u32, 5), c.bad_lines);
    const g = parse("fan.silent = no\nguard.cpu = no\nguard.memory = no\ntcc = no\nfan.curve = no\n");
    try std.testing.expect(!g.fan_silent and !g.guard_cpu and !g.guard_memory and !g.tcc and !g.fan_curve and g.bad_lines == 0);
    try std.testing.expect(c.fan_silent and c.guard_cpu and c.guard_memory and c.fan_curve);
    try std.testing.expect(c.ac.any() and c.battery.any());
    try std.testing.expect(c.source(false) == &c.battery);
}

test "set replaces a line, takes back a commented one, or adds one" {
    var out: [512]u8 = undefined;
    const example =
        \\# The most each chip may reach.
        \\# cpu0.max = 85
        \\gpu0.max = 80 # mine
        \\
    ;
    try std.testing.expectEqualStrings(
        \\# The most each chip may reach.
        \\cpu0.max = 75
        \\gpu0.max = 80 # mine
        \\
    , set(example, "cpu0.max", "75", null, &out).?);
    try std.testing.expectEqualStrings(
        \\# The most each chip may reach.
        \\# cpu0.max = 85
        \\gpu0.max = 70
        \\
    , set(example, "gpu0.max", "70", null, &out).?);
    try std.testing.expectEqualStrings(
        \\# The most each chip may reach.
        \\# cpu0.max = 85
        \\# gpu0.max = 80 # mine
        \\
    , set(example, "gpu0.max", null, null, &out).?);
    try std.testing.expectEqualStrings(
        \\# The most each chip may reach.
        \\# cpu0.max = 85
        \\gpu0.max = 80 # mine
        \\turbo.battery = no
        \\
    , set(example, "turbo.battery", "no", null, &out).?);
    try std.testing.expectEqualStrings("learn = no\n", set("", "learn", "no", null, &out).?);
    try std.testing.expectEqualStrings("a = 1\nlearn = no\n", set("a = 1", "learn", "no", null, &out).?);
    // a second live line for the same key would win when read, so it goes
    try std.testing.expectEqualStrings("epp.ac = power\n# epp.ac = default\n", set("epp.ac = performance\nepp.ac = default\n", "epp.ac", "power", null, &out).?);
    // prose that names a key is not a commented-out setting
    try std.testing.expectEqualStrings("# learn is on by default\nlearn = no\n", set("# learn is on by default\n", "learn", "no", null, &out).?);
    try std.testing.expect(set("cpu0.max = 85\n", "cpu0.max", "75", null, out[0..4]) == null);
}

test "set handles one of many fan.exclude lines" {
    var out: [512]u8 = undefined;
    const text = "fan.exclude = a/pwm1\nfan.exclude = b/pwm2\n";
    try std.testing.expectEqualStrings("fan.exclude = a/pwm1\n# fan.exclude = b/pwm2\n", set(text, "fan.exclude", null, "b/pwm2", &out).?);
    try std.testing.expectEqualStrings(text, set(text, "fan.exclude", "b/pwm2", "b/pwm2", &out).?);
    try std.testing.expectEqualStrings(text ++ "fan.exclude = c/pwm3\n", set(text, "fan.exclude", "c/pwm3", "c/pwm3", &out).?);
    const c = parse(set(text, "fan.exclude", null, "a/pwm1", &out).?);
    try std.testing.expect(!c.isExcluded("a/pwm1") and c.isExcluded("b/pwm2"));
}
