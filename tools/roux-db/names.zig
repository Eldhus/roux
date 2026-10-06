//! Names that become Roc: queries, parameters and result columns are Roc
//! record fields and functions, so they are snake_case and not keywords;
//! query files name modules, so they are PascalCase. Pure.

const std = @import("std");
const assert = std.debug.assert;

/// The longest name roux-db accepts: a field, a function, a module.
pub const name_bytes_max = 64;

/// Words Roc reserves; a field or function so named would not parse.
const roc_keywords = [_][]const u8{
    "and",      "as",       "break", "continue", "crash",  "dbg",    "else",
    "expect",   "exposing", "for",   "if",       "import", "in",     "match",
    "or",       "return",   "var",   "where",    "while",  "module", "app",
    "platform", "package",
};

/// `[a-z][a-z0-9_]*`, no `__`, not ending in `_`, at most
/// `name_bytes_max`: a Roc field or function name.
pub fn is_snake(name: []const u8) bool {
    if (name.len == 0 or name.len > name_bytes_max) return false;
    if (!std.ascii.isLower(name[0])) return false;
    if (name[name.len - 1] == '_') return false;
    for (name, 0..) |byte, i| {
        const fits = std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '_';
        if (!fits) return false;
        if (byte == '_' and i > 0 and name[i - 1] == '_') return false;
    }
    return true;
}

/// `[A-Z][A-Za-z0-9]*`, at most `name_bytes_max`: a Roc module name.
pub fn is_pascal(name: []const u8) bool {
    if (name.len == 0 or name.len > name_bytes_max) return false;
    if (!std.ascii.isUpper(name[0])) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) return false;
    }
    return true;
}

pub fn is_roc_keyword(name: []const u8) bool {
    for (roc_keywords) |keyword| {
        if (std.mem.eql(u8, keyword, name)) return true;
    }
    return false;
}

/// `by_id` as `ById`: a query's row type. `snake` is `is_snake`.
pub fn pascal_from_snake(snake: []const u8, buffer: *[name_bytes_max]u8) []const u8 {
    assert(is_snake(snake));
    var length: u32 = 0;
    var upper_next = true;
    for (snake) |byte| {
        if (byte == '_') {
            upper_next = true;
            continue;
        }
        buffer[length] = if (upper_next) std.ascii.toUpper(byte) else byte;
        length += 1;
        upper_next = false;
    }
    const pascal = buffer[0..length];
    assert(is_pascal(pascal));
    return pascal;
}

test "names: snake_case, as Roc fields want" {
    try std.testing.expect(is_snake("by_id"));
    try std.testing.expect(is_snake("price_kr2"));
    try std.testing.expect(!is_snake(""));
    try std.testing.expect(!is_snake("ById"));
    try std.testing.expect(!is_snake("_id"));
    try std.testing.expect(!is_snake("id_"));
    try std.testing.expect(!is_snake("by__id"));
    try std.testing.expect(!is_snake("2nd"));
    try std.testing.expect(!is_snake("price-kr"));
    const long: [name_bytes_max + 1]u8 = @splat('a');
    try std.testing.expect(!is_snake(&long));
    try std.testing.expect(is_snake(long[0..name_bytes_max]));
}

test "names: PascalCase modules, and keywords refused" {
    try std.testing.expect(is_pascal("Dishes"));
    try std.testing.expect(is_pascal("V2"));
    try std.testing.expect(!is_pascal("dishes"));
    try std.testing.expect(!is_pascal("My_Dishes"));
    try std.testing.expect(is_roc_keyword("match"));
    try std.testing.expect(!is_roc_keyword("matches"));
}

test "names: a query's row type is its name in PascalCase" {
    var buffer: [name_bytes_max]u8 = undefined;
    try std.testing.expectEqualStrings("ById", pascal_from_snake("by_id", &buffer));
    try std.testing.expectEqualStrings("All", pascal_from_snake("all", &buffer));
    try std.testing.expectEqualStrings("Top10Dishes", pascal_from_snake("top10_dishes", &buffer));
}
