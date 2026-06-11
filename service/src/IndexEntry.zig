const std = @import("std");
const Url = @import("Url.zig");
const User = @import("User.zig");
const utils = @import("utils.zig");

public: bool,
user_hash: utils.Hash,
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

    var file = try dir.createFile(&genFilename(self.user_hash, self.url.hash()), .{});
    defer file.close();

    var writer = file.writer(&.{});

    try writer.interface.writeByte(@intFromBool(self.public));
    try writer.interface.writeAll(&self.user_hash);
    try self.url.write(&writer.interface);
    try writer.interface.writeInt(u16, @truncate(self.title.len), .little);
    try writer.interface.writeAll(self.title);
}

fn getFn(alloc: std.mem.Allocator, dir: std.fs.Dir, filename: []const u8) !@This() {
    const file = try dir.openFile(filename, .{});
    defer file.close();

    var buffer: [@max(1, @sizeOf(utils.Hash), Url.read_buffer_len, @sizeOf(u16))]u8 = undefined;
    var reader = file.reader(&buffer);

    const public = try reader.interface.takeByte() == @intFromBool(true);
    const user_hash = (try reader.interface.takeArray(@sizeOf(utils.Hash))).*;
    var url: Url = try .read(alloc, &reader.interface);
    errdefer url.deinit(alloc);
    const title = try reader.interface.readAlloc(alloc, try reader.interface.takeInt(u16, .little));
    errdefer alloc.free(title);

    return .{
        .public = public,
        .user_hash = user_hash,
        .url = url,
        .title = title,
    };
}

pub fn get(alloc: std.mem.Allocator, user_hash: utils.Hash, url_hash: utils.Hash) !@This() {
    var dir = try openDir(.{});
    defer dir.close();
    return getFn(alloc, dir, &genFilename(user_hash, url_hash));
}

pub fn getSize() !u32 {
    var dir = try openDir(.{ .iterate = true });
    defer dir.close();

    var size: u32 = 0;
    var it = dir.iterateAssumeFirstIteration();
    while (try it.next()) |_| size += 1;

    return size;
}

pub fn getUserEntries(alloc: std.mem.Allocator, user: *const User) ![]const @This() {
    var dir = try openDir(.{ .iterate = true });
    defer dir.close();

    var entries: std.ArrayList(@This()) = .empty;
    defer entries.deinit(alloc);

    var it = dir.iterateAssumeFirstIteration();
    while (try it.next()) |e| {
        var ie = try getFn(alloc, dir, e.name);
        errdefer ie.deinit(alloc);
        std.debug.print("{f}\n", .{ie.url});
        if (!std.mem.eql(u8, &user.hash, &ie.user_hash)) {
            ie.deinit(alloc);
            continue;
        }
        std.debug.print("ok\n", .{});
        try entries.append(alloc, ie);
    }

    return try entries.toOwnedSlice(alloc);
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    self.url.deinit(alloc);
    alloc.free(self.title);
    self.* = undefined;
}
