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

// The helpers marked noinline are called from hundreds of places: inlined at each one they came
// to a seventh of the binary, and a call costs nothing next to the system call it makes.

/// Joins path pieces into `buf`. A path that does not fit becomes "", which fails to open.
pub noinline fn join(buf: []u8, parts: []const []const u8) [:0]const u8 {
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

pub noinline fn openRead(path: [:0]const u8) ?i32 {
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

pub noinline fn readFile(path: [:0]const u8, buf: []u8) ?[]u8 {
    const fd = openRead(path) orelse return null;
    defer close(fd);
    const n = pread(fd, buf, 0) orelse return null;
    return buf[0..n];
}

/// The file must exist: this never creates anything in /sys.
pub noinline fn writeFile(path: [:0]const u8, data: []const u8) bool {
    const o: linux.O = .{ .ACCMODE = .WRONLY, .TRUNC = true, .CLOEXEC = true };
    const rc = ok(linux.syscall4(.openat, at_fdcwd, @intFromPtr(path.ptr), flags(o), 0)) orelse return false;
    const fd: i32 = @intCast(rc);
    defer close(fd);
    return (pwrite(fd, data, 0) orelse return false) == data.len;
}

/// Replaces a file in one step, so a crash leaves the old content or the new, never half.
pub noinline fn replaceFile(path: [:0]const u8, data: []const u8) bool {
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

pub noinline fn exists(path: [:0]const u8) bool {
    const fd = openRead(path) orelse return false;
    close(fd);
    return true;
}

pub fn parseInt(text: []const u8) ?i64 {
    return std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t\r\n"), 10) catch null;
}

pub noinline fn readInt(path: [:0]const u8) ?i64 {
    var buf: [32]u8 = undefined;
    return parseInt(readFile(path, &buf) orelse return null);
}

pub noinline fn readIntFd(fd: i32) ?i64 {
    var buf: [32]u8 = undefined;
    const n = pread(fd, &buf, 0) orelse return null;
    return parseInt(buf[0..n]);
}

pub noinline fn writeInt(path: [:0]const u8, value: i64) bool {
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

pub fn readLink(path: [:0]const u8, buf: []u8) ?[]u8 {
    const n = ok(linux.syscall4(.readlinkat, at_fdcwd, @intFromPtr(path.ptr), @intFromPtr(buf.ptr), buf.len)) orelse return null;
    return buf[0..n];
}

pub fn write(fd: i32, data: []const u8) bool {
    var done: usize = 0;
    while (done < data.len) {
        const n = ok(linux.syscall3(.write, @as(usize, @intCast(fd)), @intFromPtr(data[done..].ptr), data.len - done)) orelse return false;
        if (n == 0) return false;
        done += n;
    }
    return true;
}

pub fn read(fd: i32, buf: []u8) ?usize {
    return ok(linux.syscall3(.read, @as(usize, @intCast(fd)), @intFromPtr(buf.ptr), buf.len));
}

/// A process with a pipe to its stdin and one from its stdout. Its stderr is ours.
pub const Child = struct { pid: i32, to: i32, from: i32 };

pub fn spawn(path: [:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) ?Child {
    var down: [2]i32 = undefined;
    var up: [2]i32 = undefined;
    _ = ok(linux.pipe2(&down, .{ .CLOEXEC = true })) orelse return null;
    _ = ok(linux.pipe2(&up, .{ .CLOEXEC = true })) orelse {
        close(down[0]);
        close(down[1]);
        return null;
    };
    const pid = ok(linux.fork()) orelse {
        for ([_]i32{ down[0], down[1], up[0], up[1] }) |fd| close(fd);
        return null;
    };
    if (pid == 0) {
        // the copies lose close-on-exec; every other end of the pipes closes at exec
        _ = linux.dup2(down[0], 0);
        _ = linux.dup2(up[1], 1);
        _ = linux.execve(path.ptr, argv, envp);
        linux.exit_group(127);
    }
    close(down[0]);
    close(up[1]);
    return .{ .pid = @intCast(pid), .to = down[1], .from = up[0] };
}

/// True when `fd` has something to read, or its other end is gone.
pub fn waitReadable(fd: i32, timeout_ms: i32) bool {
    var fds = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN }};
    const n = ok(linux.poll(&fds, 1, timeout_ms)) orelse return false;
    return n > 0;
}

/// Collects a child that has ended, or waits up to `ms` for it to end. True when it is gone.
pub fn reap(pid: i32, ms: i64) bool {
    var waited: i64 = 0;
    while (true) {
        var status: i32 = 0;
        const rc = ok(linux.wait4(pid, &status, linux.W.NOHANG, null)) orelse return true;
        if (rc != 0) return true;
        if (waited >= ms) return false;
        sleepMs(20);
        waited += 20;
    }
}

/// A process that only burns one core, `cpu`, until it is killed, or zcool goes however it goes.
pub fn forkWorker(cpu: usize) ?i32 {
    const parent = linux.getpid();
    const pid = ok(linux.fork()) orelse return null;
    if (pid != 0) return @intCast(pid);
    prctl(1, @backingInt(linux.SIG.KILL)); // PR_SET_PDEATHSIG
    if (linux.getppid() != parent) linux.exit_group(0);
    var mask: [16]usize = @splat(0);
    const bits = @bitSizeOf(usize);
    if (cpu / bits < mask.len) {
        mask[cpu / bits] = @as(usize, 1) << @intCast(cpu % bits);
        _ = linux.syscall3(.sched_setaffinity, 0, @sizeOf(@TypeOf(mask)), @intFromPtr(&mask));
    }
    var x: f64 = 1;
    while (true) {
        x = x * 1.0000001 + 0.000001;
        std.mem.doNotOptimizeAway(x);
    }
}

/// The CPUs this process may run on.
pub fn cpuCount() usize {
    var mask: [16]usize = @splat(0);
    _ = ok(linux.syscall3(.sched_getaffinity, 0, @sizeOf(@TypeOf(mask)), @intFromPtr(&mask))) orelse return 1;
    var n: usize = 0;
    for (mask) |word| n += @popCount(word);
    return @max(n, 1);
}

pub fn kill(pid: i32, signal: linux.SIG) void {
    _ = linux.kill(pid, signal);
}

/// Ignores SIGPIPE: a write to a pipe whose reader is gone fails instead of ending the process.
pub fn ignoreSigpipe() void {
    var ignore = linux.Sigaction{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(.PIPE, &ignore, null);
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

// ---------------------------------------------------------------- what ztune adds

/// A generic netlink socket, bound and non-blocking: nl80211 lives there.
pub fn netlinkGeneric() ?i32 {
    const SOCK_RAW = 3;
    const SOCK_NONBLOCK = 0o4000;
    const SOCK_CLOEXEC = 0o2000000;
    const fd = ok(linux.syscall3(.socket, 16, SOCK_RAW | SOCK_NONBLOCK | SOCK_CLOEXEC, 16)) orelse return null;
    const Addr = extern struct { family: u16 = 16, pad: u16 = 0, pid: u32 = 0, groups: u32 = 0 };
    const addr = Addr{};
    _ = ok(linux.syscall3(.bind, fd, @intFromPtr(&addr), @sizeOf(Addr))) orelse {
        close(@intCast(fd));
        return null;
    };
    return @intCast(fd);
}

pub fn send(fd: i32, data: []const u8) bool {
    const MSG_NOSIGNAL = 0x4000;
    const n = ok(linux.syscall6(.sendto, @as(usize, @intCast(fd)), @intFromPtr(data.ptr), data.len, MSG_NOSIGNAL, 0, 0)) orelse return false;
    return n == data.len;
}

pub const sched_other: usize = 0;
pub const sched_batch: usize = 3;

/// A thread's scheduling policy, or null when it is gone.
pub fn schedPolicy(tid: i32) ?usize {
    return ok(linux.syscall1(.sched_getscheduler, @as(usize, @intCast(tid))));
}

pub fn setSchedPolicy(tid: i32, policy: usize) bool {
    const param: i32 = 0;
    return ok(linux.syscall3(.sched_setscheduler, @as(usize, @intCast(tid)), policy, @intFromPtr(&param))) != null;
}
