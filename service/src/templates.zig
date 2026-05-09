const httpz = @import("httpz");
const preferences = @import("preferences.zig");
const search = @import("search.zig");
const std = @import("std");

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
            \\<html land="en">
            \\<head>
            \\  <meta charset="UTF-8">
            \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \\  <title>{f}</title>
            \\  <style>
            \\    *{{box-sizing:border-box}}
            \\    body{{font-family:Arial,sans-serif}}
            \\    .form{{display:grid;grid-template-columns:repeat(2,min-content);justify-items:flex-start;gap:.25rem;margin:1rem 0}}
            \\    .form>[type="submit"]{{grid-column:1/3}}
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
            \\    <p><b>Table of Contents</b></p>
            \\    <ul style="display:flex;flex-direction:column;gap:.5rem;padding-left:1.5rem">{f}</ul>
        , .{Template{ .self = s.self, .formatFn = f }});
    }

    fn formatBody(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        try w.print(
            \\<div style="display:grid;grid-template:5rem auto/12.5rem 67rem;gap:.5rem;align-items:center">
            \\  <a href="/"><img src="/static/logo.gif" border="0" width="200" height="78" alt="Greple"></a>
            \\  {f}
            \\  <div style="font-size:small;align-self:start;margin-top:1rem;margin-left:.5rem">
            \\    <div style="display:flex;flex-direction:column;gap:.5rem">
            \\      <a href="/">Home</a>
            \\      <a href="/console">Search Console</a>
            \\      <a href="/preferences">Preferences</a>
            \\      <a href="/help">Search Tips</a>
            \\    </div>
            \\    {f}
            \\  </div>
            \\  <div style="align-self:start">{f}</div>
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
            \\    <small>Results <b>{d} - {d}</b> of about <b>{d}</b>. Search took <b>{d:.2}</b> seconds.</small>
            \\  </div>
            \\</div>
        , .{
            Escape{ .string = s.q },
            Escape{ .string = s.q },
            @min(s.results.results.len, 1),
            s.results.results.len,
            s.results.total,
            @as(f32, @floatFromInt(s.results.time)) / 1e9,
        });
    }

    fn formatMain(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        for (s.results.results) |d| try w.print(
            \\<p>
            \\  <a href="http://{f}">{f}</a>
            \\  <small style="-webkit-box-orient: vertical; -webkit-line-clamp: 3; display: -webkit-box; overflow: hidden; text-overflow: ellipsis; width: 32rem">{f}</small>
            \\  <small><font color="green">{f}</font></small>
            \\</p>
        , .{
            Escape{ .string = d.url.? },
            Escape{ .string = d.title.? },
            Escape{ .string = d.text },
            Escape{ .string = d.url.? },
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
    prefs: *const preferences.Preferences,

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
            \\<form method="POST">
            \\  <a name="user_account"><b>User Account</b></a>
            \\  <p>Login into a Greple account to access the search console. If you don't have an account, use the same form to register.</p>
            \\  <div class="form">
            \\    <label for="user">Username:</label>
            \\    <input id="user" name="user" size="32" value="{f}">
            \\    <label for="password">Password:</label>
            \\    <input id="password" name="password" size="32" type="password">
            \\  </div>
            \\  <a name="safe_search"><b>Safe Search</b></a>
            \\  <p>Filter out search results matching a defined regular expression.</p>
            \\  <div class="form">
            \\    <label for="safe_search_enabled">Enabled:</label>
            \\    <input id="safe_search_enabled" type="checkbox" name="safe_search_enabled"{s}>
            \\    <label for="safe_search_regex">Regex:</label>
            \\    <input id="safe_search_regex" name="safe_search_regex" size="32" value="{f}">
            \\  </div>
            \\  <p><input type="submit" value="Save"></p>
            \\</form>
        , .{
            Escape{ .string = s.prefs.user },
            if (s.prefs.safe_search_enabled) " checked" else "",
            Escape{ .string = s.prefs.safe_search_regex },
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
    fn formatTitle(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.writeAll("Search Console");
    }

    fn formatTOC(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.writeAll(
            \\<li><a href="#domains">Domains</a></li>
            \\<li><a href="#register">Register Domain</a></li>
            \\<li><a href="#submit">Submit Page</a></li>
            \\<li><a href="#url">URL Shortener</a></li>
        );
    }

    fn formatMain(_: *const anyopaque, w: *std.Io.Writer) !void {
        // TODO: fix duplicate form field name
        try w.writeAll(
            \\<a name="domains"><b>Domains</b></a>
            \\<p>TODO Your domains</p>
            \\<a name="register"><b>Register Domain</b></a>
            \\<p>TODO Register a domain</p>
            \\<a name="submit"><b>Submit Page</b></a>
            \\<p>Submit a page to be crawled and added to the search index.</p>
            \\<form method="POST" class="form">
            \\  <label for="public">Public:</label>
            \\  <input id="public" name="public" type="checkbox" checked>
            \\  <label for="url">URL:</label>
            \\  <input id="url" name="url" size="32">
            \\  <input type="hidden" name="title" value="Lorem ipsum">
            \\  <input type="hidden" name="text" value="Lorem ipsum dolor sit amet, consetetur sadipscing elitr, sed diam nonumy eirmod tempor invidunt ut labore et dolore magna aliquyam erat, sed diam voluptua. At vero eos et accusam et justo duo dolores et ea rebum. Stet clita kasd gubergren, no sea takimata sanctus est Lorem ipsum dolor sit amet.">
            \\  <input type="submit" name="form_submit" value="Submit">
            \\</form>
            \\<a name="url"><b>URL Shortener</b></a>
            \\<p>Input an URL to generate an easy to remember short URL.</p>
            \\<form method="POST" class="form">
            \\  <label for="url">URL:</label>
            \\  <input id="url" name="url" size="32">
            \\  <input type="submit" name="form_url" value="Shorten">
            \\</form>
        );
    }

    fn format(_: *const anyopaque, w: *std.Io.Writer) !void {
        try (Columns{
            .self = &{},
            .formatTitleFn = &formatTitle,
            .formatTOCFn = &formatTOC,
            .formatMainFn = &formatMain,
        }).interface().format(w);
    }

    pub fn interface(_: *const @This()) Template {
        return Template{ .self = &{}, .formatFn = &format };
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
