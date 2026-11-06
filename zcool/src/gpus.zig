// SPDX-License-Identifier: GPL-3.0-or-later

//! The GPUs on the PCI bus: which one shows the boot screen, which may sleep, and what
//! keeps one awake. The kernel puts an idle GPU to sleep once its runtime power control
//! says "auto". zcool sets that for every GPU that does not show the boot screen, and
//! puts the old value back when it stops.

const std = @import("std");
const sys = @import("sys.zig");
const journal = @import("journal.zig");

pub const max_gpus = 8;

pub const Vendor = enum { amd, intel, nvidia, other };

pub const Gpu = struct {
    addr: [16]u8 = undefined,
    addr_len: u8 = 0,
    vendor: Vendor = .other,
    /// shows the boot screen: zcool never puts it to sleep
    boot: bool = false,
    driver: [16]u8 = undefined,
    driver_len: u8 = 0,
    /// its runtime power control is "auto": the kernel may put it to sleep when idle
    may_sleep: bool = false,

    pub fn address(self: *const Gpu) []const u8 {
        return self.addr[0..self.addr_len];
    }

    pub fn driverName(self: *const Gpu) []const u8 {
        return self.driver[0..self.driver_len];
    }

    /// NVIDIA's own driver puts no sensors in /sys: zcool-nvidia reads this one
    pub fn proprietary(self: *const Gpu) bool {
        return std.mem.eql(u8, self.driverName(), "nvidia");
    }
};

pub var list: [max_gpus]Gpu = undefined;
pub var count: usize = 0;

pub fn devicePath(buf: []u8, addr: []const u8, file: []const u8) [:0]const u8 {
    return sys.join(buf, &.{ sys.root, "/sys/bus/pci/devices/", addr, "/", file });
}

fn trimmed(path: [:0]const u8, buf: []u8) []const u8 {
    return std.mem.trim(u8, sys.readFile(path, buf) orelse return "", " \t\r\n");
}

/// The last part of a path: what a sysfs link points at.
fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

pub fn scan() void {
    count = 0;
    var dir_buf: [256]u8 = undefined;
    var dir = sys.Dir.open(sys.join(&dir_buf, &.{ sys.root, "/sys/bus/pci/devices" })) orelse return;
    defer dir.close();
    while (dir.next()) |entry| {
        if (count == max_gpus or entry.len > 16) continue;
        var path_buf: [256]u8 = undefined;
        var text: [32]u8 = undefined;
        // 0x0300 VGA, 0x0302 3D (a GPU with no outputs), 0x0380 other display controllers
        if (!std.mem.startsWith(u8, trimmed(devicePath(&path_buf, entry, "class"), &text), "0x03")) continue;
        var g = Gpu{};
        @memcpy(g.addr[0..entry.len], entry);
        g.addr_len = @intCast(entry.len);
        const vendor = trimmed(devicePath(&path_buf, entry, "vendor"), &text);
        g.vendor = if (std.mem.eql(u8, vendor, "0x1002")) .amd else if (std.mem.eql(u8, vendor, "0x8086")) .intel else if (std.mem.eql(u8, vendor, "0x10de")) .nvidia else .other;
        g.boot = (sys.readInt(devicePath(&path_buf, entry, "boot_vga")) orelse 0) == 1;
        var link_buf: [256]u8 = undefined;
        if (sys.readLink(devicePath(&path_buf, entry, "driver"), &link_buf)) |target| {
            const name = baseName(target);
            const n = @min(name.len, g.driver.len);
            @memcpy(g.driver[0..n], name[0..n]);
            g.driver_len = @intCast(n);
        }
        g.may_sleep = std.mem.eql(u8, trimmed(devicePath(&path_buf, entry, "power/control"), &text), "auto");
        list[count] = g;
        count += 1;
    }
    // the directory comes in no fixed order: sorted, the ids stay the same between runs.
    // A few entries at most, so the plainest sort is the smallest code.
    var i: usize = 1;
    while (i < count) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.lessThan(u8, list[j].address(), list[j - 1].address())) : (j -= 1) {
            std.mem.swap(Gpu, &list[j], &list[j - 1]);
        }
    }
}

/// The GPU a hwmon directory belongs to, through its device link.
pub fn forHwmon(base: []const u8) ?usize {
    var path_buf: [256]u8 = undefined;
    var link_buf: [256]u8 = undefined;
    const target = sys.readLink(sys.join(&path_buf, &.{ base, "/device" }), &link_buf) orelse return null;
    const name = baseName(target);
    for (list[0..count], 0..) |*g, i| {
        if (std.mem.eql(u8, g.address(), name)) return i;
    }
    return null;
}

/// Lets every GPU that does not show the boot screen sleep when it has nothing to do.
pub fn allowSleep(dry_run: bool) void {
    for (list[0..count]) |*g| {
        if (g.boot) continue;
        explainNvidia(g, g.address());
        if (g.may_sleep) continue;
        var path_buf: [256]u8 = undefined;
        const path = devicePath(&path_buf, g.address(), "power/control");
        if (dry_run) {
            sys.printf("{s}: would let it sleep when idle\n", .{g.address()});
            continue;
        }
        if (!journal.remember(path)) continue;
        if (!sys.writeFile(path, "auto")) {
            sys.printf("{s}: the kernel did not let it sleep\n", .{g.address()});
            continue;
        }
        var text: [16]u8 = undefined;
        g.may_sleep = std.mem.eql(u8, trimmed(path, &text), "auto");
        if (g.may_sleep) sys.printf("{s} ({s}): may sleep when idle\n", .{ g.address(), g.driverName() });
    }
}

pub const D3 = enum { unknown, enabled, off_by_default, off, unsupported };

/// The "Runtime D3 status" line of /proc/driver/nvidia/gpus/BUS/power.
pub fn parseD3(text: []const u8) D3 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const key = "Runtime D3 status:";
        if (!std.mem.startsWith(u8, line, key)) continue;
        const value = std.mem.trim(u8, line[key.len..], " \t\r");
        if (std.mem.startsWith(u8, value, "Enabled")) return .enabled;
        if (std.mem.startsWith(u8, value, "Disabled by default")) return .off_by_default;
        if (std.mem.startsWith(u8, value, "Disabled")) return .off;
        if (std.mem.startsWith(u8, value, "Not supported")) return .unsupported;
        return .unknown;
    }
    return .unknown;
}

pub fn nvidiaD3(g: *const Gpu) D3 {
    if (!g.proprietary()) return .unknown;
    var path_buf: [256]u8 = undefined;
    var text: [512]u8 = undefined;
    const path = sys.join(&path_buf, &.{ sys.root, "/proc/driver/nvidia/gpus/", g.address(), "/power" });
    return parseD3(sys.readFile(path, &text) orelse return .unknown);
}

/// NVIDIA's driver decides on its own whether the GPU may power down: says what stands in
/// the way, after `lead` (the address in the log, an indent in `zcool list`).
pub fn explainNvidia(g: *const Gpu, lead: []const u8) void {
    const sep = if (lead.len > 0 and lead[0] != ' ') ": " else "";
    switch (nvidiaD3(g)) {
        .off_by_default => sys.printf("{s}{s}NVIDIA keeps this GPU awake unless /etc/modprobe.d says `options nvidia NVreg_DynamicPowerManagement=0x02` (then reboot)\n", .{ lead, sep }),
        .off => sys.printf("{s}{s}NVreg_DynamicPowerManagement turns its sleep off\n", .{ lead, sep }),
        .unsupported => sys.printf("{s}{s}this GPU or the board cannot power it down\n", .{ lead, sep }),
        .enabled, .unknown => {},
    }
}

/// "active", "suspended" or "unsupported", as the kernel's runtime power management says.
pub fn state(g: *const Gpu, buf: []u8) []const u8 {
    var path_buf: [256]u8 = undefined;
    const value = trimmed(devicePath(&path_buf, g.address(), "power/runtime_status"), buf);
    return if (value.len == 0) "?" else value;
}

/// The processes that hold one of the GPU's device files open: while one does, it cannot sleep.
pub fn printHolders(g: *const Gpu) void {
    var names: [6][24]u8 = undefined;
    var lens: [6]u8 = undefined;
    var n: usize = 0;
    var path_buf: [256]u8 = undefined;
    if (sys.Dir.open(devicePath(&path_buf, g.address(), "drm"))) |dir_value| {
        var dir = dir_value;
        defer dir.close();
        while (dir.next()) |entry| {
            if (n == names.len - 1) break;
            if (!std.mem.startsWith(u8, entry, "card") and !std.mem.startsWith(u8, entry, "renderD")) continue;
            const text = std.fmt.bufPrint(&names[n], "/dev/dri/{s}", .{entry}) catch continue;
            lens[n] = @intCast(text.len);
            n += 1;
        }
    }
    if (g.proprietary()) {
        var info: [1024]u8 = undefined;
        const path = sys.join(&path_buf, &.{ sys.root, "/proc/driver/nvidia/gpus/", g.address(), "/information" });
        if (deviceMinor(sys.readFile(path, &info) orelse "")) |minor| {
            if (std.fmt.bufPrint(&names[n], "/dev/nvidia{d}", .{minor})) |text| {
                lens[n] = @intCast(text.len);
                n += 1;
            } else |_| {}
        }
    }
    if (n == 0) return;

    var found: usize = 0;
    var line_buf: [400]u8 = undefined;
    var line_len: usize = 0;
    var proc = sys.Dir.open(sys.join(&path_buf, &.{ sys.root, "/proc" })) orelse return;
    defer proc.close();
    while (proc.next()) |pid| {
        if (pid[0] < '0' or pid[0] > '9' or found == 8) continue;
        if (!holdsAny(pid, names[0..n], lens[0..n])) continue;
        var comm_buf: [32]u8 = undefined;
        var comm_path: [256]u8 = undefined;
        const comm = trimmed(sys.join(&comm_path, &.{ sys.root, "/proc/", pid, "/comm" }), &comm_buf);
        const part = std.fmt.bufPrint(line_buf[line_len..], "{s}{s} ({s})", .{ if (found == 0) "" else ", ", comm, pid }) catch break;
        line_len += part.len;
        found += 1;
    }
    if (found > 0) {
        sys.printf("  held open by {s}\n", .{line_buf[0..line_len]});
    } else if (std.os.linux.geteuid() != 0) {
        sys.print("  run as root to see what holds it open\n");
    }
}

/// True when the process has one of the named device files open.
fn holdsAny(pid: []const u8, names: []const [24]u8, lens: []const u8) bool {
    var fd_buf: [256]u8 = undefined;
    var fds = sys.Dir.open(sys.join(&fd_buf, &.{ sys.root, "/proc/", pid, "/fd" })) orelse return false;
    defer fds.close();
    while (fds.next()) |fd| {
        var link_path: [256]u8 = undefined;
        var target_buf: [64]u8 = undefined;
        const target = sys.readLink(sys.join(&link_path, &.{ sys.root, "/proc/", pid, "/fd/", fd }), &target_buf) orelse continue;
        for (names, lens) |*name, len| {
            if (std.mem.eql(u8, target, name[0..len])) return true;
        }
    }
    return false;
}

/// "Device Minor:  0" in /proc/driver/nvidia/gpus/BUS/information: the N of /dev/nvidiaN.
pub fn deviceMinor(text: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const key = "Device Minor:";
        if (!std.mem.startsWith(u8, line, key)) continue;
        return std.fmt.parseInt(u32, std.mem.trim(u8, line[key.len..], " \t\r"), 10) catch null;
    }
    return null;
}

test "reads whether NVIDIA lets the GPU power down" {
    try std.testing.expectEqual(D3.enabled, parseD3("Runtime D3 status:          Enabled (fine-grained)\nVideo Memory:               Off\n"));
    try std.testing.expectEqual(D3.off_by_default, parseD3("Runtime D3 status:          Disabled by default\n"));
    try std.testing.expectEqual(D3.off, parseD3("Runtime D3 status:          Disabled\n"));
    try std.testing.expectEqual(D3.unsupported, parseD3("Runtime D3 status:          Not supported\n"));
    try std.testing.expectEqual(D3.unknown, parseD3("Video Memory: Active\n"));
}

test "finds the device minor" {
    try std.testing.expectEqual(@as(?u32, 1), deviceMinor("Model:           NVIDIA GeForce GTX 1650\nDevice Minor:    1\n"));
    try std.testing.expectEqual(@as(?u32, null), deviceMinor("Model: x\n"));
}
