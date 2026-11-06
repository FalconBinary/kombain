// SPDX-License-Identifier: GPL-3.0-or-later

//! A stand-in for NVIDIA's libnvidia-ml.so.1, for tests/sim.py. Each GPU is a directory of
//! small files under $FAKE_NVML/BUS that the simulator keeps up to date: temp, power, util,
//! limit and the rest, see the functions below. What the library is asked to change it writes
//! back there. Every call that reaches a GPU whose runtime_status (under $FAKE_NVML_SYS) says
//! "suspended" is noted in BUS/woken, and every temperature read in BUS/reads.

const std = @import("std");
const linux = std.os.linux;

const success: c_int = 0;
const invalid: c_int = 2;
const not_supported: c_int = 3;
const not_found: c_int = 6;

var buses: [8][16]u8 = undefined;
var bus_lens: [8]u8 = undefined;
var nbuses: usize = 0;

fn env(name: [:0]const u8) []const u8 {
    return std.mem.span(std.c.getenv(name.ptr) orelse return "");
}

fn printZ(buf: []u8, comptime fmt: []const u8, args: anytype) ?[:0]const u8 {
    const text = std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args) catch return null;
    buf[text.len] = 0;
    return buf[0..text.len :0];
}

fn path(buf: []u8, bus: []const u8, file: []const u8) [:0]const u8 {
    return printZ(buf, "{s}/{s}/{s}", .{ env("FAKE_NVML"), bus, file }) orelse buf[0..0 :0];
}

fn readText(p: [:0]const u8, buf: []u8) ?[]const u8 {
    const fd: i32 = @intCast(@as(isize, @bitCast(linux.open(p.ptr, .{ .ACCMODE = .RDONLY }, 0))));
    if (fd < 0) return null;
    defer _ = linux.close(fd);
    const n: isize = @bitCast(linux.read(fd, buf.ptr, buf.len));
    if (n < 0) return null;
    return std.mem.trim(u8, buf[0..@intCast(n)], " \t\r\n");
}

fn readNum(bus: []const u8, file: []const u8) ?c_uint {
    var path_buf: [512]u8 = undefined;
    var text: [64]u8 = undefined;
    const t = readText(path(&path_buf, bus, file), &text) orelse return null;
    return std.fmt.parseInt(c_uint, t, 10) catch null;
}

fn writeText(p: [:0]const u8, text: []const u8, append: bool) void {
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = !append, .APPEND = append };
    const fd: i32 = @intCast(@as(isize, @bitCast(linux.open(p.ptr, flags, 0o644))));
    if (fd < 0) return;
    defer _ = linux.close(fd);
    _ = linux.write(fd, text.ptr, text.len);
}

fn put(bus: []const u8, file: []const u8, comptime fmt: []const u8, args: anytype) void {
    var path_buf: [512]u8 = undefined;
    var text: [64]u8 = undefined;
    writeText(path(&path_buf, bus, file), std.fmt.bufPrint(&text, fmt, args) catch return, false);
}

fn note(bus: []const u8, file: []const u8) void {
    var path_buf: [512]u8 = undefined;
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    var text: [32]u8 = undefined;
    const line = std.fmt.bufPrint(&text, "{d}\n", .{@as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000)}) catch return;
    writeText(path(&path_buf, bus, file), line, true);
}

fn noteTop(file: []const u8) void {
    var path_buf: [512]u8 = undefined;
    const p = printZ(&path_buf, "{s}/{s}", .{ env("FAKE_NVML"), file }) orelse return;
    writeText(p, "x\n", true);
}

fn asleep(bus: []const u8) bool {
    var path_buf: [512]u8 = undefined;
    var text: [32]u8 = undefined;
    const p = printZ(&path_buf, "{s}/sys/bus/pci/devices/{s}/power/runtime_status", .{ env("FAKE_NVML_SYS"), bus }) orelse return false;
    const state = readText(p, &text) orelse return false;
    return std.mem.eql(u8, state, "suspended");
}

fn busOf(dev: ?*anyopaque) []const u8 {
    const i = @intFromPtr(dev) -% 1;
    if (i >= nbuses) return "";
    const bus = buses[i][0..bus_lens[i]];
    if (asleep(bus)) note(bus, "woken");
    return bus;
}

fn supported(bus: []const u8, file: []const u8) bool {
    return (readNum(bus, file) orelse 0) == 1;
}

export fn nvmlInitWithFlags(flags: c_uint) c_int {
    _ = flags;
    noteTop("inits");
    return success;
}

export fn nvmlInit_v2() c_int {
    noteTop("inits");
    return success;
}

export fn nvmlShutdown() c_int {
    noteTop("shutdowns");
    return success;
}

export fn nvmlDeviceGetHandleByPciBusId_v2(bus_z: [*:0]const u8, dev: *?*anyopaque) c_int {
    const bus = std.mem.span(bus_z);
    if (readNum(bus, "temp") == null or bus.len > 16) return not_found;
    if (asleep(bus)) note(bus, "woken");
    for (0..nbuses) |i| {
        if (std.mem.eql(u8, buses[i][0..bus_lens[i]], bus)) {
            dev.* = @ptrFromInt(i + 1);
            return success;
        }
    }
    if (nbuses == buses.len) return not_found;
    @memcpy(buses[nbuses][0..bus.len], bus);
    bus_lens[nbuses] = @intCast(bus.len);
    nbuses += 1;
    dev.* = @ptrFromInt(nbuses);
    return success;
}

const Temperature = extern struct { version: c_uint, sensor: c_int, temperature: c_int };

export fn nvmlDeviceGetTemperatureV(dev: ?*anyopaque, t: *Temperature) c_int {
    const bus = busOf(dev);
    t.temperature = @intCast(readNum(bus, "temp") orelse return not_found);
    note(bus, "reads");
    return success;
}

export fn nvmlDeviceGetTemperatureThreshold(dev: ?*anyopaque, kind: c_int, out: *c_uint) c_int {
    const bus = busOf(dev);
    out.* = readNum(bus, if (kind == 1) "slowdown" else if (kind == 3) "gpumax" else return not_supported) orelse return not_supported;
    return success;
}

export fn nvmlDeviceGetPowerUsage(dev: ?*anyopaque, out: *c_uint) c_int {
    out.* = readNum(busOf(dev), "power") orelse return not_supported;
    return success;
}

const Utilization = extern struct { gpu: c_uint, memory: c_uint };

export fn nvmlDeviceGetUtilizationRates(dev: ?*anyopaque, out: *Utilization) c_int {
    out.* = .{ .gpu = readNum(busOf(dev), "util") orelse 0, .memory = 0 };
    return success;
}

export fn nvmlDeviceGetPowerManagementLimitConstraints(dev: ?*anyopaque, low: *c_uint, high: *c_uint) c_int {
    const bus = busOf(dev);
    if (!supported(bus, "limit_ok")) return not_supported;
    low.* = readNum(bus, "lmin") orelse return not_supported;
    high.* = readNum(bus, "lmax") orelse return not_supported;
    return success;
}

export fn nvmlDeviceGetPowerManagementLimit(dev: ?*anyopaque, out: *c_uint) c_int {
    const bus = busOf(dev);
    if (!supported(bus, "limit_ok")) return not_supported;
    out.* = readNum(bus, "limit") orelse return not_supported;
    return success;
}

export fn nvmlDeviceGetPowerManagementDefaultLimit(dev: ?*anyopaque, out: *c_uint) c_int {
    const bus = busOf(dev);
    if (!supported(bus, "limit_ok")) return not_supported;
    out.* = readNum(bus, "ldef") orelse return not_supported;
    return success;
}

export fn nvmlDeviceSetPowerManagementLimit(dev: ?*anyopaque, value: c_uint) c_int {
    const bus = busOf(dev);
    if (!supported(bus, "limit_ok")) return not_supported;
    if (value < (readNum(bus, "lmin") orelse 0) or value > (readNum(bus, "lmax") orelse 0)) return invalid;
    put(bus, "limit", "{d}", .{value});
    return success;
}

export fn nvmlDeviceGetMaxClockInfo(dev: ?*anyopaque, kind: c_int, out: *c_uint) c_int {
    if (kind != 0) return not_supported;
    out.* = readNum(busOf(dev), "maxclock") orelse return not_supported;
    return success;
}

export fn nvmlDeviceSetGpuLockedClocks(dev: ?*anyopaque, low: c_uint, high: c_uint) c_int {
    const bus = busOf(dev);
    if (!supported(bus, "clocks_ok")) return not_supported;
    if (low > high) return invalid;
    put(bus, "locked", "{d}", .{high});
    return success;
}

export fn nvmlDeviceResetGpuLockedClocks(dev: ?*anyopaque) c_int {
    const bus = busOf(dev);
    if (!supported(bus, "clocks_ok")) return not_supported;
    put(bus, "locked", "0", .{});
    return success;
}

export fn nvmlDeviceGetNumFans(dev: ?*anyopaque, out: *c_uint) c_int {
    out.* = readNum(busOf(dev), "fans") orelse 0;
    return success;
}

fn fanFile(buf: []u8, index: c_uint, suffix: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "fan{d}{s}", .{ index, suffix }) catch "";
}

export fn nvmlDeviceGetFanSpeed_v2(dev: ?*anyopaque, index: c_uint, out: *c_uint) c_int {
    var name: [16]u8 = undefined;
    out.* = readNum(busOf(dev), fanFile(&name, index, "")) orelse return not_supported;
    return success;
}

export fn nvmlDeviceSetFanSpeed_v2(dev: ?*anyopaque, index: c_uint, percent: c_uint) c_int {
    const bus = busOf(dev);
    var name: [16]u8 = undefined;
    if (index >= (readNum(bus, "fans") orelse 0) or percent > 100) return invalid;
    put(bus, fanFile(&name, index, ""), "{d}", .{percent});
    put(bus, fanFile(&name, index, "_mode"), "manual", .{});
    return success;
}

export fn nvmlDeviceSetDefaultFanSpeed_v2(dev: ?*anyopaque, index: c_uint) c_int {
    const bus = busOf(dev);
    var name: [16]u8 = undefined;
    if (index >= (readNum(bus, "fans") orelse 0)) return invalid;
    put(bus, fanFile(&name, index, "_mode"), "auto", .{});
    return success;
}
