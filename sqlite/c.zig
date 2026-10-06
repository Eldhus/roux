//! SQLite's C API, as much as roux calls, written by hand from
//! `vendor/sqlite/sqlite3.h` (no `@cImport`: what crosses is what is
//! named here). An interface file: SQLite's callbacks are C function
//! pointers over C `void *` user data, by its design.

pub const Db = opaque {};
pub const Stmt = opaque {};

// Result codes (sqlite3.h, "Result Codes"): the primary code is the low
// byte of an extended one.
pub const ok = 0;
pub const busy = 5;
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

// --- for a VFS of our own (sqlite/vfs.zig) and counted mutexes ----------------

pub const ioerr = 10;
pub const notfound = 12;
pub const cantopen = 14;
pub const ioerr_read = ioerr | (1 << 8);
pub const ioerr_short_read = ioerr | (2 << 8);
pub const ioerr_write = ioerr | (3 << 8);
pub const ioerr_fsync = ioerr | (4 << 8);
pub const ioerr_truncate = ioerr | (6 << 8);
pub const ioerr_fstat = ioerr | (7 << 8);
pub const ioerr_delete = ioerr | (10 << 8);
pub const ioerr_access = ioerr | (13 << 8);
pub const ioerr_shmsize = ioerr | (19 << 8);
pub const ioerr_delete_noent = ioerr | (23 << 8);

pub const open_readonly = 0x00000001;
pub const open_main_db = 0x00000100;
pub const open_main_journal = 0x00000800;
pub const open_wal = 0x00080000;

pub const lock_none = 0;
pub const lock_shared = 1;
pub const lock_reserved = 2;
pub const lock_pending = 3;
pub const lock_exclusive = 4;

pub const shm_unlock = 1;
pub const shm_lock = 2;
pub const shm_shared = 4;
pub const shm_exclusive = 8;
pub const shm_locks = 8;

pub const iocap_powersafe_overwrite = 0x00001000;

pub const config_mutex = 10;
pub const config_getmutex = 11;

pub extern fn sqlite3_config(op: c_int, ...) c_int;
pub extern fn sqlite3_shutdown() c_int;
pub extern fn sqlite3_vfs_register(vfs: *Vfs, make_default: c_int) c_int;

pub const Mutex = opaque {};

pub const MutexMethods = extern struct {
    init: ?*const fn () callconv(.c) c_int,
    end: ?*const fn () callconv(.c) c_int,
    alloc: ?*const fn (kind: c_int) callconv(.c) ?*Mutex,
    free: ?*const fn (mutex: ?*Mutex) callconv(.c) void,
    enter: ?*const fn (mutex: ?*Mutex) callconv(.c) void,
    try_enter: ?*const fn (mutex: ?*Mutex) callconv(.c) c_int,
    leave: ?*const fn (mutex: ?*Mutex) callconv(.c) void,
    held: ?*const fn (mutex: ?*Mutex) callconv(.c) c_int,
    not_held: ?*const fn (mutex: ?*Mutex) callconv(.c) c_int,
};

/// `sqlite3_file`: every VFS file begins with its methods.
pub const File = extern struct {
    methods: ?*const IoMethods,
};

/// `sqlite3_io_methods`, version 2 (shared memory; no mmap).
pub const IoMethods = extern struct {
    version: c_int,
    close: *const fn (file: *File) callconv(.c) c_int,
    read: *const fn (
        file: *File,
        buffer: ?*anyopaque,
        amount: c_int,
        offset: i64,
    ) callconv(.c) c_int,
    write: *const fn (
        file: *File,
        buffer: ?*const anyopaque,
        amount: c_int,
        offset: i64,
    ) callconv(.c) c_int,
    truncate: *const fn (file: *File, size: i64) callconv(.c) c_int,
    sync: *const fn (file: *File, flags: c_int) callconv(.c) c_int,
    file_size: *const fn (file: *File, size: *i64) callconv(.c) c_int,
    lock: *const fn (file: *File, level: c_int) callconv(.c) c_int,
    unlock: *const fn (file: *File, level: c_int) callconv(.c) c_int,
    check_reserved_lock: *const fn (file: *File, out: *c_int) callconv(.c) c_int,
    file_control: *const fn (file: *File, op: c_int, argument: ?*anyopaque) callconv(.c) c_int,
    sector_size: *const fn (file: *File) callconv(.c) c_int,
    device_characteristics: *const fn (file: *File) callconv(.c) c_int,
    shm_map: *const fn (
        file: *File,
        region: c_int,
        region_bytes: c_int,
        extend: c_int,
        out: *?*volatile anyopaque,
    ) callconv(.c) c_int,
    shm_lock: *const fn (file: *File, offset: c_int, count: c_int, flags: c_int) callconv(.c) c_int,
    shm_barrier: *const fn (file: *File) callconv(.c) void,
    shm_unmap: *const fn (file: *File, delete: c_int) callconv(.c) c_int,
};

/// `sqlite3_vfs`, version 2.
pub const Vfs = extern struct {
    version: c_int,
    file_bytes: c_int,
    path_bytes_max: c_int,
    next: ?*Vfs,
    name: [*:0]const u8,
    app_data: ?*anyopaque,
    open: *const fn (
        vfs: *Vfs,
        name: ?[*:0]const u8,
        file: *File,
        flags: c_int,
        out_flags: ?*c_int,
    ) callconv(.c) c_int,
    delete: *const fn (vfs: *Vfs, name: [*:0]const u8, sync_directory: c_int) callconv(.c) c_int,
    access: *const fn (
        vfs: *Vfs,
        name: [*:0]const u8,
        flags: c_int,
        out: *c_int,
    ) callconv(.c) c_int,
    full_pathname: *const fn (
        vfs: *Vfs,
        name: [*:0]const u8,
        out_bytes: c_int,
        out: [*]u8,
    ) callconv(.c) c_int,
    dl_open: ?*const anyopaque = null,
    dl_error: ?*const anyopaque = null,
    dl_sym: ?*const anyopaque = null,
    dl_close: ?*const anyopaque = null,
    randomness: *const fn (vfs: *Vfs, bytes: c_int, out: [*]u8) callconv(.c) c_int,
    sleep: *const fn (vfs: *Vfs, microseconds: c_int) callconv(.c) c_int,
    current_time: *const fn (vfs: *Vfs, out: *f64) callconv(.c) c_int,
    get_last_error: *const fn (vfs: *Vfs, bytes: c_int, out: ?[*]u8) callconv(.c) c_int,
    current_time_int64: *const fn (vfs: *Vfs, out: *i64) callconv(.c) c_int,
};
