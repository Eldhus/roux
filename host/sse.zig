//! A server-sent event framed in one pass (WHATWG HTML, server-sent
//! events), for Sse.roc's `send!`: `event: name` (none when the name is
//! empty), each line of the data as `data: ` and the line, then a blank
//! line. A line ends at LF, CRLF or CR; data ending in a line break has an
//! empty last line.
//!
//! An event of any size, through memory of a fixed size: the host frames
//! it into the request's scratch memory a piece at a time, and sends each
//! piece as the stream's next chunk once it is full, the last when the
//! event is done. An event that fits is one piece, one chunk. The pieces'
//! boundaries fall anywhere, inside a line too: a client reads the stream
//! as bytes, so it cannot see them. An event takes effect only at its
//! blank line, so one cut off by a peer that left is lost whole, never
//! half applied.
//!
//! In Zig, not Roc: in Roc, splitting and joining the data on each kind of
//! line break was three quarters of a Datastar action's instructions.

const std = @import("std");
const assert = std.debug.assert;

/// Frame the event through `piece`, handing it to `sink.send` each time
/// it is full, and at the end what is left, if anything: the pieces, in
/// order, are the event. Every piece but the last is `piece.len` bytes;
/// the last has 1 to `piece.len`. An error from `sink.send` stops the
/// framing there, the rest unsent. The name has no line break (Sse.roc
/// checks).
pub fn frame(piece: []u8, name: []const u8, data: []const u8, sink: anytype) !void {
    assert(piece.len > 0);
    assert(find_break(name, 0) == null);
    var pieces: PiecesType(@TypeOf(sink)) = .{ .piece = piece, .sink = sink };
    if (name.len > 0) {
        try pieces.put("event: ");
        try pieces.put(name);
        try pieces.put("\n");
    }
    // A line per break, and the last: at most one more than the bytes.
    var start: usize = 0;
    for (0..data.len + 1) |_| {
        const end = find_break(data, start) orelse data.len;
        assert(end >= start);
        try pieces.put("data: ");
        try pieces.put(data[start..end]);
        try pieces.put("\n");
        if (end == data.len) break;
        start = end + break_length(data, end);
    } else unreachable;
    try pieces.put("\n");
    try pieces.end();
}

/// The piece being filled, and where its bytes go once it is full.
fn PiecesType(comptime Sink: type) type {
    return struct {
        piece: []u8,
        used: usize = 0,
        sink: Sink,

        const Pieces = @This();

        /// Never full on return: a full piece is sent at once. Inline: as a
        /// call it cost 9% more instructions a small event than framing in
        /// one pass did; inline, 0.9% (examples/sse `/count`, 2026-10-16).
        inline fn put(pieces: *Pieces, bytes: []const u8) !void {
            assert(pieces.used < pieces.piece.len);
            // Room to spare, as for every part of a small event: one copy.
            if (bytes.len < pieces.piece.len - pieces.used) {
                @memcpy(pieces.piece[pieces.used..][0..bytes.len], bytes);
                pieces.used += bytes.len;
                return;
            }
            try pieces.put_filling(bytes);
        }

        /// `bytes` fill the piece at least once.
        fn put_filling(pieces: *Pieces, bytes: []const u8) !void {
            assert(bytes.len >= pieces.piece.len - pieces.used);
            var rest = bytes;
            // Each pass copies at least one byte, and the last finds none.
            for (0..bytes.len + 1) |_| {
                if (rest.len == 0) break;
                const count = @min(rest.len, pieces.piece.len - pieces.used);
                assert(count > 0);
                @memcpy(pieces.piece[pieces.used..][0..count], rest[0..count]);
                pieces.used += count;
                rest = rest[count..];
                if (pieces.used == pieces.piece.len) {
                    try pieces.sink.send(pieces.piece);
                    pieces.used = 0;
                }
            } else unreachable;
            assert(rest.len == 0);
            assert(pieces.used < pieces.piece.len);
        }

        /// The last piece, what is left: none when the event filled its
        /// last piece exactly, which `put` has sent already.
        fn end(pieces: *Pieces) !void {
            if (pieces.used == 0) return;
            try pieces.sink.send(pieces.piece[0..pieces.used]);
            pieces.used = 0;
        }
    };
}

/// The first CR or LF from `start`, sixteen bytes at a time:
/// `std.mem.indexOfAnyPos` compares byte by byte, and was a fifth of a
/// Datastar action's instructions.
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

/// A test's sink: the pieces joined in `out`, each checked as `frame`
/// promises (full but for the last, never empty); `fail_at`, the send that
/// fails.
const Collected = struct {
    out: []u8,
    piece_bytes: usize,
    len: usize = 0,
    sends: usize = 0,
    last_short: bool = false,
    fail_at: ?usize = null,

    fn send(collected: *Collected, bytes: []const u8) !void {
        if (collected.fail_at == collected.sends) return error.Disconnected;
        // Only the last piece is short.
        try std.testing.expect(!collected.last_short);
        try std.testing.expect(bytes.len > 0 and bytes.len <= collected.piece_bytes);
        collected.last_short = bytes.len < collected.piece_bytes;
        @memcpy(collected.out[collected.len..][0..bytes.len], bytes);
        collected.len += bytes.len;
        collected.sends += 1;
    }

    fn joined(collected: *const Collected) []const u8 {
        return collected.out[0..collected.len];
    }
};

test "sse: an event framed" {
    var piece: [256]u8 = undefined;
    var out: [256]u8 = undefined;
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
        var collected: Collected = .{ .out = &out, .piece_bytes = piece.len };
        try frame(&piece, case[0], case[1], &collected);
        try std.testing.expectEqualStrings(case[2], collected.joined());
        try std.testing.expectEqual(1, collected.sends); // it fits: one chunk
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

test "sse: an event framed through pieces of every size, from a byte to past its length" {
    const name = "patch";
    const data = "a\r\nbc\rd";
    const framed = "event: patch\ndata: a\ndata: bc\ndata: d\n\n";
    var piece: [framed.len + 1]u8 = undefined;
    var out: [framed.len]u8 = undefined;
    for (1..piece.len + 1) |size| {
        var collected: Collected = .{ .out = &out, .piece_bytes = size };
        try frame(piece[0..size], name, data, &collected);
        try std.testing.expectEqualStrings(framed, collected.joined());
        try std.testing.expectEqual(@divCeil(framed.len, size), collected.sends);
    }
}

test "sse: a send that fails stops the framing at that piece, at every piece" {
    const data = "a\nb\nc\nd";
    const framed = "data: a\ndata: b\ndata: c\ndata: d\n\n";
    const size = 4;
    const sends = @divCeil(framed.len, size);
    var piece: [size]u8 = undefined;
    var out: [framed.len]u8 = undefined;
    for (0..sends) |fail_at| {
        var collected: Collected = .{ .out = &out, .piece_bytes = size, .fail_at = fail_at };
        try std.testing.expectError(error.Disconnected, frame(&piece, "", data, &collected));
        try std.testing.expectEqual(fail_at, collected.sends);
        try std.testing.expectEqualStrings(framed[0 .. fail_at * size], collected.joined());
    }
}

test "sse: a MiB event, lines short and one long, through the host's 64 KiB piece" {
    const gpa = std.testing.allocator;
    const data = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(data);
    // Lines a few bytes long, by each kind of break (CR, LF, CRLF, empty
    // lines), in a pattern that does not repeat with the piece; then one
    // line longer than a piece.
    for (data, 0..) |*byte, index| byte.* = "abc\r\n"[(index * 7 + index / 3) % 5];
    @memset(data[data.len / 2 ..][0 .. 100 * 1024], 'x');
    // Each line adds at most `data: ` and a line feed; the last its blank
    // line too.
    const bound = "event: patch\n".len + data.len + (data.len + 1) * "data: \n".len + 1;
    const whole = try gpa.alloc(u8, bound);
    defer gpa.free(whole);
    const expected = try gpa.alloc(u8, bound);
    defer gpa.free(expected);
    var one: Collected = .{ .out = expected, .piece_bytes = bound };
    try frame(whole, "patch", data, &one);
    try std.testing.expectEqual(1, one.sends);

    const piece = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(piece);
    const out = try gpa.alloc(u8, bound);
    defer gpa.free(out);
    var pieces: Collected = .{ .out = out, .piece_bytes = piece.len };
    try frame(piece, "patch", data, &pieces);
    try std.testing.expectEqualSlices(u8, one.joined(), pieces.joined());
    try std.testing.expect(pieces.sends > 16);
}
