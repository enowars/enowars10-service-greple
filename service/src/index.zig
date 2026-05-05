const preferences = @import("preferences.zig");
const std = @import("std");

pub fn getDir(iterate: bool) !std.fs.Dir {
    return std.fs.cwd().openDir("index", .{ .iterate = iterate });
}

pub fn readHeader(
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    prefs: *const preferences.Preferences,
    sha1: []const u8,
) !?struct {
    url: []const u8,
    title: []const u8,
} {
    const file = try dir.openFile(sha1, .{});
    defer file.close();

    var reader = file.reader(&.{});
    // TODO: figure out a comptime way to calc the min allocation size
    var content: std.ArrayList(u8) = try .initCapacity(alloc, 32);
    while (true) {
        content.items.len += try reader.interface.readSliceShort(content.unusedCapacitySlice());
        if (std.mem.containsAtLeastScalar(u8, content.items, 3, '\n')) break;
        if (content.items.len < content.capacity) return error.InvalidIndexFileFormat;
        try content.ensureUnusedCapacity(alloc, 1);
    }

    var it = std.mem.splitScalar(u8, content.items, '\n');
    const user = it.next().?;
    if (blk: {
        if (std.mem.eql(u8, user, "anybody")) break :blk false;
        if (prefs.user) |u| if (std.mem.eql(u8, user, u)) break :blk false;
        break :blk true;
    }) return null;
    return .{ .url = it.next().?, .title = it.next().? };
}

pub fn writeEntry(
    alloc: std.mem.Allocator,
    prefs: *const preferences.Preferences,
    url: []const u8,
    title: []const u8,
    text: []const u8,
) !void {
    const user = prefs.user orelse "nobody";

    const data = try std.mem.concat(alloc, u8, &.{ user, "\x00", url });
    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(data, &hash, .{});
    const sha1 = std.fmt.bytesToHex(hash, .lower);

    var dir = try getDir(false);
    defer dir.close();

    var file = try dir.createFile(&sha1, .{ .exclusive = true });
    defer file.close();

    try file.writeAll(user);
    try file.writeAll("\n");
    try file.writeAll(url);
    try file.writeAll("\n");
    try file.writeAll(title);
    try file.writeAll("\n");
    try file.writeAll(text);
    try file.writeAll("\n");
}
