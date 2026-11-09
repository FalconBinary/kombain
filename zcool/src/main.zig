// SPDX-License-Identifier: GPL-3.0-or-later

//! zcool: keeps every chip under the temperature you set, with as little lost speed as possible.
//!
//! It uses what the kernel exposes in /sys: hwmon for temperatures and fans, powercap
//! and cpufreq for the CPU, a GPU's power cap, and runtime power management to let a GPU
//! that shows nothing sleep. NVIDIA's own driver has nothing there; zcool-nvidia reads it
//! through NVIDIA's library. It never takes over a chip's own protection: PROCHOT and the
//! thermal shutdown stay in hardware and keep working if this daemon is gone.

const std = @import("std");
const sys = @import("sys.zig");
const control = @import("control.zig");
const config = @import("config.zig");
const journal = @import("journal.zig");
const undervolt = @import("undervolt.zig");
const sandbox = @import("sandbox.zig");
const gpus = @import("gpus.zig");
const nvidia = @import("nvidia.zig");
const ec = @import("ec.zig");
const menu = @import("menu.zig");
const guard = @import("guard.zig");
const dump = @import("dump.zig");
const calibrate = @import("calibrate.zig");
const thermal_model = @import("model.zig");
const Text = @import("text.zig").Text;
const tcc = @import("tcc.zig");

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
    // through the registers it keeps open; the journal cannot reach /dev from the sandbox
    tcc.restore();
    if (!dry_run) _ = journal.restore();
    // zcool-nvidia puts NVIDIA's settings back when its input ends
    nvidia.closeNow();
}

const max_chips = 16;
const max_sensors = 128;
const max_fans = 16;
const max_policies = 256;
const max_packages = 8;
/// Failed takeovers before a fan is left to the firmware: about 5 s at the 250 ms tick.
const take_tries = 20;

const Kind = enum { cpu, gpu, nvme, other };
const Backend = enum { hwmon, nvidia };
/// How a NVIDIA GPU is held under its limit, found the first time it is needed.
const Lever = enum { unknown, limit, clocks, none };
/// zcool-nvidia's answers take a library call; once a second is plenty for a GPU.
const nvidia_period_ms = 1000;

const Nv = struct {
    /// a first reading came in: the limits, clocks and fans the driver reports are known
    known: bool = false,
    util: u32 = 0,
    power_mw: u32 = 0,
    limit: u32 = 0,
    limit_min: u32 = 0,
    limit_max: u32 = 0,
    max_clock: u32 = 0,
    reference: u32 = 0,
    lever: Lever = .unknown,
    /// a limit is set and not yet given back
    changed: bool = false,
    /// the helper has let go of the driver, so the GPU can sleep
    rested: bool = false,
    fan: [nvidia.max_fans]u8 = @splat(0),
};

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
    /// the limit before the power source moves it
    base_limit: f32 = 0,
    crit: f32 = 0,
    thermal: control.Thermal = .{},
    throttle: control.Throttle = .{},
    quiet: control.Quiet = .{},
    learned: control.Learned = .{},
    /// how hard its fans run
    drive: control.FanDrive = .{},
    learned_logged: bool = false,
    /// what was last written to disk
    learned_saved: f32 = 0,
    quiet_logged: bool = false,
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
    /// the last raw reading, the model's view of the sink, and what the model is learning: a jump
    /// of the die under way, and how long the chip has stood steady
    raw: f32 = 0,
    sink: thermal_model.Observer = .{},
    last_raw: f32 = 0,
    last_watts: f32 = -1,
    jump: thermal_model.Jump = .{},
    watts_ema: f32 = -1,
    die_ema: f32 = 0,
    die_dev: f32 = 0,
    duty_ema: f32 = 0,
    steady_for: f32 = 0,
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
    backend: Backend = .hwmon,
    /// for a GPU, its place in gpus.list
    gpu: i8 = -1,
    /// it may sleep: read only as often as needed, so that it can
    sleepy: bool = false,
    nv: Nv = .{},
    /// a NVIDIA GPU its library cannot read, read through an MSI laptop's EC instead
    ec_temp: bool = false,
    /// what NVIDIA's library last answered instead of a reading
    nv_error: [48]u8 = undefined,
    nv_error_len: u8 = 0,

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
    take_failures: u8 = 0,
    orig_pwm: i64 = 0,
    orig_enable: i64 = 0,
    floor: f32 = 0,
    written: i64 = -1,
    ctl: control.Fan = .{},
    stalled_for: f32 = 0,
    stall_logged: bool = false,
    /// a fan NVIDIA's driver runs: zcool-nvidia sets it, in percent
    nv_index: i8 = -1,
    /// an MSI laptop's Cooler Boost: both fans at full, or the firmware's curve
    ec_boost: bool = false,
    /// an MSI laptop's fans through a curve of zcool's own, with Cooler Boost on top
    ec_curve: bool = false,
    boost_on: bool = false,
    /// how long Cooler Boost has been on: the fans take a while to get there
    full_for: f32 = 0,

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

const Policy = struct {
    index: u16,
    original: i64,
    min: i64,
    max: i64,
    /// its energy preference, as it was before zcool, when it has one
    epp: [24]u8 = undefined,
    epp_len: u8 = 0,
    epp_saved: bool = false,
};

const CpuPower = struct {
    rapl_count: u8 = 0,
    rapl_base: [max_packages]i64 = undefined,
    rapl_index: [max_packages]u8 = undefined,
    rapl_original: [max_packages]i64 = undefined,
    rapl_energy_fd: [max_packages]i32 = undefined,
    rapl_energy: [max_packages]i64 = undefined,
    rapl_watts: [max_packages]f32 = undefined,
    /// the last half second's reading itself, for the model: the average above lags a jump
    rapl_watts_raw: [max_packages]f32 = undefined,
    rapl_reference: [max_packages]f32 = undefined,
    rapl_sampled_ms: i64 = 0,
    rapl_saved: bool = false,
    /// the short-term limit (PL2), which the CPU may burst to for the long one's whole window
    pl2: [max_packages]bool = @splat(false),
    pl2_original: [max_packages]i64 = @splat(0),
    /// the most it may be: the firmware's, or the power source's `burst`
    pl2_setting: [max_packages]i64 = @splat(0),
    /// what it is held to now: the setting, or less while the machine's model says the sink
    /// cannot take more
    pl2_cap: [max_packages]i64 = @splat(0),
    pl2_saved: [max_packages]bool = @splat(false),
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
/// `zcool list`: what the daemon says as it goes is left out of the tables.
var listing: bool = false;

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
                if (kind == .gpu) {
                    setUpGpu(c, base);
                    if (gpus.forHwmon(base)) |g| {
                        c.gpu = @intCast(g);
                        c.sleepy = gpus.list[g].may_sleep and !gpus.list[g].boot;
                    }
                }
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
    // amdgpu calls its power limit power1_cap, Intel's discrete GPUs power1_max
    for ([_][]const u8{ "/power1_cap", "/power1_max" }) |file| {
        const cap = sys.join(&path_buf, &.{ base, file });
        if (cap.len == 0 or cap.len > c.cap_path.len) continue;
        const value = sys.readInt(cap) orelse continue;
        if (value <= 0) continue;
        @memcpy(c.cap_path[0..cap.len], cap);
        c.cap_len = @intCast(cap.len);
        c.cap_base = value;
        c.cap_min = sys.readInt(sys.join(&path_buf, &.{ base, file, "_min" })) orelse 0;
        c.cap_reference = value;
        c.power_fd = sys.openRead(sys.join(&path_buf, &.{ base, "/power1_average" })) orelse
            sys.openRead(sys.join(&path_buf, &.{ base, "/power1_input" })) orelse -1;
        break;
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
        setLimit(c, control.clampLimit(wanted, crit, fallback));
        if (c.base_limit != wanted) {
            sys.printf("{s}: limit {d:.0} is outside the safe range, using {d:.0}\n", .{ c.name(), wanted, c.base_limit });
        }
        return;
    }
    setLimit(c, switch (c.kind) {
        .cpu => if (crit > 0) @min(90, crit - 10) else 90,
        .gpu => if (crit > 0) crit - 15 else 85,
        .nvme => if (crit > 0) crit - 10 else 70,
        .other => 0, // watched only: board sensors are often not worth a fan spike
    });
}

/// The power source moves every limit by this, 0 or lower.
var shift_now: f32 = 0;

fn setLimit(c: *Chip, limit: f32) void {
    c.base_limit = limit;
    c.limit = if (limit > 0) @max(30, limit + shift_now) else 0;
}

fn discoverCpuPower() void {
    var path_buf: [256]u8 = undefined;
    var dir_buf: [256]u8 = undefined;
    var i: u8 = 0;
    while (i < 16 and cpu_power.rapl_count < max_packages) : (i += 1) {
        var num: [4]u8 = undefined;
        const digits = std.fmt.bufPrint(&num, "{d}", .{i}) catch break;
        const limit = sys.readInt(sys.join(&path_buf, &.{ sys.root, "/sys/class/powercap/intel-rapl:", digits, "/constraint_0_power_limit_uw" })) orelse break;
        // psys is the whole platform's power, the GPU's with it: only a package is the CPU's
        var zone_buf: [32]u8 = undefined;
        if (sys.readFile(sys.join(&path_buf, &.{ sys.root, "/sys/class/powercap/intel-rapl:", digits, "/name" }), &zone_buf)) |zone| {
            if (!std.mem.startsWith(u8, zone, "package")) continue;
        }
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
        cpu_power.rapl_watts_raw[n] = 0;
        cpu_power.rapl_reference[n] = @floatFromInt(base);
        var name_buf: [32]u8 = undefined;
        const name = sys.readFile(sys.join(&path_buf, &.{ sys.root, "/sys/class/powercap/intel-rapl:", digits, "/constraint_1_name" }), &name_buf) orelse "";
        if (std.mem.eql(u8, std.mem.trim(u8, name, " \n"), "short_term")) {
            const pl2 = sys.readInt(sys.join(&path_buf, &.{ sys.root, "/sys/class/powercap/intel-rapl:", digits, "/constraint_1_power_limit_uw" })) orelse 0;
            cpu_power.pl2[n] = pl2 > 0 and pl2 < 1_000_000_000;
            cpu_power.pl2_original[n] = pl2;
            cpu_power.pl2_setting[n] = pl2;
            cpu_power.pl2_cap[n] = pl2;
        }
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
        var policy = Policy{ .index = index, .original = original, .min = least, .max = most };
        var epp_buf: [32]u8 = undefined;
        if (sys.readFile(policyPath(&path_buf, digits, "energy_performance_preference"), &epp_buf)) |text| {
            const name = std.mem.trim(u8, text, " \t\r\n");
            if (name.len > 0 and name.len <= policy.epp.len) {
                @memcpy(policy.epp[0..name.len], name);
                policy.epp_len = @intCast(name.len);
            }
        }
        cpu_power.policies[cpu_power.npolicies] = policy;
        cpu_power.npolicies += 1;
    }
    discoverTurbo();
}

/// Turbo is one switch for the whole CPU: intel_pstate's no_turbo, or cpufreq's boost.
const Turbo = struct {
    path: [256]u8 = undefined,
    len: u8 = 0,
    /// intel_pstate's switch says the opposite: 1 is off
    inverted: bool = false,
    original: i64 = -1,
    saved: bool = false,
};
var turbo = Turbo{};

fn discoverTurbo() void {
    for ([_]struct { file: []const u8, inverted: bool }{
        .{ .file = "/sys/devices/system/cpu/intel_pstate/no_turbo", .inverted = true },
        .{ .file = "/sys/devices/system/cpu/cpufreq/boost", .inverted = false },
    }) |candidate| {
        var path_buf: [256]u8 = undefined;
        const path = sys.join(&path_buf, &.{ sys.root, candidate.file });
        const value = sys.readInt(path) orelse continue;
        @memcpy(turbo.path[0..path.len], path);
        turbo.len = @intCast(path.len);
        turbo.inverted = candidate.inverted;
        turbo.original = value;
        return;
    }
}

fn turboOn() ?bool {
    if (turbo.len == 0) return null;
    var path_buf: [260]u8 = undefined;
    const value = sys.readInt(sys.join(&path_buf, &.{turbo.path[0..turbo.len]})) orelse return null;
    return (value == 1) != turbo.inverted;
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
    addNvidiaChips();
    addEcFan();
}

/// An MSI laptop's EC: its fans join as the board's, which cool every chip. Through a curve of
/// zcool's own they run at any speed, with Cooler Boost past full; without it only Cooler
/// Boost, which is full or the firmware's curve.
fn addEcFan() void {
    if (!cfg.use_ec) return;
    ec.open();
    const l = ec.layout orelse return;
    if (!ec.writable or nfans == max_fans) return;
    var fan = Fan{ .owner = -1 };
    if (cfg.fan_curve and l.curve != null and !cfg.isExcluded("ec/fans")) {
        fan.ec_curve = true;
        nameFan(&fan, "ec/fans");
    } else {
        if (cfg.isExcluded("ec/cooler_boost")) return;
        fan.ec_boost = true;
        nameFan(&fan, "ec/cooler_boost");
    }
    fans[nfans] = fan;
    nfans += 1;
}

fn nameFan(fan: *Fan, id: []const u8) void {
    @memcpy(fan.id[0..id.len], id);
    fan.id_len = @intCast(id.len);
}

/// A GPU on NVIDIA's own driver. Its limits and fans come with the first reading, which is
/// not taken while it sleeps.
fn addNvidiaChips() void {
    for (gpus.list[0..gpus.count], 0..) |*g, i| {
        if (!g.proprietary() or nchips == max_chips) continue;
        var path_buf: [256]u8 = undefined;
        if (!sys.exists(sys.join(&path_buf, &.{ sys.root, "/proc/driver/nvidia/gpus/", g.address(), "/information" }))) continue;
        chips[nchips] = .{ .kind = .gpu, .backend = .nvidia, .gpu = @intCast(i) };
        const c = &chips[nchips];
        setId(c, "gpu{d}", .{count_of[@backingInt(Kind.gpu)]});
        count_of[@backingInt(Kind.gpu)] += 1;
        c.sleepy = g.may_sleep and !g.boot;
        c.period_ms = nvidia_period_ms;
        c.runtime_fd = sys.openRead(gpus.devicePath(&path_buf, g.address(), "power/runtime_status")) orelse -1;
        nchips += 1;
    }
}

fn hasNvidia() bool {
    for (chips[0..nchips]) |*c| if (c.backend == .nvidia) return true;
    return false;
}

fn busOf(c: *const Chip) []const u8 {
    return gpus.list[@intCast(c.gpu)].address();
}

/// Sends a request that changes something; true when zcool-nvidia says it took.
fn helperDid(comptime fmt: []const u8, args: anytype) bool {
    var buf: [96]u8 = undefined;
    const request = std.fmt.bufPrint(&buf, fmt, args) catch return false;
    const reply = nvidia.ask(request, 5000) orelse return false;
    return std.mem.eql(u8, reply, "ok");
}

/// What the driver says, and the first time also what it allows: the limit follows from its thresholds.
fn readNvidia(c: *Chip, index: usize) ?f32 {
    var buf: [48]u8 = undefined;
    const request = std.fmt.bufPrint(&buf, "read {s}", .{busOf(c)}) catch return null;
    const line = nvidia.ask(request, 5000) orelse return fromEc(c);
    const r = nvidia.parse(line) orelse {
        const n = @min(line.len, c.nv_error.len);
        if (!std.mem.eql(u8, c.nv_error[0..c.nv_error_len], line[0..n])) {
            @memcpy(c.nv_error[0..n], line[0..n]);
            c.nv_error_len = @intCast(n);
            if (!listing) sys.printf("{s}: NVIDIA's library answers \"{s}\"\n", .{ c.name(), line[0..n] });
        }
        return fromEc(c);
    };
    c.nv_error_len = 0;
    c.nv.util = r.util orelse 0;
    c.nv.power_mw = r.power_mw orelse 0;
    c.nv.fan = r.fan;
    c.nv.rested = false;
    if (!c.nv.known) {
        c.nv.known = true;
        // its own library reads it now: what the EC stood in for is over
        c.ec_temp = false;
        c.no_actuator = false;
        const slowdown = r.slowdown orelse 0;
        c.crit = if (slowdown >= 50 and slowdown <= 130) slowdown else 0;
        if (cfg.limitFor(c.name())) |wanted| {
            setLimit(c, control.clampLimit(wanted, c.crit, 100));
            if (c.base_limit != wanted) sys.printf("{s}: limit {d:.0} is outside the safe range, using {d:.0}\n", .{ c.name(), wanted, c.base_limit });
        } else {
            // the driver's own target, when it gives one with room below the slowdown point
            const own = r.gpu_max orelse 0;
            setLimit(c, if (c.crit > 0 and own >= 50 and own <= c.crit - 5) own else if (c.crit > 0) c.crit - 15 else 85);
        }
        c.nv.limit = r.limit orelse 0;
        c.nv.limit_min = r.limit_min orelse 0;
        c.nv.limit_max = r.limit_max orelse 0;
        c.nv.max_clock = r.max_clock orelse 0;
        addNvidiaFans(c, index, r.fans);
        if (!listing) {
            if (r.fans == 0) {
                sys.printf("{s}: NVIDIA at {s}, limit {d:.0}C, shares the board's fans\n", .{ c.name(), busOf(c), c.limit });
            } else {
                sys.printf("{s}: NVIDIA at {s}, limit {d:.0}C, {d} fan(s) of its own\n", .{ c.name(), busOf(c), c.limit, r.fans });
            }
        }
    }
    if (c.crit > 0 and r.temp >= c.crit - 3) c.emergency = true;
    return r.temp;
}

/// When NVIDIA's library cannot read its GPU, an MSI laptop's EC still can, and then the
/// fans can help it: the EC has one GPU temperature, so only with a single NVIDIA GPU.
fn fromEc(c: *Chip) ?f32 {
    if (c.nv.known or !cfg.use_ec) return null;
    var count: usize = 0;
    for (chips[0..nchips]) |*other| {
        if (other.backend == .nvidia) count += 1;
    }
    if (count != 1) return null;
    ec.open();
    const t = ec.gpuTemperature() orelse return null;
    if (!c.ec_temp) {
        c.ec_temp = true;
        c.no_actuator = true;
        if (c.limit == 0) setLimit(c, control.clampLimit(cfg.limitFor(c.name()) orelse 85, 0, 95));
        if (!listing) sys.printf("{s}: read through the EC instead, limit {d:.0}C, fans only\n", .{ c.name(), c.limit });
    }
    return t;
}

fn addNvidiaFans(c: *Chip, index: usize, count: u8) void {
    var i: u8 = 0;
    while (i < count and nfans < max_fans) : (i += 1) {
        var id_buf: [40]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "{s}/fan{d}", .{ c.name(), i }) catch return;
        if (cfg.isExcluded(id)) continue;
        var fan = Fan{ .owner = @intCast(index), .nv_index = @intCast(i) };
        @memcpy(fan.id[0..id.len], id);
        fan.id_len = @intCast(id.len);
        fans[nfans] = fan;
        nfans += 1;
        c.own_fans = true;
    }
}

// ---------------------------------------------------------------- actuators

/// Each value is read once: what the journal keeps is what `releaseFan` writes back.
fn takeFan(fan: *Fan) bool {
    if (fan.ec_curve) return takeCurve(fan);
    if (fan.ec_boost) {
        // on already, from the key on the keyboard say: it stays on
        const on = ec.boost() orelse return false;
        fan.floor = if (on) 255 else 0;
        fan.ctl = .{ .duty = fan.floor };
        fan.written = @intFromBool(on);
        if (dry_run) return true;
        if (!fan.journaled) {
            const l = ec.layout.?;
            var path_buf: [256]u8 = undefined;
            if (!journal.rememberByte(ec.path(&path_buf), l.boost, l.boost_bit, @intFromBool(on))) return false;
            fan.orig_pwm = @intFromBool(on);
            fan.journaled = true;
        }
        return true;
    }
    if (fan.nv_index >= 0) {
        // never below what the driver runs it at now, like any other fan
        fan.floor = @as(f32, @floatFromInt(chips[@intCast(fan.owner)].nv.fan[@intCast(fan.nv_index)])) * 255 / 100;
        fan.ctl = .{ .duty = fan.floor };
        fan.written = -1;
        return true;
    }
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
            if (!journal.rememberInt(fan.enablePath(&enable_buf), fan.orig_enable)) return false;
        }
        fan.orig_pwm = current;
        if (!journal.rememberInt(pwm, current)) return false;
        fan.journaled = true;
    }
    if (fan.enable_len > 0 and !sys.writeInt(fan.enablePath(&enable_buf), 1)) return false;
    return true;
}

fn releaseFan(fan: *Fan) void {
    fan.managed = false;
    if (dry_run) return;
    if (fan.ec_curve) return restoreCurve(fan);
    if (fan.ec_boost) {
        _ = ec.setBoost(fan.orig_pwm != 0);
        return;
    }
    if (fan.nv_index >= 0) {
        const c = &chips[@intCast(fan.owner)];
        // asleep, the GPU has dropped it already, and asking would wake it
        if (!c.asleep) _ = helperDid("fan {s} {d} auto", .{ busOf(c), fan.nv_index });
        return;
    }
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
    fan.full_for = if (fan.ec_boost and fan.managed and fan.written == 1) fan.full_for + dt else 0;
    if (fan.unusable) return;
    if (!fan.managed) {
        if (demand <= 0) return;
        if (!takeFan(fan)) {
            // a driver can fail one read and answer the next; until it is given up the fan
            // still counts as cooling to come, so power is not taken in its place
            fan.take_failures +|= 1;
            if (fan.take_failures == 1) sys.printf("{s}: did not answer, trying again\n", .{fan.name()});
            if (fan.take_failures < take_tries) return;
            fan.unusable = true;
            sys.printf("{s}: cannot be controlled, leaving it to the firmware\n", .{fan.name()});
            return;
        }
        fan.take_failures = 0;
        fan.managed = true;
        if (fan.ec_boost) {
            sys.printf("{s}: taking over, it was {s}\n", .{ fan.name(), if (fan.written == 1) "on" else "off" });
        } else if (fan.ec_curve) {
            sys.printf("{s}: taking over from {d:.0}%{s}\n", .{ fan.name(), fan.floor * 100 / 255, if (fan.boost_on) ", Cooler Boost on" else "" });
        } else {
            sys.printf("{s}: taking over from {d:.0}/255\n", .{ fan.name(), fan.floor });
        }
    }
    fan.ctl.update(fan.floor, demand, dt);
    if (fan.ctl.canRelease()) {
        sys.printf("{s}: back to the firmware\n", .{fan.name()});
        releaseFan(fan);
        return;
    }
    if (fan.ec_boost) return updateBoost(fan);
    if (fan.ec_curve) return updateCurve(fan, dt);
    const duty: i64 = @intFromFloat(@round(fan.ctl.duty));
    if (fan.written < 0 or @abs(duty - fan.written) >= 2 or (duty == 255 and fan.written != 255)) {
        if (!dry_run) {
            var pwm_buf: [200]u8 = undefined;
            const done = if (fan.nv_index >= 0)
                helperDid("fan {s} {d} {d}", .{ busOf(&chips[@intCast(fan.owner)]), fan.nv_index, @divTrunc(duty * 100 + 127, 255) })
            else
                sys.writeInt(fan.pwmPath(&pwm_buf), duty);
            if (!done) {
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

// ---------------------------------------------------------------- an MSI laptop's fans by zcool's curve

/// What the EC held before zcool's curve: its fan mode and each fan's curve, put back when
/// zcool lets go. Also in the journal, for whatever ends zcool.
var curve_mode: u8 = 0;
var curve_original: [2][ec.curve_len]u8 = undefined;
/// What calibration says the board's fans need for what the CPU draws now, held at its fan point,
/// as a demand over the speed zcool took them from. Null while nothing tells.
fn calibratedNeed(c: *const Chip, index: usize) ?f32 {
    if (c.kind != .cpu or !cal.known()) return null;
    const duty = cal.fanDuty(chipWatts(c) orelse return null, c.limit - control.fan_margin) orelse return null;
    for (fans[0..nfans]) |*f| {
        if (f.unusable or !f.managed or f.owner >= 0 or !fanServes(f, index)) continue;
        return std.math.clamp((duty - f.floor) / @max(255 - f.floor, 1), 0, 1);
    }
    return null;
}

/// zcool's curve runs a fan at full this far over the highest limit of its chips, by the EC alone
const curve_safe_above: f32 = 8;
/// a fan the EC has been seen turning: only then does an RPM of 0 mean it stands still
var rpm_seen: [2]bool = .{ false, false };
/// Cooler Boost on top of the curve once it is at full, off again below this: well below, or
/// it goes off as soon as the power taken brings the chip back, and on again with the next heat
const curve_boost_off: f32 = 191;

/// The EC reads the CPU for the first fan's curve and the GPU for the second's.
fn curveSafePoint(fan: usize) u8 {
    var highest: f32 = 0;
    var any: f32 = 0;
    for (chips[0..nchips]) |*c| {
        if (!c.controlled()) continue;
        const limit = @max(c.base_limit, c.limit);
        any = @max(any, limit);
        if (c.kind == (if (fan == 0) Kind.cpu else Kind.gpu)) highest = @max(highest, limit);
    }
    if (highest == 0) highest = if (any > 0) any else 85;
    return @intFromFloat(std.math.clamp(highest + curve_safe_above, 60, 98));
}

fn takeCurve(fan: *Fan) bool {
    const l = ec.layout.?;
    const c = &l.curve.?;
    const mode = ec.read(l.fan_mode) orelse return false;
    if (mode == c.advanced and !fan.journaled) {
        // a curve someone chose in MSI's tools: it stays theirs
        sys.printf("{s}: the EC runs a fan curve someone chose, zcool keeps to Cooler Boost\n", .{fan.name()});
        return boostInstead(fan);
    }
    const r = ec.readings() orelse return false;
    const on = ec.boost() orelse return false;
    var originals: [2][ec.curve_len]u8 = undefined;
    for (0..2) |i| if (!ec.readCurve(c, i, &originals[i])) return false;
    // never below what the firmware runs them at now, and a boost already on stays on
    const speed: f32 = @floatFromInt(@min(@max(r.cpu_fan, r.gpu_fan), 100));
    fan.floor = if (on) 255 else speed * 255 / 100;
    fan.ctl = .{ .duty = fan.floor };
    fan.boost_on = on;
    fan.written = -1;
    if (dry_run) return true;
    if (!fan.journaled) {
        var path_buf: [256]u8 = undefined;
        const p = ec.path(&path_buf);
        // the mode first: newest first on the way back, so it goes back last, onto its own curve
        if (!journal.rememberByte(p, l.fan_mode, null, mode)) return false;
        for (0..2) |i| for (0..ec.curve_len) |k| {
            if (!journal.rememberByte(p, ec.curveAddr(c, i, k), null, originals[i][k])) return false;
        };
        if (!journal.rememberByte(p, l.boost, l.boost_bit, @intFromBool(on))) return false;
        fan.orig_pwm = @intFromBool(on);
        curve_original = originals;
        // the silent curve was zcool's: the one before it goes back
        curve_mode = fan_mode_original orelse mode;
        fan.journaled = true;
    }
    // the curve holds the mode byte now; the silent curve may come back once it lets go
    silent_now = false;
    const percent: u8 = @intFromFloat(@round(fan.floor * 100 / 255));
    if (!setCurve(percent)) {
        restoreCurve(fan);
        sys.printf("{s}: the EC did not take zcool's curve, zcool keeps to Cooler Boost\n", .{fan.name()});
        return boostInstead(fan);
    }
    fan.written = percent;
    return true;
}

/// Every fan at `percent` below the safe point, and the mode that runs the curve.
fn setCurve(percent: u8) bool {
    const l = ec.layout.?;
    const c = &l.curve.?;
    for (0..2) |i| {
        const bytes = ec.ownCurve(percent, curveSafePoint(i));
        if (!ec.writeCurve(c, i, &bytes)) return false;
    }
    if (!ec.write(l.fan_mode, c.advanced)) return false;
    return ec.read(l.fan_mode) == c.advanced and ec.read(c.speeds[0]) == percent;
}

fn restoreCurve(fan: *Fan) void {
    if (dry_run or !fan.journaled) return;
    const l = ec.layout.?;
    for (0..2) |i| _ = ec.writeCurve(&l.curve.?, i, &curve_original[i]);
    _ = ec.write(l.fan_mode, curve_mode);
    _ = ec.setBoost(fan.orig_pwm != 0);
    fan.boost_on = fan.orig_pwm != 0;
}

/// The fans as Cooler Boost alone, as zcool ran them before it had curves.
fn boostInstead(fan: *Fan) bool {
    fan.ec_curve = false;
    fan.ec_boost = true;
    nameFan(fan, "ec/cooler_boost");
    if (cfg.isExcluded("ec/cooler_boost")) {
        fan.unusable = true;
        return false;
    }
    return takeFan(fan);
}

fn updateCurve(fan: *Fan, dt: f32) void {
    const l = ec.layout.?;
    const c = &l.curve.?;
    const percent: u8 = @intFromFloat(@round(fan.ctl.duty * 100 / 255));
    if (!dry_run and ec.read(l.fan_mode) != c.advanced) {
        // the EC goes back to its own curve by itself, as the power source changes say
        sys.printf("{s}: the EC went back to its own curve, zcool's again\n", .{fan.name()});
        if (!setCurve(percent)) return curveFailed(fan);
        fan.written = percent;
        if (fan.boost_on and ec.boost() == false and !ec.setBoost(true)) return curveFailed(fan);
    }
    if (fan.written < 0 or @abs(@as(i64, percent) - fan.written) >= 2 or (percent == 100 and fan.written != 100)) {
        if (!dry_run) {
            for (c.speeds) |addr| if (!ec.write(addr, percent)) return curveFailed(fan);
        }
        fan.written = percent;
    }
    // past full: Cooler Boost, and off only once the fans have come well down
    const allowed = !boost_barred and (!boost_useless or boost_rescue);
    const boost = allowed and (if (fan.ctl.duty >= 254) true else if (fan.ctl.duty < curve_boost_off) false else fan.boost_on);
    if (boost != fan.boost_on) {
        if (!dry_run and !ec.setBoost(boost)) return curveFailed(fan);
        sys.printf("{s}: Cooler Boost {s}\n", .{ fan.name(), if (boost) "on, every fan past full" else "off" });
        fan.boost_on = boost;
    }
    if (percent < 50) {
        fan.stalled_for = 0;
        return;
    }
    var still: ?usize = null;
    for (0..2) |i| {
        const rpm = ec.rpm(i) orelse continue;
        if (rpm > 0) rpm_seen[i] = true else if (rpm_seen[i]) still = i;
    }
    fan.stalled_for = if (still != null) fan.stalled_for + dt else 0;
    if (fan.stalled_for >= 5 and !fan.stall_logged) {
        sys.printf("{s}: the {s} fan is set to {d}% and not turning. Check this fan\n", .{ fan.name(), ec.fan_names[still.?], percent });
        fan.stall_logged = true;
    }
}

fn curveFailed(fan: *Fan) void {
    sys.printf("{s}: write failed, leaving it to the firmware\n", .{fan.name()});
    releaseFan(fan);
    fan.unusable = true;
}

/// Cooler Boost has two speeds: on near the limit, and off only once the fans would have come
/// well down, so that it does not switch back and forth around one temperature.
const boost_on: f32 = 191;
const boost_off: f32 = 64;

fn updateBoost(fan: *Fan) void {
    const on: i64 = if (fan.ctl.duty >= boost_on) 1 else if (fan.ctl.duty < boost_off) 0 else fan.written;
    if (on == fan.written) return;
    if (!dry_run and !ec.setBoost(on == 1)) {
        sys.printf("{s}: write failed, leaving it to the firmware\n", .{fan.name()});
        releaseFan(fan);
        fan.unusable = true;
        return;
    }
    sys.printf("{s}: {s}\n", .{ fan.name(), if (on == 1) "on, both fans at full" else "off, the firmware's curve again" });
    fan.written = on;
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
            cpu_power.rapl_watts_raw[i] = watts;
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
        // back up: the short-term limit first, so the long one is never above it
        if (level >= 1) setPl2(i, null);
        if (!sys.writeInt(path, target)) return false;
        // some firmware takes the write and keeps its own value
        const back = sys.readInt(path) orelse return false;
        if (@abs(back - target) > @divTrunc(target, 20)) return false;
        // down: the short-term limit with it, or the CPU bursts to it for the long one's whole window
        if (level < 1) setPl2(i, target);
    }
    cpu_power.rapl_saved = true;
    return true;
}

/// The short-term limit of package `i`: `target`, or with null what it was.
fn setPl2(i: usize, target: ?i64) void {
    if (!cpu_power.pl2[i]) return;
    var path_buf: [256]u8 = undefined;
    var num: [4]u8 = undefined;
    const digits = std.fmt.bufPrint(&num, "{d}", .{cpu_power.rapl_index[i]}) catch return;
    const path = sys.join(&path_buf, &.{ sys.root, "/sys/class/powercap/intel-rapl:", digits, "/constraint_1_power_limit_uw" });
    const cap = cpu_power.pl2_cap[i];
    if (!cpu_power.pl2_saved[i]) {
        if (target == null and cap == cpu_power.pl2_original[i]) return;
        if (!journal.remember(path)) {
            cpu_power.pl2[i] = false;
            return;
        }
        cpu_power.pl2_saved[i] = true;
    }
    const value = @min(target orelse cap, cap);
    const back = if (sys.writeInt(path, value)) sys.readInt(path) else null;
    if ((target != null or cap != cpu_power.pl2_original[i]) and (back == null or @abs(back.? - value) > @divTrunc(value, 20))) {
        sys.print("cpu: the short-term power limit does not stick here, the long-term one alone holds it\n");
        _ = sys.writeInt(path, cpu_power.pl2_original[i]);
        cpu_power.pl2[i] = false;
    }
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

/// The package draws well above the limit it was given, or its energy cannot be read to tell.
fn powerOverLimit() bool {
    if (cpu_power.applied >= 1) return false;
    for (0..cpu_power.rapl_count) |i| {
        if (cpu_power.rapl_energy_fd[i] < 0 or cpu_power.rapl_energy[i] < 0) return true;
        const limit_mw = cpu_power.rapl_reference[i] * cpu_power.applied / 1000;
        if (cpu_power.rapl_watts[i] > limit_mw * 1.15) return true;
    }
    return false;
}

/// A power limit can be accepted and then have no effect. If the temperature stays over the
/// limit in spite of it, the power limits go back and frequency limits hold the chip from then
/// on: two levers that act at different speeds would swing it between full and cut.
fn watchEscalation(hottest_over: bool, dt: f32) void {
    if (cpu_power.rapl_count == 0 or cpu_power.escalated) return;
    // over the limit while drawing what the limit allows is a slow cooler, not an ignored limit
    cpu_power.over_for = if (hottest_over and powerOverLimit()) cpu_power.over_for + dt else 0;
    if (cpu_power.over_for >= 3 and cpu_power.npolicies > 0) {
        cpu_power.escalated = true;
        sys.print("cpu: the power limit is not holding the temperature, frequency limits hold it from now on\n");
        if (!dry_run) {
            _ = applyRapl(1, false);
            applyFreq(cpu_power.applied);
            cpu_power.freq_active = true;
        }
        cpu_power.rapl_count = 0;
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

fn nvLimit(c: *Chip, level: f32, starting: bool) bool {
    if (c.nv.limit_max == 0 or c.nv.limit_min >= c.nv.limit_max) return false;
    if (level >= 1) return helperDid("limit {s} default", .{busOf(c)});
    // a limit far above what the GPU draws does nothing: start from the real power
    if (starting) c.nv.reference = if (c.nv.power_mw > 5000) @min(c.nv.power_mw, c.nv.limit) else c.nv.limit;
    const wanted: u32 = @intFromFloat(@as(f32, @floatFromInt(c.nv.reference)) * level);
    return helperDid("limit {s} {d}", .{ busOf(c), std.math.clamp(wanted, c.nv.limit_min, c.nv.limit_max) });
}

fn nvClocks(c: *Chip, level: f32) bool {
    if (c.nv.max_clock == 0) return false;
    if (level >= 1) return helperDid("clocks {s} reset", .{busOf(c)});
    const wanted: u32 = @intFromFloat(@as(f32, @floatFromInt(c.nv.max_clock)) * level);
    return helperDid("clocks {s} {d}", .{ busOf(c), wanted });
}

/// A power limit where the driver takes one (desktop cards); a clock limit where it does
/// not (most laptops); else the GPU is left to its own protection.
fn applyNvidia(c: *Chip, level: f32) void {
    if (!c.nv.known or c.nv.lever == .none) return;
    if (level == c.cap_applied or (level < 1 and @abs(level - c.cap_applied) < 0.01)) return;
    const starting = c.cap_applied >= 1;
    c.cap_applied = level;
    if (level >= 1 and !c.nv.changed) return;
    if (dry_run) return;
    switch (c.nv.lever) {
        .unknown => {
            if (nvLimit(c, level, starting)) {
                c.nv.lever = .limit;
            } else if (nvClocks(c, level)) {
                c.nv.lever = .clocks;
            } else {
                c.nv.lever = .none;
                c.no_actuator = true;
                sys.printf("{s}: the driver takes no power or clock limit: fans and its own protection only\n", .{c.name()});
                return;
            }
            sys.printf("{s}: holding it with {s}\n", .{ c.name(), if (c.nv.lever == .limit) "its power limit" else "a clock limit" });
        },
        .limit => _ = nvLimit(c, level, starting),
        .clocks => _ = nvClocks(c, level),
        .none => return,
    }
    c.nv.changed = level < 1;
}

// ---------------------------------------------------------------- the loop

/// Its state comes from the kernel, which reads nothing from the GPU: this does not wake it.
fn isAsleep(c: *const Chip) bool {
    var state: [16]u8 = undefined;
    const n = sys.pread(c.runtime_fd, &state, 0) orelse 0;
    return n >= 9 and std.mem.startsWith(u8, state[0..n], "suspended");
}

fn owns(fan: *const Fan, index: usize) bool {
    return fan.owner >= 0 and @as(usize, @intCast(fan.owner)) == index;
}

fn ownFansHeld(index: usize) bool {
    for (fans[0..nfans]) |*f| if (owns(f, index) and f.managed) return true;
    return false;
}

fn readChips(now: i64) bool {
    for (chips[0..nchips], 0..) |*c, index| {
        if (c.runtime_fd >= 0) {
            // reading a sensor would wake a sleeping GPU and waste more power than it saves
            const asleep = isAsleep(c);
            if (asleep != c.asleep) {
                c.asleep = asleep;
                if (asleep) {
                    // whatever was set on it is gone with its power, or comes back on its own
                    if (c.nv.changed) c.cap_applied = -1;
                } else {
                    // awake again, maybe for a game: look at once
                    c.period_ms = if (c.backend == .nvidia) nvidia_period_ms else 0;
                    c.due_ms = now;
                }
            }
            if (asleep) continue;
        }
        if (now < c.due_ms) continue;
        c.due_ms = now + c.period_ms;
        var reading: ?f32 = null;
        c.emergency = false;
        if (c.backend == .nvidia) {
            reading = readNvidia(c, index);
        } else {
            var best: f32 = -1000;
            var primary: f32 = -1000;
            for (sensors[0..nsensors]) |*s| {
                if (s.chip != index) continue;
                const milli = sys.readIntFd(s.fd) orelse continue;
                const t = @as(f32, @floatFromInt(milli)) / 1000;
                // some inputs are not wired to anything and read 0 or 127
                if (t <= 0 or t >= 125) continue;
                s.last = t;
                best = @max(best, t);
                if (s.primary) primary = t;
                if (s.crit > 0 and t >= s.crit - 3) c.emergency = true;
            }
            if (best > -1000) reading = if (c.has_primary and primary > -1000) primary else best;
        }
        if (reading == null) {
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
        c.raw = reading.?;
        c.thermal.update(reading.?, dt);
        if (c.sleepy) pace(c, index, now);
    }
    return true;
}

/// A GPU that may sleep is read less often while it has nothing to do, and NVIDIA's library
/// is let go of: each read would keep it awake.
fn pace(c: *Chip, index: usize, now: i64) void {
    const limit = if (c.controlled()) c.limit else 85;
    const quiet = control.isQuiet(c.thermal.forecast(), limit, c.throttle.level, ownFansHeld(index)) and c.nv.util == 0;
    c.period_ms = control.readPeriod(c.period_ms, if (c.backend == .nvidia) nvidia_period_ms else 0, quiet);
    c.due_ms = now + c.period_ms;
    if (c.backend == .nvidia and quiet and !c.nv.rested and c.period_ms >= 4000) {
        c.nv.rested = helperDid("rest", .{});
    }
}

/// True when every fan of the chip's own is at full: then the shared fans help it too.
fn ownFansSpent(index: usize) bool {
    for (fans[0..nfans]) |*f| {
        if (!owns(f, index) or f.unusable) continue;
        if (!f.managed or f.ctl.duty < 254) return false;
    }
    return true;
}

/// A GPU's own fans serve only that GPU. The rest cool every chip that has none of its own,
/// and one that has, once its own have nothing left: a case fan before taking power.
fn fanServes(fan: *const Fan, index: usize) bool {
    if (fan.owner >= 0) return @as(usize, @intCast(fan.owner)) == index;
    return !chips[index].own_fans or ownFansSpent(index);
}

fn noMoreCooling(index: usize) bool {
    for (fans[0..nfans]) |*f| {
        if (f.unusable or !fanServes(f, index)) continue;
        if (!f.managed) return false;
        if (!atFull(f, 254)) return false;
    }
    return true;
}

/// Cooler Boost on is every fan at full, whatever the duty behind it says. Taken for room,
/// power went back while the fans had none, and on the GF63 the chip went over its limit. On
/// the way up the duty says it as before; once the fans have had time to spin up, the boost
/// does. zcool's curve gets there by the duty itself, so the boost on top is full at once.
fn atFull(f: *const Fan, duty: f32) bool {
    if (f.ec_boost) return f.written == 1 and (f.ctl.duty >= duty or f.full_for >= ec_spin_up);
    if (f.ec_curve and f.boost_on) return true;
    return f.ctl.duty >= duty;
}

const ec_spin_up: f32 = 2;

/// Quiet mode is on for the power source zcool is on now.
var quiet_now: bool = false;

/// Power is a lever for this chip, so quiet mode has something to give before the fans.
fn hasPowerLever(c: *const Chip) bool {
    return switch (c.kind) {
        .cpu => cpu_power.rapl_count > 0 or cpu_power.npolicies > 0,
        .gpu => !c.no_actuator and (c.backend != .nvidia or c.nv.lever != .none),
        else => false,
    };
}

/// What the chip draws, in watts, where a power limit is what holds it: what the cooler
/// carries is learned from that.
fn chipWatts(c: *const Chip) ?f32 {
    switch (c.kind) {
        .cpu => {
            if (cpu_power.rapl_count == 0 or cpu_power.escalated) return null;
            var milliwatts: f32 = 0;
            for (cpu_power.rapl_watts[0..cpu_power.rapl_count]) |w| milliwatts += w;
            return milliwatts / 1000;
        },
        .gpu => {
            if (c.backend == .nvidia) return if (c.nv.lever == .limit) @as(f32, @floatFromInt(c.nv.power_mw)) / 1000 else null;
            if (c.cap_len == 0 or c.power_fd < 0) return null;
            const microwatts = sys.readIntFd(c.power_fd) orelse return null;
            return @as(f32, @floatFromInt(microwatts)) / 1_000_000;
        },
        else => return null,
    }
}

/// The CPU's power as the last half second read it, in watts: what the model works with.
fn cpuWattsNow() ?f32 {
    if (cpu_power.rapl_count == 0 or cpu_power.escalated) return null;
    var milliwatts: f32 = 0;
    for (0..cpu_power.rapl_count) |i| {
        if (cpu_power.rapl_energy_fd[i] < 0) return null;
        milliwatts += cpu_power.rapl_watts_raw[i];
    }
    return milliwatts / 1000;
}

/// The power a limit starts from, in watts, as the actuators work it out when they start.
fn referenceWatts(c: *const Chip) f32 {
    switch (c.kind) {
        .cpu => {
            var total: f32 = 0;
            for (0..cpu_power.rapl_count) |i| {
                const base: f32 = @floatFromInt(cpu_power.rapl_base[i]);
                const milliwatts = cpu_power.rapl_watts[i];
                total += (if (milliwatts > 5000) @min(milliwatts * 1000, base) else base) / 1_000_000;
            }
            return total;
        },
        .gpu => {
            if (c.backend == .nvidia) {
                const mw = if (c.nv.power_mw > 5000) @min(c.nv.power_mw, c.nv.limit) else c.nv.limit;
                return @as(f32, @floatFromInt(mw)) / 1000;
            }
            const microwatts = if (c.power_fd >= 0) sys.readIntFd(c.power_fd) orelse 0 else 0;
            const reference = if (microwatts > 5_000_000) @min(microwatts, c.cap_base) else c.cap_base;
            return @as(f32, @floatFromInt(reference)) / 1_000_000;
        },
        else => return 0,
    }
}

// ---------------------------------------------------------------- the EC's fan curves

var fan_mode = control.FanMode{};
var fan_mode_original: ?u8 = null;
var fan_mode_refused = false;
var silent_now = false;

/// The firmware's silent fan curve while every chip is far below its limit, its normal one as
/// soon as one heads up: before Cooler Boost, before any power is taken.
fn adaptFanMode(dt: f32) void {
    if (!cfg.fan_silent or !cfg.use_ec or fan_mode_refused or !ec.writable) return;
    if (ec.layout == null) return;
    var margin: f32 = 1000;
    var busy = false;
    for (chips[0..nchips]) |*c| {
        if (!c.controlled() or !c.thermal.ready or c.asleep) continue;
        margin = @min(margin, c.limit - c.thermal.forecast());
        if (c.throttle.level < 1 or c.emergency) busy = true;
    }
    for (fans[0..nfans]) |*f| {
        if (f.ec_boost and f.written == 1) busy = true;
        if (f.ec_curve and f.managed) return;
    }
    const want = fan_mode.update(margin, dt) and !busy;
    if (want != silent_now) setSilent(want);
}

fn setSilent(on: bool) void {
    const l = ec.layout.?;
    if (on) {
        const current = ec.read(l.fan_mode) orelse return;
        if (current != l.fan_auto) {
            // a curve someone else chose, MSI's advanced one say: it stays theirs
            fan_mode_refused = true;
            return;
        }
        if (fan_mode_original == null) {
            if (!dry_run) {
                var path_buf: [256]u8 = undefined;
                if (!journal.rememberByte(ec.path(&path_buf), l.fan_mode, null, current)) return;
            }
            fan_mode_original = current;
        }
        if (!dry_run and (!ec.write(l.fan_mode, l.fan_silent) or ec.read(l.fan_mode) != l.fan_silent)) {
            _ = ec.write(l.fan_mode, current);
            fan_mode_refused = true;
            sys.print("ec: the silent fan curve was refused, the firmware's normal one stays\n");
            return;
        }
        sys.printf("ec: {s}the firmware's silent fan curve, every chip far below its limit\n", .{if (dry_run) "would take " else ""});
    } else {
        if (!dry_run) _ = ec.write(l.fan_mode, fan_mode_original orelse l.fan_auto);
        sys.printf("ec: {s}the firmware's normal fan curve again\n", .{if (dry_run) "would take " else ""});
    }
    silent_now = on;
}

// ---------------------------------------------------------------- the machine's model

/// The heat of this machine as `zcool calibrate --long` measured it, refined as zcool runs.
var model = thermal_model.Model{};
var model_saved = thermal_model.Model{};
var model_due_ms: i64 = 0;
/// how long a burst must stay under the limit on its own: zcool's own power control is awake
/// again within this
const burst_seconds: f32 = 3;

fn modelPath(buf: []u8) [:0]const u8 {
    return sys.join(buf, &.{ sys.root, "/var/lib/zcool/model" });
}

fn loadModel() void {
    var path_buf: [256]u8 = undefined;
    var text: [1024]u8 = undefined;
    model = thermal_model.parse(sys.readFile(modelPath(&path_buf), &text) orelse return);
    model_saved = model;
}

/// Once a minute at most, and only when learning moved something.
fn saveModel(now: i64, force: bool) void {
    if (dry_run or !cfg.learn or !model.known()) return;
    if (!force and now < model_due_ms) return;
    model_due_ms = now + 60_000;
    var moved = @abs(model.r_die - model_saved.r_die) >= 0.005;
    for (model.g, model_saved.g) |a, b| {
        if (@abs(a - b) >= 0.02) moved = true;
    }
    if (!moved) return;
    var buf: [512]u8 = undefined;
    var path_buf: [256]u8 = undefined;
    if (sys.replaceFile(modelPath(&path_buf), thermal_model.format(&model, &buf))) model_saved = model;
}

/// How hard the fans that cool the chip run now, as a duty of 255: Cooler Boost on is 255; a fan
/// zcool does not hold runs at the firmware's speed, read from the EC.
fn fanDutyFor(index: usize) f32 {
    var duty: f32 = 0;
    var any = false;
    for (fans[0..nfans]) |*f| {
        if (f.unusable or !fanServes(f, index)) continue;
        any = true;
        if (f.ec_boost) {
            duty = @max(duty, if (f.managed and f.written == 1) 255 else ecFanDuty());
        } else if (f.ec_curve) {
            duty = @max(duty, if (f.managed) (if (f.boost_on) 255 else f.ctl.duty) else ecFanDuty());
        } else {
            duty = @max(duty, if (f.managed) f.ctl.duty else f.floor);
        }
    }
    return if (any) duty else ecFanDuty();
}

fn ecFanDuty() f32 {
    const r = ec.readings() orelse return 0;
    return @as(f32, @floatFromInt(@min(@max(r.cpu_fan, r.gpu_fan), 100))) * 255 / 100;
}

/// What this tick taught the model: the die's jump when the power jumped, the cooler when the
/// chip has stood steady for 20 s. Saved once a minute.
fn learnOnline(c: *Chip, watts: f32, duty: f32, dt: f32) void {
    if (c.last_watts >= 0) {
        if (c.jump.update(c.raw, c.last_raw, watts, c.last_watts, dt)) |sample| {
            if (model.learnJump(sample.d_die, sample.d_watts)) |r| model.r_die = r;
        }
        // steady: the die within half a degree of its 10 s average and the fans at one speed, for
        // 15 s. The power may hunt meanwhile: what the cooler carried is its average over the same
        // time. A tick that is not steady costs three, so one odd reading does not restart the clock.
        if (c.watts_ema < 0) {
            c.watts_ema = watts;
            c.die_ema = c.raw;
            c.die_dev = 0;
            c.duty_ema = duty;
        }
        c.watts_ema += (watts - c.watts_ema) * dt / (dt + 10);
        c.die_ema += (c.raw - c.die_ema) * dt / (dt + 10);
        c.die_dev += (@abs(c.raw - c.die_ema) - c.die_dev) * dt / (dt + 10);
        c.duty_ema += (duty - c.duty_ema) * dt / (dt + 10);
        const steady = c.die_dev < 0.5 and @abs(duty - c.duty_ema) < 10;
        c.steady_for = if (steady) c.steady_for + dt else @max(0, c.steady_for - 3 * dt);
        if (c.steady_for >= 15) {
            _ = model.learnSteady(c.die_ema, c.watts_ema, duty);
            c.steady_for = 10;
        }
    }
    c.last_watts = watts;
    c.last_raw = c.raw;
}

fn describeModel() void {
    if (model.known()) describeModelOf(&model);
}

/// `m`'s lines: the model in use, or a fit that was not kept, for the record.
fn describeModelOf(m: *const thermal_model.Model) void {
    const t = &cal_line;
    _ = t.add("model: the die ").tenth(m.r_die * 10).add(" C above the sink per 10 W, the room ").whole(m.ambient);
    t.add(" C, the sink ").whole(m.mass).add(" J/C; the cooler carries per degree:").line();
    _ = t.add(" ");
    for (thermal_model.point_names, 0..) |name, i| {
        if (m.g[i] > 0) _ = t.add(" ").add(name).add(" ").hundredth(m.g[i]);
    }
    t.add(" W/C").line();
    for (chips[0..nchips]) |*c| {
        if (c.kind != .cpu or !c.controlled()) continue;
        _ = t.add("  holds ").whole(m.holds(253, c.limit)).add(" W at ").whole(c.limit).add("C with the fans at full");
        if (c.thermal.ready) {
            const watts = chipWatts(c) orelse 0;
            const sink = if (c.sink.ready) c.sink.sink else m.sink(c.thermal.temp, watts);
            _ = t.add("; a burst from now may draw ").whole(m.burst(sink, 253, c.limit - 1, burst_seconds)).add(" W");
        }
        t.line();
        break;
    }
}

fn step(dt: f32) void {
    adaptFanMode(dt);
    if (boost_useless) {
        var over = false;
        var near = false;
        for (chips[0..nchips]) |*c| {
            if (!c.controlled() or !c.thermal.ready or c.asleep) continue;
            if (c.emergency or c.thermal.temp > c.limit + 1) over = true;
            if (c.thermal.temp > c.limit - 1) near = true;
        }
        boost_rescue = over or (boost_rescue and near);
    }
    // quiet mode: whether each chip lets its fans past the firmware's curve yet
    var loud: [max_chips]bool = undefined;
    var wants: [max_chips]f32 = undefined;
    for (chips[0..nchips], 0..) |*c, index| {
        const quiet = quiet_now and c.controlled() and hasPowerLever(c);
        loud[index] = c.quiet.update(quiet, &c.thermal, c.limit, c.throttle.level, c.emergency, dt);
        wants[index] = 0;
        if (!c.controlled() or !c.thermal.ready or c.asleep) continue;
        if (!loud[index]) {
            c.drive = .{};
            continue;
        }
        c.drive.need = calibratedNeed(c, index);
        const d = c.drive.update(&c.thermal, c.limit, dt);
        // a chip going through its critical point gets everything at once, and one whose power
        // is taken keeps every fan until it has it all back: power first, then quiet. Fans
        // that came down while it was cut went off and on again on the GF63.
        wants[index] = if (c.emergency or c.throttle.level < 1) 1 else d;
    }
    for (fans[0..nfans]) |*f| {
        var demand: f32 = 0;
        for (chips[0..nchips], 0..) |*c, index| {
            if (!c.controlled() or !c.thermal.ready or c.asleep or !fanServes(f, index)) continue;
            demand = @max(demand, wants[index]);
        }
        updateFan(f, demand, dt);
    }

    var cpu_level: f32 = 1;
    var cpu_over = false;
    for (chips[0..nchips], 0..) |*c, index| {
        if (!c.controlled() or !c.thermal.ready or c.asleep) continue;
        const crit = if (c.emergency) c.thermal.temp + 1 else c.crit;
        const exhausted = noMoreCooling(index);
        // power starts at what the cooler is known to carry, once the fans have given all
        c.throttle.start = if (cfg.learn and exhausted and c.throttle.level >= 1) c.learned.startLevel(c.limit, referenceWatts(c)) else 1;
        if (c.kind == .cpu and model.known() and cpu_power.rapl_count > 0) {
            if (cpuWattsNow()) |watts| {
                const duty = fanDutyFor(index);
                const sink = c.sink.update(&model, c.raw, watts, duty, dt);
                c.thermal.model_forecast = model.forecast(sink, watts, duty, thermal_model.fan_horizon);
                // the burst the sink can take for the next seconds, a degree under the limit
                modelCap(model.burst(sink, duty, c.limit - 1, burst_seconds));
                if (cfg.learn and !dry_run) learnOnline(c, watts, duty, dt);
            } else c.thermal.model_forecast = null;
        }
        c.throttle.update(&c.thermal, c.limit, crit, exhausted or !loud[index], dt);
        if (cfg.learn and !dry_run) learn(c, nearlyNoMoreCooling(index), dt);
        report(c, loud[index]);
        switch (c.kind) {
            .cpu => {
                cpu_level = @min(cpu_level, c.throttle.level);
                if (c.thermal.temp > c.limit + 2) cpu_over = true;
            },
            .gpu => if (c.backend == .nvidia) applyNvidia(c, c.throttle.level) else applyGpu(c, c.throttle.level),
            else => {},
        }
    }
    applyCpu(cpu_level);
    watchEscalation(cpu_over, dt);
}

/// Every fan that serves the chip is at full or close to it: the controller settles just short
/// of full, and what the chip draws there is close to all the cooler carries.
fn nearlyNoMoreCooling(index: usize) bool {
    for (fans[0..nfans]) |*f| {
        if (f.unusable or !fanServes(f, index)) continue;
        if (!f.managed or !atFull(f, 230)) return false;
    }
    return true;
}

fn learn(c: *Chip, near_full: bool, dt: f32) void {
    const watts = chipWatts(c) orelse return;
    c.learned.observe(watts, &c.thermal, c.limit, near_full and c.throttle.level < 1 and !c.no_actuator, dt);
    if (c.learned.known() and !c.learned_logged) {
        c.learned_logged = true;
        sys.printf("{s}: learned that the cooler carries {d:.0} W at {d:.0}C with every fan at full\n", .{ c.name(), c.learned.watts, c.learned.at });
    }
}

fn report(c: *Chip, loud: bool) void {
    const throttled = c.throttle.level < 0.995 and !c.no_actuator;
    if (throttled and !loud and !c.quiet_logged) {
        c.quiet_logged = true;
        c.throttle_logged = true;
        sys.printf("{s}: {d:.1}C, quiet: a little power before louder fans, for the {d:.0}C limit\n", .{ c.name(), c.thermal.temp, c.limit });
    } else if (throttled and loud and c.quiet_logged) {
        c.quiet_logged = false;
        sys.printf("{s}: {d:.1}C, quiet has given what it may, the fans join in\n", .{ c.name(), c.thermal.temp });
    }
    if (throttled != c.throttle_logged) {
        c.throttle_logged = throttled;
        if (throttled) {
            sys.printf("{s}: {d:.1}C, fans have nothing left, trimming power for the {d:.0}C limit\n", .{ c.name(), c.thermal.temp, c.limit });
        } else {
            c.quiet_logged = false;
            sys.printf("{s}: {d:.1}C, full power again\n", .{ c.name(), c.thermal.temp });
        }
    }
    // over at 2 C past the limit, back under only at it, so one reading does not say both
    const over = if (c.over_logged) c.thermal.temp > c.limit else c.thermal.temp > c.limit + 2;
    if (over != c.over_logged) {
        c.over_logged = over;
        if (over and c.no_actuator) {
            sys.printf("{s}: {d:.1}C is over the {d:.0}C limit and only fans can help it\n", .{ c.name(), c.thermal.temp, c.limit });
        } else if (over) {
            sys.printf("{s}: {d:.1}C is over the {d:.0}C limit\n", .{ c.name(), c.thermal.temp, c.limit });
        } else {
            sys.printf("{s}: {d:.1}C, back under the limit\n", .{ c.name(), c.thermal.temp });
        }
    }
}

// ---------------------------------------------------------------- the battery and the EC's profiles

/// The kernel's own charge limit, which ThinkPads, ASUS, Dell and others have.
fn batteryThreshold(buf: []u8) ?[:0]const u8 {
    var dir_buf: [256]u8 = undefined;
    var dir = sys.Dir.open(sys.join(&dir_buf, &.{ sys.root, "/sys/class/power_supply" })) orelse return null;
    defer dir.close();
    while (dir.next()) |entry| {
        if (!std.mem.startsWith(u8, entry, "BAT")) continue;
        const path = sys.join(buf, &.{ sys.root, "/sys/class/power_supply/", entry, "/charge_control_end_threshold" });
        if (sys.exists(path)) return path;
    }
    return null;
}

/// Unlike everything else, a charge limit stays when zcool stops: it has to hold while the
/// laptop is off and plugged in. `battery.max = 100` takes it away.
fn applyChargeLimit() void {
    const wanted = cfg.battery_max;
    if (wanted == 0) return;
    var path_buf: [256]u8 = undefined;
    const path = batteryThreshold(&path_buf);
    var current: i64 = 0;
    if (path) |file| {
        current = sys.readInt(file) orelse 0;
    } else {
        const ec_limit = if (cfg.use_ec) ec.chargeLimit() else null;
        current = ec_limit orelse {
            sys.print("battery: this machine takes no charge limit\n");
            return;
        };
    }
    if (current == wanted) {
        sys.printf("battery: charges up to {d}%\n", .{wanted});
        return;
    }
    if (dry_run) {
        sys.printf("battery: would charge up to {d}%\n", .{wanted});
        return;
    }
    const done = if (path) |file| sys.writeInt(file, wanted) else ec.setChargeLimit(wanted);
    if (done) {
        sys.printf("battery: charges up to {d}% from now on\n", .{wanted});
    } else {
        sys.printf("battery: a {d}% limit was refused{s}\n", .{ wanted, if (path == null and !ec.writable) ": the EC is read only, see the README" else "" });
    }
}

var mains_fd: i32 = -1;
var mains_due_ms: i64 = 0;
var on_mains: ?bool = null;
/// The EC's profile before zcool changed it: back to it on a source with no profile set.
var profile_original: ?u8 = null;

/// A known EC whose profile follows the power source, where the config names one for it.
var ec_modes: bool = false;

/// The online file of the mains supply, which says whether the laptop is plugged in.
fn openMains() ?i32 {
    var dir_buf: [256]u8 = undefined;
    var dir = sys.Dir.open(sys.join(&dir_buf, &.{ sys.root, "/sys/class/power_supply" })) orelse return null;
    defer dir.close();
    while (dir.next()) |entry| {
        var path_buf: [256]u8 = undefined;
        var type_buf: [16]u8 = undefined;
        const kind = sys.readFile(sys.join(&path_buf, &.{ sys.root, "/sys/class/power_supply/", entry, "/type" }), &type_buf) orelse continue;
        if (!std.mem.startsWith(u8, kind, "Mains")) continue;
        return sys.openRead(sys.join(&path_buf, &.{ sys.root, "/sys/class/power_supply/", entry, "/online" })) orelse continue;
    }
    return null;
}

fn findMains() void {
    if (!cfg.ac.any() and !cfg.battery.any()) return;
    if (cfg.ac.mode != null or cfg.battery.mode != null) {
        if (ec.layout == null) {
            sys.print("mode.ac and mode.battery need an MSI EC that zcool knows: left as they are\n");
        } else {
            ec_modes = true;
        }
    }
    mains_fd = openMains() orelse {
        // no mains supply to follow: a desktop, always on mains
        on_mains = true;
        applySource(true);
        return;
    };
}

/// What the config sets follows the power source: checked every two seconds.
fn followPowerSource(now: i64) void {
    if (mains_fd < 0 or now < mains_due_ms) return;
    mains_due_ms = now + 2000;
    const mains = (sys.readIntFd(mains_fd) orelse return) == 1;
    if (on_mains != null and on_mains.? == mains) return;
    on_mains = mains;
    applySource(mains);
}

fn applySource(mains: bool) void {
    const src = cfg.source(mains);
    const source: []const u8 = if (mains) "on mains" else "on battery";
    shift_now = @floatFromInt(src.shift);
    for (chips[0..nchips]) |*c| {
        if (c.base_limit > 0) c.limit = @max(30, c.base_limit + shift_now);
    }
    quiet_now = src.quiet;
    var buf: [200]u8 = undefined;
    var n: usize = 0;
    if (src.shift != 0) n = appendf(&buf, n, ", limits {d}C lower", .{-src.shift});
    if (src.epp != null and hasEpp()) n = appendf(&buf, n, ", energy preference {s}", .{@tagName(src.epp.?)});
    if (src.turbo != null and turbo.len > 0) n = appendf(&buf, n, ", turbo {s}", .{if (src.turbo.?) "on" else "off"});
    if (src.quiet) n = appendf(&buf, n, ", quiet fans", .{});
    if (src.burst) |w| n = appendf(&buf, n, ", bursts up to {d} W", .{w});
    const what = if (n > 2) buf[2..n] else "the firmware's own settings";
    // a config with only the EC's profiles says so in the EC's own line
    if (generalSettings(&cfg.ac) or generalSettings(&cfg.battery)) {
        sys.printf("power: {s}{s} {s}\n", .{ source, if (dry_run) ", would set:" else ":", what });
    }
    applyEpp(src.epp);
    applyTurbo(src.turbo);
    applyBurst(src.burst);
    if (ec_modes) applyEcMode(src.mode, source);
}

fn generalSettings(src: *const config.Source) bool {
    return src.shift != 0 or src.epp != null or src.turbo != null or src.quiet or src.burst != null;
}

/// The CPU's short-term limit held at `watts`, never above the firmware's; null gives the
/// firmware's back. Power taken for the heat stays under it as well.
fn applyBurst(watts: ?u16) void {
    for (0..cpu_power.rapl_count) |i| {
        if (!cpu_power.pl2[i]) continue;
        const want: i64 = if (watts) |w| @as(i64, w) * 1_000_000 else cpu_power.pl2_original[i];
        cpu_power.pl2_setting[i] = @min(want, cpu_power.pl2_original[i]);
        cpu_power.pl2_cap[i] = cpu_power.pl2_setting[i];
        // under a cut the next one writes it, already under the cap
        if (!dry_run and cpu_power.applied >= 1) setPl2(i, null);
    }
}

/// The burst the machine's model allows right now: the setting, or less while the sink is warm.
/// Written when it moved by 2 W, under a cut as well, since the cut's own write may be long past.
fn modelCap(watts: f32) void {
    for (0..cpu_power.rapl_count) |i| {
        if (!cpu_power.pl2[i]) continue;
        // never under the long-term limit: the short-term one is the burst above it
        const floor: f32 = @floatFromInt(cpu_power.rapl_original[i]);
        const allowed: i64 = @intFromFloat(@max(watts * 1_000_000, floor));
        const cap = @min(cpu_power.pl2_setting[i], allowed);
        if (@abs(cap - cpu_power.pl2_cap[i]) < 2_000_000) continue;
        cpu_power.pl2_cap[i] = cap;
        if (dry_run) continue;
        if (cpu_power.applied >= 1) {
            setPl2(i, null);
        } else {
            setPl2(i, @intFromFloat(cpu_power.rapl_reference[i] * cpu_power.applied));
        }
    }
}

/// Adds to a line being built; what does not fit is left out.
fn appendf(buf: []u8, n: usize, comptime fmt: []const u8, args: anytype) usize {
    const written = std.fmt.bufPrint(buf[n..], fmt, args) catch return n;
    return n + written.len;
}

fn hasEpp() bool {
    for (cpu_power.policies[0..cpu_power.npolicies]) |*p| if (p.epp_len > 0) return true;
    return false;
}

var epp_refused = false;

/// The CPU's energy preference: how readily it climbs to high clocks. With none set for this
/// source, what it was before zcool.
fn applyEpp(wanted: ?config.Epp) void {
    if (dry_run) return;
    var path_buf: [256]u8 = undefined;
    for (cpu_power.policies[0..cpu_power.npolicies]) |*p| {
        if (p.epp_len == 0) continue;
        if (wanted == null and !p.epp_saved) continue;
        const target: []const u8 = if (wanted) |e| @tagName(e) else p.epp[0..p.epp_len];
        var num: [8]u8 = undefined;
        const digits = std.fmt.bufPrint(&num, "{d}", .{p.index}) catch continue;
        const path = policyPath(&path_buf, digits, "energy_performance_preference");
        if (!p.epp_saved) {
            if (!journal.rememberValue(path, p.epp[0..p.epp_len])) continue;
            p.epp_saved = true;
        }
        if (!sys.writeFile(path, target) and !epp_refused) {
            epp_refused = true;
            sys.print("cpu: the energy preference was refused; under the performance governor only `performance` is taken\n");
        }
    }
}

fn applyTurbo(wanted: ?bool) void {
    if (turbo.len == 0 or dry_run) return;
    const on = wanted orelse (if (turbo.saved) (turbo.original == 1) != turbo.inverted else return);
    var path_buf: [260]u8 = undefined;
    const path = sys.join(&path_buf, &.{turbo.path[0..turbo.len]});
    if (!turbo.saved) {
        if (!journal.rememberInt(path, turbo.original)) return;
        turbo.saved = true;
    }
    if (!sys.writeInt(path, if (on != turbo.inverted) 1 else 0)) sys.print("cpu: the turbo switch was refused\n");
}

/// The EC's own power profile, or the one it had before zcool on a source with none set.
fn applyEcMode(mode: ?ec.Profile, source: []const u8) void {
    const l = ec.layout.?;
    const byte = (if (mode) |m| l.profiles[@backingInt(m)] else profile_original) orelse return;
    const current = ec.read(l.profile) orelse return;
    if (current == byte) return;
    const name = ec.profileName(l, byte);
    if (dry_run) {
        sys.printf("ec: would set the profile to {s} {s}\n", .{ name, source });
        return;
    }
    if (!ec.writable) return;
    if (profile_original == null) {
        var path_buf: [256]u8 = undefined;
        if (!journal.rememberByte(ec.path(&path_buf), l.profile, null, current)) return;
        profile_original = current;
    }
    if (ec.write(l.profile, byte)) sys.printf("ec: profile {s} {s}\n", .{ name, source });
}

// ---------------------------------------------------------------- what was learned

fn learnedPath(buf: []u8) [:0]const u8 {
    return sys.join(buf, &.{ sys.root, "/var/lib/zcool/learned" });
}

/// `cpu0 31.5 90 600` per line: watts, the limit they were learned at, seconds of learning.
fn loadLearned() void {
    var path_buf: [256]u8 = undefined;
    var text_buf: [2048]u8 = undefined;
    const text = sys.readFile(learnedPath(&path_buf), &text_buf) orelse return;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const id = fields.next() orelse continue;
        const watts = tenths(fields.next() orelse continue) orelse continue;
        const at = tenths(fields.next() orelse continue) orelse continue;
        const seconds = tenths(fields.next() orelse continue) orelse continue;
        if (!(watts >= 1 and watts <= 2000 and at >= 35 and at <= 130 and seconds >= 10)) continue;
        for (chips[0..nchips]) |*c| {
            if (!std.mem.eql(u8, c.name(), id)) continue;
            c.learned = .{ .watts = watts, .at = at, .seconds = @min(seconds, 600) };
            c.learned_logged = true;
            c.learned_saved = watts;
        }
    }
}

/// "31.5" or "90": a number with at most one decimal, as saveLearned writes it. Far smaller
/// than the standard float parser, which would double the binary.
fn tenths(text: []const u8) ?f32 {
    const dot = std.mem.indexOfScalar(u8, text, '.');
    const whole = std.fmt.parseInt(u32, text[0 .. dot orelse text.len], 10) catch return null;
    var tenth: u32 = 0;
    if (dot) |d| {
        if (d + 2 != text.len or text[d + 1] < '0' or text[d + 1] > '9') return null;
        tenth = text[d + 1] - '0';
    }
    return @as(f32, @floatFromInt(whole)) + @as(f32, @floatFromInt(tenth)) / 10;
}

var learned_due_ms: i64 = 0;

/// Once a minute at most, and only when something moved.
fn saveLearned(now: i64, force: bool) void {
    if (dry_run or !cfg.learn) return;
    if (!force and now < learned_due_ms) return;
    learned_due_ms = now + 60_000;
    var changed = false;
    for (chips[0..nchips]) |*c| {
        if (c.learned.known() and @abs(c.learned.watts - c.learned_saved) >= 0.5) changed = true;
    }
    if (!changed) return;
    var buf: [2048]u8 = undefined;
    var n: usize = 0;
    for (chips[0..nchips]) |*c| {
        if (!c.learned.known()) continue;
        const line = std.fmt.bufPrint(buf[n..], "{s} {d:.1} {d:.0} {d:.0}\n", .{ c.name(), c.learned.watts, c.learned.at, @min(c.learned.seconds, 600) }) catch break;
        n += line.len;
        c.learned_saved = c.learned.watts;
    }
    var path_buf: [256]u8 = undefined;
    _ = sys.replaceFile(learnedPath(&path_buf), buf[0..n]);
}

/// How often to look: four times a second while a fan is held or a chip is near its limit, twice
/// while one is within 20 C of it, once a second while every chip is further away still. A
/// laptop at rest sits 30 C under its limit for hours: two wakeups a second there were the
/// daemon's whole cost (0.17 ms of CPU a second, measured), and the CPU's own throttle and the
/// burst limit stand behind a second's delay as behind a half's.
fn tickMs() i64 {
    var nearest: f32 = 1000;
    for (fans[0..nfans]) |*f| if (f.managed) return 250;
    for (chips[0..nchips]) |*c| {
        if (!c.controlled() or !c.thermal.ready or c.asleep) continue;
        if (c.thermal.forecast() > c.limit - control.fan_band or c.throttle.level < 1) return 250;
        nearest = @min(nearest, c.limit - c.thermal.forecast());
    }
    return if (nearest >= control.rest_margin) 1000 else 500;
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
    sys.ignoreSigpipe();
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
    var proc_buf: [256]u8 = undefined;
    // /proc for the guard: the pressure figures and the processes, read only
    return sandbox.apply(&.{sys.join(&proc_buf, &.{ sys.root, "/proc" })}, &.{
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
        _ = nvidia.resetLeftovers();
    }
    gpus.scan();
    if (cfg.gpu_sleep) gpus.allowSleep(dry_run);
    discover();
    if (cfg.learn) loadLearned();
    loadCalibration();
    loadModel();
    if (model.known()) describeModel();
    for (fans[0..nfans]) |*f| {
        // calibration found the fans turn as fast at 60% as at full: the EC does not follow the curve
        if (f.ec_curve and cal.curveFollowed() == false) {
            sys.printf("{s}: calibration found the fans do not follow zcool's curve: Cooler Boost alone\n", .{f.name()});
            f.ec_curve = false;
            f.ec_boost = true;
            nameFan(f, "ec/cooler_boost");
        }
    }
    for (chips[0..nchips]) |*c| {
        if (c.kind == .cpu and cal.known()) c.quiet.floor = cal.quietFloor() orelse control.quiet_floor;
    }
    if (cal.known() and !cal.boostWorth()) {
        for (fans[0..nfans]) |*f| {
            if (!f.ec_curve) continue;
            boost_useless = true;
            sys.printf("{s}: calibration found Cooler Boost carries {d:.0}% more than full speed: only for a chip over its limit\n", .{ f.name(), (cal.boostGain() orelse 0) * 100 });
        }
    }
    if (ec.layout != null) {
        var curve = false;
        for (fans[0..nfans]) |*f| curve = curve or f.ec_curve;
        const what: []const u8 = if (!ec.writable) "read only: load ec_sys with write_support=1" else if (curve) "its fans join, at the speed zcool sets and Cooler Boost past full" else "Cooler Boost joins the fans";
        sys.printf("ec: {s}, {s}\n", .{ ec.version(), what });
    } else if (cfg.use_ec and !ec.present and isMsi()) {
        sys.printf("ec: not reached, {s}\n", .{noEcReason()});
    }
    applyChargeLimit();
    findMains();
    installSignals();
    // started before the sandbox, which allows no programs to run
    if (hasNvidia()) {
        if (nvidia.start()) {
            sys.print("zcool-nvidia: reading NVIDIA's GPUs through its library\n");
        } else {
            sys.print("zcool-nvidia did not start: NVIDIA's GPUs are left to their driver\n");
        }
    }

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

    if (!dry_run and cfg.learn) {
        var lib_buf: [256]u8 = undefined;
        sys.mkdir(sys.join(&lib_buf, &.{ sys.root, "/var/lib/zcool" }));
    }
    // the CPU's own throttle just above the limit: its registers are open only before the sandbox
    if (cfg.tcc and undervolt.isIntel()) {
        if (undervolt.lockdownActive()) {
            sys.print("tcc: kernel lockdown blocks MSR writes, the CPU's own throttle stays at TjMax\n");
        } else for (chips[0..nchips]) |*c| {
            if (c.kind != .cpu or !c.controlled()) continue;
            tcc.apply(c.base_limit, dry_run);
            break;
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
    guard.cpu_on = cfg.guard_cpu;
    guard.memory_on = cfg.guard_memory;
    guard.dry_run = dry_run;

    var last = sys.nowMs();
    const started = last;
    while (!stop_requested) {
        const now = sys.nowMs();
        const dt = @as(f32, @floatFromInt(now - last)) / 1000;
        last = now;
        if (!readChips(now)) {
            saveLearned(now, true);
            nvidia.stop();
            emergencyRestore();
            return 1;
        }
        sampleCpuPower(now);
        step(dt);
        followPowerSource(now);
        saveLearned(now, false);
        saveModel(now, false);
        guard.tick(now);
        if (undervolted and now - started > 600_000) {
            undervolt.markStable();
            undervolted = false;
        }
        sys.sleepMs(tickMs());
    }
    if (undervolted) undervolt.markStable();
    saveLearned(sys.nowMs(), true);
    saveModel(sys.nowMs(), true);
    guard.restore();
    nvidia.stop();
    emergencyRestore();
    return 0;
}

fn listChips() void {
    listing = true;
    gpus.scan();
    discover();
    if (hasNvidia()) _ = nvidia.start();
    const now = sys.nowMs();
    _ = readChips(now);
    sys.print("chip            now  limit   crit  power control\n");
    for (chips[0..nchips]) |*c| {
        const power: []const u8 = switch (c.kind) {
            .cpu => if (cpu_power.rapl_count > 0) "rapl" else if (cpu_power.npolicies > 0) "freq" else "none",
            .gpu => if (c.backend == .nvidia)
                (if (c.ec_temp) "ec, fans" else if (!c.nv.known) "?" else if (c.nv.limit_max > c.nv.limit_min) "limit" else if (c.nv.max_clock > 0) "clocks" else "none")
            else if (c.cap_len > 0) "cap" else "none",
            else => "none",
        };
        if (c.asleep) {
            sys.printf("{s:<14} asleep, not woken to read it\n", .{c.name()});
        } else if (c.limit > 0) {
            sys.printf("{s:<14} {d:>4.0}  {d:>5.0}  {d:>5.0}  {s}\n", .{ c.name(), c.thermal.temp, c.limit, c.crit, power });
        } else {
            sys.printf("{s:<14} {d:>4.0}  watch  {d:>5.0}  {s}\n", .{ c.name(), c.thermal.temp, c.crit, power });
        }
    }
    if (hasNvidia() and !nvidia.running()) {
        sys.print("\nzcool-nvidia or NVIDIA's library is missing: that GPU is left to its driver\n");
    }
    for (chips[0..nchips]) |*c| {
        if (c.nv_error_len > 0) sys.printf("{s}: NVIDIA's library answers \"{s}\"{s}\n", .{ c.name(), c.nv_error[0..c.nv_error_len], if (c.ec_temp) ", read through the EC" else "" });
    }
    listGpus();
    if (nfans == 0) sys.print("\nno controllable fans found\n") else sys.print("\nfan                       duty    rpm\n");
    for (fans[0..nfans]) |*f| {
        if (f.ec_boost) {
            sys.printf("{s:<24} {s:>5}      -\n", .{ f.name(), if (ec.boost() orelse false) "full" else "auto" });
            continue;
        }
        if (f.ec_curve) {
            const l = ec.layout.?;
            const c = &l.curve.?;
            var speed_buf: [8]u8 = undefined;
            var rpm_buf: [8]u8 = undefined;
            const speed: []const u8 = if (ec.boost() orelse false) "full" else if (ec.read(l.fan_mode) != c.advanced) "auto" else if (ec.read(c.speeds[0])) |p| std.fmt.bufPrint(&speed_buf, "{d}%", .{p}) catch "?" else "?";
            const rpm: []const u8 = if (ec.rpm(0)) |v| std.fmt.bufPrint(&rpm_buf, "{d}", .{v}) catch "?" else "-";
            sys.printf("{s:<24} {s:>5}  {s:>5}\n", .{ f.name(), speed, rpm });
            continue;
        }
        if (f.nv_index >= 0) {
            const c = &chips[@intCast(f.owner)];
            sys.printf("{s:<24} {d:>4}%      -\n", .{ f.name(), c.nv.fan[@intCast(f.nv_index)] });
            continue;
        }
        var pwm_buf: [200]u8 = undefined;
        var duty_buf: [8]u8 = undefined;
        var rpm_buf: [8]u8 = undefined;
        const duty = if (sys.readInt(f.pwmPath(&pwm_buf))) |v| std.fmt.bufPrint(&duty_buf, "{d}", .{v}) catch "?" else "?";
        const rpm = if (f.input_fd >= 0) (if (sys.readIntFd(f.input_fd)) |v| std.fmt.bufPrint(&rpm_buf, "{d}", .{v}) catch "?" else "?") else "-";
        sys.printf("{s:<24} {s:>5}  {s:>5}\n", .{ f.name(), duty, rpm });
    }
    listEc();
    var path_buf: [256]u8 = undefined;
    if (batteryThreshold(&path_buf)) |path| sys.printf("\nbattery: charges up to {d}%\n", .{sys.readInt(path) orelse 100});
    listPower();
    nvidia.stop();
}

/// The power source and what follows it, and what zcool has learned about the cooler.
fn listPower() void {
    var line: [200]u8 = undefined;
    var n: usize = 0;
    if (openMains()) |fd| {
        defer sys.close(fd);
        const mains = (sys.readIntFd(fd) orelse 1) == 1;
        n = appendf(&line, n, "on {s}", .{if (mains) "mains" else "battery"});
    }
    for (cpu_power.policies[0..cpu_power.npolicies]) |*p| {
        if (p.epp_len == 0) continue;
        n = appendf(&line, n, "{s}energy preference {s}", .{ if (n > 0) ", " else "", p.epp[0..p.epp_len] });
        break;
    }
    if (turboOn()) |on| n = appendf(&line, n, "{s}turbo {s}", .{ if (n > 0) ", " else "", if (on) "on" else "off" });
    if (n > 0) sys.printf("\npower: {s}\n", .{line[0..n]});
    var guard_buf: [128]u8 = undefined;
    if (guard.summary(&guard_buf)) |text| sys.printf("guard: {s}\n", .{text});
    var tcc_buf: [128]u8 = undefined;
    if (tcc.describe(&tcc_buf)) |text| {
        sys.printf("tcc: {s}\n", .{text});
    } else if (cfg.tcc and undervolt.isIntel() and std.os.linux.getuid() != 0) {
        sys.print("tcc: only root reads where the CPU throttles itself: doas zcool list\n");
    }
    loadLearned();
    var first = true;
    for (chips[0..nchips]) |*c| {
        if (!c.learned.known()) continue;
        if (first) sys.print("\nlearned: what the cooler carries with every fan at full\n");
        first = false;
        sys.printf("  {s:<12} {d:>5.0} W at {d:.0}C\n", .{ c.name(), c.learned.watts, c.learned.at });
    }
    loadCalibration();
    if (cal.known()) {
        sys.print("\n");
        describeCalibration();
    } else {
        sys.print("\nnot calibrated: doas zcool calibrate, plugged in, a few minutes\n");
    }
    loadModel();
    if (model.known()) {
        sys.print("\n");
        describeModel();
    } else if (cal.known()) {
        sys.print("no model of the machine's heat yet: doas zcool calibrate --long, plugged in, up to an hour\n");
    }
}

/// An MSI laptop's EC: what it reads, and why zcool does or does not use it.
fn listEc() void {
    if (!cfg.use_ec) return;
    ec.open();
    if (!ec.present) {
        if (isMsi()) sys.printf("\nMSI laptop: zcool can use its EC (Cooler Boost, charge limit), but {s}\n", .{noEcReason()});
        return;
    }
    const l = ec.layout orelse {
        sys.printf("\nec: firmware {s} is not one zcool knows, so it is left alone\n", .{ec.version()});
        return;
    };
    sys.printf("\nec: {s}, {s}{s}\n", .{ ec.version(), l.family, if (ec.writable) "" else ", read only: load ec_sys with write_support=1" });
    if (ec.readings()) |r| sys.printf("  cpu {d}C, fan {d}%   gpu {d}C, fan {d}%\n", .{ r.cpu_temp, r.cpu_fan, r.gpu_temp, r.gpu_fan });
    var charge_buf: [16]u8 = undefined;
    const boost: []const u8 = if (ec.boost()) |b| (if (b) "on" else "off") else "?";
    const profile: []const u8 = if (ec.read(l.profile)) |byte| ec.profileName(l, byte) else "?";
    const charge: []const u8 = if (ec.chargeLimit()) |c|
        (if (c == 0) "none" else std.fmt.bufPrint(&charge_buf, "{d}%", .{c}) catch "?")
    else
        "not supported";
    sys.printf("  cooler boost {s}, profile {s}, charge limit {s}\n", .{ boost, profile, charge });
    const c = l.curve orelse return;
    const mode = ec.read(l.fan_mode) orelse return;
    const curve: []const u8 = if (mode == c.advanced) "the advanced curve, zcool's while it holds the fans" else if (mode == l.fan_silent) "the firmware's silent curve" else if (mode == l.fan_auto) "the firmware's normal curve" else "unknown";
    sys.printf("  fans by {s}", .{curve});
    // a fan that does not turn is often not there: a GF63 Thin has one, the EC keeps two curves
    for (0..2) |i| if (ec.rpm(i)) |rpm| {
        if (i == 0 or rpm > 0) sys.printf("{s}{s} {d} rpm", .{ if (i == 0) "; " else ", ", ec.fan_names[i], rpm });
    };
    sys.print("\n");
}

/// What keeps zcool from an MSI laptop's EC, the first thing to fix first.
fn noEcReason() []const u8 {
    // debugfs is root's alone
    if (std.os.linux.getuid() != 0) return "only root reaches it: doas zcool list";
    var buf: [4096]u8 = undefined;
    var path_buf: [256]u8 = undefined;
    const cmdline = sys.readFile(sys.join(&path_buf, &.{ sys.root, "/proc/cmdline" }), &buf) orelse "";
    if (std.mem.indexOf(u8, cmdline, "debugfs=off") != null) return "the kernel runs with debugfs=off: drop it, see the README";
    const mounts = sys.readFile(sys.join(&path_buf, &.{ sys.root, "/proc/mounts" }), &buf) orelse "";
    if (std.mem.indexOf(u8, mounts, " /sys/kernel/debug debugfs ") == null) return "debugfs is not mounted: doas mount -t debugfs debugfs /sys/kernel/debug";
    if (!sys.exists(sys.join(&path_buf, &.{ sys.root, "/sys/module/ec_sys" }))) return "ec_sys is not loaded: doas modprobe ec_sys write_support=1";
    return "ec_sys shows no EC";
}

fn isMsi() bool {
    var path_buf: [256]u8 = undefined;
    var vendor: [64]u8 = undefined;
    const text = sys.readFile(sys.join(&path_buf, &.{ sys.root, "/sys/class/dmi/id/sys_vendor" }), &vendor) orelse return false;
    return std.mem.indexOf(u8, text, "Micro-Star") != null;
}

/// Each GPU: whether it shows the boot screen, whether it may sleep, and what keeps it awake.
fn listGpus() void {
    if (gpus.count == 0) return;
    sys.print("\ngpu            driver    screen  sleeps     now\n");
    for (gpus.list[0..gpus.count]) |*g| {
        var state_buf: [16]u8 = undefined;
        const state = gpus.state(g, &state_buf);
        const sleeps: []const u8 = if (g.boot) "no" else if (g.may_sleep) "when idle" else "no";
        sys.printf("{s:<14} {s:<9} {s:<7} {s:<10} {s}\n", .{ g.address(), g.driverName(), if (g.boot) "boot" else "-", sleeps, state });
        if (g.boot) {
            if (g.vendor == .intel and !hasChipFor(g)) sys.print("  its heat counts in the CPU's package power limit\n");
            continue;
        }
        if (!g.may_sleep) sys.print("  `zcool run` lets it sleep when idle; `gpu.sleep = no` keeps it awake\n");
        gpus.explainNvidia(g, "  ");
        if (!std.mem.eql(u8, state, "suspended")) gpus.printHolders(g);
    }
}

fn hasChipFor(g: *const gpus.Gpu) bool {
    for (chips[0..nchips]) |*c| {
        if (c.gpu >= 0 and &gpus.list[@intCast(c.gpu)] == g) return true;
    }
    return false;
}

// ---------------------------------------------------------------- the menu

/// What the menu shows: every chip with its default limit, and every fan, also the ones the
/// config leaves alone, so they can be taken back.
fn runMenu(path: [:0]const u8) u8 {
    listing = true;
    const limits = cfg.nlimits;
    const excludes = cfg.nexcludes;
    cfg.nlimits = 0;
    cfg.nexcludes = 0;
    gpus.scan();
    discover();
    if (hasNvidia()) _ = nvidia.start();
    _ = readChips(sys.nowMs());
    cfg.nlimits = limits;
    cfg.nexcludes = excludes;
    loadLearned();
    const rc = menu.run(path, menuInfo);
    nvidia.stop();
    return rc;
}

fn menuInfo(info: *menu.Info) void {
    _ = readChips(sys.nowMs());
    info.nchips = 0;
    for (chips[0..nchips]) |*c| {
        if (info.nchips == menu.max_chips) break;
        var m = menu.ChipInfo{
            .temp = if (c.thermal.ready) c.thermal.temp else 0,
            .default_limit = c.base_limit,
            .max_limit = if (c.crit > 0) c.crit - 5 else switch (c.kind) {
                .cpu => 95,
                .gpu => 100,
                else => 80,
            },
            .asleep = c.asleep,
            .learned_watts = if (c.learned.known()) c.learned.watts else 0,
            .learned_at = c.learned.at,
        };
        const n = @min(c.id_len, m.name.len);
        @memcpy(m.name[0..n], c.id[0..n]);
        m.name_len = @intCast(n);
        // a NVIDIA GPU its library has not read yet has no default to show
        if (c.kind == .other or (c.backend == .nvidia and c.base_limit == 0)) m.default_limit = 0;
        info.chips[info.nchips] = m;
        info.nchips += 1;
    }
    info.nfans = 0;
    for (fans[0..nfans]) |*f| {
        if (info.nfans == menu.max_fans) break;
        @memcpy(info.fans[info.nfans][0..f.id_len], f.id[0..f.id_len]);
        info.fan_lens[info.nfans] = f.id_len;
        info.nfans += 1;
    }
    info.on_mains = null;
    if (openMains()) |fd| {
        defer sys.close(fd);
        if (sys.readIntFd(fd)) |v| info.on_mains = v == 1;
    }
    info.ec = ec.layout != null;
    info.has_burst = cpu_power.rapl_count > 0 and cpu_power.pl2[0];
    if (ec.readings()) |r| {
        info.ec_cpu = r.cpu_temp;
        info.ec_gpu = r.gpu_temp;
        info.ec_cpu_fan = r.cpu_fan;
        info.ec_gpu_fan = r.gpu_fan;
    }
    info.has_epp = hasEpp();
    info.has_turbo = turbo.len > 0;
    info.undervolt_note = if (undervolt.lockdownActive()) "kernel lockdown is on: refused" else "";
}

// ---------------------------------------------------------------- calibration

/// What `zcool calibrate` measured last, from /var/lib/zcool/calibration.
var cal = calibrate.Result{};
/// Calibration holds zcool's curve at full without Cooler Boost for one of its points.
var boost_barred = false;
/// Calibration found Cooler Boost carries next to nothing over full speed: it comes only for a
/// chip over its limit, and stays until that chip is back under it.
var boost_useless = false;
var boost_rescue = false;

fn calibrationPath(buf: []u8) [:0]const u8 {
    return sys.join(buf, &.{ sys.root, "/var/lib/zcool/calibration" });
}

fn loadCalibration() void {
    var path_buf: [256]u8 = undefined;
    var text: [2048]u8 = undefined;
    cal = calibrate.parse(sys.readFile(calibrationPath(&path_buf), &text) orelse return);
}

/// What calibration does now, in /run/zcool/calibration: `cores 3` while it loads three cores,
/// `idle` once it is done. Under a fake root nothing real is loaded, and the simulator models
/// the load it reads here.
fn calibrationStep(cores: usize) void {
    var text_buf: [32]u8 = undefined;
    var path_buf: [256]u8 = undefined;
    var t = Text{ .buf = &text_buf };
    if (cores == 0) _ = t.add("idle\n") else _ = t.add("cores ").num(@intCast(cores)).add("\n");
    _ = sys.replaceFile(sys.join(&path_buf, &.{ sys.root, "/run/zcool/calibration" }), t.str());
}

/// Calibration's lines, built without std.fmt: see text.zig.
var cal_line_buf: [256]u8 = undefined;
var cal_line = Text{ .buf = &cal_line_buf };

/// The clocks of the first `cpus` CPUs, where the load runs, their mean: a CPU-bound load runs
/// in proportion to them. The idle ones sit at their lowest and say nothing about it: on the
/// GF63 one loaded CPU of twelve read as 1564 MHz.
fn meanMhz(cpus: usize) f32 {
    var path_buf: [256]u8 = undefined;
    var sum: f32 = 0;
    var n: f32 = 0;
    for (cpu_power.policies[0..cpu_power.npolicies]) |p| {
        if (p.index >= cpus) continue;
        var num: [8]u8 = undefined;
        const digits = std.fmt.bufPrint(&num, "{d}", .{p.index}) catch continue;
        const khz = sys.readInt(policyPath(&path_buf, digits, "scaling_cur_freq")) orelse continue;
        sum += @floatFromInt(khz);
        n += 1;
    }
    return if (n > 0) sum / n / 1000 else 0;
}

fn cpuWatts() f32 {
    var mw: f32 = 0;
    for (cpu_power.rapl_watts[0..cpu_power.rapl_count]) |w| mw += w;
    return mw / 1000;
}

/// RPM of the CPU's fan and the GPU's: through the EC, or the first fans hwmon shows.
fn fanRpm() [2]u32 {
    if (ec.layout) |l| if (l.curve != null) return .{ ec.rpm(0) orelse 0, ec.rpm(1) orelse 0 };
    var rpm: [2]u32 = .{ 0, 0 };
    var n: usize = 0;
    for (fans[0..nfans]) |*f| {
        if (f.input_fd < 0 or n == 2) continue;
        rpm[n] = @intCast(@max(sys.readIntFd(f.input_fd) orelse 0, 0));
        n += 1;
    }
    return rpm;
}

/// Every fan zcool can run held at `duty`; never under the firmware's speed, as always.
fn holdFans(duty: f32, boost: bool, dt: f32) void {
    boost_barred = !boost;
    for (fans[0..nfans]) |*f| {
        if (f.unusable) continue;
        const demand = if (f.managed) std.math.clamp((duty - f.floor) / @max(255 - f.floor, 1), 0.001, 1) else 1;
        updateFan(f, demand, dt);
    }
}

/// The package held at `level` of the long-term limit its firmware gave it. What it drew on
/// every CPU is no measure: by then zcool held it at the limit, and on the GF63 that read 37 W
/// for a CPU the firmware lets draw 45.
fn holdPower(level_wanted: f32) bool {
    for (0..cpu_power.rapl_count) |i| {
        cpu_power.rapl_reference[i] = @floatFromInt(cpu_power.rapl_base[i]);
    }
    // all of it would be the firmware's limits back, its short-term one too: 107 W on the GF63
    const level = @min(level_wanted, 0.999);
    cpu_power.applied = level;
    return applyRapl(level, false);
}

const Calibration = struct {
    c: *Chip,
    load: calibrate.Load = .{},
    result: calibrate.Result = .{},
    cores: usize,
    last: i64 = 0,

    /// One tick: read everything, keep the CPU at its limit if asked, and watch every chip.
    /// False when calibration has to stop.
    fn tick(self: *Calibration, fan_duty: ?f32, boost: bool, hold_limit: bool) ?f32 {
        sys.sleepMs(250);
        const now = sys.nowMs();
        const dt = @as(f32, @floatFromInt(now - self.last)) / 1000;
        self.last = now;
        if (stop_requested or !readChips(now)) return null;
        sampleCpuPower(now);
        if (fan_duty) |duty| holdFans(duty, boost, dt);
        const c = self.c;
        if (hold_limit) {
            c.throttle.update(&c.thermal, c.limit, c.crit, true, dt);
            // never all of it: that gives the firmware's short-term limit back, and the CPU bursts
            // to it (107 W on the GF63) every time the hold eases, 5 C on the die at once, which
            // is no steady state to measure and ran the die to 75 C on a slow test machine
            applyCpu(@min(c.throttle.level, 0.999));
        }
        for (chips[0..nchips]) |*other| {
            if (!other.controlled() or !other.thermal.ready or other.asleep) continue;
            if (other.thermal.temp > other.limit + 4 or other.emergency) {
                const t = &cal_line;
                t.add(other.name()).add(": ").tenth(other.thermal.temp).add("C, far over its ").whole(other.limit).add("C limit: calibration stops").line();
                return null;
            }
        }
        return dt;
    }

    /// A calibration starts cold. The speed phase holds the die at its limit for ten seconds, and
    /// on a sink still warm from the last load that is power cut, not the CPU's speed: a --long
    /// run right after the short one on the GF63 read 2500 MHz on six CPUs at 13 W, against
    /// 3647 MHz at 33 W from cold. So first every fan at full and no load, until the die is 20 C
    /// under its limit, up to ten minutes. False when calibration has to stop.
    fn coolDown(self: *Calibration) bool {
        const c = self.c;
        const target = @max(c.limit - 20, 40);
        calibrationStep(0);
        var t: f32 = 0;
        var said = false;
        while (t < 600) {
            t += self.tick(253, false, false) orelse return false;
            if (c.thermal.temp <= target) break;
            if (!said) {
                said = true;
                cal_line.add("cooling first: the die is at ").whole(c.thermal.temp).add("C, measuring starts under ").whole(target).add("C").line();
            }
        }
        if (!said) return true;
        const line = &cal_line;
        if (c.thermal.temp <= target) {
            line.add("  ").whole(c.thermal.temp).add("C after ").whole(t).add(" s").line();
        } else {
            line.add("  still ").whole(c.thermal.temp).add("C after ten minutes: measuring anyway").line();
        }
        return true;
    }

    /// The load on `n` CPUs for 10 s, power held at the limit: what it draws and how fast.
    fn coresPoint(self: *Calibration, i: usize, n: usize) bool {
        calibrationStep(n);
        if (sys.root.len == 0) self.load.set(n);
        var watts: f32 = 0;
        var mhz: f32 = 0;
        var samples: f32 = 0;
        var t: f32 = 0;
        while (t < 10) {
            t += self.tick(255, true, true) orelse return false;
            if (t < 5) continue;
            watts += cpuWatts();
            mhz += meanMhz(n);
            samples += 1;
        }
        self.result.core_counts[i] = @intCast(n);
        self.result.cores[i] = .{ .watts = watts / samples, .mhz = mhz / samples };
        const line = &cal_line;
        line.add("  ").num(@intCast(n)).add(if (n == 1) " CPU: " else " CPUs: ").whole(mhz / samples).add(" MHz at ").tenth(watts / samples).add(" W").line();
        return true;
    }

    /// Every CPU loaded at `level` of the long-term limit, every fan at full: how fast it runs.
    /// False once the cooler cannot hold it, or calibration has to stop.
    fn powerPoint(self: *Calibration, i: usize, level: f32) bool {
        calibrationStep(self.cores);
        if (!holdPower(level)) return false;
        var watts: f32 = 0;
        var mhz: f32 = 0;
        var samples: f32 = 0;
        var t: f32 = 0;
        while (t < 10) {
            t += self.tick(255, true, false) orelse return false;
            if (self.c.thermal.temp > self.c.limit + 1) {
                const line = &cal_line;
                line.add("  past ").tenth(cpuWatts()).add(" W the cooler does not hold ").whole(self.c.limit).add("C").line();
                return false;
            }
            if (t < 5) continue;
            watts += cpuWatts();
            mhz += meanMhz(self.cores);
            samples += 1;
        }
        self.result.power[i] = .{ .watts = watts / samples, .mhz = mhz / samples };
        // this close, the next step would take it over: a die follows its power at once
        if (self.c.thermal.temp > self.c.limit - 1.5) {
            const line = &cal_line;
            line.add("  ").tenth(watts / samples).add(" W: ").whole(mhz / samples).add(" MHz, and the cooler holds no more").line();
            return false;
        }
        const line = &cal_line;
        line.add("  ").tenth(watts / samples).add(" W: ").whole(mhz / samples).add(" MHz").line();
        return true;
    }

    /// Every fan at one speed and the CPU held at its limit: the power it settles at is what
    /// that speed carries. False when calibration has to stop.
    fn fanPoint(self: *Calibration, i: usize) bool {
        const p = calibrate.fan_points[i];
        calibrationStep(self.cores);
        var watts = calibrate.Settle{};
        var temps = calibrate.Settle{};
        var t: f32 = 0;
        while (t < 90) {
            t += self.tick(p.duty, p.boost, true) orelse return false;
            watts.add(cpuWatts());
            temps.add(self.c.thermal.temp);
            if (t >= 20 and watts.steady(0.06) and temps.steady(0.015)) break;
        }
        const temp = temps.mean();
        if (temp <= calibrate.ambient + 5) return true;
        // where it settled is near the limit: what it carries at the limit itself
        self.result.carries[i] = watts.mean() * (self.c.limit - calibrate.ambient) / (temp - calibrate.ambient);
        self.result.rpm[i] = fanRpm();
        const line = &cal_line;
        _ = line.add("  fans at ").add(p.name).add(": ").tenth(self.result.carries[i]).add(" W at ").whole(self.c.limit).add("C");
        if (t >= 90) _ = line.add(" (still moving after 90 s)");
        for (self.result.rpm[i], 0..) |rpm, k| {
            if (rpm > 0) _ = line.add(", ").add(ec.fan_names[k]).add(" fan ").num(rpm).add(" rpm");
        }
        line.line();
        return true;
    }
};

fn runCalibrate(long: bool) u8 {
    if (std.os.linux.getuid() != 0 and sys.root.len == 0) {
        sys.print("calibration sets power limits and fans: doas zcool calibrate\n");
        return 1;
    }
    if (dry_run) {
        sys.print("calibration has no dry run: it measures what limits and fans do\n");
        return 2;
    }
    if (openMains()) |fd| {
        defer sys.close(fd);
        if (sys.readIntFd(fd) == 0) {
            sys.print("on battery: plug the charger in, calibration measures full power\n");
            return 1;
        }
    }
    // the service runs the same fans and limits: it stops for the few minutes, and comes back
    var stopped = false;
    if (menu.serviceRunning()) {
        sys.print("stopping the zcool service while calibration runs\n");
        stopped = menu.tellService("d") orelse false;
        var waited: u32 = 0;
        while (menu.serviceRunning() and waited < 50) : (waited += 1) sys.sleepMs(200);
        if (menu.serviceRunning()) {
            sys.print("the service did not stop: doas sv stop zcool, then try again\n");
            return 1;
        }
    }
    defer if (stopped) {
        _ = menu.tellService("u");
        sys.print("the zcool service runs again, with what was measured\n");
    };
    journal.prepare();
    _ = journal.restore();
    gpus.scan();
    discover();
    if (cfg.learn) loadLearned();
    var cpu: ?*Chip = null;
    for (chips[0..nchips]) |*c| {
        if (c.kind == .cpu and c.controlled()) {
            cpu = c;
            break;
        }
    }
    const c = cpu orelse {
        sys.print("no CPU with a limit: nothing to calibrate\n");
        return 1;
    };
    if (cpu_power.rapl_count == 0) {
        sys.print("this CPU shows no power limit (RAPL): nothing to calibrate\n");
        return 1;
    }
    installSignals();
    if (cfg.tcc and undervolt.isIntel() and !undervolt.lockdownActive()) tcc.apply(c.base_limit, false);
    var path_buf: [256]u8 = undefined;
    sys.mkdir(sys.join(&path_buf, &.{ sys.root, "/var/lib/zcool" }));

    const cores = if (sys.root.len > 0) @max(cpu_power.npolicies, 1) else sys.cpuCount();
    var run = Calibration{ .c = c, .cores = cores, .last = sys.nowMs() };
    run.result.limit = c.limit;
    cal_line.add("calibrating ").add(c.name()).add(" at its ").whole(c.limit).add("C limit, ").add(if (long) "up to an hour with the model" else "for 3 to 8 minutes").add("; Ctrl-C stops it and keeps nothing").line();
    const ok = run.coolDown() and measure(&run) and (!long or measureLong(&run));
    run.load.stop();
    calibrationStep(0);
    // power, fans, everything back as it was
    emergencyRestore();
    restoring = false;
    if (!ok) {
        sys.print("calibration stopped: nothing was kept, everything is back as it was\n");
        return 1;
    }
    var buf: [2048]u8 = undefined;
    if (!sys.replaceFile(calibrationPath(&path_buf), calibrate.format(&run.result, &buf))) {
        sys.print("cannot write /var/lib/zcool/calibration\n");
        return 1;
    }
    // what Cooler Boost or full speed carries is what the cooler carries
    const full = if (run.result.carries[0] > 0) run.result.carries[0] else run.result.carries[1];
    if (cfg.learn and full > 0) {
        c.learned = .{ .watts = full, .at = c.limit, .seconds = 60 };
        c.learned_saved = 0;
        saveLearned(sys.nowMs(), true);
    }
    cal = run.result;
    sys.print("\n");
    describeCalibration();
    return 0;
}

fn measure(run: *Calibration) bool {
    sys.print("how fast it runs on one CPU, half of them and all\n");
    const counts = [calibrate.core_points]usize{ 1, @max(run.cores / 2, 1), run.cores };
    for (counts, 0..) |n, i| {
        if (i > 0 and n == counts[i - 1]) continue;
        if (!run.coresPoint(i, n)) return false;
    }
    sys.print("how fast it runs at each power, every CPU loaded and every fan at full\n");
    var held: f32 = calibrate.power_points[0];
    for (calibrate.power_points, 0..) |level, i| {
        if (!run.powerPoint(i, level)) {
            if (stop_requested) return false;
            break;
        }
        held = level;
    }
    // the cooler held at the limit at each fan speed: from the top, so the heat is there
    // already, and from the power it held last, not all of it at once
    run.c.throttle = .{ .level = held };
    var has_curve = false;
    var has_pwm = false;
    var has_boost = false;
    for (fans[0..nfans]) |*f| {
        if (f.unusable) continue;
        has_curve = has_curve or f.ec_curve;
        has_boost = has_boost or f.ec_boost or f.ec_curve;
        has_pwm = has_pwm or (!f.ec_boost and !f.ec_curve and f.nv_index < 0);
    }
    if (!has_curve and !has_pwm and !has_boost) {
        sys.print("no fans zcool can run: what the cooler carries is learned as zcool runs\n");
        return true;
    }
    sys.print("what each fan speed carries at the limit\n");
    for (calibrate.fan_points, 0..) |p, i| {
        // Cooler Boost alone has no speeds between the firmware's curve and full
        if (p.boost and !has_boost) continue;
        if (!p.boost and !has_curve and !has_pwm) continue;
        if (!run.fanPoint(i)) return false;
    }
    return true;
}

/// One steady state in the making: the die and the power recorded tick by tick with every fan at
/// one speed, until the trend has stood still (calibrate.Trend) after `min_s` at least, or `max_s`
/// is up.
const Hold = struct {
    raws: [2400]f32 = undefined,
    times: [2400]f32 = undefined,
    n: usize = 0,
    t: f32 = 0,
    trend: calibrate.Trend = .{},
    watts: calibrate.Trend = .{},
    settled: bool = false,
    over: bool = false,

    /// One tick, recorded. Null when calibration has to stop.
    fn tick(self: *Hold, calib: *Calibration, duty: f32) ?f32 {
        const dt = calib.tick(duty, false, false) orelse return null;
        self.t += dt;
        self.trend.add(calib.c.raw, dt);
        self.watts.add(cpuWatts(), dt);
        if (self.n < self.raws.len) {
            self.raws[self.n] = calib.c.raw;
            self.times[self.n] = self.t;
            self.n += 1;
        }
        return dt;
    }

    /// Ticks on until steady or `max_s`; stops early, `over`, when the die comes within half a
    /// degree of `limit`. False when calibration has to stop.
    fn run(self: *Hold, calib: *Calibration, duty: f32, min_s: f32, max_s: f32, limit: ?f32) bool {
        while (self.t < max_s) {
            _ = self.tick(calib, duty) orelse return false;
            if (limit) |l| if (calib.c.raw > l - 0.5) {
                self.over = true;
                return true;
            };
            if (self.t >= min_s and self.trend.steady(0.3)) {
                self.settled = true;
                return true;
            }
        }
        return true;
    }

    /// Where the die settled: its mean over the last window.
    fn final(self: *const Hold) f32 {
        return self.trend.mean();
    }

    fn meanWatts(self: *const Hold) f32 {
        return self.watts.mean();
    }

    /// How long the die took to cover 63% of the way from a second in (its own jump is over by
    /// then) to where it settled: the sink's time at this fan speed. 0 when it never got there.
    fn tau(self: *const Hold) f32 {
        const target_final = self.final();
        var start_i: usize = 0;
        while (start_i < self.n and self.times[start_i] < 1) start_i += 1;
        if (start_i >= self.n) return 0;
        const from = self.raws[start_i];
        const target = from + 0.63 * (target_final - from);
        var k = start_i + 1;
        while (k < self.n) : (k += 1) {
            const passed = if (target_final > from) self.raws[k] >= target else self.raws[k] <= target;
            if (!passed) continue;
            // between the two readings around the crossing
            const span = self.raws[k] - self.raws[k - 1];
            const part = if (@abs(span) > 1e-3) std.math.clamp((target - self.raws[k - 1]) / span, 0, 1) else 1;
            return self.times[k - 1] + (self.times[k] - self.times[k - 1]) * part - self.times[start_i];
        }
        return 0;
    }
};

var hold: Hold = .{};

/// `--long`: the machine's heat as a model (model.zig). The die's jump per watt from steps of
/// power with every fan at full; the sink's own time from the climb after the last step; the
/// steady state of each fan speed at two powers under what it carries, each held for four times
/// that; the room with the load off. Up to an hour on a laptop; nothing is kept unless the fit
/// holds together and agrees with what the fans were measured carrying.
fn measureLong(run: *Calibration) bool {
    const c = run.c;
    const carries_full = if (run.result.carries[1] > 0) run.result.carries[1] else run.result.carries[0];
    if (carries_full <= 0 or cpu_power.rapl_count == 0) {
        sys.print("no fan point was measured: nothing to model\n");
        return true;
    }
    const base: f32 = @as(f32, @floatFromInt(cpu_power.rapl_base[0])) / 1e6;
    sys.print("the machine's heat as a model: this takes as long as it takes\n");

    // 1. the die's jump per watt: from a low power to the most the cooler carries, three times,
    // every fan at full. Two ticks after the step, the linear part of the sink's rise cancels.
    // The climb after the last step runs on until it settles: that is the sink's own time.
    var jumps: [8]f32 = undefined;
    var njumps: usize = 0;
    const low_w = 0.2 * base;
    const high_w = @min(0.95 * carries_full, 0.999 * base);
    var sink_tau: f32 = 0;
    sys.print("  the die's jump when the power jumps, three times\n");
    var round: usize = 0;
    while (round < 3) : (round += 1) {
        calibrationStep(run.cores);
        if (!holdPower(low_w / base)) return false;
        var settle = calibrate.Settle{};
        var t: f32 = 0;
        while (t < 60) {
            t += run.tick(253, false, false) orelse return false;
            settle.add(c.raw);
            if (t >= 10 and settle.steady(0.01)) break;
        }
        const raw0 = c.raw;
        if (!holdPower(high_w / base)) return false;
        hold = .{};
        _ = hold.tick(run, 253) orelse return false;
        const d1 = c.raw - raw0;
        _ = hold.tick(run, 253) orelse return false;
        const d2 = c.raw - raw0;
        const jump = (2 * d1 - d2) / (high_w - low_w);
        const line = &cal_line;
        _ = line.add("    ").tenth(2 * d1 - d2).add(" C over ").whole(high_w - low_w).add(" W");
        if (jump >= 0.02 and jump <= 0.6) {
            jumps[njumps] = jump;
            njumps += 1;
            line.line();
        } else line.add(": not a jump a die makes, left out").line();
        if (round < 2) continue;
        if (!hold.run(run, 253, 60, 600, c.limit)) return false;
        sink_tau = hold.tau();
        _ = line.add("    the climb after it ");
        if (hold.over) {
            _ = line.add("reached the limit");
        } else if (hold.settled) {
            _ = line.add("settled at ").tenth(hold.final()).add(" C after ").whole(hold.t).add(" s");
        } else _ = line.add("still moved after ").whole(hold.t).add(" s");
        if (sink_tau > 0) _ = line.add(": the sink takes ").whole(sink_tau).add(" s to cover 63%");
        line.line();
    }
    // four of the sink's times for a steady state (2% of the way left), a minute at least; ten
    // to give up waiting
    const hold_min = std.math.clamp(4 * sink_tau, 60, 480);
    const hold_max = std.math.clamp(10 * sink_tau, 240, 600);

    // 2. each fan speed at two powers under what it carries, each held for the sink's time
    var steadies: [8]thermal_model.Steady = undefined;
    var nsteadies: usize = 0;
    cal_line.add("  each fan speed at two powers, each held ").whole(hold_min).add(" to ").whole(hold_max).add(" s").line();
    for ([_]usize{ 1, 2, 3 }) |p| {
        const carries = run.result.carries[p];
        if (carries <= 0) continue;
        // 55% then 90% of what the speed carries, the other way round at the next speed, so that
        // every hold starts a small step from the one before
        const shares: [2]f32 = if (p % 2 == 1) [2]f32{ 0.55, 0.9 } else [2]f32{ 0.9, 0.55 };
        for (shares, 0..) |share, k| {
            const w = carries * share;
            calibrationStep(run.cores);
            if (!holdPower(w / base)) return false;
            hold = .{};
            if (!hold.run(run, thermal_model.point_duty[p], hold_min, hold_max, c.limit)) return false;
            const line = &cal_line;
            _ = line.add("    ").add(thermal_model.point_names[p]).add(" at ").tenth(hold.meanWatts()).add(" W: ");
            if (hold.over or hold.n < 40) {
                line.add("the die reached the limit, left out").line();
                continue;
            }
            const final = hold.final();
            _ = line.tenth(final).add(" C after ").whole(hold.t).add(" s");
            if (!hold.settled) _ = line.add(" (still moving)");
            // the sink's approach, on the second power at a speed only: on the first the fan is
            // still coming down from the speed before, which cools faster than this one does
            const tau = if (k == 1) hold.tau() else 0;
            if (tau > 0) _ = line.add(", the sink takes ").whole(tau).add(" s to cover 63%");
            line.line();
            steadies[nsteadies] = .{ .point = p, .watts = hold.meanWatts(), .die = final, .tau = tau };
            nsteadies += 1;
        }
    }

    // 3. the room: the load off and every fan at full, held as long as a steady state
    sys.print("  the room: the load off, every fan at full\n");
    calibrationStep(0);
    if (sys.root.len == 0) run.load.stop();
    if (!holdPower(0.999)) return false;
    hold = .{};
    if (!hold.run(run, 253, hold_min, hold_max, null)) return false;
    const first = thermal_model.fit(steadies[0..nsteadies], jumps[0..njumps], null);
    var ambient: ?f32 = null;
    if (first.known()) {
        const read = hold.final() - hold.meanWatts() * (1 / first.conductance(253) + first.r_die);
        const line = &cal_line;
        if (read > first.ambient + 2) {
            // the GF63's first long calibration read 38 C off a sink still warm; its lines met at 32
            line.add("    the idle die puts the room at ").whole(read).add(" C, the lines through the steady states meet at ").whole(first.ambient).add(" C: the sink was still warm, the lines win").line();
        } else {
            ambient = read;
            line.add("    the room: ").whole(read).add(" C, the die idling at ").tenth(hold.final()).add(" C on ").tenth(hold.meanWatts()).add(" W").line();
        }
    }
    const fitted = thermal_model.fit(steadies[0..nsteadies], jumps[0..njumps], ambient);
    if (!fitted.known()) {
        sys.print("  too little settled for a model: nothing kept\n");
        return true;
    }
    if (fitted.complaint(carries_full, c.limit)) |why| {
        cal_line.add("  ").add(why).add(": nothing kept; what it found, for the record:").line();
        describeModelOf(&fitted);
        return true;
    }
    var buf: [512]u8 = undefined;
    var path_buf: [256]u8 = undefined;
    if (!sys.replaceFile(modelPath(&path_buf), thermal_model.format(&fitted, &buf))) {
        sys.print("  cannot write /var/lib/zcool/model\n");
        return true;
    }
    model = fitted;
    model_saved = fitted;
    describeModel();
    return true;
}

fn describeCalibration() void {
    if (!cal.known()) return;
    const t = &cal_line;
    t.add("calibrated at ").whole(cal.limit).add("C").line();
    var listed = false;
    for (calibrate.fan_points, 0..) |p, i| {
        if (cal.carries[i] <= 0) continue;
        _ = t.add(if (listed) ", " else "  fans carry: ").add(p.name).add(" ").whole(cal.carries[i]).add(" W");
        listed = true;
    }
    const turning = cal.fansTurning();
    if (turning > 0) _ = t.add("; ").num(turning).add(if (turning == 1) " fan turns" else " fans turn");
    if (cal.curveFollowed()) |followed| _ = t.add(if (followed) "; they follow zcool's curve" else "; they do not follow zcool's curve: Cooler Boost alone");
    t.line();
    if (cal.boostGain()) |gain| if (!cal.boostWorth()) {
        t.add("  Cooler Boost carries ").whole(gain * 100).add("% more than full speed: zcool keeps it for a chip over its limit").line();
    };
    var first = true;
    for (cal.power) |p| {
        if (p.watts <= 0) continue;
        _ = t.add(if (first) "  power: " else ", ").whole(p.watts).add(" W ").whole(p.mhz).add(" MHz");
        first = false;
    }
    if (!first) t.line();
    if (cal.quietFloor()) |floor| t.add("  quiet mode may give up ").whole((1 - floor) * 100).add("% of the power for 5% of the speed").line();
    // the firmware's bursts against what the cooler carries: on the GF63 107 W against 32
    const carries = if (cal.carries[0] > 0) cal.carries[0] else cal.carries[1];
    if (cpu_power.rapl_count > 0 and cpu_power.pl2[0] and carries > 0) {
        const burst: f32 = @as(f32, @floatFromInt(cpu_power.pl2_original[0])) / 1e6;
        if (burst > carries * 2 + 10) {
            _ = t.add("  bursts: the firmware lets it draw ").whole(burst).add(" W for a while and the cooler carries ").whole(carries);
            t.add(" W: burst.ac = ").whole(@round(carries * 2 / 5) * 5).add(" holds them to twice that").line();
        }
    }
    first = true;
    for (cal.cores, cal.core_counts) |p, n| {
        if (p.watts <= 0) continue;
        _ = t.add(if (first) "  on " else ", ").num(n).add(if (n == 1) " CPU " else " CPUs ").whole(p.mhz).add(" MHz at ").whole(p.watts).add(" W");
        first = false;
    }
    if (!first) t.line();
}

const usage =
    \\zcool: keeps chips under the temperature you set, losing as little speed as it can
    \\
    \\  zcool list                what is here: chips, limits, fans
    \\  zcool dump                the CPU's registers, clocks, power limits, GPUs, EC and sensors, read only
    \\  zcool calibrate           3 to 8 minutes of load that teach zcool its fans and power
    \\  zcool calibrate --long    and up to an hour more for a model of the machine's heat
    \\  zcool menu                every setting on one screen; saving restarts the service
    \\  zcool run [--dry-run]     the daemon; --dry-run only says what it would do
    \\  zcool restore             puts back everything an earlier run changed
    \\  zcool undervolt           shows the current offsets
    \\  zcool undervolt off       clears them
    \\  zcool undervolt probe     whether firmware allows offsets: 1 mV, then back
    \\  zcool undervolt reset     forgets that a run with an offset did not end cleanly
    \\
    \\Limits and other settings live in /etc/zcool.conf, see the README.
    \\
;

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    nvidia.setEnvironment(init.environ.block.slice.ptr);
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
        _ = nvidia.resetLeftovers();
        return 0;
    }
    if (std.mem.eql(u8, command, "list")) {
        loadConfig(config_path);
        listChips();
        return 0;
    }
    if (std.mem.eql(u8, command, "calibrate")) {
        loadConfig(config_path);
        return runCalibrate(std.mem.eql(u8, sub, "--long"));
    }
    if (std.mem.eql(u8, command, "dump")) {
        dump.run();
        return 0;
    }
    if (std.mem.eql(u8, command, "menu")) {
        loadConfig(config_path);
        var path_buf: [256]u8 = undefined;
        return runMenu(config_path orelse sys.join(&path_buf, &.{ sys.root, "/etc/zcool.conf" }));
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
        if (std.mem.eql(u8, sub, "probe")) return if (undervolt.probe()) 0 else 1;
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
