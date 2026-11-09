// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const release = optimize != .debug;
    const module = b.createModule(.{
        .root_source_file = b.path("src/jitter.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .single_threaded = true,
        .strip = if (release) true else null,
        .unwind_tables = if (release) .none else null,
    });
    b.installArtifact(b.addExecutable(.{ .name = "zjitter", .root_module = module }));

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/jitter.zig"),
        .target = target,
        .optimize = .debug,
    }) });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);
}
