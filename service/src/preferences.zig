const httpz = @import("httpz");
const std = @import("std");

pub const Preferences = struct {
    user: ?[]const u8 = null,
    safe_search_enabled: bool = false,
    safe_search_regex: []const u8 = "xxx",
};

pub fn parse(req: *const httpz.Request) !Preferences {
    var prefs: Preferences = .{};

    // TODO: verify password matches user
    if (req.cookies().get("preferences")) |c| {
        var it = std.mem.splitScalar(u8, c, '&');
        while (it.next()) |kv| {
            if (std.mem.indexOfScalarPos(u8, kv, 0, '=')) |s| {
                const key = std.Uri.percentDecodeInPlace(try req.arena.dupe(u8, kv[0..s]));
                const value = std.Uri.percentDecodeInPlace(try req.arena.dupe(u8, kv[s + 1 ..]));

                if (std.mem.eql(u8, key, "user")) {
                    prefs.user = value;
                } else if (std.mem.eql(u8, key, "safe_search_enabled")) {
                    prefs.safe_search_enabled = true;
                } else if (std.mem.eql(u8, key, "safe_search_regex")) {
                    prefs.safe_search_regex = value;
                }
            }
        }
    }

    return prefs;
}
