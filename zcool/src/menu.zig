// SPDX-License-Identifier: GPL-3.0-or-later

//! `zcool menu`: every setting of /etc/zcool.conf on one screen, with what each does, the
//! chips' temperatures as they are now and what zcool has learned. It edits the config's
//! text line by line, so comments and order stay, and saving restarts the service.

const std = @import("std");
const sys = @import("sys.zig");
const config = @import("config.zig");

pub const max_chips = 16;
pub const max_fans = 16;

pub const ChipInfo = struct {
    name: [24]u8 = undefined,
    name_len: u8 = 0,
    temp: f32 = 0,
    /// what zcool uses with nothing in the config, and the most it allows
    default_limit: f32 = 0,
    max_limit: f32 = 0,
    asleep: bool = false,
    learned_watts: f32 = 0,
    learned_at: f32 = 0,

    pub fn id(self: *const ChipInfo) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Info = struct {
    chips: [max_chips]ChipInfo = undefined,
    nchips: usize = 0,
    fans: [max_fans][40]u8 = undefined,
    fan_lens: [max_fans]u8 = undefined,
    nfans: usize = 0,
    on_mains: ?bool = null,
    /// an MSI EC zcool knows, and what it reads
    ec: bool = false,
    ec_cpu: ?u8 = null,
    ec_gpu: ?u8 = null,
    ec_cpu_fan: ?u8 = null,
    ec_gpu_fan: ?u8 = null,
    has_epp: bool = false,
    has_turbo: bool = false,
    undervolt_note: []const u8 = "",
};

/// Fills in what is true now; called once a second.
pub const Refresh = *const fn (info: *Info) void;

// ---------------------------------------------------------------- text

/// A line built from pieces. std.fmt makes code for every shape of line, and for a menu's
/// few dozen of them that came to more than the rest of zcool's new code together.
const Text = struct {
    buf: []u8,
    len: usize = 0,

    fn add(self: *Text, s: []const u8) *Text {
        const n = @min(s.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], s[0..n]);
        self.len += n;
        return self;
    }

    fn num(self: *Text, v: i64) *Text {
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
    fn whole(self: *Text, v: f32) *Text {
        return self.num(@intFromFloat(@round(std.math.clamp(v, -1e6, 1e6))));
    }

    fn str(self: *const Text) []const u8 {
        return self.buf[0..self.len];
    }
};

fn joined(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    var t = Text{ .buf = buf };
    return t.add(a).add(b).str();
}

// ---------------------------------------------------------------- the items

const Kind = enum { header, limit, choice, number, fan };

const Item = struct {
    kind: Kind,
    label: []const u8,
    key: [48]u8 = undefined,
    key_len: u8 = 0,
    help: []const u8 = "",
    /// a choice: index 0 is what leaving it out means
    choices: []const []const u8 = &.{},
    /// a number: its range and step, and the value that means leaving it out
    min: i32 = 0,
    max: i32 = 0,
    step: i32 = 1,
    unset: i32 = 0,
    unset_label: []const u8 = "",
    unit: []const u8 = "",
    chip: u8 = 0,
    fan: u8 = 0,

    fn keyName(self: *const Item) []const u8 {
        return self.key[0..self.key_len];
    }
};

const epp_choices = [_][]const u8{ "as the firmware has it", "performance", "balance_performance", "balance_power", "power", "default" };
const turbo_choices = [_][]const u8{ "as the firmware has it", "yes", "no" };
const noise_choices = [_][]const u8{ "normal", "quiet" };
const mode_choices = [_][]const u8{ "as the firmware has it", "eco", "comfort", "sport", "turbo" };
const yes_first = [_][]const u8{ "yes", "no" };

const max_items = 80;
var items: [max_items]Item = undefined;
var nitems: usize = 0;

fn add(item: Item, key: []const u8) void {
    if (nitems == max_items) return;
    var it = item;
    const n = @min(key.len, it.key.len);
    @memcpy(it.key[0..n], key[0..n]);
    it.key_len = @intCast(n);
    items[nitems] = it;
    nitems += 1;
}

fn header(label: []const u8) void {
    add(.{ .kind = .header, .label = label }, "");
}

fn buildItems(info: *const Info) void {
    nitems = 0;
    header("Limits: the most each chip may reach");
    for (info.chips[0..info.nchips], 0..) |*c, i| {
        if (c.default_limit <= 0) continue;
        var key: [48]u8 = undefined;
        const k = joined(&key, c.id(), ".max");
        add(.{
            .kind = .limit,
            .label = "",
            .chip = @intCast(i),
            .help = "Lower is cooler and quieter, and slower under long loads. Never above the chip's critical point minus 5.",
        }, k);
    }
    for ([_]bool{ true, false }) |mains| {
        header(if (mains) "On mains" else "On battery");
        const suffix = if (mains) ".ac" else ".battery";
        var key: [48]u8 = undefined;
        add(.{
            .kind = .choice,
            .label = "CPU energy preference",
            .choices = &epp_choices,
            .help = "How readily the CPU climbs to high clocks. balance_power and power save the battery and heat for a little speed.",
        }, joined(&key, "epp", suffix));
        add(.{
            .kind = .choice,
            .label = "Turbo",
            .choices = &turbo_choices,
            .help = "Clocks above the base clock. Off on battery: much longer battery life and a cool, quiet laptop, a slower one.",
        }, joined(&key, "turbo", suffix));
        add(.{
            .kind = .choice,
            .label = "Fans",
            .choices = &noise_choices,
            .help = "quiet: up to 15% of a chip's power goes before the fans go past the firmware's curve or Cooler Boost comes on.",
        }, joined(&key, "noise", suffix));
        add(.{
            .kind = .number,
            .label = "Every limit moves by",
            .min = -config.max_shift,
            .max = 0,
            .unit = " C",
            .unset = 0,
            .help = "Lowers every chip's limit on this source: on battery, -10 keeps the laptop cooler and quieter.",
        }, joined(&key, "limits", suffix));
        if (info.ec) add(.{
            .kind = .choice,
            .label = "MSI EC power profile",
            .choices = &mode_choices,
            .help = "The EC's own profile: how much power the firmware allows and how it runs the fans. eco on battery saves the most.",
        }, joined(&key, "mode", suffix));
    }
    header("Battery");
    add(.{
        .kind = .number,
        .label = "Charge up to",
        .min = 50,
        .max = 100,
        .step = 5,
        .unset = 45,
        .unset_label = "as it is",
        .unit = "%",
        .help = "A laptop kept plugged in lives longer at 80%. Stays set when zcool stops; 100 takes the limit away.",
    }, "battery.max");
    if (info.nfans > 0) {
        header("Fans zcool may drive");
        for (0..info.nfans) |i| {
            add(.{
                .kind = .fan,
                .label = "",
                .fan = @intCast(i),
                .help = "no: zcool never touches this fan. It already never runs one slower than the firmware had it.",
            }, "fan.exclude");
        }
    }
    header("Under heavy work");
    add(.{
        .kind = .choice,
        .label = "Jobs yield to the desktop",
        .choices = &yes_first,
        .help = "When the CPU is short, the jobs that took it longest (a build, an encode) get nice 10 and the desktop, sound and games nice -5.",
    }, "guard.cpu");
    add(.{
        .kind = .choice,
        .label = "End a memory hog in time",
        .choices = &yes_first,
        .help = "With memory and swap all but gone, the process holding the most is ended before the system stalls for minutes. Never the session.",
    }, "guard.memory");
    add(.{
        .kind = .choice,
        .label = "CPU's own throttle at limit+3",
        .choices = &yes_first,
        .help = "Intel: the CPU throttles itself in microseconds 3 C above the limit, catching spikes too fast for any program.",
    }, "tcc");
    if (info.ec) add(.{
        .kind = .choice,
        .label = "zcool runs the fans",
        .choices = &yes_first,
        .help = "zcool sets the EC's fans to the speed the heat needs, through a curve of its own; no: only Cooler Boost, on or off.",
    }, "fan.curve");
    if (info.ec) add(.{
        .kind = .choice,
        .label = "Silent fan curve when cool",
        .choices = &yes_first,
        .help = "The EC's own silent curve while every chip is 25 C below its limit; its normal curve the moment one heads up.",
    }, "fan.silent");
    header("Other");
    add(.{
        .kind = .choice,
        .label = "Learn the cooler",
        .choices = &yes_first,
        .help = "Learns how much power the cooler carries at the limit, so power goes straight there the next time it is needed.",
    }, "learn");
    add(.{
        .kind = .choice,
        .label = "GPUs sleep when idle",
        .choices = &yes_first,
        .help = "A GPU that does not show the screen sleeps when idle. no keeps them all awake, should one misbehave waking up.",
    }, "gpu.sleep");
    if (info.ec) add(.{
        .kind = .choice,
        .label = "Use the MSI EC",
        .choices = &yes_first,
        .help = "Cooler Boost, the charge limit and the EC's profiles. no keeps zcool away from the EC altogether.",
    }, "ec");
    add(.{
        .kind = .number,
        .label = "Undervolt, core",
        .min = -125,
        .max = 0,
        .step = 5,
        .unset = 0,
        .unit = " mV",
        .help = "Intel only, and not with kernel lockdown. Test each step under load: too low crashes the machine. The BIOS is better.",
    }, "undervolt.core");
    add(.{
        .kind = .number,
        .label = "Undervolt, cache",
        .min = -125,
        .max = 0,
        .step = 5,
        .unset = 0,
        .unit = " mV",
        .help = "Usually the same as the core. Many CPUs since 2020 have it locked by firmware: `doas zcool undervolt probe` tells.",
    }, "undervolt.cache");
}

// ---------------------------------------------------------------- values

var text_buf: [8192]u8 = undefined;
var text: []const u8 = "";
var saved_buf: [8192]u8 = undefined;
var saved: []const u8 = "";
var scratch: [8192]u8 = undefined;

/// The value of the first line that sets `key`, as the daemon reads it.
fn get(key: []const u8, only: ?[]const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var found: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), key)) continue;
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (only) |v| {
            if (std.mem.eql(u8, value, v)) return value;
            continue;
        }
        // the daemon takes the last for a setting and the first for a limit
        if (found == null or !std.mem.endsWith(u8, key, ".max") or std.mem.eql(u8, key, "battery.max")) found = value;
    }
    return found;
}

fn put(key: []const u8, value: ?[]const u8, only: ?[]const u8) void {
    const next = config.set(text, key, value, only, &scratch) orelse {
        status("the config would grow past 8 KiB; left as it was");
        return;
    };
    @memcpy(text_buf[0..next.len], next);
    text = text_buf[0..next.len];
}

fn numberOf(item: *const Item) i32 {
    const v = get(item.keyName(), null) orelse return item.unset;
    return std.fmt.parseInt(i32, v, 10) catch item.unset;
}

fn choiceOf(item: *const Item) usize {
    const v = get(item.keyName(), null) orelse return 0;
    for (item.choices, 0..) |c, i| if (std.mem.eql(u8, c, v)) return i;
    return 0;
}

fn limitOf(item: *const Item) ?i32 {
    const v = get(item.keyName(), null) orelse return null;
    return std.fmt.parseInt(i32, v, 10) catch null;
}

fn fanName(info: *const Info, i: usize) []const u8 {
    return info.fans[i][0..info.fan_lens[i]];
}

/// Moves a value by `steps`; 0 sets it back to what leaving it out means.
fn change(item: *const Item, info: *const Info, steps: i32) void {
    var num: [16]u8 = undefined;
    switch (item.kind) {
        .header => {},
        .choice => {
            if (steps == 0) return put(item.keyName(), null, null);
            const n: i32 = @intCast(item.choices.len);
            const at: i32 = @intCast(choiceOf(item));
            const next: usize = @intCast(@mod(at + std.math.sign(steps), n));
            put(item.keyName(), if (next == 0) null else item.choices[next], null);
        },
        .number => {
            if (steps == 0) return put(item.keyName(), null, null);
            // leaving it out sits at one end of the range, or inside it
            const v = std.math.clamp(numberOf(item) + steps * item.step, @min(item.min, item.unset), @max(item.max, item.unset));
            if (v == item.unset or (item.unset < item.min and v < item.min)) return put(item.keyName(), null, null);
            var t = Text{ .buf = &num };
            put(item.keyName(), t.num(v).str(), null);
        },
        .limit => {
            if (steps == 0) return put(item.keyName(), null, null);
            const c = &info.chips[item.chip];
            const now = limitOf(item) orelse @as(i32, @intFromFloat(c.default_limit));
            const v = std.math.clamp(now + steps, 30, @as(i32, @intFromFloat(c.max_limit)));
            var t = Text{ .buf = &num };
            put(item.keyName(), t.num(v).str(), null);
        },
        .fan => {
            const name = fanName(info, item.fan);
            const excluded = get("fan.exclude", name) != null;
            if (steps == 0 and !excluded) return;
            put("fan.exclude", if (excluded) null else name, name);
        },
    }
}

// ---------------------------------------------------------------- presets

const Preset = struct {
    name: []const u8,
    epp: [2]?[]const u8,
    turbo: [2]?[]const u8,
    noise: [2]?[]const u8,
    limits: [2]?[]const u8,
    mode: [2]?[]const u8,
};

/// [mains, battery] for each
const presets = [_]Preset{
    .{
        .name = "quiet",
        .epp = .{ "balance_power", "power" },
        .turbo = .{ null, "no" },
        .noise = .{ "quiet", "quiet" },
        .limits = .{ "-5", "-10" },
        .mode = .{ "comfort", "eco" },
    },
    .{
        .name = "balanced",
        .epp = .{ "balance_performance", "balance_power" },
        .turbo = .{ null, "no" },
        .noise = .{ null, "quiet" },
        .limits = .{ null, "-5" },
        .mode = .{ "comfort", "eco" },
    },
    .{
        .name = "fast",
        .epp = .{ "performance", "balance_performance" },
        .turbo = .{ "yes", "yes" },
        .noise = .{ null, null },
        .limits = .{ null, null },
        .mode = .{ "sport", "comfort" },
    },
};

fn applyPreset(p: *const Preset, info: *const Info) void {
    for ([_][]const u8{ ".ac", ".battery" }, 0..) |suffix, i| {
        var key: [32]u8 = undefined;
        put(joined(&key, "epp", suffix), p.epp[i], null);
        put(joined(&key, "turbo", suffix), p.turbo[i], null);
        put(joined(&key, "noise", suffix), p.noise[i], null);
        put(joined(&key, "limits", suffix), p.limits[i], null);
        if (info.ec) put(joined(&key, "mode", suffix), p.mode[i], null);
    }
    var line: [64]u8 = undefined;
    var t = Text{ .buf = &line };
    status(t.add("preset ").add(p.name).add(": s saves it").str());
}

// ---------------------------------------------------------------- the screen

var status_buf: [160]u8 = undefined;
var status_len: usize = 0;

fn status(s: []const u8) void {
    const n = @min(s.len, status_buf.len);
    @memcpy(status_buf[0..n], s[0..n]);
    status_len = n;
}

const Screen = struct {
    buf: [32768]u8 = undefined,
    len: usize = 0,
    // all zero: the screen then takes no room in the binary; render sets the width
    cols: usize = 0,
    /// visible characters on the current line
    col: usize = 0,

    fn raw(self: *Screen, s: []const u8) void {
        const n = @min(s.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], s[0..n]);
        self.len += n;
    }

    /// Text that counts toward the width, all of it ASCII: cut at the edge of the terminal.
    fn text(self: *Screen, s: []const u8) void {
        const n = @min(s.len, self.cols -| self.col);
        self.raw(s[0..n]);
        self.col += n;
    }

    fn num(self: *Screen, v: i64) void {
        var tmp: [24]u8 = undefined;
        var t = Text{ .buf = &tmp };
        self.text(t.num(v).str());
    }

    fn whole(self: *Screen, v: f32) void {
        var tmp: [24]u8 = undefined;
        var t = Text{ .buf = &tmp };
        self.text(t.whole(v).str());
    }

    fn pad(self: *Screen, to: usize) void {
        while (self.col < to and self.col < self.cols) self.text(" ");
    }

    fn endLine(self: *Screen) void {
        // the terminal's own output processing adds the carriage return
        self.raw("\x1b[K\n");
        self.col = 0;
    }
};

var screen: Screen = .{};
var selected: usize = 0;
var top: usize = 0;

fn render(info: *const Info, rows: usize, cols: usize) void {
    const s = &screen;
    s.len = 0;
    s.cols = @max(cols, 20);
    s.col = 0;
    s.raw("\x1b[H");
    // what is true now
    s.raw("\x1b[1m");
    s.text(" zcool");
    s.raw("\x1b[0m");
    if (info.on_mains) |m| {
        s.text("   on ");
        s.text(if (m) "mains" else "battery");
    }
    s.text(if (std.mem.eql(u8, text, saved)) "   saved" else "   not saved");
    s.endLine();
    s.text(" ");
    for (info.chips[0..info.nchips]) |*c| {
        // board sensors zcool only watches would crowd the line
        if (c.default_limit <= 0 and !c.asleep) continue;
        if (c.asleep) {
            s.text(c.id());
            s.text(" asleep  ");
        } else if (c.temp > 0) {
            s.text(c.id());
            s.text(" ");
            s.whole(c.temp);
            s.text("C  ");
        }
    }
    if (info.ec_cpu_fan) |f| {
        s.text("fans ");
        s.num(f);
        s.text("% ");
        s.num(info.ec_gpu_fan orelse 0);
        s.text("%");
    }
    s.endLine();
    var learned = false;
    for (info.chips[0..info.nchips]) |*c| {
        if (c.learned_watts <= 0) continue;
        if (!learned) s.text(" learned:");
        learned = true;
        s.text(" ");
        s.text(c.id());
        s.text(" ");
        s.whole(c.learned_watts);
        s.text(" W at ");
        s.whole(c.learned_at);
        s.text("C");
    }
    if (!learned) s.raw("\x1b[2m");
    if (!learned) s.text(" learned: nothing yet; it learns while it holds a chip at its limit");
    s.raw("\x1b[0m");
    s.endLine();
    s.endLine();

    // the items, scrolled so the selected one shows
    const fixed_rows: usize = 4 + 4;
    const list_rows = if (rows > fixed_rows + 3) rows - fixed_rows else 3;
    if (selected < top) top = selected;
    // the section's title too, when the first item of a section is chosen
    if (selected > 0 and items[selected - 1].kind == .header and selected - 1 < top) top = selected - 1;
    if (selected >= top + list_rows) top = selected + 1 - list_rows;
    var row: usize = 0;
    var i = top;
    while (i < nitems and row < list_rows) : ({
        i += 1;
        row += 1;
    }) {
        renderItem(&items[i], info, i == selected);
    }
    while (row < list_rows) : (row += 1) s.endLine();

    // what the selected one does, and the keys
    s.raw("\x1b[2m");
    s.text(" ");
    var n: usize = 0;
    while (n < s.cols - 1) : (n += 1) s.text("-");
    s.raw("\x1b[0m");
    s.endLine();
    // two lines at most, broken between words
    var help = items[selected].help;
    for (0..2) |_| {
        const width = s.cols -| 2;
        var cut = @min(help.len, width);
        if (cut < help.len) cut = std.mem.lastIndexOfScalar(u8, help[0..cut], ' ') orelse cut;
        s.text(" ");
        s.text(help[0..cut]);
        s.endLine();
        help = std.mem.trimStart(u8, help[cut..], " ");
    }
    s.raw("\x1b[7m");
    if (status_len > 0) {
        s.text(" ");
        s.text(status_buf[0..status_len]);
    } else {
        s.text(" arrows move and change  d default  1 quiet  2 balanced  3 fast  s save  q quit");
    }
    s.pad(s.cols);
    s.raw("\x1b[0m\x1b[J");
    _ = sys.write(1, s.buf[0..s.len]);
}

fn renderItem(item: *const Item, info: *const Info, chosen: bool) void {
    const s = &screen;
    if (item.kind == .header) {
        s.raw("\x1b[1m");
        s.text(" ");
        s.text(item.label);
        s.raw("\x1b[0m");
        s.endLine();
        return;
    }
    if (chosen) s.raw("\x1b[7m");
    s.text(if (chosen) " > " else "   ");
    s.text(switch (item.kind) {
        .limit => info.chips[item.chip].id(),
        .fan => fanName(info, item.fan),
        else => item.label,
    });
    s.pad(30);
    var value_buf: [96]u8 = undefined;
    var unset = false;
    const value: []const u8 = switch (item.kind) {
        .header => "",
        .choice => blk: {
            const at = choiceOf(item);
            unset = at == 0;
            break :blk item.choices[at];
        },
        .number => blk: {
            const v = numberOf(item);
            unset = v == item.unset;
            if (unset and item.unset_label.len > 0) break :blk item.unset_label;
            var t = Text{ .buf = &value_buf };
            break :blk t.num(v).add(item.unit).str();
        },
        .limit => blk: {
            const c = &info.chips[item.chip];
            var t = Text{ .buf = &value_buf };
            const v = limitOf(item) orelse {
                unset = true;
                break :blk t.whole(c.default_limit).add(" C, the default").str();
            };
            _ = t.num(v).add(" C");
            if (@as(f32, @floatFromInt(v)) > c.max_limit) _ = t.add(", used as ").whole(c.max_limit).add(": the most it allows");
            break :blk t.str();
        },
        .fan => blk: {
            const excluded = get("fan.exclude", fanName(info, item.fan)) != null;
            unset = !excluded;
            break :blk if (excluded) "no, left alone" else "yes";
        },
    };
    // what leaving it out means is shown dim: nothing in the config sets it
    if (unset and !chosen) s.raw("\x1b[2m");
    s.text(value);
    if (unset and !chosen) s.raw("\x1b[22m");
    const key = item.keyName();
    if (!info.has_epp and std.mem.startsWith(u8, key, "epp.")) s.text("   (this CPU has none)");
    if (!info.has_turbo and std.mem.startsWith(u8, key, "turbo.")) s.text("   (this CPU has no switch)");
    if (std.mem.startsWith(u8, key, "undervolt.") and info.undervolt_note.len > 0) {
        s.text("   (");
        s.text(info.undervolt_note);
        s.text(")");
    }
    if (chosen) s.pad(s.cols);
    s.raw("\x1b[0m");
    s.endLine();
}

// ---------------------------------------------------------------- the terminal

const Termios = extern struct { iflag: u32, oflag: u32, cflag: u32, lflag: u32, line: u8, cc: [19]u8 };
const TCGETS = 0x5401;
const TCSETS = 0x5402;
const TIOCGWINSZ = 0x5413;
const Winsize = extern struct { rows: u16, cols: u16, xpixel: u16, ypixel: u16 };

var saved_termios: Termios = undefined;
var terminal_raw = false;

fn enterRaw() bool {
    if (sys.raw(.ioctl, 0, TCGETS, @intFromPtr(&saved_termios), 0) == null) return false;
    var t = saved_termios;
    t.lflag &= ~@as(u32, 0o2 | 0o10 | 0o1 | 0o100000); // ICANON ECHO ISIG IEXTEN
    t.iflag &= ~@as(u32, 0o2000 | 0o400 | 0o2 | 0o40); // IXON ICRNL BRKINT ISTRIP
    t.cc[6] = 1; // VMIN
    t.cc[5] = 0; // VTIME
    if (sys.raw(.ioctl, 0, TCSETS, @intFromPtr(&t), 0) == null) return false;
    terminal_raw = true;
    // the alternate screen, without a cursor
    _ = sys.write(1, "\x1b[?1049h\x1b[?25l\x1b[H\x1b[2J");
    return true;
}

fn leaveRaw() void {
    if (!terminal_raw) return;
    terminal_raw = false;
    _ = sys.raw(.ioctl, 0, TCSETS, @intFromPtr(&saved_termios), 0);
    _ = sys.write(1, "\x1b[0m\x1b[?25h\x1b[?1049l");
}

fn size() Winsize {
    var w = Winsize{ .rows = 0, .cols = 0, .xpixel = 0, .ypixel = 0 };
    _ = sys.raw(.ioctl, 1, TIOCGWINSZ, @intFromPtr(&w), 0);
    if (w.rows == 0) w.rows = 24;
    if (w.cols == 0) w.cols = 80;
    return w;
}

fn onStop(_: std.os.linux.SIG) callconv(.c) void {
    leaveRaw();
    sys.exit(130);
}

fn onResize(_: std.os.linux.SIG) callconv(.c) void {}

fn installSignals() void {
    const linux = std.os.linux;
    var stop = linux.Sigaction{ .handler = .{ .handler = onStop }, .mask = linux.sigemptyset(), .flags = 0 };
    for ([_]linux.SIG{ .TERM, .HUP, .INT }) |signal| _ = linux.sigaction(signal, &stop, null);
    // a handler of its own, so that a resize interrupts the wait and redraws at once
    var resize = linux.Sigaction{ .handler = .{ .handler = onResize }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(.WINCH, &resize, null);
}

const Key = enum { none, up, down, left, right, page_up, page_down, home, end, enter, quit, save, default, preset1, preset2, preset3 };

/// The length of the first key in what the terminal sent: a burst can hold several.
fn keyLength(bytes: []const u8) usize {
    if (bytes.len < 2 or bytes[0] != 0x1b or (bytes[1] != '[' and bytes[1] != 'O')) return 1;
    var i: usize = 2;
    while (i < bytes.len) : (i += 1) {
        const b = bytes[i];
        if ((b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or b == '~') return i + 1;
    }
    return bytes.len;
}

fn decode(bytes: []const u8) Key {
    if (bytes.len == 0) return .none;
    if (bytes[0] == 0x1b) {
        if (bytes.len == 1) return .quit;
        const seq = bytes[1..];
        if (std.mem.eql(u8, seq, "[A") or std.mem.eql(u8, seq, "OA")) return .up;
        if (std.mem.eql(u8, seq, "[B") or std.mem.eql(u8, seq, "OB")) return .down;
        if (std.mem.eql(u8, seq, "[C") or std.mem.eql(u8, seq, "OC")) return .right;
        if (std.mem.eql(u8, seq, "[D") or std.mem.eql(u8, seq, "OD")) return .left;
        if (std.mem.eql(u8, seq, "[5~")) return .page_up;
        if (std.mem.eql(u8, seq, "[6~")) return .page_down;
        if (std.mem.eql(u8, seq, "[H") or std.mem.eql(u8, seq, "[1~") or std.mem.eql(u8, seq, "OH")) return .home;
        if (std.mem.eql(u8, seq, "[F") or std.mem.eql(u8, seq, "[4~") or std.mem.eql(u8, seq, "OF")) return .end;
        return .none;
    }
    return switch (bytes[0]) {
        'k' => .up,
        'j' => .down,
        'h', '-' => .left,
        'l', '+', ' ' => .right,
        '\r', '\n' => .enter,
        'q', 'Q', 3 => .quit,
        's', 'S' => .save,
        'd', 'D' => .default,
        '1' => .preset1,
        '2' => .preset2,
        '3' => .preset3,
        else => .none,
    };
}

fn move(by: i32) void {
    var at: i32 = @intCast(selected);
    const last: i32 = @intCast(nitems - 1);
    const dir: i32 = if (by < 0) -1 else 1;
    var left = @abs(by);
    while (left > 0) : (left -= 1) {
        var next = at + dir;
        while (next >= 0 and next <= last and items[@intCast(next)].kind == .header) next += dir;
        if (next < 0 or next > last) break;
        at = next;
    }
    selected = @intCast(at);
}

// ---------------------------------------------------------------- saving

/// Writes the config with the mode it should have: readable for `zcool list` without root.
fn writeConfig(path: [:0]const u8) bool {
    var tmp_buf: [300]u8 = undefined;
    const tmp = sys.join(&tmp_buf, &.{ path, ".menu" });
    const linux = std.os.linux;
    const o: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const at_fdcwd: usize = @bitCast(@as(isize, -100));
    const fd = sys.raw(.openat, at_fdcwd, @intFromPtr(tmp.ptr), @as(u32, @bitCast(o)), 0o644) orelse return false;
    const ok = sys.write(@intCast(fd), text);
    sys.close(@intCast(fd));
    if (!ok) {
        sys.unlink(tmp);
        return false;
    }
    if (sys.raw(.renameat, at_fdcwd, @intFromPtr(tmp.ptr), at_fdcwd, @intFromPtr(path.ptr)) == null) {
        sys.unlink(tmp);
        return false;
    }
    return true;
}

/// The runit service, when it runs: a `t` to its supervisor restarts it with the new config.
fn restartService() ?bool {
    for ([_][]const u8{ "/etc/sv/zcool/supervise", "/var/service/zcool/supervise" }) |dir| {
        var path_buf: [256]u8 = undefined;
        var stat: [16]u8 = undefined;
        const state = sys.readFile(sys.join(&path_buf, &.{ sys.root, dir, "/stat" }), &stat) orelse continue;
        if (!std.mem.startsWith(u8, state, "run")) return null;
        const linux = std.os.linux;
        const o: linux.O = .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true };
        const at_fdcwd: usize = @bitCast(@as(isize, -100));
        const control = sys.join(&path_buf, &.{ sys.root, dir, "/control" });
        const fd = sys.raw(.openat, at_fdcwd, @intFromPtr(control.ptr), @as(u32, @bitCast(o)), 0) orelse return false;
        defer sys.close(@intCast(fd));
        return sys.write(@intCast(fd), "t");
    }
    return null;
}

fn save(path: [:0]const u8) void {
    if (!writeConfig(path)) {
        var line: [160]u8 = undefined;
        var t = Text{ .buf = &line };
        status(t.add("cannot write ").add(path).add(": run it as root, doas zcool menu").str());
        return;
    }
    @memcpy(saved_buf[0..text.len], text);
    saved = saved_buf[0..text.len];
    var line: [160]u8 = undefined;
    var t = Text{ .buf = &line };
    status(if (restartService()) |done|
        (if (done) "saved; zcool restarted with it" else "saved, but the service did not take the restart: doas sv restart zcool")
    else
        t.add("saved ").add(path).add("; zcool is not running as a service").str());
}

// ---------------------------------------------------------------- the loop

/// True when it is time to leave.
fn handle(key: Key, info: *const Info, path: [:0]const u8, quit_asked: *bool) bool {
    const item = &items[selected];
    switch (key) {
        .none => {},
        .up => move(-1),
        .down => move(1),
        .page_up => move(-10),
        .page_down => move(10),
        .home => {
            selected = 0;
            move(1);
        },
        .end => selected = nitems - 1,
        .left => change(item, info, -1),
        .right, .enter => change(item, info, 1),
        .default => change(item, info, 0),
        .preset1 => applyPreset(&presets[0], info),
        .preset2 => applyPreset(&presets[1], info),
        .preset3 => applyPreset(&presets[2], info),
        .save => save(path),
        .quit => {
            if (quit_asked.* or std.mem.eql(u8, text, saved)) return true;
            quit_asked.* = true;
            status("not saved: s saves, q again leaves without saving");
        },
    }
    return false;
}

pub fn run(path: [:0]const u8, refresh: Refresh) u8 {
    const content = sys.readFile(path, &text_buf) orelse text_buf[0..0];
    text = content;
    @memcpy(saved_buf[0..content.len], content);
    saved = saved_buf[0..content.len];

    var info = Info{};
    refresh(&info);
    buildItems(&info);
    move(1);
    if (!enterRaw()) {
        sys.eprint("zcool menu needs a terminal\n");
        return 1;
    }
    installSignals();
    var quit_asked = false;
    var failed_reads: u32 = 0;
    var last_refresh = sys.nowMs();
    while (true) {
        const w = size();
        render(&info, w.rows, w.cols);
        if (sys.waitReadable(0, 1000)) {
            var bytes: [64]u8 = undefined;
            // a signal, such as a resize, interrupts a read: only a terminal gone for good ends it
            const n = sys.read(0, &bytes) orelse {
                failed_reads += 1;
                if (failed_reads > 20) break;
                continue;
            };
            failed_reads = 0;
            if (n == 0) break;
            var at: usize = 0;
            var leave = false;
            while (at < n and !leave) {
                const len = keyLength(bytes[at..n]);
                const key = decode(bytes[at .. at + len]);
                at += len;
                if (key != .quit) quit_asked = false;
                if (key != .none) status_len = 0;
                leave = handle(key, &info, path, &quit_asked);
            }
            if (leave) break;
        }
        const now = sys.nowMs();
        if (now - last_refresh >= 1000) {
            last_refresh = now;
            refresh(&info);
        }
    }
    leaveRaw();
    return 0;
}

test "text from pieces" {
    var buf: [32]u8 = undefined;
    var t = Text{ .buf = &buf };
    try std.testing.expectEqualStrings("cpu0 -125 mV 90C", t.add("cpu0 ").num(-125).add(" mV ").whole(89.6).add("C").str());
    var small: [4]u8 = undefined;
    var u = Text{ .buf = &small };
    try std.testing.expectEqualStrings("1234", u.num(123456).str());
}

test "keys from a terminal" {
    try std.testing.expectEqual(@as(usize, 3), keyLength("\x1b[Bj"));
    try std.testing.expectEqual(@as(usize, 4), keyLength("\x1b[6~q"));
    try std.testing.expectEqual(@as(usize, 1), keyLength("jj"));
    try std.testing.expectEqual(@as(usize, 1), keyLength("\x1b"));
    try std.testing.expectEqual(Key.up, decode("\x1b[A"));
    try std.testing.expectEqual(Key.left, decode("\x1bOD"));
    try std.testing.expectEqual(Key.page_down, decode("\x1b[6~"));
    try std.testing.expectEqual(Key.quit, decode("\x1b"));
    try std.testing.expectEqual(Key.quit, decode("q"));
    try std.testing.expectEqual(Key.save, decode("s"));
    try std.testing.expectEqual(Key.none, decode("\x1b[Z"));
}

test "values move within their range and back to leaving them out" {
    var info = Info{};
    info.nchips = 1;
    info.chips[0] = .{ .default_limit = 90, .max_limit = 95 };
    @memcpy(info.chips[0].name[0..4], "cpu0");
    info.chips[0].name_len = 4;
    info.ec = true;
    info.nfans = 1;
    @memcpy(info.fans[0][0..15], "ec/cooler_boost");
    info.fan_lens[0] = 15;
    buildItems(&info);
    text = "";
    const find = struct {
        fn by(key: []const u8) *const Item {
            for (items[0..nitems]) |*it| if (std.mem.eql(u8, it.keyName(), key)) return it;
            unreachable;
        }
    }.by;
    // a limit starts at the default and stops at the most allowed
    change(find("cpu0.max"), &info, 1);
    try std.testing.expectEqualStrings("91", get("cpu0.max", null).?);
    var i: usize = 0;
    while (i < 10) : (i += 1) change(find("cpu0.max"), &info, 1);
    try std.testing.expectEqualStrings("95", get("cpu0.max", null).?);
    change(find("cpu0.max"), &info, 0);
    try std.testing.expect(get("cpu0.max", null) == null);
    // a choice goes round, its first place leaves it out
    change(find("turbo.battery"), &info, 1);
    try std.testing.expectEqualStrings("yes", get("turbo.battery", null).?);
    change(find("turbo.battery"), &info, 1);
    try std.testing.expectEqualStrings("no", get("turbo.battery", null).?);
    change(find("turbo.battery"), &info, 1);
    try std.testing.expect(get("turbo.battery", null) == null);
    // the battery: from "as it is" to 50, and back
    change(find("battery.max"), &info, 1);
    try std.testing.expectEqualStrings("50", get("battery.max", null).?);
    change(find("battery.max"), &info, -1);
    try std.testing.expect(get("battery.max", null) == null);
    change(find("battery.max"), &info, -1);
    try std.testing.expect(get("battery.max", null) == null);
    // limits move down from 0, not up
    change(find("limits.battery"), &info, -1);
    try std.testing.expectEqualStrings("-1", get("limits.battery", null).?);
    change(find("limits.battery"), &info, 1);
    change(find("limits.battery"), &info, 1);
    try std.testing.expect(get("limits.battery", null) == null);
    // a fan is left alone and taken back
    change(find("fan.exclude"), &info, 1);
    try std.testing.expect(get("fan.exclude", "ec/cooler_boost") != null);
    change(find("fan.exclude"), &info, 1);
    try std.testing.expect(get("fan.exclude", "ec/cooler_boost") == null);
    // a preset fills in both sources, and the daemon reads it
    applyPreset(&presets[1], &info);
    const c = config.parse(text);
    try std.testing.expectEqual(config.Epp.balance_power, c.battery.epp.?);
    try std.testing.expect(c.battery.turbo.? == false and c.battery.quiet and c.battery.shift == -5);
    try std.testing.expect(c.ac.turbo == null and !c.ac.quiet and c.ac.shift == 0);
    try std.testing.expectEqual(@as(u32, 0), c.bad_lines);
}
