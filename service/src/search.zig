const std = @import("std");
const query = @import("query.zig");

pub fn getIndex(iterate: bool) !std.fs.Dir {
    return std.fs.cwd().openDir("index", .{ .iterate = iterate });
}

fn performGrep(alloc: std.mem.Allocator, cwd: std.fs.Dir, pattern: []const u8) ![]const u8 {
    // TODO: configure to not capture stderr?
    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "/bin/grep", "-rin", pattern, "." },
        .cwd_dir = cwd,
    });
    alloc.free(result.stderr);
    return result.stdout;
}

const PartialResult = struct {
    sha1: []const u8,
    text: []const u8,
    score: f32,

    fn add_match(self: *@This(), alloc: std.mem.Allocator, text: []const u8) !void {
        if (self.text.len < text.len) {
            alloc.free(self.text);
            self.text = try alloc.dupe(u8, text);
        }
        self.score += std.math.pow(f32, @floatFromInt(text.len), 1/3);
    }

    fn order(self: *const @This(), other: *const @This()) std.math.Order {
        return std.math.order(self.score, other.score).invert();
    }

    fn clone(self: *const @This(), alloc: std.mem.Allocator) !@This() {
        const sha1 = try alloc.dupe(u8, self.sha1);
        errdefer alloc.free(sha1);

        const text = try alloc.dupe(u8, self.text);
        errdefer alloc.free(text);

        return .{
            .sha1 = sha1,
            .text = text,
            .score = self.score,
        };
    }

    fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(self.sha1);
        alloc.free(self.text);
        self.* = undefined;
    }
};

fn aggregatePartialResults(alloc: std.mem.Allocator, stdout: []const u8) !std.StringHashMap(PartialResult) {
    var results: std.StringHashMap(PartialResult) = .init(alloc);
    errdefer {
        var it = results.iterator();
        while (it.next()) |e| e.value_ptr.deinit(alloc);
        results.deinit();
    }

    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |l| {
        if (l.len == 0) continue;

        var split = std.mem.splitScalar(u8, l, ':');

        const sha1 = try alloc.dupe(u8, split.next().?["./".len..]);
        errdefer alloc.free(sha1);

        const line = try std.fmt.parseInt(usize, split.next().?, 10);
        if (line <= 2) {
            alloc.free(sha1);
            continue;
        }

        const text = try alloc.dupe(u8, split.next().?);
        errdefer alloc.free(text);

        const result = try results.getOrPut(sha1);
        if (result.found_existing) {
            defer {
                alloc.free(sha1);
                alloc.free(text);
            }
            try result.value_ptr.add_match(alloc, text);
        } else {
            result.key_ptr.* = sha1;
            result.value_ptr.sha1 = sha1;
            result.value_ptr.text = text;
            result.value_ptr.score = 0;
        }
    }

    return results;
}

fn getTop10PartialResults(alloc: std.mem.Allocator, results: std.StringHashMap(PartialResult)) ![]const *const PartialResult {
    var buffer: [10]*const PartialResult = undefined;
    var top10Results: std.ArrayList(*const PartialResult) = .initBuffer(&buffer);

    var it = results.iterator();
    while (it.next()) |e| {
        const i = std.sort.upperBound(*const PartialResult, top10Results.items, e.value_ptr, PartialResult.order);

        if (i == top10Results.capacity) continue;

        if (top10Results.items.len == top10Results.capacity) {
            _ = top10Results.pop();
        }

        top10Results.insertAssumeCapacity(i, e.value_ptr);
    }

    return try alloc.dupe(*const PartialResult, top10Results.items);
}

const Result = struct {
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

fn readIndexData(alloc: std.mem.Allocator, cwd: std.fs.Dir, sha1: []const u8) !struct {
    url: []const u8,
    title: []const u8,

    fn deinit(self: *@This(), inner_alloc: std.mem.Allocator) void {
        inner_alloc.free(self.url);
        inner_alloc.free(self.title);
        self.* = undefined;
    }
} {
    const content = blk: {
        const file = try cwd.openFile(sha1, .{});
        defer file.close();

        var reader = file.reader(&.{});

        var content: std.ArrayList(u8) = try .initCapacity(alloc, 32);
        defer content.deinit(alloc);

        while (true) {
            content.items.len += try reader.interface.readSliceShort(content.unusedCapacitySlice());
            if (std.mem.containsAtLeastScalar(u8, content.items, 2, '\n')) break;
            if (content.items.len < content.capacity) return error.InvalidIndexFileFormat;
            try content.ensureUnusedCapacity(alloc, 1);
        }

        break :blk try content.toOwnedSlice(alloc);
    };
    defer alloc.free(content);

    var it = std.mem.splitScalar(u8, content, '\n');

    const url = try alloc.dupe(u8, it.next().?);
    errdefer alloc.free(url);

    const title = try alloc.dupe(u8, it.next().?);
    errdefer alloc.free(title);

    return .{ .url = url, .title = title };
}

fn loadAdditionalResultData(alloc: std.mem.Allocator, cwd: std.fs.Dir, partial_results: []const *const PartialResult) ![]Result {
    var results: std.ArrayList(Result) = .empty;
    errdefer for (results.items) |*r| r.deinit(alloc);
    defer results.deinit(alloc);

    for (partial_results) |r| {
        var data = try readIndexData(alloc, cwd, r.sha1);
        errdefer data.deinit(alloc);

        const text = try alloc.dupe(u8, r.text);
        errdefer alloc.free(text);

        try results.append(alloc, .{
            .url = data.url,
            .title = data.title,
            .text = text,
        });
    }

    return try results.toOwnedSlice(alloc);
}

pub const Results = struct {
    results: []Result,
    time: u64,
    total: usize,

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        for (self.results) |*r| r.deinit(alloc);
        self.* = undefined;
    }
};

pub fn performSearch(alloc: std.mem.Allocator, pattern: []const u8) !Results {
    var timer = try std.time.Timer.start();

    var cwd = try getIndex(false);
    defer cwd.close();

    const stdout = try performGrep(alloc, cwd, pattern);
    defer alloc.free(stdout);

    var partial_results = try aggregatePartialResults(alloc, stdout);
    defer {
        var it = partial_results.iterator();
        while (it.next()) |e| e.value_ptr.deinit(alloc);
        partial_results.deinit();
    }

    const top10_partial_results = try getTop10PartialResults(alloc, partial_results);
    defer alloc.free(top10_partial_results);

    const results = try loadAdditionalResultData(alloc, cwd, top10_partial_results);
    errdefer {
        for (results) |d| d.deinit(alloc);
        alloc.free(results);
    }

    return .{
        .results = results,
        .time = timer.read(),
        .total = partial_results.count(),
    };
}
