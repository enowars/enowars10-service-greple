const crawl = @import("crawl.zig");
const httpz = @import("httpz");
const IndexEntry = @import("IndexEntry.zig");
const Paste = @import("Paste.zig");
const Query = @import("Query.zig");
const SafeSearch = @import("SafeSearch.zig");
const search = @import("search.zig");
const ShortUrl = @import("ShortUrl.zig");
const std = @import("std");
const templates = @import("templates.zig");
const User = @import("User.zig");
const utils = @import("utils.zig");

pub const std_options: std.Options = .{ .http_disable_tls = true };

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
        error.HostTooLong,
        error.InvalidPassword,
        error.InvalidRequest,
        error.InvalidUrl,
        error.InvalidUsername,
        error.MissingUsernameOrPassword,
        error.PathTooLong,
        error.TextTooLong,
        error.TitleTooLong,
        => |bad_request_err| blk: {
            res.status = 400;
            break :blk bad_request_err;
        },
        error.AccessDenied,
        error.InvalidCredentials,
        => |forbidden_err| blk: {
            res.status = 403;
            break :blk forbidden_err;
        },
        error.DnsResolutionFailed,
        error.IndexingFailed,
        => |internal_err| blk: {
            res.status = 500;
            break :blk internal_err;
        },
        else => blk: {
            res.status = 500;
            break :blk error.InternalServerError;
        },
    };
    std.log.info("{d} {} {s} {}", .{ res.status, req.method, req.url.path, err });
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
        };
        break :blk try search.performSearch(res.arena, &user, &safe_search, &query);
    };

    if (query_params.has("lucky") and results.results.len > 0) {
        var location: std.Io.Writer.Allocating = .init(res.arena);
        defer location.deinit();
        try results.results[0].url.format(&location.writer);

        res.status = 302;
        res.headers.add("Location", try location.toOwnedSlice());
        return;
    }

    try templates.respond(res, (templates.Search{
        .q = q,
        .results = &results,
    }).interface());
}

fn getConsole(_: @This(), req: *httpz.Request, res: *httpz.Response) !void {
    if (try User.parse(req)) |_| return templates.respond(res, (templates.SearchConsole{}).interface());
    return error.AccessDenied;
}

fn postSubmitPage(_: @This(), req: *httpz.Request, res: *httpz.Response) !void {
    if (try User.parse(req)) |*u| {
        const data = try req.formData();
        const public = data.has("public");
        const url = data.get("url") orelse return error.InvalidRequest;

        const full_url = try std.mem.concat(res.arena, u8, &.{ "http://", url });
        defer res.arena.free(full_url);

        const index_entry, const document = try crawl.crawl(res.arena, u, public, full_url);
        defer {
            res.arena.free(index_entry.title);
            for (document.text) |l| res.arena.free(l);
            res.arena.free(document.text);
        }
        try index_entry.put();
        try document.put(&index_entry);

        return templates.respond(res, (templates.Message{
            .title = "Search Console: Submitted Page",
            .message = "The page has been submitted to the index.",
            .is_error = false,
        }).interface());
    }

    return error.AccessDenied;
}

fn postShortenUrl(_: @This(), req: *httpz.Request, res: *httpz.Response) !void {
    if (try User.parse(req)) |_| {
        const data = try req.formData();
        const url = data.get("url") orelse return error.InvalidRequest;

        const full_url = try std.mem.concat(res.arena, u8, &.{ "http://", url });
        defer res.arena.free(full_url);

        const short_url: ShortUrl = try .init(full_url);
        try short_url.put();

        var message: std.Io.Writer.Allocating = .init(res.arena);
        defer message.deinit();
        try message.writer.writeAll("http://");
        try message.writer.writeAll(req.header("host") orelse "[host]");
        try message.writer.writeAll("/u/");
        try message.writer.printHex(&short_url.hash, .lower);

        return templates.respond(res, (templates.Message{
            .title = "Search Console: Shortened URL",
            .message = try message.toOwnedSlice(),
            .is_error = false,
        }).interface());
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

fn postUserAccount(_: @This(), req: *httpz.Request, res: *httpz.Response) !void {
    const data = try req.formData();
    const username = data.get("username") orelse return error.InvalidRequest;
    const password = data.get("password") orelse return error.InvalidRequest;
    if (username.len == 0 or password.len == 0) return error.MissingUsernameOrPassword;

    const user: User = try .login(username, password);

    var value: std.Io.Writer.Allocating = .init(res.arena);
    defer value.deinit();
    try value.writer.writeAll("username=");
    try std.Uri.Component.percentEncode(&value.writer, user.username, cookieValidChar);
    try value.writer.writeAll("&hmac=");
    try value.writer.printHex(&user.hmac, .lower);

    res.status = 302;
    res.headers.add("Location", "/preferences");
    try res.setCookie("user_account", try value.toOwnedSlice(), cookie_opts);
}

fn postSafeSearch(_: @This(), req: *httpz.Request, res: *httpz.Response) !void {
    const data = try req.formData();
    const enabled = data.has("enabled");
    const regex = data.get("regex") orelse return error.InvalidRequest;

    var value: std.Io.Writer.Allocating = .init(res.arena);
    defer value.deinit();
    if (enabled) try value.writer.writeAll("enabled=on&");
    try value.writer.writeAll("regex=");
    try std.Uri.Component.percentEncode(&value.writer, regex, cookieValidChar);

    res.status = 302;
    res.headers.add("Location", "/preferences");
    try res.setCookie("safe_search", try value.toOwnedSlice(), cookie_opts);
}

fn getPastebin(_: @This(), _: *const httpz.Request, res: *httpz.Response) !void {
    try templates.respond(res, (templates.Pastebin{}).interface());
}

fn postPastebin(_: @This(), req: *httpz.Request, res: *httpz.Response) !void {
    const data = try req.formData();

    const title = data.get("title") orelse return error.InvalidRequest;
    const text = data.get("text") orelse return error.InvalidRequest;

    const paste: Paste = .init(title, text);
    try paste.put();

    var location: std.Io.Writer.Allocating = .init(res.arena);
    defer location.deinit();
    try location.writer.print("/p/{s}", .{std.fmt.bytesToHex(paste.hash, .lower)});

    res.status = 302;
    res.headers.add("Location", try location.toOwnedSlice());
}

fn getUrl(_: @This(), req: *const httpz.Request, res: *httpz.Response) !void {
    const hash = req.param("hash") orelse return error.InvalidRequest;

    var short_url: ShortUrl = try .get(req.arena, try utils.hexToBytes(ShortUrl.bytes, hash));
    defer short_url.deinit(res.arena);

    var location: std.Io.Writer.Allocating = .init(res.arena);
    defer location.deinit();
    try short_url.url.format(&location.writer);

    res.status = 302;
    res.headers.add("Location", try location.toOwnedSlice());
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
    try makeDir("index");
    try makeDir("pastes");
    try makeDir("urls");
    try makeDir("users");

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const allocator = gpa.allocator();

    var server: httpz.Server(@This()) = try .init(allocator, .{
        .address = .all(7777),
        .request = .{ .max_form_count = 6 },
        .workers = .{ .count = 1 },
    }, .{});
    defer {
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});
    router.get("/", getIndex, .{});
    router.get("/search", getSearch, .{});
    router.get("/console", getConsole, .{});
    router.post("/submit_page", postSubmitPage, .{});
    router.post("/shorten_url", postShortenUrl, .{});
    router.get("/preferences", getPreferences, .{});
    router.post("/user_account", postUserAccount, .{});
    router.post("/safe_search", postSafeSearch, .{});
    router.get("/pastebin", getPastebin, .{});
    router.post("/pastebin", postPastebin, .{});
    router.get("/u/:hash", getUrl, .{});
    router.get("/p/:hash", getPaste, .{});
    router.get("/help", getHelp, .{});
    router.get("/logo.gif", getLogoGif, .{});

    server_instance = &server;
    try server.listen();
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
