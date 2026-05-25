const Domain = @import("domain.zig");
const httpz = @import("httpz");
const SafeSearch = @import("safe_search.zig");
const search = @import("search.zig");
const std = @import("std");
const User = @import("user.zig");
const utils = @import("utils.zig");

const Escape = struct {
    string: []const u8,

    pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
        for (self.string) |c| try w.writeAll(switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => &.{c},
        });
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
            \\    body{{font-family:Arial,sans-serif}}
            \\    .form{{display:grid;grid-template-columns:repeat(2,max-content);justify-items:flex-start;gap:.5rem;margin:1rem 0}}
            \\    .form>[type="submit"]{{grid-column:1/3}}
            \\    a[name]{{display:block;font-weight:bold;margin-top:2.5rem}}
            \\    a[name]:first-child{{margin-top:unset}}
            \\  </style>
            \\</head>
            \\<body bgcolor="#ffffff" text="#000000" link="#0000cc" vlink="#551A8B" alink="#ff0000">{f}</body>
            \\</html>
        , .{
            Template{ .self = s.self, .formatFn = s.formatTitleFn },
            Template{ .self = s.self, .formatFn = s.formatBodyFn },
        });
    }

    fn interface(self: *const @This()) Template {
        return Template{ .self = self, .formatFn = &format };
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
            \\  <img width="300" height="117" src="/static/logo.gif" border="0" alt="Greple">
            \\  <small>Search {d} web pages</small>
            \\  <form action="/search" method="GET" style="display: flex; gap: .5rem; flex-direction: column; width: fit-content">
            \\    <input type="text" value="" name="q" size="50">
            \\    <div style="display: flex; gap: .25rem; justify-content: center">
            \\      <input name="btnG" type="submit" value="Greple Search">
            \\      <input name="btnI" type="submit" value="I'm Feeling Lucky">
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
        return Template{ .self = self, .formatFn = &format };
    }
};

const Columns = struct {
    self: *const anyopaque,
    formatTitleFn: *const fn (self: *const anyopaque, w: *std.Io.Writer) std.Io.Writer.Error!void,
    formatHeaderFn: ?*const fn (self: *const anyopaque, w: *std.Io.Writer) std.Io.Writer.Error!void = null,
    formatTOCFn: ?*const fn (self: *const anyopaque, w: *std.Io.Writer) std.Io.Writer.Error!void = null,
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

    fn formatTOC(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        if (s.formatTOCFn) |f| try w.print(
            \\<p><b>Table of Contents</b></p>
            \\<ul style="display:flex;flex-direction:column;gap:.5rem;padding-left:1.5rem">{f}</ul>
        , .{Template{ .self = s.self, .formatFn = f }});
    }

    fn formatBody(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        try w.print(
            \\<div style="display:grid;grid-template:5rem auto/12.5rem 67rem;gap:.5rem;align-items:center">
            \\  <a href="/"><img src="/static/logo.gif" border="0" width="200" height="78" alt="Greple"></a>
            \\  {f}
            \\  <div style="font-size:small;align-self:start;margin-top:1rem;margin-left:.5rem">
            \\    <nav style="display:flex;flex-direction:column;gap:.5rem;align-items:start">
            \\      <a href="/">Home</a>
            \\      <a href="/console">Search Console</a>
            \\      <a href="/preferences">Preferences</a>
            \\      <a href="/help">Search Tips</a>
            \\    </nav>
            \\    {f}
            \\  </div>
            \\  <main style="align-self:start">{f}</main>
            \\</div>
        , .{
            Template{ .self = self, .formatFn = formatHeader },
            Template{ .self = self, .formatFn = formatTOC },
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
        return Template{ .self = self, .formatFn = &format };
    }
};

pub const Search = struct {
    q: []const u8,
    results: *const search.Results,

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
            \\    <input type="submit" name="btnG" value="Greple Search">
            \\    <input type="submit" name="btnI" value="I'm Feeling Lucky"><br>
            \\  </form>
            \\  <div style="padding:2pt;color:white;background:#3366cc;display:flex;justify-content:space-between">
            \\    <small>Searched the web for <b>{f}</b>.</small>
            \\    <small>Results <b>{d} - {d}</b> of {s}<b>{d}</b>. Search took <b>{d:.3}</b> seconds.</small>
            \\  </div>
            \\</div>
        , .{
            Escape{ .string = s.q },
            Escape{ .string = s.q },
            @min(s.results.results.len, 1),
            s.results.results.len,
            if (s.results.total > s.results.results.len) " about" else "",
            s.results.total,
            @as(f32, @floatFromInt(s.results.time)) / 1e9,
        });
    }

    fn formatMain(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        for (s.results.results) |r| try w.print(
            \\<p>
            \\  <a href="http://{d}.{d}.{d}.{d}:{d}{f}">{f}</a>
            \\  <small style="-webkit-box-orient: vertical; -webkit-line-clamp: 3; display: -webkit-box; overflow: hidden; text-overflow: ellipsis; width: 32rem">{f}</small>
            \\  <small><font color="green">{f}{f}</font></small>
            \\</p>
        , .{
            r.domain.?.ipv4[0],
            r.domain.?.ipv4[1],
            r.domain.?.ipv4[2],
            r.domain.?.ipv4[3],
            r.domain.?.port,
            Escape{ .string = r.path.? },
            Escape{ .string = r.title.? },
            Escape{ .string = r.text },
            Escape{ .string = r.domain.?.domain },
            Escape{ .string = r.path.? },
        });
        if (s.results.filtered > 0) try w.print(
            \\<p style="font-size: small">We have removed {d} results from this
            \\page because they were filtered out by your safe search settings.
            \\If you wish to see these results, you can adjust your filter
            \\settings in your search preferences.</p>
        , .{s.results.filtered});
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
        return Template{ .self = self, .formatFn = &format };
    }
};

pub const Preferences = struct {
    user: ?User,
    safe_search: SafeSearch,

    fn formatTitle(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.writeAll("Preferences");
    }

    fn formatTOC(_: *const anyopaque, w: *std.Io.Writer) !void {
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
            \\<form method="POST" class="form">
            \\  <label for="user_account_username">Username:</label>
            \\  <input id="user_account_username" name="username" size="32" value="{f}">
            \\  <label for="user_account_password">Password:</label>
            \\  <input id="user_account_password" name="password" size="32" type="password">
            \\  <input type="submit" name="form_user_account" value="Login">
            \\</form>
            \\<a name="safe_search">Safe Search</a>
            \\<p>Filter out search results matching a defined regular expression.</p>
            \\<form method="POST" class="form">
            \\  <label for="safe_search_enabled">Enabled:</label>
            \\  <input id="safe_search_enabled" name="enabled" type="checkbox"{s}>
            \\  <label for="safe_search_regex">Regex:</label>
            \\  <input id="safe_search_regex" name="regex" size="32" value="{f}">
            \\  <input type="submit" name="form_safe_search" value="Save">
            \\</form>
        , .{
            Escape{ .string = if (s.user) |u| u.username else "" },
            if (s.safe_search.enabled) " checked" else "",
            Escape{ .string = s.safe_search.regex },
        });
    }

    fn format(self: *const anyopaque, w: *std.Io.Writer) !void {
        try (Columns{
            .self = self,
            .formatTitleFn = &formatTitle,
            .formatTOCFn = &formatTOC,
            .formatMainFn = &formatMain,
        }).interface().format(w);
    }

    pub fn interface(self: *const @This()) Template {
        return Template{ .self = self, .formatFn = &format };
    }
};

pub const SearchConsole = struct {
    domains: []const Domain,

    fn formatTitle(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.writeAll("Search Console");
    }

    fn formatTOC(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.writeAll(
            \\<li><a href="#domains">Domains</a></li>
            \\<li><a href="#register_domain">Register Domain</a></li>
            \\<li><a href="#submit_page">Submit Page</a></li>
            \\<li><a href="#shorten_url">Shorten URL</a></li>
        );
    }

    fn formatDomainsTable(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        for (s.domains) |*d| {
            try w.print(
                \\<span>{f}</span>
                \\<span>{d}.{d}.{d}.{d}</span>
                \\<span>{d}</span>
            , .{
                Escape{ .string = d.domain },
                d.ipv4[0],
                d.ipv4[1],
                d.ipv4[2],
                d.ipv4[3],
                d.port,
            });
        }
    }

    fn formatDomainsSelect(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        for (s.domains) |*d| {
            try w.print(
                \\<option value="{s}">{f}</option>
            , .{
                std.fmt.bytesToHex(d.hash, .lower),
                Escape{ .string = d.domain },
            });
        }
    }

    fn formatMain(s: *const anyopaque, w: *std.Io.Writer) !void {
        try w.print(
            \\<a name="domains">Domains</a>
            \\<p>These domains are registered to your user account.</p>
            \\<div style="display:grid;grid-template-columns:repeat(3,max-content);row-gap:.25rem;column-gap:.5rem">
            \\  <u>Domain</u>
            \\  <u>IPv4</u>
            \\  <u>HTTP-Port</u>
            \\  {f}
            \\</div>
            \\<a name="register_domain">Register Domain</a>
            \\<p>You can register a domain name with an associated IPv4 address and HTTP port number. Registering a domain allows you to submit pages from the domain to the search index. You need to verify the ownership of the IPv4 through a challenge.</p>
            \\<form method="POST" class="form">
            \\  <label for="register_domain_domain">Domain:</label>
            \\  <input id="register_domain_domain" name="domain" size="32">
            \\  <label for="register_domain_ipv4">IPv4:</label>
            \\  <input id="register_domain_ipv4" name="ipv4" size="32">
            \\  <label for="register_domain_port">Port:</label>
            \\  <input id="register_domain_port" name="port" type="number" value="80">
            \\  <input type="submit" name="form_register_domain" value="Register">
            \\</form>
            \\<a name="submit_page">Submit Page</a>
            \\<p>Submit a page to be crawled and added to the search index. If you select public anybody will be able to search for the page, if not only your user account will be able to find the page.</p>
            \\<form method="POST" class="form">
            \\  <label for="submit_page_public">Public:</label>
            \\  <input id="submit_page_public" name="public" type="checkbox" checked>
            \\  <label for="submit_page_domain">Domain:</label>
            \\  <select id="submit_page_domain" name="domain">{f}</select>
            \\  <label for="submit_page_path">Path:</label>
            \\  <input id="submit_page_path" name="path" size="32" value="/">
            \\  <label for="submit_page_title">Title:</label>
            \\  <input id="submit_page_title" name="title" size="32">
            \\  <label for="submit_page_text">Text:</label>
            \\  <textarea id="submit_page_text" name="text" cols="64" rows="8"></textarea>
            \\  <input type="submit" name="form_submit_page" value="Submit">
            \\</form>
            \\<a name="shorten_url">Shorten URL</a>
            \\<p>Input an path under one of your domains to generate an easy to remember short URL. Be careful anyone with the short URL will be able to access the long URL.</p>
            \\<form method="POST" class="form">
            \\  <label for="shorten_url_domain">Domain:</label>
            \\  <select id="shorten_url_domain" name="domain">{f}</select>
            \\  <label for="shorten_url_path">Path:</label>
            \\  <input id="shorten_url_path" name="path" size="32" value="/">
            \\  <input type="submit" name="form_shorten_url" value="Shorten">
            \\</form>
        , .{
            Template{ .self = s, .formatFn = &formatDomainsTable },
            Template{ .self = s, .formatFn = &formatDomainsSelect },
            Template{ .self = s, .formatFn = &formatDomainsSelect },
        });
    }

    fn format(self: *const anyopaque, w: *std.Io.Writer) !void {
        try (Columns{
            .self = self,
            .formatTitleFn = &formatTitle,
            .formatTOCFn = &formatTOC,
            .formatMainFn = &formatMain,
        }).interface().format(w);
    }

    pub fn interface(self: *const @This()) Template {
        return Template{ .self = self, .formatFn = &format };
    }
};

pub const SearchTips = struct {
    fn formatTitle(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.writeAll("Search Tips");
    }

    fn formatTOC(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.writeAll(
            \\<li><a href="#basic">Basic Search</a></li>
            \\<li><a href="#and">Automatic "and" Queries</a></li>
            \\<li><a href="#stopwords">What is a stopword?</a></li>
            \\<li><a href="#context">See your search terms in context</a></li>
            \\<li><a href="#stemming">Does Greple use stemming?</a></li>
            \\<li><a href="#case">Does capitalization matter?</a></li>
        );
    }

    fn formatMain(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.writeAll(@embedFile("static/search_tips.html"));
    }

    fn format(self: *const anyopaque, w: *std.Io.Writer) !void {
        try (Columns{
            .self = self,
            .formatTitleFn = &formatTitle,
            .formatTOCFn = &formatTOC,
            .formatMainFn = &formatMain,
        }).interface().format(w);
    }

    pub fn interface(self: *const @This()) Template {
        return Template{ .self = self, .formatFn = &format };
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
        return Template{ .self = self, .formatFn = &format };
    }
};

pub fn respond(res: *httpz.Response, template: Template) !void {
    res.status = 200;
    res.content_type = .HTML;
    try template.format(res.writer());
}
