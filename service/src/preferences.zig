const httpz = @import("httpz");
const std = @import("std");
const utils = @import("utils.zig");

const key = "change me";

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

const Hmac = std.crypto.auth.hmac.sha2.HmacSha224;

pub fn parse(req: *const httpz.Request) !Preferences {
    var prefs: Preferences = .{};

    if (req.cookies().get("user")) |u| if (req.cookies().get("hmac")) |h| {
        var hmac_bytes: [Hmac.mac_length]u8 = undefined;
        Hmac.create(&hmac_bytes, u, key);
        const hmac = std.fmt.bytesToHex(&hmac_bytes, .lower);
        if (std.mem.eql(u8, h, &hmac)) prefs.user = u;
    };

    if (req.cookies().get("preferences")) |c| {
        var it = std.mem.splitScalar(u8, c, '&');
        while (it.next()) |kv| {
            if (std.mem.indexOfScalarPos(u8, kv, 0, '=')) |s| {
                var d = try req.arena.dupe(u8, kv);
                const k = std.Uri.percentDecodeInPlace(d[0..s]);
                const v = std.Uri.percentDecodeInPlace(d[s + 1 ..]);

                if (std.mem.eql(u8, k, "safe_search_enabled")) {
                    prefs.safe_search_enabled = true;
                } else if (std.mem.eql(u8, k, "safe_search_regex")) {
                    prefs.safe_search_regex = v;
                }
            }
        }
    }

    return prefs;
}

pub fn login(user: []const u8, password: []const u8, res: *httpz.Response) !void {
    std.debug.assert(password.len > 0);
    if (std.mem.eql(u8, user, user_anybody)) return error.InvalidCredentials;
    if (std.mem.eql(u8, user, user_nobody)) return error.InvalidCredentials;

    var hash_bytes: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(user, &hash_bytes, .{});
    const hash = std.fmt.bytesToHex(hash_bytes, .lower);

    var dir = try std.fs.cwd().openDir("users", .{});
    defer dir.close();

    var file = try dir.createFile(&hash, .{ .read = true, .truncate = false });
    defer file.close();

    const size = (try file.stat()).size;
    if (size == 0) {
        try file.writeAll(password);
    } else {
        if (size != password.len) return error.InvalidCredentials;

        var reader = file.reader(&.{});
        const expected = try reader.interface.readAlloc(res.arena, size);
        defer res.arena.free(expected);

        if (!std.mem.eql(u8, password, expected)) return error.InvalidCredentials;
    }

    var user_cookie: std.Io.Writer.Allocating = .init(res.arena);
    defer user_cookie.deinit();

    try user_cookie.writer.writeAll("user=");
    try std.Uri.Component.percentEncode(&user_cookie.writer, user, utils.cookieValidChar);

    res.headers.add("Set-Cookie", try user_cookie.toOwnedSlice());

    var hmac_bytes: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&hmac_bytes, user, key);
    const hmac = std.fmt.bytesToHex(hmac_bytes, .lower);

    const hmac_cookie = try std.mem.concat(res.arena, u8, &.{ "hmac=", &hmac });
    errdefer res.arena.free(hmac_cookie);

    res.headers.add("Set-Cookie", hmac_cookie);
}
