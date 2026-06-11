const crawl = @import("crawl.zig");
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

    var user = try User.parse(alloc, req);
    defer if (user) |*u| u.deinit(alloc);

    var safe_search = try SafeSearch.parse(alloc, req);
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
        try results.results[0].url.format(&location.writer);

        req.setStatus(.found);
        try req.setHeader("Location", location.written());
        return req.sendBody("Found");
    };

    try templates.respond(alloc, req, (templates.Search{
        .q = q,
        .results = &results,
    }).interface());
}

fn getConsole(alloc: std.mem.Allocator, req: *const zap.Request) !void {
    req.parseCookies(false);

    var user = try User.parse(alloc, req) orelse return error.AccessDenied;
    defer user.deinit(alloc);

    const entries = try IndexEntry.getUserEntries(alloc, &user);
    defer alloc.free(entries);

    return templates.respond(alloc, req, (templates.SearchConsole{
        .entries = entries,
    }).interface());
}

fn postSubmitPage(alloc: std.mem.Allocator, req: *const zap.Request) !void {
    req.parseCookies(false);

    var user = try User.parse(alloc, req) orelse return error.AccessDenied;
    defer user.deinit(alloc);

    try req.parseBody();

    const public = try req.getParamStr(alloc, "public");
    defer if (public) |p| alloc.free(p);

    const url = try req.getParamStr(alloc, "url") orelse return error.InvalidRequest;
    defer alloc.free(url);

    const full_url = try std.mem.concat(alloc, u8, &.{ "http://", url });
    defer alloc.free(full_url);

    const index_entry, const document = try crawl.crawl(alloc, &user, public != null, full_url);
    defer {
        alloc.free(index_entry.title);
        for (document.text) |l| alloc.free(l);
        alloc.free(document.text);
    }
    try index_entry.put();
    try document.put(&index_entry);

    return templates.respond(alloc, req, (templates.Message{
        .title = "Search Console: Submitted Page",
        .message = "The page has been submitted to the index.",
        .is_error = false,
    }).interface());
}

fn postShortenUrl(alloc: std.mem.Allocator, req: *const zap.Request) !void {
    try req.parseBody();

    const url = try req.getParamStr(alloc, "url") orelse return error.InvalidRequest;
    defer alloc.free(url);

    const full_url = try std.mem.concat(alloc, u8, &.{ "http://", url });
    defer alloc.free(full_url);

    const short_url: ShortUrl = try .init(full_url);
    try short_url.put();

    var message: std.Io.Writer.Allocating = .init(alloc);
    defer message.deinit();
    try message.writer.writeAll("http://");
    try message.writer.writeAll(req.getHeaderCommon(.host) orelse "[host]");
    try message.writer.writeAll("/u/");
    try message.writer.printHex(&short_url.hash, .lower);

    return templates.respond(alloc, req, (templates.Message{
        .title = "Search Console: Shortened URL",
        .message = try message.toOwnedSlice(),
        .is_error = false,
    }).interface());
}

fn getPreferences(alloc: std.mem.Allocator, req: *const zap.Request) !void {
    req.parseCookies(false);

    var user = try User.parse(alloc, req);
    defer if (user) |*u| u.deinit(alloc);

    var safe_search = try SafeSearch.parse(alloc, req);
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

    if (username.len == 0 or password.len == 0) return error.MissingUsernameOrPassword;

    const user: User = try .login(username, password);

    var value: std.Io.Writer.Allocating = .init(alloc);
    defer value.deinit();
    try value.writer.writeAll("username=");
    try value.writer.writeAll(user.username);
    try value.writer.writeAll("&hmac=");
    try value.writer.printHex(&user.hmac, .lower);

    try req.setCookie(.{ .name = "user_account", .value = value.written(), .secure = false });
    try req.redirectTo("/preferences", null);
}

fn cookieValidChar(char: u8) bool {
    return switch (char) {
        '&' => false,
        else => |c| utils.cookieValidChar(c),
    };
}

fn postSafeSearch(alloc: std.mem.Allocator, req: *const zap.Request) !void {
    try req.parseBody();

    const enabled = try req.getParamStr(alloc, "enabled");
    defer if (enabled) |e| alloc.free(e);

    const regex = try req.getParamStr(alloc, "regex") orelse return error.InvalidRequest;
    defer alloc.free(regex);

    var value: std.Io.Writer.Allocating = .init(alloc);
    defer value.deinit();
    if (enabled != null) try value.writer.writeAll("enabled=on&");
    try value.writer.writeAll("regex=");
    try std.Uri.Component.percentEncode(&value.writer, regex, cookieValidChar);

    try req.setCookie(.{ .name = "safe_search", .value = value.written(), .secure = false });
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

    const paste: Paste = .init(title, text);
    try paste.put();

    var location: std.Io.Writer.Allocating = .init(alloc);
    defer location.deinit();
    try location.writer.print("/p/{s}", .{std.fmt.bytesToHex(paste.hash, .lower)});

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

const Prefix = u40;
const prefix_bytes = @typeInfo(Prefix).int.bits / 8;

fn prefix(bytes: []const u8) Prefix {
    std.debug.assert(bytes.len >= prefix_bytes);
    return std.mem.readInt(Prefix, bytes[0..prefix_bytes], .big);
}

fn eqlSuffix(a: []const u8, comptime b: []const u8) bool {
    std.debug.assert(a.len >= prefix_bytes);
    comptime std.debug.assert(b.len >= prefix_bytes);
    if (a.len != b.len) return false;
    if (comptime b.len <= prefix_bytes) return true;
    return std.mem.eql(u8, a[prefix_bytes..], b[prefix_bytes..]);
}

fn startSuffix(a: []const u8, comptime b: []const u8) bool {
    std.debug.assert(a.len >= prefix_bytes);
    if (comptime b.len <= prefix_bytes) return true;
    return std.mem.eql(u8, a[prefix_bytes..b.len], b[prefix_bytes..]);
}

fn sendMethodNotAllowed(req: *const zap.Request, allow: []const u8) !void {
    req.setStatus(.method_not_allowed);
    try req.setHeader("Allow", allow);
    return req.sendBody("Method Not Allowed");
}

fn handleRequest(alloc: std.mem.Allocator, req: *const zap.Request) !void {
    if (req.path) |path| {
        if (path.len == 1 and path[0] == '/') {
            if (req.methodAsEnum() != .GET) return sendMethodNotAllowed(req, "GET");
            return getIndex(alloc, req);
        }

        const method = req.methodAsEnum();
        if (path.len >= prefix_bytes) switch (prefix(path)) {
            prefix("/search") => if (eqlSuffix(path, "/search")) return switch (method) {
                .GET => getSearch(alloc, req),
                else => sendMethodNotAllowed(req, "GET"),
            },
            prefix("/console") => if (eqlSuffix(path, "/console")) return switch (method) {
                .GET => getConsole(alloc, req),
                else => sendMethodNotAllowed(req, "GET"),
            },
            prefix("/submit_page") => if (eqlSuffix(path, "/submit_page")) return switch (method) {
                .POST => postSubmitPage(alloc, req),
                else => sendMethodNotAllowed(req, "POST"),
            },
            prefix("/shorten_url") => if (eqlSuffix(path, "/shorten_url")) return switch (method) {
                .POST => postShortenUrl(alloc, req),
                else => sendMethodNotAllowed(req, "POST"),
            },
            prefix("/preferences") => if (eqlSuffix(path, "/preferences")) return switch (method) {
                .GET => getPreferences(alloc, req),
                else => sendMethodNotAllowed(req, "GET"),
            },
            prefix("/user_account") => if (eqlSuffix(path, "/user_account")) return switch (method) {
                .POST => postUserAccount(alloc, req),
                else => sendMethodNotAllowed(req, "POST"),
            },
            prefix("/safe_search") => if (eqlSuffix(path, "/safe_search")) return switch (method) {
                .POST => postSafeSearch(alloc, req),
                else => sendMethodNotAllowed(req, "POST"),
            },
            prefix("/pastebin") => if (eqlSuffix(path, "/pastebin")) return switch (method) {
                .GET => getPastebin(alloc, req),
                .POST => postPastebin(alloc, req),
                else => sendMethodNotAllowed(req, "GET, POST"),
            },
            prefix("/u/00")...prefix("/u/ff"),
            => switch (method) {
                .GET => if (startSuffix(path, "/u/") and path.len == 3 + ShortUrl.bytes * 2) return getUrl(alloc, req),
                else => return sendMethodNotAllowed(req, "GET"),
            },
            prefix("/p/00")...prefix("/p/ff"),
            => switch (method) {
                .GET => if (startSuffix(path, "/p/") and path.len == 3 + @sizeOf(utils.Hash) * 2) return getPaste(alloc, req),
                else => return sendMethodNotAllowed(req, "GET"),
            },
            prefix("/help") => if (eqlSuffix(path, "/help")) return switch (method) {
                .GET => getHelp(alloc, req),
                else => sendMethodNotAllowed(req, "GET"),
            },
            prefix("/logo.gif") => if (eqlSuffix(path, "/logo.gif")) return switch (method) {
                .GET => getLogoGif(req),
                else => sendMethodNotAllowed(req, "GET"),
            },
            else => {},
        };
    }

    req.setStatus(.not_found);
    try req.setContentType(.TEXT);
    try req.sendBody("Not Found");
}

fn makeDir(sub_path: []const u8) !void {
    std.fs.cwd().makeDir(sub_path) catch |err| switch (err) {
        std.fs.Dir.MakeError.PathAlreadyExists => {},
        else => return err,
    };
}

pub fn main() !void {
    try makeDir("documents");
    try makeDir("index");
    try makeDir("pastes");
    try makeDir("urls");
    try makeDir("users");

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    const Handler = struct {
        var alloc: std.mem.Allocator = undefined;
        fn handleRequest_(req: zap.Request) !void {
            try handleRequest(alloc, &req);
        }
    };
    Handler.alloc = gpa.allocator();

    var listener: zap.HttpListener = .init(.{
        .port = 7777,
        .on_request = Handler.handleRequest_,
        .max_clients = 1_000_000,
    });
    try listener.listen();
    zap.start(.{ .workers = 2, .threads = 8 });
}
