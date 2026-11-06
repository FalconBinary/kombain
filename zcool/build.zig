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

    // the one part that needs libc: NVIDIA's library is only reachable through dlopen
    const helper = b.createModule(.{
        .root_source_file = b.path("src/nvidia_helper.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .single_threaded = true,
        .strip = if (release) true else null,
    });
    b.installArtifact(b.addExecutable(.{ .name = "zcool-nvidia", .root_module = helper }));

    // tests/sim.py loads this in place of NVIDIA's library
    const fake = b.addLibrary(.{
        .name = "nvidia-ml",
        .linkage = .dynamic,
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fake_nvml.zig"),
            .target = target,
            .optimize = .debug,
            .link_libc = true,
        }),
    });
    const install_fake = b.addInstallArtifact(fake, .{ .dest_dir = .{ .override = .{ .custom = "fake-nvml" } } });
    b.step("fake-nvml", "Build the stand-in for NVIDIA's library that tests/sim.py uses").dependOn(&install_fake.step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/all_tests.zig"),
        .target = target,
        .optimize = .debug,
    }) });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the unit tests").dependOn(&run_tests.step);
}
