const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const radio = b.dependency("radio", .{});
    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });

    const raylib = raylib_dep.module("raylib"); // main raylib module
    const raygui = raylib_dep.module("raygui"); // raygui module
    const raylib_artifact = raylib_dep.artifact("raylib"); // raylib C library

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "tinyradio",
        .use_lld = false,

        .root_module = exe_mod,
    });
    exe.root_module.addImport("radio", radio.module("radio"));
    exe.root_module.addImport("raylib", raylib);
    exe.root_module.addImport("raygui", raygui);
    exe.addLibraryPath(b.path(".devbox/nix/profile/default/lib"));
    exe.addSystemIncludePath(b.path(".devbox/nix/profile/default/include"));
    exe.linkLibC();
    exe.linkLibrary(raylib_artifact);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
        .use_lld = false,
    });
    exe_unit_tests.root_module.addImport("radio", radio.module("radio"));
    exe_unit_tests.root_module.addImport("raylib", raylib);
    exe_unit_tests.root_module.addImport("raygui", raygui);
    exe_unit_tests.addLibraryPath(b.path(".devbox/nix/profile/default/lib"));
    exe_unit_tests.addSystemIncludePath(b.path(".devbox/nix/profile/default/include"));
    exe_unit_tests.linkLibC();
    exe_unit_tests.linkLibrary(raylib_artifact);
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
