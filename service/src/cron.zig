const Paste = @import("Paste.zig");
const ShortUrl = @import("ShortUrl.zig");
const std = @import("std");
const User = @import("User.zig");

var running: bool = true;

fn handleSignal(_: i32) callconv(.c) void {
    running = false;
}

pub fn main() !void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
    std.posix.sigaction(std.posix.SIG.INT, &action, null);

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    while (running) {
        const start = std.time.nanoTimestamp();

        const threshold = start - std.time.ns_per_min * 12;
        try User.runCron(alloc, threshold);
        try Paste.runCron(threshold);
        try ShortUrl.runCron(threshold);

        const elapsed = std.time.nanoTimestamp() - start;
        if (elapsed > std.time.ns_per_s) std.log.info(
            "cron took {d}ms",
            .{@divFloor(elapsed, std.time.ns_per_ms)},
        );

        const step_ns = std.time.ns_per_s;
        var remaining: u64 = std.time.ns_per_s * 10;
        while (remaining > 0 and running) {
            const chunk = @min(remaining, step_ns);
            std.Thread.sleep(chunk);
            remaining -= chunk;
        }
    }
}
