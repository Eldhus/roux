//! The host's test root: tidy over this tree, with fourneau's rules.
//!
//! The host builds only as libhost.a for `roc build`, so its behaviour is
//! tested through the platform's examples; what a test binary can check
//! here is the code itself, and the database, which knows nothing of Roc
//! (database_test.zig).

const std = @import("std");
const tidy = @import("tidy");

test {
    _ = @import("backup.zig");
    _ = @import("database.zig");
    _ = @import("database_test.zig");
    _ = @import("dev.zig");
    _ = @import("requests.zig");
}

const trees = [_]tidy.Tree{
    .{
        .dir = "host",
        .roots = &.{ "tests.zig", "host.zig", "pad_archive.zig", "floor.zig" },
        .untested = &.{
            "tests.zig",
            "host.zig",
            "pad_archive.zig",
            "roc_platform_abi.zig",
            "floor.zig",
        },
        .generated = &.{"roc_platform_abi.zig"},
        // host.zig: the Roc ABI, extern symbols and opaque boxes;
        // database.zig: SQLite's progress handler, a C callback.
        .interfaces = &.{ "host.zig", "database.zig" },
    },
    .{
        .dir = "sqlite",
        // sqlite.zig is the `sqlite` module's root, imported by name;
        // floor.zig a program.
        .roots = &.{ "tests.zig", "sqlite.zig", "floor.zig" },
        .untested = &.{ "tests.zig", "floor.zig" },
        .generated = &.{},
        // c.zig: SQLite's C API, whose callbacks are C function pointers;
        // authorizer.zig, vfs.zig and mutex.zig: tables of such callbacks.
        .interfaces = &.{ "c.zig", "authorizer.zig", "vfs.zig", "mutex.zig" },
    },
    .{
        .dir = "tools/roux-db",
        .roots = &.{ "tests.zig", "main.zig" },
        .untested = &.{"tests.zig"},
        .generated = &.{},
        .interfaces = &.{},
    },
    .{
        .dir = "tools/rocstache",
        // root.zig is the `rocstache` module's root; object.zig the root
        // of each app's templates object, compiled in the app's build
        // directory (generate.zig writes it there).
        .roots = &.{ "tests.zig", "root.zig", "object.zig" },
        .untested = &.{ "tests.zig", "object.zig" },
        .generated = &.{},
        // object.zig: the Roc ABI (the hosted function, the glue's
        // allocation table over the host's exports).
        .interfaces = &.{"object.zig"},
    },
    .{
        .dir = "tools/roux",
        .roots = &.{"main.zig"},
        .untested = &.{"main.zig"},
        .generated = &.{},
        .interfaces = &.{},
    },
};

test "tidy: the host obeys the rules a machine can check" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const problems = try tidy.check(arena_state.allocator(), std.testing.io, &trees);
    try std.testing.expectEqual(@as(u32, 0), problems);
}
