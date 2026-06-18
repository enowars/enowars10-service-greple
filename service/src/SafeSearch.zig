const mvzr = @import("mvzr");
const std = @import("std");
const utils = @import("utils.zig");
const zap = @import("zap");

const Regex = mvzr.SizedRegex(38, 2);

enabled: bool,
regex: []const u8,

pub fn getFromCookie(alloc: std.mem.Allocator, req: *const zap.Request) !?@This() {
    var enabled = false;
    var regex: ?[]const u8 = null;
    defer if (regex) |r| alloc.free(r);

    if (try req.getCookieStr(alloc, "safe_search")) |c| {
        defer alloc.free(c);
        var it = std.mem.splitScalar(u8, c, '&');
        while (it.next()) |kv| {
            if (std.mem.indexOfScalarPos(u8, kv, 0, '=')) |s| {
                const k = kv[0..s];
                const v = kv[s + 1 ..];
                if (std.mem.eql(u8, k, "enabled")) {
                    if (enabled) return null;
                    enabled = true;
                } else if (std.mem.eql(u8, k, "regex")) {
                    if (regex) |_| return null;
                    regex = std.Uri.percentDecodeInPlace(try alloc.dupe(u8, v));
                } else {
                    return null;
                }
            }
        }
    }

    if (regex) |r| {
        defer regex = null;
        return .{
            .enabled = enabled,
            .regex = r,
        };
    }

    return null;
}

pub fn compile(self: *const @This()) ?Regex {
    return if (self.enabled) .compile(self.regex) else null;
}

pub fn put(self: *const @This(), alloc: std.mem.Allocator, req: *const zap.Request) !void {
    if (self.enabled and self.compile() == null) return error.InvalidOrTooComplexRegex;
    var value: std.Io.Writer.Allocating = .init(alloc);
    defer value.deinit();
    if (self.enabled) try value.writer.writeAll("enabled=on&");
    try value.writer.writeAll("regex=");
    try std.Uri.Component.percentEncode(&value.writer, self.regex, utils.cookieValidChar);
    try req.setCookie(.{ .name = "safe_search", .value = value.written(), .secure = false });
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    alloc.free(self.regex);
    self.* = undefined;
}
