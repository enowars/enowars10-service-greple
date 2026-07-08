const std = @import("std");
const utils = @import("utils.zig");

title: []const u8,
text: []const u8,

fn openDir(args: std.fs.Dir.OpenOptions) !std.fs.Dir {
    return std.fs.cwd().openDir("pastes", args);
}

pub fn put(self: *const @This()) !void {
    if (self.title.len > std.math.maxInt(u16)) return error.TitleTooLong;
    if (self.text.len > std.math.maxInt(u16)) return error.TextTooLong;

    var dir = try openDir(.{});
    defer dir.close();

    var writer: utils.Writer = try .open(dir, &std.fmt.bytesToHex(self.hash(), .lower));
    defer writer.close();
    try writer.interface().writeInt(u16, @truncate(self.title.len), .little);
    try writer.interface().writeAll(self.title);
    try writer.interface().writeInt(u16, @truncate(self.text.len), .little);
    try writer.interface().writeAll(self.text);
    try writer.end();
}

pub fn get(alloc: std.mem.Allocator, paste_hash: utils.Hash) !@This() {
    var dir = try openDir(.{});
    defer dir.close();

    var file = try dir.openFile(&std.fmt.bytesToHex(paste_hash, .lower), .{});
    defer file.close();

    var buffer: [@sizeOf(u16)]u8 = undefined;
    var reader = file.reader(&buffer);

    const title = try reader.interface.readAlloc(alloc, try reader.interface.takeInt(u16, .little));
    errdefer alloc.free(title);
    const text = try reader.interface.readAlloc(alloc, try reader.interface.takeInt(u16, .little));
    errdefer alloc.free(text);

    return .{ .title = title, .text = text };
}

pub fn hash(self: *const @This()) utils.Hash {
    return utils.hash(&utils.hash(self.title) ++ &utils.hash(self.text));
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
    alloc.free(self.title);
    alloc.free(self.text);
    self.* = undefined;
}
