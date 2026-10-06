//! SQLite's C API, as much as roux calls, written by hand from
//! `vendor/sqlite/sqlite3.h` (no `@cImport`: what crosses is what is
//! named here). An interface file: SQLite's callbacks are C function
//! pointers over C `void *` user data, by its design.

pub const Db = opaque {};
pub const Stmt = opaque {};

// Result codes (sqlite3.h, "Result Codes"): the primary code is the low
// byte of an extended one.
pub const ok = 0;
pub const row = 100;
pub const done = 101;

// Flags for `open_v2`.
pub const open_readwrite = 0x00000002;
pub const open_create = 0x00000004;
pub const open_memory = 0x00000080;
pub const open_exrescode = 0x02000000;

// Fundamental datatypes, as `column_type` returns them.
pub const text = 3;

pub extern fn sqlite3_initialize() c_int;
pub extern fn sqlite3_libversion() [*:0]const u8;
pub extern fn sqlite3_compileoption_used(name: [*:0]const u8) c_int;

pub extern fn sqlite3_open_v2(
    filename: [*:0]const u8,
    db: *?*Db,
    flags: c_int,
    vfs: ?[*:0]const u8,
) c_int;
pub extern fn sqlite3_close_v2(db: ?*Db) c_int;
pub extern fn sqlite3_errmsg(db: ?*Db) [*:0]const u8;
pub extern fn sqlite3_errstr(code: c_int) [*:0]const u8;
pub extern fn sqlite3_error_offset(db: *Db) c_int;

pub extern fn sqlite3_prepare_v3(
    db: *Db,
    sql: [*]const u8,
    sql_bytes: c_int,
    flags: c_uint,
    stmt: *?*Stmt,
    tail: ?*[*]const u8,
) c_int;
pub extern fn sqlite3_step(stmt: *Stmt) c_int;
pub extern fn sqlite3_reset(stmt: *Stmt) c_int;
pub extern fn sqlite3_finalize(stmt: ?*Stmt) c_int;

pub extern fn sqlite3_bind_int64(stmt: *Stmt, index: c_int, value: i64) c_int;

pub extern fn sqlite3_column_count(stmt: *Stmt) c_int;
pub extern fn sqlite3_column_type(stmt: *Stmt, column: c_int) c_int;
pub extern fn sqlite3_column_int64(stmt: *Stmt, column: c_int) i64;
pub extern fn sqlite3_column_text(stmt: *Stmt, column: c_int) ?[*]const u8;
pub extern fn sqlite3_column_bytes(stmt: *Stmt, column: c_int) c_int;
