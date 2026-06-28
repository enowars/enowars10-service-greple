const Document = @import("Document.zig");
const IndexEntry = @import("IndexEntry.zig");
const mvzr = @import("mvzr");
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
    verify: struct { url: Url },
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
    // TODO: replace switches with ifs
    // switch (std.mem.bigToNative(u32, address.in.sa.addr)) {
    //     bytesToU32(.{ 10, 0, 0, 0 })...bytesToU32(.{ 10, 255, 255, 255 }),
    //     bytesToU32(.{ 91, 99, 0, 0 })...bytesToU32(.{ 91, 99, 255, 255 }), // TODO: remove CICD
    //     bytesToU32(.{ 172, 18, 0, 1 }),
    //     => {},
    //     else => return false,
    // }
    // if (address.getPort() < 1024 or address.getPort() > 9999) return false;
    return true;
}

test isAddressSafe {
    try std.testing.expect(!isAddressSafe(.initIp6(.{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 }, 1, 1, 1)));
    try std.testing.expect(!isAddressSafe(.initIp4(.{ 1, 1, 1, 0 }, 1)));
    try std.testing.expect(!isAddressSafe(.initIp4(.{ 1, 1, 1, 255 }, 1)));
    try std.testing.expect(isAddressSafe(.initIp4(.{ 1, 1, 1, 1 }, 1)));
    // TODO: extend
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

    fn getUrl(self: *@This()) *Url {
        return switch (self.queue.get().*) {
            inline else => |*i| &i.url,
        };
    }

    fn onError(self: *@This(), err: anyerror) void {
        std.log.warn("{f} ({f}): {}", .{ self.getUrl(), self.conn.?.addr, err });
        self.getUrl().deinit(self.alloc);
        self.queue.consume();
        if (!self.queue.isEmpty()) self.next();
    }

    pub fn crawl(self: *@This(), user_hash: utils.Hash, public: bool, url: *const Url) !void {
        self.mut.lock();
        defer self.mut.unlock();

        var u = try url.toOwned(self.alloc);
        errdefer u.deinit(self.alloc);

        const was_empty = self.queue.isEmpty();
        try self.queue.put(.{ .crawl = .{ .user_hash = user_hash, .public = public, .url = u } });
        if (was_empty) self.next();
    }

    pub fn verify(self: *@This(), url: *const Url) !void {
        self.mut.lock();
        defer self.mut.unlock();

        var u = try url.toOwned(self.alloc);
        errdefer u.deinit(self.alloc);

        const was_empty = self.queue.isEmpty();
        try self.queue.put(.{ .verify = .{ .url = u } });
        if (was_empty) self.next();
    }

    fn next(self: *@This()) void {
        const url = self.getUrl();

        const address_list = std.net.getAddressList(
            self.alloc,
            url.host,
            url.port,
        ) catch |err| return self.onError(err);
        defer address_list.deinit();

        if (self.conn) |c| {
            for (address_list.addrs) |b| if (c.addr.eql(b)) return self.sendRequest();

            // TODO: destroy http1
            self.request = null;
            fio_close(c.uuid);
            self.conn = null;
        }

        for (address_list.addrs) |a| {
            if (!isAddressSafe(a)) continue;

            var buffer: std.Io.Writer.Allocating = .init(self.alloc);
            defer buffer.deinit();
            const address, const port = addrToCStr(a, &buffer) catch |err| return self.onError(err);

            const uuid = fio_connect(.{
                .address = address,
                .port = port,
                .on_connect = on_connect,
                .on_fail = on_fail,
                .tls = null,
                .udata = self,
                .timeout = 0,
            });
            if (uuid < 0) return self.onError(error.OpeningConnectionFailed);

            self.conn = .{ .addr = a, .uuid = uuid };
            return;
        }

        self.onError(error.NoValidAddress);
    }

    fn onConnect(self: *@This()) void {
        self.mut.lock();
        defer self.mut.unlock();
        std.debug.assert(self.conn != null);
        std.debug.assert(self.request == null);
        std.debug.assert(!self.queue.isEmpty());

        self.http_settings.udata = self;
        self.request = @ptrCast(@alignCast(fio_malloc(@sizeOf(zap.fio.http_s)) orelse
            return self.onError(error.RequestAllocFailed)));
        self.request.?.* = .{
            .private_data = .{
                .vtbl = http1_vtable(),
                .flag = @intFromPtr(http1_new(self.conn.?.uuid, &self.http_settings, null, 0).?),
                .out_headers = 0,
            },
            .received_at = .{ .tv_sec = 0, .tv_nsec = 0 },
            .method = 0,
            .status_str = 0,
            .version = 0,
            .path = 0,
            .query = 0,
            .headers = 0,
            .cookies = 0,
            .params = 0,
            .body = 0,
            .status = 0,
            .udata = null,
        };

        self.sendRequest();
    }

    fn onFail(self: *@This()) void {
        self.mut.lock();
        defer self.mut.unlock();
        std.debug.assert(self.conn != null);
        std.debug.assert(self.request == null);
        std.debug.assert(!self.queue.isEmpty());

        std.log.warn("{f} ({f}): error.ConnectionFailed", .{ self.getUrl(), self.conn.?.addr });
        self.getUrl().deinit(self.alloc);
        self.queue.consume();
        self.conn = null;
        if (!self.queue.isEmpty()) self.next();
    }

    fn onResponse(self: *@This(), response: *const zap.fio.http_s) void {
        self.mut.lock();
        defer self.mut.unlock();
        std.debug.assert(self.conn != null);
        std.debug.assert(self.request != null);
        std.debug.assert(!self.queue.isEmpty());

        std.log.info("{f} ({f}): {d} {s}", .{
            self.getUrl(),
            self.conn.?.addr,
            response.status,
            zap.util.fio2str(response.status_str) orelse "",
        });

        switch (self.queue.get().*) {
            .crawl => |item| {
                if (response.status != 200) return self.onError(error.StatusNot200Ok);

                const x = zap.fio.fiobj_obj2cstr(response.body);
                const body = x.data[0..x.len];

                const title_tag = title_re.match(body) orelse return self.onError(error.NoTitle);
                const title = title_tag.slice["<title>".len .. title_tag.slice.len - "</title>".len];

                var text: std.ArrayList([]const u8) = .empty;
                defer text.deinit(self.alloc);
                var it = p_re.iterator(body);
                while (it.next()) |p_tag| {
                    std.debug.assert(p_tag.slice.len > "<p></p>".len);
                    const p = body[p_tag.start + "<p>".len .. p_tag.end - "</p>".len];
                    text.append(self.alloc, utils.unescape(p)) catch |err| return self.onError(err);
                }
                if (text.items.len == 0) return self.onError(error.NoText);

                const index_entry: IndexEntry = .{
                    .public = item.public,
                    .user_hash = item.user_hash,
                    .url = item.url,
                    .title = title,
                };
                index_entry.put() catch |err| return self.onError(err);
                (Document{
                    .text = text.items,
                }).put(&index_entry) catch |err| return self.onError(err);
            },
            .verify => {},
        }

        self.getUrl().deinit(self.alloc);
        self.queue.consume();
        if (!self.queue.isEmpty()) self.next();
    }

    fn sendRequest(self: *@This()) void {
        std.debug.assert(self.request != null);

        self.request.?.private_data.out_headers = zap.fio.fiobj_hash_new();
        self.request.?.headers = zap.fio.fiobj_hash_new();

        const url = self.getUrl();
        var host: std.Io.Writer.Allocating = .init(self.alloc);
        defer host.deinit();
        url.formatNetloc(&host.writer) catch |err| return self.onError(err);

        self.request.?.path = zap.fio.fiobj_str_new(url.path.ptr, url.path.len);

        if (zap.fio.http_set_header2(
            self.request.?,
            zap.util.str2fio("Host"),
            zap.util.str2fio(host.written()),
        ) < 0) return self.onError(error.FailedToSetHostHeader);

        // TODO: don't use, as it sends date and last-modified on a request???
        zap.fio.http_finish(self.request.?);
    }
};

alloc: std.mem.Allocator,
mut: std.Thread.Mutex,
connections: utils.HashMap(Connection),

pub fn init(alloc: std.mem.Allocator) @This() {
    return .{
        .alloc = alloc,
        .mut = .{},
        .connections = .init(alloc),
    };
}

pub fn get(self: *@This(), user_hash: utils.Hash) !*Connection {
    const result = try self.connections.getOrPut(user_hash);
    if (!result.found_existing) result.value_ptr.* = .init(self.alloc);
    return result.value_ptr;
}

pub fn deinit(self: *@This()) void {
    self.connections.deinit();
    self.* = undefined;
}
