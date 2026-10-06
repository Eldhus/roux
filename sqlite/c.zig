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

// What an authorizer returns to refuse an action: the prepare fails.
pub const deny = 1;

// Flags for `open_v2`.
pub const open_readwrite = 0x00000002;
pub const open_create = 0x00000004;
pub const open_memory = 0x00000080;
pub const open_exrescode = 0x02000000;

// Fundamental datatypes, as `column_type` returns them.
pub const text = 3;
pub const null_type = 5;

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

pub extern fn sqlite3_set_authorizer(
    db: *Db,
    callback: ?*const fn (
        user: ?*anyopaque,
        action: c_int,
        first: ?[*:0]const u8,
        second: ?[*:0]const u8,
        database: ?[*:0]const u8,
        trigger: ?[*:0]const u8,
    ) callconv(.c) c_int,
    user: ?*anyopaque,
) c_int;

pub extern fn sqlite3_stmt_readonly(stmt: *Stmt) c_int;
pub extern fn sqlite3_bind_parameter_count(stmt: *Stmt) c_int;
pub extern fn sqlite3_bind_parameter_name(stmt: *Stmt, index: c_int) ?[*:0]const u8;
/// `destructor` null is SQLITE_STATIC: the bytes outlive the statement's use.
pub extern fn sqlite3_bind_text64(
    stmt: *Stmt,
    index: c_int,
    text: [*]const u8,
    bytes: u64,
    destructor: ?*const fn (?*anyopaque) callconv(.c) void,
    encoding: u8,
) c_int;
pub const utf8: u8 = 1;
pub extern fn sqlite3_column_name(stmt: *Stmt, column: c_int) ?[*:0]const u8;
pub extern fn sqlite3_column_table_name(stmt: *Stmt, column: c_int) ?[*:0]const u8;
pub extern fn sqlite3_column_origin_name(stmt: *Stmt, column: c_int) ?[*:0]const u8;
pub extern fn sqlite3_column_decltype(stmt: *Stmt, column: c_int) ?[*:0]const u8;
/// Our patch (vendor/sqlite/README.md): 1 when the result column can be
/// NULL, 0 when it never is, -1 for an expression SQLite cannot prove.
pub extern fn sqlite3_column_nullable(stmt: *Stmt, column: c_int) c_int;

pub const interrupt = 9;
pub const constraint = 19;

pub const open_nomutex = 0x00008000;
/// For `prepare_v3`: kept for the connection's life.
pub const prepare_persistent: c_uint = 0x01;

pub const integer = 1;
pub const float = 2;
pub const blob = 4;

pub extern fn sqlite3_errcode(db: *Db) c_int;
pub extern fn sqlite3_get_autocommit(db: *Db) c_int;
pub extern fn sqlite3_stmt_busy(stmt: *Stmt) c_int;
pub extern fn sqlite3_next_stmt(db: *Db, stmt: ?*Stmt) ?*Stmt;
pub extern fn sqlite3_clear_bindings(stmt: *Stmt) c_int;
pub extern fn sqlite3_bind_null(stmt: *Stmt, index: c_int) c_int;
pub extern fn sqlite3_bind_double(stmt: *Stmt, index: c_int, value: f64) c_int;
/// `destructor` null is SQLITE_STATIC, as for `bind_text64`.
pub extern fn sqlite3_bind_blob64(
    stmt: *Stmt,
    index: c_int,
    bytes: ?[*]const u8,
    length: u64,
    destructor: ?*const fn (?*anyopaque) callconv(.c) void,
) c_int;
pub extern fn sqlite3_column_double(stmt: *Stmt, column: c_int) f64;
pub extern fn sqlite3_column_blob(stmt: *Stmt, column: c_int) ?[*]const u8;

/// Called every `instructions` virtual-machine steps; non-zero interrupts.
pub extern fn sqlite3_progress_handler(
    db: *Db,
    instructions: c_int,
    callback: ?*const fn (user: ?*anyopaque) callconv(.c) c_int,
    user: ?*anyopaque,
) void;

/// Sets limit `id` to `value` (unless negative); returns the old value.
pub extern fn sqlite3_limit(db: *Db, id: c_int, value: c_int) c_int;
pub const limit_length = 0;
pub const limit_sql_length = 1;
pub const limit_column = 2;
pub const limit_expr_depth = 3;
pub const limit_compound_select = 4;
pub const limit_vdbe_op = 5;
pub const limit_function_arg = 6;
pub const limit_attached = 7;
pub const limit_like_pattern_length = 8;
pub const limit_variable_number = 9;
pub const limit_trigger_depth = 10;
pub const limit_worker_threads = 11;

/// `(db, op, int value, int *readback)` for the boolean options below.
pub extern fn sqlite3_db_config(db: *Db, op: c_int, ...) c_int;
pub const dbconfig_enable_trigger = 1003;
pub const dbconfig_defensive = 1010;
pub const dbconfig_dqs_dml = 1013;
pub const dbconfig_dqs_ddl = 1014;
pub const dbconfig_enable_view = 1015;
pub const dbconfig_trusted_schema = 1017;
