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

pub fn performSearch(alloc: std.mem.Allocator, q: *const query.Query) !Results {
    var index = try std.fs.cwd().openDir("index", .{});
    defer index.close();

    // TODO: also exclude
    var timer = try std.time.Timer.start();
    const run_result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "/bin/grep", "-r", q.include, "." },
        .cwd_dir = index,
    });
    defer {
        alloc.free(run_result.stdout);
        alloc.free(run_result.stderr);
    }
    const time = timer.read();
    std.debug.print("{s}", .{run_result.stderr});

    var filenames = try std.ArrayList([]const u8).initCapacity(alloc, 0);
    defer {
        for (filenames.items) |f| alloc.free(f);
        filenames.deinit(alloc);
    }

    var it = std.mem.splitScalar(u8, run_result.stdout, '\n');
    blk: while (it.next()) |l| {
        if (l.len == 0) continue;
        const filename = l[0..std.mem.indexOfScalar(u8, l, ':').?];
        for (filenames.items) |f| if (std.mem.eql(u8, filename, f)) continue :blk;
        try filenames.append(alloc, try alloc.dupe(u8, filename));
    }

    var list = try std.ArrayList(Document).initCapacity(alloc, 0);
    errdefer list.deinit(alloc);

    for (filenames.items) |f| {
        const file = try index.openFile(f, .{});
        defer file.close();

        var buffer: [1024]u8 = undefined;
        var r = file.reader(&buffer);

        const url = (try r.interface.takeDelimiterExclusive('\n'))["url:".len..];
        try r.seekBy(1);
        const title = (try r.interface.takeDelimiterExclusive('\n'))["title:".len..];
        try r.seekBy(1);
        // TODO: read text
        const text = "Lorem ipsum";

        var document = try list.addOne(alloc);
        document.url = try alloc.dupe(u8, url);
        document.title = try alloc.dupe(u8, title);
        document.text = try alloc.dupe(u8, text);
    }

    // TODO: sort results only keep up to 10 results

    return Results{
        .documents = try list.toOwnedSlice(alloc),
        .time = time,
        .total = list.items.len,
    };
}
