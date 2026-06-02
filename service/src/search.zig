const Document = @import("Document.zig");
const IndexEntry = @import("IndexEntry.zig");
const mvzr = @import("mvzr");
const Query = @import("Query.zig");
const SafeSearch = @import("SafeSearch.zig");
const std = @import("std");
const User = @import("User.zig");
const utils = @import("utils.zig");

fn performGrep(alloc: std.mem.Allocator, query: *const Query) ![]const u8 {
    var cwd = try Document.openDir();
    defer cwd.close();

    if (query.user_hash) |u| {
        const subdir = cwd.openDir(&std.fmt.bytesToHex(u, .lower), .{}) catch |err| switch (err) {
            std.fs.Dir.OpenError.FileNotFound => return alloc.dupe(u8, ""),
            else => |leftover_err| return leftover_err,
        };
        cwd.close();
        cwd = subdir;
    }

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "/bin/grep", "-ri", query.pattern, "." },
        .cwd_dir = cwd,
        .max_output_bytes = std.math.maxInt(usize),
    });
    alloc.free(result.stderr);

    return result.stdout;
}

const Result = struct {
    user_hash: utils.Hash,
    url: ?[]const u8,
    title: ?[]const u8,
    text: []const u8,
    score: f32,

    fn addMatch(self: *@This(), text: []const u8) void {
        if (self.text.len < text.len) self.text = text;
        self.score += std.math.pow(f32, @floatFromInt(text.len), 1 / 3);
    }

    fn order(self: *const @This(), other: *const @This()) std.math.Order {
        return std.math.order(self.score, other.score).invert();
    }
};

const HashMap = std.HashMap(utils.Hash, Result, struct {
    pub fn hash(_: @This(), k: utils.Hash) u64 {
        return std.mem.readInt(u64, k[0..8], .little);
    }
    pub fn eql(_: @This(), a: utils.Hash, b: utils.Hash) bool {
        return std.mem.eql(u8, &a, &b);
    }
}, std.hash_map.default_max_load_percentage);

// TODO: add test in checker to ensure allowed complexity isn't reduced
const Regex = mvzr.SizedRegex(42, 2);

fn aggregateResults(
    alloc: std.mem.Allocator,
    user: *const ?User,
    safe_search: *const SafeSearch,
    query: *const Query,
    stdout: []const u8,
) !HashMap {
    const regex: ?Regex = if (safe_search.enabled) .compile(safe_search.regex) else null;

    var results: HashMap = .init(alloc);

    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |l| {
        if (l.len == 0) continue;

        var split = std.mem.splitAny(u8, l, ":/");
        std.debug.assert(std.mem.eql(u8, split.next() orelse return error.UnexpectedGrepStdout, "."));
        const dirname = if (query.user_hash) |_| null else (split.next() orelse return error.UnexpectedGrepStdout);
        const filename = split.next() orelse return error.UnexpectedGrepStdout;
        const text = split.rest();

        if (regex) |*r| {
            utils.setNice(18);
            defer utils.setNice(0);
            if (r.isMatch(text)) continue;
        }

        const user_hash = if (query.user_hash) |u| u else try utils.hexToBytes(@sizeOf(utils.Hash), dirname.?);
        const url_hash = try utils.hexToBytes(@sizeOf(utils.Hash), filename);

        var entry: IndexEntry = try .get(alloc, user_hash, url_hash);
        errdefer entry.deinit(alloc);

        const owner_match = if (user.*) |u| std.mem.eql(u8, &user_hash, &u.hash) else false;
        if (!owner_match and !entry.public) {
            entry.deinit(alloc);
            continue;
        }

        const result = try results.getOrPut(url_hash);
        if (result.found_existing) {
            result.value_ptr.addMatch(text);
        } else {
            result.key_ptr.* = url_hash;
            result.value_ptr.user_hash = user_hash;
            result.value_ptr.url = entry.url;
            result.value_ptr.title = entry.title;
            result.value_ptr.text = text;
            result.value_ptr.score = 0;
        }
    }

    return results;
}

fn getTop10Results(alloc: std.mem.Allocator, results: HashMap) ![]const *const Result {
    var top10_results: std.ArrayList(*const Result) = try .initCapacity(alloc, @min(10, results.count()));
    defer top10_results.deinit(alloc);

    var it = results.iterator();
    while (it.next()) |e| {
        const i = std.sort.upperBound(*const Result, top10_results.items, e.value_ptr, Result.order);
        if (i == top10_results.capacity) continue;
        if (top10_results.items.len == top10_results.capacity) _ = top10_results.pop();
        top10_results.insertAssumeCapacity(i, e.value_ptr);
    }

    return try top10_results.toOwnedSlice(alloc);
}

pub const Results = struct {
    results: []const *const Result,
    time: u64,
    total: usize,
};

pub fn performSearch(
    alloc: std.mem.Allocator,
    user: *const ?User,
    safe_search: *const SafeSearch,
    query: *const Query,
) !Results {
    var timer: std.time.Timer = try .start();

    const stdout = try performGrep(alloc, query);
    const results = try aggregateResults(alloc, user, safe_search, query, stdout);
    const top10_results = try getTop10Results(alloc, results);

    const time = timer.read();

    return .{
        .results = top10_results,
        .time = time,
        .total = if (top10_results.len < 10) top10_results.len else results.count(),
    };
}
