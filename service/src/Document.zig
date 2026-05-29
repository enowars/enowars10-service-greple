const IndexEntry = @import("IndexEntry.zig");
const std = @import("std");

text: []const []const u8,

pub fn openDir() !std.fs.Dir {
    return std.fs.cwd().openDir("documents", .{});
}

pub fn put(self: *const @This(), index_entry: *const IndexEntry) !void {
    var dir = try openDir();
    defer dir.close();

    const dirname = std.fmt.bytesToHex(index_entry.domain_hash, .lower);
    dir.makeDir(&dirname) catch |err| switch (err) {
        std.fs.Dir.MakeError.PathAlreadyExists => {},
        else => |leftover_err| return leftover_err,
    };
    var domain_dir = try dir.openDir(&dirname, .{});
    defer domain_dir.close();

    var file = try domain_dir.createFile(&std.fmt.bytesToHex(index_entry.path_hash, .lower), .{ .exclusive = true });
    defer file.close();

    for (self.text) |l| {
        try file.writeAll(l);
        try file.writeAll("\n");
    }
}
