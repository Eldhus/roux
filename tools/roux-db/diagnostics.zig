//! What roux-db found wrong, each at a place in a file: collected for the
//! whole run (a person fixes them all at once), bounded, printed as
//! `file:line:column: message`.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// Problems kept; past this many the rest are counted, not kept.
pub const diagnostics_max = 64;
/// A message longer than this is cut short.
const message_bytes_max = 512;

pub const Diagnostic = struct {
    /// Index into the run's files (0 is schema.sql).
    file: u16,
    /// Byte offset in that file.
    offset: u32,
    message: []const u8,
};

pub const Diagnostics = struct {
    arena: Allocator,
    list: [diagnostics_max]Diagnostic = undefined,
    count: u32 = 0,
    dropped: u32 = 0,

    pub fn init(arena: Allocator) Diagnostics {
        return .{ .arena = arena };
    }

    pub fn add(
        diagnostics: *Diagnostics,
        file: u16,
        offset: u32,
        comptime format: []const u8,
        arguments: anytype,
    ) void {
        assert(diagnostics.count <= diagnostics_max);
        if (diagnostics.count == diagnostics_max) {
            diagnostics.dropped += 1;
            return;
        }
        var buffer: [message_bytes_max]u8 = undefined;
        // Too long: what fit, marked as cut.
        const text = std.fmt.bufPrint(&buffer, format, arguments) catch cut: {
            @memcpy(buffer[message_bytes_max - 3 ..], "...");
            break :cut buffer[0..];
        };
        const message = diagnostics.arena.dupe(u8, text) catch "(out of memory for the message)";
        diagnostics.list[diagnostics.count] = .{
            .file = file,
            .offset = offset,
            .message = message,
        };
        diagnostics.count += 1;
    }

    pub fn items(diagnostics: *const Diagnostics) []const Diagnostic {
        return diagnostics.list[0..diagnostics.count];
    }

    pub fn ok(diagnostics: *const Diagnostics) bool {
        return diagnostics.count == 0 and diagnostics.dropped == 0;
    }
};

pub const Position = struct { line: u32, column: u32 };

/// The 1-based line and column of `offset` in `text`: columns count bytes.
pub fn position(text: []const u8, offset: u32) Position {
    assert(offset <= text.len);
    var line: u32 = 1;
    var line_start: u32 = 0;
    for (text[0..offset], 0..) |byte, i| {
        if (byte == '\n') {
            line += 1;
            line_start = @intCast(i + 1);
        }
    }
    return .{ .line = line, .column = offset - line_start + 1 };
}

test "diagnostics: positions are 1-based lines and columns" {
    const text = "ab\ncd\n";
    try std.testing.expectEqual(Position{ .line = 1, .column = 1 }, position(text, 0));
    try std.testing.expectEqual(Position{ .line = 2, .column = 2 }, position(text, 4));
    try std.testing.expectEqual(Position{ .line = 3, .column = 1 }, position(text, 6));
}

test "diagnostics: past the bound, problems are counted, not kept" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostics = Diagnostics.init(arena_state.allocator());
    for (0..diagnostics_max + 3) |i| diagnostics.add(0, 0, "problem {d}", .{i});
    try std.testing.expectEqual(diagnostics_max, diagnostics.items().len);
    try std.testing.expectEqual(3, diagnostics.dropped);
    try std.testing.expect(!diagnostics.ok());
}
