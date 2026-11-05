// SPDX-License-Identifier: GPL-3.0-or-later

//! The Intel voltage offset register, MSR 0x150, as documented by the undervolt tools.

const std = @import("std");

pub const msr_address: u64 = 0x150;
pub const core_plane: u6 = 0;
pub const cache_plane: u6 = 2;
/// Enough to matter, not enough to matter much when it is wrong.
pub const max_offset_mv: i32 = -125;

fn offsetField(mv: i32) u64 {
    const units: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(mv)) * 1.024));
    const eleven: u32 = @bitCast(units);
    return @as(u64, eleven & 0x7ff) << 21;
}

pub fn encodeWrite(plane: u6, mv: i32) u64 {
    return (@as(u64, 1) << 63) | (@as(u64, plane) << 40) | (@as(u64, 1) << 36) | (@as(u64, 1) << 32) | offsetField(mv);
}

pub fn encodeRead(plane: u6) u64 {
    return (@as(u64, 1) << 63) | (@as(u64, plane) << 40) | (@as(u64, 1) << 36);
}

pub fn decodeOffset(value: u64) i32 {
    const field: u32 = @truncate((value >> 21) & 0x7ff);
    const signed: i32 = if (field & 0x400 != 0) @as(i32, @intCast(field)) - 0x800 else @intCast(field);
    return @intFromFloat(@round(@as(f32, @floatFromInt(signed)) / 1.024));
}

/// Writes an offset and asks the CPU what it now holds. `port` has write(u64) bool and read() ?u64.
/// A CPU with undervolting locked accepts the write and keeps its old value.
pub fn setPlane(port: anytype, plane: u6, mv: i32) bool {
    if (!port.write(encodeWrite(plane, mv))) return false;
    if (!port.write(encodeRead(plane))) return false;
    const back = port.read() orelse return false;
    return decodeOffset(back) == mv;
}

/// Behaves like the register: a read request is answered with the plane's current offset.
const FakeCpu = struct {
    locked: bool = false,
    offsets: [8]u64 = @splat(0),
    latch: u64 = 0,

    fn write(self: *FakeCpu, value: u64) bool {
        const plane: u3 = @truncate(value >> 40);
        if ((value >> 32) & 1 == 1 and !self.locked) self.offsets[plane] = value & 0xffe00000;
        self.latch = self.offsets[plane];
        return true;
    }

    fn read(self: *FakeCpu) ?u64 {
        return self.latch;
    }
};

test "an offset that takes is confirmed by the CPU" {
    var cpu = FakeCpu{};
    try std.testing.expect(setPlane(&cpu, core_plane, -80));
    try std.testing.expect(setPlane(&cpu, cache_plane, -60));
    try std.testing.expectEqual(@as(i32, -80), decodeOffset(cpu.offsets[core_plane]));
    try std.testing.expectEqual(@as(i32, -60), decodeOffset(cpu.offsets[cache_plane]));
    try std.testing.expect(setPlane(&cpu, core_plane, 0));
    try std.testing.expectEqual(@as(i32, 0), decodeOffset(cpu.offsets[core_plane]));
}

test "a CPU locked by firmware is detected, not assumed to have worked" {
    var cpu = FakeCpu{ .locked = true };
    try std.testing.expect(!setPlane(&cpu, core_plane, -80));
    try std.testing.expectEqual(@as(u64, 0), cpu.offsets[core_plane]);
}

test "matches the values the undervolt tools publish" {
    try std.testing.expectEqual(@as(u64, 0x80000011F0000000), encodeWrite(core_plane, -125));
    try std.testing.expectEqual(@as(u64, 0x80000211F0000000), encodeWrite(cache_plane, -125));
    try std.testing.expectEqual(@as(u64, 0x80000011F9A00000), encodeWrite(core_plane, -50));
    try std.testing.expectEqual(@as(u64, 0x8000001000000000), encodeRead(core_plane));
}

test "what is written reads back" {
    var mv: i32 = 0;
    while (mv >= max_offset_mv) : (mv -= 1) {
        try std.testing.expectEqual(mv, decodeOffset(encodeWrite(core_plane, mv)));
    }
}
