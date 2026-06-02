const Url = @import("Url.zig");
const std = @import("std");

pub const bytes = 64 / 8;

hash: [bytes]u8,
url: Url,

fn openDir() !std.fs.Dir {
    return std.fs.cwd().openDir("urls", .{});
}

pub fn init(url: []const u8) !@This() {
    const u: Url = try .init(url);
    return .{ .hash = u.hash()[0..bytes].*, .url = u };
}

pub fn put(self: *const @This()) !void {
    var dir = try openDir();
    defer dir.close();

    var file = dir.createFile(&std.fmt.bytesToHex(self.hash, .lower), .{ .exclusive = true }) catch |err| switch (err) {
        std.fs.File.OpenError.PathAlreadyExists => return,
        else => |leftover_err| return leftover_err,
    };
    defer file.close();

    var writer = file.writer(&.{});
    try self.url.write(&writer.interface);
}

pub fn get(alloc: std.mem.Allocator, hash: [bytes]u8) !@This() {
    var dir = try openDir();
    defer dir.close();

    var file = try dir.openFile(&std.fmt.bytesToHex(hash, .lower), .{});
    defer file.close();

    var buffer: [Url.read_buffer_len]u8 = undefined;
    var reader = file.reader(&buffer);

    return .{
        .hash = hash,
        .url = try .read(alloc, &reader.interface),
    };
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    self.url.deinit(alloc);
    self.* = undefined;
}
