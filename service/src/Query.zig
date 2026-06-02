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

const re_prefix = "\\(^\\|[^a-zA-Z0-9]\\)";
const re_sep = "[^a-zA-Z0-9]\\+";
const re_suffix = "\\([^a-zA-Z0-9]\\|$\\)";

pattern: []const u8,
user_hash: ?utils.Hash,

pub fn init(alloc: std.mem.Allocator, q: []const u8) !?@This() {
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(alloc);

    var user_hash: ?utils.Hash = null;

    var first: bool = true;

    var it = std.mem.splitAny(u8, q, seperators);
    while (it.next()) |w| {
        if (w.len == 0) continue;

        if (user_hash == null and std.ascii.eqlIgnoreCase(w, "user") and q[it.index.? - 1] == ':') {
            if (it.peek()) |s| if (s.len > 0) {
                const username = it.next().?;
                user_hash = utils.hash(username);
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

    if (first and user_hash == null) return null;

    if (!first) try pattern.appendSlice(alloc, re_suffix);

    return .{
        .pattern = try pattern.toOwnedSlice(alloc),
        .user_hash = user_hash,
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
    try std.testing.expect(r.?.user_hash == null);
    try std.testing.expectEqualSlices(u8, r.?.pattern, re_prefix ++ "a" ++ re_sep ++ "b" ++ re_sep ++ "c" ++ re_sep ++ "d" ++ re_sep ++ "e" ++ re_sep ++ "f" ++ re_suffix);
}
