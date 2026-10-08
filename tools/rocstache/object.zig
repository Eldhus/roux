//! The dispatcher of an app's templates: the object roux build links with
//! roc's archive of the app and one object per template (part.zig), all
//! compiled in the app's build directory beside the registry roux build
//! wrote (templates.zig) and the contracts' glue.
//!
//! It is the host side of `Rocstache.compiled_render!`: Roc passes a
//! template's id and its contract boxed; this calls the part compiled for
//! exactly that contract, to measure and then render into a new Roc
//! `Str`, and releases the box (a hosted function owns its arguments).
//! Memory comes from the host's `roc_alloc`, as Roc's own does, so the
//! host's per-shard count of live allocations sees it.

const std = @import("std");
const assert = std.debug.assert;
const registry = @import("templates.zig");
const symbols = @import("symbols.zig");
const Out = @import("out.zig").Out;
const abi = registry.abi;

extern fn roc_alloc(length: usize, alignment: usize) callconv(.c) *anyopaque;
extern fn roc_dealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void;

pub const panic = symbols.panic;

export fn hosted_template_render(id: u64, box: abi.RocBox) callconv(.c) abi.RocStr {
    inline for (registry.all) |entry| {
        if (id == entry.id) return render_boxed(entry.id, entry.Ctx, box);
    }
    // The app's Roc names a contract this object was not built with: its
    // `Page.roc` changed without a `roux build`.
    @panic("a template id not in this app's templates object: run roux build");
}

fn render_boxed(comptime id: u64, comptime Ctx: type, box: abi.RocBox) abi.RocStr {
    const Measure = fn (*const Ctx) callconv(.c) usize;
    const Draw = fn (*const Ctx, *Out) callconv(.c) void;
    const measure = @extern(*const Measure, .{ .name = symbols.measure_name(id) });
    const draw = @extern(*const Draw, .{ .name = symbols.render_name(id) });
    const ctx: *const Ctx = @ptrCast(@alignCast(box.?));
    const size = measure(ctx);
    const result: abi.RocStr = if (size == 0) .empty() else blk: {
        // A Roc string's heap bytes follow a reference count of one word.
        const base: [*]u8 = @ptrCast(roc_alloc(@sizeOf(usize) + size, @alignOf(usize)));
        @as(*isize, @ptrCast(@alignCast(base))).* = 1;
        var out: Out = .{ .buffer = base + @sizeOf(usize), .capacity = size };
        draw(ctx, &out);
        assert(out.len == size);
        break :blk .{ .bytes = out.buffer, .capacity_or_alloc_ptr = size << 1, .length = size };
    };
    const refcounted = comptime holds_refcounted(Ctx);
    abi.decrefBoxWith(box, @alignOf(Ctx), refcounted, Release(Ctx).callback(), &host);
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
