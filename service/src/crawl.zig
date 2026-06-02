const Document = @import("Document.zig");
const IndexEntry = @import("IndexEntry.zig");
const mvzr = @import("mvzr");
const std = @import("std");
const Url = @import("Url.zig");
const User = @import("User.zig");

const title_re = mvzr.compile("<title>.*?</title>").?;
const p_re = mvzr.compile("<p>.*?</p>").?;

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

fn bytesToU32(bytes: [4]u8) u32 {
    return std.mem.readInt(u32, &bytes, .big);
}

fn fetch(
    alloc: std.mem.Allocator,
    url: *const Url,
    content_type: []const u8,
) ![]const u8 {
    const addr = blk: {
        const list = std.net.getAddressList(alloc, url.host, url.port) catch return error.DnsResolutionFailed;
        defer list.deinit();
        for (list.addrs) |a| {
            if (a.any.family != std.posix.AF.INET) continue;
            switch (@as(u8, @truncate(std.mem.bigToNative(u32, a.in.sa.addr)))) {
                0, 255 => continue,
                else => {},
            }
            switch (std.mem.bigToNative(u32, a.in.sa.addr)) {
                bytesToU32(.{ 10, 0, 0, 0 })...bytesToU32(.{ 10, 255, 255, 255 }),
                bytesToU32(.{ 91, 99, 0, 0 })...bytesToU32(.{ 91, 99, 255, 255 }), // TODO: remove CICD
                bytesToU32(.{ 172, 18, 0, 1 }), // TODO: remove local testing
                => {},
                else => continue,
            }
            switch (a.in.getPort()) {
                7777 => {},
                else => continue,
            }
            break :blk a;
        }
        return error.DnsResolutionFailed;
    };

    const stream = try connect(addr);
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
        .port = url.port,
        .host_len = 0,
        .proxied = false,
        .closing = false,
        .protocol = .plain,
    };

    var request: std.http.Client.Request = .{
        .uri = url.toStdUri(),
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

pub fn crawl(
    alloc: std.mem.Allocator,
    user: *const User,
    public: bool,
    url: []const u8,
) !struct { IndexEntry, Document } {
    const u: Url = try .init(url);

    const body = fetch(alloc, &u, "text/html") catch |err| {
        std.log.info("Indexing failed {s} {}", .{ url, err });
        return error.IndexingFailed;
    };
    defer alloc.free(body);

    const title = title_re.match(body) orelse return error.IndexingFailed;
    std.debug.assert(title.slice.len >= "<title></title>".len);
    const d_title = try alloc.dupe(u8, title.slice["<title>".len .. title.slice.len - "</title>".len]);
    errdefer alloc.free(d_title);

    var text: std.ArrayList([]const u8) = .empty;
    defer {
        for (text.items) |l| alloc.free(l);
        text.deinit(alloc);
    }
    var it = p_re.iterator(body);
    while (it.next()) |p| {
        std.debug.assert(p.slice.len >= "<p></p>".len);
        if (p.slice.len == "<p></p>".len) continue;
        const line = try alloc.dupe(u8, p.slice["<p>".len .. p.slice.len - "</p>".len]);
        errdefer alloc.free(line);
        try text.append(alloc, line);
    }
    if (text.items.len == 0) return error.IndexingFailed;

    return .{
        .{
            .public = public,
            .user_hash = user.hash,
            .url_hash = u.hash(),
            .url = u,
            .title = d_title,
        },
        .{ .text = try text.toOwnedSlice(alloc) },
    };
}
