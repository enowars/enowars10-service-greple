const std = @import("std");

pub fn Queue(T: type, size: usize) type {
    const Iter = struct {
        data: []const T,
        read_index: usize,
        write_index: usize,

        pub fn next(self: *@This()) ?*const T {
            if (self.read_index == self.write_index) return null;
            defer self.read_index = (self.read_index + 1) % (2 * size);
            return &self.data[self.read_index % size];
        }
    };

    return struct {
        data: [size]T,
        read_index: usize,
        write_index: usize,

        pub fn init() @This() {
            return .{ .data = undefined, .read_index = 0, .write_index = 0 };
        }

        pub fn isEmpty(self: *const @This()) bool {
            return self.read_index == self.write_index;
        }

        pub fn put(self: *@This(), item: T) !void {
            if (self.read_index == (self.write_index + size) % (2 * size)) return error.QueueFull;
            self.data[self.write_index % size] = item;
            self.write_index = (self.write_index + 1) % (2 * size);
        }

        pub fn get(self: *@This()) *T {
            std.debug.assert(!self.isEmpty());
            return &self.data[self.read_index % size];
        }

        pub fn consume(self: *@This()) void {
            std.debug.assert(!self.isEmpty());
            self.data[self.read_index % size] = undefined;
            self.read_index = (self.read_index + 1) % (2 * size);
        }

        pub fn iter(self: *const @This()) Iter {
            return .{
                .data = &self.data,
                .read_index = self.read_index,
                .write_index = self.write_index,
            };
        }
    };
}

test Queue {
    var q: Queue(u8, 2) = .init();
    try std.testing.expect(q.isEmpty());
    try q.put('a');
    try std.testing.expect(!q.isEmpty());
    try q.put('b');
    try std.testing.expect(!q.isEmpty());
    try std.testing.expectError(error.QueueFull, q.put('c'));
    try std.testing.expectEqual('a', q.get().*);
    try std.testing.expect(!q.isEmpty());
    q.consume();
    try std.testing.expect(!q.isEmpty());
    try std.testing.expectEqual('b', q.get().*);
    try std.testing.expect(!q.isEmpty());
    q.consume();
    try std.testing.expect(q.isEmpty());
}
