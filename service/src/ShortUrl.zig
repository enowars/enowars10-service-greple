const Url = @import("Url.zig");
const std = @import("std");

pub const bytes = 64 / 8;

url: Url,

fn openDir() !std.fs.Dir {
    return std.fs.cwd().openDir("urls", .{});
}

pub fn init(alloc: std.mem.Allocator, url: []const u8) !@This() {
    return .{ .url = try .init(alloc, url, true) };
}

pub fn put(self: *const @This()) !void {
    var dir = try openDir();
    defer dir.close();

    const filename = &std.fmt.bytesToHex(self.hash(), .lower);
    var file = dir.createFile(filename, .{ .exclusive = true }) catch |err| switch (err) {
        std.fs.File.OpenError.PathAlreadyExists => return,
        else => |leftover_err| return leftover_err,
    };
    defer file.close();

    var writer = file.writer(&.{});
    try self.url.write(&writer.interface);
}

pub fn get(alloc: std.mem.Allocator, short_url_hash: [bytes]u8) !@This() {
    var dir = try openDir();
    defer dir.close();

    var file = try dir.openFile(&std.fmt.bytesToHex(short_url_hash, .lower), .{});
    defer file.close();

    var buffer: [Url.read_buffer_len]u8 = undefined;
    var reader = file.reader(&buffer);

    return .{ .url = try .read(alloc, &reader.interface) };
}

pub fn hash(self: *const @This()) [bytes]u8 {
    return self.url.hash()[0..bytes].*;
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    self.url.deinit(alloc);
    self.* = undefined;
}
