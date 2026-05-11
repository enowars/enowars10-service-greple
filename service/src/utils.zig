const std = @import("std");

pub const Hash = std.crypto.hash.sha2.Sha224;

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
