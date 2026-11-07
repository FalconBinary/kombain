// SPDX-License-Identifier: GPL-3.0-or-later

//! The embedded controller of MSI laptops: Cooler Boost (both fans at full), the EC's own
//! power profiles, the battery charge limit, and the temperatures and fan speeds it sees.
//!
//! It is reached through the kernel's ec_sys, which goes through the kernel's own EC driver,
//! so zcool never races it. That needs debugfs and `ec_sys write_support=1`; without write
//! support it is only read. Only firmware listed here is touched, at the addresses the msi-ec
//! project (github.com/BeardOverflow/msi-ec) lists for it.

const std = @import("std");
const sys = @import("sys.zig");

pub const io_path = "/sys/kernel/debug/ec/ec0/io";
const write_support_path = "/sys/module/ec_sys/parameters/write_support";
const version_at = 0xa0;
const version_len = 12;

/// The EC's own power profiles, as MSI's tools name them.
pub const Profile = enum { eco, comfort, sport, turbo };

pub const Layout = struct {
    family: []const u8,
    firmware: []const []const u8,
    boost: u8,
    boost_bit: u3,
    profile: u8,
    /// the byte for each Profile, in its order
    profiles: [4]u8,
    charge: u8,
    cpu_temp: u8,
    cpu_fan: u8,
    gpu_temp: u8,
    gpu_fan: u8,
};

pub const layouts = [_]Layout{
    .{
        // msi-ec's CONF_G1_7
        .family = "GF63/GF65 Thin",
        .firmware = &.{
            "16R1EMS1.105", "16R3EMS1.100", "16R3EMS1.102", "16R3EMS1.104", "16R4EMS1.101",
            "16R4EMS1.102", "16R4EMS2.101", "16R4EMS2.102", "16R5EMS1.101", "16R5EMS1.102",
            "16W1EMS1.102", "16W1EMS1.103", "16W1EMS1.104", "16W1EMS2.103", "16W2EMS1.101",
        },
        .boost = 0x98,
        .boost_bit = 7,
        .profile = 0xf2,
        .profiles = .{ 0xc2, 0xc1, 0xc0, 0xc4 },
        .charge = 0xef,
        .cpu_temp = 0x68,
        .cpu_fan = 0x71,
        .gpu_temp = 0x80,
        .gpu_fan = 0x89,
    },
};

pub fn find(firmware: []const u8) ?*const Layout {
    for (&layouts) |*l| {
        for (l.firmware) |f| if (std.mem.eql(u8, f, firmware)) return l;
    }
    return null;
}

/// The EC was found: its firmware version is known, though maybe not to zcool.
pub var present = false;
/// Firmware listed here: only then is anything read for meaning, or written.
pub var layout: ?*const Layout = null;
/// ec_sys takes writes.
pub var writable = false;
var version_buf: [version_len]u8 = undefined;
var version_n: usize = 0;
var fd: i32 = -1;

pub fn version() []const u8 {
    return version_buf[0..version_n];
}

pub fn path(buf: []u8) [:0]const u8 {
    return sys.join(buf, &.{ sys.root, io_path });
}

/// Opens the EC once and reads its firmware version.
pub fn open() void {
    if (fd >= 0) return;
    var buf: [256]u8 = undefined;
    fd = sys.openReadWrite(path(&buf)) orelse sys.openRead(path(&buf)) orelse return;
    present = true;
    const n = sys.pread(fd, &version_buf, version_at) orelse 0;
    version_n = printable(version_buf[0..n]).len;
    layout = find(version());
    var flag: [8]u8 = undefined;
    const support = sys.readFile(sys.join(&buf, &.{ sys.root, write_support_path }), &flag) orelse "";
    writable = support.len > 0 and support[0] == 'Y';
}

/// The version, up to the first byte that is not printable: the EC pads it with zeros.
fn printable(raw: []const u8) []const u8 {
    for (raw, 0..) |c, i| if (c < 0x21 or c > 0x7e) return raw[0..i];
    return raw;
}

pub fn read(addr: u8) ?u8 {
    if (fd < 0) return null;
    var b: [1]u8 = undefined;
    const n = sys.pread(fd, &b, addr) orelse return null;
    return if (n == 1) b[0] else null;
}

pub fn write(addr: u8, value: u8) bool {
    if (fd < 0 or !writable) return false;
    const n = sys.pwrite(fd, &.{value}, addr) orelse return false;
    return n == 1;
}

/// Changes one bit and leaves the rest of the byte to the firmware, which owns it.
pub fn setBit(addr: u8, bit: u3, on: bool) bool {
    const old = read(addr) orelse return false;
    const new = withBit(old, bit, on);
    return new == old or write(addr, new);
}

pub fn withBit(byte: u8, bit: u3, on: bool) u8 {
    const mask = @as(u8, 1) << bit;
    return if (on) byte | mask else byte & ~mask;
}

pub fn boost() ?bool {
    const l = layout orelse return null;
    const byte = read(l.boost) orelse return null;
    return byte & (@as(u8, 1) << l.boost_bit) != 0;
}

pub fn setBoost(on: bool) bool {
    const l = layout orelse return false;
    return setBit(l.boost, l.boost_bit, on);
}

pub fn profile() ?Profile {
    const l = layout orelse return null;
    return profileOf(l, read(l.profile) orelse return null);
}

pub fn profileOf(l: *const Layout, byte: u8) ?Profile {
    for (l.profiles, 0..) |p, i| if (p == byte) return @fromBackingInt(@intCast(i));
    return null;
}

pub fn setProfile(p: Profile) bool {
    const l = layout orelse return false;
    return write(l.profile, l.profiles[@backingInt(p)]);
}

/// The charge limit in percent: null when this EC takes none, 0 while none is set.
pub fn chargeLimit() ?u8 {
    const l = layout orelse return null;
    return decodeCharge(read(l.charge) orelse return null);
}

/// Bit 7 says the EC supports a limit; the rest is the limit, from 10 to 100.
pub fn decodeCharge(byte: u8) ?u8 {
    if (byte & 0x80 == 0) return null;
    const percent = byte & 0x7f;
    return if (percent >= 10 and percent <= 100) percent else 0;
}

pub fn setChargeLimit(percent: u8) bool {
    const l = layout orelse return false;
    if (percent < 10 or percent > 100) return false;
    return write(l.charge, 0x80 | percent);
}

pub const Readings = struct { cpu_temp: u8, cpu_fan: u8, gpu_temp: u8, gpu_fan: u8 };

pub fn readings() ?Readings {
    const l = layout orelse return null;
    return .{
        .cpu_temp = read(l.cpu_temp) orelse return null,
        .cpu_fan = read(l.cpu_fan) orelse return null,
        .gpu_temp = read(l.gpu_temp) orelse return null,
        .gpu_fan = read(l.gpu_fan) orelse return null,
    };
}

/// The EC's GPU temperature, when it looks real: 0 means the GPU is off or not wired to it.
pub fn gpuTemperature() ?f32 {
    const l = layout orelse return null;
    const t = read(l.gpu_temp) orelse return null;
    return if (t > 0 and t < 125) @floatFromInt(t) else null;
}

test "only firmware msi-ec lists for a layout is known" {
    try std.testing.expect(find("16R5EMS1.102") != null);
    try std.testing.expect(find("16R4EMS1.101") != null);
    try std.testing.expect(find("16R5EMS1.103") == null);
    try std.testing.expect(find("16R5EMS1.10") == null);
    try std.testing.expect(find("") == null);
}

test "the version stops at the padding" {
    try std.testing.expectEqualStrings("16R5EMS1.102", printable("16R5EMS1.102"));
    try std.testing.expectEqualStrings("16R5EMS1.1", printable("16R5EMS1.1\x00\x00"));
    try std.testing.expectEqualStrings("", printable("\xff\xff"));
}

test "the charge limit byte" {
    try std.testing.expect(decodeCharge(0x50) == null);
    try std.testing.expectEqual(@as(u8, 0), decodeCharge(0x80).?);
    try std.testing.expectEqual(@as(u8, 80), decodeCharge(0x80 | 80).?);
    try std.testing.expectEqual(@as(u8, 100), decodeCharge(0x80 | 100).?);
    try std.testing.expectEqual(@as(u8, 0), decodeCharge(0x80 | 120).?);
}

test "a bit changes alone" {
    try std.testing.expectEqual(@as(u8, 0x8d), withBit(0x0d, 7, true));
    try std.testing.expectEqual(@as(u8, 0x0d), withBit(0x8d, 7, false));
    try std.testing.expectEqual(@as(u8, 0x0d), withBit(0x0d, 7, false));
}

test "profiles are read back by their byte" {
    const l = &layouts[0];
    try std.testing.expectEqual(Profile.eco, profileOf(l, 0xc2).?);
    try std.testing.expectEqual(Profile.turbo, profileOf(l, 0xc4).?);
    try std.testing.expect(profileOf(l, 0x00) == null);
}
