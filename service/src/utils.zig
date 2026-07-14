const mvzr = @import("mvzr");
const std = @import("std");

const key = @embedFile("secret.bin");
const HashFn = std.crypto.hash.sha2.Sha224;
const HmacFn = std.crypto.auth.hmac.Hmac(HashFn);
pub const Hash = [HashFn.digest_length]u8;
pub const Hmac = [HmacFn.mac_length]u8;

pub fn hash(data: []const u8) Hash {
    var h: Hash = undefined;
    HashFn.hash(data, &h, .{});
    return h;
}

pub fn hmac(data: []const u8) Hmac {
    var h: Hmac = undefined;
    HmacFn.create(&h, data, key);
    return h;
}

pub fn hexToBytes(n: comptime_int, data: []const u8) ![n]u8 {
    if (data.len != n * 2) return error.InvalidLength;
    var bytes: [n]u8 = undefined;
    for (0..n) |i| bytes[i] = try std.fmt.parseInt(u8, data[i * 2 .. i * 2 + 2], 16);
    return bytes;
}

pub fn cookieValidChar(char: u8) bool {
    return switch (char) {
        0...31,
        ' ',
        '"',
        '%',
        '&',
        '+',
        ',',
        ';',
        '\\',
        127...std.math.maxInt(u8),
        => false,
        else => true,
    };
}

pub fn pathValidChar(char: u8) bool {
    return switch (char) {
        0...31,
        ' ',
        '"',
        '#',
        '%',
        '\'',
        '/',
        '<',
        '>',
        '?',
        '[',
        '\\',
        ']',
        '^',
        '`',
        '{',
        '|',
        '}',
        127...std.math.maxInt(u8),
        => false,
        else => true,
    };
}

pub fn fullMatch(re: anytype, s: []const u8) bool {
    const m = re.matchPos(0, s) orelse return false;
    return m.end == s.len;
}

test fullMatch {
    const re = comptime mvzr.compile("a").?;
    try std.testing.expect(fullMatch(&re, "a"));
    try std.testing.expect(!fullMatch(&re, "ab"));
}

pub const CronState = struct {
    had_documents: bool = false,
    had_index_entries_or_netlocs: bool = false,
};

pub fn HashMap(V: type) type {
    return std.HashMap(Hash, V, struct {
        pub fn hash(_: @This(), k: Hash) u64 {
            return std.mem.readInt(u64, k[0..8], .little);
        }
        pub fn eql(_: @This(), a: Hash, b: Hash) bool {
            return std.mem.eql(u8, &a, &b);
        }
    }, std.hash_map.default_max_load_percentage);
}

pub fn escape(string: []const u8, w: *std.Io.Writer) !void {
    for (string) |c| try w.writeAll(switch (c) {
        inline '&', '<', '>', '"', '\'' => |x| "&#" ++ std.fmt.comptimePrint("{d}", .{x}) ++ ";",
        else => &.{c},
    });
}

test escape {
    {
        var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer w.deinit();
        try escape("abc", &w.writer);
        try std.testing.expectEqualSlices(u8, "abc", w.written());
    }
    {
        var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer w.deinit();
        try escape("a'c", &w.writer);
        try std.testing.expectEqualSlices(u8, "a&#39;c", w.written());
    }
}

const esc_re = mvzr.SizedRegex(6, 2).compile("&#[1-9][0-9]*;").?;

pub fn unescape(string: []u8) []u8 {
    var it = esc_re.iterator(string);
    while (it.next()) |m| {
        const c = std.fmt.parseInt(u8, m.slice[2 .. m.slice.len - 1], 10) catch |err| switch (err) {
            std.fmt.ParseIntError.Overflow => continue,
            std.fmt.ParseIntError.InvalidCharacter => unreachable,
        };
        string[m.start] = c;
        @memmove(string[m.start + 1 .. it.haystack.len - m.slice.len + 1], string[m.end..it.haystack.len]);
        it.haystack.len -= m.slice.len - 1;
        it.idx -= m.slice.len - 1;
    }
    return string[0..it.haystack.len];
}

test unescape {
    {
        const string = try std.testing.allocator.dupe(u8, "abc");
        defer std.testing.allocator.free(string);
        const r = unescape(string);
        try std.testing.expectEqualStrings("abc", r);
    }
    {
        const string = try std.testing.allocator.dupe(u8, "a&#39;c");
        defer std.testing.allocator.free(string);
        const r = unescape(string);
        try std.testing.expectEqualStrings("a'c", r);
    }
    {
        const string = try std.testing.allocator.dupe(u8, "a&#39;b&#38;c");
        defer std.testing.allocator.free(string);
        const r = unescape(string);
        try std.testing.expectEqualStrings("a'b&c", r);
    }
}

pub const Writer = struct {
    dir: std.fs.Dir,
    name: []const u8,
    tmp_name: [17]u8,
    file: ?std.fs.File,
    writer: std.fs.File.Writer,

    pub fn open(dir: std.fs.Dir, name: []const u8) !@This() {
        while (true) {
            var tmp_name: [17]u8 = undefined;
            tmp_name[0] = '.';
            @memcpy(tmp_name[1..], &std.fmt.hex(std.crypto.random.int(u64)));

            const file = dir.createFile(&tmp_name, .{ .exclusive = true }) catch |err| switch (err) {
                std.fs.File.OpenError.PathAlreadyExists => continue,
                else => |leftover_err| return leftover_err,
            };
            errdefer {
                file.close();
                dir.deleteFile(&tmp_name) catch {};
            }

            return .{
                .dir = dir,
                .name = name,
                .tmp_name = tmp_name,
                .file = file,
                .writer = file.writer(&.{}),
            };
        }
    }

    pub fn interface(self: *@This()) *std.Io.Writer {
        return &self.writer.interface;
    }

    pub fn end(self: *@This()) !void {
        self.file.?.close();
        self.file = null;
        try self.dir.rename(&self.tmp_name, self.name);
    }

    pub fn close(self: *@This()) void {
        if (self.file) |f| {
            f.close();
            self.dir.deleteFile(&self.tmp_name) catch {};
        }
    }
};

test Writer {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var w: Writer = try .open(dir.dir, "0123456789abcdef");
    defer w.close();
    try w.interface().writeAll("xyz");
    try w.end();
    const file = try dir.dir.openFile("0123456789abcdef", .{});
    defer file.close();
    const data = try file.readToEndAlloc(std.testing.allocator, std.math.maxInt(usize));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("xyz", data);
}

fn _cleanUpTmpFiles(dir: std.fs.Dir, it: *std.fs.Dir.Iterator) !void {
    while (try it.next()) |e| if (e.name[0] == '.') try dir.deleteFile(e.name);
}

pub fn cleanUpTmpFiles(sub_path: []const u8) !void {
    var dir = try std.fs.cwd().openDir(sub_path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterateAssumeFirstIteration();
    try _cleanUpTmpFiles(dir, &it);
}

test cleanUpTmpFiles {
    var dir = std.testing.tmpDir(.{ .iterate = true });
    defer dir.cleanup();
    {
        const file = try dir.dir.createFile(".abc", .{});
        defer file.close();
    }
    {
        const file = try dir.dir.createFile("xyz", .{});
        defer file.close();
    }
    var it = dir.dir.iterate();
    try _cleanUpTmpFiles(dir.dir, &it);
    blk: {
        const file = dir.dir.openFile(".abc", .{}) catch |err| switch (err) {
            std.fs.File.OpenError.FileNotFound => break :blk,
            else => |leftover_err| return leftover_err,
        };
        defer file.close();
        return error.ExpectedFileNotFoundError;
    }
    {
        const file = try dir.dir.openFile("xyz", .{});
        defer file.close();
    }
}
