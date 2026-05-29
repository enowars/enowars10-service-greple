const crawl = @import("crawl.zig");
const Document = @import("Document.zig");
const Domain = @import("Domain.zig");
const httpz = @import("httpz");
const IndexEntry = @import("IndexEntry.zig");
const Paste = @import("Paste.zig");
const Query = @import("Query.zig");
const SafeSearch = @import("SafeSearch.zig");
const search = @import("search.zig");
const std = @import("std");
const templates = @import("templates.zig");
const Url = @import("Url.zig");
const User = @import("User.zig");
const utils = @import("utils.zig");

const cookie_opts: httpz.response.CookieOpts = .{
    .http_only = true,
    .same_site = .strict,
};

var server_instance: ?*httpz.Server(@This()) = null;

fn shutdown(_: i32) callconv(.c) noreturn {
    if (server_instance) |server| {
        server_instance = null;
        server.stop();
    }
    std.posix.exit(0);
}

fn errorMessage(alloc: std.mem.Allocator, err: anyerror) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    for (@errorName(err)) |c| {
        if (std.ascii.isUpper(c)) try writer.writer.writeByte(' ');
        try writer.writer.writeByte(c);
    }
    return writer.toOwnedSlice();
}

pub fn uncaughtError(_: @This(), req: *httpz.Request, res: *httpz.Response, err: anyerror) void {
    const safe_err = switch (err) {
        error.InvalidDomain,
        error.InvalidIpv4,
        error.InvalidPath,
        error.InvalidPort,
        error.InvalidRequest,
        error.MissingUsernameOrPassword,
        error.UrlAlreadyShort,
        => |bad_request_err| blk: {
            res.status = 400;
            break :blk bad_request_err;
        },
        error.AccessDenied => |forbidden_err| blk: {
            res.status = 403;
            break :blk forbidden_err;
        },
        error.IndexingFailed => |internal_err| blk: {
            res.status = 500;
            break :blk internal_err;
        },
        else => |leftover_err| blk: {
            std.log.info("500 {} {s} {}", .{ req.method, req.url.path, leftover_err });
            res.status = 500;
            break :blk error.InternalServerError;
        },
    };
    const message = errorMessage(res.arena, safe_err) catch "Internal Server Error";
    templates.respond(res, (templates.Message{
        .title = "Error",
        .message = message,
        .is_error = true,
    }).interface()) catch {
        res.body = message;
    };
}

fn getIndex(_: @This(), _: *const httpz.Request, res: *httpz.Response) !void {
    try templates.respond(res, (templates.Index{
        .index_size = try IndexEntry.getSize(),
    }).interface());
}

fn getSearch(_: @This(), req: *httpz.Request, res: *httpz.Response) !void {
    const user = try User.parse(req);
    const safe_search = try SafeSearch.parse(req);

    const query_params = try req.query();
    const q = query_params.get("q") orelse "";

    var results = blk: {
        const query = try Query.init(res.arena, q) orelse break :blk search.Results{
            .results = &.{},
            .time = 0,
            .total = 0,
            .filtered = 0,
        };
        break :blk try search.performSearch(res.arena, user, safe_search, &query);
    };

    if (query_params.has("btnI") and results.results.len > 0) {
        var writer: std.Io.Writer.Allocating = .init(res.arena);
        defer writer.deinit();
        try writer.writer.print("http://{f}{s}", .{
            results.results[0].domain.?,
            results.results[0].path.?,
        });

        res.status = 302;
        res.headers.add("Location", try writer.toOwnedSlice());
        return;
    }

    try templates.respond(res, (templates.Search{
        .q = q,
        .results = &results,
    }).interface());
}

fn getSearchConsole(_: @This(), req: *httpz.Request, res: *httpz.Response) !void {
    if (try User.parse(req)) |*u| {
        return templates.respond(res, (templates.SearchConsole{
            .domains = try Domain.getAllOwned(res.arena, u),
        }).interface());
    }
    return error.AccessDenied;
}

fn postSearchConsoleRegisterDomain(
    req: *const httpz.Request,
    res: *httpz.Response,
    user: *const User,
    data: *const httpz.key_value.StringKeyValue,
) !void {
    const domain = data.get("domain") orelse return error.InvalidRequest;
    const ipv4 = data.get("ipv4") orelse return error.InvalidRequest;
    const port = data.get("port") orelse return error.InvalidRequest;

    const d: Domain = try .init(user, domain, ipv4, port);
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

    var d: Domain = try .get(res.arena, try utils.hexToBytes(@sizeOf(utils.Hash), domain));
    defer d.deinit(res.arena);
    if (!std.mem.eql(u8, &d.user_hash, &user.hash)) return error.InvalidRequest;

    var index_entry, var document = try crawl.crawl(res.arena, public, &d, path);
    defer {
        index_entry.deinit(res.arena);
        document.deinit(res.arena);
    }
    try index_entry.put(res.arena);
    try document.put(&index_entry);

    try templates.respond(res, (templates.Message{
        .title = "Search Console: Submitted Page",
        .message = "The page has been submitted to the index.",
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

fn postSearchConsole(_: @This(), req: *httpz.Request, res: *httpz.Response) !void {
    if (try User.parse(req)) |*u| {
        const data = try req.formData();
        if (data.has("form_register_domain")) return postSearchConsoleRegisterDomain(req, res, u, data);
        if (data.has("form_submit_page")) return postSearchConsoleSubmitPage(res, u, data);
        if (data.has("form_shorten_url")) return postSearchConsoleShortenUrl(req, res, data);
        return error.InvalidRequest;
    }
    return error.AccessDenied;
}

fn getPreferences(_: @This(), req: *const httpz.Request, res: *httpz.Response) !void {
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

fn postPreferences(_: @This(), req: *httpz.Request, res: *httpz.Response) !void {
    const data = try req.formData();
    if (data.has("form_user_account")) return postPreferencesUserAccount(req, res, data);
    if (data.has("form_safe_search")) return postPreferencesSafeSearch(req, res, data);
    return error.InvalidRequest;
}

fn getPastebin(_: @This(), _: *const httpz.Request, res: *httpz.Response) !void {
    try templates.respond(res, (templates.Pastebin{}).interface());
}

fn postPastebin(_: @This(), req: *httpz.Request, res: *httpz.Response) !void {
    const data = try req.formData();

    const title = data.get("title") orelse return error.InvalidRequest;
    const text = data.get("text") orelse return error.InvalidRequest;

    const paste: Paste = .{
        .hash = utils.hash(title), // TODO: use random id
        .title = title,
        .text = text,
    };
    try paste.put();

    var writer: std.Io.Writer.Allocating = .init(res.arena);
    defer writer.deinit();
    try writer.writer.print("/p/{s}", .{std.fmt.bytesToHex(paste.hash, .lower)});

    res.status = 302;
    res.headers.add("Location", try writer.toOwnedSlice());
}

fn getUrl(_: @This(), req: *const httpz.Request, res: *httpz.Response) !void {
    const hash = req.param("hash") orelse return error.InvalidRequest;

    var url: Url = try .get(req.arena, try utils.hexToBytes(Url.bytes, hash));
    defer url.deinit(res.arena);

    var domain: Domain = try .get(res.arena, url.domain_hash);
    defer domain.deinit(res.arena);

    var writer: std.Io.Writer.Allocating = .init(res.arena);
    defer writer.deinit();
    try writer.writer.print("http://{f}{s}", .{ domain, url.path });

    res.status = 302;
    res.headers.add("Location", try writer.toOwnedSlice());
}

fn getPaste(_: @This(), req: *const httpz.Request, res: *httpz.Response) !void {
    const hash = req.param("hash") orelse return error.InvalidRequest;
    var paste: Paste = try .get(req.arena, try utils.hexToBytes(@sizeOf(utils.Hash), hash));
    defer paste.deinit(res.arena);
    try templates.respond(res, (templates.Paste{ .paste = &paste }).interface());
}

fn getHelp(_: @This(), _: *const httpz.Request, res: *httpz.Response) !void {
    try templates.respond(res, (templates.SearchTips{}).interface());
}

fn getLogoGif(_: @This(), _: *const httpz.Request, res: *httpz.Response) !void {
    res.content_type = .GIF;
    res.headers.add("Cache-Control", "max-age=" ++ std.fmt.comptimePrint("{d}", .{60 * 60 * 24}));
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
    try makeDir("pastes");
    try makeDir("urls");
    try makeDir("users");

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const allocator = gpa.allocator();

    var server: httpz.Server(@This()) = try .init(allocator, .{
        .address = .all(7777),
        .request = .{ .max_form_count = 6 },
    }, .{});
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
    router.get("/pastebin", getPastebin, .{});
    router.post("/pastebin", postPastebin, .{});
    router.get("/u/:hash", getUrl, .{});
    router.get("/p/:hash", getPaste, .{});
    router.get("/help", getHelp, .{});
    router.get("/static/logo.gif", getLogoGif, .{});

    server_instance = &server;
    try server.listen();
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
