const mvzr = @import("mvzr");
const std = @import("std");
const User = @import("User.zig");
const utils = @import("utils.zig");

const re = mvzr.compile("([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z0-9][a-z0-9-]{0,61}[a-z0-9]").?;

hash: utils.Hash,
user_hash: utils.Hash,
domain: []const u8,
ipv4: [4]u8,
port: u16,

fn openDir(args: std.fs.Dir.OpenOptions) !std.fs.Dir {
    return std.fs.cwd().openDir("domains", args);
}

pub fn init(user: *const User, domain: []const u8, ipv4: []const u8, port: []const u8) !@This() {
    if (!re.isMatch(domain)) return error.InvalidDomain;

    const addr = std.net.Ip4Address.parse(ipv4, 1) catch return error.InvalidIpv4;

    const p = std.fmt.parseInt(u16, port, 10) catch return error.InvalidPort;
    if (p != 80) return error.InvalidPort; // TODO: extend port whitelist

    return .{
        .hash = utils.hash(domain),
        .user_hash = user.hash,
        .domain = domain,
        .ipv4 = std.mem.asBytes(&addr.sa.addr).*,
        .port = p,
    };
}

pub fn put(self: *const @This()) !void {
    if (self.domain.len > std.math.maxInt(u16)) return error.DomainTooLong;

    var dir = try openDir(.{});
    defer dir.close();

    var file = try dir.createFile(&std.fmt.bytesToHex(self.hash, .lower), .{ .exclusive = true });
    defer file.close();

    var writer = file.writer(&.{});

    try writer.interface.writeAll(&self.user_hash);
    try writer.interface.writeInt(u16, @truncate(self.domain.len), .little);
    try writer.interface.writeAll(self.domain);
    try writer.interface.writeAll(&self.ipv4);
    try writer.interface.writeInt(u16, self.port, .little);
}

fn getFromDir(alloc: std.mem.Allocator, dir: std.fs.Dir, hash: utils.Hash) !@This() {
    var file = try dir.openFile(&std.fmt.bytesToHex(hash, .lower), .{});
    defer file.close();

    var buffer: [@max(@sizeOf(utils.Hash), @sizeOf(u16), @sizeOf([4]u8))]u8 = undefined;
    var reader = file.reader(&buffer);

    return .{
        .hash = hash,
        .user_hash = (try reader.interface.takeArray(@sizeOf(utils.Hash))).*,
        .domain = try reader.interface.readAlloc(alloc, try reader.interface.takeInt(u16, .little)),
        .ipv4 = (try reader.interface.takeArray(4)).*,
        .port = try reader.interface.takeInt(u16, .little),
    };
}

pub fn get(alloc: std.mem.Allocator, hash: utils.Hash) !@This() {
    var dir = try openDir(.{});
    defer dir.close();
    return getFromDir(alloc, dir, hash);
}

pub fn getAllOwned(alloc: std.mem.Allocator, user: *const User) ![]const @This() {
    var dir = try openDir(.{ .iterate = true });
    defer dir.close();

    var domains: std.ArrayList(@This()) = .empty;
    defer domains.deinit(alloc);

    var it = dir.iterateAssumeFirstIteration();
    while (try it.next()) |e| {
        var domain = try getFromDir(alloc, dir, try utils.hexToBytes(@sizeOf(utils.Hash), e.name));
        if (!std.mem.eql(u8, &domain.user_hash, &user.hash)) {
            domain.deinit(alloc);
            continue;
        }
        try domains.append(alloc, domain);
    }

    return domains.toOwnedSlice(alloc);
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    alloc.free(self.domain);
    self.* = undefined;
}

test "domain name regex" {
    std.testing.expect(re.isMatch("abc.com"));
    std.testing.expect(!re.isMatch(" abc.com"));
}
