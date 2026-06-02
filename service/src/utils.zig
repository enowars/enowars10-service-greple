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
    return hash(&(a ++ b));
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

fn setTimeout(fd: std.posix.fd_t, level: i32, optname: u32) !void {
    try std.posix.setsockopt(fd, level, optname, std.mem.asBytes(&std.posix.timeval{ .sec = 0, .usec = 1e5 }));
}

fn connect(addr: std.net.Address) !std.net.Stream {
    const fd = try std.posix.socket(
        addr.any.family,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        std.posix.IPPROTO.TCP,
    );
    errdefer std.net.Stream.close(.{ .handle = fd });

    try setTimeout(fd, std.posix.IPPROTO.TCP, std.posix.TCP.USER_TIMEOUT);
    try setTimeout(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO);
    try setTimeout(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO);

    try std.posix.connect(fd, &addr.any, addr.getOsSockLen());

    return .{ .handle = fd };
}

pub fn formatIpv4(ipv4: u32, writer: *std.Io.Writer) !void {
    const bytes = std.mem.asBytes(&ipv4);
    try writer.print("{d}.{d}.{d}.{d}", .{ bytes[3], bytes[2], bytes[1], bytes[0] });
}

pub fn fetch(
    alloc: std.mem.Allocator,
    ipv4: u32,
    port: u16,
    path: []const u8,
    content_type: []const u8,
) ![]const u8 {
    const stream = try connect(.{
        .in = .{ .sa = .{ .addr = @byteSwap(ipv4), .port = @byteSwap(port) } },
    });
    defer stream.close();

    const read_buffer = try alloc.alloc(u8, (std.http.Client{ .allocator = undefined }).read_buffer_size);
    defer alloc.free(read_buffer);

    const write_buffer = try alloc.alloc(u8, (std.http.Client{ .allocator = undefined }).write_buffer_size);
    defer alloc.free(write_buffer);

    var connection: std.http.Client.Connection = .{
        .client = undefined,
        .stream_writer = stream.writer(write_buffer),
        .stream_reader = stream.reader(read_buffer),
        .pool_node = .{},
        .port = port,
        .host_len = 0,
        .proxied = false,
        .closing = false,
        .protocol = .plain,
    };

    var host: std.Io.Writer.Allocating = .init(alloc);
    defer host.deinit();
    try formatIpv4(ipv4, &host.writer);

    var request: std.http.Client.Request = .{
        .uri = .{
            .scheme = "http",
            .host = .{ .percent_encoded = host.written() },
            .port = port,
            .path = .{ .percent_encoded = path },
        },
        .client = undefined,
        .connection = &connection,
        .reader = .{
            .in = connection.reader(),
            .state = .ready,
            .interface = undefined,
            .max_head_len = read_buffer.len,
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
    try request.sendBodiless();

    var response = try request.receiveHead(&.{});
    if (response.head.status != .ok) return error.HttpStatusNotOk;
    if (response.head.content_type) |c| {
        if (!std.mem.startsWith(u8, c, content_type)) return error.InvalidContentType;
    } else return error.InvalidContentType;

    var reader = response.reader(&.{});
    return reader.allocRemaining(alloc, .unlimited);
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
