const std = @import("std");

pub fn cookieValidChar(char: u8) bool {
    return switch (char) {
        0...31 => false,
        ' ' => false,
        '"' => false,
        '\'' => false,
        ',' => false,
        ';' => false,
        '\\' => false,
        127...std.math.maxInt(u8) => false,
        else => true,
    };
}
