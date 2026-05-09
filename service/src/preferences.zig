const httpz = @import("httpz");
const std = @import("std");

pub const user_nobody = "nobody";
pub const user_anybody = "anybody";

pub const Preferences = struct {
    user: []const u8 = user_nobody,
    safe_search_enabled: bool = false,
    safe_search_regex: []const u8 = "xxx",

    pub fn canRead(self: *const @This(), user: []const u8) bool {
        if (std.mem.eql(u8, user, user_anybody)) return true;
        if (std.mem.eql(u8, user, user_nobody)) return false;
        return std.mem.eql(u8, user, self.user);
    }
};

pub fn parse(req: *const httpz.Request) !Preferences {
    var prefs: Preferences = .{};
    var password: []const u8 = "";

    if (req.cookies().get("preferences")) |c| {
        var it = std.mem.splitScalar(u8, c, '&');
        while (it.next()) |kv| {
            if (std.mem.indexOfScalarPos(u8, kv, 0, '=')) |s| {
                var dupe = try req.arena.dupe(u8, kv);
                for (dupe) |*x| if (x.* == '+') {
                    x.* = ' ';
                };
                const key = std.Uri.percentDecodeInPlace(dupe[0..s]);
                const value = std.Uri.percentDecodeInPlace(dupe[s + 1 ..]);

                if (std.mem.eql(u8, key, "user")) {
                    prefs.user = value;
                } else if (std.mem.eql(u8, key, "password")) {
                    password = value;
                } else if (std.mem.eql(u8, key, "safe_search_enabled")) {
                    prefs.safe_search_enabled = true;
                } else if (std.mem.eql(u8, key, "safe_search_regex")) {
                    prefs.safe_search_regex = value;
                }
            }
        }
    }

    if (!blk: {
        if (std.mem.eql(u8, prefs.user, user_anybody)) break :blk false;
        if (std.mem.eql(u8, prefs.user, user_nobody)) break :blk false;
        if (password.len == 0) break :blk false;

        var hash: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(prefs.user, &hash, .{});
        const sha1 = std.fmt.bytesToHex(hash, .lower);

        var dir = try std.fs.cwd().openDir("users", .{});
        defer dir.close();

        var file = try dir.createFile(&sha1, .{ .read = true, .truncate = false });
        defer file.close();

        const size = (try file.stat()).size;
        if (size == 0) {
            try file.writeAll(password);
            break :blk true;
        }
        if (size != password.len) break :blk false;

        var reader = file.reader(&.{});
        const expected = try reader.interface.readAlloc(req.arena, size);
        break :blk std.mem.eql(u8, password, expected);
    }) prefs.user = user_nobody;

    return prefs;
}
