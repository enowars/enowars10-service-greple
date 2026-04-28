const httpz = @import("httpz");
const query = @import("query.zig");
const search = @import("search.zig");
const std = @import("std");
const templates = @import("templates.zig");

var server_instance: ?*httpz.Server(void) = null;

fn shutdown(_: i32) callconv(.c) noreturn {
    if (server_instance) |server| {
        server_instance = null;
        server.stop();
    }
    std.posix.exit(0);
}

fn handleIndex(_: *httpz.Request, res: *httpz.Response) !void {
    var index = try search.getIndex(true);
    defer index.close();

    var index_size: u32 = 0;
    var it = index.iterateAssumeFirstIteration();
    while (try it.next()) |_| index_size += 1;

    try templates.respond(res, (templates.Index{
        .index_size = index_size,
    }).interface());
}

fn handleSearch(req: *httpz.Request, res: *httpz.Response) !void {
    const queryParams = try req.query();
    const q = queryParams.get("q") orelse "";

    var results = blk: {
        var parsed_q = try query.Query.init(res.arena, q) orelse break :blk search.Results{
            .documents = &.{},
            .time = 0,
            .total = 0,
        };
        defer parsed_q.deinit(res.arena);
        break :blk try search.performSearch(res.arena, &parsed_q);
    };
    defer results.deinit(res.arena);

    if (queryParams.has("btnI") and results.documents.len > 0) {
        res.status = 302;
        res.headers.add("Location", try std.mem.concat(
            res.arena,
            u8,
            &.{ "http://", results.documents[0].url },
        ));
        return;
    }

    try templates.respond(res, (templates.Search{
        .q = q,
        .results = &results,
    }).interface());
}

fn handleHelp(_: *httpz.Request, res: *httpz.Response) !void {
    try templates.respond(res, (templates.Help{}).interface());
}

fn handleLogoGif(_: *httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
    res.headers.add("Content-Type", "image/gif");
    res.body = @embedFile("static/logo.gif");
}

pub fn main() !void {
    std.posix.sigaction(std.posix.SIG.INT, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try httpz.Server(void).init(allocator, .{ .address = .all(7777) }, {});
    defer {
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});
    router.get("/", handleIndex, .{});
    router.get("/search", handleSearch, .{});
    router.get("/help", handleHelp, .{});
    router.get("/static/logo.gif", handleLogoGif, .{});

    server_instance = &server;
    try server.listen();
}
