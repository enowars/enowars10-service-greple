const httpz = @import("httpz");
const index = @import("index.zig");
const preferences = @import("preferences.zig");
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

fn getIndex(_: *const httpz.Request, res: *httpz.Response) !void {
    var dir = try index.getDir(true);
    defer dir.close();

    var index_size: u32 = 0;
    var it = dir.iterateAssumeFirstIteration();
    while (try it.next()) |_| index_size += 1;

    try templates.respond(res, (templates.Index{
        .index_size = index_size,
    }).interface());
}

fn getSearch(req: *httpz.Request, res: *httpz.Response) !void {
    const prefs = try preferences.parse(req);

    const queryParams = try req.query();
    const q = queryParams.get("q") orelse "";

    var results = blk: {
        const pattern = try query.parse(res.arena, q) orelse break :blk search.Results{
            .results = &.{},
            .time = 0,
            .total = 0,
            .filtered = 0,
        };
        break :blk try search.performSearch(res.arena, &prefs, pattern);
    };

    if (queryParams.has("btnI") and results.results.len > 0) {
        res.status = 302;
        res.headers.add("Location", try std.mem.concat(
            res.arena,
            u8,
            &.{ "http://", results.results[0].url.? },
        ));
        return;
    }

    try templates.respond(res, (templates.Search{
        .q = q,
        .results = &results,
    }).interface());
}

fn checkLogin(prefs: *const preferences.Preferences, res: *httpz.Response) !bool {
    if (std.mem.eql(u8, prefs.user, preferences.user_nobody)) {
        try templates.respond(res, (templates.Error{
            .message =
            \\You are not allowed to access this page.
            \\Login in <a href="/preferences" style="color: white">preferences</a>.
            ,
        }).interface());
        return false;
    }
    return true;
}

fn getSearchConsole(req: *httpz.Request, res: *httpz.Response) !void {
    const prefs = try preferences.parse(req);
    if (!try checkLogin(&prefs, res)) return;
    try templates.respond(res, (templates.SearchConsole{}).interface());
}

fn postSearchConsole(req: *httpz.Request, res: *httpz.Response) !void {
    const prefs = try preferences.parse(req);
    if (!try checkLogin(&prefs, res)) return;

    const data = try req.formData();
    const url = data.get("url") orelse return;
    const title = data.get("title") orelse return;
    const text = data.get("text") orelse return;

    try index.writeEntry(res.arena, &prefs, url, title, text);

    res.status = 302;
    res.headers.add("Location", req.url.path);
}

fn getPreferences(req: *const httpz.Request, res: *httpz.Response) !void {
    const prefs = try preferences.parse(req);
    try templates.respond(res, (templates.Preferences{ .prefs = &prefs }).interface());
}

fn postPreferences(req: *const httpz.Request, res: *httpz.Response) !void {
    if (req.body()) |b| res.headers.add(
        "Set-Cookie",
        try std.mem.concat(res.arena, u8, &.{ "preferences=", b }),
    );
    res.status = 302;
    res.headers.add("Location", req.url.path);
}

fn getHelp(_: *const httpz.Request, res: *httpz.Response) !void {
    try templates.respond(res, (templates.Help{}).interface());
}

fn getLogoGif(_: *const httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
    res.content_type = .GIF;
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

    var server = try httpz.Server(void).init(allocator, .{
        .address = .all(7777),
        .request = .{ .max_form_count = 3 },
    }, {});
    defer {
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});
    router.get("/", getIndex, .{});
    router.get("/search", getSearch, .{});
    router.get("/console", getSearchConsole, .{});
    router.post("/console", postSearchConsole, .{});
    router.get("/preferences", getPreferences, .{});
    router.post("/preferences", postPreferences, .{});
    router.get("/help", getHelp, .{});
    router.get("/static/logo.gif", getLogoGif, .{});

    server_instance = &server;
    try server.listen();
}
