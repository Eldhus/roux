//! What a compiled template writes with: a buffer sized exactly by a
//! measure pass, HTML escaping, integers, percent-encoding. Each writer
//! has its measure beside it, and the two must agree byte for byte
//! (render.zig asserts the total).

const std = @import("std");
const assert = std.debug.assert;

/// What a template renders into: a buffer of exactly the measured size,
/// so writes never check for room (asserted in safe builds). `extern`: the
/// dispatcher hands it to a part, another object.
pub const Out = extern struct {
    buffer: [*]u8,
    capacity: usize,
    len: usize = 0,

    pub inline fn write(out: *Out, bytes: []const u8) void {
        assert(out.len + bytes.len <= out.capacity);
        @memcpy(out.buffer[out.len..][0..bytes.len], bytes);
        out.len += bytes.len;
    }

    /// Text known at comptime: a fixed-size copy the compiler inlines.
    pub inline fn write_static(out: *Out, comptime bytes: []const u8) void {
        assert(out.len + bytes.len <= out.capacity);
        out.buffer[out.len..][0..bytes.len].* = bytes[0..bytes.len].*;
        out.len += bytes.len;
    }

    inline fn write_byte(out: *Out, byte: u8) void {
        assert(out.len < out.capacity);
        out.buffer[out.len] = byte;
        out.len += 1;
    }
};

// ---- integers ----------------------------------------------------------------

pub fn int_bytes(value: anytype) usize {
    const negative = @typeInfo(@TypeOf(value)).int.signedness == .signed and value < 0;
    return @intFromBool(negative) + digits(@intCast(@abs(value)));
}

pub fn write_int(value: anytype, out: *Out) void {
    if (@typeInfo(@TypeOf(value)).int.signedness == .signed and value < 0) out.write_byte('-');
    write_unsigned(@intCast(@abs(value)), out);
}

fn digits(value: u64) usize {
    var count: usize = 1;
    var v = value;
    while (v >= 10) : (v /= 10) count += 1;
    return count;
}

const pairs = blk: {
    var table: [200]u8 = undefined;
    for (0..100) |i| {
        table[i * 2] = '0' + i / 10;
        table[i * 2 + 1] = '0' + i % 10;
    }
    break :blk table;
};

/// Two digits at a time from a table, written backwards.
fn write_unsigned(value: u64, out: *Out) void {
    var buffer: [20]u8 = undefined;
    var at: usize = buffer.len;
    var v = value;
    while (v >= 100) : (v /= 100) {
        at -= 2;
        buffer[at..][0..2].* = pairs[(v % 100) * 2 ..][0..2].*;
    }
    if (v >= 10) {
        at -= 2;
        buffer[at..][0..2].* = pairs[v * 2 ..][0..2].*;
    } else {
        at -= 1;
        buffer[at] = '0' + @as(u8, @intCast(v));
    }
    out.write(buffer[at..]);
}

// ---- HTML escaping -------------------------------------------------------------

const lanes = 16;
const V = @Vector(lanes, u8);

/// The bytes `escape` writes for `text`: each `&<>"'` grows into its entity.
pub fn escaped_bytes(text: []const u8) usize {
    var total = text.len;
    var i: usize = 0;
    while (i + lanes <= text.len) : (i += lanes) {
        const chunk: V = text[i..][0..lanes].*;
        total += 4 * hits(chunk, '&') + 3 * (hits(chunk, '<') + hits(chunk, '>')) +
            5 * hits(chunk, '"') + 4 * hits(chunk, '\'');
    }
    for (text[i..]) |b| total += entity(b).len -| 1;
    return total;
}

inline fn hits(chunk: V, comptime byte: u8) usize {
    const mask: u16 = @bitCast(chunk == @as(V, @splat(byte)));
    return @popCount(mask);
}

/// HTML-escapes `&<>"'`, for text and quoted attribute values alike: clean
/// runs are found 16 bytes at a time and copied whole.
pub fn escape(text: []const u8, out: *Out) void {
    var i: usize = 0;
    var run: usize = 0;
    while (i + lanes <= text.len) {
        const chunk: V = text[i..][0..lanes].*;
        const special = (chunk == @as(V, @splat('&'))) | (chunk == @as(V, @splat('<'))) |
            (chunk == @as(V, @splat('>'))) | (chunk == @as(V, @splat('"'))) |
            (chunk == @as(V, @splat('\'')));
        const mask: u16 = @bitCast(special);
        if (mask == 0) {
            i += lanes;
            continue;
        }
        const at = i + @ctz(mask);
        out.write(text[run..at]);
        out.write(entity(text[at]));
        i = at + 1;
        run = i;
    }
    while (i < text.len) : (i += 1) {
        const e = entity(text[i]);
        if (e.len == 0) continue;
        out.write(text[run..i]);
        out.write(e);
        run = i + 1;
    }
    out.write(text[run..]);
}

pub inline fn entity(b: u8) []const u8 {
    return switch (b) {
        '&' => "&amp;",
        '<' => "&lt;",
        '>' => "&gt;",
        '"' => "&quot;",
        '\'' => "&#39;",
        else => "",
    };
}

pub const Case = enum { upper, lower };

/// ASCII letters changed to `case`, and escaped when `escaped`; the
/// entities escaping adds are never changed. As many bytes as `escape`
/// writes, or as the text has.
pub fn write_case(text: []const u8, comptime case: Case, comptime escaped: bool, out: *Out) void {
    for (text) |b| {
        const e = entity(b);
        if (escaped and e.len != 0) {
            out.write(e);
        } else {
            out.write_byte(if (case == .upper) std.ascii.toUpper(b) else std.ascii.toLower(b));
        }
    }
}

// ---- URLs ----------------------------------------------------------------------

fn unreserved(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '-' or b == '.' or b == '_' or b == '~';
}

pub fn percent_encoded_bytes(text: []const u8) usize {
    var total: usize = 0;
    for (text) |b| total += if (unreserved(b)) 1 else 3;
    return total;
}

/// Every byte but `A-Z a-z 0-9 - . _ ~` as `%XX` (RFC 3986's unreserved
/// set): safe in a path segment, a query value or an attribute.
pub fn percent_encode(text: []const u8, out: *Out) void {
    const hex = "0123456789ABCDEF";
    for (text) |b| {
        if (unreserved(b)) {
            out.write_byte(b);
        } else {
            out.write(&.{ '%', hex[b >> 4], hex[b & 15] });
        }
    }
}

const testing = std.testing;

fn check_writer(
    comptime write: anytype,
    comptime measure: anytype,
    input: anytype,
    expected: []const u8,
) !void {
    var buffer: [256]u8 = undefined;
    var out: Out = .{ .buffer = &buffer, .capacity = buffer.len };
    write(input, &out);
    try testing.expectEqualStrings(expected, buffer[0..out.len]);
    try testing.expectEqual(expected.len, measure(input));
}

test "out: each writer and its measure agree" {
    const escapes = [_][2][]const u8{
        .{ "plain", "plain" },
        .{ "<b>\"x\" & 'y'</b>", "&lt;b&gt;&quot;x&quot; &amp; &#39;y&#39;&lt;/b&gt;" },
        .{ "0123456789abcdef<0123456789abcdef&", "0123456789abcdef&lt;0123456789abcdef&amp;" },
        .{ "café & thé, 16 bytes or more", "café &amp; thé, 16 bytes or more" },
    };
    for (escapes) |case| try check_writer(escape, escaped_bytes, case[0], case[1]);
    try check_writer(percent_encode, percent_encoded_bytes, "a b/c&d", "a%20b%2Fc%26d");
    try check_writer(write_int, int_bytes, @as(u64, 0), "0");
    try check_writer(write_int, int_bytes, @as(i32, -120), "-120");
    try check_writer(write_int, int_bytes, @as(u64, std.math.maxInt(u64)), "18446744073709551615");
    try check_writer(write_int, int_bytes, @as(i64, std.math.minInt(i64)), "-9223372036854775808");
}

test "out: escaping measures exactly, by a sweep of every byte at every position" {
    var text: [40]u8 = @splat('x');
    for (0..256) |byte| {
        for (0..text.len) |at| {
            text[at] = @intCast(byte);
            var buffer: [text.len * 6]u8 = undefined;
            var out: Out = .{ .buffer = &buffer, .capacity = buffer.len };
            escape(&text, &out);
            try testing.expectEqual(out.len, escaped_bytes(&text));
            text[at] = 'x';
        }
    }
}
