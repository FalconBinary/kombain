// SPDX-License-Identifier: GPL-3.0-or-later

//! /etc/ztune.conf: `key = value` lines, `#` starts a comment.
//!
//!     aspm = no            leave PCIe link power alone
//!     wifi = no            leave Wi-Fi power saving alone
//!     memory = no          leave MGLRU, huge pages and kswapd's watermark alone
//!     disk = no            leave writeback and the I/O schedulers alone
//!     nmi_watchdog = no    leave the NMI watchdog on
//!     build = no           no build mode
//!     game = no            no game mode
//!     game.add = mygame    one more process name that means a game runs
//!     build.add = tsc      one more that means a build runs
//!     jobs = 8             what `ztune calibrate` would set, set by hand

const std = @import("std");

pub const max_names = 16;

pub const Names = struct {
    buf: [max_names][16]u8 = undefined,
    lens: [max_names]u8 = undefined,
    n: usize = 0,
    slices: [max_names][]const u8 = undefined,

    fn add(self: *Names, name: []const u8) bool {
        if (self.n == max_names or name.len == 0 or name.len > 15) return false;
        @memcpy(self.buf[self.n][0..name.len], name);
        self.lens[self.n] = @intCast(name.len);
        self.n += 1;
        return true;
    }

    pub fn all(self: *Names) []const []const u8 {
        for (0..self.n) |i| self.slices[i] = self.buf[i][0..self.lens[i]];
        return self.slices[0..self.n];
    }
};

pub const Config = struct {
    aspm: bool = true,
    wifi: bool = true,
    memory: bool = true,
    disk: bool = true,
    nmi_watchdog: bool = true,
    build: bool = true,
    game: bool = true,
    games: Names = .{},
    builds: Names = .{},
    jobs: u16 = 0,
    bad_lines: u32 = 0,
};

pub fn parse(text: []const u8) Config {
    var c = Config{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            c.bad_lines += 1;
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (!apply(&c, key, value)) c.bad_lines += 1;
    }
    return c;
}

fn apply(c: *Config, key: []const u8, value: []const u8) bool {
    const switches = .{ "aspm", "wifi", "memory", "disk", "nmi_watchdog", "build", "game" };
    inline for (switches) |name| {
        if (std.mem.eql(u8, key, name)) {
            @field(c, name) = yesNo(value) orelse return false;
            return true;
        }
    }
    if (std.mem.eql(u8, key, "game.add")) return c.games.add(value);
    if (std.mem.eql(u8, key, "build.add")) return c.builds.add(value);
    if (std.mem.eql(u8, key, "jobs")) {
        const n = std.fmt.parseInt(u16, value, 10) catch return false;
        if (n < 1 or n > 1024) return false;
        c.jobs = n;
        return true;
    }
    return false;
}

fn yesNo(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "yes")) return true;
    if (std.mem.eql(u8, value, "no")) return false;
    return null;
}

test "the config file" {
    var c = parse(
        \\# a comment
        \\aspm = no
        \\wifi = no   # trailing
        \\game.add = mygame
        \\build.add = tsc
        \\jobs = 8
        \\jobs = 0
        \\nonsense
        \\memory = maybe
    );
    try std.testing.expect(!c.aspm and !c.wifi and c.memory and c.disk and c.build and c.game);
    try std.testing.expectEqualStrings("mygame", c.games.all()[0]);
    try std.testing.expectEqualStrings("tsc", c.builds.all()[0]);
    try std.testing.expectEqual(@as(u16, 8), c.jobs);
    try std.testing.expectEqual(@as(u32, 3), c.bad_lines);
}
