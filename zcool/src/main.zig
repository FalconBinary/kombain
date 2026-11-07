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
    addNvidiaChips();
    addEcFan();
}

/// An MSI laptop's EC: Cooler Boost joins as one of the board's fans, which cool every chip.
fn addEcFan() void {
    if (!cfg.use_ec) return;
    ec.open();
    if (ec.layout == null or !ec.writable or nfans == max_fans) return;
    const id = "ec/cooler_boost";
    if (cfg.isExcluded(id)) return;
    var fan = Fan{ .owner = -1, .ec_boost = true };
    @memcpy(fan.id[0..id.len], id);
    fan.id_len = id.len;
    fans[nfans] = fan;
    nfans += 1;
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
            c.limit = control.clampLimit(wanted, c.crit, 100);
            if (c.limit != wanted) sys.printf("{s}: limit {d:.0} is outside the safe range, using {d:.0}\n", .{ c.name(), wanted, c.limit });
        } else {
            // the driver's own target, when it gives one with room below the slowdown point
            const own = r.gpu_max orelse 0;
            c.limit = if (c.crit > 0 and own >= 50 and own <= c.crit - 5) own else if (c.crit > 0) c.crit - 15 else 85;
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
        if (c.limit == 0) c.limit = control.clampLimit(cfg.limitFor(c.name()) orelse 85, 0, 95);
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
            .gpu => if (c.backend == .nvidia) applyNvidia(c, c.throttle.level) else applyGpu(c, c.throttle.level),
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

fn findMains() void {
    if (cfg.mode_ac == null and cfg.mode_battery == null) return;
    if (ec.layout == null) {
        sys.print("mode.ac and mode.battery need an MSI EC that zcool knows: left as they are\n");
        return;
    }
    var dir_buf: [256]u8 = undefined;
    var dir = sys.Dir.open(sys.join(&dir_buf, &.{ sys.root, "/sys/class/power_supply" })) orelse return;
    defer dir.close();
    while (dir.next()) |entry| {
        var path_buf: [256]u8 = undefined;
        var type_buf: [16]u8 = undefined;
        const kind = sys.readFile(sys.join(&path_buf, &.{ sys.root, "/sys/class/power_supply/", entry, "/type" }), &type_buf) orelse continue;
        if (!std.mem.startsWith(u8, kind, "Mains")) continue;
        mains_fd = sys.openRead(sys.join(&path_buf, &.{ sys.root, "/sys/class/power_supply/", entry, "/online" })) orelse continue;
        return;
    }
}

/// The EC's own power profile follows the power source, where the config names one for it.
fn followPowerSource(now: i64) void {
    if (mains_fd < 0 or now < mains_due_ms) return;
    mains_due_ms = now + 2000;
    const mains = (sys.readIntFd(mains_fd) orelse return) == 1;
    if (on_mains != null and on_mains.? == mains) return;
    on_mains = mains;
    const l = ec.layout.?;
    const mode = if (mains) cfg.mode_ac else cfg.mode_battery;
    const byte = (if (mode) |m| l.profiles[@backingInt(m)] else profile_original) orelse return;
    const current = ec.read(l.profile) orelse return;
    if (current == byte) return;
    const name = if (ec.profileOf(l, byte)) |m| @tagName(m) else "its own";
    const source = if (mains) "on mains" else "on battery";
    if (dry_run) {
        sys.printf("ec: would switch to the {s} profile {s}\n", .{ name, source });
        return;
    }
    if (!ec.writable) return;
    if (profile_original == null) {
        var path_buf: [256]u8 = undefined;
        if (!journal.rememberByte(ec.path(&path_buf), l.profile, null, current)) return;
        profile_original = current;
    }
    if (ec.write(l.profile, byte)) sys.printf("ec: {s} profile {s}\n", .{ name, source });
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
        _ = nvidia.resetLeftovers();
    }
    gpus.scan();
    if (cfg.gpu_sleep) gpus.allowSleep(dry_run);
    discover();
    if (ec.layout != null) sys.printf("ec: {s}, {s}\n", .{ ec.version(), if (ec.writable) "Cooler Boost joins the fans" else "read only: load ec_sys with write_support=1" });
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
            nvidia.stop();
            emergencyRestore();
            return 1;
        }
        sampleCpuPower(now);
        step(dt);
        followPowerSource(now);
        if (undervolted and now - started > 600_000) {
            undervolt.markStable();
            undervolted = false;
        }
        sys.sleepMs(tickMs());
    }
    if (undervolted) undervolt.markStable();
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
    nvidia.stop();
}

/// An MSI laptop's EC: what it reads, and why zcool does or does not use it.
fn listEc() void {
    if (!cfg.use_ec) return;
    ec.open();
    if (!ec.present) {
        if (isMsi()) sys.print("\nMSI laptop: zcool can use its EC (Cooler Boost, charge limit) with debugfs on and ec_sys loaded with write_support=1, see the README\n");
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
    const profile: []const u8 = if (ec.profile()) |m| @tagName(m) else "?";
    const charge: []const u8 = if (ec.chargeLimit()) |c|
        (if (c == 0) "none" else std.fmt.bufPrint(&charge_buf, "{d}%", .{c}) catch "?")
    else
        "not supported";
    sys.printf("  cooler boost {s}, profile {s}, charge limit {s}\n", .{ boost, profile, charge });
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

const usage =
    \\zcool: keeps chips under the temperature you set, losing as little speed as it can
    \\
    \\  zcool list                what is here: chips, limits, fans
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
