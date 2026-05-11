const preferences = @import("preferences.zig");
const std = @import("std");
const utils = @import("utils.zig");

pub fn indexDir(iterate: bool) !std.fs.Dir {
    return std.fs.cwd().openDir("index", .{ .iterate = iterate });
}

pub fn documentsDir() !std.fs.Dir {
    return std.fs.cwd().openDir("documents", .{});
}

const Entry = struct {
    public: bool,
    url: []const u8,
    title: []const u8,
};

fn readIndexHeader(alloc: std.mem.Allocator, reader: *std.Io.Reader) !Entry {
    return .{
        .public = try reader.takeByte() == @intFromBool(true),
        .url = try reader.readAlloc(alloc, try reader.takeInt(u16, .little)),
        .title = try reader.readAlloc(alloc, try reader.takeInt(u16, .little)),
    };
}

fn findIndexUser(hash: []const u8, reader: *std.Io.Reader) !bool {
    while (true) {
        const cmp = reader.take(utils.Hash.digest_length) catch |err| switch (err) {
            std.Io.Reader.Error.EndOfStream => return false,
            else => |leftover_err| return leftover_err,
        };
        if (std.mem.eql(u8, hash, cmp)) return true;
    }
}

fn writeIndexEntry(
    alloc: std.mem.Allocator,
    prefs: *const preferences.Preferences,
    public: bool,
    url: []const u8,
    title: []const u8,
    filename: []const u8,
) !void {
    var user_hash: [utils.Hash.digest_length]u8 = undefined;
    utils.Hash.hash(prefs.user_account_user.?, &user_hash, .{});

    var index_dir = try indexDir(false);
    defer index_dir.close();

    var index_file = try index_dir.createFile(filename, .{ .read = true, .truncate = false });
    defer index_file.close();

    var buffer: [utils.Hash.digest_length]u8 = undefined;
    var reader = index_file.reader(&buffer);

    const entry = readIndexHeader(alloc, &reader.interface) catch |err| switch (err) {
        std.Io.Reader.Error.EndOfStream => {
            var writer = index_file.writer(&.{});

            try writer.interface.writeByte(@intFromBool(public));

            const url_len: u16 = @truncate(url.len);
            try writer.interface.writeInt(u16, url_len, .little);
            try writer.interface.writeAll(url[0..url_len]);

            const title_len: u16 = @truncate(title.len);
            try writer.interface.writeInt(u16, title_len, .little);
            try writer.interface.writeAll(title[0..title_len]);

            try writer.interface.writeAll(&user_hash);

            return;
        },
        else => |leftover_err| return leftover_err,
    };
    defer {
        alloc.free(entry.url);
        alloc.free(entry.title);
    }

    if (!std.mem.eql(u8, entry.url, url)) return error.HashCollision;

    var writer = index_file.writer(&.{});

    if (public and !entry.public) try writer.interface.writeByte(@intFromBool(true));

    if (!try findIndexUser(&user_hash, &reader.interface)) {
        try writer.seekTo(reader.pos);
        try writer.interface.writeAll(&user_hash);
    }
}

fn writeDocumentsEntry(text: []const []const u8, filename: []const u8) !void {
    var document_dir = try documentsDir();
    defer document_dir.close();

    var document_file = document_dir.createFile(filename, .{ .exclusive = true }) catch |err| switch (err) {
        std.fs.File.OpenError.PathAlreadyExists => return,
        else => |leftover_err| return leftover_err,
    };
    defer document_file.close();

    for (text) |l| {
        try document_file.writeAll(l);
        try document_file.writeAll("\n");
    }
}

// TODO: check user has permission to add entries for the domain
// TODO: load title and text from web
pub fn writeEntry(
    alloc: std.mem.Allocator,
    prefs: *const preferences.Preferences,
    public: bool,
    url: []const u8,
    title: []const u8,
    text: []const []const u8,
) !void {
    var hash: [utils.Hash.digest_length]u8 = undefined;
    utils.Hash.hash(url, &hash, .{});
    const filename = std.fmt.bytesToHex(hash, .lower);
    try writeIndexEntry(alloc, prefs, public, url, title, &filename);
    try writeDocumentsEntry(text, &filename);
}

pub fn readIndexEntry(
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    prefs: *const preferences.Preferences,
    filename: []const u8,
) !Entry {
    const file = try dir.openFile(filename, .{});
    defer file.close();

    var buffer: [utils.Hash.digest_length]u8 = undefined;
    var reader = file.reader(&buffer);

    const entry = try readIndexHeader(alloc, &reader.interface);
    errdefer {
        alloc.free(entry.url);
        alloc.free(entry.title);
    }

    if (entry.public) return entry;

    if (prefs.user_account_user) |u| {
        var user_hash: [utils.Hash.digest_length]u8 = undefined;
        utils.Hash.hash(u, &user_hash, .{});
        if (try findIndexUser(&user_hash, &reader.interface)) return entry;
    }

    return error.NotAuthorized;
}
