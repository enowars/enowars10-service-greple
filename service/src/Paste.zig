const std = @import("std");
const utils = @import("utils.zig");

hash: utils.Hash,
title: []const u8,
text: []const u8,

fn openDir() !std.fs.Dir {
    return std.fs.cwd().openDir("pastes", .{});
}

pub fn init(title: []const u8, text: []const u8) @This() {
    return .{
        .hash = utils.combineHashes(utils.hash(title), utils.hash(text)),
        .title = title,
        .text = text,
    };
}

pub fn put(self: *const @This()) !void {
    if (self.title.len > std.math.maxInt(u16)) return error.TitleTooLong;
    if (self.text.len > std.math.maxInt(u16)) return error.TextTooLong;

    var dir = try openDir();
    defer dir.close();

    const filename = std.fmt.bytesToHex(self.hash, .lower);
    var file = dir.createFile(&filename, .{ .exclusive = true }) catch |err| switch (err) {
        std.fs.File.OpenError.PathAlreadyExists => return,
        else => |leftover_err| return leftover_err,
    };
    defer file.close();

    var writer = file.writer(&.{});

    try writer.interface.writeInt(u16, @truncate(self.title.len), .little);
    try writer.interface.writeAll(self.title);
    try writer.interface.writeInt(u16, @truncate(self.text.len), .little);
    try writer.interface.writeAll(self.text);
}

pub fn get(alloc: std.mem.Allocator, hash: utils.Hash) !@This() {
    var dir = try openDir();
    defer dir.close();

    var file = try dir.openFile(&std.fmt.bytesToHex(hash, .lower), .{});
    defer file.close();

    var buffer: [@sizeOf(u16)]u8 = undefined;
    var reader = file.reader(&buffer);

    return .{
        .hash = hash,
        .title = try reader.interface.readAlloc(alloc, try reader.interface.takeInt(u16, .little)),
        .text = try reader.interface.readAlloc(alloc, try reader.interface.takeInt(u16, .little)),
    };
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    alloc.free(self.title);
    alloc.free(self.text);
    self.* = undefined;
}
