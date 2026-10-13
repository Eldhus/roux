//! The host's test root: tidy over this tree, with fourneau's rules.
//!
//! The host builds only as libhost.a for `roc build`, so a test binary
//! checks the parts that need no Roc: the database (database_test.zig),
//! request handles, SSE framing, dev mode's pages and queries, backups'
//! names, the VM's escaping and digits. The compiler and the VM together
//! have their own root (templates_test.zig); the rest is tested through
//! the platform's examples.

const std = @import("std");
const tidy = @import("tidy");

test {
    _ = @import("backup.zig");
    _ = @import("database.zig");
    _ = @import("database_test.zig");
    _ = @import("dev.zig");
    _ = @import("requests.zig");
    _ = @import("sse.zig");
    _ = @import("templates.zig");
}

const trees = [_]tidy.Tree{
    .{
        .dir = "host",
        // templates_test.zig: its own test root, with the compiler imported.
        .roots = &.{
            "tests.zig",
            "templates_test.zig",
            "host.zig",
            "pad_archive.zig",
            "floor.zig",
        },
        .untested = &.{
            "tests.zig",
            "templates_test.zig",
            "host.zig",
            "pad_archive.zig",
            "roc_platform_abi.zig",
            "floor.zig",
        },
        .generated = &.{"roc_platform_abi.zig"},
        // host.zig: the Roc ABI, extern symbols and opaque boxes;
        // database.zig: SQLite's progress handler, a C callback;
        // templates_test.zig: a RocHost's allocator, the Roc ABI's.
        .interfaces = &.{ "host.zig", "database.zig", "templates_test.zig" },
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
        // root.zig is the `rocstache` module's root.
        .roots = &.{ "tests.zig", "root.zig" },
        .untested = &.{"tests.zig"},
        .generated = &.{},
        .interfaces = &.{},
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
