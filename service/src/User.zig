const Document = @import("Document.zig");
const IndexEntry = @import("IndexEntry.zig");
const mvzr = @import("mvzr");
const Netloc = @import("Netloc.zig");
const std = @import("std");
const utils = @import("utils.zig");
const zap = @import("zap");

pub const username_re = mvzr.SizedRegex(2, 1).compile("[\\w+-=]+").?;

username: []const u8,
password_hash: ?utils.Hash,

fn openDir(args: std.fs.Dir.OpenOptions) !std.fs.Dir {
    return std.fs.cwd().openDir("users", args);
}

pub fn put(self: *const @This()) !void {
    std.debug.assert(self.password_hash != null);
    if (self.username.len > std.math.maxInt(u16)) return error.UsernameTooLong;

    var dir = try openDir(.{});
    defer dir.close();

    var writer: utils.Writer = try .open(dir, &std.fmt.bytesToHex(self.hash(), .lower));
    defer writer.close();
    try writer.interface().writeInt(u16, @truncate(self.username.len), .little);
    try writer.interface().writeAll(self.username);
    try writer.interface().writeAll(&self.password_hash.?);
    try writer.end();
}

pub fn get(alloc: std.mem.Allocator, user_hash: utils.Hash) !@This() {
    var dir = try openDir(.{});
    defer dir.close();

    const file = try dir.openFile(&std.fmt.bytesToHex(user_hash, .lower), .{});
    defer file.close();

    var buffer: [@max(@sizeOf(u16), @sizeOf(utils.Hash))]u8 = undefined;
    var reader = file.reader(&buffer);

    const username = try reader.interface.readAlloc(alloc, try reader.interface.takeInt(u16, .little));
    errdefer alloc.free(username);
    const password_hash = (try reader.interface.takeArray(@sizeOf(utils.Hash))).*;

    return .{
        .username = username,
        .password_hash = password_hash,
    };
}

pub fn getFromCookie(alloc: std.mem.Allocator, req: *const zap.Request) !?@This() {
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
                    if (username) |_| return error.InvalidUserAccountCookie;
                    username = std.Uri.percentDecodeInPlace(try alloc.dupe(u8, v));
                } else if (std.mem.eql(u8, k, "hmac")) {
                    if (hmac) |_| return error.InvalidUserAccountCookie;
                    hmac = utils.hexToBytes(@sizeOf(utils.Hmac), v) catch return error.InvalidUserAccountCookie;
                } else {
                    return error.InvalidUserAccountCookie;
                }
            }
        }
    } else return null;

    if (username) |u| if (hmac) |h| {
        if (std.mem.eql(u8, &h, &utils.hmac(u))) {
            defer username = null;
            return .{
                .username = u,
                .password_hash = null,
            };
        }
    };

    return error.InvalidUserAccountCookie;
}

fn setCookie(self: *const @This(), alloc: std.mem.Allocator, req: *const zap.Request) !void {
    var value: std.Io.Writer.Allocating = .init(alloc);
    defer value.deinit();
    try value.writer.writeAll("username=");
    try std.Uri.Component.percentEncode(&value.writer, self.username, utils.cookieValidChar);
    try value.writer.writeAll("&hmac=");
    try value.writer.printHex(&utils.hmac(self.username), .lower);
    try req.setCookie(.{ .name = "user_account", .value = value.written(), .secure = false });
}

pub fn eql(a: *const @This(), b: *const @This()) bool {
    std.debug.assert(a != b);
    if (!std.mem.eql(u8, a.username, b.username)) return false;
    if (a.password_hash) |aph| if (b.password_hash) |bph| return std.mem.eql(u8, &aph, &bph);
    return true;
}

pub fn login(alloc: std.mem.Allocator, req: *const zap.Request, username: []const u8, password: []const u8) !void {
    const provided_user: @This() = .{
        .username = username,
        .password_hash = utils.hash(password),
    };

    var user = get(alloc, provided_user.hash()) catch |err| switch (err) {
        std.fs.File.OpenError.FileNotFound => {
            if (!utils.fullMatch(username_re, username)) return error.InvalidUsername;
            if (password.len == 0) return error.InvalidPassword;
            try provided_user.put();
            try provided_user.setCookie(alloc, req);
            return;
        },
        else => |leftover_err| return leftover_err,
    };
    defer user.deinit(alloc);

    if (!eql(&provided_user, &user)) return error.InvalidCredentials;

    try user.setCookie(alloc, req);
}

pub fn hash(self: *const @This()) utils.Hash {
    return utils.hash(self.username);
}

fn bumpMtime(dir: std.fs.Dir, name: []const u8, threshold: i128) !void {
    const file = try dir.openFile(name, .{});
    defer file.close();
    try file.updateTimes(std.time.nanoTimestamp(), threshold + std.time.ns_per_s * 30);
}

pub fn runCron(alloc: std.mem.Allocator, threshold: i128) !void {
    var dir = try openDir(.{ .iterate = true });
    defer dir.close();

    var stale: utils.HashMap(utils.CronState) = .init(alloc);
    defer stale.deinit();

    {
        var it = dir.iterateAssumeFirstIteration();
        while (try it.next()) |e| {
            if (e.name[0] == '.') continue;
            const stat = try dir.statFile(e.name);
            if (stat.mtime > threshold) continue;
            const user_hash = try utils.hexToBytes(@sizeOf(utils.Hash), e.name);
            try stale.put(user_hash, .{});
        }
    }

    {
        var it = stale.iterator();
        while (it.next()) |entry| {
            const user_hash_hex = std.fmt.bytesToHex(entry.key_ptr.*, .lower);
            if (try Document.runCron(&user_hash_hex)) entry.value_ptr.had_documents = true;
        }
    }

    try IndexEntry.runCronSweep(alloc, &stale);
    try Netloc.runCronSweep(alloc, &stale);

    {
        var it = stale.iterator();
        while (it.next()) |entry| {
            const user_hash_hex = std.fmt.bytesToHex(entry.key_ptr.*, .lower);
            if (entry.value_ptr.had_documents or entry.value_ptr.had_index_entries_or_netlocs) {
                try bumpMtime(dir, &user_hash_hex, threshold);
            } else {
                try dir.deleteFile(&user_hash_hex);
            }
        }
    }
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    alloc.free(self.username);
    self.* = undefined;
}
