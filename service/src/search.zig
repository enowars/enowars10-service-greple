const std = @import("std");
const query = @import("query.zig");

const Document = struct {
    url: []const u8,
    title: []const u8,
    text: []const u8,
};

pub const index = blk: {
    @setEvalBranchQuota(1e6);

    const index_bin = @embedFile("index.bin");

    const index_size = std.mem.readInt(i32, index_bin[0..4], .big);

    var ind: [index_size]Document = undefined;
    var it = std.mem.splitScalar(u8, index_bin[4..], 0);
    for (0..index_size) |i| {
        ind[i].url = it.next().?;
        ind[i].title = it.next().?;
        ind[i].text = it.next().?;
    }
    break :blk ind;
};

const DocumentPtrWithScore = struct {
    document: *const Document,
    score: u32,

    fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
        return lhs.score > rhs.score;
    }
};

pub const Results = struct {
    documents: []const *const Document,
    time: u64,
    total: usize,
};

pub fn performSearch(alloc: std.mem.Allocator, q: *const query.Query) !Results {
    var timer = try std.time.Timer.start();

    const results = blk: {
        var list = try std.ArrayList(DocumentPtrWithScore).initCapacity(alloc, 0);
        defer list.deinit(alloc);

        for (&index) |*document| if (try q.match(alloc, document.text)) |s| {
            try list.append(alloc, .{ .document = document, .score = s });
        };

        std.mem.sort(DocumentPtrWithScore, list.items, {}, DocumentPtrWithScore.lessThan);

        var results = try std.ArrayList(*const Document).initCapacity(alloc, list.items.len);
        errdefer list.deinit(alloc);

        for (list.items) |i| results.appendAssumeCapacity(i.document);

        break :blk try results.toOwnedSlice(alloc);
    };

    return Results{
        .documents = results[0..@min(10, results.len)],
        .time = timer.read(),
        .total = results.len,
    };
}
