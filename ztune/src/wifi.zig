// SPDX-License-Identifier: GPL-3.0-or-later

//! A Wi-Fi card's power saving, through nl80211 over generic netlink, as `iw dev X set
//! power_save` does it. Dozing between beacons saves watts on battery and costs latency: a
//! ping can wait 100 ms for the card to wake.

const std = @import("std");
const sys = @import("sys.zig");

const NLMSG_ERROR = 2;
const NLMSG_DONE = 3;
const NLM_F_REQUEST = 1;
const NLM_F_ACK = 4;
const GENL_ID_CTRL = 0x10;
const CTRL_CMD_GETFAMILY = 3;
const CTRL_ATTR_FAMILY_ID = 1;
const CTRL_ATTR_FAMILY_NAME = 2;
// include/uapi/linux/nl80211.h
const NL80211_CMD_SET_POWER_SAVE = 61;
const NL80211_CMD_GET_POWER_SAVE = 62;
const NL80211_ATTR_IFINDEX = 3;
const NL80211_ATTR_PS_STATE = 93;

pub const max_cards = 4;

pub const Card = struct {
    name: [16]u8 = undefined,
    name_len: u8 = 0,
    ifindex: u32 = 0,
    /// what it was before ztune, to give back
    original: ?bool = null,
    set: ?bool = null,

    pub fn nameOf(self: *const Card) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub var cards: [max_cards]Card = undefined;
pub var ncards: usize = 0;
var fd: i32 = -1;
var family: u16 = 0;
var seq: u32 = 0;

/// The socket and the cards, before the sandbox: it allows no new sockets.
pub fn open() void {
    var dir_buf: [128]u8 = undefined;
    var dir = sys.Dir.open(sys.join(&dir_buf, &.{ sys.root, "/sys/class/net" })) orelse return;
    defer dir.close();
    while (dir.next()) |name| {
        if (ncards == max_cards or name.len > 15) continue;
        var path_buf: [256]u8 = undefined;
        if (!sys.exists(sys.join(&path_buf, &.{ sys.root, "/sys/class/net/", name, "/phy80211" }))) continue;
        const index = sys.readInt(sys.join(&path_buf, &.{ sys.root, "/sys/class/net/", name, "/ifindex" })) orelse continue;
        var card = Card{ .ifindex = @intCast(index) };
        @memcpy(card.name[0..name.len], name);
        card.name_len = @intCast(name.len);
        cards[ncards] = card;
        ncards += 1;
    }
    // under a fake root there is no card to reach
    if (ncards == 0 or sys.root.len > 0) return;
    const sock = sys.netlinkGeneric() orelse return;
    var msg: [64]u8 = undefined;
    var reply: [4096]u8 = undefined;
    seq +%= 1;
    const n = ask(sock, request(&msg, GENL_ID_CTRL, NLM_F_REQUEST, CTRL_CMD_GETFAMILY, &.{.{ .kind = CTRL_ATTR_FAMILY_NAME, .value = "nl80211\x00" }}), &reply) orelse {
        sys.close(sock);
        return;
    };
    family = familyId(reply[0..n]) orelse {
        sys.close(sock);
        return;
    };
    fd = sock;
}

pub fn reachable() bool {
    return fd >= 0;
}

pub fn powerSave(card: *const Card) ?bool {
    if (fd < 0) return null;
    var index: [4]u8 = undefined;
    std.mem.writeInt(u32, &index, card.ifindex, .little);
    var msg: [64]u8 = undefined;
    var reply: [4096]u8 = undefined;
    seq +%= 1;
    const n = ask(fd, request(&msg, family, NLM_F_REQUEST, NL80211_CMD_GET_POWER_SAVE, &.{.{ .kind = NL80211_ATTR_IFINDEX, .value = &index }}), &reply) orelse return null;
    return psState(reply[0..n]);
}

pub fn setPowerSave(card: *const Card, on: bool) bool {
    if (fd < 0) return false;
    var index: [4]u8 = undefined;
    var state: [4]u8 = undefined;
    std.mem.writeInt(u32, &index, card.ifindex, .little);
    std.mem.writeInt(u32, &state, @intFromBool(on), .little);
    var msg: [64]u8 = undefined;
    var reply: [4096]u8 = undefined;
    seq +%= 1;
    const n = ask(fd, request(&msg, family, NLM_F_REQUEST | NLM_F_ACK, NL80211_CMD_SET_POWER_SAVE, &.{
        .{ .kind = NL80211_ATTR_IFINDEX, .value = &index },
        .{ .kind = NL80211_ATTR_PS_STATE, .value = &state },
    }), &reply) orelse return false;
    return acked(reply[0..n]);
}

// ---------------------------------------------------------------- generic netlink

/// One request and its answer: the kernel answers before send returns.
fn ask(sock: i32, msg: []const u8, reply: []u8) ?usize {
    drain(sock);
    if (!sys.send(sock, msg)) return null;
    const n = sys.read(sock, reply) orelse return null;
    drain(sock);
    return n;
}

fn drain(sock: i32) void {
    var spare: [4096]u8 = undefined;
    while (sys.read(sock, &spare)) |got| {
        if (got == 0) break;
    }
}

pub const Attr = struct { kind: u16, value: []const u8 };

/// A netlink header, a generic netlink header and its attributes, each padded to four bytes.
pub fn request(buf: []u8, fam: u16, flags: u16, cmd: u8, attrs: []const Attr) []const u8 {
    var at: usize = 20;
    for (attrs) |a| {
        const len = 4 + a.value.len;
        const padded = (len + 3) & ~@as(usize, 3);
        @memset(buf[at .. at + padded], 0);
        std.mem.writeInt(u16, buf[at..][0..2], @intCast(len), .little);
        std.mem.writeInt(u16, buf[at + 2 ..][0..2], a.kind, .little);
        @memcpy(buf[at + 4 ..][0..a.value.len], a.value);
        at += padded;
    }
    std.mem.writeInt(u32, buf[0..4], @intCast(at), .little);
    std.mem.writeInt(u16, buf[4..6], fam, .little);
    std.mem.writeInt(u16, buf[6..8], flags, .little);
    std.mem.writeInt(u32, buf[8..12], seq, .little);
    std.mem.writeInt(u32, buf[12..16], 0, .little);
    buf[16] = cmd;
    buf[17] = 1;
    buf[18] = 0;
    buf[19] = 0;
    return buf[0..at];
}

const Attrs = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(self: *Attrs) ?Attr {
        if (self.pos + 4 > self.data.len) return null;
        const len = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        const kind = std.mem.readInt(u16, self.data[self.pos + 2 ..][0..2], .little) & 0x3fff;
        if (len < 4 or self.pos + len > self.data.len) return null;
        const value = self.data[self.pos + 4 .. self.pos + len];
        self.pos += (len + 3) & ~@as(usize, 3);
        return .{ .kind = kind, .value = value };
    }
};

/// The attributes of the first message of a reply, or its error.
fn firstMessage(data: []const u8) ?struct { kind: u16, error_code: i32, attrs: Attrs } {
    if (data.len < 16) return null;
    const len = std.mem.readInt(u32, data[0..4], .little);
    const kind = std.mem.readInt(u16, data[4..6], .little);
    if (len < 16 or len > data.len) return null;
    if (kind == NLMSG_ERROR) {
        if (len < 20) return null;
        return .{ .kind = kind, .error_code = std.mem.readInt(i32, data[16..20], .little), .attrs = .{ .data = &.{} } };
    }
    return .{ .kind = kind, .error_code = 0, .attrs = .{ .data = data[@min(len, 20)..len] } };
}

fn familyId(data: []const u8) ?u16 {
    const r = firstMessage(data) orelse return null;
    if (r.kind == NLMSG_ERROR or r.kind == NLMSG_DONE) return null;
    var attrs = r.attrs;
    while (attrs.next()) |a| {
        if (a.kind == CTRL_ATTR_FAMILY_ID and a.value.len >= 2) return std.mem.readInt(u16, a.value[0..2], .little);
    }
    return null;
}

fn psState(data: []const u8) ?bool {
    const r = firstMessage(data) orelse return null;
    if (r.kind == NLMSG_ERROR) return null;
    var attrs = r.attrs;
    while (attrs.next()) |a| {
        if (a.kind == NL80211_ATTR_PS_STATE and a.value.len >= 4) return std.mem.readInt(u32, a.value[0..4], .little) != 0;
    }
    return null;
}

/// An acknowledgement is an error message with code 0.
fn acked(data: []const u8) bool {
    const r = firstMessage(data) orelse return false;
    return r.kind == NLMSG_ERROR and r.error_code == 0;
}

test "a power save request is laid out as nl80211 reads it" {
    var buf: [64]u8 = undefined;
    var index: [4]u8 = undefined;
    var state: [4]u8 = undefined;
    std.mem.writeInt(u32, &index, 3, .little);
    std.mem.writeInt(u32, &state, 1, .little);
    const msg = request(&buf, 0x1c, NLM_F_REQUEST | NLM_F_ACK, NL80211_CMD_SET_POWER_SAVE, &.{
        .{ .kind = NL80211_ATTR_IFINDEX, .value = &index },
        .{ .kind = NL80211_ATTR_PS_STATE, .value = &state },
    });
    try std.testing.expectEqual(@as(usize, 36), msg.len);
    try std.testing.expectEqual(@as(u32, 36), std.mem.readInt(u32, msg[0..4], .little));
    try std.testing.expectEqual(@as(u8, NL80211_CMD_SET_POWER_SAVE), msg[16]);
    try std.testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, msg[20..22], .little));
    try std.testing.expectEqual(@as(u16, NL80211_ATTR_PS_STATE), std.mem.readInt(u16, msg[30..32], .little));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, msg[32..36], .little));
}

test "replies: a family, a power save state, an acknowledgement" {
    var buf: [64]u8 = undefined;
    var id: [2]u8 = undefined;
    std.mem.writeInt(u16, &id, 0x1c, .little);
    try std.testing.expectEqual(@as(u16, 0x1c), familyId(request(&buf, GENL_ID_CTRL, 0, 1, &.{.{ .kind = CTRL_ATTR_FAMILY_ID, .value = &id }})).?);
    var state: [4]u8 = undefined;
    std.mem.writeInt(u32, &state, 1, .little);
    try std.testing.expect(psState(request(&buf, 0x1c, 0, NL80211_CMD_GET_POWER_SAVE, &.{.{ .kind = NL80211_ATTR_PS_STATE, .value = &state }})).?);
    var ack: [36]u8 = @splat(0);
    std.mem.writeInt(u32, ack[0..4], 36, .little);
    std.mem.writeInt(u16, ack[4..6], NLMSG_ERROR, .little);
    try std.testing.expect(acked(&ack));
    std.mem.writeInt(i32, ack[16..20], -1, .little);
    try std.testing.expect(!acked(&ack));
}
