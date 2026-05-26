const Domain = @import("domain.zig");
const std = @import("std");
const utils = @import("utils.zig");

const seperators = struct {
    fn f(c: u8) []const u8 {
        return switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9' => .{},
            else => .{c},
        } ++ if (c < std.math.maxInt(u8)) f(c + 1) else "";
    }
}.f(0);
const site_seperators = struct {
    fn f(c: u8) []const u8 {
        return switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '.' => .{},
            else => .{c},
        } ++ if (c < std.math.maxInt(u8)) f(c + 1) else "";
    }
}.f(0);

const re_prefix = "\\(^\\|[^a-zA-Z0-9]\\)";
const re_sep = "[^a-zA-Z0-9]\\+";
const re_suffix = "\\([^a-zA-Z0-9]\\|$\\)";

pattern: []const u8,
domain: ?Domain,

pub fn init(alloc: std.mem.Allocator, q: []const u8) !?@This() {
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(alloc);

    var domain: ?Domain = null;

    var first: bool = true;

    var it = std.mem.splitAny(u8, q, seperators);
    while (it.next()) |w| {
        if (w.len == 0) continue;

        if (domain == null and std.ascii.eqlIgnoreCase(w, "site") and q[it.index.? - 1] == ':') {
            it.delimiter = site_seperators;
            defer it.delimiter = seperators;
            if (it.peek()) |s| if (s.len > 0) {
                // TODO: handle url not found
                domain = Domain.get(alloc, utils.hash(it.next().?)) catch |err| switch (err) {
                    std.fs.File.OpenError.FileNotFound => return null,
                    else => |leftover_err| return leftover_err,
                };
                continue;
            };
        }

        if (first) {
            try pattern.appendSlice(alloc, re_prefix);
            first = false;
        } else {
            try pattern.appendSlice(alloc, re_sep);
        }
        try pattern.appendSlice(alloc, w);
    }

    if (first and domain == null) return null;

    if (!first) try pattern.appendSlice(alloc, re_suffix);

    return .{
        .pattern = try pattern.toOwnedSlice(alloc),
        .domain = domain,
    };
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    alloc.free(self.pattern);
    self.* = undefined;
}

test "word separation" {
    var r = try init(std.testing.allocator, "a-b.c_d*e  f");
    try std.testing.expect(r != null);
    defer r.?.deinit(std.testing.allocator);
    try std.testing.expect(r.?.site == null);
    try std.testing.expectEqualSlices(u8, r.?.pattern, re_prefix ++ "a" ++ re_sep ++ "b" ++ re_sep ++ "c" ++ re_sep ++ "d" ++ re_sep ++ "e" ++ re_sep ++ "f" ++ re_suffix);
}

test "site: parameter parsing" {
    var r = try init(std.testing.allocator, "SiTe:a-b.abc.com a");
    try std.testing.expect(r != null);
    defer r.?.deinit(std.testing.allocator);
    try std.testing.expect(r.?.site != null);
    try std.testing.expectEqualSlices(u8, r.?.site.?, "a-b.abc.com");
}
