const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const radio = b.dependency("radio", .{});
    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
        .linux_display_backend = .X11,
    });

    const raylib = raylib_dep.module("raylib"); // main raylib module
    raylib.addLibraryPath(b.path(".devbox/nix/profile/default/lib"));
    raylib.addSystemIncludePath(b.path(".devbox/nix/profile/default/include"));
    const raygui = raylib_dep.module("raygui"); // raygui module
    const raylib_artifact = raylib_dep.artifact("raylib"); // raylib C library
    // add vaxis dependency to module
    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("radio", radio.module("radio"));
    exe_mod.addImport("vaxis", vaxis.module("vaxis"));
    exe_mod.addLibraryPath(b.path(".devbox/nix/profile/default/lib"));
    exe_mod.addSystemIncludePath(b.path(".devbox/nix/profile/default/include"));
    const exe = b.addExecutable(.{
        .name = "tinyradio",
        .use_lld = false,

        .root_module = exe_mod,
    });
    exe.linkLibC();
    b.installArtifact(exe);

    const test_app = b.addExecutable(.{
        .name = "tinierradio",
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_app.root_module.addImport("radio", radio.module("radio"));
    test_app.root_module.addImport("raylib", raylib);
    test_app.root_module.addImport("raygui", raygui);
    test_app.addLibraryPath(b.path(".devbox/nix/profile/default/lib"));
    test_app.addSystemIncludePath(b.path(".devbox/nix/profile/default/include"));
    test_app.linkLibC();
    test_app.linkLibrary(raylib_artifact);
    b.installArtifact(test_app);

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
    exe_unit_tests.linkLibC();
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
