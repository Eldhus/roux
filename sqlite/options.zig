//! SQLite's compile-time options for roux, each with why. `build.zig`
//! compiles `vendor/sqlite/sqlite3.c` with `flags`; `tests.zig` asserts
//! that SQLite reports each one (`sqlite3_compileoption_used`), so the
//! build is what this file says.
//!
//! The rest of SQLite's behaviour is set at run time, explicitly, on every
//! connection (PRAGMAs read back, every `sqlite3_limit`), never left to a
//! default.

const assert = @import("std").debug.assert;

/// The vendored release (vendor/sqlite/README.md); a test asserts it is
/// the one linked.
pub const version = "3.53.4";

pub const Option = struct {
    /// Defined as `-D<define>`.
    define: []const u8,
    /// As `sqlite3_compileoption_used` knows it, which is not always the
    /// define (no prefix, and some without their value); null for an option
    /// SQLite does not list (`HAVE_` options describe the system).
    reported: ?[:0]const u8,
};

pub const options = [_]Option{
    // Connections are never used by two threads at once: readers stay on
    // their shard, the writer moves only under its lock. Not 0: shards are
    // threads, and SQLite's global state (allocator, page cache) needs its
    // mutexes.
    .{ .define = "SQLITE_THREADSAFE=2", .reported = "THREADSAFE=2" },
    // Double quotes are identifiers only: a misspelt column is an error,
    // not a string literal.
    .{ .define = "SQLITE_DQS=0", .reported = "DQS=0" },
    // No global memory statistics: they take a mutex on every allocation.
    .{ .define = "SQLITE_DEFAULT_MEMSTATUS=0", .reported = "DEFAULT_MEMSTATUS=0" },
    // Foreign keys enforced; each connection also says so (read back).
    .{ .define = "SQLITE_DEFAULT_FOREIGN_KEYS=1", .reported = "DEFAULT_FOREIGN_KEYS" },
    .{ .define = "SQLITE_LIKE_DOESNT_MATCH_BLOBS", .reported = "LIKE_DOESNT_MATCH_BLOBS" },
    .{ .define = "SQLITE_OMIT_DEPRECATED", .reported = "OMIT_DEPRECATED" },
    .{ .define = "SQLITE_OMIT_SHARED_CACHE", .reported = "OMIT_SHARED_CACHE" },
    // The binary is all there is: no extension is ever loaded.
    .{ .define = "SQLITE_OMIT_LOAD_EXTENSION", .reported = "OMIT_LOAD_EXTENSION" },
    // `sqlite3_initialize` is ours to call, at startup, after configuring.
    .{ .define = "SQLITE_OMIT_AUTOINIT", .reported = "OMIT_AUTOINIT" },
    // Small temporary buffers on the stack instead of the heap.
    .{ .define = "SQLITE_USE_ALLOCA", .reported = "USE_ALLOCA" },
    .{ .define = "SQLITE_STRICT_SUBTYPE=1", .reported = "STRICT_SUBTYPE" },
    // No memory-mapped I/O: every read goes through the VFS, and a disk
    // error is an error, not a SIGBUS.
    .{ .define = "SQLITE_MAX_MMAP_SIZE=0", .reported = "MAX_MMAP_SIZE=0" },
    // A statement's journal in memory, never spilled to a temporary file:
    // roux's VFS opens only the database, its WAL and its journal.
    .{ .define = "SQLITE_STMTJRNL_SPILL=-1", .reported = "STMTJRNL_SPILL=-1" },
    // Temporary tables and indices in memory: no temporary files.
    .{ .define = "SQLITE_TEMP_STORE=3", .reported = "TEMP_STORE=3" },
    // A heap of the host's, allocated at startup (sqlite.zig's `Setup`).
    .{ .define = "SQLITE_ENABLE_MEMSYS5", .reported = "ENABLE_MEMSYS5" },
    // The generator types a result column by its origin table and column.
    .{ .define = "SQLITE_ENABLE_COLUMN_METADATA", .reported = "ENABLE_COLUMN_METADATA" },
    // Without it the unix VFS syncs data with fsync, flushing metadata too.
    .{ .define = "HAVE_FDATASYNC=1", .reported = null },
    // Without it the unix VFS sleeps in whole seconds when it waits.
    .{ .define = "HAVE_USLEEP=1", .reported = null },
};

pub const flags = flags: {
    var result: [options.len][]const u8 = undefined;
    for (options, &result) |option, *flag| flag.* = "-D" ++ option.define;
    break :flags result;
};

/// SQLite's own assertions and checks, for the tests (Debug) only: they
/// cost too much for a server.
pub const flags_debug = flags ++ [_][]const u8{"-DSQLITE_DEBUG"};

comptime {
    // The tests build what the server builds, plus SQLite's assertions.
    assert(flags_debug.len == flags.len + 1);
}
