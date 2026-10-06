//! The app's one SQLite database, as the host keeps it.
//!
//! Opened once, in `init!`, before any shard: the connections, every
//! PRAGMA, limit and option set and read back, the schema created or
//! compared, and every statement of `Database.roc` prepared on each
//! connection that runs it. After that nothing is prepared, nothing is
//! opened and no SQL text is read: a request names a statement by number.
//!
//! - Readers: one connection per shard, never leaving its thread. With
//!   SQLite's own VFS a statement runs to its end without yielding the
//!   fiber, so one is enough (asserted: a reader is never entered twice).
//! - The writer: one connection for the process, behind `WriterLock`, a
//!   bounded queue with a bounded wait (`writer_busy`, a 503). SQLite never
//!   sees two writers, so `busy_timeout` is 0.
//! - No migrations yet: a new database gets `schema.sql`; an existing one
//!   must hold exactly the schema `schema.sql` makes (`sqlite_schema`
//!   compared row by row), or it does not open.
//!
//! Values cross as `Value`; rows go to a sink the caller passes at compile
//! time (host.zig builds Roc lists; the tests a record of what came), so
//! this file knows nothing of Roc and is tested alone (database_test.zig).
//! An interface file: SQLite's progress handler is a C callback.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const c = sqlite.c;
const types = sqlite.types;
const authorizer = sqlite.authorizer;

/// Statements of one database: roux-db's bound.
pub const statements_max = 1024;
/// The most rows a statement may say it returns (roux-db's `:many` bound).
pub const rows_max_limit = 100_000;
/// Text and blob bytes one statement may return, in all.
pub const result_bytes_max = 16 * 1024 * 1024;
/// The largest text or blob SQLite holds (`SQLITE_LIMIT_LENGTH`).
pub const value_bytes_max = 16 * 1024 * 1024;
/// The bounds a database runs with; the host's are the defaults, a test
/// shortens the waits.
pub const Limits = struct {
    /// A statement past this is interrupted (`timed_out`).
    statement_time_ms: u32 = 2_000,
    /// How long a request waits for the writer before `writer_busy`.
    write_wait_ms: u32 = 1_000,
    /// Requests waiting for the writer; one more is `writer_busy` at once.
    writers_waiting: u32 = 64,
};
/// Statements of schema.sql.
pub const schema_statements_max = 1024;
/// SQLite's page cache, per connection.
pub const writer_cache_kib = 8 * 1024;
pub const reader_cache_kib = 4 * 1024;
/// The write-ahead log is cut back to this after a checkpoint.
pub const wal_bytes_max = 64 * 1024 * 1024;
/// Virtual-machine steps between two looks at the clock.
const progress_instructions = 1000;
const message_bytes_max = 512;

/// Why a statement failed; host.zig and Sqlite.roc share the codes.
pub const Failure = enum(u8) {
    writer_busy = 1,
    timed_out = 2,
    too_many_rows = 3,
    invalid_value = 4,
    constraint = 5,
    write_refused = 6,
    failed = 7,
    misuse = 8,
};

/// A failure and what it was, for the log and the app.
pub const Report = struct {
    failure: Failure = .failed,
    buffer: [message_bytes_max]u8 = undefined,
    length: u32 = 0,

    pub fn fail(
        report: *Report,
        failure: Failure,
        comptime format: []const u8,
        arguments: anytype,
    ) error{Failed} {
        report.failure = failure;
        const text = std.fmt.bufPrint(&report.buffer, format, arguments) catch cut: {
            @memcpy(report.buffer[message_bytes_max - 3 ..], "...");
            break :cut report.buffer[0..];
        };
        report.length = @intCast(text.len);
        return error.Failed;
    }

    pub fn message(report: *const Report) []const u8 {
        return report.buffer[0..report.length];
    }
};

/// A SQLite value, a parameter or a cell.
pub const Value = union(enum) {
    null,
    integer: i64,
    real: f64,
    /// Valid UTF-8 (checked as it leaves SQLite).
    text: []const u8,
    blob: []const u8,
};

/// A statement as roux-db describes it (`Database.roc`).
pub const StatementDescription = struct {
    name: []const u8,
    sql: []const u8,
    writes: bool,
    rows_max: u32,
    /// Type codes (sqlite/types.zig).
    params: []const u8,
    columns: []const u8,
};

pub const Description = struct {
    path: []const u8,
    schema: []const u8,
    statements: []const StatementDescription,
};

pub const Statement = struct {
    name: []const u8,
    sql: [:0]const u8,
    writes: bool,
    rows_max: u32,
    params: []const types.Type,
    columns: []const types.Type,
};

pub const Role = enum { writer, reader };

pub const Connection = struct {
    db: *c.Db,
    role: Role,
    /// By statement number; null for one this connection does not run (a
    /// write on a reader).
    prepared: []?*c.Stmt,
    /// While a statement runs: the clock to read, and when to interrupt.
    io: ?Io = null,
    deadline: Io.Timestamp = .zero,
    running: bool = false,
};

pub const Database = struct {
    limits: Limits,
    path: [:0]const u8,
    statements: []const Statement,
    writer: *Connection,
    begin: *c.Stmt,
    commit: *c.Stmt,
    rollback: *c.Stmt,
    lock: WriterLock = .{},
};

/// Opens the database `description` names: the writer, the schema, the
/// statements. At startup only (allocates; any failure is in `report`).
pub fn open(
    gpa: Allocator,
    description: Description,
    limits: Limits,
    report: *Report,
) error{Failed}!*Database {
    sqlite.initialize() catch return report.fail(.failed, "sqlite3_initialize failed", .{});
    const statements = try decode_statements(gpa, description.statements, report);
    const path = dupe_sentinel(gpa, description.path) catch return out_of_memory(report);
    const writer = try open_connection(gpa, path, .writer, statements, report);
    errdefer close_connection(gpa, writer);
    try ensure_schema(writer.db, description.schema, report);
    try prepare_statements(writer, statements, report);
    const database = gpa.create(Database) catch return out_of_memory(report);
    database.* = .{
        .limits = limits,
        .path = path,
        .statements = statements,
        .writer = writer,
        .begin = try prepare_own(writer.db, "BEGIN IMMEDIATE", report),
        .commit = try prepare_own(writer.db, "COMMIT", report),
        .rollback = try prepare_own(writer.db, "ROLLBACK", report),
    };
    assert(c.sqlite3_get_autocommit(writer.db) != 0);
    return database;
}

/// Closes the writer and frees what `open` made; every reader is closed
/// first (`close_connection`). For tests, and a shutdown.
pub fn close(gpa: Allocator, database: *Database) void {
    assert(database.lock.state.load(.monotonic) == 0);
    _ = c.sqlite3_finalize(database.begin);
    _ = c.sqlite3_finalize(database.commit);
    _ = c.sqlite3_finalize(database.rollback);
    close_connection(gpa, database.writer);
    for (database.statements) |statement| {
        gpa.free(statement.name);
        gpa.free(statement.sql);
        gpa.free(statement.params);
        gpa.free(statement.columns);
    }
    gpa.free(database.statements);
    gpa.free(database.path);
    gpa.destroy(database);
}

pub fn close_connection(gpa: Allocator, connection: *Connection) void {
    assert(!connection.running);
    for (connection.prepared) |prepared| _ = c.sqlite3_finalize(prepared);
    const result = c.sqlite3_close_v2(connection.db);
    assert(result == c.ok);
    gpa.free(connection.prepared);
    gpa.destroy(connection);
}

/// A shard's reader, at the shard's start: every read statement prepared.
pub fn open_reader(
    gpa: Allocator,
    database: *const Database,
    report: *Report,
) error{Failed}!*Connection {
    const reader = try open_connection(gpa, database.path, .reader, database.statements, report);
    errdefer close_connection(gpa, reader);
    try prepare_statements(reader, database.statements, report);
    return reader;
}

/// `bytes` with a 0 after them, as SQLite reads a path or a statement.
fn dupe_sentinel(gpa: Allocator, bytes: []const u8) error{OutOfMemory}![:0]u8 {
    const copy = try gpa.allocSentinel(u8, bytes.len, 0);
    @memcpy(copy, bytes);
    return copy;
}

fn out_of_memory(report: *Report) error{Failed} {
    return report.fail(.failed, "out of memory opening the database", .{});
}

fn decode_statements(
    gpa: Allocator,
    descriptions: []const StatementDescription,
    report: *Report,
) error{Failed}![]const Statement {
    if (descriptions.len > statements_max) {
        return report.fail(.misuse, "{d} statements, over {d}", .{
            descriptions.len,
            statements_max,
        });
    }
    const statements = gpa.alloc(Statement, descriptions.len) catch return out_of_memory(report);
    for (descriptions, statements) |description, *statement| {
        if (description.rows_max > rows_max_limit) {
            return report.fail(.misuse, "{s}: rows_max {d}, over {d}", .{
                description.name, description.rows_max, rows_max_limit,
            });
        }
        statement.* = .{
            .name = gpa.dupe(u8, description.name) catch return out_of_memory(report),
            .sql = dupe_sentinel(gpa, description.sql) catch return out_of_memory(report),
            .writes = description.writes,
            .rows_max = description.rows_max,
            .params = try decode_types(gpa, description.name, description.params, report),
            .columns = try decode_types(gpa, description.name, description.columns, report),
        };
    }
    return statements;
}

fn decode_types(
    gpa: Allocator,
    name: []const u8,
    codes: []const u8,
    report: *Report,
) error{Failed}![]const types.Type {
    const decoded = gpa.alloc(types.Type, codes.len) catch return out_of_memory(report);
    for (codes, decoded) |code, *t| {
        t.* = types.Type.from_code(code) orelse
            return report.fail(.misuse, "{s}: type code {d}: regenerate with roux-db", .{
                name,
                code,
            });
    }
    return decoded;
}

fn open_connection(
    gpa: Allocator,
    path: [:0]const u8,
    role: Role,
    statements: []const Statement,
    report: *Report,
) error{Failed}!*Connection {
    var db: ?*c.Db = null;
    const flags = c.open_readwrite | c.open_create | c.open_nomutex | c.open_exrescode;
    if (c.sqlite3_open_v2(path, &db, flags, null) != c.ok) {
        const text = if (db) |handle| std.mem.span(c.sqlite3_errmsg(handle)) else "out of memory";
        _ = c.sqlite3_close_v2(db);
        return report.fail(.failed, "open {s}: {s}", .{ path, text });
    }
    errdefer _ = c.sqlite3_close_v2(db);
    const prepared = gpa.alloc(?*c.Stmt, statements.len) catch return out_of_memory(report);
    @memset(prepared, null);
    const connection = gpa.create(Connection) catch return out_of_memory(report);
    connection.* = .{ .db = db.?, .role = role, .prepared = prepared };
    try configure(connection, report);
    c.sqlite3_progress_handler(connection.db, progress_instructions, progress, connection);
    return connection;
}

// --- configuration, every setting read back ----------------------------------

const Option = struct { op: c_int, value: c_int };

/// `sqlite3_db_config` options, each set and read back.
const options = [_]Option{
    .{ .op = c.dbconfig_defensive, .value = 1 },
    .{ .op = c.dbconfig_dqs_dml, .value = 0 },
    .{ .op = c.dbconfig_dqs_ddl, .value = 0 },
    .{ .op = c.dbconfig_trusted_schema, .value = 0 },
    .{ .op = c.dbconfig_enable_trigger, .value = 1 },
    .{ .op = c.dbconfig_enable_view, .value = 1 },
};

const Limit = struct { id: c_int, value: c_int };

/// Every `sqlite3_limit`, explicit: none left to SQLite's default.
const sqlite_limits = [_]Limit{
    .{ .id = c.limit_length, .value = value_bytes_max },
    .{ .id = c.limit_sql_length, .value = 1024 * 1024 },
    .{ .id = c.limit_column, .value = 256 },
    .{ .id = c.limit_expr_depth, .value = 1000 },
    .{ .id = c.limit_compound_select, .value = 64 },
    .{ .id = c.limit_vdbe_op, .value = 250_000_000 },
    .{ .id = c.limit_function_arg, .value = 32 },
    .{ .id = c.limit_attached, .value = 0 },
    .{ .id = c.limit_like_pattern_length, .value = 1000 },
    .{ .id = c.limit_variable_number, .value = 64 },
    .{ .id = c.limit_trigger_depth, .value = 32 },
    .{ .id = c.limit_worker_threads, .value = 0 },
};

fn configure(connection: *Connection, report: *Report) error{Failed}!void {
    const db = connection.db;
    for (options) |option| {
        var readback: c_int = -1;
        const result = c.sqlite3_db_config(db, option.op, option.value, &readback);
        if (result != c.ok or readback != option.value) {
            return report.fail(.failed, "sqlite3_db_config {d}: {d}, not {d}", .{
                option.op, readback, option.value,
            });
        }
    }
    for (sqlite_limits) |limit| {
        _ = c.sqlite3_limit(db, limit.id, limit.value);
        const readback = c.sqlite3_limit(db, limit.id, -1);
        if (readback != limit.value) {
            return report.fail(.failed, "sqlite3_limit {d}: {d}, not {d}", .{
                limit.id,
                readback,
                limit.value,
            });
        }
    }
    try configure_pragmas(connection, report);
}

const Pragma = struct {
    /// Sets it; reading `name` back must give `expected`.
    set: []const u8,
    name: []const u8,
    expected: i64,
    role: ?Role = null,
};

const cache_writer = "PRAGMA cache_size = -" ++ std.fmt.comptimePrint("{d}", .{writer_cache_kib});
const cache_reader = "PRAGMA cache_size = -" ++ std.fmt.comptimePrint("{d}", .{reader_cache_kib});

const pragmas = [_]Pragma{
    // FULL: a commit is durable when it returns (synchronous, decided
    // 2026-10-06; the fsync floor is in the diary).
    .{ .set = "PRAGMA synchronous = FULL", .name = "PRAGMA synchronous", .expected = 2 },
    .{ .set = "PRAGMA foreign_keys = ON", .name = "PRAGMA foreign_keys", .expected = 1 },
    .{ .set = "PRAGMA trusted_schema = OFF", .name = "PRAGMA trusted_schema", .expected = 0 },
    .{ .set = "PRAGMA busy_timeout = 0", .name = "PRAGMA busy_timeout", .expected = 0 },
    .{ .set = "PRAGMA temp_store = MEMORY", .name = "PRAGMA temp_store", .expected = 2 },
    .{
        .set = cache_writer,
        .name = "PRAGMA cache_size",
        .expected = -writer_cache_kib,
        .role = .writer,
    },
    .{
        .set = cache_reader,
        .name = "PRAGMA cache_size",
        .expected = -reader_cache_kib,
        .role = .reader,
    },
    .{
        .set = "PRAGMA journal_size_limit = " ++ std.fmt.comptimePrint("{d}", .{wal_bytes_max}),
        .name = "PRAGMA journal_size_limit",
        .expected = wal_bytes_max,
        .role = .writer,
    },
    .{
        .set = "PRAGMA wal_autocheckpoint = 1000",
        .name = "PRAGMA wal_autocheckpoint",
        .expected = 1000,
        .role = .writer,
    },
    .{
        .set = "PRAGMA query_only = ON",
        .name = "PRAGMA query_only",
        .expected = 1,
        .role = .reader,
    },
};

fn configure_pragmas(connection: *Connection, report: *Report) error{Failed}!void {
    const db = connection.db;
    // WAL first: it is the database file's, kept once set.
    // The writer sets WAL; a reader reads it back.
    const sql = switch (connection.role) {
        .writer => "PRAGMA journal_mode = WAL",
        .reader => "PRAGMA journal_mode",
    };
    const mode = try pragma_text(db, sql, report);
    if (!std.mem.eql(u8, mode.slice(), "wal")) {
        return report.fail(.failed, "journal_mode {s}, not wal", .{mode.slice()});
    }
    for (pragmas) |pragma| {
        if (pragma.role) |role| if (role != connection.role) continue;
        sqlite.exec(db, pragma.set) catch
            return report.fail(.failed, "{s}: {s}", .{ pragma.set, c.sqlite3_errmsg(db) });
        const value = try pragma_integer(db, pragma.name, report);
        if (value != pragma.expected) {
            return report.fail(.failed, "{s}: {d}, not {d}", .{
                pragma.name,
                value,
                pragma.expected,
            });
        }
    }
}

const Text = struct {
    buffer: [64]u8 = undefined,
    length: u32 = 0,

    fn slice(text: *const Text) []const u8 {
        return text.buffer[0..text.length];
    }
};

fn pragma_text(db: *c.Db, sql: []const u8, report: *Report) error{Failed}!Text {
    const statement = try prepare_own(db, sql, report);
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.row) {
        return report.fail(.failed, "{s}: {s}", .{ sql, c.sqlite3_errmsg(db) });
    }
    var text: Text = .{};
    const bytes = c.sqlite3_column_text(statement, 0) orelse return text;
    const length: u32 = @intCast(@min(c.sqlite3_column_bytes(statement, 0), text.buffer.len));
    @memcpy(text.buffer[0..length], bytes[0..length]);
    text.length = length;
    return text;
}

fn pragma_integer(db: *c.Db, sql: []const u8, report: *Report) error{Failed}!i64 {
    const statement = try prepare_own(db, sql, report);
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.row) {
        return report.fail(.failed, "{s}: {s}", .{ sql, c.sqlite3_errmsg(db) });
    }
    return c.sqlite3_column_int64(statement, 0);
}

/// One of the host's own statements, kept for the connection's life.
fn prepare_own(db: *c.Db, sql: []const u8, report: *Report) error{Failed}!*c.Stmt {
    var statement: ?*c.Stmt = null;
    const length: c_int = @intCast(sql.len);
    if (c.sqlite3_prepare_v3(db, sql.ptr, length, c.prepare_persistent, &statement, null) != c.ok) {
        return report.fail(.failed, "{s}: {s}", .{ sql, c.sqlite3_errmsg(db) });
    }
    return statement.?;
}

// --- the schema ---------------------------------------------------------------

/// A new database (nothing in `sqlite_schema`) gets `schema`; an existing
/// one must already be exactly what `schema` makes.
fn ensure_schema(db: *c.Db, schema: []const u8, report: *Report) error{Failed}!void {
    const objects = try pragma_integer(db, "SELECT count(*) FROM sqlite_schema", report);
    if (objects == 0) return create_schema(db, schema, report);
    var expected: ?*c.Db = null;
    const flags = c.open_readwrite | c.open_create | c.open_memory | c.open_exrescode;
    if (c.sqlite3_open_v2(":memory:", &expected, flags, null) != c.ok) {
        _ = c.sqlite3_close_v2(expected);
        return out_of_memory(report);
    }
    defer _ = c.sqlite3_close_v2(expected);
    sqlite.exec(expected.?, schema) catch
        return report.fail(.failed, "schema.sql: {s}", .{c.sqlite3_errmsg(expected.?)});
    return compare_schemas(db, expected.?, report);
}

fn create_schema(db: *c.Db, schema: []const u8, report: *Report) error{Failed}!void {
    sqlite.exec(db, "BEGIN IMMEDIATE") catch
        return report.fail(.failed, "BEGIN: {s}", .{c.sqlite3_errmsg(db)});
    var verdict: authorizer.Verdict = .{ .policy = .schema };
    authorizer.install(db, &verdict);
    sqlite.exec(db, schema) catch {
        const refused = verdict.refused;
        authorizer.uninstall(db);
        sqlite.exec(db, "ROLLBACK") catch {};
        if (refused) |action| {
            return report.fail(.failed, "schema.sql may not hold {s}", .{
                authorizer.describe(action),
            });
        }
        return report.fail(.failed, "schema.sql: {s}", .{c.sqlite3_errmsg(db)});
    };
    authorizer.uninstall(db);
    sqlite.exec(db, "COMMIT") catch
        return report.fail(.failed, "COMMIT: {s}", .{c.sqlite3_errmsg(db)});
}

/// `sqlite_schema` row by row: SQLite keeps each CREATE as it was written,
/// so two databases made by the same `schema.sql` hold the same rows.
fn compare_schemas(db: *c.Db, expected: *c.Db, report: *Report) error{Failed}!void {
    const sql = "SELECT type, name, tbl_name, coalesce(sql, '') FROM sqlite_schema " ++
        "ORDER BY type, name";
    const actual_rows = try prepare_own(db, sql, report);
    defer _ = c.sqlite3_finalize(actual_rows);
    const expected_rows = try prepare_own(expected, sql, report);
    defer _ = c.sqlite3_finalize(expected_rows);
    for (0..schema_statements_max * 4) |_| {
        const actual_step = c.sqlite3_step(actual_rows);
        const expected_step = c.sqlite3_step(expected_rows);
        if (actual_step == c.done and expected_step == c.done) return;
        if (actual_step != c.row or expected_step != c.row) {
            return schema_differs(expected_rows, actual_rows, report);
        }
        for (0..4) |column| {
            const actual = column_text(actual_rows, @intCast(column));
            const wanted = column_text(expected_rows, @intCast(column));
            if (!std.mem.eql(u8, actual, wanted)) {
                return schema_differs(expected_rows, actual_rows, report);
            }
        }
    } else return report.fail(.failed, "more than {d} schema objects", .{
        schema_statements_max * 4,
    });
}

fn schema_differs(expected: *c.Stmt, actual: *c.Stmt, report: *Report) error{Failed} {
    const expected_name = name_of_row(expected);
    const actual_name = name_of_row(actual);
    return report.fail(.failed, "the database's schema is not schema.sql's (first difference: " ++
        "{s} in schema.sql, {s} in the database). No migrations yet: a schema " ++
        "change needs a new database", .{ expected_name, actual_name });
}

/// The `name` column of the row a schema listing is on, if any.
fn name_of_row(listing: *c.Stmt) []const u8 {
    return if (c.sqlite3_stmt_busy(listing) != 0) column_text(listing, 1) else "(none)";
}

fn column_text(statement: *c.Stmt, column: c_int) []const u8 {
    const bytes = c.sqlite3_column_text(statement, column) orelse return "";
    return bytes[0..@intCast(c.sqlite3_column_bytes(statement, column))];
}

// --- the statements -------------------------------------------------------------

/// Prepares each statement this connection runs (a reader: those that do
/// not write), checking that SQLite reads it as roux-db did; a query that
/// does what a query may not is refused by the same policy roux-db applied.
fn prepare_statements(
    connection: *Connection,
    statements: []const Statement,
    report: *Report,
) error{Failed}!void {
    const db = connection.db;
    var verdict: authorizer.Verdict = .{ .policy = .query };
    for (statements, connection.prepared) |statement, *prepared| {
        if (statement.writes and connection.role == .reader) continue;
        verdict.reset();
        authorizer.install(db, &verdict);
        var handle: ?*c.Stmt = null;
        const length: c_int = @intCast(statement.sql.len);
        const flags = c.prepare_persistent;
        const result = c.sqlite3_prepare_v3(db, statement.sql.ptr, length, flags, &handle, null);
        authorizer.uninstall(db);
        if (result != c.ok or handle == null) {
            return report.fail(.misuse, "{s}: {s}: regenerate Database.roc with roux-db", .{
                statement.name, c.sqlite3_errmsg(db),
            });
        }
        prepared.* = handle;
        try check_statement(handle.?, statement, report);
    }
}

/// What SQLite says of a statement is what roux-db recorded.
fn check_statement(handle: *c.Stmt, statement: Statement, report: *Report) error{Failed}!void {
    const writes = c.sqlite3_stmt_readonly(handle) == 0;
    const columns: u32 = @intCast(c.sqlite3_column_count(handle));
    const params: u32 = @intCast(c.sqlite3_bind_parameter_count(handle));
    const rows_fit = (statement.rows_max == 0) == (columns == 0);
    if (writes != statement.writes or columns != statement.columns.len or
        params != statement.params.len or !rows_fit)
    {
        return report.fail(.misuse, "{s}: SQLite reads it otherwise than Database.roc says: " ++
            "regenerate with roux-db", .{statement.name});
    }
}

/// Runs statement `index` with `params` on `connection`, each row's cells
/// to `sink` (`row()`, then `cell(Value)` per column, both `!void`), each
/// cell checked against the statement's column type.
pub fn run(
    database: *const Database,
    connection: *Connection,
    index: u32,
    params: []const Value,
    io: Io,
    sink: anytype,
    report: *Report,
) error{Failed}!void {
    if (index >= database.statements.len) {
        return report.fail(.misuse, "statement {d} of {d}: regenerate Database.roc with roux-db", .{
            index, database.statements.len,
        });
    }
    const statement = &database.statements[index];
    const handle = connection.prepared[index] orelse
        return report.fail(.misuse, "{s} writes: run it with a Sqlite.Write", .{statement.name});
    assert(!connection.running); // a reader is entered by one fiber at a time
    connection.running = true;
    defer connection.running = false;
    try bind(handle, statement, params, report);
    defer {
        _ = c.sqlite3_reset(handle);
        _ = c.sqlite3_clear_bindings(handle);
    }

    connection.io = io;
    const time: Io.Duration = .fromMilliseconds(database.limits.statement_time_ms);
    connection.deadline = Io.Timestamp.now(io, .awake).addDuration(time);
    defer connection.io = null;
    try step_rows(connection, handle, statement, sink, report);
    assert(c.sqlite3_stmt_busy(handle) == 0); // ran to its end
}

fn bind(
    handle: *c.Stmt,
    statement: *const Statement,
    params: []const Value,
    report: *Report,
) error{Failed}!void {
    if (params.len != statement.params.len) {
        return report.fail(.misuse, "{s}: {d} parameters, not {d}", .{
            statement.name, params.len, statement.params.len,
        });
    }
    for (params, statement.params, 1..) |param, param_type, position| {
        if (!fits(param, param_type)) {
            return report.fail(.misuse, "{s}: parameter {d} is {t}, not {s}", .{
                statement.name, position, param, param_type.scalar.roc(),
            });
        }
        const index: c_int = @intCast(position);
        const result = switch (param) {
            .null => c.sqlite3_bind_null(handle, index),
            .integer => |value| c.sqlite3_bind_int64(handle, index, value),
            .real => |value| c.sqlite3_bind_double(handle, index, value),
            .text => |text| c.sqlite3_bind_text64(handle, index, text.ptr, text.len, null, c.utf8),
            .blob => |bytes| c.sqlite3_bind_blob64(handle, index, bytes.ptr, bytes.len, null),
        };
        if (result != c.ok) return report.fail(.failed, "{s}: binding parameter {d}", .{
            statement.name,
            position,
        });
    }
}

/// Whether a value is one a column or parameter of `value_type` holds.
fn fits(value: Value, value_type: types.Type) bool {
    return switch (value) {
        .null => value_type.nullable,
        .integer => |n| switch (value_type.scalar) {
            .i64 => true,
            .bool => n == 0 or n == 1,
            else => false,
        },
        .real => value_type.scalar == .f64,
        .text => value_type.scalar == .str,
        .blob => value_type.scalar == .bytes,
    };
}

fn step_rows(
    connection: *Connection,
    handle: *c.Stmt,
    statement: *const Statement,
    sink: anytype,
    report: *Report,
) error{Failed}!void {
    var rows: u32 = 0;
    var bytes: u64 = 0;
    for (0..statement.rows_max + 2) |_| {
        switch (c.sqlite3_step(handle)) {
            c.done => return,
            c.row => {},
            else => |code| return step_failed(connection.db, code, statement, report),
        }
        if (rows == statement.rows_max) {
            return report.fail(.too_many_rows, "{s}: more than {d} rows", .{
                statement.name,
                statement.rows_max,
            });
        }
        rows += 1;
        sink.row() catch return report.fail(.failed, "{s}: out of memory", .{statement.name});
        for (statement.columns, 0..) |column_type, column| {
            const value = try read_cell(handle, @intCast(column), column_type, statement, report);
            bytes += switch (value) {
                .text, .blob => |slice| slice.len,
                else => 0,
            };
            if (bytes > result_bytes_max) {
                return report.fail(.too_many_rows, "{s}: over {d} bytes", .{
                    statement.name,
                    result_bytes_max,
                });
            }
            sink.cell(value) catch return report.fail(.failed, "{s}: out of memory", .{
                statement.name,
            });
        }
    } else unreachable; // rows_max + 1 rows fail; one more step is done
}

fn read_cell(
    handle: *c.Stmt,
    column: c_int,
    column_type: types.Type,
    statement: *const Statement,
    report: *Report,
) error{Failed}!Value {
    const value: Value = switch (c.sqlite3_column_type(handle, column)) {
        c.null_type => .null,
        c.integer => .{ .integer = c.sqlite3_column_int64(handle, column) },
        c.float => .{ .real = c.sqlite3_column_double(handle, column) },
        c.text => .{ .text = column_text(handle, column) },
        c.blob => .{ .blob = column_blob(handle, column) },
        else => unreachable, // SQLite has five types
    };
    if (!fits(value, column_type)) {
        return report.fail(.invalid_value, "{s}: column {d} is {t}, typed {s}{s}", .{
            statement.name,           column,                                            value,
            column_type.scalar.roc(), if (column_type.nullable) "" else " (never NULL)",
        });
    }
    if (value == .text and !std.unicode.utf8ValidateSlice(value.text)) {
        return report.fail(.invalid_value, "{s}: column {d} is not UTF-8", .{
            statement.name,
            column,
        });
    }
    return value;
}

fn column_blob(handle: *c.Stmt, column: c_int) []const u8 {
    const bytes = c.sqlite3_column_blob(handle, column) orelse return "";
    return bytes[0..@intCast(c.sqlite3_column_bytes(handle, column))];
}

fn step_failed(db: *c.Db, code: c_int, statement: *const Statement, report: *Report) error{Failed} {
    const failure: Failure = switch (code & 0xff) {
        c.constraint => .constraint,
        c.interrupt => .timed_out,
        else => .failed,
    };
    return report.fail(failure, "{s}: {s}", .{ statement.name, c.sqlite3_errmsg(db) });
}

/// Interrupts a statement past its connection's deadline.
fn progress(user: ?*anyopaque) callconv(.c) c_int {
    const connection: *Connection = @ptrCast(@alignCast(user.?));
    const io = connection.io orelse return 0; // the host's own statements
    const now = Io.Timestamp.now(io, .awake);
    return @intFromBool(now.nanoseconds > connection.deadline.nanoseconds);
}

// --- the writer -----------------------------------------------------------------

/// Takes the writer for one request and begins its transaction.
pub fn begin_write(database: *Database, io: Io, report: *Report) error{Failed}!void {
    try database.lock.acquire(io, database.limits, report);
    errdefer database.lock.release(io);
    assert(c.sqlite3_get_autocommit(database.writer.db) != 0);
    defer _ = c.sqlite3_reset(database.begin);
    if (c.sqlite3_step(database.begin) != c.done) {
        return report.fail(.failed, "BEGIN IMMEDIATE: {s}", .{
            c.sqlite3_errmsg(database.writer.db),
        });
    }
}

/// Commits and gives the writer back; a failed commit rolls back.
pub fn commit_write(database: *Database, io: Io, report: *Report) error{Failed}!void {
    defer database.lock.release(io);
    const result = c.sqlite3_step(database.commit);
    _ = c.sqlite3_reset(database.commit);
    if (result != c.done) {
        const failure = report.fail(.failed, "COMMIT: {s}", .{
            c.sqlite3_errmsg(database.writer.db),
        });
        roll_back(database);
        return failure;
    }
    assert_quiet(database.writer);
}

/// Rolls back and gives the writer back: a request that ends holding it.
pub fn rollback_write(database: *Database, io: Io) void {
    defer database.lock.release(io);
    roll_back(database);
}

fn roll_back(database: *Database) void {
    const db = database.writer.db;
    if (c.sqlite3_get_autocommit(db) == 0) {
        _ = c.sqlite3_step(database.rollback);
        _ = c.sqlite3_reset(database.rollback);
    }
    assert_quiet(database.writer);
}

/// Between transactions a connection holds no transaction and no statement
/// that has not been reset: nothing leaks to the next request.
fn assert_quiet(connection: *const Connection) void {
    assert(c.sqlite3_get_autocommit(connection.db) != 0);
    assert(!connection.running);
    var statement = c.sqlite3_next_stmt(connection.db, null);
    for (0..statements_max + 8) |_| {
        const handle = statement orelse return;
        assert(c.sqlite3_stmt_busy(handle) == 0);
        statement = c.sqlite3_next_stmt(connection.db, handle);
    } else unreachable;
}

/// The writer, one request at a time across every shard. A request waits
/// at most `Limits.write_wait_ms` (a futex: its fiber yields), and at most
/// `Limits.writers_waiting` wait; the rest are `writer_busy` at once. Not
/// FIFO: a waiter woken may lose to one arriving (to measure: TODO).
pub const WriterLock = struct {
    /// 0 free, 1 held.
    state: std.atomic.Value(u32) = .init(0),
    waiting: std.atomic.Value(u32) = .init(0),

    pub fn acquire(lock: *WriterLock, io: Io, limits: Limits, report: *Report) error{Failed}!void {
        if (lock.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) return;
        if (lock.waiting.fetchAdd(1, .monotonic) >= limits.writers_waiting) {
            _ = lock.waiting.fetchSub(1, .monotonic);
            return report.fail(.writer_busy, "{d} requests wait for the writer", .{
                limits.writers_waiting,
            });
        }
        defer _ = lock.waiting.fetchSub(1, .monotonic);
        const wait: Io.Duration = .fromMilliseconds(limits.write_wait_ms);
        const deadline = Io.Timestamp.now(io, .awake).addDuration(wait);
        // Each pass takes the lock, or waits until a release or the deadline.
        const passes_max = 1 << 20;
        for (0..passes_max) |_| {
            if (lock.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) return;
            if (Io.Timestamp.now(io, .awake).nanoseconds >= deadline.nanoseconds) break;
            const timeout: Io.Timeout = .{ .deadline = deadline.withClock(.awake) };
            io.futexWaitTimeout(u32, &lock.state.raw, 1, timeout) catch break;
        }
        return report.fail(.writer_busy, "the writer stayed busy for {d} ms", .{
            limits.write_wait_ms,
        });
    }

    pub fn release(lock: *WriterLock, io: Io) void {
        const was = lock.state.swap(0, .release);
        assert(was == 1);
        io.futexWake(u32, &lock.state.raw, 1);
    }
};
