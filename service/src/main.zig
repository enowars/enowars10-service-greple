const httpz = @import("httpz");
const index = @import("index.zig");
const preferences = @import("preferences.zig");
const query = @import("query.zig");
const search = @import("search.zig");
const std = @import("std");
const templates = @import("templates.zig");
const urls = @import("urls.zig");
const utils = @import("utils.zig");

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
        try templates.respond(res, (templates.Message{
            .title = "Error",
            .message =
            \\You are not allowed to access this page.
            \\Login using <a href="/preferences" style="color: white">preferences</a>.
            ,
            .is_error = true,
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

fn postSearchConsoleSubmit(res: *httpz.Response, prefs: *const preferences.Preferences, data: *const httpz.key_value.StringKeyValue) !void {
    // TODO: allow public entries
    const public = data.has("public");
    _ = public;
    const url = data.get("url") orelse return error.InvalidRequest;
    const title = data.get("title") orelse return error.InvalidRequest;
    const text = data.get("text") orelse return error.InvalidRequest;

    try index.writeEntry(res.arena, prefs, url, title, text);

    try templates.respond(res, (templates.Message{
        .title = "Search Console: Submitted Page",
        .message = "The page has been submitted for indexing.",
        .is_error = false,
    }).interface());
}

fn postSearchConsoleURL(res: *httpz.Response, data: *const httpz.key_value.StringKeyValue) !void {
    const url = data.get("url") orelse return error.InvalidRequest;
    const hash = try urls.writeURL(url);
    try templates.respond(res, (templates.Message{
        .title = "Search Console: Shortened URL",
        .message = &hash,
        .is_error = false,
    }).interface());
}

fn postSearchConsole(req: *httpz.Request, res: *httpz.Response) !void {
    const prefs = try preferences.parse(req);
    if (!try checkLogin(&prefs, res)) return;

    const data = try req.formData();

    (blk: {
        if (data.has("form_submit")) break :blk postSearchConsoleSubmit(res, &prefs, data);
        if (data.has("form_url")) break :blk postSearchConsoleURL(res, data);
        break :blk error.InvalidRequest;
    }) catch |err| switch (err) {
        error.InvalidRequest => try templates.respond(res, (templates.Message{
            .title = "Search Console: Error",
            .message = "Invalid request.",
            .is_error = true,
        }).interface()),
        else => |leftover_err| return leftover_err,
    };
}

fn getPreferences(req: *const httpz.Request, res: *httpz.Response) !void {
    const prefs = try preferences.parse(req);
    try templates.respond(res, (templates.Preferences{ .prefs = &prefs }).interface());
}

fn preferencesCookieValidChar(char: u8) bool {
    return switch (char) {
        '&' => false,
        else => |c| utils.cookieValidChar(c),
    };
}

fn postPreferences(req: *httpz.Request, res: *httpz.Response) !void {
    const data = try req.formData();

    const user, const password, const safe_search_enabled, const safe_search_regex = (blk: {
        break :blk .{
            data.get("user") orelse break :blk error.InvalidRequest,
            data.get("password") orelse break :blk error.InvalidRequest,
            data.has("safe_search_enabled"),
            data.get("safe_search_regex") orelse break :blk error.InvalidRequest,
        };
    }) catch |err| switch (err) {
        error.InvalidRequest => return templates.respond(res, (templates.Message{
            .title = "Preferences: Error",
            .message = "Invalid request.",
            .is_error = true,
        }).interface()),
        else => |leftover_err| return leftover_err,
    };

    if (password.len > 0) preferences.login(user, password, res) catch |err| switch (err) {
        error.InvalidCredentials => return templates.respond(res, (templates.Message{
            .title = "Preferences: Error",
            .message = "Invalid credentials.",
            .is_error = true,
        }).interface()),
        else => |leftover_err| return leftover_err,
    };

    var cookie: std.Io.Writer.Allocating = .init(res.arena);
    defer cookie.deinit();

    try cookie.writer.writeAll("preferences=");

    if (safe_search_enabled) try cookie.writer.writeAll("safe_search_enabled=on&");

    try cookie.writer.writeAll("safe_search_regex=");
    try std.Uri.Component.percentEncode(&cookie.writer, safe_search_regex, preferencesCookieValidChar);

    res.headers.add("Set-Cookie", try cookie.toOwnedSlice());

    res.status = 302;
    res.headers.add("Location", req.url.path);
}

fn getURL(req: *const httpz.Request, res: *httpz.Response) !void {
    const hash = req.param("hash") orelse return error.InvalidRequest;
    const url = try urls.getURL(req.arena, hash);
    res.status = 302;
    res.headers.add("Location", url);
}

fn getHelp(_: *const httpz.Request, res: *httpz.Response) !void {
    try templates.respond(res, (templates.SearchTips{}).interface());
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

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const allocator = gpa.allocator();

    var server: httpz.Server(void) = try .init(allocator, .{
        .address = .all(7777),
        .request = .{ .max_form_count = 5 },
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
    router.get("/u/:hash", getURL, .{});
    router.get("/help", getHelp, .{});
    router.get("/static/logo.gif", getLogoGif, .{});

    server_instance = &server;
    try server.listen();
}
