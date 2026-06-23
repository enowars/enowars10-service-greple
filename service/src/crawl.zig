const Document = @import("Document.zig");
const IndexEntry = @import("IndexEntry.zig");
const mvzr = @import("mvzr");
const Netloc = @import("Netloc.zig");
const std = @import("std");
const Url = @import("Url.zig");
const User = @import("User.zig");
const utils = @import("utils.zig");

const title_re = mvzr.SizedRegex(17, 1).compile("<title>.*?</title>").?;
const p_re = mvzr.SizedRegex(9, 1).compile("<p>[^<]+</p>").?;

fn setTimeout(fd: std.posix.fd_t, level: i32, optname: u32) !void {
    try std.posix.setsockopt(fd, level, optname, std.mem.asBytes(&std.posix.timeval{ .sec = 0, .usec = 5e5 }));
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
    api_key: []const u8,
    content_type: []const u8,
) ![]u8 {
    const addr = blk: {
        const list = try std.net.getAddressList(alloc, url.host, url.port);
        defer list.deinit();
        for (list.addrs) |a| {
            if (a.any.family != std.posix.AF.INET) continue;
            switch (@as(u8, @truncate(std.mem.bigToNative(u32, a.in.sa.addr)))) {
                0, 255 => continue,
                else => {},
            }
            if (@import("builtin").is_test) break :blk a;
            switch (std.mem.bigToNative(u32, a.in.sa.addr)) {
                bytesToU32(.{ 10, 0, 0, 0 })...bytesToU32(.{ 10, 255, 255, 255 }),
                bytesToU32(.{ 91, 99, 0, 0 })...bytesToU32(.{ 91, 99, 255, 255 }), // TODO: remove CICD
                bytesToU32(.{ 172, 18, 0, 1 }),
                => {},
                else => continue,
            }
            switch (a.in.getPort()) {
                1024...9999 => {},
                else => continue,
            }
            break :blk a;
        }
        return error.NoValidAddressFound;
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
        .headers = .{ .accept_encoding = .omit },
        .extra_headers = if (api_key.len > 0) &.{.{ .name = "X-API-Key", .value = api_key }} else &.{},
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

pub const Result = struct {
    body: []const u8,
    index_entry: IndexEntry,
    document: Document,

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(self.body);
        alloc.free(self.document.text);
        self.* = undefined;
    }
};

pub fn crawl(
    alloc: std.mem.Allocator,
    user_hash: utils.Hash,
    public: bool,
    url: *const Url,
) !Result {
    var netloc = Netloc.getByUserUrl(alloc, user_hash, url) catch |err| switch (err) {
        std.fs.File.OpenError.FileNotFound => null,
        else => |leftover_err| return leftover_err,
    };
    defer if (netloc) |*nl| nl.deinit(alloc);

    const body = fetch(alloc, url, if (netloc) |nl| nl.api_key else "", "text/html") catch |err| {
        std.log.warn("Indexing failed {f} {}", .{ url, err });
        return error.IndexingFailed;
    };
    errdefer alloc.free(body);

    const title_tag = title_re.match(body) orelse return error.IndexingFailed;
    std.debug.assert(title_tag.slice.len >= "<title></title>".len);
    const title = title_tag.slice["<title>".len .. title_tag.slice.len - "</title>".len];

    var text: std.ArrayList([]const u8) = .empty;
    defer text.deinit(alloc);
    var it = p_re.iterator(body);
    while (it.next()) |p_tag| {
        std.debug.assert(p_tag.slice.len > "<p></p>".len);
        const p = body[p_tag.start + "<p>".len .. p_tag.end - "</p>".len];
        try text.append(alloc, utils.unescape(p));
    }
    if (text.items.len == 0) return error.IndexingFailed;

    return .{
        .body = body,
        .index_entry = .{
            .public = public,
            .user_hash = user_hash,
            .url = url.*,
            .title = title,
        },
        .document = .{
            .text = try text.toOwnedSlice(alloc),
        },
    };
}

test crawl {
    var r = try crawl(std.testing.allocator, .{0} ** 28, true, &.{
        .host = "example.com",
        .port = 80,
        .path = "/",
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Example Domain", r.index_entry.title);
    const t: []const []const u8 = &.{
        "This domain is for use in documentation examples without needing permission. Avoid use in operations.",
    };
    try std.testing.expectEqualDeep(t, r.document.text);
}
