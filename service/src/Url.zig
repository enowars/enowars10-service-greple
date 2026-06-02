const crawl = @import("crawl.zig");
const std = @import("std");
const utils = @import("utils.zig");

pub const bytes = 64 / 8;

hash: [bytes]u8,
url: []const u8,

fn openDir() !std.fs.Dir {
    return std.fs.cwd().openDir("urls", .{});
}

pub fn init(url: []const u8) !@This() {
    return .{ .hash = utils.hash(url)[0..bytes].*, .url = url };
}

pub fn put(self: *const @This()) !void {
    if (self.url.len > std.math.maxInt(u16)) return error.UrlTooLong;

    var dir = try openDir();
    defer dir.close();

    var file = dir.createFile(&std.fmt.bytesToHex(self.hash, .lower), .{ .exclusive = true }) catch |err| switch (err) {
        std.fs.File.OpenError.PathAlreadyExists => return,
        else => |leftover_err| return leftover_err,
    };
    defer file.close();

    var writer = file.writer(&.{});

    try writer.interface.writeInt(u16, @truncate(self.url.len), .little);
    try writer.interface.writeAll(self.url);
}

pub fn get(alloc: std.mem.Allocator, hash: [bytes]u8) !@This() {
    var dir = try openDir();
    defer dir.close();

    var file = try dir.openFile(&std.fmt.bytesToHex(hash, .lower), .{});
    defer file.close();

    var buffer: [@max(bytes, @sizeOf(u16))]u8 = undefined;
    var reader = file.reader(&buffer);

    return .{
        .hash = hash,
        .url = try reader.interface.readAlloc(alloc, try reader.interface.takeInt(u16, .little)),
    };
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    alloc.free(self.url);
    self.* = undefined;
}
