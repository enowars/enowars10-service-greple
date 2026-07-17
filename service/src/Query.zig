const mvzr = @import("mvzr");
const std = @import("std");
const User = @import("User.zig");
const utils = @import("utils.zig");

fn reToSep(re: anytype) []const u8 {
    @setEvalBranchQuota(10_000);
    return struct {
        fn f(c: u8) []const u8 {
            return (if (utils.fullMatch(re, &.{c})) "" else .{c}) ++ (if (c < std.math.maxInt(u8)) f(c + 1) else "");
        }
    }.f(0);
}
const seperators = reToSep(mvzr.SizedRegex(1, 1).compile("\\w").?);
const user_seperators = reToSep(User.username_re);

const re_prefix = "\\(^\\|\\W\\)";
const re_sep = "\\W\\+";
const re_suffix = "\\(\\W\\|$\\)";

pattern: [:0]const u8,
user_hash: ?utils.Hash,

pub fn init(alloc: std.mem.Allocator, q: []const u8) !?@This() {
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(alloc);

    var user_hash: ?utils.Hash = null;

    var first: bool = true;

    var it = std.mem.splitAny(u8, q, seperators);
    while (it.next()) |w| {
        if (w.len == 0) continue;

        if (user_hash == null and std.ascii.eqlIgnoreCase(w, "user")) if (it.index) |i| if (q[i - 1] == ':') {
            it.delimiter = user_seperators;
            defer it.delimiter = seperators;
            if (it.peek()) |s| if (s.len > 0) {
                user_hash = utils.hash(it.next().?);
                continue;
            };
        };

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
        .pattern = try pattern.toOwnedSliceSentinel(alloc, 0),
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
    try std.testing.expectEqualSlices(u8, re_prefix ++ "a" ++ re_sep ++ "b" ++ re_sep ++ "c_d" ++ re_sep ++ "e" ++ re_sep ++ "f" ++ re_suffix, r.?.pattern);
}

test "user:" {
    var r = try init(std.testing.allocator, "abc user:1/-3+4 xyz");
    try std.testing.expect(r != null);
    defer r.?.deinit(std.testing.allocator);
    try std.testing.expect(r.?.user_hash != null);
    try std.testing.expectEqualSlices(u8, &utils.hash("1/-3+4"), &r.?.user_hash.?);
    try std.testing.expectEqualSlices(u8, re_prefix ++ "abc" ++ re_sep ++ "xyz" ++ re_suffix, r.?.pattern);
}
