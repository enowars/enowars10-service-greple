const std = @import("std");

fn splitWords(text: []const u8) std.mem.SplitIterator(u8, .any) {
    // TODO: handle non ascii
    return std.mem.splitAny(u8, text, "\x00\x01\x02\x03\x04\x05\x06\x07\x08\t\n\x0b\x0c\r\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f !\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~");
}

pub const Query = struct {
    include: []const u8,
    exclude: []const u8,

    pub fn init(alloc: std.mem.Allocator, q: []const u8) !?@This() {
        var include = try std.ArrayList(u8).initCapacity(alloc, 0);
        errdefer include.deinit(alloc);
        var exclude = try std.ArrayList(u8).initCapacity(alloc, 0);
        errdefer exclude.deinit(alloc);

        var phrase_it = std.mem.splitScalar(u8, q, ' ');
        while (phrase_it.next()) |p| {
            if (p.len == 0) continue;

            var explicit = false;
            var buffer = &include;

            var phrase = try std.ArrayList([]const u8).initCapacity(alloc, p.len);
            defer phrase.deinit(alloc);

            var word_it = splitWords(p);
            while (word_it.next()) |w| {
                if (w.len == 0) {
                    explicit = true;
                    switch (word_it.buffer[word_it.index.? - 1]) {
                        '+' => buffer = &include,
                        '-' => buffer = &exclude,
                        else => {},
                    }
                    continue;
                }
                phrase.appendAssumeCapacity(w);
            }

            // TODO: support phrases
            if (phrase.items.len != 1) continue;

            if (phrase.items.len == 1 and phrase.items[0].len == 1 and !explicit) continue;

            if (buffer.items.len != 0) try buffer.append(alloc, '\n');
            try buffer.appendSlice(alloc, "^\\(title\\|text\\):\\(\\|.*[^a-zA-Z0-9]\\)");
            try buffer.appendSlice(alloc, phrase.items[0]);
            try buffer.appendSlice(alloc, "\\($\\|[^a-zA-Z0-9]\\)");
        }

        if (include.items.len == 0) {
            include.deinit(alloc);
            exclude.deinit(alloc);
            return null;
        }

        return .{
            .include = try include.toOwnedSlice(alloc),
            .exclude = try exclude.toOwnedSlice(alloc),
        };
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(self.include);
        alloc.free(self.exclude);
        self.* = undefined;
    }
};

// TODO: add tests
