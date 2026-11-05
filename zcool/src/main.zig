// SPDX-License-Identifier: GPL-3.0-or-later

//! zcool: keeps every chip under the temperature you set, with as little lost speed as possible.
//!
//! It only uses what the kernel exposes in /sys: hwmon for temperatures and fans,
//! powercap and cpufreq for the CPU, the amdgpu power cap for the GPU. It never
//! takes over a chip's own protection: PROCHOT and the thermal shutdown stay in
//! hardware and keep working if this daemon is gone.

const std = @import("std");
const sys = @import("sys.zig");
const control = @import("control.zig");
const config = @import("config.zig");
const journal = @import("journal.zig");
const undervolt = @import("undervolt.zig");
const sandbox = @import("sandbox.zig");

pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .signal_stack_size = null,
};

pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(msg: []const u8, _: ?usize) noreturn {
    @branchHint(.cold);
    sys.eprint("zcool: internal error: ");
    sys.eprint(msg);
    sys.eprint("\n");
    emergencyRestore();
    sys.exit(134);
}

var restoring: bool = false;

/// Only raw system calls and static buffers: this also runs from a crash handler.
fn emergencyRestore() void {
    if (restoring) return;
    restoring = true;
    if (!dry_run) _ = journal.restore();
}

const max_chips = 16;
const max_sensors = 128;
const max_fans = 16;
const max_policies = 256;
const max_packages = 8;

const Kind = enum { cpu, gpu, nvme, other };

const Sensor = struct {
    fd: i32,
    crit: f32,
    chip: u8,
    primary: bool,
    label: [16]u8 = undefined,
    label_len: u8 = 0,
    last: f32 = 0,
};

const Chip = struct {
    id: [24]u8 = undefined,
    id_len: u8 = 0,
    kind: Kind,
    limit: f32 = 0,
    crit: f32 = 0,
    thermal: control.Thermal = .{},
    throttle: control.Throttle = .{},
    has_primary: bool = false,
    failures: u8 = 0,
    period_ms: i64 = 0,
    due_ms: i64 = 0,
    last_read_ms: i64 = 0,
    own_fans: bool = false,
    emergency: bool = false,
    over_logged: bool = false,
    throttle_logged: bool = false,
    no_actuator: bool = false,
    asleep: bool = false,
    blind_logged: bool = false,
    // the GPU power cap and runtime power state
    cap_path: [160]u8 = undefined,
    cap_len: u8 = 0,
    cap_base: i64 = 0,
    cap_min: i64 = 0,
    cap_saved: bool = false,
    cap_applied: f32 = 1,
    cap_reference: i64 = 0,
    power_fd: i32 = -1,
    runtime_fd: i32 = -1,

    fn name(self: *const Chip) []const u8 {
        return self.id[0..self.id_len];
    }

    fn controlled(self: *const Chip) bool {
        return self.limit > 0;
    }
};

const Fan = struct {
    id: [40]u8 = undefined,
    id_len: u8 = 0,
    pwm: [160]u8 = undefined,
    pwm_len: u8 = 0,
    enable: [160]u8 = undefined,
    enable_len: u8 = 0,
    input_fd: i32 = -1,
    owner: i16 = -1,
    managed: bool = false,
    journaled: bool = false,
    unusable: bool = false,
    orig_pwm: i64 = 0,
    orig_enable: i64 = 0,
    floor: f32 = 0,
    written: i64 = -1,
    ctl: control.Fan = .{},
    stalled_for: f32 = 0,
    stall_logged: bool = false,

    fn name(self: *const Fan) []const u8 {
        return self.id[0..self.id_len];
    }

    fn pwmPath(self: *const Fan, buf: []u8) [:0]const u8 {
        return sys.join(buf, &.{self.pwm[0..self.pwm_len]});
    }

    fn enablePath(self: *const Fan, buf: []u8) [:0]const u8 {
        return sys.join(buf, &.{self.enable[0..self.enable_len]});
    }
};

const Policy = struct { index: u16, original: i64, min: i64, max: i64 };

const CpuPower = struct {
    rapl_count: u8 = 0,
    rapl_base: [max_packages]i64 = undefined,
    rapl_index: [max_packages]u8 = undefined,
    rapl_original: [max_packages]i64 = undefined,
    rapl_energy_fd: [max_packages]i32 = undefined,
    rapl_energy: [max_packages]i64 = undefined,
    rapl_watts: [max_packages]f32 = undefined,
    rapl_reference: [max_packages]f32 = undefined,
    rapl_sampled_ms: i64 = 0,
    rapl_saved: bool = false,
    freq_saved: bool = false,
    freq_active: bool = false,
    escalated: bool = false,
    over_for: f32 = 0,
    policies: [max_policies]Policy = undefined,
    npolicies: u16 = 0,
    applied: f32 = 1,
};

var sensors: [max_sensors]Sensor = undefined;
var nsensors: usize = 0;
var chips: [max_chips]Chip = undefined;
var nchips: usize = 0;
var fans: [max_fans]Fan = undefined;
var nfans: usize = 0;
var cpu_power = CpuPower{};
var cfg = config.Config{};

var dry_run: bool = false;
var stop_requested: bool = false;

// ---------------------------------------------------------------- discovery

fn classify(name: []const u8) Kind {
    const cpu_names = [_][]const u8{ "coretemp", "k10temp", "zenpower", "k8temp", "cpu_thermal", "cpu-thermal", "via_cputemp" };
    const gpu_names = [_][]const u8{ "amdgpu", "radeon", "nouveau", "i915", "xe" };
    for (cpu_names) |n| if (std.mem.eql(u8, name, n)) return .cpu;
    for (gpu_names) |n| if (std.mem.eql(u8, name, n)) return .gpu;
    if (std.mem.eql(u8, name, "nvme")) return .nvme;
    return .other;
}

fn isPrimaryLabel(kind: Kind, label: []const u8) bool {
    return switch (kind) {
        .gpu => std.mem.eql(u8, label, "edge"),
        .nvme => std.mem.eql(u8, label, "Composite"),
        .cpu => std.mem.eql(u8, label, "Tctl") or std.mem.eql(u8, label, "Tdie"),
        .other => false,
    };
}

/// True when `name` is prefix + digits + suffix, for names like temp3_input.
fn matchIndexed(name: []const u8, prefix: []const u8, suffix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, suffix)) return null;
    if (name.len <= prefix.len + suffix.len) return null;
    const digits = name[prefix.len .. name.len - suffix.len];
    for (digits) |c| if (c < '0' or c > '9') return null;
    return digits;
}

fn degrees(path: [:0]const u8) f32 {
    const milli = sys.readInt(path) orelse return 0;
    return @as(f32, @floatFromInt(milli)) / 1000;
}

fn setId(chip: *Chip, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.bufPrint(&chip.id, fmt, args) catch chip.id[0..0];
    chip.id_len = @intCast(text.len);
}

var count_of: [4]u8 = .{ 0, 0, 0, 0 };
var other_names: [max_chips][16]u8 = undefined;
var other_counts: [max_chips]u8 = undefined;
var nother: usize = 0;

fn otherIndex(name: []const u8) u8 {
    for (0..nother) |i| {
        if (std.mem.eql(u8, std.mem.sliceTo(&other_names[i], 0), name)) {
            other_counts[i] += 1;
            return other_counts[i] - 1;
        }
    }
    if (nother == max_chips or name.len >= 16) return 0;
    @memset(&other_names[nother], 0);
    @memcpy(other_names[nother][0..name.len], name);
    other_counts[nother] = 1;
    nother += 1;
    return 0;
}

fn scanHwmon(base: []const u8) void {
    var path_buf: [256]u8 = undefined;
    var name_buf: [32]u8 = undefined;
    const raw_name = sys.readFile(sys.join(&path_buf, &.{ base, "/name" }), &name_buf) orelse return;
    const chip_name = std.mem.trim(u8, raw_name, " \t\r\n");
    const kind = classify(chip_name);

    var chip_index: ?usize = null;
    var dir = sys.Dir.open(sys.join(&path_buf, &.{base})) orelse return;
    defer dir.close();
    while (dir.next()) |entry| {
        if (matchIndexed(entry, "temp", "_input")) |digits| {
            if (nsensors == max_sensors) continue;
            if (chip_index == null) {
                if (nchips == max_chips) continue;
                chip_index = nchips;
                chips[nchips] = .{ .kind = kind };
                const c = &chips[nchips];
                switch (kind) {
                    .cpu, .gpu, .nvme => {
                        const n = count_of[@backingInt(kind)];
                        count_of[@backingInt(kind)] += 1;
                        setId(c, "{s}{d}", .{ @tagName(kind), n });
                    },
                    .other => setId(c, "{s}{d}", .{ chip_name, otherIndex(chip_name) }),
                }
                c.period_ms = if (kind == .nvme) 5000 else 0;
                if (kind == .gpu) setUpGpu(c, base);
                nchips += 1;
            }
            const c = &chips[chip_index.?];
            const fd = sys.openRead(sys.join(&path_buf, &.{ base, "/", entry })) orelse continue;
            var s = Sensor{ .fd = fd, .crit = 0, .chip = @intCast(chip_index.?), .primary = false };
            s.crit = degrees(sys.join(&path_buf, &.{ base, "/temp", digits, "_crit" }));
            var label_buf: [32]u8 = undefined;
            if (sys.readFile(sys.join(&path_buf, &.{ base, "/temp", digits, "_label" }), &label_buf)) |raw_label| {
                const label = std.mem.trim(u8, raw_label, " \t\r\n");
                const n = @min(label.len, s.label.len);
                @memcpy(s.label[0..n], label[0..n]);
                s.label_len = @intCast(n);
                s.primary = isPrimaryLabel(kind, label);
            }
            if (s.primary) c.has_primary = true;
            sensors[nsensors] = s;
            nsensors += 1;
        } else if (matchIndexed(entry, "pwm", "")) |digits| {
            addFan(base, chip_name, digits, kind);
        }
    }
    if (chip_index) |i| finishChip(&chips[i]);
    // fans on a GPU belong to that GPU; everything else cools whoever needs it
    if (kind == .gpu) {
        if (chip_index) |i| {
            var f: usize = 0;
            while (f < nfans) : (f += 1) {
                if (fans[f].owner == -2) {
                    fans[f].owner = @intCast(i);
                    chips[i].own_fans = true;
                }
            }
        }
    }
    var f: usize = 0;
    while (f < nfans) : (f += 1) {
        if (fans[f].owner == -2) fans[f].owner = -1;
    }
}

fn addFan(base: []const u8, chip_name: []const u8, digits: []const u8, kind: Kind) void {
    var id_buf: [40]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buf, "{s}/pwm{s}", .{ chip_name, digits }) catch return;
    if (cfg.isExcluded(id) or nfans == max_fans) return;
    var path_buf: [256]u8 = undefined;
    var fan = Fan{};
    @memcpy(fan.id[0..id.len], id);
    fan.id_len = @intCast(id.len);
    const pwm = sys.join(&path_buf, &.{ base, "/pwm", digits });
    if (pwm.len == 0 or pwm.len > fan.pwm.len) return;
    @memcpy(fan.pwm[0..pwm.len], pwm);
    fan.pwm_len = @intCast(pwm.len);
    const enable = sys.join(&path_buf, &.{ base, "/pwm", digits, "_enable" });
    if (enable.len <= fan.enable.len and sys.exists(enable)) {
        @memcpy(fan.enable[0..enable.len], enable);
        fan.enable_len = @intCast(enable.len);
    }
    fan.input_fd = sys.openRead(sys.join(&path_buf, &.{ base, "/fan", digits, "_input" })) orelse -1;
    fan.owner = if (kind == .gpu) -2 else -1;
    fans[nfans] = fan;
    nfans += 1;
}

fn setUpGpu(c: *Chip, base: []const u8) void {
    var path_buf: [256]u8 = undefined;
    const cap = sys.join(&path_buf, &.{ base, "/power1_cap" });
    if (cap.len > 0 and cap.len <= c.cap_path.len) {
        if (sys.readInt(cap)) |value| {
            if (value > 0) {
                @memcpy(c.cap_path[0..cap.len], cap);
                c.cap_len = @intCast(cap.len);
                c.cap_base = value;
                c.cap_min = sys.readInt(sys.join(&path_buf, &.{ base, "/power1_cap_min" })) orelse 0;
                c.cap_reference = value;
                c.power_fd = sys.openRead(sys.join(&path_buf, &.{ base, "/power1_average" })) orelse
                    sys.openRead(sys.join(&path_buf, &.{ base, "/power1_input" })) orelse -1;
            }
        }
    }
    c.runtime_fd = sys.openRead(sys.join(&path_buf, &.{ base, "/device/power/runtime_status" })) orelse -1;
}

/// Decides the limit: from the config, else a default that leaves room below the critical point.
fn finishChip(c: *Chip) void {
    var crit: f32 = 0;
    for (sensors[0..nsensors]) |*s| {
        if (&chips[s.chip] != c or s.crit <= 0) continue;
        if (s.primary) {
            crit = s.crit;
            break;
        }
        crit = if (crit == 0) s.crit else @min(crit, s.crit);
    }
    // a driver that reports nonsense must not move the safety margin
    if (crit < 50 or crit > 130) crit = 0;
    c.crit = crit;
    const fallback: f32 = switch (c.kind) {
        .cpu => 95,
        .gpu => 100,
        .nvme, .other => 80,
    };
    if (cfg.limitFor(c.name())) |wanted| {
        c.limit = control.clampLimit(wanted, crit, fallback);
        if (c.limit != wanted) {
            sys.printf("{s}: limit {d:.0} is outside the safe range, using {d:.0}\n", .{ c.name(), wanted, c.limit });
        }
        return;
    }
    c.limit = switch (c.kind) {
        .cpu => if (crit > 0) @min(90, crit - 10) else 90,
        .gpu => if (crit > 0) crit - 15 else 85,
        .nvme => if (crit > 0) crit - 10 else 70,
        .other => 0, // watched only: board sensors are often not worth a fan spike
    };
}

fn discoverCpuPower() void {
    var path_buf: [256]u8 = undefined;
    var dir_buf: [256]u8 = undefined;
    var i: u8 = 0;
    while (i < max_packages) : (i += 1) {
        var num: [4]u8 = undefined;
        const digits = std.fmt.bufPrint(&num, "{d}", .{i}) catch break;
        const limit = sys.readInt(sys.join(&path_buf, &.{ sys.root, "/sys/class/powercap/intel-rapl:", digits, "/constraint_0_power_limit_uw" })) orelse break;
        const most = sys.readInt(sys.join(&path_buf, &.{ sys.root, "/sys/class/powercap/intel-rapl:", digits, "/constraint_0_max_power_uw" })) orelse limit;
        // firmware sometimes reports "no limit" as thousands of watts
        const base = if (limit > 0 and limit < 1_000_000_000) limit else most;
        if (base <= 0 or base >= 1_000_000_000) break;
        const n = cpu_power.rapl_count;
        cpu_power.rapl_base[n] = base;
        cpu_power.rapl_original[n] = limit;
        cpu_power.rapl_index[n] = i;
        cpu_power.rapl_energy_fd[n] = sys.openRead(sys.join(&path_buf, &.{ sys.root, "/sys/class/powercap/intel-rapl:", digits, "/energy_uj" })) orelse -1;
        cpu_power.rapl_energy[n] = -1;
        cpu_power.rapl_watts[n] = 0;
        cpu_power.rapl_reference[n] = @floatFromInt(base);
        cpu_power.rapl_count += 1;
    }
    var dir = sys.Dir.open(sys.join(&dir_buf, &.{ sys.root, "/sys/devices/system/cpu/cpufreq" })) orelse return;
    defer dir.close();
    while (dir.next()) |entry| {
        const digits = matchIndexed(entry, "policy", "") orelse continue;
        if (cpu_power.npolicies == max_policies) break;
        const index = std.fmt.parseInt(u16, digits, 10) catch continue;
        const original = sys.readInt(policyPath(&path_buf, digits, "scaling_max_freq")) orelse continue;
        const most = sys.readInt(policyPath(&path_buf, digits, "cpuinfo_max_freq")) orelse original;
        const least = sys.readInt(policyPath(&path_buf, digits, "cpuinfo_min_freq")) orelse 0;
        cpu_power.policies[cpu_power.npolicies] = .{ .index = index, .original = original, .min = least, .max = most };
        cpu_power.npolicies += 1;
    }
}

fn policyPath(buf: []u8, digits: []const u8, file: []const u8) [:0]const u8 {
    return sys.join(buf, &.{ sys.root, "/sys/devices/system/cpu/cpufreq/policy", digits, "/", file });
}

fn discover() void {
    var base_buf: [256]u8 = undefined;
    var indexes: [64]u16 = undefined;
    var count: usize = 0;
    var dir = sys.Dir.open(sys.join(&base_buf, &.{ sys.root, "/sys/class/hwmon" })) orelse return;
    while (dir.next()) |entry| {
        const digits = matchIndexed(entry, "hwmon", "") orelse continue;
        if (count == indexes.len) break;
        indexes[count] = std.fmt.parseInt(u16, digits, 10) catch continue;
        count += 1;
    }
    dir.close();
    // hwmon numbers follow probe order: sorting keeps ids the same between runs
    std.mem.sort(u16, indexes[0..count], {}, std.sort.asc(u16));
    for (indexes[0..count]) |n| {
        var num: [8]u8 = undefined;
        const digits = std.fmt.bufPrint(&num, "{d}", .{n}) catch continue;
        var path: [256]u8 = undefined;
        scanHwmon(sys.join(&path, &.{ sys.root, "/sys/class/hwmon/hwmon", digits }));
    }
    discoverCpuPower();
    for (chips[0..nchips]) |*c| {
        c.no_actuator = c.kind != .cpu and c.cap_len == 0;
    }
}

// ---------------------------------------------------------------- actuators

fn takeFan(fan: *Fan) bool {
    var pwm_buf: [200]u8 = undefined;
    var enable_buf: [200]u8 = undefined;
    const pwm = fan.pwmPath(&pwm_buf);
    const current = sys.readInt(pwm) orelse return false;
    if (current < 0 or current > 255) return false;
    // never below what the firmware is running right now: this may be a pump
    fan.floor = @floatFromInt(current);
    fan.ctl = .{ .duty = fan.floor };
    fan.written = -1;
    if (dry_run) return true;
    if (!fan.journaled) {
        if (fan.enable_len > 0) {
            fan.orig_enable = sys.readInt(fan.enablePath(&enable_buf)) orelse return false;
            if (!journal.remember(fan.enablePath(&enable_buf))) return false;
        }
        fan.orig_pwm = current;
        if (!journal.remember(pwm)) return false;
        fan.journaled = true;
    }
    if (fan.enable_len > 0 and !sys.writeInt(fan.enablePath(&enable_buf), 1)) return false;
    return true;
}

fn releaseFan(fan: *Fan) void {
    fan.managed = false;
    if (dry_run) return;
    var pwm_buf: [200]u8 = undefined;
    var enable_buf: [200]u8 = undefined;
    if (fan.enable_len > 0) {
        _ = sys.writeInt(fan.pwmPath(&pwm_buf), fan.orig_pwm);
        _ = sys.writeInt(fan.enablePath(&enable_buf), fan.orig_enable);
    } else {
        _ = sys.writeInt(fan.pwmPath(&pwm_buf), fan.orig_pwm);
    }
}

fn updateFan(fan: *Fan, demand: f32, dt: f32) void {
    if (fan.unusable) return;
    if (!fan.managed) {
        if (demand <= 0) return;
        if (!takeFan(fan)) {
            fan.unusable = true;
            sys.printf("{s}: cannot be controlled, leaving it to the firmware\n", .{fan.name()});
            return;
        }
        fan.managed = true;
        sys.printf("{s}: taking over from {d:.0}/255\n", .{ fan.name(), fan.floor });
    }
    fan.ctl.update(fan.floor, demand, dt);
    if (fan.ctl.canRelease()) {
        sys.printf("{s}: back to the firmware\n", .{fan.name()});
        releaseFan(fan);
        return;
    }
    const duty: i64 = @intFromFloat(@round(fan.ctl.duty));
    if (fan.written < 0 or @abs(duty - fan.written) >= 2 or (duty == 255 and fan.written != 255)) {
        if (!dry_run) {
            var pwm_buf: [200]u8 = undefined;
            if (!sys.writeInt(fan.pwmPath(&pwm_buf), duty)) {
                sys.printf("{s}: write failed, leaving it to the firmware\n", .{fan.name()});
                releaseFan(fan);
                fan.unusable = true;
                return;
            }
        }
        fan.written = duty;
    }
    if (fan.input_fd >= 0 and duty >= 200) {
        const rpm = sys.readIntFd(fan.input_fd) orelse 1;
        fan.stalled_for = if (rpm == 0) fan.stalled_for + dt else 0;
        if (fan.stalled_for >= 5 and !fan.stall_logged) {
            sys.printf("{s}: at {d}/255 and not spinning. Check this fan\n", .{ fan.name(), duty });
            fan.stall_logged = true;
        }
    }
}

/// Average power per package, from the energy counter.
fn sampleCpuPower(now: i64) void {
    const elapsed = now - cpu_power.rapl_sampled_ms;
    if (elapsed < 500) return;
    cpu_power.rapl_sampled_ms = now;
    var i: usize = 0;
    while (i < cpu_power.rapl_count) : (i += 1) {
        const fd = cpu_power.rapl_energy_fd[i];
        if (fd < 0) continue;
        const energy = sys.readIntFd(fd) orelse continue;
        // the first sample has no baseline, and the counter wraps around
        if (cpu_power.rapl_energy[i] >= 0 and energy > cpu_power.rapl_energy[i]) {
            const uj: f32 = @floatFromInt(energy - cpu_power.rapl_energy[i]);
            const ms: f32 = @floatFromInt(elapsed);
            const watts = uj / ms; // microjoules per millisecond is milliwatts
            cpu_power.rapl_watts[i] += (watts - cpu_power.rapl_watts[i]) * 0.5;
        }
        cpu_power.rapl_energy[i] = energy;
    }
}

fn applyRapl(level: f32, starting: bool) bool {
    var path_buf: [256]u8 = undefined;
    var i: usize = 0;
    while (i < cpu_power.rapl_count) : (i += 1) {
        var num: [4]u8 = undefined;
        const digits = std.fmt.bufPrint(&num, "{d}", .{cpu_power.rapl_index[i]}) catch return false;
        const path = sys.join(&path_buf, &.{ sys.root, "/sys/class/powercap/intel-rapl:", digits, "/constraint_0_power_limit_uw" });
        if (!cpu_power.rapl_saved and !journal.remember(path)) return false;
        const base: f32 = @floatFromInt(cpu_power.rapl_base[i]);
        // a limit far above what the chip draws does nothing: start from the real power
        if (starting) {
            const milliwatts = cpu_power.rapl_watts[i];
            cpu_power.rapl_reference[i] = if (milliwatts > 5000) @min(milliwatts * 1000, base) else base;
        }
        const target: i64 = if (level >= 1) cpu_power.rapl_original[i] else @intFromFloat(cpu_power.rapl_reference[i] * level);
        if (!sys.writeInt(path, target)) return false;
        // some firmware takes the write and keeps its own value
        const back = sys.readInt(path) orelse return false;
        if (@abs(back - target) > @divTrunc(target, 20)) return false;
    }
    cpu_power.rapl_saved = true;
    return true;
}

fn applyFreq(level: f32) void {
    var path_buf: [256]u8 = undefined;
    for (cpu_power.policies[0..cpu_power.npolicies]) |p| {
        var num: [8]u8 = undefined;
        const digits = std.fmt.bufPrint(&num, "{d}", .{p.index}) catch continue;
        const path = policyPath(&path_buf, digits, "scaling_max_freq");
        if (!cpu_power.freq_saved and !journal.remember(path)) continue;
        const span: f32 = @floatFromInt(p.max);
        const wanted: i64 = @intFromFloat(span * level);
        const target = if (level >= 1) p.original else std.math.clamp(wanted, p.min, p.original);
        _ = sys.writeInt(path, target);
    }
    cpu_power.freq_saved = true;
}

fn applyCpu(level: f32) void {
    if (level == cpu_power.applied or (level < 1 and @abs(level - cpu_power.applied) < 0.01)) return;
    const starting = cpu_power.applied >= 1;
    cpu_power.applied = level;
    if (dry_run) return;
    if (cpu_power.rapl_count > 0) {
        if (!applyRapl(level, starting)) {
            sys.print("cpu: the power limit does not stick here, using frequency limits\n");
            cpu_power.rapl_count = 0;
        } else if (!cpu_power.escalated) {
            if (cpu_power.freq_active and level >= 1) {
                applyFreq(1);
                cpu_power.freq_active = false;
            }
            return;
        }
    }
    applyFreq(level);
    cpu_power.freq_active = level < 1;
    if (level >= 1) cpu_power.escalated = false;
}

/// A power limit can be accepted and then have no effect. If the temperature stays
/// over the limit in spite of it, frequency limits join in.
fn watchEscalation(hottest_over: bool, dt: f32) void {
    if (cpu_power.rapl_count == 0 or cpu_power.escalated) return;
    cpu_power.over_for = if (hottest_over) cpu_power.over_for + dt else 0;
    if (cpu_power.over_for >= 3 and cpu_power.npolicies > 0) {
        cpu_power.escalated = true;
        sys.print("cpu: the power limit is not holding the temperature, also limiting frequency\n");
        if (!dry_run) {
            applyFreq(cpu_power.applied);
            cpu_power.freq_active = true;
        }
    }
}

fn applyGpu(c: *Chip, level: f32) void {
    if (c.cap_len == 0) return;
    if (level == c.cap_applied or (level < 1 and @abs(level - c.cap_applied) < 0.01)) return;
    if (c.cap_applied >= 1) {
        // start from what the GPU draws right now, a cap far above that does nothing
        const microwatts = if (c.power_fd >= 0) sys.readIntFd(c.power_fd) orelse 0 else 0;
        c.cap_reference = if (microwatts > 5_000_000) @min(microwatts, c.cap_base) else c.cap_base;
    }
    c.cap_applied = level;
    if (dry_run) return;
    var path_buf: [200]u8 = undefined;
    const path = sys.join(&path_buf, &.{c.cap_path[0..c.cap_len]});
    if (!c.cap_saved) {
        if (!journal.remember(path)) return;
        c.cap_saved = true;
    }
    const reference: f32 = @floatFromInt(c.cap_reference);
    const target: i64 = if (level >= 1) c.cap_base else @intFromFloat(reference * level);
    _ = sys.writeInt(path, @max(target, c.cap_min));
}

// ---------------------------------------------------------------- the loop

fn readChips(now: i64) bool {
    for (chips[0..nchips], 0..) |*c, index| {
        if (now < c.due_ms) continue;
        c.due_ms = now + c.period_ms;
        if (c.runtime_fd >= 0) {
            // reading a sensor would wake a sleeping GPU and waste more power than it saves
            var state: [16]u8 = undefined;
            const n = sys.pread(c.runtime_fd, &state, 0) orelse 0;
            c.asleep = n >= 9 and std.mem.startsWith(u8, state[0..n], "suspended");
            if (c.asleep) continue;
        }
        var best: f32 = -1000;
        var primary: f32 = -1000;
        var good = false;
        c.emergency = false;
        for (sensors[0..nsensors]) |*s| {
            if (s.chip != index) continue;
            const milli = sys.readIntFd(s.fd) orelse continue;
            const t = @as(f32, @floatFromInt(milli)) / 1000;
            // some inputs are not wired to anything and read 0 or 127
            if (t <= 0 or t >= 125) continue;
            good = true;
            s.last = t;
            best = @max(best, t);
            if (s.primary) primary = t;
            if (s.crit > 0 and t >= s.crit - 3) c.emergency = true;
        }
        if (!good) {
            c.failures +|= 1;
            if (c.failures < 5 or !c.controlled()) continue;
            if (c.thermal.ready) {
                sys.printf("{s}: sensors are gone, handing everything back\n", .{c.name()});
                return false;
            }
            // it never gave a usable reading, so nothing was built on it
            if (!c.blind_logged) {
                c.blind_logged = true;
                sys.printf("{s}: no usable readings, ignoring it\n", .{c.name()});
            }
            continue;
        }
        c.failures = 0;
        const dt = if (c.last_read_ms == 0) 0 else @as(f32, @floatFromInt(now - c.last_read_ms)) / 1000;
        c.last_read_ms = now;
        c.thermal.update(if (c.has_primary and primary > -1000) primary else best, dt);
    }
    return true;
}

fn fanServes(fan: *const Fan, index: usize) bool {
    if (fan.owner >= 0) return @as(usize, @intCast(fan.owner)) == index;
    return !chips[index].own_fans;
}

fn noMoreCooling(index: usize) bool {
    for (fans[0..nfans]) |*f| {
        if (f.unusable or !fanServes(f, index)) continue;
        if (!f.managed or f.ctl.duty < 254) return false;
    }
    return true;
}

fn step(dt: f32) void {
    for (fans[0..nfans]) |*f| {
        var demand: f32 = 0;
        for (chips[0..nchips], 0..) |*c, index| {
            if (!c.controlled() or !c.thermal.ready or c.asleep or !fanServes(f, index)) continue;
            // a chip going through its critical point gets everything at once
            const d = if (c.emergency) 1 else control.fanDemand(c.thermal.forecast(), c.limit);
            demand = @max(demand, d);
        }
        updateFan(f, demand, dt);
    }

    var cpu_level: f32 = 1;
    var cpu_over = false;
    for (chips[0..nchips], 0..) |*c, index| {
        if (!c.controlled() or !c.thermal.ready or c.asleep) continue;
        const crit = if (c.emergency) c.thermal.temp + 1 else c.crit;
        c.throttle.update(&c.thermal, c.limit, crit, noMoreCooling(index), dt);
        report(c);
        switch (c.kind) {
            .cpu => {
                cpu_level = @min(cpu_level, c.throttle.level);
                if (c.thermal.temp > c.limit + 2) cpu_over = true;
            },
            .gpu => applyGpu(c, c.throttle.level),
            else => {},
        }
    }
    applyCpu(cpu_level);
    watchEscalation(cpu_over, dt);
}

fn report(c: *Chip) void {
    const throttled = c.throttle.level < 0.995 and !c.no_actuator;
    if (throttled != c.throttle_logged) {
        c.throttle_logged = throttled;
        if (throttled) {
            sys.printf("{s}: {d:.1}C, fans have nothing left, trimming power for the {d:.0}C limit\n", .{ c.name(), c.thermal.temp, c.limit });
        } else {
            sys.printf("{s}: {d:.1}C, full power again\n", .{ c.name(), c.thermal.temp });
        }
    }
    const over = c.thermal.temp > c.limit + 2;
    if (over != c.over_logged) {
        c.over_logged = over;
        if (over and c.no_actuator) {
            sys.printf("{s}: {d:.1}C is over the {d:.0}C limit and only fans can help it\n", .{ c.name(), c.thermal.temp, c.limit });
        } else if (over) {
            sys.printf("{s}: {d:.1}C is over the {d:.0}C limit\n", .{ c.name(), c.thermal.temp, c.limit });
        }
    }
}

fn tickMs() i64 {
    for (fans[0..nfans]) |*f| if (f.managed) return 250;
    for (chips[0..nchips]) |*c| {
        if (c.controlled() and (c.thermal.forecast() > c.limit - control.fan_band or c.throttle.level < 1)) return 250;
    }
    return 500;
}

fn onStop(_: std.os.linux.SIG) callconv(.c) void {
    stop_requested = true;
}

fn onCrash(_: std.os.linux.SIG) callconv(.c) void {
    emergencyRestore();
    sys.exit(139);
}

fn installSignals() void {
    const linux = std.os.linux;
    var stop = linux.Sigaction{ .handler = .{ .handler = onStop }, .mask = linux.sigemptyset(), .flags = 0 };
    for ([_]linux.SIG{ .TERM, .INT, .HUP }) |signal| _ = linux.sigaction(signal, &stop, null);
    var crash = linux.Sigaction{ .handler = .{ .handler = onCrash }, .mask = linux.sigemptyset(), .flags = 0 };
    for ([_]linux.SIG{ .SEGV, .BUS, .ILL, .FPE, .ABRT }) |signal| _ = linux.sigaction(signal, &crash, null);
}

fn loadConfig(path_arg: ?[:0]const u8) void {
    var path_buf: [256]u8 = undefined;
    const path = path_arg orelse sys.join(&path_buf, &.{ sys.root, "/etc/zcool.conf" });
    var text: [8192]u8 = undefined;
    const content = sys.readFile(path, &text) orelse return;
    cfg = config.parse(content);
    if (cfg.bad_lines > 0) sys.printf("{s}: skipped {d} line(s) that make no sense\n", .{ path, cfg.bad_lines });
}

fn applySandbox() sandbox.Status {
    var sys_buf: [256]u8 = undefined;
    var run_buf: [256]u8 = undefined;
    var lib_buf: [256]u8 = undefined;
    return sandbox.apply(&.{}, &.{
        sys.join(&sys_buf, &.{ sys.root, "/sys" }),
        sys.join(&run_buf, &.{ sys.root, "/run/zcool" }),
        sys.join(&lib_buf, &.{ sys.root, "/var/lib/zcool" }),
    });
}

fn runDaemon(selftest: bool) u8 {
    if (!dry_run) {
        journal.prepare();
        // left over from a crash: back to the originals before reading them as the new originals
        const leftovers = journal.restore();
        if (leftovers > 0) sys.printf("restored {d} value(s) left by an earlier run\n", .{leftovers});
    }
    discover();
    installSignals();

    var undervolted = false;
    if (dry_run) {
        if (cfg.undervolt_core != 0 or cfg.undervolt_cache != 0) sys.print("dry run: undervolt not applied\n");
    } else if (cfg.undervolt_core != 0 or cfg.undervolt_cache != 0) {
        if (undervolt.apply(cfg.undervolt_core, cfg.undervolt_cache)) |reason| {
            sys.printf("undervolt: {s}\n", .{undervolt.explain(reason)});
        } else {
            undervolted = true;
            sys.printf("undervolt: core {d} mV, cache {d} mV\n", .{ cfg.undervolt_core, cfg.undervolt_cache });
        }
    }

    const sandboxed = applySandbox();
    sys.printf("sandbox: {s}\n", .{@tagName(sandboxed)});
    if (selftest) {
        var passwd: [64]u8 = undefined;
        var path_buf: [64]u8 = undefined;
        const open = sys.readFile(sys.join(&path_buf, &.{"/etc/passwd"}), &passwd) != null;
        sys.printf("selftest: /etc/passwd {s}\n", .{if (open) "readable" else "blocked"});
        return 0;
    }

    if (dry_run) sys.print("dry run: nothing will be written\n");
    if (nchips == 0) sys.print("no temperature sensors found, idling\n");

    var last = sys.nowMs();
    const started = last;
    while (!stop_requested) {
        const now = sys.nowMs();
        const dt = @as(f32, @floatFromInt(now - last)) / 1000;
        last = now;
        if (!readChips(now)) {
            emergencyRestore();
            return 1;
        }
        sampleCpuPower(now);
        step(dt);
        if (undervolted and now - started > 600_000) {
            undervolt.markStable();
            undervolted = false;
        }
        sys.sleepMs(tickMs());
    }
    if (undervolted) undervolt.markStable();
    emergencyRestore();
    return 0;
}

fn listChips() void {
    discover();
    const now = sys.nowMs();
    _ = readChips(now);
    sys.print("chip            now  limit   crit  power control\n");
    for (chips[0..nchips], 0..) |*c, index| {
        const power: []const u8 = switch (c.kind) {
            .cpu => if (cpu_power.rapl_count > 0) "rapl" else if (cpu_power.npolicies > 0) "freq" else "none",
            .gpu => if (c.cap_len > 0) "cap" else "none",
            else => "none",
        };
        _ = index;
        if (c.limit > 0) {
            sys.printf("{s:<14} {d:>4.0}  {d:>5.0}  {d:>5.0}  {s}\n", .{ c.name(), c.thermal.temp, c.limit, c.crit, power });
        } else {
            sys.printf("{s:<14} {d:>4.0}  watch  {d:>5.0}  {s}\n", .{ c.name(), c.thermal.temp, c.crit, power });
        }
    }
    var nvidia_buf: [256]u8 = undefined;
    if (sys.exists(sys.join(&nvidia_buf, &.{ sys.root, "/proc/driver/nvidia/version" }))) {
        sys.print("\nNVIDIA's proprietary driver has no sensors in /sys: that GPU is not covered\n");
    }
    if (nfans == 0) sys.print("\nno controllable fans found\n") else sys.print("\nfan                       duty    rpm\n");
    for (fans[0..nfans]) |*f| {
        var pwm_buf: [200]u8 = undefined;
        const duty = sys.readInt(f.pwmPath(&pwm_buf)) orelse -1;
        const rpm = if (f.input_fd >= 0) sys.readIntFd(f.input_fd) orelse -1 else -1;
        sys.printf("{s:<24} {d:>5}  {d:>5}\n", .{ f.name(), duty, rpm });
    }
}

const usage =
    \\zcool: keeps chips under the temperature you set, losing as little speed as it can
    \\
    \\  zcool list                what is here: chips, limits, fans
    \\  zcool run [--dry-run]     the daemon; --dry-run only says what it would do
    \\  zcool restore             puts back everything an earlier run changed
    \\  zcool undervolt           shows the current offsets
    \\  zcool undervolt off       clears them
    \\  zcool undervolt reset     forgets that a run with an offset did not end cleanly
    \\
    \\Limits and other settings live in /etc/zcool.conf, see the README.
    \\
;

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    var command: []const u8 = "";
    var sub: []const u8 = "";
    var config_path: ?[:0]const u8 = null;
    var selftest = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--selftest-sandbox")) {
            selftest = true;
        } else if (std.mem.eql(u8, arg, "--root") and i + 1 < argv.len) {
            i += 1;
            sys.root = std.mem.span(argv[i]);
        } else if (std.mem.eql(u8, arg, "--config") and i + 1 < argv.len) {
            i += 1;
            config_path = std.mem.span(argv[i]);
        } else if (command.len == 0) {
            command = arg;
        } else {
            sub = arg;
        }
    }

    if (std.mem.eql(u8, command, "restore")) {
        const n = journal.restore();
        sys.printf("restored {d} value(s)\n", .{n});
        return 0;
    }
    if (std.mem.eql(u8, command, "list")) {
        loadConfig(config_path);
        listChips();
        return 0;
    }
    if (std.mem.eql(u8, command, "run")) {
        loadConfig(config_path);
        return runDaemon(selftest);
    }
    if (std.mem.eql(u8, command, "undervolt")) {
        if (std.mem.eql(u8, sub, "off")) {
            if (undervolt.clear()) {
                sys.print("offsets cleared\n");
                return 0;
            }
            sys.print("could not clear the offsets; a reboot does\n");
            return 1;
        }
        if (std.mem.eql(u8, sub, "reset")) {
            undervolt.markStable();
            return 0;
        }
        undervolt.report();
        return 0;
    }
    sys.print(usage);
    return if (command.len == 0 or std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) 0 else 2;
}
