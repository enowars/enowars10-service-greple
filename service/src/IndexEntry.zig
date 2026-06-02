const std = @import("std");
const utils = @import("utils.zig");

public: bool,
user_hash: utils.Hash,
url_hash: utils.Hash,
url: []const u8,
title: []const u8,

pub fn openDir(args: std.fs.Dir.OpenOptions) !std.fs.Dir {
    return std.fs.cwd().openDir("index", args);
}

fn genFilename(user_hash: utils.Hash, url_hash: utils.Hash) [@sizeOf(utils.Hash) * 2]u8 {
    return std.fmt.bytesToHex(utils.combineHashes(user_hash, url_hash), .lower);
}

pub fn put(self: *const @This()) !void {
    if (self.url.len > std.math.maxInt(u16)) return error.UrlTooLong;
    if (self.title.len > std.math.maxInt(u16)) return error.TitleTooLong;

    var dir = try openDir(.{});
    defer dir.close();

    var file = try dir.createFile(&genFilename(self.user_hash, self.url_hash), .{});
    defer file.close();

    var writer = file.writer(&.{});

    try writer.interface.writeByte(@intFromBool(self.public));
    try writer.interface.writeInt(u16, @truncate(self.url.len), .little);
    try writer.interface.writeAll(self.url);
    try writer.interface.writeInt(u16, @truncate(self.title.len), .little);
    try writer.interface.writeAll(self.title);
}

pub fn get(alloc: std.mem.Allocator, user_hash: utils.Hash, url_hash: utils.Hash) !@This() {
    var dir = try openDir(.{});
    defer dir.close();

    const filename = genFilename(user_hash, url_hash);
    const file = try dir.openFile(&filename, .{});
    defer file.close();

    var buffer: [@max(1, @sizeOf(utils.Hash), @sizeOf(u16))]u8 = undefined;
    var reader = file.reader(&buffer);

    return .{
        .public = try reader.interface.takeByte() == @intFromBool(true),
        .user_hash = user_hash,
        .url_hash = url_hash,
        .url = try reader.interface.readAlloc(alloc, try reader.interface.takeInt(u16, .little)),
        .title = try reader.interface.readAlloc(alloc, try reader.interface.takeInt(u16, .little)),
    };
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    alloc.free(self.url);
    alloc.free(self.title);
    self.* = undefined;
}

pub fn getSize() !u32 {
    var dir = try openDir(.{ .iterate = true });
    defer dir.close();

    var size: u32 = 0;
    var it = dir.iterateAssumeFirstIteration();
    while (try it.next()) |_| size += 1;

    return size;
}
