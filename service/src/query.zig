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

            // TODO: directly write to buffer
            var phrase = try std.ArrayList([]const u8).initCapacity(alloc, p.len);
            defer phrase.deinit(alloc);

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
                phrase.appendAssumeCapacity(w);
            }

            if (phrase.items.len == 1 and phrase.items[0].len == 1 and !explicit) continue;

            var buffer: std.ArrayList(u8) = .empty;
            defer buffer.deinit(alloc);
            try buffer.appendSlice(alloc, "^\\(title\\|text\\):\\(\\|.*[^a-zA-Z0-9]\\)");
            for (phrase.items) |w| {
                try buffer.appendSlice(alloc, w);
                try buffer.appendSlice(alloc, "\\($\\|[^a-zA-Z0-9]\\+\\)");
            }

            var pattern = try patterns.addOne(alloc);
            errdefer _ = patterns.pop();
            pattern.kind = kind;
            pattern.pattern = try buffer.toOwnedSlice(alloc);
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
