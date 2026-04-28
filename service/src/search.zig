const std = @import("std");
const query = @import("query.zig");

const Document = struct {
    url: []const u8,
    title: []const u8,
    text: []const u8,

    fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(self.url);
        alloc.free(self.title);
        alloc.free(self.text);
        self.* = undefined;
    }
};

pub const Results = struct {
    documents: []Document,
    time: u64,
    total: usize,

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        for (self.documents) |*d| d.deinit(alloc);
        alloc.free(self.documents);
        self.* = undefined;
    }
};

pub fn getIndex(iterate: bool) !std.fs.Dir {
    return std.fs.cwd().openDir("index", .{ .iterate = iterate });
}

fn grep(alloc: std.mem.Allocator, cwd: std.fs.Dir, pattern: []const u8) !std.mem.SplitIterator(u8, .scalar) {
    if (pattern.len == 0) return .{
        .buffer = "",
        .index = null,
        .delimiter = '\x00',
    };
    const run_result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "/bin/grep", "-rli", pattern, "." },
        .cwd_dir = cwd,
    });
    alloc.free(run_result.stderr);
    return std.mem.splitScalar(u8, run_result.stdout, '\n');
}

pub fn performSearch(alloc: std.mem.Allocator, q: *const query.Query) !Results {
    std.debug.assert(q.patterns.len > 0);
    std.debug.assert(q.patterns[0].kind == .include);

    var index = try getIndex(false);
    defer index.close();

    var filenames: std.StringHashMap(void) = .init(alloc);
    defer filenames.deinit();

    var timer = try std.time.Timer.start();

    var first_grep = try grep(alloc, index, q.patterns[0].pattern);
    defer alloc.free(first_grep.buffer);
    while (first_grep.next()) |f| if (f.len != 0) try filenames.put(f, {});

    for (q.patterns[1..]) |p| {
        var next_grep = try grep(alloc, index, p.pattern);
        defer alloc.free(next_grep.buffer);

        switch (p.kind) {
            .include => {
                var to_remove: std.StringHashMap(void) = try filenames.clone();
                defer to_remove.deinit();
                while (next_grep.next()) |f| _ = to_remove.remove(f);
                var it = to_remove.keyIterator();
                while (it.next()) |f| _ = filenames.remove(f.*);
            },
            .exclude => while (next_grep.next()) |f| {
                _ = filenames.remove(f);
            },
        }
    }

    var list: std.ArrayList(Document) = .empty;
    defer list.deinit(alloc);

    var it = filenames.keyIterator();
    while (it.next()) |f| {
        const file = try index.openFile(f.*, .{});
        defer file.close();

        var buffer: [1024]u8 = undefined;
        var r = file.reader(&buffer);

        try r.seekBy("url:".len);
        const url = try alloc.dupe(u8, try r.interface.takeDelimiterExclusive('\n'));
        errdefer alloc.free(url);

        try r.seekBy(1 + "title:".len);
        const title = try alloc.dupe(u8, try r.interface.takeDelimiterExclusive('\n'));
        errdefer alloc.free(title);

        try r.seekBy(1 + "text:".len);
        const text = try r.interface.allocRemaining(alloc, .unlimited);
        errdefer alloc.free(text);

        try list.append(alloc, .{ .url = url, .title = title, .text = text });
    }

    // TODO: sort results only keep up to 10 results

    return Results{
        .documents = try list.toOwnedSlice(alloc),
        .time = timer.read(),
        .total = list.items.len,
    };
}
