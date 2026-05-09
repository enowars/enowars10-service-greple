const index = @import("index.zig");
const mvzr = @import("mvzr");
const preferences = @import("preferences.zig");
const query = @import("query.zig");
const std = @import("std");

fn performGrep(alloc: std.mem.Allocator, cwd: std.fs.Dir, pattern: []const u8) ![]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "/bin/grep", "-rin", pattern, "." },
        .cwd_dir = cwd,
        .max_output_bytes = std.math.maxInt(usize),
    });
    alloc.free(result.stderr);
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

fn aggregateResults(alloc: std.mem.Allocator, stdout: []const u8) !std.StringHashMap(Result) {
    var results: std.StringHashMap(Result) = .init(alloc);

    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |l| {
        if (l.len == 0) continue;

        var split = std.mem.splitScalar(u8, l, ':');
        const sha1 = split.next().?["./".len..];
        const line = try std.fmt.parseInt(usize, split.next().?, 10);
        if (line <= index.header_lines) continue;
        const text = split.rest();

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

    return results;
}

const Regex = mvzr.SizedRegex(1 << 10, 1 << 3);

fn getTop10Results(
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    prefs: *const preferences.Preferences,
    results: std.StringHashMap(Result),
) !struct { results: []const *const Result, filtered: usize } {
    var regex: ?Regex = if (prefs.safe_search_enabled) .compile(prefs.safe_search_regex) else null;

    var top10_results: std.ArrayList(*const Result) = try .initCapacity(alloc, @min(10, results.count()));
    var filtered: usize = 0;

    var it = results.iterator();
    while (it.next()) |e| {
        const i = std.sort.upperBound(*const Result, top10_results.items, e.value_ptr, Result.order);

        if (i == top10_results.capacity) continue;

        if (regex) |*r| if (r.match(e.value_ptr.text)) |_| {
            filtered += 1;
            continue;
        };

        const header = try index.readHeader(alloc, dir, prefs, e.key_ptr.*) orelse continue;
        e.value_ptr.url = header.url;
        e.value_ptr.title = header.title;

        if (top10_results.items.len == top10_results.capacity) _ = top10_results.pop();
        top10_results.insertAssumeCapacity(i, e.value_ptr);
    }

    return .{
        .results = top10_results.items,
        .filtered = filtered,
    };
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

    var timer: std.time.Timer = try .start();
    const stdout = try performGrep(alloc, cwd, pattern);
    const results = try aggregateResults(alloc, stdout);
    const top10_results = try getTop10Results(alloc, cwd, prefs, results);
    const time = timer.read();

    return .{
        .results = top10_results.results,
        .time = time,
        .total = if (top10_results.results.len < 10) top10_results.results.len else results.count(),
        .filtered = top10_results.filtered,
    };
}
