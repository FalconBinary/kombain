// SPDX-License-Identifier: GPL-3.0-or-later

//! The decisions, with no system calls, so they can be tested against a model.
//!
//! The order is what keeps a chip fast: forecast the temperature, spin the fans
//! up before the limit, no faster than the heat needs, and only when the fans have
//! nothing left take a little power away, in small steps, giving it back as soon as
//! there is room.

const std = @import("std");

/// How far ahead the temperature is forecast, in seconds.
pub const horizon: f32 = 4;
/// How far the forecast may run ahead of the temperature. A CPU's die jumps 20 C within a
/// second when a burst of work starts, and levels off as soon after: following that slope any
/// further spun fans and took power for heat that never came (seen on a real laptop at 65 C).
pub const max_lead: f32 = 8;
/// Within this much of the limit nothing is quiet: the firmware's silent curve goes, and the
/// temperature is read often.
pub const fan_band: f32 = 8;
/// The fans hold a chip this far under its limit: no faster than the heat needs, and the last
/// degrees are left for a burst to land in before any power is taken.
pub const fan_margin: f32 = 2;
/// With every fan at full, power comes back in full only this far under the limit. Full power
/// gives a CPU its short-term limit back too, and it bursts to that at once, with nothing left
/// to catch it: on a real laptop from 68 C to over its 70 C limit within a second.
pub const release_margin: f32 = 3;
/// And only once it has stayed there this long: a die follows its power at once, so right after
/// a deep cut it reads cool while the work goes on. On the GF63 54 C five seconds into the load
/// gave full power back, and a second later it was 64 C and power went again.
pub const release_hold: f32 = 5;
/// A chip is never throttled below this level; below that the hardware protects itself.
pub const min_level: f32 = 0.3;
/// Fans return to firmware control after this long with nothing to do.
pub const release_after: f32 = 20;
/// Every chip at least this far under its limit is a machine at rest: read once a second.
pub const rest_margin: f32 = 20;

pub const Thermal = struct {
    temp: f32 = 0,
    slope: f32 = 0,
    ready: bool = false,
    /// where the machine's model says the die will be two seconds on, when there is one: the
    /// time a fan takes to spin up, which is all the model's forecast needs to run ahead
    model_forecast: ?f32 = null,

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
    /// With a model of the machine its word stands, hedged by a little of the slope's.
    pub fn forecast(self: *const Thermal) f32 {
        if (self.model_forecast) |m| return @max(m, self.temp + std.math.clamp(self.slope * horizon, 0, 3));
        return self.temp + std.math.clamp(self.slope * horizon, 0, max_lead);
    }
};

/// How hard the fans run for one chip: 0 leaves them to the firmware's curve, 1 is full speed.
///
/// They start `fan_band` under the limit and reach full speed at it, rising with the forecast,
/// so a heat that is still climbing finds them already turning. Once the heat holds steady, the
/// fans find the speed it needs: a little less while the chip stays well under the fan point,
/// 2 C under the limit, and a little more while it stays over it. So the temperature settles at
/// the fan point instead of wherever the band happens to balance it lower down: the same heat
/// for less fan. Within a degree of the fan point it finds nothing new, as fans that chase every
/// tenth of a degree are heard doing it.
pub const FanDrive = struct {
    /// what the steady heat was found to need, on top of the band or under it
    held: f32 = 0,
    /// what calibration says the fans need for the heat right now, as a demand: while the heat
    /// is steady the trim goes there at once instead of finding it over minutes
    need: ?f32 = null,

    pub fn update(self: *FanDrive, thermal: *const Thermal, limit: f32, dt: f32) f32 {
        const forecast = thermal.forecast();
        const band = std.math.clamp((forecast - (limit - fan_band)) / fan_band, 0, 1);
        const off = forecast - (limit - fan_margin);
        if (off > 0.5) {
            self.held += (off - 0.5) * 0.008 * dt;
        } else if (off < -1 and thermal.slope < 0.05) {
            // steady, or the heat going: not while it still climbs
            self.held += (off + 1) * 0.008 * dt;
        }
        if (self.need) |n| {
            if (@abs(thermal.slope) < 0.1 and off < 0.5) self.held += std.math.clamp(n - band - self.held, -0.05 * dt, 0.05 * dt);
        }
        // the trim under the band was for a steady heat: new work that climbs gets the band back,
        // faster than the slow rise the trim itself brings
        if (thermal.slope > 0.3 and self.held < 0) self.held = @min(0, self.held + 0.1 * dt);
        // never under the firmware's speed, never past full: nothing builds up that is not used
        self.held = std.math.clamp(self.held, -band, 1 - band);
        // and the last degree and a half before the limit gets every fan, whatever was found
        const last = (forecast - (limit - 1.5)) / 1.5;
        return std.math.clamp(@max(band + self.held, last), 0, 1);
    }
};

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
    /// how long it has been `release_margin` under the limit
    cool_for: f32 = 0,

    /// `no_more_cooling` is true when every fan that serves this chip is at full speed, or it has none.
    pub fn update(self: *Throttle, thermal: *const Thermal, limit: f32, crit: f32, no_more_cooling: bool, dt: f32) void {
        const temp = thermal.temp;
        if (crit > 0 and temp >= crit - 3) {
            self.level = min_level;
            return;
        }
        const over = temp > limit + 2;
        const engage = no_more_cooling and thermal.forecast() > limit - 0.5;
        self.cool_for = if (temp <= limit - release_margin) self.cool_for + dt else 0;
        // nothing to do yet: stays at full power until cooling is exhausted or the limit is broken
        if (self.level >= 1 and !engage and !over) return;
        if (self.level >= 1 and no_more_cooling and self.start < 1) self.level = @max(self.start, min_level);

        var rate = -(0.02 * thermal.slope + 0.003 * (temp - (limit - 1)));
        // while the fans still have room they get to act before any power is taken,
        // and power taken earlier comes back: the fans carry it
        if (!no_more_cooling and !over) rate = if (temp < limit - 0.5) @max(rate, 0.02) else @max(rate, 0);
        // over the limit with nothing left to cool it: a CPU's die follows its power at once,
        // so taking a little more brings it back within seconds instead of a minute
        if (no_more_cooling and temp > limit) rate -= (temp - limit) * 0.03;
        if (over) rate -= (temp - limit) * 0.05;
        self.level = std.math.clamp(self.level + std.math.clamp(rate, -0.5, 0.1) * dt, min_level, 1);
        // all of it only with room for the burst it lets loose, and once the work has eased
        if (self.level >= 1 and no_more_cooling and self.cool_for < release_hold) self.level = 0.99;
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
    /// the share of power quiet mode may give up before the fans: calibration may know better
    floor: f32 = quiet_floor,
    loud: bool = false,
    cool_for: f32 = 0,
    floor_for: f32 = 0,

    /// True while the fans may go past the firmware's curve for this chip.
    pub fn update(self: *Quiet, on: bool, thermal: *const Thermal, limit: f32, level: f32, emergency: bool, dt: f32) bool {
        if (!on) {
            self.* = .{ .floor = self.floor };
            return true;
        }
        // at the floor and still heading for the limit: the power alone is not enough
        self.floor_for = if (level <= self.floor + 0.01 and thermal.forecast() > limit - 1) self.floor_for + dt else 0;
        if (self.floor_for >= quiet_patience or emergency or thermal.temp > limit + 1) self.loud = true;
        self.cool_for = if (thermal.forecast() < limit - fan_band) self.cool_for + dt else 0;
        if (self.cool_for >= quiet_after) self.loud = false;
        return self.loud;
    }
};

/// The firmware's silent fan curve while every chip is this far below its limit, forecast and
/// all, for `silent_after` seconds; its normal curve again once one has stayed within
/// `silent_leave` for `silent_patience`, or at once within `silent_urgent`. A desktop's short
/// bursts lift a die's forecast that far for a second and are gone: on the GF63 they swapped the
/// curves every half minute while it sat idle. The firmware keeps its own protection either way.
pub const silent_enter: f32 = 25;
pub const silent_leave: f32 = 18;
pub const silent_urgent: f32 = 10;
pub const silent_after: f32 = 20;
pub const silent_patience: f32 = 3;

pub const FanMode = struct {
    silent: bool = false,
    calm_for: f32 = 0,
    near_for: f32 = 0,

    /// `margin` is how far the chip nearest its limit is from it.
    pub fn update(self: *FanMode, margin: f32, dt: f32) bool {
        self.near_for = if (margin < silent_leave) self.near_for + dt else 0;
        if (margin < silent_urgent or self.near_for >= silent_patience or (!self.silent and margin < silent_leave)) {
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
    var drive = FanDrive{};
    var throttle = Throttle{};
    var peak: f32 = 0;
    const dt: f32 = 0.25;
    var t: f32 = 0;
    while (t < seconds) : (t += dt) {
        thermal.update(plant.temp, dt);
        fan.update(80, drive.update(&thermal, limit, dt), dt);
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
    var drive = FanDrive{};
    try std.testing.expect(drive.update(&t, 90, 0.25) == 0);
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
    var drive = FanDrive{};
    var throttle = Throttle{};
    var quiet = Quiet{};
    const dt: f32 = 0.25;
    var t: f32 = 0;
    var lowest_before_fans: f32 = 1;
    var fans_at: f32 = -1;
    while (t < 400) : (t += dt) {
        thermal.update(plant.temp, dt);
        const loud = quiet.update(true, &thermal, 85, throttle.level, false, dt);
        const demand = if (loud) drive.update(&thermal, 85, dt) else 0;
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
        fan.update(0, if (loud) drive.update(&thermal, 85, dt) else 0, dt);
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
    // a burst lifts the forecast for a second: stays
    try std.testing.expect(mode.update(15, 1));
    try std.testing.expect(mode.update(30, 0.5));
    // heading for the limit and staying there: the normal curve
    try std.testing.expect(mode.update(15, 2));
    try std.testing.expect(!mode.update(15, 1.5));
    // and the calm has to last again before it goes back
    try std.testing.expect(!mode.update(30, 5));
    try std.testing.expect(!mode.update(22, 30));
    try std.testing.expect(!mode.update(30, 19));
    try std.testing.expect(mode.update(30, 2));
    // far nearer: at once
    try std.testing.expect(!mode.update(8, 0.5));
}

test "power comes back in full only with room for the burst" {
    var t = Thermal{ .temp = 83, .ready = true };
    var throttle = Throttle{ .level = 0.9 };
    var i: u32 = 0;
    // 2 C under the limit with every fan at full: close to all of it, never all of it
    while (i < 200) : (i += 1) throttle.update(&t, 85, 100, true, 0.25);
    try std.testing.expect(throttle.level > 0.95 and throttle.level < 1);
    // fans that still have room catch the burst: all of it
    i = 0;
    while (i < 200) : (i += 1) throttle.update(&t, 85, 100, false, 0.25);
    try std.testing.expectEqual(@as(f32, 1), throttle.level);
    // well under it with every fan at full: all of it too, once it has stayed there
    throttle.level = 0.9;
    t.temp = 80;
    i = 0;
    while (i < 16) : (i += 1) throttle.update(&t, 85, 100, true, 0.25);
    try std.testing.expect(throttle.level < 1);
    while (i < 100) : (i += 1) throttle.update(&t, 85, 100, true, 0.25);
    try std.testing.expectEqual(@as(f32, 1), throttle.level);
}

/// Where the fans settle for a heat that needs some of them, and how hard they run there.
const Settled = struct { temp: f32, duty: f32, peak: f32 };

fn settle(plant: *Plant, band_only: bool, seconds: f32) Settled {
    return settleWith(plant, band_only, null, seconds);
}

fn settleWith(plant: *Plant, band_only: bool, need: ?f32, seconds: f32) Settled {
    var thermal = Thermal{};
    var fan = Fan{ .duty = 60 };
    var drive = FanDrive{ .need = need };
    var peak: f32 = 0;
    const dt: f32 = 0.25;
    var t: f32 = 0;
    while (t < seconds) : (t += dt) {
        thermal.update(plant.temp, dt);
        // what zcool did before: from 8 C under the limit, linearly to full at it
        const demand = if (band_only) std.math.clamp((thermal.forecast() - 77) / 8, 0, 1) else drive.update(&thermal, 85, dt);
        fan.update(60, demand, dt);
        plant.stepLinear(1, fan.duty, dt);
        peak = @max(peak, plant.temp);
    }
    return .{ .temp = plant.temp, .duty = fan.duty, .peak = peak };
}

test "a steady heat is held near the fan point with less fan than the band alone" {
    // 90 W: the band alone settles it at 78.6 C
    var a = Plant{ .power = 90, .g_min = 0.5, .g_max = 4 };
    const drive = settle(&a, false, 600);
    var b = Plant{ .power = 90, .g_min = 0.5, .g_max = 4 };
    const band = settle(&b, true, 600);
    try std.testing.expect(drive.temp > 81 and drive.temp < 85 - fan_margin + 0.6);
    try std.testing.expect(drive.peak <= 85);
    try std.testing.expect(drive.duty < band.duty - 5);
}

test "a heat that climbs finds the fans as the band has them, and every fan at the limit" {
    var t = Thermal{ .temp = 85, .ready = true };
    var drive = FanDrive{};
    try std.testing.expectEqual(@as(f32, 1), drive.update(&t, 85, 0.25));
    t.temp = 70;
    drive = .{};
    try std.testing.expectEqual(@as(f32, 0), drive.update(&t, 85, 0.25));
    // trimmed for a steady heat, then it climbs: the trim goes within seconds
    t = .{ .temp = 80, .slope = 0.5, .ready = true };
    drive = .{ .held = -0.2 };
    var i: u32 = 0;
    while (i < 12) : (i += 1) _ = drive.update(&t, 85, 0.25);
    try std.testing.expect(drive.held > -0.1);
    // at the limit every fan, whatever the trim
    t = .{ .temp = 85, .ready = true };
    drive = .{ .held = -0.5 };
    try std.testing.expectEqual(@as(f32, 1), drive.update(&t, 85, 0.25));
    // the heat goes: what was found on top goes with it, and the fans go back to the firmware
    t = .{ .temp = 60, .slope = -0.5, .ready = true };
    drive = .{ .held = 0.3 };
    i = 0;
    while (i < 80) : (i += 1) _ = drive.update(&t, 85, 0.25);
    try std.testing.expectEqual(@as(f32, 0), drive.update(&t, 85, 0.25));
}

test "over the limit with every fan at full, power goes until it is back within seconds" {
    // a die over its sink by 0.12 C per watt, as a laptop CPU's is: 90 W asked, 40 W carried
    var sink: f32 = 64;
    var thermal = Thermal{};
    var throttle = Throttle{ .level = 0.7 };
    const dt: f32 = 0.25;
    var t: f32 = 0;
    var over_for: f32 = 0;
    while (t < 60) : (t += dt) {
        const watts = 90 * throttle.level;
        const die = sink + watts * 0.12;
        thermal.update(die, dt);
        throttle.update(&thermal, 70, 100, true, dt);
        sink += (watts - (sink - 30) * 1.2) * dt / 30;
        if (die > 70.5) over_for += dt;
    }
    try std.testing.expect(over_for < 6);
    try std.testing.expect(thermal.temp > 67 and thermal.temp < 70.5);
}

test "what calibration knows the fans go to at once, what it does not they find" {
    // 90 W holds at the fan point with the fans at 87/255 here: a demand of 0.14 over 60
    var a = Plant{ .power = 90, .g_min = 0.5, .g_max = 4 };
    const told = settleWith(&a, false, 0.14, 60);
    var b = Plant{ .power = 90, .g_min = 0.5, .g_max = 4 };
    const found = settleWith(&b, false, null, 60);
    try std.testing.expect(@abs(told.duty - 87) < 6);
    try std.testing.expect(found.duty > told.duty + 5);
    try std.testing.expect(told.peak <= 85);
}
