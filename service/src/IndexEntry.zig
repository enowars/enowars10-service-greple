const std = @import("std");
const Url = @import("Url.zig");
const utils = @import("utils.zig");

public: bool,
user_hash: utils.Hash,
url_hash: utils.Hash,
url: Url,
title: []const u8,

pub fn openDir(args: std.fs.Dir.OpenOptions) !std.fs.Dir {
    return std.fs.cwd().openDir("index", args);
}

fn genFilename(user_hash: utils.Hash, url_hash: utils.Hash) [@sizeOf(utils.Hash) * 2]u8 {
    return std.fmt.bytesToHex(utils.combineHashes(user_hash, url_hash), .lower);
}

pub fn put(self: *const @This()) !void {
    if (self.title.len > std.math.maxInt(u16)) return error.TitleTooLong;

    var dir = try openDir(.{});
    defer dir.close();

    var file = try dir.createFile(&genFilename(self.user_hash, self.url_hash), .{});
    defer file.close();

    var writer = file.writer(&.{});

    try writer.interface.writeByte(@intFromBool(self.public));
    try self.url.write(&writer.interface);
    try writer.interface.writeInt(u16, @truncate(self.title.len), .little);
    try writer.interface.writeAll(self.title);
}

pub fn get(alloc: std.mem.Allocator, user_hash: utils.Hash, url_hash: utils.Hash) !@This() {
    var dir = try openDir(.{});
    defer dir.close();

    const file = try dir.openFile(&genFilename(user_hash, url_hash), .{});
    defer file.close();

    var buffer: [@max(1, Url.read_buffer_len, @sizeOf(u16))]u8 = undefined;
    var reader = file.reader(&buffer);

    return .{
        .public = try reader.interface.takeByte() == @intFromBool(true),
        .user_hash = user_hash,
        .url_hash = url_hash,
        .url = try .read(alloc, &reader.interface),
        .title = try reader.interface.readAlloc(alloc, try reader.interface.takeInt(u16, .little)),
    };
}

pub fn getSize() !u32 {
    var dir = try openDir(.{ .iterate = true });
    defer dir.close();

    var size: u32 = 0;
    var it = dir.iterateAssumeFirstIteration();
    while (try it.next()) |_| size += 1;

    return size;
}
