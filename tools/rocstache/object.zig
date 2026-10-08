//! The root of an app's templates object (`templates.o`), compiled in the
//! app's build directory beside the registry roux build wrote
//! (templates.zig) and the contracts' glue. roux links it with roc's
//! archive of the app and the host.
//!
//! It is the host side of `Rocstache.compiled_render!`: Roc passes a
//! template's id and its contract boxed; this renders the template
//! compiled for exactly that contract into a new Roc `Str`, and releases
//! the box (a hosted function owns its arguments). Memory comes from the
//! host's `roc_alloc`, as Roc's own does, so the host's per-shard count of
//! live allocations sees it.

const std = @import("std");
const assert = std.debug.assert;
const registry = @import("templates.zig");
const render = @import("render.zig");
const abi = registry.abi;

extern fn roc_alloc(length: usize, alignment: usize) callconv(.c) *anyopaque;
extern fn roc_dealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void;

export fn hosted_template_render(id: u64, box: abi.RocBox) callconv(.c) abi.RocStr {
    inline for (registry.all, 0..) |entry, index| {
        if (id == entry.id) return render_boxed(index, box);
    }
    // The app's Roc names a contract this object was not built with: its
    // `Page.roc` changed without a `roux build`.
    std.debug.panic("template 0x{x:0>16} is not in this app's templates: run roux build", .{id});
}

fn render_boxed(comptime index: usize, box: abi.RocBox) abi.RocStr {
    const T = render.Compiled(registry, index);
    const ctx: *const T.Ctx = @ptrCast(@alignCast(box.?));
    const size = T.measure(ctx);
    const result: abi.RocStr = if (size == 0) .empty() else blk: {
        // A Roc string's heap bytes follow a reference count of one word.
        const base: [*]u8 = @ptrCast(roc_alloc(@sizeOf(usize) + size, @alignOf(usize)));
        @as(*isize, @ptrCast(@alignCast(base))).* = 1;
        var out: render.Out = .{ .buffer = base + @sizeOf(usize), .capacity = size };
        T.render(ctx, &out);
        assert(out.len == size);
        break :blk .{ .bytes = out.buffer, .capacity_or_alloc_ptr = size << 1, .length = size };
    };
    const refcounted = comptime holds_refcounted(T.Ctx);
    abi.decrefBoxWith(box, @alignOf(T.Ctx), refcounted, Release(T.Ctx).callback(), &host);
    return result;
}

/// Whether a contract holds a `Str` or a `List`: Roc's box header is
/// larger when it does, so the release must know.
fn holds_refcounted(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (@hasField(T, "capacity_or_alloc_ptr")) return true; // a Str or a List
    inline for (@typeInfo(T).@"struct".field_types) |F| {
        if (comptime holds_refcounted(F)) return true;
    }
    return false;
}

/// The box's teardown: the contract's own glue-generated `decref`.
fn Release(comptime Ctx: type) type {
    return struct {
        fn payload(data: ?*anyopaque, roc_host: *abi.RocHost) callconv(.c) void {
            const ctx: *const Ctx = @ptrCast(@alignCast(data.?));
            ctx.decref(roc_host);
        }

        fn callback() ?abi.RocBoxPayloadDecref {
            return if (comptime holds_refcounted(Ctx)) &payload else null;
        }
    };
}

// The glue's helpers allocate through a table; it points at the host's
// exports, as Roc's compiled code does.
var host_env: u8 = 0;
var host: abi.RocHost = .{
    .env = &host_env,
    .roc_alloc = host_alloc,
    .roc_dealloc = host_dealloc,
    .roc_realloc = host_realloc,
    .roc_dbg = host_ignore,
    .roc_expect_failed = host_ignore,
    .roc_crashed = host_ignore,
};

fn host_alloc(_: *abi.RocHost, length: usize, alignment: usize) callconv(.c) *anyopaque {
    return roc_alloc(length, alignment);
}

fn host_dealloc(_: *abi.RocHost, ptr: *anyopaque, alignment: usize) callconv(.c) void {
    roc_dealloc(ptr, alignment);
}

fn host_realloc(_: *abi.RocHost, _: *anyopaque, _: usize, _: usize) callconv(.c) *anyopaque {
    @panic("the templates object never reallocates");
}

fn host_ignore(_: *abi.RocHost, _: [*]const u8, _: usize) callconv(.c) void {}
