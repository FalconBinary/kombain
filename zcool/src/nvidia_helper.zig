// SPDX-License-Identifier: GPL-3.0-or-later

//! zcool-nvidia: the one part of zcool that needs libc. NVIDIA's own driver puts no sensors
//! in /sys, and its library, NVML, is the only way to read such a GPU or set its limits.
//! zcool starts this when that driver is loaded and asks it one line at a time:
//!
//!     read BUS                 t=67 p=45200 u=34 crit=98 max=87 clk=1590 lim=80000 ... fans=1 f0=45
//!     limit BUS MW|default     ok | no
//!     clocks BUS MHZ|reset     ok | no
//!     fan BUS N PERCENT|auto   ok | no
//!     rest                     ok, after letting go of the driver, so an idle GPU can sleep
//!
//! The library is opened without touching any GPU, and a GPU is only reached when zcool asks,
//! which it does not while the GPU sleeps. When zcool goes, however it goes, this one's input
//! ends and everything it changed goes back. The GPUs it changed are also listed in
//! /run/zcool/nvidia, for `zcool-nvidia --reset` in case this process was killed too.

const std = @import("std");
const sys = @import("sys.zig");
const sandbox = @import("sandbox.zig");

/// The default panic handler symbolises a stack trace and brings most of std.debug with it:
/// 180 KiB of this program's 324, measured. One line says what went wrong, and zcool puts the
/// GPU back when the pipe closes.
pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .signal_stack_size = null,
};

pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(msg: []const u8, _: ?usize) noreturn {
    @branchHint(.cold);
    sys.eprint("zcool-nvidia: internal error: ");
    sys.eprint(msg);
    sys.eprint("\n");
    sys.exit(134);
}

const Device = ?*anyopaque;
const Temperature = extern struct { version: c_uint, sensor: c_int, temperature: c_int };
const Utilization = extern struct { gpu: c_uint, memory: c_uint };

const success = 0;
const init_no_attach: c_uint = 1 << 1;
const sensor_gpu = 0;
const threshold_slowdown = 1;
const threshold_gpu_max = 3;
const clock_graphics = 0;

const Nvml = struct {
    initWithFlags: ?*const fn (c_uint) callconv(.c) c_int = null,
    init: ?*const fn () callconv(.c) c_int = null,
    shutdown: *const fn () callconv(.c) c_int,
    byBus: *const fn ([*:0]const u8, *Device) callconv(.c) c_int,
    temperatureV: ?*const fn (Device, *Temperature) callconv(.c) c_int = null,
    temperature: ?*const fn (Device, c_int, *c_uint) callconv(.c) c_int = null,
    threshold: ?*const fn (Device, c_int, *c_uint) callconv(.c) c_int = null,
    power: ?*const fn (Device, *c_uint) callconv(.c) c_int = null,
    utilization: ?*const fn (Device, *Utilization) callconv(.c) c_int = null,
    limitRange: ?*const fn (Device, *c_uint, *c_uint) callconv(.c) c_int = null,
    limit: ?*const fn (Device, *c_uint) callconv(.c) c_int = null,
    defaultLimit: ?*const fn (Device, *c_uint) callconv(.c) c_int = null,
    setLimit: ?*const fn (Device, c_uint) callconv(.c) c_int = null,
    maxClock: ?*const fn (Device, c_int, *c_uint) callconv(.c) c_int = null,
    lockClocks: ?*const fn (Device, c_uint, c_uint) callconv(.c) c_int = null,
    resetClocks: ?*const fn (Device) callconv(.c) c_int = null,
    numFans: ?*const fn (Device, *c_uint) callconv(.c) c_int = null,
    fanSpeed: ?*const fn (Device, c_uint, *c_uint) callconv(.c) c_int = null,
    setFan: ?*const fn (Device, c_uint, c_uint) callconv(.c) c_int = null,
    defaultFan: ?*const fn (Device, c_uint) callconv(.c) c_int = null,
};

const symbols = .{
    .{ "initWithFlags", "nvmlInitWithFlags" },
    .{ "init", "nvmlInit_v2" },
    .{ "shutdown", "nvmlShutdown" },
    .{ "byBus", "nvmlDeviceGetHandleByPciBusId_v2" },
    .{ "temperatureV", "nvmlDeviceGetTemperatureV" },
    .{ "temperature", "nvmlDeviceGetTemperature" },
    .{ "threshold", "nvmlDeviceGetTemperatureThreshold" },
    .{ "power", "nvmlDeviceGetPowerUsage" },
    .{ "utilization", "nvmlDeviceGetUtilizationRates" },
    .{ "limitRange", "nvmlDeviceGetPowerManagementLimitConstraints" },
    .{ "limit", "nvmlDeviceGetPowerManagementLimit" },
    .{ "defaultLimit", "nvmlDeviceGetPowerManagementDefaultLimit" },
    .{ "setLimit", "nvmlDeviceSetPowerManagementLimit" },
    .{ "maxClock", "nvmlDeviceGetMaxClockInfo" },
    .{ "lockClocks", "nvmlDeviceSetGpuLockedClocks" },
    .{ "resetClocks", "nvmlDeviceResetGpuLockedClocks" },
    .{ "numFans", "nvmlDeviceGetNumFans" },
    .{ "fanSpeed", "nvmlDeviceGetFanSpeed_v2" },
    .{ "setFan", "nvmlDeviceSetFanSpeed_v2" },
    .{ "defaultFan", "nvmlDeviceSetDefaultFanSpeed_v2" },
};

fn load() ?Nvml {
    var lib = std.DynLib.open("libnvidia-ml.so.1") catch return null;
    var n: Nvml = undefined;
    inline for (symbols) |s| {
        const F = @FieldType(Nvml, s[0]);
        switch (@typeInfo(F)) {
            .optional => |o| @field(n, s[0]) = lib.lookup(o.child, s[1]),
            else => @field(n, s[0]) = lib.lookup(F, s[1]) orelse return null,
        }
    }
    if (n.initWithFlags == null and n.init == null) return null;
    if (n.temperatureV == null and n.temperature == null) return null;
    return n;
}

var nvml: ?Nvml = null;
var ready = false;
var sandboxed = false;
/// The library read nothing from a GPU it had not attached: from then on it attaches.
var attach = false;
/// What the last failed call returned, for the error line zcool logs.
var last_rc: c_int = 0;

/// What this process changed on one GPU, to put back.
const Changed = struct {
    bus: [16]u8 = undefined,
    len: u8 = 0,
    limit: bool = false,
    clocks: bool = false,
    fans: u8 = 0,

    fn name(self: *const Changed) []const u8 {
        return self.bus[0..self.len];
    }
};

var changed: [8]Changed = undefined;
var nchanged: usize = 0;

fn listPath(buf: []u8) [:0]const u8 {
    return sys.join(buf, &.{ sys.root, "/run/zcool/nvidia" });
}

fn entryFor(bus: []const u8) ?*Changed {
    for (changed[0..nchanged]) |*c| {
        if (std.mem.eql(u8, c.name(), bus)) return c;
    }
    if (nchanged == changed.len or bus.len > 16) return null;
    const c = &changed[nchanged];
    c.* = .{};
    @memcpy(c.bus[0..bus.len], bus);
    c.len = @intCast(bus.len);
    nchanged += 1;
    // listed before the change, so a kill between the two still finds it
    var path_buf: [256]u8 = undefined;
    var line_buf: [24]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{s}\n", .{bus}) catch return c;
    _ = sys.appendFile(listPath(&path_buf), line);
    return c;
}

/// Reaches the driver. The first time, the sandbox closes behind it: by then the device
/// files exist, and nothing else outside the list below is needed.
fn start() bool {
    const n = nvml orelse return false;
    if (ready) return true;
    const rc = if (n.initWithFlags) |f| f(if (attach) 0 else init_no_attach) else n.init.?();
    ready = rc == success;
    if (!ready) {
        last_rc = rc;
        sys.eprintf("zcool-nvidia: NVIDIA's library did not start ({d})\n", .{rc});
    }
    if (!sandboxed) {
        sandboxed = true;
        confine();
    }
    return ready;
}

fn confine() void {
    var bufs: [10][256]u8 = undefined;
    _ = sandbox.apply(&.{
        "/usr",
        "/lib",
        "/lib64",
        "/etc",
        sys.join(&bufs[0], &.{ sys.root, "/proc" }),
        sys.join(&bufs[1], &.{ sys.root, "/sys" }),
    }, &.{
        sys.join(&bufs[2], &.{ sys.root, "/dev" }),
        sys.join(&bufs[3], &.{ sys.root, "/run/zcool" }),
    });
}

fn rest() void {
    if (!ready) return;
    _ = nvml.?.shutdown();
    ready = false;
}

fn device(bus: []const u8) Device {
    if (!start()) return null;
    var bus_buf: [32]u8 = undefined;
    const bus_z = sys.join(&bus_buf, &.{bus});
    var dev: Device = null;
    const rc = nvml.?.byBus(bus_z.ptr, &dev);
    if (rc != success) {
        last_rc = rc;
        return null;
    }
    return dev;
}

fn temperature(dev: Device) ?c_int {
    const n = nvml.?;
    if (n.temperatureV) |f| {
        var t = Temperature{ .version = @sizeOf(Temperature) | (1 << 24), .sensor = sensor_gpu, .temperature = 0 };
        const rc = f(dev, &t);
        if (rc == success) return t.temperature;
        last_rc = rc;
    }
    if (n.temperature) |f| {
        var t: c_uint = 0;
        const rc = f(dev, sensor_gpu, &t);
        if (rc == success) return @intCast(t);
        last_rc = rc;
    }
    return null;
}

const Line = struct {
    buf: [400]u8 = undefined,
    len: usize = 0,

    fn add(self: *Line, key: []const u8, value: anytype) void {
        const text = std.fmt.bufPrint(self.buf[self.len..], "{s}{s}={d}", .{ if (self.len == 0) "" else " ", key, value }) catch return;
        self.len += text.len;
    }
};

fn read(bus: []const u8) void {
    var dev = device(bus);
    var temp = if (dev != null) temperature(dev) else null;
    // A GPU the library has not attached can answer nothing: attach once and ask again.
    // That costs nothing on a GPU that cannot sleep, and one that can is let go between reads.
    if (temp == null and !attach) {
        attach = true;
        rest();
        dev = device(bus);
        temp = if (dev != null) temperature(dev) else null;
    }
    if (dev == null) return fail("no device");
    const n = nvml.?;
    var line = Line{};
    line.add("t", temp orelse return fail("no temperature"));
    var v: c_uint = 0;
    var w: c_uint = 0;
    if (n.power) |f| if (f(dev, &v) == success) line.add("p", v);
    if (n.utilization) |f| {
        var u = Utilization{ .gpu = 0, .memory = 0 };
        if (f(dev, &u) == success) line.add("u", u.gpu);
    }
    if (n.threshold) |f| {
        if (f(dev, threshold_slowdown, &v) == success) line.add("crit", v);
        if (f(dev, threshold_gpu_max, &v) == success) line.add("max", v);
    }
    if (n.maxClock) |f| if (f(dev, clock_graphics, &v) == success) line.add("clk", v);
    if (n.limit) |f| if (f(dev, &v) == success) line.add("lim", v);
    if (n.limitRange) |f| if (f(dev, &v, &w) == success) {
        line.add("lmin", v);
        line.add("lmax", w);
    };
    if (n.defaultLimit) |f| if (f(dev, &v) == success) line.add("ldef", v);
    if (n.numFans) |f| if (f(dev, &v) == success and v > 0) {
        const fans = @min(v, 8);
        line.add("fans", fans);
        if (n.fanSpeed) |speed| {
            var i: c_uint = 0;
            while (i < fans) : (i += 1) {
                var key: [3]u8 = .{ 'f', '0' + @as(u8, @intCast(i)), 0 };
                if (speed(dev, i, &w) == success) line.add(key[0..2], w);
            }
        }
    };
    answer(line.buf[0..line.len]);
}

/// An error with what the library returned, which `zcool list` and the log show.
fn fail(what: []const u8) void {
    var buf: [64]u8 = undefined;
    answer(std.fmt.bufPrint(&buf, "err {s} (NVML {d})", .{ what, last_rc }) catch "err");
}

fn answer(text: []const u8) void {
    _ = sys.write(1, text);
    _ = sys.write(1, "\n");
}

fn setLimit(bus: []const u8, value: []const u8) bool {
    const dev = device(bus) orelse return false;
    const n = nvml.?;
    const set = n.setLimit orelse return false;
    var target: c_uint = 0;
    if (std.mem.eql(u8, value, "default")) {
        if (n.defaultLimit == null or n.defaultLimit.?(dev, &target) != success) return false;
    } else {
        target = std.fmt.parseInt(c_uint, value, 10) catch return false;
    }
    const entry = entryFor(bus) orelse return false;
    if (set(dev, target) != success) return false;
    entry.limit = !std.mem.eql(u8, value, "default");
    return true;
}

fn setClocks(bus: []const u8, value: []const u8) bool {
    const dev = device(bus) orelse return false;
    const n = nvml.?;
    const entry = entryFor(bus) orelse return false;
    if (std.mem.eql(u8, value, "reset")) {
        const reset = n.resetClocks orelse return false;
        if (reset(dev) != success) return false;
        entry.clocks = false;
        return true;
    }
    const lock = n.lockClocks orelse return false;
    const mhz = std.fmt.parseInt(c_uint, value, 10) catch return false;
    if (lock(dev, 0, mhz) != success) return false;
    entry.clocks = true;
    return true;
}

fn setFan(bus: []const u8, index_text: []const u8, value: []const u8) bool {
    const dev = device(bus) orelse return false;
    const n = nvml.?;
    const index = std.fmt.parseInt(u3, index_text, 10) catch return false;
    const entry = entryFor(bus) orelse return false;
    const bit = @as(u8, 1) << index;
    if (std.mem.eql(u8, value, "auto")) {
        const auto = n.defaultFan orelse return false;
        if (auto(dev, index) != success) return false;
        entry.fans &= ~bit;
        return true;
    }
    const set = n.setFan orelse return false;
    const percent = std.fmt.parseInt(c_uint, value, 10) catch return false;
    if (percent > 100 or set(dev, index, percent) != success) return false;
    entry.fans |= bit;
    return true;
}

/// Everything this process changed, back to the driver's own control.
fn putBack() void {
    for (changed[0..nchanged]) |*c| {
        if (c.limit) _ = setLimit(c.name(), "default");
        if (c.clocks) _ = setClocks(c.name(), "reset");
        var i: u4 = 0;
        while (i < 8) : (i += 1) {
            if (c.fans & (@as(u8, 1) << @intCast(i)) == 0) continue;
            var digit: [1]u8 = .{'0' + @as(u8, i)};
            _ = setFan(c.name(), &digit, "auto");
        }
    }
    nchanged = 0;
    rest();
    var path_buf: [256]u8 = undefined;
    sys.unlink(listPath(&path_buf));
}

/// After a crash: everything that can have been changed on the GPUs in the list goes back.
fn resetListed() u8 {
    var path_buf: [256]u8 = undefined;
    var text: [512]u8 = undefined;
    const list = sys.readFile(listPath(&path_buf), &text) orelse return 0;
    var lines = std.mem.tokenizeScalar(u8, list, '\n');
    var count: u32 = 0;
    while (lines.next()) |bus| {
        const entry = entryFor(bus) orelse continue;
        entry.limit = true;
        entry.clocks = true;
        entry.fans = 0xff;
        count += 1;
    }
    putBack();
    sys.printf("NVIDIA settings put back on {d} GPU(s)\n", .{count});
    return 0;
}

fn handle(request: []const u8) void {
    var words = std.mem.tokenizeScalar(u8, request, ' ');
    const verb = words.next() orelse return;
    const a = words.next() orelse "";
    const b = words.next() orelse "";
    const c = words.next() orelse "";
    if (std.mem.eql(u8, verb, "hello")) return answer(if (nvml != null) "ok" else "err no library");
    if (std.mem.eql(u8, verb, "read")) return read(a);
    if (std.mem.eql(u8, verb, "rest")) {
        rest();
        return answer("ok");
    }
    const done = if (std.mem.eql(u8, verb, "limit"))
        setLimit(a, b)
    else if (std.mem.eql(u8, verb, "clocks"))
        setClocks(a, b)
    else if (std.mem.eql(u8, verb, "fan"))
        setFan(a, b, c)
    else
        false;
    answer(if (done) "ok" else "no");
}

fn serve() u8 {
    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    while (true) {
        const n = sys.read(0, buf[len..]) orelse 0;
        // zcool is gone, however it went
        if (n == 0) break;
        len += n;
        while (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |end| {
            handle(buf[0..end]);
            std.mem.copyForwards(u8, buf[0..], buf[end + 1 .. len]);
            len -= end + 1;
        }
        if (len == buf.len) len = 0;
    }
    putBack();
    return 0;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    var mode: []const u8 = "";
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "--root") and i + 1 < argv.len) {
            i += 1;
            sys.root = std.mem.span(argv[i]);
        } else {
            mode = arg;
        }
    }
    sys.ignoreSigpipe();
    nvml = load();
    if (nvml == null) sys.eprint("zcool-nvidia: libnvidia-ml.so.1 is missing or too old\n");
    if (std.mem.eql(u8, mode, "--reset")) return resetListed();
    if (std.mem.eql(u8, mode, "--serve")) return serve();
    sys.eprint("zcool-nvidia is started by zcool, see `zcool list`\n");
    return 2;
}
