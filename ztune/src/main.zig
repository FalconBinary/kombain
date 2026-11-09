// SPDX-License-Identifier: GPL-3.0-or-later

//! ztune: the rest of the system tuned to what it does now. zcool has the CPU and the GPUs;
//! ztune has how devices sleep, how memory is reclaimed, when the disk is written, and how a
//! build shares the CPU with the desktop, on mains and on battery, while a game or a build runs.
//!
//! Every value it changes is journaled first and goes back when it stops, however it stops.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const journal = @import("journal.zig");
const sandbox = @import("sandbox.zig");
const config = @import("config.zig");
const profile = @import("profile.zig");
const wifi = @import("wifi.zig");
const calibrate = @import("calibrate.zig");
const Text = @import("text.zig").Text;

var cfg = config.Config{};
var dry_run = false;
var stop_requested = false;
var restoring = false;

var line_buf: [512]u8 = undefined;
var out = Text{ .buf = &line_buf };

// ---------------------------------------------------------------- what it sets

/// One file ztune sets, under /sys or /proc/sys.
const Knob = struct {
    name: []const u8,
    path: []const u8,
    /// dirty_bytes and dirty_ratio are one setting: writing one zeroes the other. While the
    /// ratio holds, it is the ratio that goes in the journal, and writing it back is all it takes.
    pair: ?[]const u8 = null,
    last: [24]u8 = undefined,
    last_len: u8 = 0,
    written: bool = false,
    journaled: bool = false,
    missing: bool = false,
    refused: bool = false,

    fn lastValue(self: *const Knob) []const u8 {
        return self.last[0..self.last_len];
    }
};

var aspm = Knob{ .name = "pcie link power", .path = "/sys/module/pcie_aspm/parameters/policy" };
var nmi = Knob{ .name = "nmi watchdog", .path = "/proc/sys/kernel/nmi_watchdog" };
var min_ttl = Knob{ .name = "mglru working set", .path = "/sys/kernel/mm/lru_gen/min_ttl_ms" };
var watermark = Knob{ .name = "kswapd watermark", .path = "/proc/sys/vm/watermark_scale_factor" };
var thp = Knob{ .name = "huge pages", .path = "/sys/kernel/mm/transparent_hugepage/enabled" };
var thp_defrag = Knob{ .name = "huge page defrag", .path = "/sys/kernel/mm/transparent_hugepage/defrag" };
var writeback = Knob{ .name = "writeback every", .path = "/proc/sys/vm/dirty_writeback_centisecs" };
var expire = Knob{ .name = "dirty pages expire", .path = "/proc/sys/vm/dirty_expire_centisecs" };
var dirty = Knob{ .name = "dirty bytes", .path = "/proc/sys/vm/dirty_bytes", .pair = "/proc/sys/vm/dirty_ratio" };
var dirty_bg = Knob{ .name = "background dirty bytes", .path = "/proc/sys/vm/dirty_background_bytes", .pair = "/proc/sys/vm/dirty_background_ratio" };

const max_disks = 16;
var disks: [max_disks]Knob = undefined;
var disk_names: [max_disks][32]u8 = undefined;
var disk_paths: [max_disks][64]u8 = undefined;
var ndisks: usize = 0;

/// What a knob holds now: the chosen word of a sysfs choice, or the number.
fn current(k: *const Knob, buf: []u8) ?[]const u8 {
    var path_buf: [256]u8 = undefined;
    const text = sys.readFile(sys.join(&path_buf, &.{ sys.root, k.path }), buf) orelse return null;
    return profile.chosen(text);
}

fn set(k: *Knob, value: []const u8) void {
    if (k.missing or k.refused) return;
    if (k.written and std.mem.eql(u8, k.lastValue(), value)) return;
    var path_buf: [256]u8 = undefined;
    const path = sys.join(&path_buf, &.{ sys.root, k.path });
    var now_buf: [256]u8 = undefined;
    const now = current(k, &now_buf) orelse {
        k.missing = true;
        return;
    };
    if (!std.mem.eql(u8, now, value)) {
        if (!k.journaled and !dry_run) {
            if (!rememberOriginal(k, path, now)) return;
            k.journaled = true;
        }
        if (dry_run) {
            out.add(k.name).add(": would set ").add(value).add(", now ").add(now).line();
        } else if (!sys.writeFile(path, value)) {
            out.add(k.name).add(": the kernel refused ").add(value).add(", left at ").add(now).line();
            k.refused = true;
            return;
        } else {
            out.add(k.name).add(": ").add(value).add(" (was ").add(now).add(")").line();
        }
    }
    const n = @min(value.len, k.last.len);
    @memcpy(k.last[0..n], value[0..n]);
    k.last_len = @intCast(n);
    k.written = true;
}

fn rememberOriginal(k: *Knob, path: [:0]const u8, now: []const u8) bool {
    if (k.pair) |pair| {
        if (std.mem.eql(u8, now, "0")) {
            var pair_buf: [256]u8 = undefined;
            var value_buf: [32]u8 = undefined;
            const pair_path = sys.join(&pair_buf, &.{ sys.root, pair });
            const ratio = std.mem.trim(u8, sys.readFile(pair_path, &value_buf) orelse return false, " \n");
            return journal.remember(pair_path, ratio);
        }
    }
    return journal.remember(path, now);
}

fn setNumber(k: *Knob, value: u64) void {
    var buf: [24]u8 = undefined;
    var t = Text{ .buf = &buf };
    set(k, t.num(@intCast(value)).str());
}

/// Every disk ztune would set an I/O scheduler for, found again from time to time: USB disks
/// come and go.
fn findDisks() void {
    var dir_buf: [128]u8 = undefined;
    var dir = sys.Dir.open(sys.join(&dir_buf, &.{ sys.root, "/sys/block" })) orelse return;
    defer dir.close();
    while (dir.next()) |name| {
        if (!profile.schedulable(name) or name.len > 24) continue;
        var known = false;
        for (disk_names[0..ndisks], 0..) |*n, i| {
            if (std.mem.eql(u8, std.mem.sliceTo(n, 0), name)) known = true;
            _ = i;
        }
        if (known or ndisks == max_disks) continue;
        @memset(&disk_names[ndisks], 0);
        @memcpy(disk_names[ndisks][0..name.len], name);
        const path = std.fmt.bufPrint(&disk_paths[ndisks], "/sys/block/{s}/queue/scheduler", .{name}) catch continue;
        disks[ndisks] = .{ .name = std.mem.sliceTo(&disk_names[ndisks], 0), .path = path };
        ndisks += 1;
    }
}

fn setSchedulers() void {
    for (disks[0..ndisks], disk_names[0..ndisks]) |*k, *name| {
        const disk = std.mem.sliceTo(name, 0);
        var path_buf: [256]u8 = undefined;
        var rot_buf: [8]u8 = undefined;
        const rotational = std.mem.startsWith(u8, sys.readFile(sys.join(&path_buf, &.{ sys.root, "/sys/block/", disk, "/queue/rotational" }), &rot_buf) orelse "0", "1");
        var avail_buf: [128]u8 = undefined;
        const available = sys.readFile(sys.join(&path_buf, &.{ sys.root, k.path }), &avail_buf) orelse continue;
        if (profile.scheduler(disk, rotational, available)) |want| set(k, want);
    }
}

/// What does not follow the source or the mode, set once.
fn applyAlways() void {
    if (cfg.nmi_watchdog) setNumber(&nmi, profile.nmi_watchdog);
    if (cfg.memory) {
        // MGLRU off, its working set means nothing
        var buf: [32]u8 = undefined;
        var path_buf: [256]u8 = undefined;
        const lru = sys.readFile(sys.join(&path_buf, &.{ sys.root, "/sys/kernel/mm/lru_gen/enabled" }), &buf) orelse "";
        if (lru.len > 0 and !std.mem.startsWith(u8, std.mem.trim(u8, lru, " \n"), "0x0000")) setNumber(&min_ttl, profile.min_ttl_ms);
        setNumber(&watermark, profile.watermark_scale_factor);
        set(&thp_defrag, profile.thp_defrag);
    }
}

fn apply(s: profile.Settings) void {
    if (cfg.aspm) set(&aspm, @tagName(s.aspm));
    if (cfg.memory) set(&thp, @tagName(s.thp));
    if (cfg.disk) {
        setNumber(&writeback, s.writeback_cs);
        setNumber(&expire, s.expire_cs);
        setNumber(&dirty, s.dirty_bytes);
        setNumber(&dirty_bg, s.dirty_background_bytes);
        setSchedulers();
    }
    if (cfg.wifi) setWifi(s.wifi_power_save);
}

fn setWifi(on: bool) void {
    for (wifi.cards[0..wifi.ncards]) |*card| {
        if (card.set == on) continue;
        if (card.original == null) card.original = wifi.powerSave(card) orelse continue;
        if (card.original == on and card.set == null) {
            card.set = on;
            continue;
        }
        if (dry_run) {
            out.add("wifi ").add(card.nameOf()).add(": would set power save ").add(if (on) "on" else "off").line();
        } else if (!wifi.setPowerSave(card, on)) {
            out.add("wifi ").add(card.nameOf()).add(": the driver refused power save ").add(if (on) "on" else "off").line();
        } else {
            out.add("wifi ").add(card.nameOf()).add(": power save ").add(if (on) "on" else "off").line();
        }
        card.set = on;
    }
}

fn restoreWifi() void {
    for (wifi.cards[0..wifi.ncards]) |*card| {
        const original = card.original orelse continue;
        if (card.set != null and card.set.? != original and !dry_run) _ = wifi.setPowerSave(card, original);
    }
}

// ---------------------------------------------------------------- what runs

const ProcTicks = struct { pid: i32, start: u64, ticks: u64 };
const max_tracked = 512;
var seen: [max_tracked]ProcTicks = undefined;
var nseen: usize = 0;
var scanned_once = false;

const Scan = struct {
    game: ?[16]u8 = null,
    /// cores kept busy by build processes since the last scan
    build_cores: f32 = 0,
    build_name: ?[16]u8 = null,
};

/// /proc/PID/stat: the name in parentheses, then fields; utime, stime and starttime are the
/// 14th, 15th and 22nd. The name may hold spaces and parentheses: the last ')' ends it.
pub fn parseStat(text: []const u8) ?struct { comm: []const u8, ticks: u64, start: u64 } {
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    if (close < open) return null;
    var fields = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
    var i: usize = 3;
    var utime: u64 = 0;
    var stime: u64 = 0;
    var start: u64 = 0;
    while (fields.next()) |f| : (i += 1) {
        switch (i) {
            14 => utime = std.fmt.parseInt(u64, f, 10) catch return null,
            15 => stime = std.fmt.parseInt(u64, f, 10) catch return null,
            22 => {
                start = std.fmt.parseInt(u64, f, 10) catch return null;
                break;
            },
            else => {},
        }
    }
    return .{ .comm = text[open + 1 .. close], .ticks = utime + stime, .start = start };
}

var scan_pids: [max_tracked]ProcTicks = undefined;

/// One look at every process: whether a game runs, and how busy a build keeps the CPU.
fn scan(dt: f32) Scan {
    var result = Scan{};
    var dir_buf: [128]u8 = undefined;
    var dir = sys.Dir.open(sys.join(&dir_buf, &.{ sys.root, "/proc" })) orelse return result;
    defer dir.close();
    var n: usize = 0;
    var busy: u64 = 0;
    while (dir.next()) |name| {
        if (name[0] < '0' or name[0] > '9') continue;
        const pid = std.fmt.parseInt(i32, name, 10) catch continue;
        var path_buf: [64]u8 = undefined;
        var stat_buf: [512]u8 = undefined;
        const text = sys.readFile(sys.join(&path_buf, &.{ sys.root, "/proc/", name, "/stat" }), &stat_buf) orelse continue;
        const stat = parseStat(text) orelse continue;
        switch (profile.classify(stat.comm, cfg.games.all(), cfg.builds.all())) {
            .other => {},
            .game => if (result.game == null) {
                var label: [16]u8 = @splat(0);
                @memcpy(label[0..@min(stat.comm.len, 15)], stat.comm[0..@min(stat.comm.len, 15)]);
                result.game = label;
            },
            .build => {
                if (n < max_tracked) {
                    scan_pids[n] = .{ .pid = pid, .start = stat.start, .ticks = stat.ticks };
                    n += 1;
                }
                // a process seen before adds what it used since; a new one all it has used
                var before: u64 = 0;
                for (seen[0..nseen]) |s| {
                    if (s.pid == pid and s.start == stat.start) before = s.ticks;
                }
                busy += stat.ticks -| before;
                if (result.build_name == null) {
                    var label: [16]u8 = @splat(0);
                    @memcpy(label[0..@min(stat.comm.len, 15)], stat.comm[0..@min(stat.comm.len, 15)]);
                    result.build_name = label;
                }
            },
        }
    }
    @memcpy(seen[0..n], scan_pids[0..n]);
    nseen = n;
    // the first look has nothing to compare with
    if (scanned_once and dt > 0) result.build_cores = @as(f32, @floatFromInt(busy)) / 100 / dt;
    scanned_once = true;
    return result;
}

// ---------------------------------------------------------------- builds as SCHED_BATCH

const Batched = struct { pid: i32, start: u64 };
var batched: [max_tracked]Batched = undefined;
var nbatched: usize = 0;

/// A build's processes, and every thread of each, run as SCHED_BATCH: the scheduler takes
/// them for the CPU-bound work they are and never lets one preempt the desktop on waking.
/// What they start inherits it. Only SCHED_OTHER is changed: nothing real-time, nothing idle.
fn batchBuilds() void {
    for (seen[0..nseen]) |p| {
        var already = false;
        for (batched[0..nbatched]) |b| {
            if (b.pid == p.pid and b.start == p.start) already = true;
        }
        if (already or nbatched == max_tracked) continue;
        if (dry_run) continue;
        if (eachThread(p.pid, sys.sched_other, sys.sched_batch) > 0) {
            batched[nbatched] = .{ .pid = p.pid, .start = p.start };
            nbatched += 1;
        }
    }
}

/// Back to SCHED_OTHER, for every process still the one it was.
fn unbatchBuilds() void {
    for (batched[0..nbatched]) |b| {
        var path_buf: [64]u8 = undefined;
        var stat_buf: [512]u8 = undefined;
        var num: [12]u8 = undefined;
        const digits = std.fmt.bufPrint(&num, "{d}", .{b.pid}) catch continue;
        const text = sys.readFile(sys.join(&path_buf, &.{ sys.root, "/proc/", digits, "/stat" }), &stat_buf) orelse continue;
        const stat = parseStat(text) orelse continue;
        if (stat.start != b.start) continue;
        _ = eachThread(b.pid, sys.sched_batch, sys.sched_other);
    }
    nbatched = 0;
}

/// Changes every thread of `pid` that runs `from` to `to`: how many were.
fn eachThread(pid: i32, from: usize, to: usize) usize {
    var changed: usize = 0;
    var num: [12]u8 = undefined;
    const digits = std.fmt.bufPrint(&num, "{d}", .{pid}) catch return 0;
    var dir_buf: [64]u8 = undefined;
    if (sys.Dir.open(sys.join(&dir_buf, &.{ sys.root, "/proc/", digits, "/task" }))) |d| {
        var dir = d;
        defer dir.close();
        while (dir.next()) |name| {
            const tid = std.fmt.parseInt(i32, name, 10) catch continue;
            if (sys.schedPolicy(tid) == from and sys.setSchedPolicy(tid, to)) changed += 1;
        }
    }
    if (changed == 0 and sys.schedPolicy(pid) == from and sys.setSchedPolicy(pid, to)) changed += 1;
    return changed;
}

// ---------------------------------------------------------------- the power source

var mains_fd: i32 = -1;

fn findMains() void {
    var dir_buf: [128]u8 = undefined;
    var dir = sys.Dir.open(sys.join(&dir_buf, &.{ sys.root, "/sys/class/power_supply" })) orelse return;
    defer dir.close();
    while (dir.next()) |name| {
        var path_buf: [256]u8 = undefined;
        var type_buf: [16]u8 = undefined;
        const kind = sys.readFile(sys.join(&path_buf, &.{ sys.root, "/sys/class/power_supply/", name, "/type" }), &type_buf) orelse continue;
        if (!std.mem.startsWith(u8, kind, "Mains")) continue;
        mains_fd = sys.openRead(sys.join(&path_buf, &.{ sys.root, "/sys/class/power_supply/", name, "/online" })) orelse continue;
        return;
    }
}

/// No mains supply to follow is a desktop: always on mains.
fn source() profile.Source {
    if (mains_fd < 0) return .mains;
    return if ((sys.readIntFd(mains_fd) orelse 1) == 0) .battery else .mains;
}

// ---------------------------------------------------------------- the daemon

fn onStop(_: linux.SIG) callconv(.c) void {
    stop_requested = true;
}

fn onCrash(_: linux.SIG) callconv(.c) void {
    restoreAll();
    sys.exit(1);
}

fn installSignals() void {
    var stop = linux.Sigaction{ .handler = .{ .handler = onStop }, .mask = linux.sigemptyset(), .flags = 0 };
    for ([_]linux.SIG{ .TERM, .INT, .HUP }) |signal| _ = linux.sigaction(signal, &stop, null);
    sys.ignoreSigpipe();
    var crash = linux.Sigaction{ .handler = .{ .handler = onCrash }, .mask = linux.sigemptyset(), .flags = 0 };
    for ([_]linux.SIG{ .SEGV, .BUS, .ILL, .FPE, .ABRT }) |signal| _ = linux.sigaction(signal, &crash, null);
}

fn restoreAll() void {
    if (restoring) return;
    restoring = true;
    unbatchBuilds();
    restoreWifi();
    if (!dry_run) _ = journal.restore();
}

pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .signal_stack_size = null,
};

pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(msg: []const u8, _: ?usize) noreturn {
    @branchHint(.cold);
    sys.eprint("ztune: internal error: ");
    sys.eprint(msg);
    sys.eprint("\n");
    restoreAll();
    sys.exit(134);
}

const tick_ms: i64 = 3000;

fn runDaemon() u8 {
    if (!dry_run) {
        journal.prepare();
        const leftovers = journal.restore();
        if (leftovers > 0) out.add("restored ").num(leftovers).add(" value(s) left by an earlier run").line();
    }
    installSignals();
    findMains();
    findDisks();
    if (cfg.wifi) wifi.open();
    if (cfg.wifi and wifi.ncards > 0 and !wifi.reachable() and sys.root.len == 0) sys.print("wifi: nl80211 is not reachable, power saving stays as it is\n");
    var lib_buf: [128]u8 = undefined;
    var run_buf: [128]u8 = undefined;
    var proc_buf: [128]u8 = undefined;
    var sys_buf: [128]u8 = undefined;
    var procsys_buf: [128]u8 = undefined;
    const status = sandbox.apply(
        &.{ sys.join(&proc_buf, &.{ sys.root, "/proc" }), sys.join(&lib_buf, &.{ sys.root, "/var/lib/ztune" }) },
        &.{ sys.join(&sys_buf, &.{ sys.root, "/sys" }), sys.join(&procsys_buf, &.{ sys.root, "/proc/sys" }), sys.join(&run_buf, &.{ sys.root, "/run/ztune" }) },
    );
    out.add("sandbox: ").add(@tagName(status)).line();
    if (dry_run) sys.print("dry run: nothing will be written\n");

    applyAlways();
    var detector = profile.Detector{};
    var last_mode: ?profile.Mode = null;
    var last_source: ?profile.Source = null;
    var last = sys.nowMs();
    var ticks: u32 = 0;
    while (!stop_requested) {
        const now = sys.nowMs();
        const dt = @as(f32, @floatFromInt(now - last)) / 1000;
        last = now;
        const src = source();
        const s = scan(dt);
        const mode = detector.update(cfg.game and s.game != null, if (cfg.build) s.build_cores else 0, dt);
        if (mode != last_mode or src != last_source) {
            _ = out.add("now: ").add(@tagName(mode)).add(" on ").add(@tagName(src));
            if (mode == .game) if (s.game) |g| {
                _ = out.add(", ").add(std.mem.sliceTo(&g, 0)).add(" runs");
            };
            if (mode == .build) if (s.build_name) |b| {
                _ = out.add(", ").add(std.mem.sliceTo(&b, 0)).add(" builds");
            };
            out.line();
            if (last_mode == .build and mode != .build) unbatchBuilds();
            last_mode = mode;
            last_source = src;
        }
        const settings = profile.settings(src, mode);
        apply(settings);
        if (settings.batch and cfg.build) batchBuilds();
        ticks += 1;
        if (ticks % 20 == 0) findDisks();
        sys.sleepMs(tick_ms);
    }
    restoreAll();
    return 0;
}

// ---------------------------------------------------------------- check

fn row(name: []const u8, now: []const u8, want: []const u8, why: []const u8) void {
    _ = out.add("  ").add(name);
    var pad = name.len;
    while (pad < 24) : (pad += 1) _ = out.add(" ");
    _ = out.add(now);
    pad = now.len;
    while (pad < 16) : (pad += 1) _ = out.add(" ");
    _ = out.add(if (std.mem.eql(u8, now, want)) "  " else "->").add(" ").add(want);
    pad = want.len;
    while (pad < 16) : (pad += 1) _ = out.add(" ");
    out.add(why).line();
}

fn checkKnob(k: *const Knob, want: []const u8, why: []const u8, on: bool) void {
    var buf: [256]u8 = undefined;
    const now = current(k, &buf) orelse return row(k.name, "-", "-", "not in this kernel");
    row(k.name, now, if (on) want else now, if (on) why else "left alone by ztune.conf");
}

fn checkNumber(k: *const Knob, want: u64, why: []const u8, on: bool) void {
    var buf: [24]u8 = undefined;
    var t = Text{ .buf = &buf };
    checkKnob(k, t.num(@intCast(want)).str(), why, on);
}

/// What ztune would set now and why, beside what is set.
fn runCheck() u8 {
    findMains();
    findDisks();
    if (cfg.wifi) wifi.open();
    _ = scan(0);
    sys.sleepMs(1000);
    const s = scan(1);
    var detector = profile.Detector{};
    const mode = detector.update(cfg.game and s.game != null, if (cfg.build) s.build_cores else 0, 1);
    const src = source();
    const want = profile.settings(src, mode);
    out.add("ztune: ").add(@tagName(mode)).add(" on ").add(@tagName(src)).add(", what ztune sets now beside what is set").line();
    out.add("  setting                 now                ztune            why").line();
    checkKnob(&aspm, @tagName(want.aspm), if (src == .battery) "links sleep deep on battery" else if (mode == .game) "no link wakes late in a game" else "the firmware's own on mains", cfg.aspm);
    for (wifi.cards[0..wifi.ncards]) |*card| {
        const ps = wifi.powerSave(card);
        var label_buf: [32]u8 = undefined;
        var label = Text{ .buf = &label_buf };
        _ = label.add("wifi ").add(card.nameOf()).add(" power save");
        const now: []const u8 = if (ps) |p| (if (p) "on" else "off") else "?";
        row(label.str(), now, if (!cfg.wifi) now else if (want.wifi_power_save) "on" else "off", if (!cfg.wifi) "left alone by ztune.conf" else if (want.wifi_power_save) "watts on battery" else "no 100 ms waits on mains");
    }
    checkNumber(&nmi, profile.nmi_watchdog, "a perf counter and wakeups nobody uses", cfg.nmi_watchdog);
    checkNumber(&min_ttl, profile.min_ttl_ms, "out of memory ends a process, no thrashing", cfg.memory);
    checkNumber(&watermark, profile.watermark_scale_factor, "kswapd reclaims early, allocations do not wait", cfg.memory);
    checkKnob(&thp, @tagName(want.thp), if (want.thp == .always) "a compiler gains from huge pages" else "huge pages for those that ask", cfg.memory);
    checkKnob(&thp_defrag, profile.thp_defrag, "no compaction in an allocation's path", cfg.memory);
    checkNumber(&writeback, want.writeback_cs, if (src == .battery) "the disk wakes once a minute" else "the default's rhythm", cfg.disk);
    checkNumber(&expire, want.expire_cs, if (src == .battery) "the disk wakes once a minute" else "the default's rhythm", cfg.disk);
    checkNumber(&dirty, want.dirty_bytes, if (mode == .build) "a build writes many objects" else "a flush never stalls the desktop", cfg.disk);
    checkNumber(&dirty_bg, want.dirty_background_bytes, "writing starts early and in small steps", cfg.disk);
    for (disks[0..ndisks], disk_names[0..ndisks]) |*k, *name| {
        const disk = std.mem.sliceTo(name, 0);
        var path_buf: [256]u8 = undefined;
        var buf: [128]u8 = undefined;
        var rot_buf: [8]u8 = undefined;
        const available = sys.readFile(sys.join(&path_buf, &.{ sys.root, k.path }), &buf) orelse continue;
        const rotational = std.mem.startsWith(u8, sys.readFile(sys.join(&path_buf, &.{ sys.root, "/sys/block/", disk, "/queue/rotational" }), &rot_buf) orelse "0", "1");
        const choice = profile.scheduler(disk, rotational, available) orelse profile.chosen(available);
        var label_buf: [40]u8 = undefined;
        var label = Text{ .buf = &label_buf };
        _ = label.add(disk).add(" scheduler");
        row(label.str(), profile.chosen(available), if (cfg.disk) choice else profile.chosen(available), if (std.mem.startsWith(u8, disk, "nvme")) "NVMe queues in hardware" else if (std.mem.eql(u8, choice, "none")) "its host schedules" else if (rotational) "a spinning disk keeps reads coming" else "an SSD on SATA");
    }
    if (mode == .build) sys.print("  a build runs: its processes run as SCHED_BATCH, the desktop first\n");
    var cal_buf: [256]u8 = undefined;
    var path_buf: [128]u8 = undefined;
    if (sys.readFile(sys.join(&path_buf, &.{ sys.root, "/var/lib/ztune/jobs" }), &cal_buf)) |jobs| {
        out.add("  builds run ").add(std.mem.trim(u8, jobs, " \n")).add(" jobs, as `ztune calibrate` found fastest").line();
    } else {
        sys.print("  not calibrated: doas ztune calibrate, plugged in, a minute\n");
    }
    if (std.os.linux.getuid() != 0 and sys.root.len == 0) sys.print("  only root sets these: doas ztune run --dry-run says what it would do\n");
    return 0;
}

// ---------------------------------------------------------------- calibrate

fn runCalibrate() u8 {
    if (std.os.linux.getuid() != 0 and sys.root.len == 0) {
        sys.print("calibration writes /etc/profile.d/ztune.sh: doas ztune calibrate\n");
        return 1;
    }
    var path_buf: [256]u8 = undefined;
    for ([_][]const u8{ "/var", "/var/lib", "/var/lib/ztune", "/etc", "/etc/profile.d" }) |dir| sys.mkdir(sys.join(&path_buf, &.{ sys.root, dir }));
    var jobs = cfg.jobs;
    if (jobs == 0) {
        installSignals();
        const cpus: u16 = @intCast(@min(sys.cpuCount(), calibrate.max_workers));
        var steps_buf: [calibrate.max_points]u16 = undefined;
        const steps = calibrate.steps(cpus, &steps_buf);
        var points: [calibrate.max_points]calibrate.Point = undefined;
        var load = calibrate.Load.init() orelse {
            sys.print("cannot share memory with the workers\n");
            return 1;
        };
        out.add("calibrating builds on ").num(cpus).add(" CPUs, about ").num(@intCast(steps.len * 11)).add(" s; Ctrl-C stops it and keeps nothing").line();
        var base: f32 = 0;
        for (steps, 0..) |n, i| {
            load.start(n);
            sys.sleepMs(3000);
            const before = load.total();
            const started = sys.nowMs();
            sys.sleepMs(8000);
            const rate = @as(f32, @floatFromInt(load.total() - before)) * 1000 / @as(f32, @floatFromInt(sys.nowMs() - started));
            load.stop();
            if (stop_requested) {
                sys.print("calibration stopped: nothing was kept\n");
                return 1;
            }
            points[i] = .{ .jobs = n, .rate = rate };
            if (i == 0) base = @max(rate, 1);
            out.add("  ").num(n).add(if (n == 1) " job:  " else " jobs: ").tenth(rate / base).add("x as fast as one").line();
        }
        jobs = calibrate.best(points[0..steps.len]);
        out.add("fastest with the fewest jobs: ").num(jobs).line();
    } else {
        out.add("jobs = ").num(jobs).add(" in ztune.conf: written as it is").line();
    }
    var num_buf: [12]u8 = undefined;
    var t = Text{ .buf = &num_buf };
    _ = t.num(jobs).add("\n");
    var script_buf: [512]u8 = undefined;
    if (!sys.replaceFile(sys.join(&path_buf, &.{ sys.root, "/var/lib/ztune/jobs" }), t.str()) or
        !sys.replaceFile(sys.join(&path_buf, &.{ sys.root, "/etc/profile.d/ztune.sh" }), calibrate.script(jobs, &script_buf)))
    {
        sys.print("cannot write /var/lib/ztune/jobs or /etc/profile.d/ztune.sh\n");
        return 1;
    }
    sys.print("written to /etc/profile.d/ztune.sh: a new login shell builds with it\n");
    return 0;
}

// ---------------------------------------------------------------- main

fn loadConfig(path_arg: ?[:0]const u8) void {
    var path_buf: [256]u8 = undefined;
    var text_buf: [8192]u8 = undefined;
    const path = path_arg orelse sys.join(&path_buf, &.{ sys.root, "/etc/ztune.conf" });
    const text = sys.readFile(path, &text_buf) orelse return;
    cfg = config.parse(text);
    if (cfg.bad_lines > 0) out.add(path).add(": skipped ").num(cfg.bad_lines).add(" line(s) that make no sense").line();
}

const usage =
    \\ztune: the system tuned to what it does now, on mains and on battery
    \\
    \\  ztune check               what it would set now and why, beside what is set
    \\  ztune run [--dry-run]     the daemon; --dry-run only says what it would do
    \\  ztune calibrate           how many jobs builds run fastest with, about a minute
    \\  ztune restore             puts back everything an earlier run changed
    \\
    \\Settings live in /etc/ztune.conf, see the README.
    \\
;

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    var command: []const u8 = "";
    var config_path: ?[:0]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--root") and i + 1 < argv.len) {
            i += 1;
            sys.root = std.mem.span(argv[i]);
        } else if (std.mem.eql(u8, arg, "--config") and i + 1 < argv.len) {
            i += 1;
            config_path = std.mem.span(argv[i]);
        } else if (command.len == 0) {
            command = arg;
        }
    }
    if (std.mem.eql(u8, command, "restore")) {
        out.add("restored ").num(journal.restore()).add(" value(s)").line();
        return 0;
    }
    loadConfig(config_path);
    if (std.mem.eql(u8, command, "run")) return runDaemon();
    if (std.mem.eql(u8, command, "check")) return runCheck();
    if (std.mem.eql(u8, command, "calibrate")) return runCalibrate();
    sys.print(usage);
    return if (command.len == 0 or std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) 0 else 2;
}

test "a process's name and times from /proc/PID/stat" {
    const s = parseStat("4242 (cc1 (copy) x) R 1 2 3 4 5 6 7 8 9 10 120 30 0 0 20 0 1 0 98765 0 0").?;
    try std.testing.expectEqualStrings("cc1 (copy) x", s.comm);
    try std.testing.expectEqual(@as(u64, 150), s.ticks);
    try std.testing.expectEqual(@as(u64, 98765), s.start);
    try std.testing.expect(parseStat("garbage") == null);
}
