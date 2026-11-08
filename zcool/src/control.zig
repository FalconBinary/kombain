// SPDX-License-Identifier: GPL-3.0-or-later

//! The decisions, with no system calls, so they can be tested against a model.
//!
//! The order is what keeps a chip fast: forecast the temperature, spin the fans
//! up before the limit, and only when the fans have nothing left take a little
//! power away, in small steps, giving it back as soon as there is room.

const std = @import("std");

/// How far ahead the temperature is forecast, in seconds.
pub const horizon: f32 = 4;
/// How far the forecast may run ahead of the temperature. A CPU's die jumps 20 C within a
/// second when a burst of work starts, and levels off as soon after: following that slope any
/// further spun fans and took power for heat that never came (seen on a real laptop at 65 C).
pub const max_lead: f32 = 8;
/// Fans start this far below the limit and reach full speed at the limit.
pub const fan_band: f32 = 8;
/// A chip is never throttled below this level; below that the hardware protects itself.
pub const min_level: f32 = 0.3;
/// Fans return to firmware control after this long with nothing to do.
pub const release_after: f32 = 20;

pub const Thermal = struct {
    temp: f32 = 0,
    slope: f32 = 0,
    ready: bool = false,

    pub fn update(self: *Thermal, raw: f32, dt: f32) void {
        if (!self.ready) {
            self.temp = raw;
            self.ready = true;
            return;
        }
        if (dt <= 0) return;
        const old = self.temp;
        self.temp += (raw - self.temp) * dt / (dt + 0.5);
        self.slope += ((self.temp - old) / dt - self.slope) * dt / (dt + 2);
    }

    /// Only a rising temperature moves the forecast: a falling one must not relax anything early.
    pub fn forecast(self: *const Thermal) f32 {
        return self.temp + std.math.clamp(self.slope * horizon, 0, max_lead);
    }
};

/// 0 means the firmware curve is fine, 1 means full speed.
pub fn fanDemand(forecast: f32, limit: f32) f32 {
    return std.math.clamp((forecast - (limit - fan_band)) / fan_band, 0, 1);
}

pub const Fan = struct {
    duty: f32 = 0,
    idle: f32 = 0,

    /// Up at once, down slowly: heat comes fast and fan noise should not pump.
    pub fn update(self: *Fan, floor: f32, demand: f32, dt: f32) void {
        const target = floor + (255 - floor) * demand;
        if (target >= self.duty) {
            self.duty = target;
        } else {
            self.duty = @max(target, self.duty - 6 * dt);
        }
        self.duty = std.math.clamp(self.duty, floor, 255);
        self.idle = if (demand > 0) 0 else self.idle + dt;
    }

    pub fn canRelease(self: *const Fan) bool {
        return self.idle >= release_after;
    }
};

pub const Throttle = struct {
    level: f32 = 1,
    /// Where to start when power must first be taken: what the cooler is known to carry.
    start: f32 = 1,

    /// `no_more_cooling` is true when every fan that serves this chip is at full speed, or it has none.
    pub fn update(self: *Throttle, thermal: *const Thermal, limit: f32, crit: f32, no_more_cooling: bool, dt: f32) void {
        const temp = thermal.temp;
        if (crit > 0 and temp >= crit - 3) {
            self.level = min_level;
            return;
        }
        const over = temp > limit + 2;
        const engage = no_more_cooling and thermal.forecast() > limit - 0.5;
        // nothing to do yet: stays at full power until cooling is exhausted or the limit is broken
        if (self.level >= 1 and !engage and !over) return;
        if (self.level >= 1 and no_more_cooling and self.start < 1) self.level = @max(self.start, min_level);

        var rate = -(0.02 * thermal.slope + 0.003 * (temp - (limit - 1)));
        // while the fans still have room they get to act before any power is taken,
        // and power taken earlier comes back: the fans carry it
        if (!no_more_cooling and !over) rate = if (temp < limit - 0.5) @max(rate, 0.02) else @max(rate, 0);
        if (over) rate -= (temp - limit) * 0.05;
        self.level = std.math.clamp(self.level + std.math.clamp(rate, -0.5, 0.1) * dt, min_level, 1);
    }
};

/// In quiet mode a chip first gives up this much of its power before its fans are pushed past
/// the firmware's curve: a few percent of speed for a lot less noise.
pub const quiet_floor: f32 = 0.85;
/// Fans that quiet mode let in stay until the heat has been gone this long, so that they do
/// not come and go with every swing of the load.
pub const quiet_after: f32 = 30;
/// How long the power must have stayed at the floor before the fans come: on the way up the
/// heat often takes it there for a moment, and gives it back as it levels off.
pub const quiet_patience: f32 = 5;

pub const Quiet = struct {
    loud: bool = false,
    cool_for: f32 = 0,
    floor_for: f32 = 0,

    /// True while the fans may go past the firmware's curve for this chip.
    pub fn update(self: *Quiet, on: bool, thermal: *const Thermal, limit: f32, level: f32, emergency: bool, dt: f32) bool {
        if (!on) {
            self.* = .{};
            return true;
        }
        // at the floor and still heading for the limit: the power alone is not enough
        self.floor_for = if (level <= quiet_floor + 0.01 and thermal.forecast() > limit - 1) self.floor_for + dt else 0;
        if (self.floor_for >= quiet_patience or emergency or thermal.temp > limit + 1) self.loud = true;
        self.cool_for = if (thermal.forecast() < limit - fan_band) self.cool_for + dt else 0;
        if (self.cool_for >= quiet_after) self.loud = false;
        return self.loud;
    }
};

/// The firmware's silent fan curve while every chip is this far below its limit, forecast and
/// all, for `silent_after` seconds; its normal curve again as soon as one comes within
/// `silent_leave`. The firmware keeps its own protection either way.
pub const silent_enter: f32 = 25;
pub const silent_leave: f32 = 18;
pub const silent_after: f32 = 20;

pub const FanMode = struct {
    silent: bool = false,
    calm_for: f32 = 0,

    /// `margin` is how far the chip nearest its limit is from it.
    pub fn update(self: *FanMode, margin: f32, dt: f32) bool {
        if (margin < silent_leave) {
            self.* = .{};
            return false;
        }
        if (margin >= silent_enter) {
            self.calm_for += dt;
        } else if (!self.silent) {
            self.calm_for = 0;
        }
        if (self.calm_for >= silent_after) self.silent = true;
        return self.silent;
    }
};

/// What the cooler carries: the power a chip settles at while it is held at its limit with
/// every fan at full. Learned while that happens and kept on disk, so that the next time the
/// heat builds up the power goes straight there instead of feeling its way down.
pub const Learned = struct {
    watts: f32 = 0,
    /// the limit it was learned at
    at: f32 = 0,
    seconds: f32 = 0,

    /// What heats a chip's surroundings: the cooler carries in proportion to how far the
    /// limit is above it. A guess, and the controller corrects what it gets wrong.
    pub const ambient: f32 = 30;

    /// Only a steady temperature near the limit, with power already taken, tells what the
    /// cooler carries; anything else tells what the work happened to ask for.
    pub fn observe(self: *Learned, watts: f32, thermal: *const Thermal, limit: f32, trimmed: bool, dt: f32) void {
        if (!trimmed or watts < 1 or dt <= 0) return;
        const temp = thermal.temp;
        if (temp > limit + 1.5 or temp < limit - 5 or temp < ambient + 10 or @abs(thermal.slope) > 0.2) return;
        if (self.at != limit and self.seconds > 0) {
            self.watts = self.carries(limit) orelse 0;
            self.seconds = @min(self.seconds, 10);
        }
        self.at = limit;
        self.seconds += dt;
        // where it settled is a little under the limit: what it carries at the limit itself
        const at_limit = watts * (limit - ambient) / (temp - ambient);
        // a plain mean at first, then the last minute or so
        self.watts += (at_limit - self.watts) * dt / @min(self.seconds, 60);
    }

    pub fn known(self: *const Learned) bool {
        return self.seconds >= 10 and self.watts >= 1;
    }

    /// What it carries at `limit`, from what it carried at the limit it was learned at.
    pub fn carries(self: *const Learned, limit: f32) ?f32 {
        if (!self.known() or self.at <= ambient + 5 or limit <= ambient + 5) return null;
        return self.watts * (limit - ambient) / (self.at - ambient);
    }

    /// The level to start at from `reference_watts`, a little under what the cooler carries.
    pub fn startLevel(self: *const Learned, limit: f32, reference_watts: f32) f32 {
        const watts = self.carries(limit) orelse return 1;
        if (reference_watts < 1) return 1;
        return std.math.clamp(watts * 0.95 / reference_watts, min_level, 1);
    }
};

/// The longest a GPU that may sleep goes unread while it has nothing to do. Every read keeps
/// it awake, and the kernel lets it sleep only after a few idle seconds (amdgpu: 5).
pub const quiet_period_ms: i64 = 10_000;

/// Nothing could need doing soon: well below the limit, no power taken, no fan held.
pub fn isQuiet(forecast: f32, limit: f32, level: f32, fans_held: bool) bool {
    return forecast < limit - fan_band - 10 and level >= 1 and !fans_held;
}

/// How long until the next read: `busy_ms` while there is something to watch, and while
/// quiet a gap that doubles up to `quiet_period_ms`, long enough for the GPU to fall asleep.
pub fn readPeriod(current_ms: i64, busy_ms: i64, quiet: bool) i64 {
    if (!quiet) return busy_ms;
    return @min(quiet_period_ms, @max(2 * current_ms, 2000));
}

/// Picks the limit a chip really gets: never above its critical point minus a margin.
pub fn clampLimit(wanted: f32, crit: f32, fallback_ceiling: f32) f32 {
    const ceiling = if (crit > 0) crit - 5 else fallback_ceiling;
    return std.math.clamp(wanted, 30, ceiling);
}

// ---------------------------------------------------------------- tests

const Plant = struct {
    temp: f32 = 45,
    ambient: f32 = 30,
    /// Heat in watts at full speed, thermal mass in J/K, and conductance in W/K at idle and at full fan.
    power: f32,
    mass: f32 = 40,
    g_min: f32 = 0.5,
    g_max: f32,

    fn step(self: *Plant, level: f32, duty: f32, dt: f32) void {
        const g = self.g_min + (self.g_max - self.g_min) * duty / 255;
        self.temp += (self.power * level * level - (self.temp - self.ambient) * g) * dt / self.mass;
    }

    /// A power limit: the heat follows the level itself, not its square as a clock limit's does.
    fn stepLinear(self: *Plant, level: f32, duty: f32, dt: f32) void {
        const g = self.g_min + (self.g_max - self.g_min) * duty / 255;
        self.temp += (self.power * level - (self.temp - self.ambient) * g) * dt / self.mass;
    }
};

fn simulate(plant: *Plant, limit: f32, seconds: f32) struct { peak: f32, level: f32 } {
    var thermal = Thermal{};
    var fan = Fan{ .duty = 80 };
    var throttle = Throttle{};
    var peak: f32 = 0;
    const dt: f32 = 0.25;
    var t: f32 = 0;
    while (t < seconds) : (t += dt) {
        thermal.update(plant.temp, dt);
        fan.update(80, fanDemand(thermal.forecast(), limit), dt);
        throttle.update(&thermal, limit, 100, fan.duty >= 255, dt);
        plant.step(throttle.level, fan.duty, dt);
        peak = @max(peak, plant.temp);
    }
    return .{ .peak = peak, .level = throttle.level };
}

test "good cooling keeps the limit without losing any speed" {
    var plant = Plant{ .power = 100, .g_max = 4 };
    const r = simulate(&plant, 85, 300);
    try std.testing.expect(r.peak <= 85);
    try std.testing.expectEqual(@as(f32, 1), r.level);
}

test "weak cooling holds the limit by giving up only what it must" {
    // 220 W against 3 W/K would settle 73 K above ambient without control: 103 C
    var plant = Plant{ .power = 220, .g_max = 3 };
    const r = simulate(&plant, 85, 600);
    try std.testing.expect(r.peak <= 87);
    try std.testing.expect(plant.temp >= 80);
    // what the cooler can carry at 85 C: level^2 * 220 = 55 K * 3 W/K, so 0.87
    try std.testing.expect(r.level > 0.8 and r.level < 0.92);
}

test "forecast only looks at a rising temperature" {
    var t = Thermal{};
    t.update(80, 1);
    t.update(70, 1);
    try std.testing.expect(t.forecast() <= t.temp);
}

test "a burst far below the limit forecasts nothing near it" {
    var t = Thermal{};
    t.update(45, 0.25);
    // 45 to 65 C in a second, as a real laptop CPU does when work starts
    var temp: f32 = 45;
    while (temp < 65) : (temp += 5) t.update(temp, 0.25);
    try std.testing.expect(t.forecast() <= t.temp + max_lead);
    try std.testing.expect(fanDemand(t.forecast(), 90) == 0);
}

test "near the critical point power drops at once" {
    var t = Thermal{ .temp = 98, .ready = true };
    var throttle = Throttle{};
    throttle.update(&t, 85, 100, false, 0.25);
    try std.testing.expectEqual(min_level, throttle.level);
}

test "throttle recovers when the heat is gone" {
    var t = Thermal{ .temp = 50, .ready = true };
    var throttle = Throttle{ .level = 0.5 };
    var i: u32 = 0;
    while (i < 40) : (i += 1) throttle.update(&t, 85, 100, true, 0.25);
    try std.testing.expectEqual(@as(f32, 1), throttle.level);
}

test "fans never go below the firmware speed and release after a while" {
    var fan = Fan{ .duty = 255 };
    var i: u32 = 0;
    while (i < 400) : (i += 1) fan.update(120, 0, 0.25);
    try std.testing.expectEqual(@as(f32, 120), fan.duty);
    try std.testing.expect(fan.canRelease());
    fan.update(120, 0.5, 0.25);
    try std.testing.expect(!fan.canRelease());
}

test "an idle GPU is read less and less often, a busy one at once" {
    try std.testing.expect(isQuiet(50, 85, 1, false));
    try std.testing.expect(!isQuiet(70, 85, 1, false));
    try std.testing.expect(!isQuiet(50, 85, 0.9, false));
    try std.testing.expect(!isQuiet(50, 85, 1, true));
    var period: i64 = 0;
    var waited: i64 = 0;
    while (period < quiet_period_ms) {
        period = readPeriod(period, 0, true);
        waited += period;
    }
    try std.testing.expectEqual(quiet_period_ms, period);
    // asleep within the first half minute of doing nothing
    try std.testing.expect(waited <= 30_000);
    try std.testing.expectEqual(@as(i64, 1000), readPeriod(quiet_period_ms, 1000, false));
}

test "a limit cannot be set above the critical point minus the margin" {
    try std.testing.expectEqual(@as(f32, 95), clampLimit(200, 100, 90));
    try std.testing.expectEqual(@as(f32, 90), clampLimit(200, 0, 90));
    try std.testing.expectEqual(@as(f32, 30), clampLimit(5, 100, 90));
    try std.testing.expectEqual(@as(f32, 75), clampLimit(75, 100, 90));
}

test "quiet mode takes a little power before the fans, and keeps the fans once it needs them" {
    // the firmware's curve alone settles at 40 + 25 / 0.9 = 68 K over: 98 C, too hot for 85
    var plant = Plant{ .power = 125, .g_min = 0.9, .g_max = 3 };
    var thermal = Thermal{};
    var fan = Fan{ .duty = 0 };
    var throttle = Throttle{};
    var quiet = Quiet{};
    const dt: f32 = 0.25;
    var t: f32 = 0;
    var lowest_before_fans: f32 = 1;
    var fans_at: f32 = -1;
    while (t < 400) : (t += dt) {
        thermal.update(plant.temp, dt);
        const loud = quiet.update(true, &thermal, 85, throttle.level, false, dt);
        const demand = if (loud) fanDemand(thermal.forecast(), 85) else 0;
        fan.update(0, demand, dt);
        if (fan.duty > 0 and fans_at < 0) fans_at = t;
        if (fans_at < 0) lowest_before_fans = @min(lowest_before_fans, throttle.level);
        throttle.update(&thermal, 85, 100, fan.duty >= 255 or !loud, dt);
        plant.stepLinear(throttle.level, fan.duty, dt);
    }
    // the fans came only after the power had gone down to the floor, and not below it
    try std.testing.expect(fans_at > 0);
    try std.testing.expect(lowest_before_fans >= quiet_floor - 0.02 and lowest_before_fans <= quiet_floor + 0.02);
    try std.testing.expect(plant.temp <= 87);
    // with the fans on it got its power back, and the fans stayed
    try std.testing.expect(throttle.level > 0.95 and quiet.loud and fan.duty > 0);
    // the load ends: the fans go back to the firmware once the heat is gone for a while
    plant.power = 10;
    t = 0;
    while (t < 200) : (t += dt) {
        thermal.update(plant.temp, dt);
        const loud = quiet.update(true, &thermal, 85, throttle.level, false, dt);
        fan.update(0, if (loud) fanDemand(thermal.forecast(), 85) else 0, dt);
        throttle.update(&thermal, 85, 100, fan.duty >= 255 or !loud, dt);
        plant.stepLinear(throttle.level, fan.duty, dt);
    }
    try std.testing.expect(!quiet.loud and fan.duty == 0);
}

test "off, quiet mode lets the fans go first as always" {
    var thermal = Thermal{ .temp = 60, .ready = true };
    var quiet = Quiet{};
    try std.testing.expect(quiet.update(false, &thermal, 85, 1, false, 0.25));
    try std.testing.expect(!quiet.update(true, &thermal, 85, 1, false, 0.25));
    thermal.temp = 87;
    try std.testing.expect(quiet.update(true, &thermal, 85, 1, false, 0.25));
}

test "the cooler is learned while it holds the limit, and power then starts there" {
    // linear in the level, as a power limit is: holds 85 C at 55 K * 3 W/K = 165 W
    var plant = Plant{ .power = 220, .g_max = 3 };
    var thermal = Thermal{};
    var throttle = Throttle{};
    var learned = Learned{};
    const dt: f32 = 0.25;
    var t: f32 = 0;
    while (t < 600) : (t += dt) {
        thermal.update(plant.temp, dt);
        throttle.update(&thermal, 85, 100, true, dt);
        learned.observe(plant.power * throttle.level, &thermal, 85, throttle.level < 1, dt);
        plant.stepLinear(throttle.level, 255, dt);
    }
    try std.testing.expect(learned.known());
    try std.testing.expect(learned.watts > 155 and learned.watts < 175);
    // at a limit 10 C lower the cooler carries less, in proportion to the rise over ambient
    try std.testing.expect(learned.carries(75).? < learned.watts * 0.85);
    // the next time, from a 220 W reference, power starts near 165 W and the peak is lower
    const start = learned.startLevel(85, 220);
    try std.testing.expect(start > 0.65 and start < 0.75);
    var cold = Plant{ .power = 220, .g_max = 3 };
    var warm = Plant{ .power = 220, .g_max = 3 };
    try std.testing.expect(peakLinear(&warm, start) < peakLinear(&cold, 1));
}

test "nothing is learned while power is not taken or the temperature moves" {
    var learned = Learned{};
    var thermal = Thermal{ .temp = 85, .ready = true };
    learned.observe(100, &thermal, 85, false, 1);
    thermal.slope = 1;
    learned.observe(100, &thermal, 85, true, 1);
    thermal = .{ .temp = 70, .ready = true };
    learned.observe(100, &thermal, 85, true, 1);
    try std.testing.expect(!learned.known());
    try std.testing.expectEqual(@as(f32, 1), learned.startLevel(85, 200));
}

fn peakLinear(plant: *Plant, start: f32) f32 {
    var thermal = Thermal{};
    var throttle = Throttle{ .start = start };
    var peak: f32 = 0;
    const dt: f32 = 0.25;
    var t: f32 = 0;
    while (t < 120) : (t += dt) {
        thermal.update(plant.temp, dt);
        throttle.update(&thermal, 85, 100, true, dt);
        plant.stepLinear(throttle.level, 255, dt);
        peak = @max(peak, plant.temp);
    }
    return peak;
}

test "the silent fan curve while everything is cool, the normal one before it is not" {
    var mode = FanMode{};
    var t: f32 = 0;
    while (t < 19) : (t += 0.5) try std.testing.expect(!mode.update(30, 0.5));
    try std.testing.expect(mode.update(30, 1));
    // a little warmer: stays, that is what the gap is for
    try std.testing.expect(mode.update(20, 0.5));
    // heading for the limit: the normal curve at once
    try std.testing.expect(!mode.update(17, 0.5));
    // and the calm has to last again before it goes back
    try std.testing.expect(!mode.update(30, 5));
    try std.testing.expect(!mode.update(22, 30));
    try std.testing.expect(!mode.update(30, 19));
    try std.testing.expect(mode.update(30, 2));
}
