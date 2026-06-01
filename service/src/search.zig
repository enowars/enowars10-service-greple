const Document = @import("Document.zig");
const Domain = @import("Domain.zig");
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

    if (query.domain) |d| {
        const subdir = try cwd.openDir(&std.fmt.bytesToHex(d.hash, .lower), .{});
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
    domain: ?Domain,
    path: ?[]const u8,
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

const Key = struct {
    domain_hash: utils.Hash,
    path_hash: utils.Hash,
};
const Context = struct {
    pub fn hash(_: @This(), k: Key) u64 {
        const d = std.mem.readInt(u32, k.domain_hash[0..4], .little);
        const p = std.mem.readInt(u32, k.path_hash[0..4], .little);
        return @as(u64, d) << 32 | p;
    }
    pub fn eql(_: @This(), a: Key, b: Key) bool {
        return std.mem.eql(u8, &a.domain_hash, &b.domain_hash) and std.mem.eql(u8, &a.path_hash, &b.path_hash);
    }
};
const HashMap = std.HashMap(Key, Result, Context, std.hash_map.default_max_load_percentage);

fn aggregateResults(alloc: std.mem.Allocator, query: *const Query, stdout: []const u8) !HashMap {
    var results: HashMap = .init(alloc);

    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |l| {
        if (l.len == 0) continue;

        var split = std.mem.splitAny(u8, l, ":/");
        std.debug.assert(std.mem.eql(u8, split.next() orelse return error.UnexpectedGrepStdout, "."));
        const dirname = if (query.domain) |_| null else (split.next() orelse return error.UnexpectedGrepStdout);
        const filename = split.next() orelse return error.UnexpectedGrepStdout;
        const text = split.rest();

        const key: Key = .{
            .domain_hash = if (query.domain) |d| d.hash else try utils.hexToBytes(@sizeOf(utils.Hash), dirname.?),
            .path_hash = try utils.hexToBytes(@sizeOf(utils.Hash), filename),
        };
        const result = try results.getOrPut(key);
        if (result.found_existing) {
            result.value_ptr.addMatch(text);
        } else {
            result.key_ptr.* = key;
            result.value_ptr.domain = query.domain;
            result.value_ptr.path = null;
            result.value_ptr.title = null;
            result.value_ptr.text = text;
            result.value_ptr.score = 0;
        }
    }

    return results;
}

// TODO: add test in checker to ensure allowed complexity isn't reduced
const Regex = mvzr.SizedRegex(42, 2);

fn getTop10Results(
    alloc: std.mem.Allocator,
    user: ?User,
    safe_search: SafeSearch,
    results: HashMap,
) !struct { results: []const *const Result, filtered: usize } {
    var regex: ?Regex = if (safe_search.enabled) .compile(safe_search.regex) else null;

    var top10_results: std.ArrayList(*const Result) = try .initCapacity(alloc, @min(10, results.count()));
    var filtered: usize = 0;

    var it = results.iterator();
    while (it.next()) |e| {
        const i = std.sort.upperBound(*const Result, top10_results.items, e.value_ptr, Result.order);

        if (i == top10_results.capacity) continue;

        if (regex) |*r| {
            utils.setNice(18);
            defer utils.setNice(0);
            if (r.match(e.value_ptr.text)) |_| {
                filtered += 1;
                continue;
            }
        }

        var entry: IndexEntry = try .get(alloc, e.key_ptr.domain_hash, e.key_ptr.path_hash);
        errdefer entry.deinit(alloc);

        var domain: Domain = e.value_ptr.domain orelse try .get(alloc, e.key_ptr.domain_hash);
        errdefer if (e.value_ptr.domain == null) domain.deinit(alloc);

        if ((if (user) |u| !std.mem.eql(u8, &domain.user_hash, &u.hash) else true) and !entry.public) {
            entry.deinit(alloc);
            if (e.value_ptr.domain == null) domain.deinit(alloc);
            continue;
        }

        e.value_ptr.domain = domain;
        e.value_ptr.path = entry.path;
        e.value_ptr.title = entry.title;

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

pub fn performSearch(
    alloc: std.mem.Allocator,
    user: ?User,
    safe_search: SafeSearch,
    query: *const Query,
) !Results {
    var timer: std.time.Timer = try .start();

    const stdout = try performGrep(alloc, query);
    const results = try aggregateResults(alloc, query, stdout);
    const top10_results = try getTop10Results(alloc, user, safe_search, results);

    const time = timer.read();

    return .{
        .results = top10_results.results,
        .time = time,
        .total = if (top10_results.results.len < 10) top10_results.results.len else results.count(),
        .filtered = top10_results.filtered,
    };
}
