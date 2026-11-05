// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // install.sh builds with -Doptimize=ReleaseSafe: a daemon that drives fans keeps its bounds checks
    const optimize = b.standardOptimizeOption(.{});
    const release = optimize != .debug;
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .single_threaded = true,
        .strip = if (release) true else null,
        .unwind_tables = if (release) .none else null,
    });
    b.installArtifact(b.addExecutable(.{ .name = "zcool", .root_module = module }));

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/all_tests.zig"),
        .target = target,
        .optimize = .debug,
    }) });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the unit tests").dependOn(&run_tests.step);
}
