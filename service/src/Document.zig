const IndexEntry = @import("IndexEntry.zig");
const std = @import("std");

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

    var file = try user_dir.createFile(&std.fmt.bytesToHex(index_entry.url.hash(), .lower), .{});
    defer file.close();

    var writer = file.writer(&.{});

    for (self.text) |l| try writer.interface.print("{s}\n", .{l});
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    for (self.text) |l| alloc.free(l);
    alloc.free(self.text);
    self.* = undefined;
}
