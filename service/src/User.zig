const mvzr = @import("mvzr");
const std = @import("std");
const utils = @import("utils.zig");
const zap = @import("zap");

const re = mvzr.compile("[a-zA-Z0-9]+").?;

hash: utils.Hash,
username: []const u8,
hmac: utils.Hmac,

pub fn parse(alloc: std.mem.Allocator, req: *const zap.Request) !?@This() {
    var username: ?[]const u8 = null;
    defer if (username) |u| alloc.free(u);
    var hmac: ?utils.Hmac = null;

    if (try req.getCookieStr(alloc, "user_account")) |c| {
        defer alloc.free(c);
        var it = std.mem.splitScalar(u8, c, '&');
        while (it.next()) |kv| {
            if (std.mem.indexOfScalarPos(u8, kv, 0, '=')) |s| {
                const k = kv[0..s];
                const v = kv[s + 1 ..];
                if (std.mem.eql(u8, k, "username")) {
                    if (username) |_| return null;
                    username = try alloc.dupe(u8, v);
                } else if (std.mem.eql(u8, k, "hmac")) {
                    if (hmac) |_| return null;
                    hmac = utils.hexToBytes(@sizeOf(utils.Hmac), v) catch null;
                } else {
                    return null;
                }
            }
        }
    }

    if (username) |u| if (hmac) |h| {
        if (std.mem.eql(u8, &h, &utils.hmac(u))) {
            defer username = null;
            return .{
                .hash = utils.hash(u),
                .username = u,
                .hmac = h,
            };
        }
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

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    alloc.free(self.username);
    self.* = undefined;
}
