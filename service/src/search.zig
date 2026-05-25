const Document = @import("document.zig");
const Domain = @import("domain.zig");
const IndexEntry = @import("index_entry.zig");
const mvzr = @import("mvzr");
const Query = @import("query.zig");
const SafeSearch = @import("safe_search.zig");
const std = @import("std");
const User = @import("user.zig");
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

    fn add_match(self: *@This(), text: []const u8) void {
        if (self.text.len < text.len) self.text = text;
        self.score += std.math.pow(f32, @floatFromInt(text.len), 1 / 3);
    }

    fn order(self: *const @This(), other: *const @This()) std.math.Order {
        return std.math.order(self.score, other.score).invert();
    }
};

fn aggregateResults(alloc: std.mem.Allocator, query: *const Query, stdout: []const u8) !std.StringHashMap(Result) {
    var results: std.StringHashMap(Result) = .init(alloc);

    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |l| {
        if (l.len == 0) continue;

        var split = std.mem.splitAny(u8, l, ":/");
        std.debug.assert(std.mem.eql(u8, split.next().?, "."));
        const dirname = if (query.domain) |_| null else split.next().?;
        const filename = split.next().?;
        const text = split.rest();

        const domain = if (query.domain) |d| d.hash else try utils.hexToBytes(@sizeOf(utils.Hash), dirname.?);
        const path = try utils.hexToBytes(@sizeOf(utils.Hash), filename);
        const key = try std.mem.concat(alloc, u8, &.{ &domain, &path });
        errdefer alloc.free(key);

        const result = try results.getOrPut(key);
        if (result.found_existing) {
            result.value_ptr.add_match(text);
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
    results: std.StringHashMap(Result),
) !struct { results: []const *const Result, filtered: usize } {
    var regex: ?Regex = if (safe_search.enabled) .compile(safe_search.regex) else null;

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

        var entry: IndexEntry = try .get(
            alloc,
            e.key_ptr.*[0..@sizeOf(utils.Hash)].*,
            e.key_ptr.*[@sizeOf(utils.Hash) .. @sizeOf(utils.Hash) * 2].*,
        );
        e.value_ptr.path = entry.path;
        e.value_ptr.title = entry.title;

        var domain: ?Domain = null;
        if (e.value_ptr.domain == null) {
            domain = try .get(alloc, entry.domain_hash);
            e.value_ptr.domain = domain;
        }

        if ((if (user) |u| !std.mem.eql(u8, &e.value_ptr.domain.?.user_hash, &u.hash) else true) and !entry.public) {
            if (domain) |*d| d.deinit(alloc);
            entry.deinit(alloc);
            continue;
        }

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
