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

fn grep(alloc: std.mem.Allocator, cwd: std.fs.Dir, patterns: []const u8) !std.mem.SplitIterator(u8, .scalar) {
    if (patterns.len == 0) return .{
        .buffer = "",
        .index = null,
        .delimiter = '\x00',
    };
    const run_result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "/bin/grep", "-rli", patterns, "." },
        .cwd_dir = cwd,
    });
    alloc.free(run_result.stderr);
    return std.mem.splitScalar(u8, run_result.stdout, '\n');
}

pub fn performSearch(alloc: std.mem.Allocator, q: *const query.Query) !Results {
    var index = try getIndex(false);
    defer index.close();

    var timer = try std.time.Timer.start();

    var include_it = try grep(alloc, index, q.include);
    defer alloc.free(include_it.buffer);

    var exclude_it = try grep(alloc, index, q.exclude);
    defer alloc.free(exclude_it.buffer);

    const time = timer.read();

    var list: std.ArrayList(Document) = .empty;
    defer list.deinit(alloc);

    blk: while (include_it.next()) |i| {
        if (i.len == 0) continue;

        exclude_it.reset();
        while (exclude_it.next()) |e| {
            if (e.len == 0) continue;
            if (std.mem.eql(u8, i, e)) continue :blk;
        }

        const file = try index.openFile(i, .{});
        defer file.close();

        var buffer: [1024]u8 = undefined;
        var r = file.reader(&buffer);

        try r.seekBy("url:".len);
        const url = try r.interface.takeDelimiterExclusive('\n');
        try r.seekBy(1 + "title:".len);
        const title = try r.interface.takeDelimiterExclusive('\n');
        try r.seekBy(1 + "text:".len);
        const text = try r.interface.allocRemaining(alloc, .unlimited);
        errdefer alloc.free(text);

        var document = try list.addOne(alloc);
        errdefer _ = list.pop();
        document.url = try alloc.dupe(u8, url);
        errdefer alloc.free(document.url);
        document.title = try alloc.dupe(u8, title);
        errdefer alloc.free(document.title);
        document.text = text;
    }

    // TODO: sort results only keep up to 10 results

    return Results{
        .documents = try list.toOwnedSlice(alloc),
        .time = time,
        .total = list.items.len,
    };
}
