//! SQLite for roux: the C API (`c`), the compile-time options (`options`)
//! and the few helpers the host, the tools and the floors share.
//!
//! The `sqlite` module carries `vendor/sqlite/sqlite3.c`, compiled with
//! `options.flags` (build.zig): importing the module links SQLite.

const std = @import("std");
const assert = std.debug.assert;

pub const c = @import("c.zig");
pub const options = @import("options.zig");
pub const authorizer = @import("authorizer.zig");
pub const types = @import("types.zig");
pub const vfs = @import("vfs.zig");
pub const mutex = @import("mutex.zig");

comptime {
    // SQLite calls these as it initializes (`SQLITE_OS_OTHER`): every
    // program linking SQLite exports them.
    _ = &vfs.sqlite3_os_init;
    _ = &vfs.sqlite3_os_end;
}

/// Statements one `exec` call runs, at most: setup scripts are short.
pub const exec_statements_max = 256;

/// Runs every statement of `sql` to completion, discarding rows: setup and
/// fixtures, never a request's path. Returns SQLite's code for the first
/// failure, with `c.sqlite3_errmsg(db)` saying why.
pub fn exec(db: *c.Db, sql: []const u8) error{Sqlite}!void {
    var rest: []const u8 = sql;
    for (0..exec_statements_max + 1) |_| {
        if (rest.len == 0) return;
        var stmt: ?*c.Stmt = null;
        var tail: [*]const u8 = rest.ptr;
        const prepared = c.sqlite3_prepare_v3(db, rest.ptr, @intCast(rest.len), 0, &stmt, &tail);
        if (prepared != c.ok) return error.Sqlite;
        const consumed: usize = @intFromPtr(tail) - @intFromPtr(rest.ptr);
        assert(consumed <= rest.len);
        rest = rest[consumed..];
        // A stretch of only whitespace and comments prepares to nothing.
        const statement = stmt orelse continue;
        defer _ = c.sqlite3_finalize(statement);
        try step_to_end(statement);
    } else unreachable; // a script longer than exec_statements_max
}

/// Steps a statement until it is done; rows are discarded. A statement that
/// returns rows forever is a bug in the caller's script.
fn step_to_end(statement: *c.Stmt) error{Sqlite}!void {
    const rows_max = 1 << 20;
    for (0..rows_max) |_| {
        switch (c.sqlite3_step(statement)) {
            c.row => {},
            c.done => return,
            else => return error.Sqlite,
        }
    } else unreachable;
}

/// 0 not yet, 1 being done, 2 done.
var initialized: std.atomic.Value(u32) = .init(0);

pub const Setup = struct {
    /// SQLite's whole heap (memsys5), allocated by the caller at startup:
    /// nothing is allocated after it, and memory running out is
    /// `SQLITE_NOMEM`, an error. Null: the system's allocator (the tools
    /// and the tests).
    heap: ?[]u8 = null,
};

/// SQLite set up for roux with the system's allocator; see `initialize_with`.
pub fn initialize() error{Sqlite}!void {
    return initialize_with(.{});
}

/// SQLite set up for roux, once per process before any connection (the
/// build has `SQLITE_OMIT_AUTOINIT`): roux's mutexes, the heap, and, as
/// SQLite initializes, roux's VFS (`sqlite3_os_init`, vfs.zig). Every
/// later call returns at once; a heap must come with the first.
pub fn initialize_with(setup: Setup) error{Sqlite}!void {
    if (initialized.load(.acquire) == 2) {
        assert(setup.heap == null); // too late for a heap: SQLite is set up
        return;
    }
    if (initialized.cmpxchgStrong(0, 1, .acquire, .acquire)) |_| {
        // Another thread is setting it up, for microseconds.
        for (0..1 << 24) |_| {
            if (initialized.load(.acquire) == 2) return;
            std.atomic.spinLoopHint();
        } else unreachable;
    }
    errdefer initialized.store(0, .release);
    try configure(setup);
    initialized.store(2, .release);
}

/// sqlite3_config, then sqlite3_initialize (which refuses configuration
/// after it).
fn configure(setup: Setup) error{Sqlite}!void {
    try mutex.install();
    if (setup.heap) |heap| {
        assert(heap.len >= heap_bytes_min);
        const length: c_int = @intCast(@min(heap.len, std.math.maxInt(c_int)));
        if (c.sqlite3_config(c.config_heap, heap.ptr, length, heap_allocation_min) != c.ok) {
            return error.Sqlite;
        }
    }
    if (c.sqlite3_initialize() != c.ok) return error.Sqlite;
}

/// memsys5's smallest block: allocations round up to a power of two.
const heap_allocation_min: c_int = 64;
const heap_bytes_min = 1 << 20;
