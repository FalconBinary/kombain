// SPDX-License-Identifier: GPL-3.0-or-later

//! The machine's heat as a model, so that zcool knows where the temperature goes instead of
//! extrapolating where it was going.
//!
//! A CPU's die sits above its heat sink by `r_die` degrees per watt, at once: that is the jump
//! a sensor shows the moment power changes. The sink has a thermal mass and warms toward
//! `ambient + watts / g(fan)`, where `g(fan)` is what the cooler carries per degree over the
//! room at each fan speed. Three numbers and a curve, learned by `zcool calibrate --long` from
//! step responses, refined while zcool runs, kept in /var/lib/zcool/model.
//!
//! What it buys: a burst from a cold machine may run at the firmware's full short-term limit
//! (the die has 30 C to spend), the same burst from a warm one is held to what the sink can
//! absorb before the die reaches the limit; the fans are told where a load is going before it
//! gets there; a short load is told apart from a long one by where the temperature will be,
//! not by guessing how long it lasts.

const std = @import("std");

/// The fan points of the calibration, as duties: Cooler Boost, 100%, 80%, 60%.
pub const point_duty = [_]f32{ 255, 253, 204, 153 };

/// With a model the fans are told where the die will be this far ahead: the time a fan takes
/// to spin up. The slope's forecast needs twice that, since it cannot know where a climb bends.
pub const fan_horizon: f32 = 2;

/// The sink's temperature, followed through the model and corrected by what the die shows.
/// The die's reading jumps the moment power does, while the power's own reading is an average
/// over the last half second: taken at face value the two put the sink ten degrees off for a
/// moment at every step. The observer moves the sink by the model's own account and lets the
/// reading pull it slowly.
pub const Observer = struct {
    sink: f32 = 0,
    ready: bool = false,

    pub fn update(self: *Observer, m: *const Model, die: f32, watts: f32, duty: f32, dt: f32) f32 {
        const measured = m.sink(die, watts);
        if (!self.ready) {
            self.sink = measured;
            self.ready = true;
            return self.sink;
        }
        if (dt > 0) {
            const g = m.conductance(duty);
            self.sink += (watts - g * (self.sink - m.ambient)) * dt / m.mass;
            self.sink += (measured - self.sink) * dt / (dt + 3);
        }
        return self.sink;
    }
};

pub const Model = struct {
    /// degrees the die sits above the sink, per watt
    r_die: f32 = 0,
    ambient: f32 = 30,
    /// the sink's thermal mass, joules per degree
    mass: f32 = 0,
    /// what the cooler carries per degree over ambient at each fan point, watts per degree
    g: [point_duty.len]f32 = @splat(0),

    pub fn known(self: *const Model) bool {
        if (self.r_die <= 0 or self.mass <= 0) return false;
        var points: u8 = 0;
        for (self.g) |v| {
            if (v > 0) points += 1;
        }
        return points >= 2;
    }

    /// What the cooler carries per degree at `duty`: between the fan points by duty, and below
    /// the slowest point in proportion to the duty, down to a quarter of it for a fan that stands.
    pub fn conductance(self: *const Model, duty: f32) f32 {
        var hi: ?usize = null;
        var lo: ?usize = null;
        for (self.g, 0..) |v, i| {
            if (v <= 0) continue;
            if (point_duty[i] >= duty and (hi == null or point_duty[i] < point_duty[hi.?])) hi = i;
            if (point_duty[i] <= duty and (lo == null or point_duty[i] > point_duty[lo.?])) lo = i;
        }
        if (hi != null and lo != null) {
            if (hi.? == lo.?) return self.g[hi.?];
            const span = point_duty[hi.?] - point_duty[lo.?];
            return self.g[lo.?] + (self.g[hi.?] - self.g[lo.?]) * (duty - point_duty[lo.?]) / span;
        }
        if (hi) |h| {
            // below the slowest known point: still air carries a quarter of what the slowest fan does
            const slow = point_duty[h];
            return self.g[h] * (0.25 + 0.75 * @max(duty, 0) / slow);
        }
        return self.g[lo.?];
    }

    /// The sink's temperature behind a die reading at `watts`.
    pub fn sink(self: *const Model, die: f32, watts: f32) f32 {
        return die - self.r_die * watts;
    }

    /// Where the die will be after `seconds` at `watts` with the fans at `duty`, from a sink at `sink_now`.
    pub fn forecast(self: *const Model, sink_now: f32, watts: f32, duty: f32, seconds: f32) f32 {
        const g = self.conductance(duty);
        const tau = self.mass / g;
        const eq = self.ambient + watts / g;
        const e = @exp(-seconds / tau);
        return eq + (sink_now - eq) * e + self.r_die * watts;
    }

    /// The most the CPU may draw from now on and keep the die under `limit` for `seconds`, with
    /// the fans at `duty` and the sink at `sink_now`. The forecast is linear in the watts:
    /// die = A + watts * (r_die + (1 - e) / g).
    pub fn burst(self: *const Model, sink_now: f32, duty: f32, limit: f32, seconds: f32) f32 {
        const g = self.conductance(duty);
        const e = @exp(-seconds / (self.mass / g));
        const a = self.ambient * (1 - e) + sink_now * e;
        return @max((limit - a) / (self.r_die + (1 - e) / g), 0);
    }

    /// The power the cooler holds the die at `limit` with, for good, with the fans at `duty`.
    pub fn holds(self: *const Model, duty: f32, limit: f32) f32 {
        const g = self.conductance(duty);
        return @max((limit - self.ambient) / (1 / g + self.r_die), 0);
    }

    /// Why this is no model of the machine, or null when it may be one. Two things a fit has to
    /// agree with: a faster fan carries more per degree than a slower one (a tenth of noise
    /// allowed), and what it says the fans at full hold at the limit is within 15% of what the
    /// calibration measured them holding minutes before. The GF63's first long calibration failed
    /// both: steady states taken too early put 80% over 100%, and a room read off a sink still
    /// warm put 24 W against the 30 measured.
    pub fn complaint(self: *const Model, carries_full: f32, limit: f32) ?[]const u8 {
        var faster: f32 = 0;
        for (self.g) |v| {
            if (v <= 0) continue;
            if (faster > 0 and v > faster * 1.1) return "a slower fan carries more per degree than a faster one: the steady states were not steady";
            faster = v;
        }
        if (carries_full > 0) {
            const held = self.holds(253, limit);
            if (@abs(held - carries_full) > 0.15 * carries_full) return "what it holds at the limit with the fans at full is not what they carried";
        }
        return null;
    }

    /// The die moved by `d_die` as the power moved by `d_watts` within a moment: that is r_die,
    /// learned slowly, from steps big enough for a sensor that counts whole degrees.
    pub fn learnJump(self: *const Model, d_die: f32, d_watts: f32) ?f32 {
        if (@abs(d_watts) < 25) return null;
        const sample = d_die / d_watts;
        if (sample < 0.02 or sample > 0.6) return null;
        return std.math.clamp(self.r_die + (sample - self.r_die) * 0.2, 0.02, 0.6);
    }

    /// Steady at `die` and `watts` with the fans at `duty`, for a while: what the cooler carries
    /// per degree at the nearest fan point, learned slowly. The other points move with it: dust
    /// slows one cooler at every speed alike, so what one speed teaches is the cooler's level and
    /// the calibration's shape stays. Null when `duty` is near no point.
    pub fn learnSteady(self: *Model, die: f32, watts: f32, duty: f32) ?usize {
        if (watts < 8) return null;
        var nearest: ?usize = null;
        for (point_duty, 0..) |d, i| {
            if (@abs(d - duty) > 20) continue;
            if (nearest == null or @abs(d - duty) < @abs(point_duty[nearest.?] - duty)) nearest = i;
        }
        const i = nearest orelse return null;
        const over = self.sink(die, watts) - self.ambient;
        if (over < 5) return null;
        const sample = std.math.clamp(watts / over, 0.05, 20);
        if (self.g[i] <= 0) {
            self.g[i] = sample;
            return i;
        }
        const was = self.g[i];
        self.g[i] += (sample - was) * 0.25;
        for (&self.g, 0..) |*g, j| {
            if (j != i and g.* > 0) g.* = std.math.clamp(g.* * self.g[i] / was, 0.05, 20);
        }
        return i;
    }
};

/// A jump of the die seen as zcool runs. The die answers its power within a tick; the power
/// reading is an average over half a second and shows the step whole only a tick or two later.
/// So the step is seen on the die, its size taken from that tick less half a tick of the sink's
/// new climb (the next tick shows the climb), and the power is read again three quarters of a
/// second on, when a whole sample of the new power is in.
pub const Jump = struct {
    d_die: f32 = 0,
    dt: f32 = 0,
    die_at: f32 = 0,
    watts_before: f32 = 0,
    age: f32 = 0,
    /// 0 nothing, 1 the die jumped this tick, 2 the climb after it is known
    state: u8 = 0,

    pub const Sample = struct { d_die: f32, d_watts: f32 };

    pub fn update(self: *Jump, die: f32, last_die: f32, watts: f32, last_watts: f32, dt: f32) ?Sample {
        if (dt > 1.1) {
            self.state = 0;
            return null;
        }
        const d = die - last_die;
        if (@abs(d) >= 1.5) {
            // a new jump, or the first: a second one on top restarts the count
            self.* = .{ .d_die = d, .dt = dt, .die_at = die, .watts_before = last_watts, .state = 1 };
            return null;
        }
        switch (self.state) {
            0 => return null,
            1 => {
                self.d_die -= (die - self.die_at) / dt * self.dt / 2;
                self.state = 2;
            },
            else => {},
        }
        self.age += dt;
        if (self.age < 0.75) return null;
        self.state = 0;
        return .{ .d_die = self.d_die, .d_watts = watts - self.watts_before };
    }
};

// ---------------------------------------------------------------- the fit of a long calibration

/// One steady state of a step response: the fans at a point, the power, where the die settled,
/// and how long the sink took to cover 63% of the way.
pub const Steady = struct { point: usize, watts: f32, die: f32, tau: f32 };

/// Fits the model to steady states (two or more per fan point give that point's g and a line
/// whose intercept is the room), the die's jumps per watt from power steps, and the room read
/// at the end with the fans at full. What has too little data stays as it was.
pub fn fit(steadies: []const Steady, jumps: []const f32, ambient_read: ?f32) Model {
    var m = Model{};
    // r_die: the median of the jumps
    if (jumps.len > 0) {
        var sorted: [32]f32 = undefined;
        const n = @min(jumps.len, sorted.len);
        @memcpy(sorted[0..n], jumps[0..n]);
        std.mem.sort(f32, sorted[0..n], {}, std.sort.asc(f32));
        m.r_die = std.math.clamp(sorted[n / 2], 0.02, 0.6);
    }
    // the room: read directly when it was, else the median intercept of the lines below
    var intercepts: [point_duty.len]f32 = undefined;
    var nintercepts: usize = 0;
    var masses: [point_duty.len]f32 = undefined;
    var nmasses: usize = 0;
    for (0..point_duty.len) |p| {
        // a line through this point's steadies: die = a + s * watts, s = 1/g + r_die
        var n: f32 = 0;
        var sw: f32 = 0;
        var sd: f32 = 0;
        var sww: f32 = 0;
        var swd: f32 = 0;
        var taus: f32 = 0;
        var ntaus: f32 = 0;
        for (steadies) |s| {
            if (s.point != p or s.watts <= 0) continue;
            n += 1;
            sw += s.watts;
            sd += s.die;
            sww += s.watts * s.watts;
            swd += s.watts * s.die;
            if (s.tau > 0) {
                taus += s.tau;
                ntaus += 1;
            }
        }
        if (n < 2) continue;
        const det = n * sww - sw * sw;
        if (@abs(det) < 1e-3) continue;
        const slope = (n * swd - sw * sd) / det;
        const intercept = (sd - slope * sw) / n;
        if (slope <= m.r_die + 0.01) continue;
        m.g[p] = 1 / (slope - m.r_die);
        intercepts[nintercepts] = intercept;
        nintercepts += 1;
        if (ntaus > 0) {
            masses[nmasses] = taus / ntaus * m.g[p];
            nmasses += 1;
        }
    }
    if (ambient_read) |a| {
        m.ambient = std.math.clamp(a, 10, 45);
    } else if (nintercepts > 0) {
        std.mem.sort(f32, intercepts[0..nintercepts], {}, std.sort.asc(f32));
        m.ambient = std.math.clamp(intercepts[nintercepts / 2], 10, 45);
    }
    if (nmasses > 0) {
        std.mem.sort(f32, masses[0..nmasses], {}, std.sort.asc(f32));
        m.mass = std.math.clamp(masses[nmasses / 2], 1, 500);
    }
    return m;
}

// ---------------------------------------------------------------- on disk

/// `r_die 0.120`, `ambient 30.0`, `mass 30.0`, `g boost 1.200` ... `g 60% 0.920`: three decimals
/// at most, parsed without the standard float parser.
pub const point_names = [_][]const u8{ "boost", "100%", "80%", "60%" };

pub fn format(m: *const Model, buf: []u8) []const u8 {
    var n: usize = 0;
    n += (std.fmt.bufPrint(buf[n..], "r_die {d:.3}\nambient {d:.1}\nmass {d:.1}\n", .{ m.r_die, m.ambient, m.mass }) catch return buf[0..n]).len;
    for (point_names, 0..) |name, i| {
        if (m.g[i] <= 0) continue;
        n += (std.fmt.bufPrint(buf[n..], "g {s} {d:.3}\n", .{ name, m.g[i] }) catch return buf[0..n]).len;
    }
    return buf[0..n];
}

pub fn parse(text: []const u8) Model {
    var m = Model{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const key = f.next() orelse continue;
        if (std.mem.eql(u8, key, "r_die")) {
            m.r_die = decimal(f.next() orelse continue) orelse 0;
        } else if (std.mem.eql(u8, key, "ambient")) {
            m.ambient = decimal(f.next() orelse continue) orelse 30;
        } else if (std.mem.eql(u8, key, "mass")) {
            m.mass = decimal(f.next() orelse continue) orelse 0;
        } else if (std.mem.eql(u8, key, "g")) {
            const name = f.next() orelse continue;
            for (point_names, 0..) |p, i| {
                if (std.mem.eql(u8, p, name)) m.g[i] = decimal(f.next() orelse break) orelse 0;
            }
        }
    }
    // nonsense is no model
    if (m.r_die < 0 or m.r_die > 1 or m.ambient < 5 or m.ambient > 50 or m.mass < 0 or m.mass > 1000) return .{};
    for (m.g) |v| if (v < 0 or v > 50) return .{};
    return m;
}

/// "0.120", "30.5", "7": up to three decimals.
pub fn decimal(text: []const u8) ?f32 {
    const dot = std.mem.indexOfScalar(u8, text, '.');
    const whole = std.fmt.parseInt(u32, text[0 .. dot orelse text.len], 10) catch return null;
    var frac: f32 = 0;
    if (dot) |d| {
        const digits = text[d + 1 ..];
        if (digits.len == 0 or digits.len > 3) return null;
        var scale: f32 = 0.1;
        for (digits) |c| {
            if (c < '0' or c > '9') return null;
            frac += @as(f32, @floatFromInt(c - '0')) * scale;
            scale /= 10;
        }
    }
    return @as(f32, @floatFromInt(whole)) + frac;
}

// ---------------------------------------------------------------- tests

/// The simulator's GF63: a sink of 30 J/C that carries 0.5 W/C still and 1.2 W/C at full,
/// a die 0.12 C/W above it, a room of 30 C.
fn gf63() Model {
    var m = Model{ .r_die = 0.12, .ambient = 30, .mass = 30 };
    for (point_duty, 0..) |d, i| m.g[i] = 0.5 + 0.7 * d / 255;
    return m;
}

test "the forecast settles where the plant does, and a burst is what the sink can take" {
    const m = gf63();
    try std.testing.expect(m.known());
    // at 30 W with the fans at full the die settles at 30 + 30/1.2 + 3.6 = 58.6
    try std.testing.expectApproxEqAbs(@as(f32, 58.6), m.forecast(50, 30, 255, 100_000), 0.1);
    // right now, the die is the sink plus the jump
    try std.testing.expectApproxEqAbs(@as(f32, 53.6), m.forecast(50, 30, 255, 0.001), 0.1);
    // the cooler holds 70 C at (70 - 30) / (1/1.2 + 0.12) = 42 W at full, less at 60%
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), m.holds(255, 70), 0.3);
    try std.testing.expect(m.holds(153, 70) < m.holds(255, 70) - 5);
    // a cold machine may burst past the firmware's 107 W for three seconds; a warm one may not
    try std.testing.expect(m.burst(40, 100, 69, 3) > 107);
    const warm = m.burst(62, 100, 69, 3);
    try std.testing.expect(warm > 30 and warm < 60);
    // and the burst it allows really keeps the die under the limit for those seconds
    try std.testing.expectApproxEqAbs(@as(f32, 69), m.forecast(62, warm, 100, 3), 0.05);
    // conductance: between points, and still air below the slowest
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m.conductance(180), 0.03);
    try std.testing.expect(m.conductance(60) < m.conductance(153) and m.conductance(0) > 0.2);
}

test "the fit recovers the plant from its steady states and jumps" {
    const truth = gf63();
    var steadies: [8]Steady = undefined;
    var n: usize = 0;
    for ([_]usize{ 1, 2, 3 }) |p| {
        for ([_]f32{ 0.5, 0.9 }) |share| {
            const w = truth.holds(point_duty[p], 70) * share;
            const g = truth.g[p];
            steadies[n] = .{ .point = p, .watts = w, .die = truth.ambient + w / g + truth.r_die * w, .tau = truth.mass / g };
            n += 1;
        }
    }
    const jumps = [_]f32{ 0.11, 0.12, 0.13, 0.12 };
    const m = fit(steadies[0..n], &jumps, 30.2);
    try std.testing.expect(m.known());
    try std.testing.expectApproxEqAbs(truth.r_die, m.r_die, 0.005);
    try std.testing.expectApproxEqAbs(truth.ambient, m.ambient, 0.3);
    try std.testing.expectApproxEqAbs(truth.mass, m.mass, 1.5);
    for ([_]usize{ 1, 2, 3 }) |p| try std.testing.expectApproxEqAbs(truth.g[p], m.g[p], 0.03);
    // Cooler Boost was not measured: unknown, and the conductance there is 100%'s
    try std.testing.expectEqual(@as(f32, 0), m.g[0]);
    try std.testing.expectApproxEqAbs(truth.g[1], m.conductance(255), 0.03);
    // too little: no fit
    try std.testing.expect(!fit(steadies[0..1], &.{}, null).known());
}

test "a fit that disagrees with the machine is no model" {
    var m = gf63();
    // the simulator's chip holds 42 W at 70 C with the fans at full: the fit agrees with 40
    try std.testing.expect(m.complaint(40, 70) == null);
    try std.testing.expect(m.complaint(0, 70) == null);
    // the GF63's first long calibration: 80% over 100%
    m.g = .{ 0, 0.89, 1.44, 1.16 };
    try std.testing.expect(std.mem.indexOf(u8, m.complaint(30, 70).?, "slower fan") != null);
    // and a room of 38 C that put "holds" at 24 W against 30 measured
    m.g = .{ 0, 0.89, 0.85, 0.8 };
    m.ambient = 38;
    m.r_die = 0.2;
    try std.testing.expect(std.mem.indexOf(u8, m.complaint(30.2, 70).?, "not what they carried") != null);
    m.ambient = 32;
    try std.testing.expect(m.complaint(30.2, 70) == null);
}

test "learning on the way: a jump teaches r_die slowly, a steady state the cooler" {
    var m = gf63();
    m.r_die = 0.08;
    const learned = m.learnJump(3.6, 30).?;
    try std.testing.expect(learned > 0.08 and learned < 0.12);
    try std.testing.expect(m.learnJump(1.0, 10) == null);
    // steady at 60 C and 30 W with the fans at 80%: the cooler carries 30 / (60 - 3.6 - 30) = 1.14
    m = gf63();
    m.g[2] = 0.8;
    const full_was = m.g[1];
    try std.testing.expectEqual(@as(usize, 2), m.learnSteady(60, 30, 200).?);
    try std.testing.expect(m.g[2] > 0.8 and m.g[2] < 1.14);
    // the other points moved by the same factor
    try std.testing.expectApproxEqAbs(full_was * m.g[2] / 0.8, m.g[1], 0.001);
    try std.testing.expect(m.learnSteady(60, 30, 100) == null);
}

test "the model goes to disk and comes back" {
    var buf: [256]u8 = undefined;
    const text = format(&gf63(), &buf);
    const back = parse(text);
    try std.testing.expect(back.known());
    try std.testing.expectApproxEqAbs(@as(f32, 0.12), back.r_die, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 30), back.ambient, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), back.g[0], 0.002);
    try std.testing.expectApproxEqAbs(@as(f32, 0.92), back.g[3], 0.002);
    try std.testing.expect(!parse("r_die 7\nmass 30\n").known());
    try std.testing.expectApproxEqAbs(@as(f32, 0.125), decimal("0.125").?, 1e-6);
    try std.testing.expect(decimal("1.2345") == null);
}

test "the observer holds the sink through a power step the power reading lags" {
    const m = gf63();
    var o = Observer{};
    _ = o.update(&m, 40.6, 5, 97, 0.25);
    try std.testing.expectApproxEqAbs(@as(f32, 40), o.sink, 0.01);
    // the die jumps 10.8 C at once; the power reading still says 5 W for this tick
    const during = o.update(&m, 51.4, 5, 97, 0.25);
    try std.testing.expect(during < 41.5);
    // the reading catches up: the sink estimate stays near the truth
    const after = o.update(&m, 51.6, 90, 97, 0.5);
    try std.testing.expect(after > 40 and after < 42.5);
}

test "a jump is read off the die and the power a moment later" {
    var j = Jump{};
    // steady at 40 C and 5 W; then the die jumps 10.8 C and the sink climbs 0.7 C a tick
    try std.testing.expect(j.update(40.0, 40.0, 5, 5, 0.25) == null);
    try std.testing.expect(j.update(51.0, 40.0, 5, 5, 0.25) == null);
    try std.testing.expect(j.update(51.7, 51.0, 47, 5, 0.25) == null);
    try std.testing.expect(j.update(52.4, 51.7, 90, 47, 0.25) == null);
    const s = j.update(53.1, 52.4, 90, 90, 0.25).?;
    // 11.0 less half a tick of the climb at 2.8 C/s: about 10.65
    try std.testing.expectApproxEqAbs(@as(f32, 10.65), s.d_die, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 85), s.d_watts, 0.01);
    // nothing more from the same jump
    try std.testing.expect(j.update(53.8, 53.1, 90, 90, 0.25) == null);
}
