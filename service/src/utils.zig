const mvzr = @import("mvzr");
const std = @import("std");

pub const HashFn = std.crypto.hash.sha2.Sha224;
pub const Hash = [HashFn.digest_length]u8;

pub fn hash(data: []const u8) Hash {
    var h: Hash = undefined;
    HashFn.hash(data, &h, .{});
    return h;
}

pub fn hexToBytes(n: comptime_int, data: []const u8) ![n]u8 {
    if (data.len != n * 2) return error.InvalidLength;
    var bytes: [n]u8 = undefined;
    for (0..n) |i| bytes[i] = try std.fmt.parseInt(u8, data[i * 2 .. i * 2 + 2], 16);
    return bytes;
}

pub fn cookieValidChar(char: u8) bool {
    return switch (char) {
        0...31 => false,
        ' ' => false,
        '"' => false,
        ',' => false,
        ';' => false,
        '\\' => false,
        127...std.math.maxInt(u8) => false,
        else => true,
    };
}

pub fn fullMatch(re: *const mvzr.Regex, s: []const u8) bool {
    const m = re.matchPos(0, s) orelse return false;
    return m.end == s.len;
}

test "fullMatch" {
    const re = mvzr.compile("a").?;
    try std.testing.expect(fullMatch(&re, "a"));
    try std.testing.expect(!fullMatch(&re, "ab"));
}
