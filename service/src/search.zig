const index = @import("index.zig");
const preferences = @import("preferences.zig");
const query = @import("query.zig");
const std = @import("std");

fn performGrep(alloc: std.mem.Allocator, cwd: std.fs.Dir, pattern: []const u8) ![]const u8 {
    // TODO: configure to not capture stderr?
    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "/bin/grep", "-rin", pattern, "." },
        .cwd_dir = cwd,
    });
    return result.stdout;
}

const Result = struct {
    url: ?[]const u8,
    title: ?[]const u8,
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

fn aggregateResults(
    alloc: std.mem.Allocator,
    cwd: std.fs.Dir,
    prefs: *const preferences.Preferences,
    stdout: []const u8,
) !struct { results: std.StringHashMap(Result), filtered: usize } {
    var results: std.StringHashMap(Result) = .init(alloc);
    var line_it = std.mem.splitScalar(u8, stdout, '\n');
    while (line_it.next()) |l| {
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
            result.value_ptr.url = null;
            result.value_ptr.title = null;
            result.value_ptr.text = text;
            result.value_ptr.score = 0;
        }
    }

    var filtered: usize = 0;
    var entry_it = results.iterator();
    while (entry_it.next()) |e| {
        const header = try index.readHeader(alloc, cwd, e.key_ptr.*);

        // TODO: use actual safe search regex to filter
        if (prefs.safe_search_enabled and std.ascii.startsWithIgnoreCase(header.url, prefs.safe_search_regex)) {
            filtered += 1;
            results.removeByPtr(e.key_ptr);
            continue;
        }

        // TODO: filter based on permission to see result
        if (e.key_ptr.*[0] == 'a') {
            results.removeByPtr(e.key_ptr);
            continue;
        }

        e.value_ptr.url = header.url;
        e.value_ptr.title = header.title;
    }

    return .{
        .results = results,
        .filtered = filtered,
    };
}

fn getTop10Results(alloc: std.mem.Allocator, results: std.StringHashMap(Result)) ![]const *const Result {
    var top10_results: std.ArrayList(*const Result) = try .initCapacity(alloc, @min(10, results.count()));
    var it = results.iterator();
    while (it.next()) |e| {
        const i = std.sort.upperBound(*const Result, top10_results.items, e.value_ptr, Result.order);
        if (i == top10_results.capacity) continue;
        if (top10_results.items.len == top10_results.capacity) _ = top10_results.pop();
        top10_results.insertAssumeCapacity(i, e.value_ptr);
    }
    return top10_results.items;
}

pub const Results = struct {
    results: []const *const Result,
    time: u64,
    total: usize,
    filtered: usize,
};

pub fn performSearch(alloc: std.mem.Allocator, prefs: *const preferences.Preferences, pattern: []const u8) !Results {
    var cwd = try index.getDir(false);
    defer cwd.close();

    var timer = try std.time.Timer.start();
    const stdout = try performGrep(alloc, cwd, pattern);
    const time = timer.read();

    const results = try aggregateResults(alloc, cwd, prefs, stdout);
    const top10_results = try getTop10Results(alloc, results.results);

    return .{
        .results = top10_results,
        .time = time,
        .total = results.results.count(),
        .filtered = results.filtered,
    };
}
