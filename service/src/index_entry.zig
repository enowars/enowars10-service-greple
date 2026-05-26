const std = @import("std");
const utils = @import("utils.zig");

public: bool,
domain_hash: utils.Hash,
path_hash: utils.Hash,
path: []const u8,
title: []const u8,

pub fn openDir(args: std.fs.Dir.OpenOptions) !std.fs.Dir {
    return std.fs.cwd().openDir("index", args);
}

fn genFilename(alloc: std.mem.Allocator, domain_hash: utils.Hash, path_hash: utils.Hash) ![]const u8 {
    return std.mem.concat(alloc, u8, &.{
        &std.fmt.bytesToHex(domain_hash, .lower),
        &std.fmt.bytesToHex(path_hash, .lower),
    });
}

pub fn put(self: *const @This(), alloc: std.mem.Allocator) !void {
    if (self.path.len > std.math.maxInt(u16)) return error.PathTooLong;
    if (self.title.len > std.math.maxInt(u16)) return error.TitleTooLong;

    var dir = try openDir(.{});
    defer dir.close();

    const filename = try genFilename(alloc, self.domain_hash, self.path_hash);
    defer alloc.free(filename);

    var file = try dir.createFile(filename, .{ .exclusive = true });
    defer file.close();

    var writer = file.writer(&.{});

    try writer.interface.writeByte(@intFromBool(self.public));
    try writer.interface.writeInt(u16, @truncate(self.path.len), .little);
    try writer.interface.writeAll(self.path);
    try writer.interface.writeInt(u16, @truncate(self.title.len), .little);
    try writer.interface.writeAll(self.title);
}

pub fn get(alloc: std.mem.Allocator, domain_hash: utils.Hash, path_hash: utils.Hash) !@This() {
    var dir = try openDir(.{});
    defer dir.close();

    const filename = try genFilename(alloc, domain_hash, path_hash);
    defer alloc.free(filename);

    const file = try dir.openFile(filename, .{});
    defer file.close();

    var buffer: [@max(1, @sizeOf(utils.Hash), @sizeOf(u16))]u8 = undefined;
    var reader = file.reader(&buffer);

    return .{
        .public = try reader.interface.takeByte() == @intFromBool(true),
        .domain_hash = domain_hash,
        .path_hash = path_hash,
        .path = try reader.interface.readAlloc(alloc, try reader.interface.takeInt(u16, .little)),
        .title = try reader.interface.readAlloc(alloc, try reader.interface.takeInt(u16, .little)),
    };
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    alloc.free(self.path);
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
