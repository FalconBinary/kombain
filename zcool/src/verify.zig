// SPDX-License-Identifier: GPL-3.0-or-later

//! Work with a known answer: what a CPU under test computes again and again while its voltage is
//! lowered, so that a wrong result shows before a machine check or a crash does. Integer
//! multiplies, fused multiply-adds on vectors of doubles, and a table walked by the results, all
//! of it deterministic: the same seed gives the same answer on every core, or the core is wrong.

const std = @import("std");

pub const seed: u64 = 0x9e3779b97f4a7c15;

const rounds = 3_000_000;
const Lanes = @Vector(4, f64);

/// Tens of milliseconds of one core's work, and its answer.
pub fn work(s: u64) u64 {
    var table: [8192]u64 = undefined;
    var x = s;
    for (&table) |*slot| {
        x = x *% 6364136223846793005 +% 1442695040888963407;
        slot.* = x;
    }
    var v: Lanes = .{ 1.0, 1.5, 2.0, 2.5 };
    const grow: Lanes = @splat(1.0000001);
    var h: u64 = s;
    var i: usize = 0;
    while (i < rounds) : (i += 1) {
        x = x *% 6364136223846793005 +% 1442695040888963407;
        const at: usize = @intCast((x >> 33) & (table.len - 1));
        table[at] ^= x;
        h = (h ^ table[at]) *% 0x100000001b3;
        const add: Lanes = @splat(@as(f64, @floatFromInt(x & 0xffff)) / 65536.0);
        v = @mulAdd(Lanes, v, grow, add);
        // bounded: a value the lanes come back to, so that no lane runs off to infinity
        if (i % 4096 == 4095) v = v * @as(Lanes, @splat(0.001));
    }
    const bits: @Vector(4, u64) = @bitCast(v);
    return h ^ bits[0] ^ (bits[1] *% 3) ^ (bits[2] *% 5) ^ (bits[3] *% 7);
}

test "the same seed gives the same answer, another seed another" {
    const a = work(seed);
    try std.testing.expectEqual(a, work(seed));
    try std.testing.expect(a != work(seed + 1));
    try std.testing.expect(a != 0);
}
