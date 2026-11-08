// SPDX-License-Identifier: GPL-3.0-or-later

//! `zcool dump`: what the machine shows about its power, clocks and heat, in one place and read
//! only. The CPU's registers, as decoded as zcool knows them; its power limits and clocks as
//! Linux sees them; the integrated GPU's clocks; NVIDIA's GPUs as its driver names them; an MSI
//! laptop's EC, byte by byte; and every sensor, fan and duty in hwmon. Nothing is written.

const std = @import("std");
const sys = @import("sys.zig");
const ec = @import("ec.zig");
const undervolt = @import("undervolt.zig");
const Text = @import("text.zig").Text;

var line_buf: [600]u8 = undefined;
var t = Text{ .buf = &line_buf };

pub fn run() void {
    sys.print("zcool dump: read only, nothing here is changed\n");
    cpuRegisters();
    rapl();
    cpufreq();
    igpu();
    nvidiaGpus();
    embedded();
    hwmon();
}

// ---------------------------------------------------------------- the CPU's registers

/// The Intel registers that decide heat and power, and what each one says.
const Register = enum(u32) {
    platform_info = 0xce,
    flex_ratio = 0x194,
    therm_status = 0x19c,
    temperature_target = 0x1a2,
    turbo_ratio_limit = 0x1ad,
    package_therm_status = 0x1b1,
    rapl_power_unit = 0x606,
    package_power_limit = 0x610,
};

fn readMsr(fd: i32, register: Register) ?u64 {
    var bytes: [8]u8 = undefined;
    if ((sys.pread(fd, &bytes, @backingInt(register)) orelse 0) != 8) return null;
    return std.mem.readInt(u64, &bytes, .little);
}

fn cpuRegisters() void {
    sys.print("\ncpu registers\n");
    if (!undervolt.isIntel()) {
        sys.print("  not Intel: zcool knows only Intel's registers\n");
        return;
    }
    var path_buf: [128]u8 = undefined;
    const fd = sys.openRead(sys.join(&path_buf, &.{ sys.root, "/dev/cpu/0/msr" })) orelse {
        sys.print(if (std.os.linux.getuid() != 0) "  only root reads them: doas zcool dump\n" else "  /dev/cpu/0/msr is missing: doas modprobe msr\n");
        return;
    };
    defer sys.close(fd);
    const platform = readMsr(fd, .platform_info) orelse 0;
    if (platform != 0) {
        const p = platformInfo(platform);
        _ = t.add("  0xce   platform info      base ").num(p.base_mhz).add(" MHz, lowest ").num(p.min_mhz);
        t.add(" MHz, turbo ratios ").add(if (p.turbo_programmable) "programmable" else "fixed").line();
    }
    const turbo = readMsr(fd, .turbo_ratio_limit) orelse 0;
    if (turbo != 0) {
        const v = turbo;
        _ = t.add("  0x1ad  turbo by cores     ");
        for (0..8) |i| {
            const ratio: u32 = @truncate((v >> @intCast(8 * i)) & 0xff);
            if (ratio == 0) break;
            _ = t.add(" ").num(@intCast(i + 1)).add(":").num(ratio * 100);
        }
        t.add(" MHz").line();
    }
    if (readMsr(fd, .flex_ratio)) |v| {
        t.add("  0x194  overclocking lock  ").add(if (ocLocked(v)) "set: voltage offsets are refused until a reboot, and the BIOS sets it again" else "clear: voltage offsets may work").line();
    }
    if (readMsr(fd, .temperature_target)) |v| {
        const max: u32 = @truncate((v >> 16) & 0xff);
        const offset: u32 = @truncate((v >> 24) & 0x3f);
        _ = t.add("  0x1a2  temperature target TjMax ").num(max).add("C, offset ").num(offset);
        t.add(": throttles itself from ").num(max -| offset).add("C").line();
        if (readMsr(fd, .package_therm_status)) |s| thermStatus("0x1b1  package now      ", s, max);
        if (readMsr(fd, .therm_status)) |s| thermStatus("0x19c  core 0 now       ", s, max);
    }
    const unit = readMsr(fd, .rapl_power_unit) orelse return;
    if (readMsr(fd, .package_power_limit)) |v| {
        const l = powerLimit(v, unit);
        _ = t.add("  0x610  power limits       PL1 ").tenth(l.pl1_w).add(" W").add(if (l.pl1_on) "" else " (off)");
        _ = t.add(" over ").tenth(l.window_s).add(" s, PL2 ").tenth(l.pl2_w).add(" W").add(if (l.pl2_on) "" else " (off)");
        t.add(if (l.locked) ", locked until a reboot" else "").line();
    }
}

const Platform = struct { base_mhz: u32, min_mhz: u32, turbo_programmable: bool };

fn platformInfo(v: u64) Platform {
    return .{
        .base_mhz = @as(u32, @truncate((v >> 8) & 0xff)) * 100,
        .min_mhz = @as(u32, @truncate((v >> 40) & 0xff)) * 100,
        .turbo_programmable = v & (1 << 28) != 0,
    };
}

/// Bit 20: set by firmware with the Plundervolt fix, it holds the voltage mailbox shut.
fn ocLocked(v: u64) bool {
    return v & (1 << 20) != 0;
}

fn thermStatus(label: []const u8, v: u64, tjmax: u32) void {
    const below: u32 = @truncate((v >> 16) & 0x7f);
    const valid = v & (1 << 31) != 0;
    _ = t.add("  ").add(label).add(" ").num(if (valid) tjmax -| below else 0).add("C");
    t.add(if (v & 1 != 0) ", throttling now" else "").add(if (v & 2 != 0) ", has throttled since this was last cleared" else "").line();
}

const Limits = struct { pl1_w: f32, pl1_on: bool, window_s: f32, pl2_w: f32, pl2_on: bool, locked: bool };

/// MSR_PKG_POWER_LIMIT in the units MSR_RAPL_POWER_UNIT gives: watts are 1/2^(bits 3:0), the
/// time window 2^Y * (1 + Z/4) seconds in units of 1/2^(bits 19:16).
fn powerLimit(v: u64, unit: u64) Limits {
    const watt: f32 = 1.0 / @as(f32, @floatFromInt(@as(u32, 1) << @intCast(unit & 0xf)));
    const second: f32 = 1.0 / @as(f32, @floatFromInt(@as(u32, 1) << @intCast((unit >> 16) & 0xf)));
    const y: u5 = @truncate((v >> 17) & 0x1f);
    const z: f32 = @floatFromInt((v >> 22) & 0x3);
    return .{
        .pl1_w = @as(f32, @floatFromInt(v & 0x7fff)) * watt,
        .pl1_on = v & (1 << 15) != 0,
        .window_s = @as(f32, @floatFromInt(@as(u32, 1) << y)) * (1 + z / 4) * second,
        .pl2_w = @as(f32, @floatFromInt((v >> 32) & 0x7fff)) * watt,
        .pl2_on = v & (1 << 47) != 0,
        .locked = v & (1 << 63) != 0,
    };
}

// ---------------------------------------------------------------- as Linux shows them

fn rapl() void {
    var dir_buf: [128]u8 = undefined;
    var dir = sys.Dir.open(sys.join(&dir_buf, &.{ sys.root, "/sys/class/powercap" })) orelse return;
    defer dir.close();
    var first = true;
    while (dir.next()) |name| {
        if (!std.mem.startsWith(u8, name, "intel-rapl:") or std.mem.count(u8, name, ":") != 1) continue;
        if (first) sys.print("\npower limits, as Linux sees them\n");
        first = false;
        var path_buf: [256]u8 = undefined;
        var text: [32]u8 = undefined;
        const zone = sys.readFile(sys.join(&path_buf, &.{ sys.root, "/sys/class/powercap/", name, "/name" }), &text) orelse "?";
        _ = t.add("  ").add(name).add(" (").add(std.mem.trim(u8, zone, "\n")).add(")");
        for ([_][]const u8{ "0", "1", "2" }) |c| {
            var limit_buf: [256]u8 = undefined;
            var name_buf: [256]u8 = undefined;
            var which: [32]u8 = undefined;
            const uw = sys.readInt(sys.join(&limit_buf, &.{ sys.root, "/sys/class/powercap/", name, "/constraint_", c, "_power_limit_uw" })) orelse continue;
            const what = sys.readFile(sys.join(&name_buf, &.{ sys.root, "/sys/class/powercap/", name, "/constraint_", c, "_name" }), &which) orelse "?";
            _ = t.add("  ").add(std.mem.trim(u8, what, "\n")).add(" ").tenth(@as(f32, @floatFromInt(uw)) / 1e6).add(" W");
        }
        t.line();
    }
}

fn cpufreq() void {
    var path_buf: [256]u8 = undefined;
    var text: [64]u8 = undefined;
    sys.print("\ncpu clocks\n");
    if (sys.readFile(sys.join(&path_buf, &.{ sys.root, "/sys/devices/system/cpu/intel_pstate/status" }), &text)) |s| {
        var turbo_buf: [256]u8 = undefined;
        const no_turbo = sys.readInt(sys.join(&turbo_buf, &.{ sys.root, "/sys/devices/system/cpu/intel_pstate/no_turbo" }));
        t.add("  intel_pstate ").add(std.mem.trim(u8, s, "\n")).add(", turbo ").add(if (no_turbo) |n| (if (n == 0) "on" else "off") else "?").line();
    }
    var dir_buf: [128]u8 = undefined;
    var dir = sys.Dir.open(sys.join(&dir_buf, &.{ sys.root, "/sys/devices/system/cpu/cpufreq" })) orelse return;
    defer dir.close();
    while (dir.next()) |name| {
        if (!std.mem.startsWith(u8, name, "policy")) continue;
        const base = "/sys/devices/system/cpu/cpufreq/";
        var a: [256]u8 = undefined;
        var b: [256]u8 = undefined;
        var c: [256]u8 = undefined;
        var d: [256]u8 = undefined;
        const min = sys.readInt(sys.join(&a, &.{ sys.root, base, name, "/scaling_min_freq" })) orelse 0;
        const max = sys.readInt(sys.join(&b, &.{ sys.root, base, name, "/scaling_max_freq" })) orelse 0;
        const now = sys.readInt(sys.join(&c, &.{ sys.root, base, name, "/scaling_cur_freq" })) orelse 0;
        var epp: [32]u8 = undefined;
        const pref = sys.readFile(sys.join(&d, &.{ sys.root, base, name, "/energy_performance_preference" }), &epp) orelse "-";
        _ = t.add("  ").add(name).add(" ").num(@divTrunc(min, 1000)).add("..").num(@divTrunc(max, 1000));
        t.add(" MHz, now ").num(@divTrunc(now, 1000)).add(", ").add(std.mem.trim(u8, pref, "\n")).line();
    }
}

fn igpu() void {
    var dir_buf: [128]u8 = undefined;
    var dir = sys.Dir.open(sys.join(&dir_buf, &.{ sys.root, "/sys/class/drm" })) orelse return;
    defer dir.close();
    while (dir.next()) |name| {
        if (!std.mem.startsWith(u8, name, "card") or std.mem.indexOfScalar(u8, name, '-') != null) continue;
        var probe: [256]u8 = undefined;
        if (!sys.exists(sys.join(&probe, &.{ sys.root, "/sys/class/drm/", name, "/gt_max_freq_mhz" }))) continue;
        t.add("\nintegrated gpu ").add(name).line();
        _ = t.add(" ");
        for ([_][]const u8{ "min", "max", "cur", "act", "boost", "RP0", "RP1", "RPn" }) |what| {
            var path_buf: [256]u8 = undefined;
            const mhz = sys.readInt(sys.join(&path_buf, &.{ sys.root, "/sys/class/drm/", name, "/gt_", what, "_freq_mhz" })) orelse continue;
            _ = t.add(" ").add(what).add(" ").num(mhz);
        }
        t.add(" MHz").line();
    }
}

fn nvidiaGpus() void {
    var dir_buf: [128]u8 = undefined;
    var dir = sys.Dir.open(sys.join(&dir_buf, &.{ sys.root, "/proc/driver/nvidia/gpus" })) orelse return;
    defer dir.close();
    while (dir.next()) |bus| {
        t.add("\nnvidia ").add(bus).line();
        for ([_][]const u8{ "information", "power" }) |file| {
            var path_buf: [256]u8 = undefined;
            var text: [1024]u8 = undefined;
            const content = sys.readFile(sys.join(&path_buf, &.{ sys.root, "/proc/driver/nvidia/gpus/", bus, "/", file }), &text) orelse continue;
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                if (line.len > 0) t.add("  ").add(line).line();
            }
        }
        sys.print("  its clocks, limits and throttle reasons: nvidia-smi -q -d CLOCK,POWER,PERFORMANCE\n");
    }
}

/// An MSI laptop's EC, all 256 bytes, and what zcool knows of them.
fn embedded() void {
    ec.open();
    if (!ec.present) return;
    t.add("\nec ").add(ec.version()).add(", ").add(if (ec.layout) |l| l.family else "not a firmware zcool knows").line();
    var row: u16 = 0;
    while (row < 256) : (row += 16) {
        _ = t.add("  ").hex(@intCast(row)).add(":");
        var col: u16 = 0;
        while (col < 16) : (col += 1) {
            const b = ec.read(@intCast(row + col));
            if (b) |v| _ = t.add(" ").hex(v) else _ = t.add(" ??");
        }
        t.line();
    }
    const l = ec.layout orelse return;
    _ = t.add("  ").hex(l.cpu_temp).add(" cpu temperature  ").hex(l.cpu_fan).add(" cpu fan %  ");
    t.hex(l.gpu_temp).add(" gpu temperature  ").hex(l.gpu_fan).add(" gpu fan %").line();
    _ = t.add("  ").hex(l.boost).add(" cooler boost  ").hex(l.profile).add(" profile  ");
    t.hex(l.charge).add(" charge limit  ").hex(l.fan_mode).add(" fan mode").line();
    if (l.curve) |c| {
        _ = t.add("  ").hex(c.temps[0]).add(" ").hex(c.temps[1]).add(" curve temperatures  ");
        t.hex(c.speeds[0]).add(" ").hex(c.speeds[1]).add(" curve speeds  ").hex(c.rpm[0]).add(" ").hex(c.rpm[1]).add(" rpm").line();
    }
}

fn hwmon() void {
    var dir_buf: [128]u8 = undefined;
    var dir = sys.Dir.open(sys.join(&dir_buf, &.{ sys.root, "/sys/class/hwmon" })) orelse return;
    defer dir.close();
    sys.print("\nhwmon\n");
    while (dir.next()) |name| {
        var path_buf: [256]u8 = undefined;
        var text: [64]u8 = undefined;
        const chip = sys.readFile(sys.join(&path_buf, &.{ sys.root, "/sys/class/hwmon/", name, "/name" }), &text) orelse continue;
        _ = t.add("  ").add(name).add(" ").add(std.mem.trim(u8, chip, "\n")).add(":");
        var inner_buf: [256]u8 = undefined;
        var inner = sys.Dir.open(sys.join(&inner_buf, &.{ sys.root, "/sys/class/hwmon/", name })) orelse {
            t.line();
            continue;
        };
        defer inner.close();
        while (inner.next()) |file| {
            const temp = std.mem.startsWith(u8, file, "temp") and std.mem.endsWith(u8, file, "_input");
            const fan = std.mem.startsWith(u8, file, "fan") and std.mem.endsWith(u8, file, "_input");
            const pwm = std.mem.startsWith(u8, file, "pwm") and std.mem.indexOfScalar(u8, file, '_') == null;
            if (!temp and !fan and !pwm) continue;
            var value_buf: [256]u8 = undefined;
            const value = sys.readInt(sys.join(&value_buf, &.{ sys.root, "/sys/class/hwmon/", name, "/", file })) orelse continue;
            const label = file[0 .. std.mem.indexOfScalar(u8, file, '_') orelse file.len];
            _ = t.add(" ").add(label).add(" ");
            if (temp) {
                _ = t.tenth(@as(f32, @floatFromInt(value)) / 1000).add("C");
            } else if (fan) {
                _ = t.num(value).add(" rpm");
            } else {
                _ = t.num(value).add("/255");
            }
        }
        t.line();
    }
}

test "the registers decode as Intel documents them" {
    // a GF63's i5-10500H: base 2.5 GHz, lowest 0.8 GHz
    const p = platformInfo((25 << 8) | (8 << 40));
    try std.testing.expectEqual(@as(u32, 2500), p.base_mhz);
    try std.testing.expectEqual(@as(u32, 800), p.min_mhz);
    try std.testing.expect(!p.turbo_programmable);
    try std.testing.expect(ocLocked(1 << 20));
    try std.testing.expect(!ocLocked(0));
    // 1/8 W and 1/1024 s units; PL1 45 W over 2^14 * 1.75 / 1024 = 28 s, PL2 64 W, on and locked
    const unit: u64 = 3 | (10 << 16);
    const y: u64 = 14;
    const z: u64 = 3;
    const v: u64 = (45 * 8) | (1 << 15) | (y << 17) | (z << 22) | ((64 * 8) << 32) | (1 << 47) | (1 << 63);
    const l = powerLimit(v, unit);
    try std.testing.expectEqual(@as(f32, 45), l.pl1_w);
    try std.testing.expectEqual(@as(f32, 64), l.pl2_w);
    try std.testing.expect(l.pl1_on and l.pl2_on and l.locked);
    try std.testing.expectApproxEqAbs(@as(f32, 28), l.window_s, 1e-4);
}
