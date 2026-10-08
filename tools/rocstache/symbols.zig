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

/// The template with this id, as another object reaches it: its measure
/// and render, by their exported names (the dispatcher, a part calling a
/// partial).
pub fn Extern(comptime Ctx: type, comptime id: u64) type {
    return struct {
        pub const measure = @extern(*const fn (*const Ctx) callconv(.c) usize, .{
            .name = measure_name(id),
        });
        pub const draw = @extern(*const fn (*const Ctx, *Out) callconv(.c) void, .{
            .name = render_name(id),
        });
    };
}

const Out = @import("out.zig").Out;
