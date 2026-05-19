const Document = @import("document.zig");
const Domain = @import("domain.zig");
const httpz = @import("httpz");
const IndexEntry = @import("index_entry.zig");
const Query = @import("query.zig");
const SafeSearch = @import("safe_search.zig");
const search = @import("search.zig");
const std = @import("std");
const templates = @import("templates.zig");
const Url = @import("url.zig");
const User = @import("user.zig");
const utils = @import("utils.zig");

const cookie_opts: httpz.response.CookieOpts = .{
    .http_only = true,
    .same_site = .strict,
};

var server_instance: ?*httpz.Server(void) = null;

fn shutdown(_: i32) callconv(.c) noreturn {
    if (server_instance) |server| {
        server_instance = null;
        server.stop();
    }
    std.posix.exit(0);
}

fn errorResponse(res: *httpz.Response, comptime page: []const u8, err: anyerror) !void {
    var writer: std.Io.Writer.Allocating = .init(res.arena);
    defer writer.deinit();
    try writer.writer.writeAll("Error:");
    for (@errorName(err)) |c| {
        if (std.ascii.isUpper(c)) try writer.writer.writeByte(' ');
        try writer.writer.writeByte(c);
    }

    try templates.respond(res, (templates.Message{
        .title = page ++ ": Error",
        .message = try writer.toOwnedSlice(),
        .is_error = true,
    }).interface());
}

fn getIndex(_: *const httpz.Request, res: *httpz.Response) !void {
    try templates.respond(res, (templates.Index{
        .index_size = try IndexEntry.getSize(),
    }).interface());
}

fn getSearch(req: *httpz.Request, res: *httpz.Response) !void {
    const user = try User.parse(req);
    const safe_search = try SafeSearch.parse(req);

    const queryParams = try req.query();
    const q = queryParams.get("q") orelse "";

    var results = blk: {
        const query = try Query.init(res.arena, q) orelse break :blk search.Results{
            .results = &.{},
            .time = 0,
            .total = 0,
            .filtered = 0,
        };
        break :blk try search.performSearch(res.arena, user, safe_search, &query);
    };

    if (queryParams.has("btnI") and results.results.len > 0) {
        var writer: std.Io.Writer.Allocating = .init(res.arena);
        defer writer.deinit();
        try writer.writer.print(
            "http://{d}.{d}.{d}.{d}:{d}{s}",
            .{
                results.results[0].domain.?.ip[0],
                results.results[0].domain.?.ip[1],
                results.results[0].domain.?.ip[2],
                results.results[0].domain.?.ip[3],
                results.results[0].domain.?.port,
                results.results[0].path.?,
            },
        );

        res.status = 302;
        res.headers.add("Location", try writer.toOwnedSlice());
        return;
    }

    try templates.respond(res, (templates.Search{
        .q = q,
        .results = &results,
    }).interface());
}

fn getSearchConsole(req: *httpz.Request, res: *httpz.Response) !void {
    const user = try User.parse(req);
    if (user) |*u| {
        try templates.respond(res, (templates.SearchConsole{
            .domains = try Domain.getAllOwned(res.arena, u),
        }).interface());
    } else {
        try errorResponse(res, "Search Console", error.AccessDenied);
    }
}

fn postSearchConsoleRegisterDomain(
    req: *const httpz.Request,
    res: *httpz.Response,
    user: *const User,
    data: *const httpz.key_value.StringKeyValue,
) !void {
    const domain = data.get("domain") orelse return error.InvalidRequest;
    const ip = data.get("ip") orelse return error.InvalidRequest;
    const port = data.get("port") orelse return error.InvalidRequest;

    const d: Domain = try .init(user, domain, ip, port);
    try d.put();

    res.status = 302;
    res.headers.add("Location", req.url.path);
}

fn postSearchConsoleSubmitPage(
    res: *httpz.Response,
    user: *const User,
    data: *const httpz.key_value.StringKeyValue,
) !void {
    const public = data.has("public");
    const domain = data.get("domain") orelse return error.InvalidRequest;
    const path = data.get("path") orelse return error.InvalidRequest;
    const title = data.get("title") orelse return error.InvalidRequest;
    const text = data.get("text") orelse return error.InvalidRequest;

    const d: Domain = try .get(res.arena, try utils.hexToBytes(@sizeOf(utils.Hash), domain));
    if (!std.mem.eql(u8, &d.user_hash, &user.hash)) return error.AccessDenied;

    const index_entry: IndexEntry = .{
        .public = public,
        .domain_hash = d.hash,
        .path_hash = utils.hash(path),
        .path = path, // TODO: verify valid path
        .title = title, // TODO: get from web
    };
    try index_entry.put(res.arena);

    // TODO: get from web
    var t: std.ArrayList([]const u8) = .empty;
    defer t.deinit(res.arena);
    var it = std.mem.splitAny(u8, text, "\r\n");
    while (it.next()) |l| {
        if (l.len == 0) continue;
        try t.append(res.arena, l);
    }
    try (Document{ .text = try t.toOwnedSlice(res.arena) }).put(&index_entry);

    try templates.respond(res, (templates.Message{
        .title = "Search Console: Submitted Page",
        .message = "The page has been submitted for indexing.",
        .is_error = false,
    }).interface());
}

fn postSearchConsoleShortenUrl(
    req: *const httpz.Request,
    res: *httpz.Response,
    data: *const httpz.key_value.StringKeyValue,
) !void {
    const domain = data.get("domain") orelse return error.InvalidRequest;
    const path = data.get("path") orelse return error.InvalidRequest;

    var d: Domain = try .get(res.arena, try utils.hexToBytes(@sizeOf(utils.Hash), domain));
    defer d.deinit(res.arena);

    const url: Url = try .init(&d, path);
    try url.put();

    var writer: std.Io.Writer.Allocating = .init(res.arena);
    defer writer.deinit();
    // TODO: add http:// host and port
    _ = req.headers.get("Host");
    try writer.writer.writeAll("/u/");
    try writer.writer.printHex(&url.hash, .lower);

    try templates.respond(res, (templates.Message{
        .title = "Search Console: Shortened URL",
        .message = try writer.toOwnedSlice(),
        .is_error = false,
    }).interface());
}

fn postSearchConsole(req: *httpz.Request, res: *httpz.Response) !void {
    if (try User.parse(req)) |*u| {
        const data = try req.formData();
        (blk: {
            if (data.has("form_register_domain")) break :blk postSearchConsoleRegisterDomain(req, res, u, data);
            if (data.has("form_submit_page")) break :blk postSearchConsoleSubmitPage(res, u, data);
            if (data.has("form_shorten_url")) break :blk postSearchConsoleShortenUrl(req, res, data);
            break :blk error.InvalidRequest;
        }) catch |err| switch (err) {
            error.AccessDenied,
            error.InvalidDomain,
            error.InvalidIp,
            error.InvalidPort,
            error.InvalidRequest,
            error.UrlAlreadyShort,
            => try errorResponse(res, "Search Console", err),
            else => |leftover_err| return leftover_err,
        };
    } else {
        try errorResponse(res, "Search Console", error.AccessDenied);
    }
}

fn getPreferences(req: *const httpz.Request, res: *httpz.Response) !void {
    const user = try User.parse(req);
    const safe_search = try SafeSearch.parse(req);
    try templates.respond(res, (templates.Preferences{ .user = user, .safe_search = safe_search }).interface());
}

fn cookieValidChar(char: u8) bool {
    return switch (char) {
        '&' => false,
        else => |c| utils.cookieValidChar(c),
    };
}

fn postPreferencesUserAccount(
    req: *const httpz.Request,
    res: *httpz.Response,
    data: *const httpz.key_value.StringKeyValue,
) !void {
    const username = data.get("username") orelse return error.InvalidRequest;
    const password = data.get("password") orelse return error.InvalidRequest;
    if (username.len == 0 or password.len == 0) return error.MissingUsernameOrPassword;

    const user: User = try .login(username, password);

    var cookie: std.Io.Writer.Allocating = .init(res.arena);
    defer cookie.deinit();
    try cookie.writer.writeAll("username=");
    try std.Uri.Component.percentEncode(&cookie.writer, user.username, cookieValidChar);
    try cookie.writer.writeAll("&hmac=");
    try cookie.writer.printHex(&user.hmac, .lower);

    res.status = 302;
    res.headers.add("Location", req.url.path);
    try res.setCookie("user_account", try cookie.toOwnedSlice(), cookie_opts);
}

fn postPreferencesSafeSearch(
    req: *const httpz.Request,
    res: *httpz.Response,
    data: *const httpz.key_value.StringKeyValue,
) !void {
    const enabled = data.has("enabled");
    const regex = data.get("regex") orelse return error.InvalidRequest;

    var cookie: std.Io.Writer.Allocating = .init(res.arena);
    defer cookie.deinit();
    if (enabled) try cookie.writer.writeAll("enabled=on&");
    try cookie.writer.writeAll("regex=");
    try std.Uri.Component.percentEncode(&cookie.writer, regex, cookieValidChar);

    res.status = 302;
    res.headers.add("Location", req.url.path);
    try res.setCookie("safe_search", try cookie.toOwnedSlice(), cookie_opts);
}

fn postPreferences(req: *httpz.Request, res: *httpz.Response) !void {
    const data = try req.formData();
    (blk: {
        if (data.has("form_user_account")) break :blk postPreferencesUserAccount(req, res, data);
        if (data.has("form_safe_search")) break :blk postPreferencesSafeSearch(req, res, data);
        break :blk error.InvalidRequest;
    }) catch |err| switch (err) {
        error.InvalidCredentials,
        error.InvalidRequest,
        error.MissingUsernameOrPassword,
        => try errorResponse(res, "Preferences", err),
        else => |leftover_err| return leftover_err,
    };
}

fn getUrl(req: *const httpz.Request, res: *httpz.Response) !void {
    const hash = req.param("hash") orelse return error.InvalidRequest;

    var url: Url = try .get(req.arena, try utils.hexToBytes(Url.bytes, hash));
    defer url.deinit(res.arena);

    var domain: Domain = try .get(res.arena, url.domain_hash);
    defer domain.deinit(res.arena);

    var writer: std.Io.Writer.Allocating = .init(res.arena);
    defer writer.deinit();
    try writer.writer.print(
        "http://{d}.{d}.{d}.{d}:{d}{s}",
        .{ domain.ip[0], domain.ip[1], domain.ip[2], domain.ip[3], domain.port, url.path },
    );

    res.status = 302;
    res.headers.add("Location", try writer.toOwnedSlice());
}

fn getHelp(_: *const httpz.Request, res: *httpz.Response) !void {
    try templates.respond(res, (templates.SearchTips{}).interface());
}

fn getLogoGif(_: *const httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
    res.content_type = .GIF;
    res.body = @embedFile("static/logo.gif");
}

fn makeDir(sub_path: []const u8) !void {
    std.fs.cwd().makeDir(sub_path) catch |err| switch (err) {
        std.fs.Dir.MakeError.PathAlreadyExists => {},
        else => return err,
    };
}

pub fn main() !void {
    std.posix.sigaction(std.posix.SIG.INT, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    try makeDir("documents");
    try makeDir("domains");
    try makeDir("index");
    try makeDir("urls");
    try makeDir("users");

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const allocator = gpa.allocator();

    var server: httpz.Server(void) = try .init(allocator, .{
        .address = .all(7777),
        .request = .{ .max_form_count = 6 },
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
    router.get("/u/:hash", getUrl, .{});
    router.get("/help", getHelp, .{});
    router.get("/static/logo.gif", getLogoGif, .{});

    server_instance = &server;
    try server.listen();
}
