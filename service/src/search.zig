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

pub fn performSearch(alloc: std.mem.Allocator, q: *const query.Query) !Results {
    var index = try getIndex(false);
    defer index.close();

    // TODO: also exclude
    var timer = try std.time.Timer.start();
    const run_result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "/bin/grep", "-rl", q.include, "." },
        .cwd_dir = index,
    });
    defer {
        alloc.free(run_result.stdout);
        alloc.free(run_result.stderr);
    }
    const time = timer.read();
    std.debug.print("{s}", .{run_result.stderr});

    var list: std.ArrayList(Document) = .empty;
    defer list.deinit(alloc);

    var it = std.mem.splitScalar(u8, run_result.stdout, '\n');
    while (it.next()) |l| {
        if (l.len == 0) continue;
        const file = try index.openFile(l, .{});
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
