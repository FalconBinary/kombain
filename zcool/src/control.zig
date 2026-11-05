// SPDX-License-Identifier: GPL-3.0-or-later

//! The decisions, with no system calls, so they can be tested against a model.
//!
//! The order is what keeps a chip fast: forecast the temperature, spin the fans
//! up before the limit, and only when the fans have nothing left take a little
//! power away, in small steps, giving it back as soon as there is room.

const std = @import("std");

/// How far ahead the temperature is forecast, in seconds.
pub const horizon: f32 = 4;
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
        return self.temp + @max(self.slope, 0) * horizon;
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

        var rate = -(0.02 * thermal.slope + 0.003 * (temp - (limit - 1)));
        // while the fans still have room they get to act before any power is taken
        if (rate < 0 and !no_more_cooling and !over) rate = 0;
        if (over) rate -= (temp - limit) * 0.05;
        self.level = std.math.clamp(self.level + std.math.clamp(rate, -0.5, 0.1) * dt, min_level, 1);
    }
};

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

test "a limit cannot be set above the critical point minus the margin" {
    try std.testing.expectEqual(@as(f32, 95), clampLimit(200, 100, 90));
    try std.testing.expectEqual(@as(f32, 90), clampLimit(200, 0, 90));
    try std.testing.expectEqual(@as(f32, 30), clampLimit(5, 100, 90));
    try std.testing.expectEqual(@as(f32, 75), clampLimit(75, 100, 90));
}
