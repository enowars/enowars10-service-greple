const Document = @import("Document.zig");
const IndexEntry = @import("IndexEntry.zig");
const mvzr = @import("mvzr");
const Netloc = @import("Netloc.zig");
const std = @import("std");
const Url = @import("Url.zig");
const utils = @import("utils.zig");
const zap = @import("zap");

const Queue = @import("queue.zig").Queue(union(enum) {
    crawl: struct {
        user_hash: utils.Hash,
        public: bool,
        url: Url,
    },
    verify: struct {
        username: []const u8,
        netloc: Netloc,
    },
}, 4);

const title_re = mvzr.SizedRegex(17, 1).compile("<title>.*?</title>").?;
const p_re = mvzr.SizedRegex(9, 1).compile("<p>[^<]+</p>").?;

const struct_fio_connect_args = extern struct {
    address: [*:0]const u8,
    port: [*:0]const u8,
    on_connect: ?*const fn (isize, ?*anyopaque) callconv(.c) void,
    on_fail: ?*const fn (isize, ?*anyopaque) callconv(.c) void,
    tls: ?*anyopaque,
    udata: ?*anyopaque,
    timeout: u8,
};
const struct_http_settings_s = extern struct {
    on_request: ?*const fn (*zap.fio.http_s) callconv(.c) void,
    on_upgrade: ?*const fn (*zap.fio.http_s, [*]u8, usize) callconv(.c) void,
    on_response: ?*const fn (*zap.fio.http_s) callconv(.c) void,
    on_finish: ?*const fn (*struct_http_settings_s) callconv(.c) void,
    udata: ?*anyopaque,
    public_folder: ?[*]const u8,
    public_folder_length: usize,
    max_header_size: usize,
    max_body_size: usize,
    max_clients: isize,
    tls: ?*anyopaque,
    reserved1: isize,
    reserved2: isize,
    reserved3: isize,
    ws_max_msg_size: usize,
    timeout: u8,
    ws_timeout: u8,
    log: u8,
    is_client: u8,
};
extern fn fio_connect(struct_fio_connect_args) isize;
extern fn http1_new(isize, *const struct_http_settings_s, ?*anyopaque, usize) ?*anyopaque;
extern fn fio_malloc(size: usize) ?*anyopaque;
extern fn http1_vtable() *anyopaque;
extern fn fio_close(isize) void;

fn fio_uuid2fd(uuid: isize) std.posix.fd_t {
    return @intCast(@as(usize, @bitCast(uuid)) >> 8);
}

fn setCloExec(uuid: isize) !void {
    const fd = fio_uuid2fd(uuid);
    const flags = try std.posix.fcntl(fd, std.posix.F.GETFD, 0);
    _ = try std.posix.fcntl(fd, std.posix.F.SETFD, flags | std.posix.FD_CLOEXEC);
}

fn on_response(response: *zap.fio.http_s) callconv(.c) void {
    const connection: *Connection = @ptrCast(@alignCast(response.udata.?));
    connection.onResponse(response);
}

fn on_connect(uuid: isize, udata: ?*anyopaque) callconv(.c) void {
    _ = uuid;
    const connection: *Connection = @ptrCast(@alignCast(udata.?));
    connection.onConnect();
}

fn on_fail(uuid: isize, udata: ?*anyopaque) callconv(.c) void {
    _ = uuid;
    const connection: *Connection = @ptrCast(@alignCast(udata.?));
    connection.onFail();
}

fn bytesToU32(bytes: [4]u8) u32 {
    return std.mem.readInt(u32, &bytes, .big);
}

fn addrToCStr(addr: std.net.Address, w: *std.Io.Writer.Allocating) !struct { [:0]const u8, [:0]const u8 } {
    try addr.format(&w.writer);
    const sep = std.mem.lastIndexOfScalar(u8, w.written(), ':').?;
    w.written()[sep] = '\x00';
    try w.writer.writeByte('\x00');
    return .{
        w.written()[0..sep :0],
        w.written()[sep + 1 .. w.written().len - 1 :0],
    };
}

fn isAddressSafe(address: std.net.Address) bool {
    if (address.any.family != std.posix.AF.INET) return false;
    if (std.mem.asBytes(&address.in.sa.addr)[3] % 255 == 0) return false;
    if (address.getPort() < 1024 or address.getPort() > 9999) return false;
    if (std.mem.asBytes(&address.in.sa.addr)[0] == 10) return true;
    return false;
}

test isAddressSafe {
    try std.testing.expect(!isAddressSafe(.initIp6(.{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 }, 1, 1, 8080)));
    try std.testing.expect(!isAddressSafe(.initIp4(.{ 1, 1, 1, 1 }, 8080)));
    try std.testing.expect(!isAddressSafe(.initIp4(.{ 10, 1, 1, 0 }, 8080)));
    try std.testing.expect(!isAddressSafe(.initIp4(.{ 10, 1, 1, 255 }, 8080)));
    try std.testing.expect(isAddressSafe(.initIp4(.{ 10, 1, 1, 1 }, 8080)));
    try std.testing.expect(!isAddressSafe(.initIp4(.{ 10, 1, 1, 1 }, 18080)));
    try std.testing.expect(!isAddressSafe(.initIp4(.{ 10, 1, 1, 1 }, 80)));
}

pub const Connection = struct {
    alloc: std.mem.Allocator,
    mut: std.Thread.Mutex,
    conn: ?struct {
        addr: std.net.Address,
        uuid: isize,
    },
    http_settings: struct_http_settings_s,
    request: ?*zap.fio.http_s,
    queue: Queue,

    fn init(alloc: std.mem.Allocator) @This() {
        return .{
            .alloc = alloc,
            .mut = .{},
            .conn = null,
            .http_settings = .{
                .on_request = null,
                .on_upgrade = null,
                .on_response = on_response,
                .on_finish = null,
                .udata = null,
                .public_folder = null,
                .public_folder_length = 0,
                .max_header_size = 32 * 1024,
                .max_body_size = 1024 * 1024 * 50,
                .max_clients = 1,
                .tls = null,
                .reserved1 = 0,
                .reserved2 = 0,
                .reserved3 = 0,
                .ws_max_msg_size = 262144,
                .timeout = 4,
                .ws_timeout = 4,
                .log = 0,
                .is_client = 1,
            },
            .request = null,
            .queue = .init(),
        };
    }

    pub fn crawl(self: *@This(), user_hash: utils.Hash, public: bool, url: *const Url) !void {
        self.mut.lock();
        defer self.mut.unlock();

        var owned_url = try url.toOwned(self.alloc);
        errdefer owned_url.deinit(self.alloc);

        const was_empty = self.queue.isEmpty();
        try self.queue.put(.{ .crawl = .{ .user_hash = user_hash, .public = public, .url = owned_url } });
        if (was_empty) self.next();
    }

    pub fn verify(self: *@This(), username: []const u8, netloc: *const Netloc) !void {
        self.mut.lock();
        defer self.mut.unlock();

        const owned_username = try self.alloc.dupe(u8, username);
        errdefer self.alloc.free(owned_username);
        var owned_netloc = try netloc.toOwned(self.alloc);
        errdefer owned_netloc.deinit(self.alloc);

        const was_empty = self.queue.isEmpty();
        try self.queue.put(.{ .verify = .{ .username = owned_username, .netloc = owned_netloc } });
        if (was_empty) self.next();
    }

    pub fn format(self: *@This(), w: *std.Io.Writer) !void {
        switch (self.queue.get().*) {
            .crawl => |c| try w.print("crawl: {f}", .{c.url}),
            .verify => |v| try w.print("verify: {f}", .{v.netloc}),
        }
        if (self.conn) |c| try w.print(" ({f})", .{c.addr});
    }

    fn consume(self: *@This()) void {
        switch (self.queue.get().*) {
            .crawl => |*c| c.url.deinit(self.alloc),
            .verify => |*v| {
                self.alloc.free(v.username);
                v.netloc.deinit(self.alloc);
            },
        }

        self.queue.consume();

        if (self.queue.isEmpty()) {
            self.request = null;
            if (self.conn) |c| {
                fio_close(c.uuid);
                self.conn = null;
            }
        } else {
            self.next();
        }
    }

    fn onError(self: *@This(), err: anyerror, reset_conn: bool) void {
        std.log.warn("{f}: {}", .{ self, err });
        if (reset_conn) self.conn = null;
        self.consume();
    }

    fn next(self: *@This()) void {
        self.http_settings.udata = self;

        const host = switch (self.queue.get().*) {
            .crawl => |c| c.url.host,
            .verify => |v| v.netloc.host,
        };
        const port = switch (self.queue.get().*) {
            .crawl => |c| c.url.port,
            .verify => |v| v.netloc.port,
        };

        const address_list = std.net.getAddressList(self.alloc, host, port) catch |err|
            return self.onError(err, false);
        defer address_list.deinit();

        if (self.conn) |c| {
            for (address_list.addrs) |b| if (c.addr.eql(b)) return self.sendRequest();

            self.request = null;
            fio_close(c.uuid);
            self.conn = null;
        }

        for (address_list.addrs) |a| {
            if (!isAddressSafe(a)) continue;

            var buffer: std.Io.Writer.Allocating = .init(self.alloc);
            defer buffer.deinit();
            const address, const str_port = addrToCStr(a, &buffer) catch |err| return self.onError(err, false);

            const uuid = fio_connect(.{
                .address = address,
                .port = str_port,
                .on_connect = on_connect,
                .on_fail = on_fail,
                .tls = null,
                .udata = self,
                .timeout = 0,
            });
            if (uuid < 0) return self.onError(error.OpeningConnectionFailed, false);

            setCloExec(uuid) catch return self.onError(error.OpeningConnectionFailed, false);

            self.conn = .{ .addr = a, .uuid = uuid };
            return;
        }

        self.onError(error.NoValidAddress, false);
    }

    fn onConnect(self: *@This()) void {
        self.mut.lock();
        defer self.mut.unlock();
        std.debug.assert(self.conn != null);
        std.debug.assert(self.request == null);
        std.debug.assert(!self.queue.isEmpty());

        self.sendRequest();
    }

    fn onFail(self: *@This()) void {
        self.mut.lock();
        defer self.mut.unlock();
        std.debug.assert(self.conn != null);
        std.debug.assert(self.request == null);
        std.debug.assert(!self.queue.isEmpty());

        self.onError(error.ConnectionFailed, true);
    }

    fn onResponse(self: *@This(), response: *const zap.fio.http_s) void {
        self.mut.lock();
        defer self.mut.unlock();
        std.debug.assert(self.conn != null);
        std.debug.assert(self.request != null);
        std.debug.assert(!self.queue.isEmpty());

        switch (self.queue.get().*) {
            .crawl => |c| {
                if (response.status != 200) return self.onError(error.StatusNot200Ok, false);

                const x = zap.fio.fiobj_obj2cstr(response.body);
                const body = x.data[0..x.len];

                const title_tag = title_re.match(body) orelse return self.onError(error.NoTitle, false);
                const title = title_tag.slice["<title>".len .. title_tag.slice.len - "</title>".len];

                var text: std.ArrayList([]const u8) = .empty;
                defer text.deinit(self.alloc);
                var it = p_re.iterator(body);
                while (it.next()) |p_tag| {
                    std.debug.assert(p_tag.slice.len > "<p></p>".len);
                    const p = body[p_tag.start + "<p>".len .. p_tag.end - "</p>".len];
                    text.append(self.alloc, utils.unescape(p)) catch |err| return self.onError(err, false);
                }
                if (text.items.len == 0) return self.onError(error.NoText, false);

                const index_entry: IndexEntry = .{
                    .public = c.public,
                    .user_hash = c.user_hash,
                    .url = c.url,
                    .title = title,
                };
                index_entry.put() catch |err| return self.onError(err, false);
                (Document{ .text = text.items }).put(&index_entry) catch |err| return self.onError(err, false);
            },
            .verify => {},
        }

        self.consume();
    }

    fn sendRequest(self: *@This()) void {
        const path = switch (self.queue.get().*) {
            .crawl => |c| c.url.path,
            .verify => "/verify",
        };

        self.request = @ptrCast(@alignCast(fio_malloc(@sizeOf(zap.fio.http_s)) orelse
            return self.onError(error.RequestAllocFailed, false)));
        self.request.?.* = .{
            .private_data = .{
                .vtbl = http1_vtable(),
                .flag = @intFromPtr(http1_new(self.conn.?.uuid, &self.http_settings, null, 0).?),
                .out_headers = zap.fio.fiobj_hash_new(),
            },
            .received_at = .{ .tv_sec = 0, .tv_nsec = 0 },
            .method = 0,
            .status_str = 0,
            .version = 0,
            .path = zap.fio.fiobj_str_new(path.ptr, path.len),
            .query = 0,
            .headers = zap.fio.fiobj_hash_new(),
            .cookies = 0,
            .params = 0,
            .body = 0,
            .status = 0,
            .udata = null,
        };

        var host: std.Io.Writer.Allocating = .init(self.alloc);
        (switch (self.queue.get().*) {
            .crawl => |c| c.url.formatNetloc(&host.writer),
            .verify => |v| v.netloc.format(&host.writer),
        }) catch |err| return self.onError(err, false);
        defer host.deinit();

        if (zap.fio.http_set_header2(
            self.request.?,
            zap.util.str2fio("host"),
            zap.util.str2fio(host.written()),
        ) < 0) return self.onError(error.FailedToSetHeader, false);

        switch (self.queue.get().*) {
            .crawl => |c| blk: {
                var netloc = Netloc.getByUserUrl(self.alloc, c.user_hash, &c.url) catch |err| switch (err) {
                    std.fs.File.OpenError.FileNotFound => break :blk,
                    else => |leftover_err| return self.onError(leftover_err, false),
                };
                defer netloc.deinit(self.alloc);
                if (zap.fio.http_set_header2(
                    self.request.?,
                    zap.util.str2fio("x-api-key"),
                    zap.util.str2fio(netloc.api_key),
                ) < 0) return self.onError(error.FailedToSetHeader, false);
            },
            .verify => |v| {
                if (zap.fio.http_set_header2(
                    self.request.?,
                    zap.util.str2fio("x-verify-username"),
                    zap.util.str2fio(v.username),
                ) < 0) return self.onError(error.FailedToSetHeader, false);
                if (zap.fio.http_set_header2(
                    self.request.?,
                    zap.util.str2fio("x-verify-token"),
                    zap.util.str2fio(&(v.netloc.verificationToken(self.alloc, v.username) catch |err|
                        return self.onError(err, false))),
                ) < 0) return self.onError(error.FailedToSetHeader, false);
            },
        }

        zap.fio.http_finish(self.request.?);
    }
};

mut: std.Thread.Mutex,
pool: std.heap.MemoryPool(Connection),
map: utils.HashMap(*Connection),

pub fn init(alloc: std.mem.Allocator) @This() {
    return .{
        .mut = .{},
        .pool = .init(alloc),
        .map = .init(alloc),
    };
}

pub fn get(self: *@This(), user_hash: utils.Hash) ?*Connection {
    self.mut.lock();
    defer self.mut.unlock();
    return self.map.get(user_hash);
}

pub fn getOrPut(self: *@This(), user_hash: utils.Hash) !*Connection {
    self.mut.lock();
    defer self.mut.unlock();
    const result = try self.map.getOrPut(user_hash);
    if (!result.found_existing) {
        result.value_ptr.* = try self.pool.create();
        result.value_ptr.*.* = .init(self.map.allocator);
    }
    return result.value_ptr.*;
}

pub fn deinit(self: *@This()) void {
    self.map.deinit();
    self.pool.deinit();
    self.* = undefined;
}
