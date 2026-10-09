//! The templates' program as bytes: what `roux build` attaches after the
//! executable roc linked, and what `roux dev` has a running app reread
//! (`templates.bin`). The host reads it (host/templates.zig). No compiler
//! runs and nothing links, so a markup edit costs only the generation.
//!
//! The program: the code's length in words, the text's in bytes, the
//! layouts' identity (a hash of what glue laid the contracts out from: the
//! host rereads in development only a program made for the layouts it was
//! built with), the code, the text, then `slack` zero bytes (the host
//! copies runs in 32-byte blocks that may run past the text's end), then
//! zeros to a whole word.
//!
//! Attached, a trailer follows it: the program's length in bytes and
//! `magic`, the executable's last 16 bytes.

const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;

pub const slack = 32;

/// The trailer's last 8 bytes: an executable with a program attached.
pub const magic = "ROUXTPL1";

pub const Program = struct {
    code: []const u64,
    text: []const u8,
    /// The layouts' identity (generate.zig).
    layouts: u64,
};

pub fn write(program: Program, writer: *Writer) Writer.Error!void {
    try int(writer, u64, program.code.len);
    try int(writer, u64, program.text.len);
    try int(writer, u64, program.layouts);
    for (program.code) |w| try int(writer, u64, w);
    try writer.writeAll(program.text);
    try writer.splatByteAll(0, slack + padding(program.text.len));
}

/// The trailer for a program of `length` bytes (`write`'s, whole words).
pub fn trailer(length: usize) [16]u8 {
    assert(length % 8 == 0);
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], length, .little);
    bytes[8..].* = magic.*;
    return bytes;
}

/// Zeros after the text and the slack, to a whole word.
fn padding(text_len: usize) usize {
    return (8 - (text_len + slack) % 8) % 8;
}

fn int(writer: *Writer, comptime T: type, value: anytype) Writer.Error!void {
    try writer.writeInt(T, @intCast(value), .little);
}

test "program: whole words, and the trailer" {
    var buffer: [256]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    const code = [_]u64{ 2, 0 };
    try write(.{ .code = &code, .text = "abc", .layouts = 7 }, &writer);
    const written = writer.buffered();
    try std.testing.expectEqual(@as(usize, 0), written.len % 8);
    try std.testing.expectEqual(@as(usize, 24 + 16 + 3 + slack + 5), written.len);
    const end = trailer(written.len);
    try std.testing.expectEqual(@as(u64, written.len), std.mem.readInt(u64, end[0..8], .little));
    try std.testing.expectEqualStrings(magic, end[8..]);
}
