const std = @import("std");
const Url = @import("Url.zig");
const utils = @import("utils.zig");

pub const bytes = 64 / 8;

url: Url,

fn openDir(args: std.fs.Dir.OpenOptions) !std.fs.Dir {
    return std.fs.cwd().openDir("urls", args);
}

pub fn init(alloc: std.mem.Allocator, url: []const u8) !@This() {
    return .{ .url = try .init(alloc, url, true) };
}

pub fn put(self: *const @This()) !void {
    var dir = try openDir(.{});
    defer dir.close();

    var writer: utils.Writer = try .open(dir, &std.fmt.bytesToHex(self.hash(), .lower));
    defer writer.close();
    try self.url.write(writer.interface());
    try writer.end();
}

pub fn get(alloc: std.mem.Allocator, short_url_hash: [bytes]u8) !@This() {
    var dir = try openDir(.{});
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

pub fn runCron(threshold: i128) !void {
    var dir = try openDir(.{ .iterate = true });
    defer dir.close();

    var it = dir.iterateAssumeFirstIteration();
    while (try it.next()) |e| {
        if (e.name[0] == '.') continue;
        const stat = try dir.statFile(e.name);
        if (stat.mtime > threshold) continue;
        try dir.deleteFile(e.name);
    }
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    self.url.deinit(alloc);
    self.* = undefined;
}
