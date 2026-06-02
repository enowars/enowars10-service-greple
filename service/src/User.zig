const httpz = @import("httpz");
const mvzr = @import("mvzr");
const std = @import("std");
const utils = @import("utils.zig");

const re = mvzr.compile("[a-zA-Z0-9]+").?;

hash: utils.Hash,
username: []const u8,
hmac: utils.Hmac,

pub fn parse(req: *const httpz.Request) !?@This() {
    var username: ?[]const u8 = null;
    var hmac: ?utils.Hmac = null;

    if (req.cookies().get("user_account")) |c| {
        var it = std.mem.splitScalar(u8, c, '&');
        while (it.next()) |kv| {
            if (std.mem.indexOfScalarPos(u8, kv, 0, '=')) |s| {
                const k = kv[0..s];
                // TODO: is dupe required?
                const v = std.Uri.percentDecodeInPlace(try req.arena.dupe(u8, kv[s + 1 ..]));
                if (std.mem.eql(u8, k, "username")) {
                    username = v;
                } else if (std.mem.eql(u8, k, "hmac")) {
                    hmac = utils.hexToBytes(@sizeOf(utils.Hmac), v) catch null;
                }
            }
        }
    }

    if (username) |u| if (hmac) |h| {
        if (std.mem.eql(u8, &h, &utils.hmac(u))) return .{
            .hash = utils.hash(u),
            .username = u,
            .hmac = h,
        };
    };

    return null;
}

fn checkUserPassword(user: utils.Hash, password_hash: utils.Hash) !bool {
    var dir = try std.fs.cwd().openDir("users", .{});
    defer dir.close();

    var file = try dir.createFile(&std.fmt.bytesToHex(user, .lower), .{ .read = true, .truncate = false });
    defer file.close();

    var buffer: [@sizeOf(utils.Hash)]u8 = undefined;
    var reader = file.reader(&buffer);

    const hash = reader.interface.take(@sizeOf(utils.Hash)) catch |err| switch (err) {
        std.Io.Reader.Error.EndOfStream => {
            try file.writeAll(&password_hash);
            return true;
        },
        else => |leftover_err| return leftover_err,
    };

    return std.mem.eql(u8, &password_hash, hash);
}

pub fn login(username: []const u8, password: []const u8) !@This() {
    if (!utils.fullMatch(&re, username)) return error.InvalidUsername;
    if (password.len == 0) return error.InvalidPassword;

    const user_hash = utils.hash(username);
    const password_hash = utils.hash(password);

    if (!try checkUserPassword(user_hash, password_hash)) return error.InvalidCredentials;

    return .{
        .hash = user_hash,
        .username = username,
        .hmac = utils.hmac(username),
    };
}
