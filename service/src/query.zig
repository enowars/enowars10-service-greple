const std = @import("std");

fn splitWords(text: []const u8) std.mem.SplitIterator(u8, .any) {
    return std.mem.splitAny(u8, text, "\x00\x01\x02\x03\x04\x05\x06\x07\x08\t\n\x0b\x0c\r\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f !\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~");
}

pub const Query = struct {
    kind: enum { include, exclude },
    phrase: []const []const u8,
    next: ?*const Query,

    pub fn init(alloc: std.mem.Allocator, q: []const u8) !?*const @This() {
        var query: ?*const @This() = null;

        var it = splitWords(q);
        while (it.next()) |w| {
            if (w.len == 0) continue;

            const modifier = blk: {
                const i = it.index orelse it.buffer.len + 1;
                if (i < w.len + 2) break :blk null;
                const m = it.buffer[i - w.len - 2];
                if (std.mem.containsAtLeastScalar(u8, "+-", 1, m)) break :blk m;
                break :blk null;
            };

            if (w.len == 1 and modifier == null) continue;

            var n = try alloc.create(@This());
            n.kind = if (modifier == '-') .exclude else .include;
            n.phrase = try alloc.dupe([]const u8, &.{w});
            n.next = query;

            query = n;
        }

        return query;
    }

    pub fn deinit(self: *const @This(), alloc: std.mem.Allocator) void {
        if (self.next) |n| n.deinit(alloc);
        alloc.free(self.phrase);
        alloc.destroy(self);
    }

    fn countMatches(self: *const @This(), alloc: std.mem.Allocator, text: []const u8) !u32 {
        var it = splitWords(text);

        var arr: [][]const u8 = try alloc.alloc([]const u8, self.phrase.len);
        defer alloc.free(arr);

        for (1..self.phrase.len) |i| {
            if (it.next()) |w| arr[i] = w else return 0;
        }

        var count: u32 = 0;

        while (it.next()) |w| {
            for (1..self.phrase.len) |i| arr[i - 1] = arr[i];
            arr[self.phrase.len - 1] = w;

            if (blk: {
                for (arr, self.phrase) |a, b| {
                    if (!std.ascii.eqlIgnoreCase(a, b)) break :blk false;
                }
                break :blk true;
            }) count += 1;
        }

        return count;
    }

    pub fn match(self: *const @This(), alloc: std.mem.Allocator, text: []const u8) !?u32 {
        const count = try self.countMatches(alloc, text);

        if (switch (self.kind) {
            .include => count == 0,
            .exclude => count > 0,
        }) return null;

        if (self.next) |n| {
            if (try n.match(alloc, text)) |c| return count + c;
            return null;
        }

        return count;
    }
};

fn testQuery(q: []const u8, expected: ?*const Query) !void {
    const query = (try Query.init(std.testing.allocator, q));
    defer if (query) |qr| qr.deinit(std.testing.allocator);
    try std.testing.expectEqualDeep(expected, query);
}

test "test Query.init w/ include queries" {
    try testQuery("ax bx cx", &Query{
        .kind = .include,
        .phrase = &.{"cx"},
        .next = &Query{
            .kind = .include,
            .phrase = &.{"bx"},
            .next = &Query{
                .kind = .include,
                .phrase = &.{"ax"},
                .next = null,
            },
        },
    });
}

test "test Query.init w/ exclude queries" {
    try testQuery("-ax", &Query{
        .kind = .exclude,
        .phrase = &.{"ax"},
        .next = null,
    });
    try testQuery("-ax bx", &Query{
        .kind = .include,
        .phrase = &.{"bx"},
        .next = &Query{
            .kind = .exclude,
            .phrase = &.{"ax"},
            .next = null,
        },
    });
    try testQuery("ax -bx", &Query{
        .kind = .exclude,
        .phrase = &.{"bx"},
        .next = &Query{
            .kind = .include,
            .phrase = &.{"ax"},
            .next = null,
        },
    });
    try testQuery("-ax bx cx", &Query{
        .kind = .include,
        .phrase = &.{"cx"},
        .next = &Query{
            .kind = .include,
            .phrase = &.{"bx"},
            .next = &Query{
                .kind = .exclude,
                .phrase = &.{"ax"},
                .next = null,
            },
        },
    });
    try testQuery("ax -bx cx", &Query{
        .kind = .include,
        .phrase = &.{"cx"},
        .next = &Query{
            .kind = .exclude,
            .phrase = &.{"bx"},
            .next = &Query{
                .kind = .include,
                .phrase = &.{"ax"},
                .next = null,
            },
        },
    });
    try testQuery("ax bx -cx", &Query{
        .kind = .exclude,
        .phrase = &.{"cx"},
        .next = &Query{
            .kind = .include,
            .phrase = &.{"bx"},
            .next = &Query{
                .kind = .include,
                .phrase = &.{"ax"},
                .next = null,
            },
        },
    });
}
