const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Xlib, XFixes and a few libc headers, translated once by the build.
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "pet",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "c", .module = translate.createModule() },
            },
        }),
    });
    exe.root_module.linkSystemLibrary("X11", .{});
    exe.root_module.linkSystemLibrary("Xfixes", .{});
    exe.root_module.linkSystemLibrary("Xext", .{});
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the desktop pet");
    run_step.dependOn(&run_cmd.step);

    // `zig build sheet` writes every animation frame to zig-out/sheet.ppm so the
    // art can be checked without launching the overlay.
    const sheet = b.addExecutable(.{
        .name = "sheet",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/sheet.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "c", .module = translate.createModule() },
                .{ .name = "sprites", .module = b.createModule(.{ .root_source_file = b.path("src/sprites.zig"), .target = target, .optimize = optimize }) },
            },
        }),
    });
    const run_sheet = b.addRunArtifact(sheet);
    run_sheet.addArg("zig-out/sheet.ppm");
    b.step("sheet", "Dump all sprite frames to zig-out/sheet.ppm").dependOn(&run_sheet.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
