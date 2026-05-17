const httpz = @import("httpz");
const std = @import("std");

enabled: bool = false,
regex: []const u8 = "xxx",

pub fn parse(req: *const httpz.Request) !@This() {
    var safe_search: @This() = .{};

    if (req.cookies().get("safe_search")) |c| {
        var it = std.mem.splitScalar(u8, c, '&');
        while (it.next()) |kv| {
            if (std.mem.indexOfScalarPos(u8, kv, 0, '=')) |s| {
                const k = kv[0..s];
                const v = std.Uri.percentDecodeInPlace(try req.arena.dupe(u8, kv[s + 1 ..]));

                if (std.mem.eql(u8, k, "enabled")) {
                    safe_search.enabled = true;
                } else if (std.mem.eql(u8, k, "regex")) {
                    safe_search.regex = v;
                }
            }
        }
    }

    return safe_search;
}
