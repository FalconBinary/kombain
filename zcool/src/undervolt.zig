// SPDX-License-Identifier: GPL-3.0-or-later

//! Optional voltage offsets. Off unless the config asks, and it never searches on
//! its own: a wrong offset does not burn a chip, but it can crash it and corrupt
//! whatever was being written at that moment.

const std = @import("std");
const sys = @import("sys.zig");
const code = @import("undervolt_code.zig");

pub const Refusal = enum {
    not_intel,
    no_msr,
    no_journal,
    lockdown,
    crashed_last_time,
    locked_by_firmware,
    too_low,
};

pub fn explain(reason: Refusal) []const u8 {
    return switch (reason) {
        .not_intel => "only Intel has a known register for this. On AMD Ryzen use Curve Optimizer in the BIOS",
        .no_msr => "/dev/cpu/0/msr is missing: load the msr module",
        .no_journal => "cannot write /var/lib/zcool, and an offset is never applied without a record of it",
        .lockdown => "kernel lockdown blocks MSR writes. Undervolt in the BIOS instead, or give up lockdown",
        .crashed_last_time => "the last run did not end cleanly after applying an offset. Skipping it; see `zcool undervolt reset`",
        .locked_by_firmware => "the CPU ignored the write: firmware has locked undervolting (Plundervolt fix). Use the BIOS",
        .too_low => "an offset below -125 mV is refused",
    };
}

fn isIntel() bool {
    var path_buf: [256]u8 = undefined;
    var buf: [512]u8 = undefined;
    const text = sys.readFile(sys.join(&path_buf, &.{ sys.root, "/proc/cpuinfo" }), &buf) orelse return false;
    return std.mem.indexOf(u8, text, "GenuineIntel") != null;
}

/// A missing file means no lockdown support in the kernel, so nothing blocks the write.
pub fn lockdownActive() bool {
    var path_buf: [256]u8 = undefined;
    var buf: [64]u8 = undefined;
    const text = sys.readFile(sys.join(&path_buf, &.{ sys.root, "/sys/kernel/security/lockdown" }), &buf) orelse return false;
    return std.mem.indexOf(u8, text, "[none]") == null;
}

fn pendingPath(buf: []u8) [:0]const u8 {
    return sys.join(buf, &.{ sys.root, "/var/lib/zcool/undervolt-pending" });
}

fn writeMsr(fd: i32, value: u64) bool {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    return (sys.pwrite(fd, &bytes, code.msr_address) orelse 0) == 8;
}

fn readMsr(fd: i32) ?u64 {
    var bytes: [8]u8 = undefined;
    if ((sys.pread(fd, &bytes, code.msr_address) orelse 0) != 8) return null;
    return std.mem.readInt(u64, &bytes, .little);
}

const MsrPort = struct {
    fd: i32,

    pub fn write(self: MsrPort, value: u64) bool {
        return writeMsr(self.fd, value);
    }

    pub fn read(self: MsrPort) ?u64 {
        return readMsr(self.fd);
    }
};

fn setPlane(fd: i32, plane: u6, mv: i32) bool {
    return code.setPlane(MsrPort{ .fd = fd }, plane, mv);
}

pub fn apply(core_mv: i32, cache_mv: i32) ?Refusal {
    if (core_mv == 0 and cache_mv == 0) return null;
    if (core_mv < code.max_offset_mv or cache_mv < code.max_offset_mv) return .too_low;
    if (!isIntel()) return .not_intel;
    if (lockdownActive()) return .lockdown;
    var pending_buf: [256]u8 = undefined;
    const pending = pendingPath(&pending_buf);
    if (sys.exists(pending)) return .crashed_last_time;
    var msr_buf: [256]u8 = undefined;
    const fd = sys.openReadWrite(sys.join(&msr_buf, &.{ sys.root, "/dev/cpu/0/msr" })) orelse return .no_msr;
    defer sys.close(fd);

    // written and synced before the first write: if this kills the machine, the next boot knows
    var dir_buf: [256]u8 = undefined;
    var parent_buf: [256]u8 = undefined;
    sys.mkdir(sys.join(&parent_buf, &.{ sys.root, "/var/lib" }));
    sys.mkdir(sys.join(&dir_buf, &.{ sys.root, "/var/lib/zcool" }));
    if (!sys.appendFile(pending, "applied\n")) return .no_journal;

    if (core_mv != 0 and !setPlane(fd, code.core_plane, core_mv)) {
        sys.unlink(pending);
        return .locked_by_firmware;
    }
    if (cache_mv != 0 and !setPlane(fd, code.cache_plane, cache_mv)) {
        sys.unlink(pending);
        _ = setPlane(fd, code.core_plane, 0);
        return .locked_by_firmware;
    }
    return null;
}

/// Called after a stable stretch and on a clean exit: the offset did not take the machine down.
pub fn markStable() void {
    var pending_buf: [256]u8 = undefined;
    sys.unlink(pendingPath(&pending_buf));
}

pub fn clear() bool {
    if (lockdownActive()) return false;
    markStable();
    var msr_buf: [256]u8 = undefined;
    const fd = sys.openReadWrite(sys.join(&msr_buf, &.{ sys.root, "/dev/cpu/0/msr" })) orelse return false;
    defer sys.close(fd);
    return setPlane(fd, code.core_plane, 0) and setPlane(fd, code.cache_plane, 0);
}

pub fn report() void {
    var msr_buf: [256]u8 = undefined;
    var pending_buf: [256]u8 = undefined;
    if (!isIntel()) {
        sys.printf("{s}\n", .{explain(.not_intel)});
        return;
    }
    if (lockdownActive()) sys.printf("{s}\n", .{explain(.lockdown)});
    if (sys.exists(pendingPath(&pending_buf))) sys.printf("{s}\n", .{explain(.crashed_last_time)});
    const fd = sys.openReadWrite(sys.join(&msr_buf, &.{ sys.root, "/dev/cpu/0/msr" })) orelse {
        sys.printf("{s}\n", .{explain(.no_msr)});
        return;
    };
    defer sys.close(fd);
    for ([_]u6{ code.core_plane, code.cache_plane }, [_][]const u8{ "core", "cache" }) |plane, name| {
        if (writeMsr(fd, code.encodeRead(plane))) {
            if (readMsr(fd)) |value| sys.printf("{s}: {d} mV\n", .{ name, code.decodeOffset(value) });
        }
    }
}
