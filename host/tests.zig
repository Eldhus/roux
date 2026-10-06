//! The host's test root: tidy over this tree, with fourneau's rules.
//!
//! The host builds only as libhost.a for `roc build`, so its behaviour is
//! tested through the platform's examples; what a test binary can check
//! here is the code itself.

const std = @import("std");
const tidy = @import("tidy");

const trees = [_]tidy.Tree{
    .{
        .dir = "host",
        .roots = &.{ "tests.zig", "host.zig", "pad_archive.zig" },
        .untested = &.{ "tests.zig", "host.zig", "pad_archive.zig", "roc_platform_abi.zig" },
        .generated = &.{"roc_platform_abi.zig"},
        // host.zig: the Roc ABI, extern symbols and opaque boxes.
        .interfaces = &.{"host.zig"},
    },
    .{
        .dir = "sqlite",
        // sqlite.zig is the `sqlite` module's root, imported by name;
        // floor.zig a program.
        .roots = &.{ "tests.zig", "sqlite.zig", "floor.zig" },
        .untested = &.{ "tests.zig", "floor.zig" },
        .generated = &.{},
        // c.zig: SQLite's C API, whose callbacks are C function pointers.
        .interfaces = &.{"c.zig"},
    },
};

test "tidy: the host obeys the rules a machine can check" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const problems = try tidy.check(arena_state.allocator(), std.testing.io, &trees);
    try std.testing.expectEqual(@as(u32, 0), problems);
}
