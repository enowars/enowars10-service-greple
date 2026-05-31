const mvzr = @import("mvzr");
const std = @import("std");
const User = @import("User.zig");
const utils = @import("utils.zig");

const re = mvzr.compile("([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z0-9][a-z0-9-]{0,61}[a-z0-9]").?;

hash: utils.Hash,
user_hash: utils.Hash,
domain: []const u8,
ipv4: u32,
port: u16,

fn openDir(args: std.fs.Dir.OpenOptions) !std.fs.Dir {
    return std.fs.cwd().openDir("domains", args);
}

fn parseIpv4(ipv4: []const u8) !u32 {
    return utils.ipv4ToInt(try std.net.Ip4Address.parse(ipv4, 1));
}

fn comptimeIpv4(comptime ipv4: []const u8) u32 {
    return parseIpv4(ipv4) catch @compileError("Invalid IPv4");
}

pub fn init(
    alloc: std.mem.Allocator,
    user: *const User,
    domain: []const u8,
    ipv4: []const u8,
    port: []const u8,
) !@This() {
    if (!utils.fullMatch(&re, domain)) return error.InvalidDomain;

    const i = parseIpv4(ipv4) catch return error.InvalidIpv4;
    const p = std.fmt.parseInt(u16, port, 10) catch return error.InvalidPort;

    switch (i) {
        comptimeIpv4("10.0.0.0")...comptimeIpv4("10.255.255.255"),
        comptimeIpv4("172.16.0.0")...comptimeIpv4("172.31.255.255"),
        comptimeIpv4("192.168.0.0")...comptimeIpv4("192.168.255.255"),
        => return error.InvalidIpv4,
        else => {},
    }

    switch (p) {
        // TODO: allow port 80
        // TODO: add other service ports
        7777 => {
            const body = utils.fetch(
                alloc,
                ipv4,
                7777,
                "/verify",
                "application/octet-stream",
            ) catch |err| {
                std.log.warn("IPv4 verification failed {s} {}", .{ ipv4, err });
                return error.Ipv4VerificationFailed;
            };
            defer alloc.free(body);
            if (!std.mem.eql(u8, body, &utils.ipv4VerificationToken(i))) return error.Ipv4VerificationFailed;
        },
        else => return error.InvalidPort,
    }

    return .{
        .hash = utils.hash(domain),
        .user_hash = user.hash,
        .domain = domain,
        .ipv4 = i,
        .port = p,
    };
}

pub fn formatIpv4(self: *const @This(), writer: *std.Io.Writer) !void {
    const bytes = std.mem.asBytes(&self.ipv4);
    try writer.print("{d}.{d}.{d}.{d}", .{ bytes[3], bytes[2], bytes[1], bytes[0] });
}

pub fn format(self: *const @This(), writer: *std.Io.Writer) !void {
    try formatIpv4(self, writer);
    try writer.print(":{d}", .{self.port});
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
    try writer.interface.writeInt(u32, self.ipv4, .little);
    try writer.interface.writeInt(u16, self.port, .little);
}

fn getFromDir(alloc: std.mem.Allocator, dir: std.fs.Dir, hash: utils.Hash) !@This() {
    var file = try dir.openFile(&std.fmt.bytesToHex(hash, .lower), .{});
    defer file.close();

    var buffer: [@max(@sizeOf(utils.Hash), @sizeOf(u16), @sizeOf(u32))]u8 = undefined;
    var reader = file.reader(&buffer);

    return .{
        .hash = hash,
        .user_hash = (try reader.interface.takeArray(@sizeOf(utils.Hash))).*,
        .domain = try reader.interface.readAlloc(alloc, try reader.interface.takeInt(u16, .little)),
        .ipv4 = try reader.interface.takeInt(u32, .little),
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

test "domain validation" {
    try std.testing.expect(utils.fullMatch(&re, "abc.com"));
    try std.testing.expect(utils.fullMatch(&re, "xyz.abc.com"));
}
