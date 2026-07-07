const std = @import("std");
const Url = @import("Url.zig");
const User = @import("User.zig");
const utils = @import("utils.zig");
const zap = @import("zap");

const Escape = struct {
    string: []const u8,

    pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
        try utils.escape(self.string, w);
    }
};

const Template = struct {
    self: *const anyopaque,
    formatFn: *const fn (self: *const anyopaque, w: *std.Io.Writer) std.Io.Writer.Error!void,

    pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
        try self.formatFn(self.self, w);
    }
};

const Base = struct {
    self: *const anyopaque,
    formatTitleFn: *const fn (self: *const anyopaque, w: *std.Io.Writer) std.Io.Writer.Error!void,
    formatBodyFn: *const fn (self: *const anyopaque, w: *std.Io.Writer) std.Io.Writer.Error!void,

    fn format(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        try w.print(
            \\<!DOCTYPE html>
            \\<html lang="en">
            \\<head>
            \\  <meta charset="UTF-8">
            \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \\  <title>{f}</title>
            \\  <style>
            \\    *{{box-sizing:border-box}}
            \\    html{{font-family:Arial,sans-serif;scroll-padding-top:1rem}}
            \\    .form{{display:grid;grid-template-columns:repeat(2,max-content);justify-items:flex-start;gap:.5rem;margin:1rem 0}}
            \\    .form>[type="submit"]{{grid-column:1/3}}
            \\    a[name]{{display:block;font-weight:bold;margin-top:2.5rem}}
            \\    a[name]:first-child{{margin-top:unset}}
            \\    table{{border-collapse:collapse}}
            \\    thead{{border-bottom:2px solid black}}
            \\    th,td{{border:1px solid black;padding:4pt}}
            \\    td:first-child{{white-space:nowrap}}
            \\    small>a{{color:#6f6f6f}}
            \\  </style>
            \\</head>
            \\<body bgcolor="#ffffff" text="#000000" link="#0000cc" vlink="#551A8B" alink="#ff0000">
            \\  {f}
            \\  <script>
            \\    function refresh(h) {{
            \\      const form = document.createElement('form');
            \\      form.action = '/refresh';
            \\      form.method = 'POST';
            \\      const input = document.createElement('input');
            \\      input.type = 'hidden';
            \\      input.name = 'hash';
            \\      input.value = h;
            \\      form.appendChild(input);
            \\      document.body.appendChild(form);
            \\      form.submit();
            \\    }}
            \\  </script>
            \\</body>
            \\</html>
        , .{
            Template{ .self = s.self, .formatFn = s.formatTitleFn },
            Template{ .self = s.self, .formatFn = s.formatBodyFn },
        });
    }

    fn interface(self: *const @This()) Template {
        return .{ .self = self, .formatFn = &format };
    }
};

pub const Index = struct {
    index_size: u32,

    fn formatTitle(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.writeAll("Greple");
    }

    fn formatBody(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        try w.print(
            \\<div style="display: flex; flex-direction: column; align-items: center; gap: 1rem; max-width: 80rem">
            \\  <img width="300" height="117" src="/logo.gif" border="0" alt="Greple">
            \\  <small>Search {d} web pages</small>
            \\  <form action="/search" method="GET" style="display: flex; gap: .5rem; flex-direction: column; width: fit-content">
            \\    <input type="text" value="" name="q" size="50">
            \\    <div style="display: flex; gap: .25rem; justify-content: center">
            \\      <input type="submit" value="Greple Search">
            \\      <input name="lucky" type="submit" value="I'm Feeling Lucky">
            \\    </div>
            \\  </form>
            \\</div>
        , .{s.index_size});
    }

    fn format(self: *const anyopaque, w: *std.Io.Writer) !void {
        try (Base{
            .self = self,
            .formatTitleFn = &formatTitle,
            .formatBodyFn = &formatBody,
        }).interface().format(w);
    }

    pub fn interface(self: *const @This()) Template {
        return .{ .self = self, .formatFn = &format };
    }
};

const Columns = struct {
    self: *const anyopaque,
    formatTitleFn: *const fn (self: *const anyopaque, w: *std.Io.Writer) std.Io.Writer.Error!void,
    formatHeaderFn: ?*const fn (self: *const anyopaque, w: *std.Io.Writer) std.Io.Writer.Error!void = null,
    formatTocFn: ?*const fn (self: *const anyopaque, w: *std.Io.Writer) std.Io.Writer.Error!void = null,
    formatMainFn: *const fn (self: *const anyopaque, w: *std.Io.Writer) std.Io.Writer.Error!void,

    fn formatTitle(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        try s.formatTitleFn(s.self, w);
    }

    fn formatHeader(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        if (s.formatHeaderFn) |f| return f(s.self, w);
        try w.print(
            \\<h1 style="font-size:1rem;padding:2pt;color:white;background:#336699;width:100%">{f}</h1>
        , .{Template{ .self = s.self, .formatFn = s.formatTitleFn }});
    }

    fn formatToc(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        if (s.formatTocFn) |f| try w.print(
            \\<p><b>Table of Contents</b></p>
            \\<ul style="display:flex;flex-direction:column;gap:.5rem;padding-left:1.5rem">{f}</ul>
        , .{Template{ .self = s.self, .formatFn = f }});
    }

    fn formatBody(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        try w.print(
            \\<div style="display:grid;grid-template:5rem auto/12.5rem 67rem;gap:.5rem;align-items:center">
            \\  <a href="/"><img src="/logo.gif" border="0" width="200" height="78" alt="Greple"></a>
            \\  {f}
            \\  <div style="font-size:small;align-self:start;margin-top:1rem;margin-left:.5rem">
            \\    <nav style="display:flex;flex-direction:column;gap:.5rem;align-items:start">
            \\      <a href="/">Home</a>
            \\      <a href="/console">Search Console</a>
            \\      <a href="/preferences">Preferences</a>
            \\      <a href="/pastebin">Pastebin</a>
            \\      <a href="/help">Search Tips</a>
            \\    </nav>
            \\    {f}
            \\  </div>
            \\  <main style="align-self:start">{f}</main>
            \\</div>
        , .{
            Template{ .self = self, .formatFn = formatHeader },
            Template{ .self = self, .formatFn = formatToc },
            Template{ .self = s.self, .formatFn = s.formatMainFn },
        });
    }

    fn format(self: *const anyopaque, w: *std.Io.Writer) !void {
        try (Base{
            .self = self,
            .formatTitleFn = &formatTitle,
            .formatBodyFn = &formatBody,
        }).interface().format(w);
    }

    fn interface(self: *const @This()) Template {
        return .{ .self = self, .formatFn = &format };
    }
};

pub const Search = struct {
    q: []const u8,
    results: *const @import("search.zig").Results,

    fn formatTitle(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        try w.print("Search: {f}", .{Escape{ .string = s.q }});
    }

    fn formatHeader(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        try w.print(
            \\<div style="display:flex;flex-direction:column;gap:.75rem">
            \\  <form action="/search" style="display:flex;gap:.25rem">
            \\    <input type="text" name="q" size="32" value="{f}">
            \\    <input type="submit" value="Greple Search">
            \\    <input type="submit" name="lucky" value="I'm Feeling Lucky"><br>
            \\  </form>
            \\  <div style="padding:2pt;color:white;background:#3366cc;display:flex;justify-content:space-between">
            \\    <small>Searched the web for <b>{f}</b>.</small>
            \\    <small>Results <b>{d} - {d}</b> of <b>{d}</b>. Search took <b title="{d} ms">{d:.2}</b> seconds.</small>
            \\  </div>
            \\</div>
        , .{
            Escape{ .string = s.q },
            Escape{ .string = s.q },
            @min(s.results.results.len, 1),
            s.results.results.len,
            s.results.total,
            @as(f32, @floatFromInt(s.results.time)) / 1e6,
            @as(f32, @floatFromInt(s.results.time)) / 1e9,
        });
    }

    fn formatMain(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        for (s.results.results) |r| try w.print(
            \\<p>
            \\  <a href="{f}">{f}</a>
            \\  <small style="-webkit-box-orient: vertical; -webkit-line-clamp: 3; display: -webkit-box; overflow: hidden; text-overflow: ellipsis; width: 32rem">{f}</small>
            \\  <small><font color="green">{f} -</font> <a href="javascript:refresh('{s}')">Refresh</a></small>
            \\</p>
        , .{
            r.index_entry.url,
            Escape{ .string = r.index_entry.title },
            Escape{ .string = r.text },
            r.index_entry.url,
            std.fmt.bytesToHex(r.index_entry.hash(), .lower),
        });
    }

    fn format(self: *const anyopaque, w: *std.Io.Writer) !void {
        try (Columns{
            .self = self,
            .formatTitleFn = &formatTitle,
            .formatHeaderFn = &formatHeader,
            .formatMainFn = &formatMain,
        }).interface().format(w);
    }

    pub fn interface(self: *const @This()) Template {
        return .{ .self = self, .formatFn = &format };
    }
};

pub const Preferences = struct {
    user: *const ?User,
    safe_search: *const ?@import("SafeSearch.zig"),

    fn formatTitle(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.writeAll("Preferences");
    }

    fn formatToc(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.writeAll(
            \\<li><a href="#user_account">User Account</a></li>
            \\<li><a href="#safe_search">Safe Search</a></li>
        );
    }

    fn formatMain(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        try w.print(
            \\<a name="user_account">User Account</a>
            \\<p>Login into a Greple account to access the search console. If you don't have an account, use the same form to register.</p>
            \\<form action="/user_account" method="POST" class="form">
            \\  <label for="user_account_username">Username:</label>
            \\  <input id="user_account_username" name="username" size="32" value="{f}">
            \\  <label for="user_account_password">Password:</label>
            \\  <input id="user_account_password" name="password" size="32" type="password">
            \\  <input type="submit" value="Login">
            \\</form>
            \\<a name="safe_search">Safe Search</a>
            \\<p>Filter out search results matching a defined regular expression.</p>
            \\<form action="/safe_search" method="POST" class="form">
            \\  <label for="safe_search_enabled">Enabled:</label>
            \\  <input id="safe_search_enabled" name="enabled" type="checkbox"{s}>
            \\  <label for="safe_search_regex">Regex:</label>
            \\  <input id="safe_search_regex" name="regex" size="32" value="{f}">
            \\  <input type="submit" value="Save">
            \\</form>
        , .{
            Escape{ .string = if (s.user.*) |*u| u.username else "" },
            if (if (s.safe_search.*) |*ss| ss.enabled else false) " checked" else "",
            Escape{ .string = if (s.safe_search.*) |ss| ss.regex else "xxx" },
        });
    }

    fn format(self: *const anyopaque, w: *std.Io.Writer) !void {
        try (Columns{
            .self = self,
            .formatTitleFn = &formatTitle,
            .formatTocFn = &formatToc,
            .formatMainFn = &formatMain,
        }).interface().format(w);
    }

    pub fn interface(self: *const @This()) Template {
        return .{ .self = self, .formatFn = &format };
    }
};

pub const SearchConsole = struct {
    users: *const utils.HashMap(User),
    entries: []const @import("IndexEntry.zig"),
    netlocs: []const @import("Netloc.zig"),

    fn formatTitle(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.writeAll("Search Console");
    }

    fn formatToc(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.writeAll(
            \\<li><a href="#pages">Pages</a></li>
            \\<li><a href="#submit_page">Submit Page</a></li>
            \\<li><a href="#shorten_url">Shorten URL</a></li>
            \\<li><a href="#netlocs">Netlocs</a></li>
            \\<li><a href="#verify_netloc">Verify Netloc</a></li>
        );
    }

    fn formatMain(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        try w.writeAll(
            \\<a name="pages">Pages</a>
            \\<p>These are the pages you submitted to the index or where submitted for one of your netlocs.</p>
            \\<table>
            \\  <thead>
            \\    <tr><th>URL</th><th>Added by</th><th>Public?</th><th>&nbsp;</th></tr>
            \\  </thead>
            \\  <tbody>
        );
        for (s.entries) |e| try w.print(
            \\<tr><td>{f}</td><td>{f}</td><td>{s}</td><td><a href="javascript:refresh('{s}')">Refresh</a></td></tr>
        , .{
            e.url,
            Escape{ .string = s.users.get(e.user_hash).?.username },
            if (e.public) "Yes" else "No",
            std.fmt.bytesToHex(e.hash(), .lower),
        });
        try w.writeAll(
            \\  </tbody>
            \\</table>
            \\<a name="submit_page">Submit Page</a>
            \\<p>Submit a page to be crawled and added to the search index. Enter the full URL of the page. If you select public anybody will be able to search for the page, if not only your user account will be able to find the page.</p>
            \\<form action="/submit_page" method="POST" class="form">
            \\  <label for="submit_page_public">Public:</label>
            \\  <input id="submit_page_public" name="public" type="checkbox" checked>
            \\  <label for="submit_page_url">URL:</label>
            \\  <span>http://<input id="submit_page_url" name="url" size="64"></span>
            \\  <input type="submit" value="Submit">
            \\</form>
            \\<a name="shorten_url">Shorten URL</a>
            \\<p>Input a full URL to generate an easy to remember short URL. Be careful anyone with the short URL will be able to access the long URL.</p>
            \\<form action="/shorten_url" method="POST" class="form">
            \\  <label for="shorten_url_url">URL:</label>
            \\  <span>http://<input id="shorten_url_url" name="url" size="64"></span>
            \\  <input type="submit" value="Shorten">
            \\</form>
            \\<a name="netlocs">Netlocs</a>
            \\<p>These are netlocs you verified your ownership of.</p>
            \\<table>
            \\  <thead>
            \\    <tr><th>Netloc</th><th>API key</th><th>Verification</th></tr>
            \\  </thead>
            \\  <tbody>
        );
        for (s.netlocs, 0..) |nl, i| {
            try w.print(
                \\<tr><td>{f}</td><td>{f}</td><td>
            , .{ nl, Escape{ .string = nl.api_key } });
            if (nl.verified) {
                try w.writeAll("Verified");
            } else {
                try w.print(
                    \\<form action="/token" method="POST">
                    \\  <input type="hidden" name="hash" value="{s}">
                    \\  <label for="netloc_{d}_token">Token:</label>
                    \\  <input id="netloc_{d}_token" name="token" size="32">
                    \\  <input type="submit" value="Verify">
                    \\</form>
                , .{ std.fmt.bytesToHex(nl.hash(), .lower), i, i });
            }
            try w.writeAll("</td></tr>");
        }
        try w.writeAll(
            \\  </tbody>
            \\</table>
            \\<a name="verify_netloc">Verify Netloc</a>
            \\<p>Verify the ownership of a netloc (host:port) by entering a token received in a GET request to <code>/.verify?token=&hellip;</code>. Extract the token from your access logs to complete the verification. You can set an API key that will be used with pages you submit for the netloc.</p>
            \\<form action="/verify_netloc" method="POST" class="form">
            \\  <label for="verify_netloc_netloc">Netloc:</label>
            \\  <input id="verify_netloc_netloc" name="netloc" size="32">
            \\  <label for="verify_netloc_api_key">API key:</label>
            \\  <input id="verify_netloc_api_key" name="api_key" size="32">
            \\  <input type="submit" value="Verify">
            \\</form>
        );
    }

    fn format(self: *const anyopaque, w: *std.Io.Writer) !void {
        try (Columns{
            .self = self,
            .formatTitleFn = &formatTitle,
            .formatTocFn = &formatToc,
            .formatMainFn = &formatMain,
        }).interface().format(w);
    }

    pub fn interface(self: *const @This()) Template {
        return .{ .self = self, .formatFn = &format };
    }
};

pub const Queue = struct {
    connection: *@import("Crawler.zig").Connection,

    fn formatTitle(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.writeAll("Queue");
    }

    fn formatBody(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        try w.writeAll(
            \\<table>
            \\  <thead>
            \\    <tr><th>#</th><th>Type</th><th>URL / Netloc</th></tr>
            \\  </thead>
            \\  <tbody>
        );
        var it = s.connection.queue.iter();
        var i: isize = 0;
        while (it.next()) |e| : (i += 1) try switch (e.*) {
            .crawl => |c| w.print("<tr><td>{d}</td><td>crawl</td><td>{f}</td></tr>", .{ i, c.url }),
            .verify => |v| w.print("<tr><td>{d}</td><td>verify</td><td>{f}</td></tr>", .{ i, v.netloc }),
        };
        try w.writeAll(
            \\  </tbody>
            \\</table>
        );
    }

    fn format(self: *const anyopaque, w: *std.Io.Writer) !void {
        try (Base{
            .self = self,
            .formatTitleFn = &formatTitle,
            .formatBodyFn = &formatBody,
        }).interface().format(w);
    }

    pub fn interface(self: *const @This()) Template {
        return .{ .self = self, .formatFn = &format };
    }
};

pub const Pastebin = struct {
    fn formatTitle(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.writeAll("Pastebin");
    }

    fn formatMain(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.writeAll(
            \\<p>Paste some text to be hosted on the server for a limited time.</p>
            \\<form method="POST" class="form">
            \\  <label for="title">Title:</label>
            \\  <input id="title" name="title" size="32">
            \\  <label for="text">Text:</label>
            \\  <textarea id="text" name="text" cols="64" rows="8"></textarea>
            \\  <input type="submit" value="Submit">
            \\</form>
        );
    }

    fn format(_: *const anyopaque, w: *std.Io.Writer) !void {
        try (Columns{
            .self = &{},
            .formatTitleFn = &formatTitle,
            .formatMainFn = &formatMain,
        }).interface().format(w);
    }

    pub fn interface(self: *const @This()) Template {
        return .{ .self = self, .formatFn = &format };
    }
};

pub const SearchTips = struct {
    fn formatTitle(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.writeAll("Search Tips");
    }

    fn formatToc(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.writeAll(
            \\<li><a href="#basic">Basic Search</a></li>
            \\<li><a href="#phrase">Multi-word Searches</a></li>
            \\<li><a href="#user">User Search</a></li>
            \\<li><a href="#context">See your search terms in context</a></li>
            \\<li><a href="#stemming">Stemming and Wildcards</a></li>
            \\<li><a href="#case">Does capitalization matter?</a></li>
            \\<li><a href="#lucky">I'm Feeling Lucky</a></li>
        );
    }

    fn formatMain(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.writeAll(@embedFile("static/search_tips.html"));
    }

    fn format(self: *const anyopaque, w: *std.Io.Writer) !void {
        try (Columns{
            .self = self,
            .formatTitleFn = &formatTitle,
            .formatTocFn = &formatToc,
            .formatMainFn = &formatMain,
        }).interface().format(w);
    }

    pub fn interface(self: *const @This()) Template {
        return .{ .self = self, .formatFn = &format };
    }
};

pub const Message = struct {
    title: []const u8,
    message: []const u8,
    is_error: bool,

    fn formatTitle(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        try w.writeAll(s.title);
    }

    fn formatMain(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        try w.print(
            \\<p style="padding:2pt{s}">{s}</p>
        , .{
            if (s.is_error) ";color:white;background:#d7452f" else "",
            s.message,
        });
    }

    fn format(self: *const anyopaque, w: *std.Io.Writer) !void {
        try (Columns{
            .self = self,
            .formatTitleFn = &formatTitle,
            .formatMainFn = &formatMain,
        }).interface().format(w);
    }

    pub fn interface(self: *const @This()) Template {
        return .{ .self = self, .formatFn = &format };
    }
};

pub const Paste = struct {
    paste: *const @import("Paste.zig"),

    fn formatTitle(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        try w.print("{f}", .{Escape{ .string = s.paste.title }});
    }

    fn formatBody(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        var it = std.mem.splitAny(u8, s.paste.text, "\r\n");
        while (it.next()) |l| {
            if (l.len == 0) continue;
            try w.print("<p>{f}</p>", .{Escape{ .string = l }});
        }
    }

    fn format(self: *const anyopaque, w: *std.Io.Writer) !void {
        try (Base{
            .self = self,
            .formatTitleFn = &formatTitle,
            .formatBodyFn = &formatBody,
        }).interface().format(w);
    }

    pub fn interface(self: *const @This()) Template {
        return .{ .self = self, .formatFn = &format };
    }
};

pub const Echo = struct {
    headers: *const zap.Request.HttpParamStrKVList,

    fn formatTitle(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.writeAll("Echo Testing");
    }

    fn formatBody(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        for (s.headers.items) |kv| {
            try w.print("<p>{f}: {f}</p>", .{ Escape{ .string = kv.key }, Escape{ .string = kv.value } });
        }
    }

    fn format(self: *const anyopaque, w: *std.Io.Writer) !void {
        try (Base{
            .self = self,
            .formatTitleFn = &formatTitle,
            .formatBodyFn = &formatBody,
        }).interface().format(w);
    }

    pub fn interface(self: *const @This()) Template {
        return .{ .self = self, .formatFn = &format };
    }
};

pub fn respond(alloc: std.mem.Allocator, req: *const zap.Request, template: Template) !void {
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    try template.format(&body.writer);
    try req.setContentType(.HTML);
    try req.sendBody(body.written());
}
