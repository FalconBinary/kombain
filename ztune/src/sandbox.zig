// SPDX-License-Identifier: GPL-3.0-or-later

//! After setup the daemon only needs /sys and its own state. Landlock enforces
//! that, so a bug in it cannot touch the rest of the system even though it runs as root.

const std = @import("std");
const sys = @import("sys.zig");

const read_file: u64 = 1 << 2;
const read_dir: u64 = 1 << 3;
const write_file: u64 = 1 << 1;
const remove_file: u64 = 1 << 5;
const make_reg: u64 = 1 << 8;
const truncate: u64 = 1 << 14;
const path_beneath: usize = 1;

const RulesetAttr = extern struct { fs: u64, net: u64 };
const PathBeneath = extern struct { allowed: u64 align(1), parent_fd: i32 align(1) };

pub const Status = enum { active, unavailable };

pub fn apply(read_paths: []const [:0]const u8, write_paths: []const [:0]const u8) Status {
    sys.prctl(38, 1); // PR_SET_NO_NEW_PRIVS
    sys.prctl(4, 0); // PR_SET_DUMPABLE
    const abi = sys.raw(.landlock_create_ruleset, 0, 0, 1, 0) orelse return .unavailable;
    var handled: u64 = (1 << 13) - 1;
    if (abi >= 2) handled |= 1 << 13;
    if (abi >= 3) handled |= truncate;
    const attr = RulesetAttr{ .fs = handled, .net = 0 };
    const rc = sys.raw(.landlock_create_ruleset, @intFromPtr(&attr), 8, 0, 0) orelse return .unavailable;
    const ruleset: i32 = @intCast(rc);
    defer sys.close(ruleset);

    const write_rights = read_file | read_dir | write_file | remove_file | make_reg | (if (abi >= 3) truncate else 0);
    for (read_paths) |path| allow(ruleset, path, read_file | read_dir);
    for (write_paths) |path| allow(ruleset, path, write_rights);
    if (sys.raw(.landlock_restrict_self, @as(usize, @intCast(ruleset)), 0, 0, 0) == null) return .unavailable;
    return .active;
}

fn allow(ruleset: i32, path: [:0]const u8, rights: u64) void {
    const fd = sys.openDir(path) orelse return;
    defer sys.close(fd);
    const rule = PathBeneath{ .allowed = rights, .parent_fd = fd };
    _ = sys.raw(.landlock_add_rule, @as(usize, @intCast(ruleset)), path_beneath, @intFromPtr(&rule), 0);
}
