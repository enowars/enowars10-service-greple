const IndexEntry = @import("IndexEntry.zig");
const std = @import("std");
const utils = @import("utils.zig");

text: []const []const u8,

pub fn openDir() !std.fs.Dir {
    return std.fs.cwd().openDir("documents", .{});
}

pub fn put(self: *const @This(), index_entry: *const IndexEntry) !void {
    var dir = try openDir();
    defer dir.close();

    const dirname = std.fmt.bytesToHex(index_entry.user_hash, .lower);
    dir.makeDir(&dirname) catch |err| switch (err) {
        std.fs.Dir.MakeError.PathAlreadyExists => {},
        else => |leftover_err| return leftover_err,
    };
    var user_dir = try dir.openDir(&dirname, .{});
    defer user_dir.close();

    var writer: utils.Writer = try .open(user_dir, &std.fmt.bytesToHex(index_entry.url.hash(), .lower));
    defer writer.close();
    for (self.text) |l| try writer.interface().print("{s}\n", .{l});
    try writer.end();
}

pub fn runCron(user_hash_hex: []const u8) !void {
    var dir = try openDir();
    defer dir.close();
    try dir.deleteTree(user_hash_hex);
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    for (self.text) |l| alloc.free(l);
    alloc.free(self.text);
    self.* = undefined;
}
