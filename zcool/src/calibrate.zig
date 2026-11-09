// SPDX-License-Identifier: GPL-3.0-or-later

//! `zcool calibrate`: a few minutes of measured work, so that zcool knows its machine before the
//! heat comes instead of finding out while it does.
//!
//! It loads the CPU itself, on one core, on half of them and on all, and measures:
//!
//! - what each fan speed carries at the limit: so the fans go straight to the speed a heat
//!   needs, and power starts where the cooler holds it;
//! - how fast the CPU runs at each power: so quiet mode knows how much power costs little
//!   speed, and gives that up before the fans get loud;
//! - which fans turn, and whether they follow zcool's curve at all.
//!
//! What is here makes no system calls but the load's, so it can be tested against a model.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

/// The ambient zcool assumes everywhere: control.Learned uses the same.
pub const ambient: f32 = 30;

pub const FanPoint = struct { name: []const u8, duty: f32, boost: bool };

/// Cooler Boost first, so the heat builds up from the top; then down the curve.
pub const fan_points = [_]FanPoint{
    .{ .name = "boost", .duty = 255, .boost = true },
    .{ .name = "100%", .duty = 253, .boost = false },
    .{ .name = "80%", .duty = 204, .boost = false },
    .{ .name = "60%", .duty = 153, .boost = false },
};

/// Of the power the CPU draws on every core with nothing holding it back.
pub const power_points = [_]f32{ 0.3, 0.4, 0.5, 0.6, 0.7, 0.85, 1.0 };

/// One core, half of them, all of them.
pub const core_points = 3;

pub const Measured = struct { watts: f32 = 0, mhz: f32 = 0 };

pub const Result = struct {
    /// the limit the fans were measured at
    limit: f32 = 0,
    /// what each fan point carries at `limit`, in watts; 0 where it was not measured
    carries: [fan_points.len]f32 = @splat(0),
    rpm: [fan_points.len][2]u32 = @splat(.{ 0, 0 }),
    power: [power_points.len]Measured = @splat(.{}),
    cores: [core_points]Measured = @splat(.{}),
    core_counts: [core_points]u16 = @splat(0),

    pub fn known(self: *const Result) bool {
        return self.limit > ambient + 5 and self.carries[0] + self.carries[1] > 0;
    }

    /// Fans that turned at full: the EC keeps two curves on a laptop that has one fan.
    pub fn fansTurning(self: *const Result) u8 {
        var n: u8 = 0;
        for (0..2) |i| {
            if (self.rpm[0][i] > 0 or self.rpm[1][i] > 0) n += 1;
        }
        return n;
    }

    /// The fans follow zcool's curve: 60% turns them clearly slower than 100%. When they do
    /// not, the EC ignores the curve, and Cooler Boost is all that moves them.
    pub fn curveFollowed(self: *const Result) ?bool {
        const full = self.rpm[1][0];
        const low = self.rpm[3][0];
        if (full == 0 or low == 0) return null;
        return @as(f32, @floatFromInt(low)) < @as(f32, @floatFromInt(full)) * 0.85;
    }

    /// What Cooler Boost carries over the curve at full, as a share: 0.02 is 2% more. Null when
    /// either was not measured.
    pub fn boostGain(self: *const Result) ?f32 {
        if (self.carries[0] <= 0 or self.carries[1] <= 0) return null;
        return self.carries[0] / self.carries[1] - 1;
    }

    /// Cooler Boost earns its noise: 5% more than full speed or better. On the GF63 it carried
    /// 2% more, at 7029 rpm against 5901.
    pub fn boostWorth(self: *const Result) bool {
        const gain = self.boostGain() orelse return true;
        return gain >= 0.05;
    }

    /// The duty the fans need to carry `watts` at `temp`, from what each speed carried: null
    /// below what 60% carries, where nothing was measured and the fans find it themselves.
    pub fn fanDuty(self: *const Result, watts: f32, temp: f32) ?f32 {
        if (!self.known() or temp <= ambient + 5) return null;
        const scale = (temp - ambient) / (self.limit - ambient);
        // from the slowest point up: 60%, 80%, 100%
        var prev_duty: f32 = 0;
        var prev_carry: f32 = 0;
        var i: usize = fan_points.len;
        while (i > 1) {
            i -= 1;
            const carry = self.carries[i] * scale;
            if (carry <= 0) continue;
            if (watts <= carry) {
                if (prev_carry == 0) return null;
                return prev_duty + (fan_points[i].duty - prev_duty) * (watts - prev_carry) / (carry - prev_carry);
            }
            prev_duty = fan_points[i].duty;
            prev_carry = carry;
        }
        return 255;
    }

    /// The share of its full power at which the CPU still has 95% of its speed: quiet mode may
    /// give up that much before the fans get louder. Null when too little was measured.
    pub fn quietFloor(self: *const Result) ?f32 {
        var full: Measured = .{};
        for (self.power) |p| {
            if (p.watts > full.watts) full = p;
        }
        if (full.watts <= 0 or full.mhz <= 0) return null;
        var floor: f32 = 1;
        for (self.power) |p| {
            if (p.watts <= 0 or p.mhz < full.mhz * 0.95) continue;
            floor = @min(floor, p.watts / full.watts);
        }
        return std.math.clamp(floor, 0.6, 0.95);
    }
};

/// Whether a reading has settled: it moved less than `tolerance` of itself over the last
/// `window_ticks` readings.
pub const Settle = struct {
    values: [40]f32 = undefined,
    n: usize = 0,
    at: usize = 0,

    pub fn add(self: *Settle, value: f32) void {
        self.values[self.at] = value;
        self.at = (self.at + 1) % self.values.len;
        self.n = @min(self.n + 1, self.values.len);
    }

    pub fn reset(self: *Settle) void {
        self.n = 0;
        self.at = 0;
    }

    pub fn mean(self: *const Settle) f32 {
        if (self.n == 0) return 0;
        var sum: f32 = 0;
        for (self.values[0..self.n]) |v| sum += v;
        return sum / @as(f32, @floatFromInt(self.n));
    }

    pub fn steady(self: *const Settle, tolerance: f32) bool {
        if (self.n < self.values.len) return false;
        var low = self.values[0];
        var high = low;
        for (self.values) |v| {
            low = @min(low, v);
            high = @max(high, v);
        }
        return high - low <= tolerance * @max(@abs(self.mean()), 1);
    }
};

// ---------------------------------------------------------------- on disk

/// `limit 70`, then `fans boost 31.2 4500 0`, `power 13.5 1600`, `cores 1 21.0 4300` lines.
pub fn format(r: *const Result, buf: []u8) []const u8 {
    var n: usize = 0;
    n += (std.fmt.bufPrint(buf[n..], "limit {d:.0}\n", .{r.limit}) catch return buf[0..n]).len;
    for (fan_points, 0..) |p, i| {
        if (r.carries[i] <= 0) continue;
        n += (std.fmt.bufPrint(buf[n..], "fans {s} {d:.1} {d} {d}\n", .{ p.name, r.carries[i], r.rpm[i][0], r.rpm[i][1] }) catch return buf[0..n]).len;
    }
    for (r.power) |p| {
        if (p.watts <= 0) continue;
        n += (std.fmt.bufPrint(buf[n..], "power {d:.1} {d:.0}\n", .{ p.watts, p.mhz }) catch return buf[0..n]).len;
    }
    for (r.cores, r.core_counts) |p, count| {
        if (p.watts <= 0) continue;
        n += (std.fmt.bufPrint(buf[n..], "cores {d} {d:.1} {d:.0}\n", .{ count, p.watts, p.mhz }) catch return buf[0..n]).len;
    }
    return buf[0..n];
}

pub fn parse(text: []const u8) Result {
    var r = Result{};
    var powers: usize = 0;
    var cores: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const key = f.next() orelse continue;
        if (std.mem.eql(u8, key, "limit")) {
            r.limit = tenths(f.next() orelse continue) orelse 0;
        } else if (std.mem.eql(u8, key, "fans")) {
            const name = f.next() orelse continue;
            for (fan_points, 0..) |p, i| {
                if (!std.mem.eql(u8, p.name, name)) continue;
                r.carries[i] = tenths(f.next() orelse break) orelse 0;
                r.rpm[i][0] = std.fmt.parseInt(u32, f.next() orelse "0", 10) catch 0;
                r.rpm[i][1] = std.fmt.parseInt(u32, f.next() orelse "0", 10) catch 0;
            }
        } else if (std.mem.eql(u8, key, "power") and powers < r.power.len) {
            r.power[powers] = .{ .watts = tenths(f.next() orelse continue) orelse 0, .mhz = tenths(f.next() orelse continue) orelse 0 };
            powers += 1;
        } else if (std.mem.eql(u8, key, "cores") and cores < r.cores.len) {
            r.core_counts[cores] = std.fmt.parseInt(u16, f.next() orelse continue, 10) catch continue;
            r.cores[cores] = .{ .watts = tenths(f.next() orelse continue) orelse 0, .mhz = tenths(f.next() orelse continue) orelse 0 };
            cores += 1;
        }
    }
    // anything that makes no sense is not trusted at all
    if (r.limit < 35 or r.limit > 130) return .{};
    for (r.carries) |c| if (c < 0 or c > 2000) return .{};
    return r;
}

/// "31.5" or "90": a number with at most one decimal. Far smaller than the standard float
/// parser, which would double the binary.
pub fn tenths(text: []const u8) ?f32 {
    const dot = std.mem.indexOfScalar(u8, text, '.');
    const whole = std.fmt.parseInt(u32, text[0 .. dot orelse text.len], 10) catch return null;
    var tenth: u32 = 0;
    if (dot) |d| {
        if (d + 2 != text.len or text[d + 1] < '0' or text[d + 1] > '9') return null;
        tenth = text[d + 1] - '0';
    }
    return @as(f32, @floatFromInt(whole)) + @as(f32, @floatFromInt(tenth)) / 10;
}

// ---------------------------------------------------------------- the load

pub const max_workers = 256;

/// Busy processes, one per core it loads. Each dies with zcool, however zcool ends.
pub const Load = struct {
    pids: [max_workers]i32 = undefined,
    n: usize = 0,

    pub fn set(self: *Load, want: usize) void {
        while (self.n > want) {
            self.n -= 1;
            sys.kill(self.pids[self.n], .KILL);
            _ = sys.reap(self.pids[self.n], 1000);
        }
        while (self.n < @min(want, max_workers)) {
            const pid = sys.forkWorker(self.n) orelse return;
            self.pids[self.n] = pid;
            self.n += 1;
        }
    }

    pub fn stop(self: *Load) void {
        self.set(0);
    }
};

test "what each fan speed carries tells the duty a heat needs" {
    var r = Result{ .limit = 70 };
    // boost, 100%, 80%, 60%
    r.carries = .{ 42, 41.8, 37.6, 33.1 };
    try std.testing.expect(r.known());
    try std.testing.expect(r.fanDuty(30, 70) == null);
    try std.testing.expect(r.fanDuty(33.1, 70) == null);
    try std.testing.expectApproxEqAbs(@as(f32, 154.1), r.fanDuty(33.2, 70).?, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 178.5), r.fanDuty(35.35, 70).?, 0.5);
    try std.testing.expectEqual(@as(f32, 255), r.fanDuty(45, 70).?);
    // at a lower temperature every speed carries less, in proportion to the rise over ambient
    const lower = r.fanDuty(33.1, 68).?;
    try std.testing.expect(lower > 153);
}

test "quiet mode gives up the power that costs least speed" {
    var r = Result{};
    // 95% of 3000 MHz is 2850, reached at 32 W of 45
    const points = [_]Measured{ .{ .watts = 13, .mhz = 1600 }, .{ .watts = 20, .mhz = 2300 }, .{ .watts = 26, .mhz = 2700 }, .{ .watts = 32, .mhz = 2860 }, .{ .watts = 38, .mhz = 2950 }, .{ .watts = 42, .mhz = 2990 }, .{ .watts = 45, .mhz = 3000 } };
    r.power = points;
    try std.testing.expectApproxEqAbs(@as(f32, 32.0 / 45.0), r.quietFloor().?, 0.001);
    r.power = @splat(.{});
    try std.testing.expect(r.quietFloor() == null);
}

test "one fan, and a curve the fans follow or not" {
    var r = Result{ .limit = 70 };
    r.rpm = .{ .{ 6900, 0 }, .{ 6500, 0 }, .{ 5200, 0 }, .{ 3900, 0 } };
    try std.testing.expectEqual(@as(u8, 1), r.fansTurning());
    try std.testing.expect(r.curveFollowed().?);
    r.rpm[3][0] = 6400;
    try std.testing.expect(!r.curveFollowed().?);
}

test "a calibration goes to disk and comes back" {
    var r = Result{ .limit = 70 };
    r.carries = .{ 42, 41.8, 37.6, 33.1 };
    r.rpm = .{ .{ 6900, 0 }, .{ 6500, 0 }, .{ 5200, 0 }, .{ 3900, 0 } };
    r.power[0] = .{ .watts = 13.5, .mhz = 1600 };
    r.power[1] = .{ .watts = 45, .mhz = 3000 };
    r.cores[0] = .{ .watts = 21, .mhz = 4300 };
    r.core_counts[0] = 1;
    var buf: [1024]u8 = undefined;
    const text = format(&r, &buf);
    const back = parse(text);
    try std.testing.expectEqual(@as(f32, 70), back.limit);
    try std.testing.expectEqual(@as(f32, 37.6), back.carries[2]);
    try std.testing.expectEqual(@as(u32, 3900), back.rpm[3][0]);
    try std.testing.expectEqual(@as(f32, 3000), back.power[1].mhz);
    try std.testing.expectEqual(@as(u16, 1), back.core_counts[0]);
    // nonsense is not trusted
    try std.testing.expect(!parse("limit 7000\nfans boost 31.2 1 0\n").known());
    try std.testing.expect(!parse("garbage").known());
}

test "a reading settles once it stops moving" {
    var s = Settle{};
    var i: usize = 0;
    while (i < 40) : (i += 1) s.add(30 + @as(f32, @floatFromInt(i)) * 0.1);
    try std.testing.expect(!s.steady(0.05));
    i = 0;
    while (i < 40) : (i += 1) s.add(31 + @as(f32, @floatFromInt(i % 3)) * 0.1);
    try std.testing.expect(s.steady(0.05));
}

test "Cooler Boost earns its noise only where it carries clearly more" {
    var r = Result{ .limit = 70 };
    // the GF63: 29.6 W against 29.0
    r.carries = .{ 29.6, 29.0, 27.6, 25.7 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0207), r.boostGain().?, 0.001);
    try std.testing.expect(!r.boostWorth());
    r.carries[0] = 33;
    try std.testing.expect(r.boostWorth());
    // not measured: it stays as it always was
    r.carries[0] = 0;
    try std.testing.expect(r.boostWorth());
}
