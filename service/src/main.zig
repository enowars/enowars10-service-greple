const Crawler = @import("Crawler.zig");
const IndexEntry = @import("IndexEntry.zig");
const mvzr = @import("mvzr");
const Netloc = @import("Netloc.zig");
const Paste = @import("Paste.zig");
const Query = @import("Query.zig");
const SafeSearch = @import("SafeSearch.zig");
const search = @import("search.zig");
const ShortUrl = @import("ShortUrl.zig");
const std = @import("std");
const templates = @import("templates.zig");
const Url = @import("Url.zig");
const User = @import("User.zig");
const utils = @import("utils.zig");
const zap = @import("zap");

pub const std_options: std.Options = .{
    .log_level = .info,
    .http_disable_tls = true,
};

fn getIndex(alloc: std.mem.Allocator, req: *const zap.Request) !void {
    try templates.respond(alloc, req, (templates.Index{
        .index_size = try IndexEntry.getSize(),
    }).interface());
}

fn getSearch(alloc: std.mem.Allocator, req: *const zap.Request) !void {
    req.parseQuery();
    req.parseCookies(false);

    var user = try User.getFromCookie(alloc, req);
    defer if (user) |*u| u.deinit(alloc);

    var safe_search = try SafeSearch.getFromCookie(alloc, req);
    defer if (safe_search) |*ss| ss.deinit(alloc);

    const q = try req.getParamStr(alloc, "q") orelse return error.InvalidRequest;
    defer alloc.free(q);

    var results = blk: {
        const query = try Query.init(alloc, q) orelse break :blk search.Results{
            .results = &.{},
            .time = 0,
            .total = 0,
        };
        break :blk try search.performSearch(alloc, &user, &safe_search, &query);
    };
    defer results.deinit(alloc);

    if (req.getParamSlice("lucky")) |_| if (results.results.len > 0) {
        var location: std.Io.Writer.Allocating = .init(alloc);
        defer location.deinit();
        try results.results[0].index_entry.url.format(&location.writer);

        req.setStatus(.found);
        try req.setHeader("Location", location.written());
        return req.sendBody("Found");
    };

    try templates.respond(alloc, req, (templates.Search{
        .q = q,
        .results = &results,
    }).interface());
}

fn getSearchConsole(alloc: std.mem.Allocator, req: *const zap.Request) !void {
    req.parseCookies(false);

    var users: utils.HashMap(User) = .init(alloc);
    defer {
        var it = users.valueIterator();
        while (it.next()) |u| u.deinit(alloc);
        users.deinit();
    }

    var user = try User.getFromCookie(alloc, req) orelse return error.AccessDenied;
    {
        errdefer user.deinit(alloc);
        try users.putNoClobber(user.hash(), user);
    }
    const user_hash = user.hash();

    const netlocs = try Netloc.getByUser(alloc, user_hash);
    defer alloc.free(netlocs);

    const entries = try IndexEntry.getByUserOrNetloc(alloc, user_hash, netlocs);
    defer alloc.free(entries);
    for (entries) |e| {
        if (!users.contains(e.user_hash)) {
            const u: User = try .get(alloc, e.user_hash);
            errdefer user.deinit(alloc);
            try users.putNoClobber(e.user_hash, u);
        }
    }

    return templates.respond(alloc, req, (templates.SearchConsole{
        .users = &users,
        .entries = entries,
        .netlocs = netlocs,
    }).interface());
}

fn postSubmitPage(alloc: std.mem.Allocator, crawler: *Crawler, req: *const zap.Request) !void {
    req.parseCookies(false);

    var user = try User.getFromCookie(alloc, req) orelse return error.AccessDenied;
    defer user.deinit(alloc);
    const user_hash = user.hash();

    try req.parseBody();

    const public = try req.getParamStr(alloc, "public");
    defer if (public) |p| alloc.free(p);
    const url = try req.getParamStr(alloc, "url") orelse return error.InvalidRequest;
    defer alloc.free(url);

    const connection = try crawler.getOrPut(user_hash);
    try connection.crawl(user_hash, public != null, &try .init(alloc, url, true));

    try req.redirectTo("/queue", null);
}

fn postShortenUrl(alloc: std.mem.Allocator, req: *const zap.Request) !void {
    try req.parseBody();

    const url = try req.getParamStr(alloc, "url") orelse return error.InvalidRequest;
    defer alloc.free(url);

    const short_url: ShortUrl = try .init(alloc, url);
    try short_url.put();

    var message: std.Io.Writer.Allocating = .init(alloc);
    defer message.deinit();
    try message.writer.writeAll("http://");
    try message.writer.writeAll(req.getHeaderCommon(.host) orelse "[host]");
    try message.writer.writeAll("/u/");
    try message.writer.printHex(&short_url.hash(), .lower);

    return templates.respond(alloc, req, (templates.Message{
        .title = "Search Console: Shortened URL",
        .message = message.written(),
        .is_error = false,
    }).interface());
}

fn postVerifyNetloc(alloc: std.mem.Allocator, crawler: *Crawler, req: *const zap.Request) !void {
    req.parseCookies(false);

    var user = try User.getFromCookie(alloc, req) orelse return error.AccessDenied;
    defer user.deinit(alloc);

    try req.parseBody();

    const netloc = try req.getParamStr(alloc, "netloc") orelse return error.InvalidRequest;
    defer alloc.free(netloc);

    const api_key = try req.getParamStr(alloc, "api_key") orelse return error.InvalidRequest;
    defer alloc.free(api_key);

    const nl: Netloc = try .init(alloc, user.hash(), netloc, api_key);
    try nl.put();

    const connection = try crawler.getOrPut(user.hash());
    try connection.verify(user.username, &nl);

    try req.redirectTo("/console", null);
}

fn getPreferences(alloc: std.mem.Allocator, req: *const zap.Request) !void {
    req.parseCookies(false);

    var user = try User.getFromCookie(alloc, req);
    defer if (user) |*u| u.deinit(alloc);

    var safe_search = try SafeSearch.getFromCookie(alloc, req);
    defer if (safe_search) |*ss| ss.deinit(alloc);

    try templates.respond(alloc, req, (templates.Preferences{
        .user = &user,
        .safe_search = &safe_search,
    }).interface());
}

fn postUserAccount(alloc: std.mem.Allocator, req: *const zap.Request) !void {
    try req.parseBody();

    const username = try req.getParamStr(alloc, "username") orelse return error.InvalidRequest;
    defer alloc.free(username);

    const password = try req.getParamStr(alloc, "password") orelse return error.InvalidRequest;
    defer alloc.free(password);

    try User.login(alloc, req, username, password);

    try req.redirectTo("/preferences", null);
}

fn postSafeSearch(alloc: std.mem.Allocator, req: *const zap.Request) !void {
    try req.parseBody();

    const enabled = try req.getParamStr(alloc, "enabled");
    defer if (enabled) |e| alloc.free(e);

    const regex = try req.getParamStr(alloc, "regex") orelse return error.InvalidRequest;
    defer alloc.free(regex);

    try (SafeSearch{
        .enabled = enabled != null,
        .regex = regex,
    }).put(alloc, req);

    try req.redirectTo("/preferences", null);
}

fn getPastebin(alloc: std.mem.Allocator, req: *const zap.Request) !void {
    try templates.respond(alloc, req, (templates.Pastebin{}).interface());
}

fn postPastebin(alloc: std.mem.Allocator, req: *const zap.Request) !void {
    try req.parseBody();

    const title = try req.getParamStr(alloc, "title") orelse return error.InvalidRequest;
    defer alloc.free(title);
    const text = try req.getParamStr(alloc, "text") orelse return error.InvalidRequest;
    defer alloc.free(text);

    const paste: Paste = .{
        .title = title,
        .text = text,
    };
    try paste.put();

    var location: std.Io.Writer.Allocating = .init(alloc);
    defer location.deinit();
    try location.writer.print("/p/{s}", .{std.fmt.bytesToHex(paste.hash(), .lower)});

    try req.redirectTo(location.written(), null);
}

fn getUrl(alloc: std.mem.Allocator, req: *const zap.Request) !void {
    const hash = req.path.?[3..];

    var short_url: ShortUrl = try .get(alloc, try utils.hexToBytes(ShortUrl.bytes, hash));
    defer short_url.deinit(alloc);

    var location: std.Io.Writer.Allocating = .init(alloc);
    defer location.deinit();
    try short_url.url.format(&location.writer);

    try req.redirectTo(location.written(), null);
}

fn getPaste(alloc: std.mem.Allocator, req: *const zap.Request) !void {
    const hash = req.path.?[3..];
    var paste: Paste = try .get(alloc, try utils.hexToBytes(@sizeOf(utils.Hash), hash));
    defer paste.deinit(alloc);
    try templates.respond(alloc, req, (templates.Paste{ .paste = &paste }).interface());
}

fn getHelp(alloc: std.mem.Allocator, req: *const zap.Request) !void {
    try templates.respond(alloc, req, (templates.SearchTips{}).interface());
}

fn getLogoGif(req: *const zap.Request) !void {
    try req.setHeader("Content-Type", "image/gif");
    try req.setHeader("Cache-Control", "max-age=" ++ std.fmt.comptimePrint("{d}", .{60 * 60 * 24}));
    try req.sendBody(@embedFile("static/logo.gif"));
}

fn postRefresh(alloc: std.mem.Allocator, crawler: *Crawler, req: *const zap.Request) !void {
    req.parseCookies(false);

    var user = try User.getFromCookie(alloc, req) orelse return error.AccessDenied;
    defer user.deinit(alloc);

    try req.parseBody();

    const hash = try req.getParamStr(alloc, "hash") orelse return error.InvalidRequest;
    defer alloc.free(hash);

    var index_entry: IndexEntry = try .get(alloc, try utils.hexToBytes(@sizeOf(utils.Hash), hash));
    defer index_entry.deinit(alloc);

    const connection = try crawler.getOrPut(user.hash());
    try connection.crawl(index_entry.user_hash, index_entry.public, &index_entry.url);

    try req.redirectTo("/queue", null);
}

fn getQueue(alloc: std.mem.Allocator, crawler: *Crawler, req: *const zap.Request) !void {
    req.parseCookies(false);

    var user = try User.getFromCookie(alloc, req) orelse return error.AccessDenied;
    defer user.deinit(alloc);

    const connection = crawler.get(user.hash()) orelse return req.redirectTo("/console", null);
    connection.mut.lock();
    defer connection.mut.unlock();

    if (connection.queue.isEmpty()) return req.redirectTo("/console", null);

    try req.setHeader("Refresh", "1");
    return templates.respond(alloc, req, (templates.Queue{ .connection = connection }).interface());
}

fn postToken(alloc: std.mem.Allocator, req: *const zap.Request) !void {
    req.parseCookies(false);

    var user = try User.getFromCookie(alloc, req) orelse return error.AccessDenied;
    defer user.deinit(alloc);

    try req.parseBody();

    const hash = try req.getParamStr(alloc, "hash") orelse return error.InvalidRequest;
    defer alloc.free(hash);

    const token = try req.getParamStr(alloc, "token") orelse return error.InvalidRequest;
    defer alloc.free(token);

    var netloc: Netloc = try .get(alloc, try utils.hexToBytes(@sizeOf(utils.Hash), hash));
    defer netloc.deinit(alloc);

    if (!std.mem.eql(u8, token, &try netloc.verificationToken(alloc, user.username))) return error.InvalidToken;

    netloc.verified = true;
    try netloc.put();

    try req.redirectTo("/console", null);
}

const Prefix = u24;
const prefix_bytes = @typeInfo(Prefix).int.bits / 8;

fn prefix(bytes: []const u8) Prefix {
    std.debug.assert(bytes.len >= prefix_bytes);
    return std.mem.readInt(Prefix, bytes[0..prefix_bytes], .big);
}

fn eqlSuffix(comptime a: []const u8, b: []const u8) bool {
    std.debug.assert(b.len >= prefix_bytes);
    comptime std.debug.assert(a.len >= prefix_bytes);
    if (b.len != a.len) return false;
    if (comptime a.len <= prefix_bytes) return true;
    return std.mem.eql(u8, b[prefix_bytes..], a[prefix_bytes..]);
}

fn startSuffix(comptime a: []const u8, b: []const u8) bool {
    std.debug.assert(b.len >= prefix_bytes);
    if (comptime a.len <= prefix_bytes) return true;
    return std.mem.eql(u8, b[prefix_bytes..a.len], a[prefix_bytes..]);
}

fn sendMethodNotAllowed(req: *const zap.Request, allow: []const u8) !void {
    req.setStatus(.method_not_allowed);
    try req.setHeader("Allow", allow);
    return req.sendBody("Method Not Allowed");
}

fn route(alloc: std.mem.Allocator, crawler: *Crawler, req: *const zap.Request) !void {
    if (req.path) |path| {
        if (path.len == 1 and path[0] == '/') {
            if (req.methodAsEnum() != .GET) return sendMethodNotAllowed(req, "GET");
            return getIndex(alloc, req);
        }

        const method = req.methodAsEnum();
        if (path.len >= prefix_bytes) switch (prefix(path)) {
            prefix("/search") => if (eqlSuffix("/search", path)) return switch (method) {
                .GET => getSearch(alloc, req),
                else => sendMethodNotAllowed(req, "GET"),
            },
            prefix("/console") => if (eqlSuffix("/console", path)) return switch (method) {
                .GET => getSearchConsole(alloc, req),
                else => sendMethodNotAllowed(req, "GET"),
            },
            prefix("/submit_page") => if (eqlSuffix("/submit_page", path)) return switch (method) {
                .POST => postSubmitPage(alloc, crawler, req),
                else => sendMethodNotAllowed(req, "POST"),
            },
            prefix("/shorten_url") => if (eqlSuffix("/shorten_url", path)) return switch (method) {
                .POST => postShortenUrl(alloc, req),
                else => sendMethodNotAllowed(req, "POST"),
            },
            prefix("/verify_netloc") => if (eqlSuffix("/verify_netloc", path)) return switch (method) {
                .POST => postVerifyNetloc(alloc, crawler, req),
                else => sendMethodNotAllowed(req, "POST"),
            },
            prefix("/preferences") => if (eqlSuffix("/preferences", path)) return switch (method) {
                .GET => getPreferences(alloc, req),
                else => sendMethodNotAllowed(req, "GET"),
            },
            prefix("/user_account") => if (eqlSuffix("/user_account", path)) return switch (method) {
                .POST => postUserAccount(alloc, req),
                else => sendMethodNotAllowed(req, "POST"),
            },
            prefix("/safe_search") => if (eqlSuffix("/safe_search", path)) return switch (method) {
                .POST => postSafeSearch(alloc, req),
                else => sendMethodNotAllowed(req, "POST"),
            },
            prefix("/pastebin") => if (eqlSuffix("/pastebin", path)) return switch (method) {
                .GET => getPastebin(alloc, req),
                .POST => postPastebin(alloc, req),
                else => sendMethodNotAllowed(req, "GET, POST"),
            },
            prefix("/u/") => if (startSuffix("/u/", path) and path.len == 3 + ShortUrl.bytes * 2) return switch (method) {
                .GET => getUrl(alloc, req),
                else => sendMethodNotAllowed(req, "GET"),
            },
            prefix("/p/") => if (startSuffix("/p/", path) and path.len == 3 + @sizeOf(utils.Hash) * 2) return switch (method) {
                .GET => getPaste(alloc, req),
                else => sendMethodNotAllowed(req, "GET"),
            },
            prefix("/help") => if (eqlSuffix("/help", path)) return switch (method) {
                .GET => getHelp(alloc, req),
                else => sendMethodNotAllowed(req, "GET"),
            },
            prefix("/logo.gif") => if (eqlSuffix("/logo.gif", path)) return switch (method) {
                .GET => getLogoGif(req),
                else => sendMethodNotAllowed(req, "GET"),
            },
            prefix("/refresh") => if (eqlSuffix("/refresh", path)) return switch (method) {
                .POST => postRefresh(alloc, crawler, req),
                else => sendMethodNotAllowed(req, "POST"),
            },
            prefix("/queue") => if (eqlSuffix("/queue", path)) return switch (method) {
                .GET => getQueue(alloc, crawler, req),
                else => sendMethodNotAllowed(req, "GET"),
            },
            prefix("/token") => if (eqlSuffix("/token", path)) return switch (method) {
                .POST => postToken(alloc, req),
                else => sendMethodNotAllowed(req, "POST"),
            },
            else => {},
        };
    }

    req.setStatus(.not_found);
    try req.setContentType(.TEXT);
    try req.sendBody("Not Found");
}

fn handleRequest(
    alloc: std.mem.Allocator,
    crawler: *Crawler,
    req: *const zap.Request,
) !void {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const method = try arena_alloc.dupe(u8, req.method.?);
    defer arena_alloc.free(method);
    const path = try arena_alloc.dupe(u8, req.path.?);
    defer arena_alloc.free(path);
    var timer = try std.time.Timer.start();
    defer {
        const elapsed = timer.read();
        if (elapsed > std.time.ns_per_s) std.log.info(
            "request {s} {s} took {d}ms",
            .{ method, path, elapsed / std.time.ns_per_ms },
        );
    }

    route(arena_alloc, crawler, req) catch |err| {
        std.log.info("{s} {s} {}", .{ req.method.?, req.path.?, err });

        const safe_err = switch (err) {
            error.HostTooLong,
            error.InvalidNetloc,
            error.InvalidOrTooComplexRegex,
            error.InvalidPassword,
            error.InvalidRequest,
            error.InvalidToken,
            error.InvalidUrl,
            error.InvalidUserAccountCookie,
            error.InvalidUsername,
            error.PathTooLong,
            error.TextTooLong,
            error.TitleTooLong,
            error.UsernameTooLong,
            => |bad_request_err| blk: {
                req.setStatus(.bad_request);
                break :blk bad_request_err;
            },
            error.FileNotFound,
            => |not_found_err| blk: {
                req.setStatus(.not_found);
                break :blk not_found_err;
            },
            error.AccessDenied,
            error.InvalidCredentials,
            => |forbidden_err| blk: {
                req.setStatus(.forbidden);
                break :blk forbidden_err;
            },
            else => blk: {
                if (@errorReturnTrace()) |rt| std.debug.dumpStackTrace(rt.*);
                req.setStatus(.internal_server_error);
                break :blk error.InternalServerError;
            },
        };
        var message: std.Io.Writer.Allocating = .init(arena_alloc);
        defer message.deinit();
        for (@errorName(safe_err)) |c| {
            if (std.ascii.isUpper(c)) try message.writer.writeByte(' ');
            try message.writer.writeByte(c);
        }

        try templates.respond(arena_alloc, req, (templates.Message{
            .title = "Error",
            .message = message.written(),
            .is_error = true,
        }).interface());
    };
}

pub fn main() !void {
    try utils.cleanUpTmpFiles("documents");
    try utils.cleanUpTmpFiles("netlocs");
    try utils.cleanUpTmpFiles("index");
    try utils.cleanUpTmpFiles("pastes");
    try utils.cleanUpTmpFiles("urls");
    try utils.cleanUpTmpFiles("users");

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    const Handler = struct {
        var alloc: std.mem.Allocator = undefined;
        var crawler: Crawler = undefined;
        fn innerHandleRequest(req: zap.Request) !void {
            try handleRequest(alloc, &crawler, &req);
        }
    };
    Handler.alloc = gpa.allocator();
    Handler.crawler = .init(Handler.alloc);
    defer Handler.crawler.deinit();

    var listener: zap.HttpListener = .init(.{
        .port = 7777,
        .on_request = Handler.innerHandleRequest,
    });
    try listener.listen();
    zap.start(.{ .workers = 1, .threads = 20 });
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
