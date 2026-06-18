const std = @import("std");
const Url = @import("Url.zig");
const utils = @import("utils.zig");

user_hash: utils.Hash,
host: []const u8,
port: u16,
api_key: []const u8,

pub fn fromUrl(user_hash: utils.Hash, url: *const Url, api_key: []const u8) !@This() {
    // TODO: disallow own port
    // if (url.port == utils.port) return error.InvalidHost;
    return .{
        .user_hash = user_hash,
        .host = url.host,
        .port = url.port,
        .api_key = api_key,
    };
}

pub fn init(alloc: std.mem.Allocator, user_hash: utils.Hash, netloc: []const u8, api_key: []const u8) !@This() {
    const url = Url.init(alloc, netloc, false) catch |err| switch (err) {
        error.InvalidUrl => return error.InvalidHost,
        else => |leftover_err| return leftover_err,
    };
    return try fromUrl(user_hash, &url, api_key);
}

fn openDir(args: std.fs.Dir.OpenOptions) !std.fs.Dir {
    return std.fs.cwd().openDir("netlocs", args);
}

pub fn put(self: *const @This()) !void {
    if (self.host.len > std.math.maxInt(u16)) return error.HostTooLong;
    if (self.api_key.len > std.math.maxInt(u16)) return error.APIKeyTooLong;

    var dir = try openDir(.{});
    defer dir.close();

    var file = try dir.createFile(&std.fmt.bytesToHex(self.hash(), .lower), .{});
    defer file.close();

    var writer = file.writer(&.{});

    try writer.interface.writeAll(&self.user_hash);
    try writer.interface.writeInt(u16, @truncate(self.host.len), .little);
    try writer.interface.writeAll(self.host);
    try writer.interface.writeInt(u16, self.port, .little);
    try writer.interface.writeInt(u16, @truncate(self.api_key.len), .little);
    try writer.interface.writeAll(self.api_key);
}

fn getFromDir(alloc: std.mem.Allocator, dir: std.fs.Dir, filename: []const u8) !@This() {
    const file = try dir.openFile(filename, .{});
    defer file.close();

    var buffer: [@max(@sizeOf(utils.Hash), @sizeOf(u16))]u8 = undefined;
    var reader = file.reader(&buffer);

    const user_hash = (try reader.interface.takeArray(@sizeOf(utils.Hash))).*;
    const host = try reader.interface.readAlloc(alloc, try reader.interface.takeInt(u16, .little));
    errdefer alloc.free(host);
    const port = try reader.interface.takeInt(u16, .little);
    const api_key = try reader.interface.readAlloc(alloc, try reader.interface.takeInt(u16, .little));
    errdefer alloc.free(api_key);

    return .{
        .user_hash = user_hash,
        .host = host,
        .port = port,
        .api_key = api_key,
    };
}

pub fn get(alloc: std.mem.Allocator, netloc_hash: utils.Hash) !@This() {
    var dir = try openDir(.{});
    defer dir.close();
    return getFromDir(alloc, dir, &std.fmt.bytesToHex(netloc_hash, .lower));
}

pub fn getByUserUrl(alloc: std.mem.Allocator, user_hash: utils.Hash, url: *const Url) !@This() {
    return get(alloc, (@This(){
        .user_hash = user_hash,
        .host = url.host,
        .port = url.port,
        .api_key = "",
    }).hash());
}

pub fn getByUser(alloc: std.mem.Allocator, user_hash: utils.Hash) ![]const @This() {
    var dir = try openDir(.{ .iterate = true });
    defer dir.close();

    var netlocs: std.ArrayList(@This()) = .empty;
    defer netlocs.deinit(alloc);

    var it = dir.iterateAssumeFirstIteration();
    while (try it.next()) |e| {
        var netloc = try getFromDir(alloc, dir, e.name);
        errdefer netloc.deinit(alloc);
        if (!std.mem.eql(u8, &user_hash, &netloc.user_hash)) {
            netloc.deinit(alloc);
            continue;
        }
        try netlocs.append(alloc, netloc);
    }

    return netlocs.toOwnedSlice(alloc);
}

pub fn format(self: *const @This(), writer: *std.Io.Writer) !void {
    try (Url{
        .host = self.host,
        .port = self.port,
        .path = "",
    }).formatNetloc(writer);
}

pub fn hash(self: *const @This()) utils.Hash {
    const host_hash = utils.hash(self.host);
    const port_hash = utils.hash(std.mem.asBytes(&std.mem.nativeToLittle(u16, self.port)));
    return utils.hash(&self.user_hash ++ &host_hash ++ &port_hash);
}

pub fn runCron(alloc: std.mem.Allocator, user_hash: utils.Hash) !void {
    var dir = try openDir(.{ .iterate = true });
    defer dir.close();

    var it = dir.iterateAssumeFirstIteration();
    while (try it.next()) |e| {
        var netloc = try getFromDir(alloc, dir, e.name);
        defer netloc.deinit(alloc);
        if (std.mem.eql(u8, &user_hash, &netloc.user_hash)) try dir.deleteFile(e.name);
    }
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    alloc.free(self.host);
    alloc.free(self.api_key);
    self.* = undefined;
}
