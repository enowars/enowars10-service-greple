const std = @import("std");

fn copy(src: std.fs.Dir, dest: std.fs.Dir) !void {
    var it = src.iterateAssumeFirstIteration();
    while (try it.next()) |e| {
        switch (e.kind) {
            .file => try src.copyFile(e.name, dest, e.name, .{}),
            .directory => {
                try dest.makeDir(e.name);

                var sub_src = try src.openDir(e.name, .{ .iterate = true });
                defer sub_src.close();

                var sub_dest = try dest.openDir(e.name, .{ .iterate = true });
                defer sub_dest.close();

                try copy(sub_src, sub_dest);
            },
            else => continue,
        }
    }
}

pub fn main() !noreturn {
    var it = std.process.args();
    if (!it.skip()) return error.InvalidArgument;
    const arg0 = it.next() orelse return error.InvalidArgument;
    if (it.skip()) return error.InvalidArgument;

    if (blk: {
        std.fs.cwd().access("initialized", .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk true,
            else => |leftover_err| return leftover_err,
        };
        break :blk false;
    }) {
        var src = try std.fs.openDirAbsolute("/initial-data", .{ .iterate = true });
        defer src.close();

        try copy(src, std.fs.cwd());

        var file = try std.fs.cwd().createFile("initialized", .{ .exclusive = true });
        defer file.close();
    }

    const argv: [*:null]const ?[*:0]const u8 = &.{arg0};
    const envp: [*:null]const ?[*:0]const u8 = &.{};
    return std.posix.execveZ(arg0, argv, envp);
}
