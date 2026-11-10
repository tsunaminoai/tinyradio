const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const radio = b.dependency("radio", .{});

    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    // Tracy zones. They compile to no-ops unless built with -Denable_ztracy=true.
    const enable_ztracy = b.option(bool, "enable_ztracy", "Record Tracy profiler zones") orelse false;
    const ztracy = b.dependency("ztracy", .{
        .target = target,
        .optimize = optimize,
        .enable_ztracy = enable_ztracy,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("radio", radio.module("radio"));
    exe_mod.addImport("vaxis", vaxis.module("vaxis"));
    exe_mod.addImport("ztracy", ztracy.module("root"));
    if (enable_ztracy) exe_mod.linkLibrary(ztracy.artifact("tracy"));
    exe_mod.addLibraryPath(b.path(".devbox/nix/profile/default/lib"));
    exe_mod.addSystemIncludePath(b.path(".devbox/nix/profile/default/include"));
    const exe = b.addExecutable(.{
        .name = "tinyradio",

        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // Benchmark: runs the FM stereo chain on a synthetic signal. No dongle needed.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bench_mod.addImport("radio", radio.module("radio"));
    bench_mod.addImport("ztracy", ztracy.module("root"));
    if (enable_ztracy) bench_mod.linkLibrary(ztracy.artifact("tracy"));
    const bench = b.addExecutable(.{
        .name = "tinyradio-bench",
        .root_module = bench_mod,
    });
    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Benchmark the tuner and FM stereo chain");
    bench_step.dependOn(&run_bench.step);
}
