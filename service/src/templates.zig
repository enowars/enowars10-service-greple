const httpz = @import("httpz");
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

const Fmt = struct {
    self: *const anyopaque,
    formatFn: *const fn (self: *const anyopaque, w: *std.Io.Writer) std.Io.Writer.Error!void,

    pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
        try self.formatFn(self.self, w);
    }
};

const Template = struct {
    self: *const anyopaque,
    formatTitleFn: *const fn (self: *const anyopaque, w: *std.Io.Writer) std.Io.Writer.Error!void,
    formatBodyFn: *const fn (self: *const anyopaque, w: *std.Io.Writer) std.Io.Writer.Error!void,

    fn format(self: *const @This(), w: *std.Io.Writer) !void {
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
            \\    a.l{{color:#6f6f6f}}
            \\  </style>
            \\</head>
            \\<body bgcolor="#ffffff" text="#000000" link="#0000cc" vlink="#551A8B" alink="#ff0000">{f}</body>
            \\</html>
        , .{
            Fmt{ .self = self.self, .formatFn = self.formatTitleFn },
            Fmt{ .self = self.self, .formatFn = self.formatBodyFn },
        });
    }
};

pub const Index = struct {
    fn formatTitle(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.writeAll("Greple");
    }

    fn formatBody(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.print(
            \\<div style="display: flex; flex-direction: column; align-items: center; gap: 1rem; max-width: 80rem">
            \\  <img width="300" height="117" src="/static/logo.gif" border="0" alt="Greple">
            \\  <small>Search {d} web pages</small>
            \\  <form action="/search" method="GET" style="display: flex; gap: .5rem; flex-direction: column; width: fit-content">
            \\    <input type="text" value="" name="q" size="55">
            \\    <div style="display: flex; gap: .25rem; justify-content: center">
            \\      <input name="btnG" type="submit" value="Greple Search">
            \\      <input name="btnI" type="submit" value="I'm Feeling Lucky">
            \\    </div>
            \\  </form>
            \\</div>
        , .{search.index.len});
    }

    pub fn interface(self: *const @This()) Template {
        return Template{
            .self = self,
            .formatTitleFn = &formatTitle,
            .formatBodyFn = &formatBody,
        };
    }
};

pub const Search = struct {
    q: []const u8,
    results: *const search.Results,

    fn formatTitle(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        try w.print("Greple Search: {f}", .{Escape{ .string = s.q }});
    }

    fn formatBody(self: *const anyopaque, w: *std.Io.Writer) !void {
        const s: *const @This() = @ptrCast(@alignCast(self));
        try w.print(
            \\<div style="display: flex; align-items: center; max-width: 80rem; gap: .5rem">
            \\  <a href="/"><img src="/static/logo.gif" border="0" width="200" height="78" alt="Greple"></a>
            \\  <div style="display: flex; flex-direction: column; gap: 1rem; width: fit-content">
            \\    <a href="/help" style="font-size: small; margin-left: 1rem; width: fit-content">Search Tips</a>
            \\    <form action="/search" style="display: flex; gap: .25rem">
            \\      <input type="text" name="q" size="31" value="{f}">
            \\      <input type="submit" name="btnG" value="Greple Search">
            \\      <input type="submit" name="btnI" value="I'm Feeling Lucky"><br>
            \\    </form>
            \\  </div>
            \\</div>
            \\<div style="padding: 2pt; color: white; background: #3366cc; max-width: 80rem; display: flex; justify-content: space-between">
            \\  <small>Searched the web for <b>{f}</b>.</small>
            \\  <small>Results <b>1 - {d}</b> of <b>{d}</b>. Search took <b>{d:.2}</b> seconds.</small>
            \\</div>
        , .{
            Escape{ .string = s.q },
            Escape{ .string = s.q },
            s.results.documents.len,
            s.results.total,
            @as(f32, @floatFromInt(s.results.time)) / 1e9,
        });
        for (s.results.documents) |d| try w.print(
            \\<p>
            \\  <a href="http://{f}">{f}</a>
            \\  <small>
            \\    <br>
            \\    {f}<br>
            \\    {f}<br>
            \\    <font color="green">{f}</font>
            \\  </small>
            \\</p>
        , .{
            Escape{ .string = d.url },
            Escape{ .string = d.title },
            Escape{ .string = d.text[0..80] },
            Escape{ .string = d.text[80..160] },
            Escape{ .string = d.url },
        });
    }

    pub fn interface(self: *const @This()) Template {
        return Template{
            .self = self,
            .formatTitleFn = &formatTitle,
            .formatBodyFn = &formatBody,
        };
    }
};

pub const Help = struct {
    fn formatTitle(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.writeAll("Grepl Search Tips");
    }

    fn formatBody(_: *const anyopaque, w: *std.Io.Writer) !void {
        try w.writeAll(@embedFile("static/help.html"));
    }

    pub fn interface(self: *const @This()) Template {
        return Template{
            .self = self,
            .formatTitleFn = &formatTitle,
            .formatBodyFn = &formatBody,
        };
    }
};

pub fn respond(res: *httpz.Response, template: Template) !void {
    res.status = 200;
    res.headers.add("Content-Type", "text/html");
    try template.format(res.writer());
}
