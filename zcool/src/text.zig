// SPDX-License-Identifier: GPL-3.0-or-later

//! A line built from pieces. std.fmt makes code for every shape of line, and for the menu's few
//! dozen of them that came to more than the rest of zcool's new code together; `zcool dump` and
//! calibration print as many.

const std = @import("std");
const sys = @import("sys.zig");

/// Not inlined: a line is a chain of these, and inlined into every chain they cost 17 KiB.
pub const Text = struct {
    buf: []u8,
    len: usize = 0,

    pub noinline fn add(self: *Text, s: []const u8) *Text {
        const n = @min(s.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], s[0..n]);
        self.len += n;
        return self;
    }

    pub noinline fn num(self: *Text, v: i64) *Text {
        var digits: [24]u8 = undefined;
        var i: usize = digits.len;
        var x: u64 = @abs(v);
        while (true) {
            i -= 1;
            digits[i] = @intCast('0' + x % 10);
            x /= 10;
            if (x == 0) break;
        }
        if (v < 0) {
            i -= 1;
            digits[i] = '-';
        }
        return self.add(digits[i..]);
    }

    /// Degrees and watts, rounded to whole ones.
    pub fn whole(self: *Text, v: f32) *Text {
        return self.num(@intFromFloat(@round(std.math.clamp(v, -1e6, 1e6))));
    }

    /// With one decimal: 31.5.
    pub noinline fn tenth(self: *Text, v: f32) *Text {
        const tenths: i64 = @intFromFloat(@round(std.math.clamp(v, -1e6, 1e6) * 10));
        if (tenths < 0 and tenths > -10) _ = self.add("-");
        _ = self.num(@divTrunc(tenths, 10)).add(".");
        return self.num(@intCast(@abs(@rem(tenths, 10))));
    }

    /// With two decimals: 0.89.
    pub noinline fn hundredth(self: *Text, v: f32) *Text {
        const hundredths: i64 = @intFromFloat(@round(std.math.clamp(v, -1e6, 1e6) * 100));
        if (hundredths < 0 and hundredths > -100) _ = self.add("-");
        _ = self.num(@divTrunc(hundredths, 100)).add(".");
        const rest: u64 = @abs(@rem(hundredths, 100));
        if (rest < 10) _ = self.add("0");
        return self.num(@intCast(rest));
    }

    /// Two hex digits: 0x9e is "9e".
    pub noinline fn hex(self: *Text, b: u8) *Text {
        const digits = "0123456789abcdef";
        return self.add(&.{ digits[b >> 4], digits[b & 0xf] });
    }

    pub fn str(self: *const Text) []const u8 {
        return self.buf[0..self.len];
    }

    /// Prints what it holds and a newline, and starts over.
    pub noinline fn line(self: *Text) void {
        _ = self.add("\n");
        sys.print(self.str());
        self.len = 0;
    }
};

test "numbers as pieces of a line" {
    var buf: [64]u8 = undefined;
    var t = Text{ .buf = &buf };
    _ = t.num(-42).add(" ").whole(31.6).add(" ").tenth(31.54).add(" ").tenth(-0.4).add(" ").hex(0x9e);
    _ = t.add(" ").hundredth(0.89).add(" ").hundredth(1.4).add(" ").hundredth(-0.05);
    try std.testing.expectEqualStrings("-42 32 31.5 -0.4 9e 0.89 1.40 -0.05", t.str());
}
