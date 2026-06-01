const mvzr = @import("mvzr");
const std = @import("std");

const key = "change me"; // TODO: change secret
const HashFn = std.crypto.hash.sha2.Sha224;
const HmacFn = std.crypto.auth.hmac.Hmac(HashFn);
pub const Hash = [HashFn.digest_length]u8;
pub const Hmac = [HmacFn.mac_length]u8;

pub fn hash(data: []const u8) Hash {
    var h: Hash = undefined;
    HashFn.hash(data, &h, .{});
    return h;
}

pub fn combineHashes(a: Hash, b: Hash) Hash {
    return (a[0 .. @sizeOf(Hash) / 2] ++ b[@sizeOf(Hash) / 2 ..]).*;
}

pub fn hmac(data: []const u8) Hmac {
    var h: Hmac = undefined;
    HmacFn.create(&h, data, key);
    return h;
}

pub fn hexToBytes(n: comptime_int, data: []const u8) ![n]u8 {
    if (data.len != n * 2) return error.InvalidLength;
    var bytes: [n]u8 = undefined;
    for (0..n) |i| bytes[i] = try std.fmt.parseInt(u8, data[i * 2 .. i * 2 + 2], 16);
    return bytes;
}

pub fn cookieValidChar(char: u8) bool {
    return switch (char) {
        0...31 => false,
        ' ' => false,
        '"' => false,
        ',' => false,
        ';' => false,
        '\\' => false,
        127...std.math.maxInt(u8) => false,
        else => true,
    };
}

pub fn fullMatch(re: *const mvzr.Regex, s: []const u8) bool {
    const m = re.matchPos(0, s) orelse return false;
    return m.end == s.len;
}

pub fn fetch(
    alloc: std.mem.Allocator,
    ipv4: []const u8,
    port: u16,
    path: []const u8,
    content_type: []const u8,
) ![]const u8 {
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();

    const connection = try client.connectTcp(ipv4, port, .plain);

    var request: std.http.Client.Request = .{
        .uri = .{
            .scheme = "http",
            .host = .{ .percent_encoded = ipv4 },
            .port = port,
            .path = .{ .percent_encoded = path },
        },
        .client = &client,
        .connection = connection,
        .reader = .{
            .in = connection.reader(),
            .state = .ready,
            .interface = undefined,
            .max_head_len = client.read_buffer_size,
        },
        .keep_alive = false,
        .method = .GET,
        .transfer_encoding = .none,
        .redirect_behavior = .not_allowed,
        .handle_continue = true,
        .headers = .{},
        .extra_headers = &.{},
        .privileged_headers = &.{},
    };
    defer request.deinit();
    try request.sendBodiless();

    var response = try request.receiveHead(&.{});
    if (response.head.status != .ok) return error.HttpStatusNotOk;
    if (response.head.content_type) |c| {
        if (!std.mem.startsWith(u8, c, content_type)) return error.InvalidContentType;
    } else return error.InvalidContentType;

    var reader = response.reader(&.{});
    return reader.allocRemaining(alloc, .unlimited);
}

pub fn ipv4ToInt(ipv4: std.net.Ip4Address) u32 {
    return @byteSwap(ipv4.sa.addr);
}

pub fn ipv4VerificationToken(ipv4: u32) Hmac {
    return hmac(std.mem.asBytes(&ipv4));
}

pub fn setNice(nice: u32) void {
    _ = std.os.linux.sched_setattr(0, &.{
        .policy = @intFromEnum(std.os.linux.SCHED.Mode.NORMAL),
        .nice = nice,
    }, 0);
}

test "fullMatch" {
    const re = mvzr.compile("a").?;
    try std.testing.expect(fullMatch(&re, "a"));
    try std.testing.expect(!fullMatch(&re, "ab"));
}
