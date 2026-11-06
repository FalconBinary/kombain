// SPDX-License-Identifier: GPL-3.0-or-later

//! zcool's side of zcool-nvidia, the helper that talks to NVIDIA's library. One request, one
//! line back. A helper that does not answer in time is stopped: an answer that came late
//! would be taken for the answer to the next request.

const std = @import("std");
const sys = @import("sys.zig");

pub const helper_name = "zcool-nvidia";
pub const max_fans = 8;

var child: ?sys.Child = null;
var environment: [*:null]const ?[*:0]const u8 = &empty_environment;
const empty_environment = [_:null]?[*:0]const u8{};
var reply: [512]u8 = undefined;

pub fn setEnvironment(envp: [*:null]const ?[*:0]const u8) void {
    environment = envp;
}

pub fn running() bool {
    return child != null;
}

fn helperPath(buf: []u8) ?[:0]const u8 {
    var exe_buf: [256]u8 = undefined;
    const exe = sys.readLink("/proc/self/exe", &exe_buf) orelse return null;
    const slash = std.mem.lastIndexOfScalar(u8, exe, '/') orelse return null;
    const path = sys.join(buf, &.{ exe[0..slash], "/", helper_name });
    return if (path.len == 0) null else path;
}

fn run(mode: [*:0]const u8) ?sys.Child {
    var path_buf: [300]u8 = undefined;
    const path = helperPath(&path_buf) orelse return null;
    var root_buf: [256]u8 = undefined;
    const root = sys.join(&root_buf, &.{sys.root});
    const argv = [_:null]?[*:0]const u8{ helper_name, mode, "--root", root.ptr };
    return sys.spawn(path, &argv, environment);
}

/// Starts the helper, which installs next to this binary. False when it cannot start.
pub fn start() bool {
    if (child != null) return true;
    child = run("--serve") orelse return false;
    const answer = ask("hello", 5000) orelse return false;
    return std.mem.eql(u8, answer, "ok");
}

/// Sends one request, and returns the line that answers it or null when the helper is gone or too slow.
pub fn ask(request: []const u8, timeout_ms: i64) ?[]const u8 {
    const c = child orelse return null;
    var line_buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{s}\n", .{request}) catch return null;
    if (!sys.write(c.to, line)) return fail();
    var len: usize = 0;
    const deadline = sys.nowMs() + timeout_ms;
    while (true) {
        const left = deadline - sys.nowMs();
        if (left <= 0 or !sys.waitReadable(c.from, @intCast(left))) return fail();
        const n = sys.read(c.from, reply[len..]) orelse return fail();
        if (n == 0) return fail();
        len += n;
        if (std.mem.indexOfScalar(u8, reply[0..len], '\n')) |end| return reply[0..end];
        if (len == reply.len) return fail();
    }
}

fn fail() ?[]const u8 {
    sys.print("zcool-nvidia stopped answering\n");
    stop();
    return null;
}

/// Ends the helper. Its input ends first, and that is when it puts back what it changed.
pub fn stop() void {
    const c = child orelse return;
    child = null;
    sys.close(c.to);
    sys.close(c.from);
    if (!sys.reap(c.pid, 5000)) {
        sys.kill(c.pid, .KILL);
        _ = sys.reap(c.pid, 1000);
    }
}

/// For a crash handler: closing its input is enough for the helper to put everything back.
pub fn closeNow() void {
    if (child) |c| sys.close(c.to);
}

/// After a run that ended without the helper's own cleanup: puts back what the list in
/// /run/zcool/nvidia says was changed. Returns false when there was nothing to do.
pub fn resetLeftovers() bool {
    var path_buf: [256]u8 = undefined;
    if (!sys.exists(sys.join(&path_buf, &.{ sys.root, "/run/zcool/nvidia" }))) return false;
    const c = run("--reset") orelse {
        sys.print("NVIDIA settings were left changed, and zcool-nvidia did not start to put them back\n");
        return true;
    };
    sys.close(c.to);
    while (sys.waitReadable(c.from, 10_000)) {
        const n = sys.read(c.from, &reply) orelse break;
        if (n == 0) break;
        sys.print(reply[0..n]);
    }
    sys.close(c.from);
    if (!sys.reap(c.pid, 10_000)) {
        sys.kill(c.pid, .KILL);
        _ = sys.reap(c.pid, 1000);
    }
    return true;
}

pub const Reading = struct {
    temp: f32 = 0,
    power_mw: ?u32 = null,
    util: ?u32 = null,
    slowdown: ?f32 = null,
    gpu_max: ?f32 = null,
    max_clock: ?u32 = null,
    limit: ?u32 = null,
    limit_min: ?u32 = null,
    limit_max: ?u32 = null,
    limit_default: ?u32 = null,
    fans: u8 = 0,
    fan: [max_fans]u8 = @splat(0),
};

/// `t=67 p=45200 u=34 crit=98 max=87 clk=1590 lim=80000 lmin=40000 lmax=90000 ldef=80000 fans=1 f0=45`.
/// Anything the GPU does not report is left out. No temperature, no reading.
pub fn parse(line: []const u8) ?Reading {
    var r = Reading{};
    var has_temp = false;
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    while (words.next()) |word| {
        const eq = std.mem.indexOfScalar(u8, word, '=') orelse continue;
        const key = word[0..eq];
        const v = std.fmt.parseInt(u32, word[eq + 1 ..], 10) catch continue;
        if (std.mem.eql(u8, key, "t")) {
            if (v == 0 or v >= 125) continue;
            r.temp = @floatFromInt(v);
            has_temp = true;
        } else if (std.mem.eql(u8, key, "p")) {
            r.power_mw = v;
        } else if (std.mem.eql(u8, key, "u")) {
            r.util = @min(v, 100);
        } else if (std.mem.eql(u8, key, "crit")) {
            r.slowdown = @floatFromInt(v);
        } else if (std.mem.eql(u8, key, "max")) {
            r.gpu_max = @floatFromInt(v);
        } else if (std.mem.eql(u8, key, "clk")) {
            r.max_clock = v;
        } else if (std.mem.eql(u8, key, "lim")) {
            r.limit = v;
        } else if (std.mem.eql(u8, key, "lmin")) {
            r.limit_min = v;
        } else if (std.mem.eql(u8, key, "lmax")) {
            r.limit_max = v;
        } else if (std.mem.eql(u8, key, "ldef")) {
            r.limit_default = v;
        } else if (std.mem.eql(u8, key, "fans")) {
            r.fans = @intCast(@min(v, max_fans));
        } else if (key.len == 2 and key[0] == 'f' and key[1] >= '0' and key[1] < '0' + max_fans) {
            r.fan[key[1] - '0'] = @intCast(@min(v, 100));
        }
    }
    return if (has_temp) r else null;
}

test "reads the helper's answer, and only what the GPU reports" {
    const r = parse("t=67 p=45200 u=34 crit=98 max=87 clk=1590 lim=80000 lmin=40000 lmax=90000 ldef=80000 fans=2 f0=45 f1=50").?;
    try std.testing.expectEqual(@as(f32, 67), r.temp);
    try std.testing.expectEqual(@as(?u32, 45200), r.power_mw);
    try std.testing.expectEqual(@as(?u32, 34), r.util);
    try std.testing.expectEqual(@as(?f32, 98), r.slowdown);
    try std.testing.expectEqual(@as(?u32, 1590), r.max_clock);
    try std.testing.expectEqual(@as(?u32, 40000), r.limit_min);
    try std.testing.expectEqual(@as(u8, 2), r.fans);
    try std.testing.expectEqual(@as(u8, 50), r.fan[1]);

    const laptop = parse("t=55 u=0 crit=98 clk=1560").?;
    try std.testing.expect(laptop.limit == null and laptop.fans == 0);
    try std.testing.expect(parse("err init 9") == null);
    try std.testing.expect(parse("t=0 u=0") == null);
    try std.testing.expect(parse("t=hot") == null);
    // more fans than it keeps track of, and a fan number past them, are cut off
    try std.testing.expectEqual(@as(u8, max_fans), parse("t=50 fans=99 f9=20").?.fans);
}
