const Domain = @import("Domain.zig");
const std = @import("std");
const utils = @import("utils.zig");

pub const bytes = 64 / 8;

hash: [bytes]u8,
domain_hash: utils.Hash,
path: []const u8,

fn openDir() !std.fs.Dir {
    return std.fs.cwd().openDir("urls", .{});
}

pub fn init(domain: *const Domain, path: []const u8) !@This() {
    if (path.len <= "/u/".len + bytes * 2) return error.UrlAlreadyShort;
    return .{
        .hash = utils.hash(path)[0..bytes].*,
        .domain_hash = domain.hash,
        .path = path,
    };
}

pub fn put(self: *const @This()) !void {
    if (self.path.len > std.math.maxInt(u16)) return error.PathTooLong;

    var dir = try openDir();
    defer dir.close();

    var file = dir.createFile(&std.fmt.bytesToHex(self.hash, .lower), .{ .exclusive = true }) catch |err| switch (err) {
        std.fs.File.OpenError.PathAlreadyExists => return,
        else => |leftover_err| return leftover_err,
    };
    defer file.close();

    var writer = file.writer(&.{});

    try writer.interface.writeAll(&self.domain_hash);
    try writer.interface.writeInt(u16, @truncate(self.path.len), .little);
    try writer.interface.writeAll(self.path);
}

pub fn get(alloc: std.mem.Allocator, hash: [bytes]u8) !@This() {
    var dir = try openDir();
    defer dir.close();

    var file = try dir.openFile(&std.fmt.bytesToHex(hash, .lower), .{});
    defer file.close();

    var buffer: [@max(bytes, @sizeOf(utils.Hash), @sizeOf(u16))]u8 = undefined;
    var reader = file.reader(&buffer);

    return .{
        .hash = hash,
        .domain_hash = (try reader.interface.takeArray(@sizeOf(utils.Hash))).*,
        .path = try reader.interface.readAlloc(alloc, try reader.interface.takeInt(u16, .little)),
    };
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    alloc.free(self.path);
    self.* = undefined;
}
