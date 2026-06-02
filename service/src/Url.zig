const mvzr = @import("mvzr");
const std = @import("std");
const utils = @import("utils.zig");

const path_re = mvzr.compile("(/([a-zA-Z0-9\\-._~]|%[0-9a-fA-F]{2})+)+/?|/").?;

host: []const u8,
port: u16,
path: []const u8,

pub const read_buffer_len = @sizeOf(u16);

pub fn init(url: []const u8) !@This() {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;

    std.debug.assert(std.mem.eql(u8, uri.scheme, "http"));

    if (uri.user != null) return error.InvalidUrl;
    if (uri.password != null) return error.InvalidUrl;
    if (uri.query != null) return error.InvalidUrl;
    if (uri.fragment != null) return error.InvalidUrl;

    if (uri.host == null) return error.InvalidUrl;
    std.debug.assert(uri.host.? == .percent_encoded);

    std.debug.assert(uri.path == .percent_encoded);
    if (!utils.fullMatch(&path_re, uri.path.percent_encoded)) return error.InvalidUrl;

    return .{
        .host = uri.host.?.percent_encoded,
        .port = uri.port orelse 80,
        .path = uri.path.percent_encoded,
    };
}

pub fn toStdUri(self: *const @This()) std.Uri {
    return .{
        .scheme = "http",
        .host = .{ .percent_encoded = self.host },
        .port = self.port,
        .path = .{ .percent_encoded = self.path },
    };
}

pub fn format(self: *const @This(), writer: *std.Io.Writer) !void {
    if (self.port == 80) {
        try writer.print("http://{s}{s}", .{ self.host, self.path });
    } else {
        try writer.print("http://{s}:{d}{s}", .{ self.host, self.port, self.path });
    }
}

pub fn write(self: *const @This(), writer: *std.Io.Writer) !void {
    if (self.host.len > std.math.maxInt(u16)) return error.HostTooLong;
    if (self.path.len > std.math.maxInt(u16)) return error.PathTooLong;

    try writer.writeInt(u16, @truncate(self.host.len), .little);
    try writer.writeAll(self.host);
    try writer.writeInt(u16, self.port, .little);
    try writer.writeInt(u16, @truncate(self.path.len), .little);
    try writer.writeAll(self.path);
}

pub fn read(alloc: std.mem.Allocator, reader: *std.Io.Reader) !@This() {
    return .{
        .host = try reader.readAlloc(alloc, try reader.takeInt(u16, .little)),
        .port = try reader.takeInt(u16, .little),
        .path = try reader.readAlloc(alloc, try reader.takeInt(u16, .little)),
    };
}

pub fn hash(self: *const @This()) utils.Hash {
    return utils.hash(&(utils.hash(self.host) ++ utils.hash(std.mem.asBytes(&self.port)) ++ utils.hash(self.path)));
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    alloc.free(self.host);
    alloc.free(self.path);
    self.* = undefined;
}

test "path validation" {
    try std.testing.expect(utils.fullMatch(&path_re, "/"));
    try std.testing.expect(utils.fullMatch(&path_re, "/abc"));
    try std.testing.expect(utils.fullMatch(&path_re, "/abc/"));
    try std.testing.expect(!utils.fullMatch(&path_re, "/ "));
    try std.testing.expect(utils.fullMatch(&path_re, "/%20"));
}
