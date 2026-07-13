const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mvzr = b.dependency("mvzr", .{
        .target = target,
        .optimize = optimize,
    }).module("mvzr");

    const zap = b.dependency("zap", .{
        .target = target,
        .optimize = optimize,
        .openssl = false,
    }).module("zap");

    const greple = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mvzr", .module = mvzr },
            .{ .name = "zap", .module = zap },
        },
    });

    b.installArtifact(b.addExecutable(.{
        .name = "greple",
        .root_module = greple,
    }));

    const cron = b.createModule(.{
        .root_source_file = b.path("src/cron.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(b.addExecutable(.{
        .name = "cron",
        .root_module = cron,
    }));

    b.step("test", "Run tests").dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = greple,
    })).step);
}
