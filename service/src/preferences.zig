const httpz = @import("httpz");
const std = @import("std");
const utils = @import("utils.zig");

const key = "change me";

pub const Preferences = struct {
    user_account_user: ?[]const u8 = null,
    safe_search_enabled: bool = false,
    safe_search_regex: []const u8 = "xxx",
};

const Hmac = std.crypto.auth.hmac.Hmac(utils.Hash);

pub fn parse(req: *const httpz.Request) !Preferences {
    var prefs: Preferences = .{};

    if (req.cookies().get("user_account")) |c| {
        var hmac_hex: ?[]const u8 = null;

        var it = std.mem.splitScalar(u8, c, '&');
        while (it.next()) |kv| {
            if (std.mem.indexOfScalarPos(u8, kv, 0, '=')) |s| {
                const k = kv[0..s];
                // TODO: is dupe required?
                const v = std.Uri.percentDecodeInPlace(try req.arena.dupe(u8, kv[s + 1 ..]));
                if (std.mem.eql(u8, k, "user")) {
                    prefs.user_account_user = v;
                } else if (std.mem.eql(u8, k, "hmac")) {
                    hmac_hex = v;
                }
            }
        }

        if (prefs.user_account_user) |u| {
            if (blk: {
                if (hmac_hex) |h| {
                    var hmac: [Hmac.mac_length]u8 = undefined;
                    Hmac.create(&hmac, u, key);
                    const expected = std.fmt.bytesToHex(&hmac, .lower);
                    break :blk !std.mem.eql(u8, h, &expected);
                }
                break :blk true;
            }) prefs.user_account_user = null;
        }
    }

    if (req.cookies().get("safe_search")) |c| {
        var it = std.mem.splitScalar(u8, c, '&');
        while (it.next()) |kv| {
            if (std.mem.indexOfScalarPos(u8, kv, 0, '=')) |s| {
                const k = kv[0..s];
                const v = std.Uri.percentDecodeInPlace(try req.arena.dupe(u8, kv[s + 1 ..]));

                if (std.mem.eql(u8, k, "enabled")) {
                    prefs.safe_search_enabled = true;
                } else if (std.mem.eql(u8, k, "regex")) {
                    prefs.safe_search_regex = v;
                }
            }
        }
    }

    return prefs;
}

fn checkUserPassword(user: []const u8, password: []const u8) !bool {
    var user_hash: [utils.Hash.digest_length]u8 = undefined;
    utils.Hash.hash(user, &user_hash, .{});
    const filename = std.fmt.bytesToHex(user_hash, .lower);

    var password_hash: [utils.Hash.digest_length]u8 = undefined;
    utils.Hash.hash(password, &password_hash, .{});

    var dir = try std.fs.cwd().openDir("users", .{});
    defer dir.close();
    var file = try dir.createFile(&filename, .{ .read = true, .truncate = false });
    defer file.close();

    var buffer: [utils.Hash.digest_length]u8 = undefined;
    var reader = file.reader(&buffer);
    const expected = reader.interface.take(utils.Hash.digest_length) catch |err| switch (err) {
        std.Io.Reader.Error.EndOfStream => {
            try file.writeAll(&password_hash);
            return true;
        },
        else => |leftover_err| return leftover_err,
    };

    return std.mem.eql(u8, &password_hash, expected);
}

pub fn login(user: []const u8, password: []const u8) ![Hmac.mac_length]u8 {
    std.debug.assert(user.len > 0);
    std.debug.assert(password.len > 0);

    if (!try checkUserPassword(user, password)) return error.InvalidCredentials;

    var hmac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&hmac, user, key);
    return hmac;
}
