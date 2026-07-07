const mvzr = @import("mvzr");
const std = @import("std");
const utils = @import("utils.zig");

const path_re = mvzr.SizedRegex(16, 2).compile("(/([a-zA-Z0-9\\-._~]|%[0-9a-fA-F]{2})+)+/?|/").?;

host: []const u8,
port: u16,
path: []const u8,

pub const read_buffer_len = @sizeOf(u16);

pub fn init(alloc: std.mem.Allocator, url: []const u8, allow_path: bool) !@This() {
    const full_url = try std.mem.concat(alloc, u8, &.{ "http://", url });
    defer alloc.free(full_url);

    const uri = std.Uri.parse(full_url) catch return error.InvalidUrl;

    std.debug.assert(std.mem.eql(u8, uri.scheme, "http"));

    if (uri.user != null) return error.InvalidUrl;
    if (uri.password != null) return error.InvalidUrl;
    if (uri.query != null) return error.InvalidUrl;
    if (uri.fragment != null) return error.InvalidUrl;

    if (uri.host == null) return error.InvalidUrl;
    std.debug.assert(uri.host.? == .percent_encoded);
    const hs = uri.host.?.percent_encoded.ptr - full_url.ptr - "http://".len;
    const host = url[hs .. hs + uri.host.?.percent_encoded.len];

    std.debug.assert(uri.path == .percent_encoded);
    if (allow_path) {
        if (!utils.fullMatch(path_re, uri.path.percent_encoded)) return error.InvalidUrl;
    } else {
        if (uri.path.percent_encoded.len != 0) return error.InvalidUrl;
    }
    const ps = uri.path.percent_encoded.ptr - full_url.ptr - "http://".len;
    const path = url[ps .. ps + uri.path.percent_encoded.len];

    return .{
        .host = host,
        .port = uri.port orelse 80,
        .path = path,
    };
}

test init {
    {
        const url = try init(std.testing.allocator, "abc:123/xyz", true);
        try std.testing.expectEqualStrings("abc", url.host);
        try std.testing.expectEqual(123, url.port);
        try std.testing.expectEqualStrings("/xyz", url.path);
    }
    try std.testing.expectError(error.InvalidUrl, init(std.testing.allocator, "abc:123/xyz", false));
    try std.testing.expectError(error.InvalidUrl, init(std.testing.allocator, "abc:123/", false));
    {
        const url = try init(std.testing.allocator, "abc:123", false);
        try std.testing.expectEqualStrings("abc", url.host);
        try std.testing.expectEqual(123, url.port);
        try std.testing.expectEqualStrings("", url.path);
    }
}

pub fn toStdUri(self: *const @This()) std.Uri {
    return .{
        .scheme = "http",
        .host = .{ .percent_encoded = self.host },
        .port = if (self.port == 80) null else self.port,
        .path = .{ .percent_encoded = self.path },
    };
}

pub fn toOwned(self: *const @This(), alloc: std.mem.Allocator) !@This() {
    const host = try alloc.dupe(u8, self.host);
    errdefer alloc.free(host);
    const path = try alloc.dupe(u8, self.path);
    errdefer alloc.free(path);
    return .{ .host = host, .port = self.port, .path = path };
}

pub fn formatNetloc(self: *const @This(), writer: *std.Io.Writer) !void {
    if (self.port == 80) try writer.writeAll(self.host) else try writer.print("{s}:{d}", .{ self.host, self.port });
}

pub fn format(self: *const @This(), writer: *std.Io.Writer) !void {
    try writer.writeAll("http://");
    try self.formatNetloc(writer);
    try writer.writeAll(self.path);
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
    const host_hash = utils.hash(self.host);
    const port_hash = utils.hash(std.mem.asBytes(&std.mem.nativeToLittle(u16, self.port)));
    const path_hash = utils.hash(self.path);
    return utils.hash(&host_hash ++ &port_hash ++ &path_hash);
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
