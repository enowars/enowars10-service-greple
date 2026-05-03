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
    return result.stdout;
}

const PartialResult = struct {
    sha1: []const u8,
    text: []const u8,
    score: f32,

    fn add_match(self: *@This(), text: []const u8) void {
        if (self.text.len < text.len) self.text = text;
        self.score += std.math.pow(f32, @floatFromInt(text.len), 1 / 3);
    }

    fn order(self: *const @This(), other: *const @This()) std.math.Order {
        return std.math.order(self.score, other.score).invert();
    }
};

fn aggregatePartialResults(alloc: std.mem.Allocator, stdout: []const u8) !std.StringHashMap(PartialResult) {
    var results: std.StringHashMap(PartialResult) = .init(alloc);
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |l| {
        if (l.len == 0) continue;

        var split = std.mem.splitScalar(u8, l, ':');
        const sha1 = split.next().?["./".len..];
        const line = try std.fmt.parseInt(usize, split.next().?, 10);
        if (line <= 2) continue;
        const text = split.next().?;

        const result = try results.getOrPut(sha1);
        if (result.found_existing) {
            result.value_ptr.add_match(text);
        } else {
            result.key_ptr.* = sha1;
            result.value_ptr.sha1 = sha1;
            result.value_ptr.text = text;
            result.value_ptr.score = 0;
        }
    }
    return results;
}

fn getTop10PartialResults(
    alloc: std.mem.Allocator,
    results: std.StringHashMap(PartialResult),
) ![]const *const PartialResult {
    var top10Results: std.ArrayList(*const PartialResult) = try .initCapacity(alloc, @min(10, results.count()));
    var it = results.iterator();
    while (it.next()) |e| {
        const i = std.sort.upperBound(
            *const PartialResult,
            top10Results.items,
            e.value_ptr,
            PartialResult.order,
        );
        if (i == top10Results.capacity) continue;
        if (top10Results.items.len == top10Results.capacity) _ = top10Results.pop();
        top10Results.insertAssumeCapacity(i, e.value_ptr);
    }
    return top10Results.items;
}

const Result = struct {
    url: []const u8,
    title: []const u8,
    text: []const u8,
};

fn readIndexData(alloc: std.mem.Allocator, cwd: std.fs.Dir, sha1: []const u8) !struct {
    url: []const u8,
    title: []const u8,
} {
    const file = try cwd.openFile(sha1, .{});
    defer file.close();

    var reader = file.reader(&.{});
    var content: std.ArrayList(u8) = try .initCapacity(alloc, 32);
    while (true) {
        content.items.len += try reader.interface.readSliceShort(content.unusedCapacitySlice());
        if (std.mem.containsAtLeastScalar(u8, content.items, 2, '\n')) break;
        if (content.items.len < content.capacity) return error.InvalidIndexFileFormat;
        try content.ensureUnusedCapacity(alloc, 1);
    }

    var it = std.mem.splitScalar(u8, content.items, '\n');
    return .{ .url = it.next().?, .title = it.next().? };
}

fn loadAdditionalResultData(alloc: std.mem.Allocator, cwd: std.fs.Dir, partial_results: []const *const PartialResult) ![]Result {
    const results: []Result = try alloc.alloc(Result, partial_results.len);
    for (0.., partial_results) |i, r| {
        const data = try readIndexData(alloc, cwd, r.sha1);
        results[i] = .{
            .url = data.url,
            .title = data.title,
            .text = r.text,
        };
    }
    return results;
}

pub const Results = struct {
    results: []Result,
    time: u64,
    total: usize,
};

pub fn performSearch(alloc: std.mem.Allocator, pattern: []const u8) !Results {
    var cwd = try getIndex(false);
    defer cwd.close();

    var timer = try std.time.Timer.start();
    const stdout = try performGrep(alloc, cwd, pattern);
    const time = timer.read();

    const partial_results = try aggregatePartialResults(alloc, stdout);
    const top10_partial_results = try getTop10PartialResults(alloc, partial_results);
    const results = try loadAdditionalResultData(alloc, cwd, top10_partial_results);

    return .{
        .results = results,
        .time = time,
        .total = partial_results.count(),
    };
}
