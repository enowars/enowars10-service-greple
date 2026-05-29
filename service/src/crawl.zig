const Document = @import("Document.zig");
const Domain = @import("Domain.zig");
const IndexEntry = @import("IndexEntry.zig");
const mvzr = @import("mvzr");
const std = @import("std");
const utils = @import("utils.zig");

const path_re = mvzr.compile("(/([a-zA-Z0-9\\-._~]|%[0-9a-fA-F]{2})+)+/?|/").?;
const title_re = mvzr.compile("<title>.*?</title>").?;
const p_re = mvzr.compile("<p>.*?</p>").?;

pub fn crawl(alloc: std.mem.Allocator, public: bool, domain: *const Domain, path: []const u8) !struct { IndexEntry, Document } {
    if (!utils.fullMatch(&path_re, path)) return error.InvalidPath;

    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();

    var ipv4: std.Io.Writer.Allocating = .init(alloc);
    defer ipv4.deinit();
    try domain.formatIpv4(&ipv4.writer);

    const connection = try client.connectTcp(ipv4.written(), domain.port, .plain);

    var request: std.http.Client.Request = .{
        .uri = .{
            .scheme = "http",
            .host = .{ .percent_encoded = ipv4.written() },
            .port = domain.port,
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
    if (response.head.status != .ok) return error.IndexingFailed;
    if (response.head.content_type) |c| {
        if (std.mem.eql(u8, c, "text/html")) return error.IndexingFailed;
    } else return error.IndexingFailed;

    var reader = response.reader(&.{});
    const body = try reader.allocRemaining(alloc, .unlimited);
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

    const d_path = try alloc.dupe(u8, path);
    errdefer alloc.free(d_path);

    return .{
        .{
            .public = public,
            .domain_hash = domain.hash,
            .path_hash = utils.hash(path),
            .path = d_path,
            .title = d_title,
        },
        .{ .text = try text.toOwnedSlice(alloc) },
    };
}

test "path validation" {
    try std.testing.expect(utils.fullMatch(&path_re, "/"));
    try std.testing.expect(utils.fullMatch(&path_re, "/abc"));
    try std.testing.expect(utils.fullMatch(&path_re, "/abc/"));
    try std.testing.expect(!utils.fullMatch(&path_re, "/ "));
    try std.testing.expect(utils.fullMatch(&path_re, "/%20"));
}
