//! SQLite for roux: the C API (`c`), the compile-time options (`options`)
//! and the few helpers the host, the tools and the floors share.
//!
//! The `sqlite` module carries `vendor/sqlite/sqlite3.c`, compiled with
//! `options.flags` (build.zig): importing the module links SQLite.

const std = @import("std");
const assert = std.debug.assert;

pub const c = @import("c.zig");
pub const options = @import("options.zig");

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

/// `sqlite3_initialize`, once per process before any connection (the build
/// has `SQLITE_OMIT_AUTOINIT`). Idempotent, as SQLite's is.
pub fn initialize() error{Sqlite}!void {
    if (c.sqlite3_initialize() != c.ok) return error.Sqlite;
}
