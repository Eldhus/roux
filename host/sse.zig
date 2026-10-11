//! A server-sent event framed in one pass (WHATWG HTML, server-sent
//! events), for Sse.roc's `send!`: `event: name` (none when the name is
//! empty), each line of the data as `data: ` and the line, then a blank
//! line. A line ends at LF, CRLF or CR; data ending in a line break has an
//! empty last line.
//!
//! Framed by the host into the request's scratch memory, then sent as one
//! chunk: in Roc, splitting and joining the data on each kind of line
//! break was three quarters of a Datastar action's instructions (measured).

const std = @import("std");
const assert = std.debug.assert;

/// The event's bytes at the start of `out`, or null when they do not fit.
/// The name has no line break (Sse.roc checks).
pub fn frame(out: []u8, name: []const u8, data: []const u8) ?[]const u8 {
    assert(find_break(name, 0) == null);
    var written: usize = 0;
    if (name.len > 0) {
        written = put(out, written, "event: ") orelse return null;
        written = put(out, written, name) orelse return null;
        written = put(out, written, "\n") orelse return null;
    }
    // A line per break, and the last: at most one more than the bytes.
    var start: usize = 0;
    for (0..data.len + 1) |_| {
        const end = find_break(data, start) orelse data.len;
        assert(end >= start);
        written = put(out, written, "data: ") orelse return null;
        written = put(out, written, data[start..end]) orelse return null;
        written = put(out, written, "\n") orelse return null;
        if (end == data.len) break;
        start = end + break_length(data, end);
    } else unreachable;
    written = put(out, written, "\n") orelse return null;
    assert(written <= out.len);
    return out[0..written];
}

/// The first CR or LF from `start`, sixteen bytes at a time:
/// `std.mem.indexOfAnyPos` compares byte by byte, and was a fifth of a
/// Datastar action's instructions (measured).
pub fn find_break(data: []const u8, start: usize) ?usize {
    assert(start <= data.len);
    const lanes = 16;
    const Lanes = @Vector(lanes, u8);
    var at = start;
    while (at + lanes <= data.len) : (at += lanes) {
        const chunk: Lanes = data[at..][0..lanes].*;
        const lf: u16 = @bitCast(chunk == @as(Lanes, @splat('\n')));
        const cr: u16 = @bitCast(chunk == @as(Lanes, @splat('\r')));
        const breaks = lf | cr;
        if (breaks != 0) return at + @ctz(breaks);
    }
    assert(data.len - at < lanes);
    for (data[at..], at..) |byte, index| {
        if (byte == '\n' or byte == '\r') return index;
    }
    return null;
}

/// The line break at `at`: CRLF is one.
fn break_length(data: []const u8, at: usize) usize {
    assert(data[at] == '\r' or data[at] == '\n');
    if (data[at] == '\r' and at + 1 < data.len and data[at + 1] == '\n') return 2;
    return 1;
}

fn put(out: []u8, at: usize, bytes: []const u8) ?usize {
    assert(at <= out.len);
    if (bytes.len > out.len - at) return null;
    @memcpy(out[at..][0..bytes.len], bytes);
    return at + bytes.len;
}

test "sse: an event framed" {
    var buffer: [256]u8 = undefined;
    const cases = [_][3][]const u8{
        .{ "", "hi", "data: hi\n\n" },
        .{ "patch", "a\nb", "event: patch\ndata: a\ndata: b\n\n" },
        .{ "", "a\r\nb\rc", "data: a\ndata: b\ndata: c\n\n" },
        .{ "", "", "data: \n\n" },
        .{ "", "\r\n\r\n", "data: \ndata: \ndata: \n\n" },
        .{ "", "x\r", "data: x\ndata: \n\n" },
        .{ "", "x\n", "data: x\ndata: \n\n" },
        .{
            "datastar-patch-elements",
            "elements <div id=\"a\">\nelements </div>",
            "event: datastar-patch-elements\ndata: elements <div id=\"a\">\n" ++
                "data: elements </div>\n\n",
        },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case[2], frame(&buffer, case[0], case[1]).?);
    }
}

test "sse: line breaks found as std finds them, at every position and length" {
    // Every length across two vectors and a tail; no break, or one of
    // either kind anywhere; every start.
    var data: [40]u8 = undefined;
    for (0..data.len + 1) |length| {
        for (0..length + 1) |position| {
            for ("\r\n") |kind| {
                @memset(data[0..length], 'a');
                if (position < length) data[position] = kind;
                for (0..length + 1) |start| {
                    try std.testing.expectEqual(
                        std.mem.indexOfAnyPos(u8, data[0..length], start, "\r\n"),
                        find_break(data[0..length], start),
                    );
                }
            }
        }
    }
}

test "sse: an event that does not fit is refused, at every size short of it" {
    const name = "patch";
    const data = "a\r\nbc\rd";
    const framed = "event: patch\ndata: a\ndata: bc\ndata: d\n\n";
    var buffer: [framed.len]u8 = undefined;
    try std.testing.expectEqualStrings(framed, frame(&buffer, name, data).?);
    for (0..framed.len) |size| {
        try std.testing.expect(frame(buffer[0..size], name, data) == null);
    }
}
