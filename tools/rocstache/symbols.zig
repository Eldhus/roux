//! What the dispatcher (object.zig) and the parts (part.zig) agree on: the
//! names a part exports, and the panic handler both objects use.

const std = @import("std");

extern fn roc_crashed(bytes: [*]const u8, len: usize) callconv(.c) void;

/// A failed safety check reports through the host, which prints it and
/// aborts. Not std's default handler: its stack traces cost ~290 ms of
/// every Debug compile of an object (DIARY, 2026-10-07).
pub const panic = std.debug.FullPanic(crash);

fn crash(message: []const u8, _: ?usize) noreturn {
    roc_crashed(message.ptr, message.len);
    @trap(); // roc_crashed aborts; this is never reached
}

/// The exported names of the template with this id.
pub fn measure_name(comptime id: u64) []const u8 {
    return std.fmt.comptimePrint("rocstache_measure_{x:0>16}", .{id});
}

pub fn render_name(comptime id: u64) []const u8 {
    return std.fmt.comptimePrint("rocstache_render_{x:0>16}", .{id});
}
