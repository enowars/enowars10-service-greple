const std = @import("std");

const seperators = struct {
    fn f(c: u8) []const u8 {
        const s = if (c < std.math.maxInt(u8)) f(c + 1) else "";
        return switch (c) {
            'a'...'z' => s,
            'A'...'Z' => s,
            '0'...'9' => s,
            else => .{c} ++ s,
        };
    }
}.f(0);

const pattern_start = "^\\(title\\|text\\):\\(\\|.*[^a-zA-Z0-9]\\)";
const pattern_sep = "\\($\\|[^a-zA-Z0-9]\\+\\)";

pub const Query = struct {
    pub const Kind = enum { include, exclude };

    const Pattern = struct {
        kind: Kind,
        pattern: []const u8,
    };

    patterns: []const Pattern,

    pub fn init(alloc: std.mem.Allocator, q: []const u8) !?@This() {
        var patterns: std.ArrayList(Pattern) = .empty;
        defer patterns.deinit(alloc);

        var phrase_it = std.mem.splitScalar(u8, q, ' ');
        while (phrase_it.next()) |p| {
            if (p.len == 0) continue;

            var explicit = false;
            var kind: Kind = .include;

            var buffer: std.ArrayList(u8) = try .initCapacity(alloc, pattern_start.len + p.len);
            defer buffer.deinit(alloc);
            buffer.appendSliceAssumeCapacity(pattern_start);

            var word_it = std.mem.splitAny(u8, p, seperators);
            while (word_it.next()) |w| {
                if (w.len == 0) {
                    explicit = true;
                    switch (word_it.buffer[word_it.index.? - 1]) {
                        '+' => kind = .include,
                        '-' => kind = .exclude,
                        else => {},
                    }
                    continue;
                }
                try buffer.appendSlice(alloc, w);
                try buffer.appendSlice(alloc, pattern_sep);
            }

            if (buffer.items.len == pattern_start.len + 1 + pattern_sep.len and !explicit) continue;

            const pattern = try buffer.toOwnedSlice(alloc);
            errdefer alloc.free(pattern);

            try patterns.append(alloc, .{
                .pattern = pattern,
                .kind = kind,
            });
        }

        if (patterns.items.len == 0) return null;
        std.mem.sort(Pattern, patterns.items, {}, struct {
            fn lessThan(_: void, lhs: Pattern, rhs: Pattern) bool {
                return switch (lhs.kind) {
                    .include => switch (rhs.kind) {
                        .include => false,
                        .exclude => true,
                    },
                    .exclude => false,
                };
            }
        }.lessThan);
        switch (patterns.items[0].kind) {
            .include => {},
            .exclude => return null,
        }

        return .{ .patterns = try patterns.toOwnedSlice(alloc) };
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        for (self.patterns) |*p| alloc.free(p.pattern);
        alloc.free(self.patterns);
        self.* = undefined;
    }
};

// TODO: add tests
