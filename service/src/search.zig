const Document = @import("Document.zig");
const IndexEntry = @import("IndexEntry.zig");
const Query = @import("Query.zig");
const SafeSearch = @import("SafeSearch.zig");
const std = @import("std");
const Url = @import("Url.zig");
const User = @import("User.zig");
const utils = @import("utils.zig");

const c = @cImport({
    @cInclude("spawn.h");
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
});

fn spawnGrep(pattern: [*:0]const u8, cwd: std.fs.Dir, pipe_r: std.posix.fd_t, pipe_w: std.posix.fd_t) !std.posix.pid_t {
    var fa: c.posix_spawn_file_actions_t = undefined;
    if (c.posix_spawn_file_actions_init(&fa) != 0) return error.SpawnFailed;
    defer _ = c.posix_spawn_file_actions_destroy(&fa);

    if (c.posix_spawn_file_actions_adddup2(&fa, pipe_w, std.posix.STDOUT_FILENO) != 0) return error.SpawnFailed;
    if (c.posix_spawn_file_actions_addclose(&fa, pipe_w) != 0) return error.SpawnFailed;
    if (c.posix_spawn_file_actions_addclose(&fa, pipe_r) != 0) return error.SpawnFailed;
    if (c.posix_spawn_file_actions_addfchdir_np(&fa, cwd.fd) != 0) return error.SpawnFailed;

    var attr: c.posix_spawnattr_t = undefined;
    if (c.posix_spawnattr_init(&attr) != 0) return error.SpawnFailed;
    defer _ = c.posix_spawnattr_destroy(&attr);
    if (c.posix_spawnattr_setflags(&attr, c.POSIX_SPAWN_USEVFORK) != 0) return error.SpawnFailed;

    var argv = [_:null]?[*:0]const u8{ "/bin/grep", "-ri", pattern, ".", null };

    var pid: c.pid_t = undefined;
    if (c.posix_spawn(
        &pid,
        "/bin/grep",
        &fa,
        &attr,
        @ptrCast(&argv),
        @ptrCast(std.c.environ),
    ) != 0) return error.SpawnFailed;

    return pid;
}

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

    const fds = try std.posix.pipe2(.{ .CLOEXEC = true });
    const pipe_r = fds[0];
    const pipe_w = fds[1];
    var pipe_r_open = true;
    errdefer if (pipe_r_open) std.posix.close(pipe_r);

    const pid = spawnGrep(query.pattern, cwd, pipe_r, pipe_w) catch |err| {
        std.posix.close(pipe_w);
        return err;
    };
    errdefer {
        if (pipe_r_open) std.posix.close(pipe_r);
        pipe_r_open = false;
        _ = std.posix.waitpid(pid, 0);
    }

    std.posix.close(pipe_w);

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(alloc);

    var buffer: [64 * 1024]u8 = undefined;
    var reader = (std.fs.File{ .handle = pipe_r }).reader(&buffer);
    reader.interface.appendRemaining(alloc, &stdout, .unlimited) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => |leftover_err| return leftover_err,
    };
    std.posix.close(pipe_r);
    pipe_r_open = false;

    _ = std.posix.waitpid(pid, 0);

    return stdout.toOwnedSlice(alloc);
}

const Result = struct {
    index_entry: IndexEntry,
    text: []const u8,
    score: f32,

    fn addMatch(self: *@This(), text: []const u8) void {
        if (self.text.len < text.len) self.text = text;
        self.score += std.math.pow(f32, @floatFromInt(text.len), 1.0 / 3.0);
    }

    fn order(self: *const @This(), other: *const @This()) std.math.Order {
        return std.math.order(self.score, other.score).invert();
    }

    fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.index_entry.deinit(alloc);
        self.* = undefined;
    }
};

fn aggregateResults(
    alloc: std.mem.Allocator,
    user: *const ?User,
    safe_search: *const ?SafeSearch,
    query: *const Query,
    stdout: []const u8,
) !utils.HashMap(Result) {
    const regex = if (safe_search.*) |ss| ss.compile() else null;

    var results: utils.HashMap(Result) = .init(alloc);

    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |l| {
        if (l.len == 0) continue;

        var split = std.mem.splitAny(u8, l, ":/");
        std.debug.assert(std.mem.eql(u8, split.next() orelse return error.UnexpectedGrepStdout, "."));
        const dirname = if (query.user_hash) |_| null else (split.next() orelse return error.UnexpectedGrepStdout);
        const filename = split.next() orelse return error.UnexpectedGrepStdout;
        if (filename[0] == '.') continue;
        const text = split.rest();

        if (regex) |*r| if (r.isMatch(text)) continue;

        const user_hash = if (query.user_hash) |u| u else try utils.hexToBytes(@sizeOf(utils.Hash), dirname.?);
        const url_hash = try utils.hexToBytes(@sizeOf(utils.Hash), filename);

        const index_entry = IndexEntry.get(alloc, utils.hash(&user_hash ++ &url_hash)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |leftover_err| return leftover_err,
        };
        errdefer {
            alloc.free(index_entry.url.host);
            alloc.free(index_entry.url.path);
            alloc.free(index_entry.title);
        }

        const owner_match = if (user.*) |u| std.mem.eql(u8, &user_hash, &u.hash()) else false;
        if (!owner_match and !index_entry.public) {
            alloc.free(index_entry.url.host);
            alloc.free(index_entry.url.path);
            alloc.free(index_entry.title);
            continue;
        }

        const result = try results.getOrPut(url_hash);
        if (result.found_existing) {
            result.value_ptr.addMatch(text);
        } else {
            result.key_ptr.* = url_hash;
            result.value_ptr.index_entry = index_entry;
            result.value_ptr.text = text;
            result.value_ptr.score = 0;
        }
    }

    return results;
}

fn getTop10Results(alloc: std.mem.Allocator, results: utils.HashMap(Result)) ![]const *Result {
    var top10_results: std.ArrayList(*Result) = try .initCapacity(alloc, @min(10, results.count()));
    defer top10_results.deinit(alloc);

    var it = results.iterator();
    while (it.next()) |e| {
        const i = std.sort.upperBound(*Result, top10_results.items, e.value_ptr, Result.order);
        if (i == top10_results.capacity) {
            e.value_ptr.deinit(alloc);
            continue;
        }
        if (top10_results.items.len == top10_results.capacity) top10_results.pop().?.deinit(alloc);
        top10_results.insertAssumeCapacity(i, e.value_ptr);
    }

    return top10_results.toOwnedSlice(alloc);
}

pub const Results = struct {
    results: []const *Result,
    time: u64,
    total: usize,

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        for (self.results) |r| r.deinit(alloc);
        alloc.free(self.results);
        self.* = undefined;
    }
};

pub fn performSearch(
    alloc: std.mem.Allocator,
    user: *const ?User,
    safe_search: *const ?SafeSearch,
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
