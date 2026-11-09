// SPDX-License-Identifier: GPL-3.0-or-later

//! What each setting should be, from the power source and what the machine is doing. No system
//! calls, so all of it is tested on its own.
//!
//! zcool has the CPU and the GPUs: their clocks, power, turbo, energy preference and fans. ztune
//! has the rest: how devices sleep, how memory is reclaimed, when the disk is written, and
//! how a build shares the CPU with the desktop.

const std = @import("std");

pub const Source = enum { mains, battery };

/// What the machine is doing, from the processes that run: a game outranks a build.
pub const Mode = enum { desktop, build, game };

pub const Aspm = enum { default, performance, powersave, powersupersave };
pub const Thp = enum { always, madvise, never };

pub const mib: u64 = 1024 * 1024;

/// What follows the power source and the mode.
pub const Settings = struct {
    /// how deep PCIe links sleep: powersupersave saves the most, performance never sleeps them
    aspm: Aspm,
    /// a Wi-Fi card that dozes between beacons: watts on battery, latency for a game
    wifi_power_save: bool,
    /// how often dirty pages are written, and how old they may get
    writeback_cs: u32,
    expire_cs: u32,
    /// how much may wait to be written before a writer is held back: a little keeps the desktop
    /// from stalling on a flush, a build writes many objects and gets more
    dirty_bytes: u64,
    dirty_background_bytes: u64,
    /// huge pages for every process, or only those that ask: a compiler gains from them
    thp: Thp,
    /// a build's processes run as SCHED_BATCH: never preempting the desktop on wakeup
    batch: bool,
};

pub fn settings(source: Source, mode: Mode) Settings {
    var s = Settings{
        .aspm = .default,
        .wifi_power_save = false,
        .writeback_cs = 1500,
        .expire_cs = 3000,
        .dirty_bytes = 256 * mib,
        .dirty_background_bytes = 64 * mib,
        .thp = .madvise,
        .batch = false,
    };
    if (source == .battery) {
        // a disk that wakes once a minute, links that sleep deep, a card that dozes
        s.aspm = .powersupersave;
        s.wifi_power_save = true;
        s.writeback_cs = 6000;
        s.expire_cs = 6000;
    }
    switch (mode) {
        .desktop => {},
        .build => {
            s.dirty_bytes = 1024 * mib;
            s.dirty_background_bytes = 256 * mib;
            s.thp = .always;
            s.batch = true;
        },
        .game => {
            // a game wants its frames and its packets now, on battery too
            s.aspm = .performance;
            s.wifi_power_save = false;
            s.writeback_cs = 1500;
            s.expire_cs = 3000;
        },
    }
    return s;
}

/// Set once and kept, whatever the source and the mode.
pub const nmi_watchdog: u8 = 0;
/// MGLRU keeps the pages used in the last second: a machine out of memory ends a process
/// instead of grinding its disk for minutes.
pub const min_ttl_ms: u32 = 1000;
/// kswapd starts reclaiming at 1.25% of memory free instead of 0.1%, so an allocation rarely
/// has to wait for it.
pub const watermark_scale_factor: u32 = 125;
/// huge pages are never compacted for in the path of an allocation
pub const thp_defrag = "defer+madvise";

// ---------------------------------------------------------------- what runs

pub const Kind = enum { other, game, build };

const games = [_][]const u8{ "gamescope", "gamescope-wl", "reaper", "wine64-preloader", "wine-preloader", "wineserver" };
const builds = [_][]const u8{
    "make", "gmake",  "ninja",   "samu",   "cc1",  "cc1plus", "cc1obj",  "lto1",  "rustc", "cargo", "clang", "clang++",
    "ld",   "ld.lld", "ld.gold", "ld.bfd", "mold", "zig",     "compile", "javac", "ghc",
};

/// What a process is from its name, as /proc/PID/stat shows it (15 characters at most).
/// Steam's `reaper` runs for exactly as long as a game it started; a Wine program's name ends
/// in .exe.
pub fn classify(comm: []const u8, extra_games: []const []const u8, extra_builds: []const []const u8) Kind {
    for (games) |g| if (std.mem.eql(u8, comm, g)) return .game;
    for (extra_games) |g| if (std.mem.eql(u8, comm, g)) return .game;
    if (comm.len > 4 and std.ascii.endsWithIgnoreCase(comm, ".exe")) return .game;
    // the kernel keeps 15 characters of a name: Cyberpunk2077.exe is Cyberpunk2077.e
    if (comm.len == 15 and (std.ascii.endsWithIgnoreCase(comm, ".e") or std.ascii.endsWithIgnoreCase(comm, ".ex"))) return .game;
    for (builds) |b| if (std.mem.eql(u8, comm, b)) return .build;
    for (extra_builds) |b| if (std.mem.eql(u8, comm, b)) return .build;
    return .other;
}

/// A build is on while its processes keep half a core busy, and stays this long after: a
/// build has pauses between its steps.
pub const build_linger: f32 = 15;
pub const build_busy: f32 = 0.5;

pub const Detector = struct {
    mode: Mode = .desktop,
    quiet_for: f32 = 0,

    /// `build_cores`: how many cores the build's processes kept busy since the last look.
    pub fn update(self: *Detector, game: bool, build_cores: f32, dt: f32) Mode {
        if (game) {
            self.mode = .game;
        } else if (build_cores >= build_busy) {
            self.mode = .build;
            self.quiet_for = 0;
        } else if (self.mode == .build) {
            self.quiet_for += dt;
            if (self.quiet_for >= build_linger) self.mode = .desktop;
        } else {
            self.mode = .desktop;
        }
        return self.mode;
    }
};

// ---------------------------------------------------------------- files

/// "always [madvise] never": the one in brackets. A file of one word: that word.
pub fn chosen(text: []const u8) []const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    const open = std.mem.indexOfScalar(u8, t, '[') orelse return t;
    const close = std.mem.indexOfScalarPos(u8, t, open, ']') orelse return t;
    return t[open + 1 .. close];
}

pub fn offers(text: []const u8, name: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n[]");
    while (words.next()) |w| if (std.mem.eql(u8, w, name)) return true;
    return false;
}

/// The I/O scheduler for a disk: none for NVMe, which queues in hardware; BFQ for one that
/// spins, so the desktop still reads while something writes; mq-deadline for SATA SSDs.
/// Null when the one it should have is not offered.
pub fn scheduler(name: []const u8, rotational: bool, available: []const u8) ?[]const u8 {
    const want: []const u8 = if (std.mem.startsWith(u8, name, "nvme"))
        "none"
    else if (rotational and offers(available, "bfq"))
        "bfq"
    else
        "mq-deadline";
    return if (offers(available, want)) want else null;
}

/// Disks ztune leaves alone: memory, loops, device mapper and optical drives have nothing to
/// gain or follow the disk under them.
pub fn schedulable(name: []const u8) bool {
    for ([_][]const u8{ "loop", "ram", "zram", "dm-", "sr", "md", "nbd" }) |p| {
        if (std.mem.startsWith(u8, name, p)) return false;
    }
    return true;
}

test "the power source and the mode set what follows them" {
    const desk = settings(.mains, .desktop);
    try std.testing.expectEqual(Aspm.default, desk.aspm);
    try std.testing.expect(!desk.wifi_power_save and !desk.batch);
    const battery = settings(.battery, .desktop);
    try std.testing.expectEqual(Aspm.powersupersave, battery.aspm);
    try std.testing.expect(battery.wifi_power_save and battery.writeback_cs == 6000);
    const build = settings(.battery, .build);
    try std.testing.expect(build.batch and build.thp == .always and build.dirty_bytes == 1024 * mib);
    try std.testing.expectEqual(Aspm.powersupersave, build.aspm);
    const game = settings(.battery, .game);
    try std.testing.expectEqual(Aspm.performance, game.aspm);
    try std.testing.expect(!game.wifi_power_save and game.writeback_cs == 1500);
}

test "a process is a game, a build or neither, by its name" {
    const none = [_][]const u8{};
    try std.testing.expectEqual(Kind.game, classify("gamescope", &none, &none));
    try std.testing.expectEqual(Kind.game, classify("Cyberpunk2077.e", &none, &none));
    try std.testing.expectEqual(Kind.game, classify("Witcher3.exe", &none, &none));
    try std.testing.expectEqual(Kind.build, classify("cc1plus", &none, &none));
    try std.testing.expectEqual(Kind.other, classify("firefox", &none, &none));
    try std.testing.expectEqual(Kind.game, classify("mygame", &.{"mygame"}, &none));
    try std.testing.expectEqual(Kind.build, classify("tsc", &none, &.{"tsc"}));
}

test "a build lingers through its pauses, a game outranks it" {
    var d = Detector{};
    try std.testing.expectEqual(Mode.build, d.update(false, 3, 3));
    try std.testing.expectEqual(Mode.build, d.update(false, 0, 9));
    try std.testing.expectEqual(Mode.game, d.update(true, 3, 3));
    try std.testing.expectEqual(Mode.build, d.update(false, 1, 3));
    try std.testing.expectEqual(Mode.build, d.update(false, 0, 9));
    try std.testing.expectEqual(Mode.desktop, d.update(false, 0, 9));
    try std.testing.expectEqual(Mode.desktop, d.update(false, 0.2, 3));
}

test "sysfs choices and I/O schedulers" {
    try std.testing.expectEqualStrings("madvise", chosen("always [madvise] never\n"));
    try std.testing.expectEqualStrings("powersupersave", chosen("powersupersave\n"));
    try std.testing.expectEqualStrings("none", scheduler("nvme0n1", false, "[none] mq-deadline kyber bfq").?);
    try std.testing.expectEqualStrings("bfq", scheduler("sda", true, "mq-deadline kyber [bfq] none").?);
    try std.testing.expectEqualStrings("mq-deadline", scheduler("sda", false, "[mq-deadline] kyber bfq none").?);
    try std.testing.expectEqualStrings("mq-deadline", scheduler("sdb", true, "[mq-deadline] none").?);
    try std.testing.expect(scheduler("sda", false, "[none]") == null);
    try std.testing.expect(!schedulable("zram0") and !schedulable("dm-0") and schedulable("nvme0n1"));
}
