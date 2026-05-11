const std = @import("std");
const utils = @import("utils.zig");

const bits = 64;

fn openDir() !std.fs.Dir {
    return std.fs.cwd().openDir("urls", .{});
}

pub fn writeURL(url: []const u8) ![bits / 4]u8 {
    var hash_bytes: [utils.Hash.digest_length]u8 = undefined;
    utils.Hash.hash(url, &hash_bytes, .{});
    const hash = std.fmt.bytesToHex(hash_bytes[0 .. bits / 8], .lower);

    var dir = try openDir();
    defer dir.close();

    blk: {
        var file = dir.createFile(&hash, .{ .exclusive = true }) catch |err| switch (err) {
            std.fs.File.OpenError.PathAlreadyExists => break :blk,
            else => |leftover_err| return leftover_err,
        };
        defer file.close();
        try file.writeAll(url);
    }

    return hash;
}

pub fn getURL(alloc: std.mem.Allocator, hash: []const u8) ![]const u8 {
    var dir = try openDir();
    defer dir.close();

    // TODO: an attacker can control hash is that bad?
    var file = try dir.openFile(hash, .{});
    defer file.close();

    var reader = file.reader(&.{});
    return try reader.interface.allocRemaining(alloc, .unlimited);
}
