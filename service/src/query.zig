const std = @import("std");

const seperators = struct {
    fn f(c: u8) []const u8 {
        const s = if (c < std.math.maxInt(u8)) f(c + 1) else "";
        return switch (c) {
            'a'...'z' => s,
            'A'...'Z' => s,
            '0'...'9' => s,
            '_' => s,
            else => .{c} ++ s,
        };
    }
}.f(0);

pub fn parse(alloc: std.mem.Allocator, q: []const u8) !?[]const u8 {
    var pattern: std.ArrayList(u8) = .empty;
    try pattern.appendSlice(alloc, "\\b");

    var first: bool = true;

    var it = std.mem.splitAny(u8, q, seperators);
    while (it.next()) |w| {
        if (w.len == 0) continue;

        if (first) {
            first = false;
        } else {
            try pattern.appendSlice(alloc, "\\W\\+");
        }
        try pattern.appendSlice(alloc, "\\(");
        try pattern.appendSlice(alloc, w);
        try pattern.appendSlice(alloc, "\\)");
    }

    if (first) return null;

    try pattern.appendSlice(alloc, "\\b");

    return try pattern.toOwnedSlice(alloc);
}
