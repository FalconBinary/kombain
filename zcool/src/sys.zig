// SPDX-License-Identifier: GPL-3.0-or-later

//! System calls without libc. Nothing here allocates.

const std = @import("std");
const linux = std.os.linux;

const at_fdcwd: usize = @bitCast(@as(isize, -100));

/// Prefix for every system path; the tests point it at a fake /sys.
pub var root: []const u8 = "";

fn ok(rc: usize) ?usize {
    const signed: isize = @bitCast(rc);
    return if (signed < 0 and signed > -4096) null else rc;
}

fn flags(o: linux.O) usize {
    return @as(u32, @bitCast(o));
}

/// Joins path pieces into `buf`. A path that does not fit becomes "", which fails to open.
pub fn join(buf: []u8, parts: []const []const u8) [:0]const u8 {
    var n: usize = 0;
    for (parts) |part| {
        if (n + part.len + 1 > buf.len) {
            buf[0] = 0;
            return buf[0..0 :0];
        }
        @memcpy(buf[n..][0..part.len], part);
        n += part.len;
    }
    buf[n] = 0;
    return buf[0..n :0];
}

pub fn openRead(path: [:0]const u8) ?i32 {
    const o: linux.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true, .NOCTTY = true };
    const rc = ok(linux.syscall4(.openat, at_fdcwd, @intFromPtr(path.ptr), flags(o), 0)) orelse return null;
    return @intCast(rc);
}

pub fn openDir(path: [:0]const u8) ?i32 {
    const o: linux.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true };
    const rc = ok(linux.syscall4(.openat, at_fdcwd, @intFromPtr(path.ptr), flags(o), 0)) orelse return null;
    return @intCast(rc);
}

pub fn openReadWrite(path: [:0]const u8) ?i32 {
    const o: linux.O = .{ .ACCMODE = .RDWR, .CLOEXEC = true };
    const rc = ok(linux.syscall4(.openat, at_fdcwd, @intFromPtr(path.ptr), flags(o), 0)) orelse return null;
    return @intCast(rc);
}

pub fn close(fd: i32) void {
    _ = linux.syscall1(.close, @as(usize, @intCast(fd)));
}

pub fn pread(fd: i32, buf: []u8, offset: u64) ?usize {
    return ok(linux.syscall4(.pread64, @as(usize, @intCast(fd)), @intFromPtr(buf.ptr), buf.len, offset));
}

pub fn pwrite(fd: i32, buf: []const u8, offset: u64) ?usize {
    return ok(linux.syscall4(.pwrite64, @as(usize, @intCast(fd)), @intFromPtr(buf.ptr), buf.len, offset));
}

pub fn readFile(path: [:0]const u8, buf: []u8) ?[]u8 {
    const fd = openRead(path) orelse return null;
    defer close(fd);
    const n = pread(fd, buf, 0) orelse return null;
    return buf[0..n];
}

/// The file must exist: this never creates anything in /sys.
pub fn writeFile(path: [:0]const u8, data: []const u8) bool {
    const o: linux.O = .{ .ACCMODE = .WRONLY, .TRUNC = true, .CLOEXEC = true };
    const rc = ok(linux.syscall4(.openat, at_fdcwd, @intFromPtr(path.ptr), flags(o), 0)) orelse return false;
    const fd: i32 = @intCast(rc);
    defer close(fd);
    return (pwrite(fd, data, 0) orelse return false) == data.len;
}

/// Replaces a file in one step, so a crash leaves the old content or the new, never half.
pub fn replaceFile(path: [:0]const u8, data: []const u8) bool {
    var tmp_buf: [300]u8 = undefined;
    const tmp = join(&tmp_buf, &.{ path, ".tmp" });
    const o: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const rc = ok(linux.syscall4(.openat, at_fdcwd, @intFromPtr(tmp.ptr), flags(o), 0o600)) orelse return false;
    const fd: i32 = @intCast(rc);
    const written = (pwrite(fd, data, 0) orelse 0) == data.len;
    close(fd);
    if (!written) return false;
    return ok(linux.syscall4(.renameat, at_fdcwd, @intFromPtr(tmp.ptr), at_fdcwd, @intFromPtr(path.ptr))) != null;
}

pub fn appendFile(path: [:0]const u8, data: []const u8) bool {
    const o: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
    const rc = ok(linux.syscall4(.openat, at_fdcwd, @intFromPtr(path.ptr), flags(o), 0o600)) orelse return false;
    const fd: i32 = @intCast(rc);
    defer close(fd);
    const n = ok(linux.syscall3(.write, @as(usize, @intCast(fd)), @intFromPtr(data.ptr), data.len)) orelse return false;
    if (n != data.len) return false;
    _ = linux.syscall1(.fsync, @as(usize, @intCast(fd)));
    return true;
}

pub fn unlink(path: [:0]const u8) void {
    _ = linux.syscall3(.unlinkat, at_fdcwd, @intFromPtr(path.ptr), 0);
}

pub fn mkdir(path: [:0]const u8) void {
    _ = linux.syscall3(.mkdirat, at_fdcwd, @intFromPtr(path.ptr), 0o700);
}

pub fn exists(path: [:0]const u8) bool {
    const fd = openRead(path) orelse return false;
    close(fd);
    return true;
}

pub fn parseInt(text: []const u8) ?i64 {
    return std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t\r\n"), 10) catch null;
}

pub fn readInt(path: [:0]const u8) ?i64 {
    var buf: [32]u8 = undefined;
    return parseInt(readFile(path, &buf) orelse return null);
}

pub fn readIntFd(fd: i32) ?i64 {
    var buf: [32]u8 = undefined;
    const n = pread(fd, &buf, 0) orelse return null;
    return parseInt(buf[0..n]);
}

pub fn writeInt(path: [:0]const u8, value: i64) bool {
    var buf: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return false;
    return writeFile(path, text);
}

/// Names in a directory, through getdents64.
pub const Dir = struct {
    fd: i32,
    buf: [4096]u8 align(8) = undefined,
    len: usize = 0,
    pos: usize = 0,

    pub fn open(path: [:0]const u8) ?Dir {
        return .{ .fd = openDir(path) orelse return null };
    }

    pub fn next(self: *Dir) ?[]const u8 {
        while (true) {
            if (self.pos >= self.len) {
                const n = ok(linux.syscall3(.getdents64, @as(usize, @intCast(self.fd)), @intFromPtr(&self.buf), self.buf.len)) orelse return null;
                if (n == 0) return null;
                self.len = n;
                self.pos = 0;
            }
            const at = self.pos;
            const reclen = std.mem.readInt(u16, self.buf[at + 16 ..][0..2], .little);
            self.pos += reclen;
            const name = std.mem.sliceTo(self.buf[at + 19 .. at + reclen], 0);
            if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            return name;
        }
    }

    pub fn close(self: *Dir) void {
        sysClose(self.fd);
    }
};

fn sysClose(fd: i32) void {
    close(fd);
}

const Timespec = extern struct { sec: i64, nsec: i64 };

pub fn nowMs() i64 {
    var ts: Timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.syscall2(.clock_gettime, 1, @intFromPtr(&ts)); // CLOCK_MONOTONIC
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// Returns early when a signal arrives, which is how a stop request is noticed at once.
pub fn sleepMs(ms: i64) void {
    const ts = Timespec{ .sec = @divTrunc(ms, 1000), .nsec = @mod(ms, 1000) * 1_000_000 };
    _ = linux.syscall2(.nanosleep, @intFromPtr(&ts), 0);
}

pub fn exit(code: u8) noreturn {
    _ = linux.syscall1(.exit_group, code);
    unreachable;
}

pub fn prctl(option: usize, a2: usize) void {
    _ = linux.syscall5(.prctl, option, a2, 0, 0, 0);
}

pub fn raw(comptime nr: linux.SYS, a1: usize, a2: usize, a3: usize, a4: usize) ?usize {
    return ok(linux.syscall4(nr, a1, a2, a3, a4));
}

pub fn print(text: []const u8) void {
    _ = linux.syscall3(.write, 1, @intFromPtr(text.ptr), text.len);
}

pub fn eprint(text: []const u8) void {
    _ = linux.syscall3(.write, 2, @intFromPtr(text.ptr), text.len);
}

pub fn printf(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    print(std.fmt.bufPrint(&buf, fmt, args) catch return);
}

pub fn eprintf(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    eprint(std.fmt.bufPrint(&buf, fmt, args) catch return);
}
