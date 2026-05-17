const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    }).module("httpz");

    const mvzr = b.dependency("mvzr", .{
        .target = target,
        .optimize = optimize,
    }).module("mvzr");

    const greple = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "httpz", .module = httpz },
            .{ .name = "mvzr", .module = mvzr },
        },
    });

    b.installArtifact(b.addExecutable(.{
        .name = "greple",
        .root_module = greple,
    }));

    b.step("test", "Run tests").dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = greple,
    })).step);
}
