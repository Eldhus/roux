//! The app's one SQLite database, as the host keeps it.
//!
//! Opened once, in `init!`, before any shard: the connections, every
//! PRAGMA, limit and option set and read back, the schema created or
//! compared, and every statement of `Database.roc` prepared on each
//! connection that runs it. After that nothing is prepared, nothing is
//! opened and no SQL text is read: a request names a statement by number.
//!
//! - Readers: a few connections per shard (`ReaderPool`), never leaving its
//!   thread, each leased for one statement. With roux's VFS a statement
//!   may yield its fiber on the disk, and another fiber of the shard then
//!   needs another reader; none free, it waits a bounded time
//!   (`readers_busy`, a 503). (With SQLite's own VFS one reader was enough:
//!   the assertion that said so fired as the VFS changed.)
//! - The writer: one connection for the process, behind `WriterLock`, a
//!   bounded queue with a bounded wait (`writer_busy`, a 503). SQLite never
//!   sees two writers, so `busy_timeout` is 0.
//! - Before that, `Opening` brings the database to `schema.sql`, on a
//!   connection of its own, in one transaction: the steps of ledger.sql it
//!   has not run, each recorded in `roux_ledger`, then Migrate.roc's plan
//!   (a new database: `schema.sql` itself). It must then hold exactly the
//!   schema `schema.sql` makes (`sqlite_schema` compared row by row), or
//!   nothing changes and it does not open.
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
    /// Readers per shard: statements of one shard waiting on the disk at
    /// once, at most (more wait for one).
    readers_per_shard: u32 = 4,
    /// How long a statement waits for a reader before `readers_busy`.
    read_wait_ms: u32 = 100,
};

/// Readers a pool holds, at most (a bit each in `ReaderPool.free`).
pub const readers_per_shard_max = 32;
/// Statements of schema.sql.
pub const schema_statements_max = 1024;
/// SQLite's page cache, per connection.
pub const writer_cache_kib = 8 * 1024;
/// Smaller than the writer's: a shard has several (`Limits.readers_per_shard`).
pub const reader_cache_kib = 1024;
/// What a connection takes from SQLite's heap beside its page cache: the
/// schema, the prepared statements, lookaside, a statement's working
/// memory (sorts, joins). A bound still to check by measurement.
pub const connection_bytes = 4 * 1024 * 1024;

/// The page cache of a backup's copy (backup.zig), one at a time.
pub const backup_cache_kib = 1024;

/// SQLite's heap for a host of `shards` shards, as an itemised sum; the
/// host allocates it at startup (`sqlite.Setup`).
pub fn heap_bytes(shards: u32, limits: Limits) u64 {
    assert(shards >= 1);
    const readers: u64 = @as(u64, shards) * limits.readers_per_shard;
    const writer_cache: u64 = writer_cache_kib * 1024;
    const reader_caches: u64 = readers * reader_cache_kib * 1024;
    const backup_cache: u64 = backup_cache_kib * 1024;
    // The writer, the readers and a backup's copy.
    const connections: u64 = (2 + readers) * connection_bytes;
    // memsys5 rounds each allocation up to a power of two: twice, at worst.
    return 2 * (writer_cache + reader_caches + backup_cache + connections);
}

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
    readers_busy = 9,
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
    /// What messages call the database, when not `path`: a rehearsal
    /// migrates a copy, and speaks of the database it copied.
    name: ?[]const u8 = null,
    schema: []const u8,
    statements: []const StatementDescription,
    synchronous: Synchronous,
};

/// When a commit is durable. `full`: when it returns (the WAL synced at
/// every commit). `normal`: at the next checkpoint (a power loss or a
/// kernel panic may lose the commits since; a process crash loses
/// nothing): 31 times the writes, measured.
pub const Synchronous = enum(u8) {
    full = 0,
    normal = 1,

    fn pragma(synchronous: Synchronous) []const u8 {
        return switch (synchronous) {
            .full => "PRAGMA synchronous = FULL",
            .normal => "PRAGMA synchronous = NORMAL",
        };
    }

    /// As `PRAGMA synchronous` reads back.
    fn level(synchronous: Synchronous) i64 {
        return switch (synchronous) {
            .full => 2,
            .normal => 1,
        };
    }
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
    synchronous: Synchronous,
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
    const writer = try open_connection(
        gpa,
        path,
        .writer,
        statements,
        description.synchronous,
        report,
    );
    errdefer close_connection(gpa, writer);
    try ensure_schema(writer.db, description, report);
    try prepare_statements(writer, statements, report);
    const database = gpa.create(Database) catch return out_of_memory(report);
    database.* = .{
        .limits = limits,
        .synchronous = description.synchronous,
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

/// One shard's readers, leased a statement at a time. Used by its own
/// thread only; a fiber waiting for a reader yields on a futex.
pub const ReaderPool = struct {
    readers: []*Connection,
    /// Bit i: reader i is free.
    free: u32,
    /// Bumped by every release: what a waiting fiber's futex watches.
    released: std.atomic.Value(u32) = .init(0),
    /// Fibers waiting for a reader: a release wakes one only if there is
    /// one (a wake is a system call on Evented, even with no waiter).
    waiting: u32 = 0,

    /// The pool, at the shard's start: `limits.readers_per_shard` readers.
    pub fn open(
        gpa: Allocator,
        database: *const Database,
        report: *Report,
    ) error{Failed}!ReaderPool {
        const count = database.limits.readers_per_shard;
        assert(count >= 1 and count <= readers_per_shard_max);
        const readers = gpa.alloc(*Connection, count) catch return out_of_memory(report);
        for (readers) |*reader| reader.* = try open_reader(gpa, database, report);
        const all: u32 = @truncate((@as(u64, 1) << @intCast(count)) - 1);
        return .{ .readers = readers, .free = all };
    }

    /// A free reader, or one released within `limits.read_wait_ms`.
    pub fn lease(
        pool: *ReaderPool,
        io: Io,
        limits: Limits,
        report: *Report,
    ) error{Failed}!*Connection {
        if (pool.free != 0) return pool.take();
        const wait: Io.Duration = .fromMilliseconds(limits.read_wait_ms);
        const deadline = Io.Timestamp.now(io, .awake).addDuration(wait);
        pool.waiting += 1;
        defer pool.waiting -= 1;
        // Each pass takes a reader, or waits for a release or the deadline.
        const passes_max = 1 << 20;
        for (0..passes_max) |_| {
            const seen = pool.released.load(.acquire);
            if (pool.free != 0) return pool.take();
            if (Io.Timestamp.now(io, .awake).nanoseconds >= deadline.nanoseconds) break;
            const timeout: Io.Timeout = .{ .deadline = deadline.withClock(.awake) };
            io.futexWaitTimeout(u32, &pool.released.raw, seen, timeout) catch break;
        }
        return report.fail(.readers_busy, "every reader of the shard stayed busy for {d} ms", .{
            limits.read_wait_ms,
        });
    }

    fn take(pool: *ReaderPool) *Connection {
        assert(pool.free != 0);
        const index: u5 = @intCast(@ctz(pool.free));
        pool.free &= ~(@as(u32, 1) << index);
        const reader = pool.readers[index];
        assert(!reader.running);
        return reader;
    }

    pub fn release(pool: *ReaderPool, io: Io, reader: *Connection) void {
        assert(!reader.running); // its statement ran to its end, or failed
        for (pool.readers, 0..) |candidate, index| {
            if (candidate != reader) continue;
            const bit = @as(u32, 1) << @intCast(index);
            assert(pool.free & bit == 0); // leased
            pool.free |= bit;
            _ = pool.released.fetchAdd(1, .release);
            if (pool.waiting > 0) io.futexWake(u32, &pool.released.raw, 1);
            return;
        }
        unreachable; // a reader of this pool
    }
};

/// A shard's reader, at the shard's start: every read statement prepared.
pub fn open_reader(
    gpa: Allocator,
    database: *const Database,
    report: *Report,
) error{Failed}!*Connection {
    const reader = try open_connection(
        gpa,
        database.path,
        .reader,
        database.statements,
        database.synchronous,
        report,
    );
    errdefer close_connection(gpa, reader);
    try prepare_statements(reader, database.statements, report);
    return reader;
}

/// A connection to the database at `path` with no statements: what
/// host/backup.zig copies before ledger.sql's steps commit (a reader, it
/// sees the database as the last commit left it).
pub fn open_copy_source(
    gpa: Allocator,
    path: []const u8,
    report: *Report,
) error{Failed}!*Connection {
    const path_z = dupe_sentinel(gpa, path) catch return out_of_memory(report);
    defer gpa.free(path_z);
    return open_connection(gpa, path_z, .reader, &.{}, .full, report);
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
    synchronous: Synchronous,
    report: *Report,
) error{Failed}!*Connection {
    var db: ?*c.Db = null;
    const flags = c.open_readwrite | c.open_create | c.open_nomutex | c.open_exrescode;
    const opened = c.sqlite3_open_v2(path, &db, flags, null);
    if (opened != c.ok) {
        const text = if (opened & 0xff == c.busy)
            "another process has it open (one process owns a database: is the app " ++
                "still running, or a sqlite3 shell?)"
        else if (db) |handle| std.mem.span(c.sqlite3_errmsg(handle)) else "out of memory";
        _ = c.sqlite3_close_v2(db);
        return report.fail(.failed, "open {s}: {s}", .{ path, text });
    }
    errdefer _ = c.sqlite3_close_v2(db);
    const prepared = gpa.alloc(?*c.Stmt, statements.len) catch return out_of_memory(report);
    @memset(prepared, null);
    const connection = gpa.create(Connection) catch return out_of_memory(report);
    connection.* = .{ .db = db.?, .role = role, .prepared = prepared };
    configure(connection, synchronous, report) catch {
        // Which database: a directory it cannot write fails here (WAL).
        var said: @TypeOf(report.buffer) = undefined;
        const message = said[0..report.length];
        @memcpy(message, report.message());
        return report.fail(report.failure, "open {s}: {s}", .{ path, message });
    };
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

/// Every `sqlite3_limit`, explicit: none left to SQLite's default. In id
/// order, from 0; `configure` fails if SQLite has one past the last, so a
/// new release's new limit is set here before it runs.
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
    .{ .id = c.limit_parser_depth, .value = 2500 },
    .{ .id = c.limit_schema, .value = 10_000 },
    .{ .id = c.limit_trigger_steps, .value = 64 },
};

comptime {
    for (sqlite_limits, 0..) |limit, index| assert(limit.id == index);
}

fn configure(
    connection: *Connection,
    synchronous: Synchronous,
    report: *Report,
) error{Failed}!void {
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
    const unset = c.sqlite3_limit(db, sqlite_limits.len, -1);
    if (unset != -1) {
        return report.fail(.failed, "sqlite3_limit {d}: a limit roux does not set", .{
            sqlite_limits.len,
        });
    }
    try configure_pragmas(connection, synchronous, report);
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

fn configure_pragmas(
    connection: *Connection,
    synchronous: Synchronous,
    report: *Report,
) error{Failed}!void {
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
    // On every connection, readers too: the last to close checkpoints.
    sqlite.exec(db, synchronous.pragma()) catch
        return report.fail(.failed, "{s}: {s}", .{ synchronous.pragma(), c.sqlite3_errmsg(db) });
    const level = try pragma_integer(db, "PRAGMA synchronous", report);
    if (level != synchronous.level()) {
        return report.fail(.failed, "PRAGMA synchronous: {d}, not {d}", .{
            level,
            synchronous.level(),
        });
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
/// one must be exactly what `schema` makes (`Opening` saw to it).
fn ensure_schema(db: *c.Db, description: Description, report: *Report) error{Failed}!void {
    const objects = try pragma_integer(db, "SELECT count(*) FROM sqlite_schema", report);
    if (objects == 0) {
        sqlite.exec(db, "BEGIN IMMEDIATE") catch
            return report.fail(.failed, "BEGIN: {s}", .{c.sqlite3_errmsg(db)});
        create_schema(db, description.schema, report) catch |err| {
            sqlite.exec(db, "ROLLBACK") catch {};
            return err;
        };
        sqlite.exec(db, "COMMIT") catch
            return report.fail(.failed, "COMMIT: {s}", .{c.sqlite3_errmsg(db)});
        return;
    }
    const pristine = try open_pristine(description.schema, report);
    defer close_pristine(pristine);
    try compare_schemas(db, pristine, description.name orelse description.path, report);
}

/// What `schema` makes, in memory, by the same policy as a new database.
pub fn open_pristine(schema: []const u8, report: *Report) error{Failed}!*c.Db {
    var pristine: ?*c.Db = null;
    const flags = c.open_readwrite | c.open_create | c.open_memory | c.open_exrescode;
    if (c.sqlite3_open_v2(":memory:", &pristine, flags, null) != c.ok) {
        _ = c.sqlite3_close_v2(pristine);
        return out_of_memory(report);
    }
    errdefer close_pristine(pristine.?);
    try create_schema(pristine.?, schema, report);
    return pristine.?;
}

pub fn close_pristine(pristine: *c.Db) void {
    const result = c.sqlite3_close_v2(pristine);
    assert(result == c.ok);
}

// --- migrations ---------------------------------------------------------------

/// A statement of a migration, and why it runs: Migrate.roc's plan.
pub const Step = struct { sql: []const u8, why: []const u8 };

/// Steps of one migration, at most.
pub const migration_steps_max = 4 * schema_statements_max;

/// What a migration is planned from, in the order SQLite made it; SQLite's
/// own tables (`sqlite_sequence`, `sqlite_stat1`, a key's index) and roux's
/// (`roux_ledger`) are left out.
pub const Listing = enum {
    /// type, name, tbl_name, sql: `sqlite_schema`.
    objects,
    /// Table, column, hidden (`pragma_table_xinfo`: 2 and 3 are generated),
    /// and 1 for the key of a table with AUTOINCREMENT, 0 for any other
    /// (`sqlite3_table_column_metadata`: no pragma says it).
    columns,
    /// The steps of ledger.sql the database ran, in order: `roux_ledger`.
    ledger,

    /// The app's: names starting `sqlite_` are SQLite's, and roux keeps
    /// the ledger in a table of its own (roux-db refuses `roux_` names).
    pub fn own(comptime name: []const u8) []const u8 {
        return name ++ " NOT LIKE 'sqlite\\_%' ESCAPE '\\' AND " ++ name ++ " <> 'roux_ledger'";
    }

    pub fn sql(listing: Listing) []const u8 {
        return switch (listing) {
            .objects => "SELECT type, name, tbl_name, coalesce(sql, '') FROM sqlite_schema " ++
                "WHERE " ++ comptime own("name") ++ " ORDER BY rowid",
            .columns => "SELECT m.name, c.name, c.hidden FROM sqlite_schema AS m " ++
                "JOIN pragma_table_xinfo(m.name) AS c " ++
                "WHERE m.type = 'table' AND " ++ comptime own("m.name") ++
                " ORDER BY m.rowid, c.cid",
            .ledger => "SELECT sql FROM roux_ledger ORDER BY step",
        };
    }

    /// Cells of each row: the SQL's columns, then the autoincrement flag.
    pub fn width(listing: Listing) u32 {
        return switch (listing) {
            .objects => 4,
            .columns => 4,
            .ledger => 1,
        };
    }

    fn selected(listing: Listing) u32 {
        return switch (listing) {
            .objects => 4,
            .columns => 3,
            .ledger => 1,
        };
    }
};

/// Rows one listing gives, at most: a table's columns are most of them.
pub const listing_rows_max = 64 * schema_statements_max;

/// Rows of `listing` over `db`, each cell text or an integer, into `sink`
/// (`row()`, then `cell(value)` for each column).
pub fn list(db: *c.Db, listing: Listing, sink: anytype, report: *Report) error{Failed}!void {
    const statement = try prepare_own(db, listing.sql(), report);
    defer _ = c.sqlite3_finalize(statement);
    const rows_max = listing_rows_max;
    // One more step than rows: the last says done.
    for (0..rows_max + 1) |index| {
        switch (c.sqlite3_step(statement)) {
            c.done => return,
            c.row => if (index == rows_max) break,
            else => return report.fail(.failed, "{t}: {s}", .{ listing, c.sqlite3_errmsg(db) }),
        }
        sink.row() catch return report.fail(.failed, "{t}: out of memory", .{listing});
        for (0..listing.selected()) |column| {
            const value: Value = switch (c.sqlite3_column_type(statement, @intCast(column))) {
                c.integer => .{ .integer = c.sqlite3_column_int64(statement, @intCast(column)) },
                else => .{ .text = column_text(statement, @intCast(column)) },
            };
            sink.cell(value) catch return report.fail(.failed, "{t}: out of memory", .{listing});
        }
        if (listing == .columns) {
            const value: Value = .{ .integer = try autoincrement(db, statement, report) };
            sink.cell(value) catch return report.fail(.failed, "{t}: out of memory", .{listing});
        }
    }
    return report.fail(.failed, "{t}: more than {d} rows", .{ listing, rows_max });
}

/// 1 when the column the `columns` listing is on is the key of a table with
/// AUTOINCREMENT: SQLite then keeps the largest key handed out in
/// `sqlite_sequence`, which a rebuild must carry over.
fn autoincrement(db: *c.Db, columns: *c.Stmt, report: *Report) error{Failed}!i64 {
    // SQLite's text results end in a NUL.
    const table: [*:0]const u8 = @ptrCast(c.sqlite3_column_text(columns, 0) orelse unreachable);
    const column: [*:0]const u8 = @ptrCast(c.sqlite3_column_text(columns, 1) orelse unreachable);
    var flag: c_int = 0;
    const result = c.sqlite3_table_column_metadata(
        db,
        "main",
        table,
        column,
        null,
        null,
        null,
        null,
        &flag,
    );
    if (result != c.ok) {
        return report.fail(.failed, "columns of {s}: {s}", .{ table, c.sqlite3_errmsg(db) });
    }
    assert(flag == 0 or flag == 1);
    return flag;
}

/// Where ledger.sql's steps a database ran are recorded, in order: made in
/// every database roux opens; one without it ran none.
const ledger_table = "CREATE TABLE IF NOT EXISTS roux_ledger " ++
    "(step INTEGER PRIMARY KEY, sql TEXT NOT NULL) STRICT";

/// A database brought to `schema.sql` before `open` opens it: a connection
/// of its own, in one transaction from `begin` until `commit`, and closed
/// (`close` rolls back what was not committed). In it, the steps of
/// ledger.sql the database has not run (`run_ledger`), then Migrate.roc's
/// plan, or `schema.sql` itself for a new database (`migrate`). Foreign
/// keys are off throughout, SQLite's way ("Making Other Kinds Of Table
/// Schema Changes": a step's DELETE cascades nothing), and checked once,
/// before the commit. Anything short of exactly the pristine schema rolls
/// it all back.
pub const Opening = struct {
    connection: *Connection,
    pristine: *c.Db,
    path: [:0]const u8,
    schema: []const u8,
    /// What messages call the database: a rehearsal's copy is named as the
    /// database it copied.
    name: []const u8,
    /// Steps of ledger.sql the database records as run.
    recorded: u32,
    /// Steps this opening ran, not only recorded: the database is copied
    /// before it commits.
    ran: u32 = 0,

    /// Steps of a ledger, at most (roux-db's bound).
    pub const steps_max = 4096;

    pub fn begin(
        gpa: Allocator,
        path: []const u8,
        name: []const u8,
        schema: []const u8,
        report: *Report,
    ) error{Failed}!Opening {
        sqlite.initialize() catch return report.fail(.failed, "sqlite3_initialize failed", .{});
        const path_z = dupe_sentinel(gpa, path) catch return out_of_memory(report);
        errdefer gpa.free(path_z);
        const connection = try open_connection(gpa, path_z, .writer, &.{}, .full, report);
        errdefer close_connection(gpa, connection);
        const db = connection.db;
        try set_foreign_keys(db, false, report);
        sqlite.exec(db, "BEGIN IMMEDIATE") catch
            return report.fail(.failed, "BEGIN: {s}", .{c.sqlite3_errmsg(db)});
        errdefer sqlite.exec(db, "ROLLBACK") catch {};
        sqlite.exec(db, ledger_table) catch
            return report.fail(.failed, "roux_ledger: {s}", .{c.sqlite3_errmsg(db)});
        const recorded = try pragma_integer(db, "SELECT count(*) FROM roux_ledger", report);
        if (recorded > steps_max) {
            return report.fail(.failed, "roux_ledger: {d} steps, over {d}", .{
                recorded, steps_max,
            });
        }
        const pristine = try open_pristine(schema, report);
        errdefer close_pristine(pristine);
        const schema_kept = gpa.dupe(u8, schema) catch return out_of_memory(report);
        errdefer gpa.free(schema_kept);
        return .{
            .connection = connection,
            .pristine = pristine,
            .path = path_z,
            .schema = schema_kept,
            .name = gpa.dupe(u8, name) catch return out_of_memory(report),
            .recorded = @intCast(recorded),
        };
    }

    /// Runs `steps`, the ledger's next, each recorded as it runs; with
    /// `execute` false, records them only (a new database, made by
    /// schema.sql).
    pub fn run_ledger(
        opening: *Opening,
        steps: []const []const u8,
        execute: bool,
        report: *Report,
    ) error{Failed}!void {
        if (opening.recorded + steps.len > steps_max) {
            return report.fail(.misuse, "a ledger of over {d} steps", .{steps_max});
        }
        const db = opening.connection.db;
        for (steps) |step| {
            const number = opening.recorded + 1;
            if (execute) {
                var buffer: [32]u8 = undefined;
                const why = std.fmt.bufPrint(&buffer, "ledger.sql's step {d}", .{number}) catch
                    unreachable; // a u32 fits
                try exec_step(db, step, why, .ledger, opening.name, report);
                opening.ran += 1;
            }
            try record_step(db, number, step, report);
            opening.recorded = number;
        }
    }

    /// Brings the database to schema.sql: by `migration` (Migrate.roc's
    /// plan), or by schema.sql itself when it holds nothing; then checks.
    /// Legacy ALTER TABLE keeps the plan's rename of a table aside from
    /// rewriting what refers to it, so every CREATE ends as schema.sql wrote
    /// it (a step of the ledger renames as SQLite does now).
    pub fn migrate(
        opening: *Opening,
        migration: []const Step,
        report: *Report,
    ) error{Failed}!void {
        if (migration.len > migration_steps_max) {
            return report.fail(.misuse, "a migration of {d} steps", .{migration.len});
        }
        const db = opening.connection.db;
        const count = "SELECT count(*) FROM sqlite_schema WHERE " ++ comptime Listing.own("name");
        if (try pragma_integer(db, count, report) == 0) {
            if (migration.len > 0) {
                return report.fail(.misuse, "a migration for a new database", .{});
            }
            try create_schema(db, opening.schema, report);
        } else {
            try set_legacy_alter_table(db, true, report);
            for (migration) |step| {
                try exec_step(db, step.sql, step.why, .plan, opening.name, report);
            }
        }
        try check_foreign_keys(db, opening.name, report);
        try compare_schemas(db, opening.pristine, opening.name, report);
    }

    pub fn commit(opening: *Opening, report: *Report) error{Failed}!void {
        const db = opening.connection.db;
        sqlite.exec(db, "COMMIT") catch
            return report.fail(.failed, "COMMIT: {s}", .{c.sqlite3_errmsg(db)});
    }

    /// Rolls back what was not committed, and closes the connection.
    pub fn close(opening: *Opening, gpa: Allocator) void {
        const db = opening.connection.db;
        if (c.sqlite3_get_autocommit(db) == 0) sqlite.exec(db, "ROLLBACK") catch {};
        close_pristine(opening.pristine);
        close_connection(gpa, opening.connection);
        gpa.free(opening.path);
        gpa.free(opening.schema);
        gpa.free(opening.name);
        opening.* = undefined;
    }
};

/// A step of the ledger, or of Migrate.roc's plan.
const StepKind = enum { ledger, plan };

/// Runs one statement of a migration, by the migration's policy, saying
/// which and why when it fails.
fn exec_step(
    db: *c.Db,
    sql: []const u8,
    why: []const u8,
    kind: StepKind,
    name: []const u8,
    report: *Report,
) error{Failed}!void {
    var verdict: authorizer.Verdict = .{ .policy = .migration };
    authorizer.install(db, &verdict);
    const ran = sqlite.exec_one(db, sql);
    authorizer.uninstall(db);
    ran catch |err| {
        switch (err) {
            error.NotOneStatement => return report.fail(.misuse, "migrating {s}: {s}: " ++
                "more than one statement", .{ name, why }),
            error.Sqlite => {},
        }
        if (verdict.refused) |action| {
            return report.fail(.misuse, "migrating {s}: {s}: a migration may not hold {s}", .{
                name, why, authorizer.describe(action),
            });
        }
        // A copied NULL is copied as NULL: the column's DEFAULT is for a
        // row that names no value. Extended codes: the connection was
        // opened with them.
        const hint = if (kind == .plan and c.sqlite3_errcode(db) == c.constraint_notnull)
            " (a NOT NULL column needs a value in every row: a column new to the table " ++
                "takes its DEFAULT, a copied one keeps its NULLs; a step of ledger.sql " ++
                "fills it)"
        else
            "";
        return report.fail(.failed, "migrating {s}: {s}: {s}{s}", .{
            name, why, c.sqlite3_errmsg(db), hint,
        });
    };
}

/// Step `number` of the ledger, recorded as run, in the migration's
/// transaction: with it, or not at all.
fn record_step(db: *c.Db, number: u32, sql: []const u8, report: *Report) error{Failed}!void {
    const record = "INSERT INTO roux_ledger (step, sql) VALUES (?1, ?2)";
    const insert = try prepare_own(db, record, report);
    defer _ = c.sqlite3_finalize(insert);
    assert(c.sqlite3_bind_int64(insert, 1, number) == c.ok);
    if (c.sqlite3_bind_text64(insert, 2, sql.ptr, sql.len, null, c.utf8) != c.ok or
        c.sqlite3_step(insert) != c.done)
    {
        return report.fail(.failed, "roux_ledger: {s}", .{c.sqlite3_errmsg(db)});
    }
}

/// Fails naming the first rows whose foreign key points nowhere, if any.
fn check_foreign_keys(db: *c.Db, path: []const u8, report: *Report) error{Failed}!void {
    const count = "SELECT count(*) FROM pragma_foreign_key_check";
    const violations = try pragma_integer(db, count, report);
    if (violations == 0) return;
    const named = "SELECT \"table\", rowid, parent FROM pragma_foreign_key_check LIMIT 3";
    const rows = try prepare_own(db, named, report);
    defer _ = c.sqlite3_finalize(rows);
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    for (0..3) |_| {
        if (c.sqlite3_step(rows) != c.row) break;
        // A WITHOUT ROWID table's row has no rowid to name.
        const said = if (c.sqlite3_column_type(rows, 1) == c.null_type)
            w.print("; a row of {s} names no {s}", .{ column_text(rows, 0), column_text(rows, 2) })
        else
            w.print("; {s} row {d} names no {s}", .{
                column_text(rows, 0), c.sqlite3_column_int64(rows, 1), column_text(rows, 2),
            });
        said catch break;
    }
    return report.fail(.failed, "migrating {s}: rows that would break a foreign key: {d}{s}", .{
        path, violations, w.buffered(),
    });
}

/// Outside a transaction only: inside one SQLite ignores the PRAGMA, and a
/// rebuild would then cascade the old table's DROP into other tables.
fn set_foreign_keys(db: *c.Db, on: bool, report: *Report) error{Failed}!void {
    assert(c.sqlite3_get_autocommit(db) != 0);
    const sql = if (on) "PRAGMA foreign_keys = ON" else "PRAGMA foreign_keys = OFF";
    sqlite.exec(db, sql) catch return report.fail(.failed, "{s}: {s}", .{
        sql, c.sqlite3_errmsg(db),
    });
    const value = try pragma_integer(db, "PRAGMA foreign_keys", report);
    if (value != @intFromBool(on)) return report.fail(.failed, "{s}: {d}", .{ sql, value });
}

fn set_legacy_alter_table(db: *c.Db, on: bool, report: *Report) error{Failed}!void {
    var readback: c_int = -1;
    const value: c_int = @intFromBool(on);
    const result = c.sqlite3_db_config(db, c.dbconfig_legacy_alter_table, value, &readback);
    if (result != c.ok or readback != value) {
        return report.fail(.failed, "legacy_alter_table: {d}, not {d}", .{ readback, value });
    }
}

/// `schema`, by its policy, in the caller's transaction (a failure leaves
/// part of it, for the caller to roll back).
fn create_schema(db: *c.Db, schema: []const u8, report: *Report) error{Failed}!void {
    var verdict: authorizer.Verdict = .{ .policy = .schema };
    authorizer.install(db, &verdict);
    defer authorizer.uninstall(db);
    sqlite.exec(db, schema) catch {
        if (verdict.refused) |action| {
            return report.fail(.failed, "schema.sql may not hold {s}", .{
                authorizer.describe(action),
            });
        }
        return report.fail(.failed, "schema.sql: {s}", .{c.sqlite3_errmsg(db)});
    };
}

/// `sqlite_schema` row by row: SQLite keeps each CREATE as it was written,
/// so two databases made by the same `schema.sql` hold the same rows.
/// SQLite's own are left out, as the listings leave them: a key's index
/// follows from its CREATE; `sqlite_sequence` outlives the last
/// AUTOINCREMENT, and ANALYZE (a `sqlite3` shell's) leaves `sqlite_stat1`.
/// So is roux's `roux_ledger`, which schema.sql never makes.
fn compare_schemas(
    db: *c.Db,
    expected: *c.Db,
    path: []const u8,
    report: *Report,
) error{Failed}!void {
    const sql = "SELECT type, name, tbl_name, coalesce(sql, '') FROM sqlite_schema " ++
        "WHERE " ++ comptime Listing.own("name") ++ " ORDER BY type, name";
    const actual_rows = try prepare_own(db, sql, report);
    defer _ = c.sqlite3_finalize(actual_rows);
    const expected_rows = try prepare_own(expected, sql, report);
    defer _ = c.sqlite3_finalize(expected_rows);
    for (0..schema_statements_max * 4 + 1) |index| {
        const actual_step = c.sqlite3_step(actual_rows);
        const expected_step = c.sqlite3_step(expected_rows);
        if (actual_step == c.done and expected_step == c.done) return;
        if (actual_step != c.row or expected_step != c.row) {
            return schema_differs(expected_rows, actual_rows, path, report);
        }
        if (index == schema_statements_max * 4) break;
        for (0..4) |column| {
            const actual = column_text(actual_rows, @intCast(column));
            const wanted = column_text(expected_rows, @intCast(column));
            if (!std.mem.eql(u8, actual, wanted)) {
                return schema_differs(expected_rows, actual_rows, path, report);
            }
        }
    }
    return report.fail(.failed, "more than {d} schema objects", .{schema_statements_max * 4});
}

/// What differs. The migration was planned for this very database, so
/// after one this is the planner's mistake, and nothing was changed.
fn schema_differs(
    expected: *c.Stmt,
    actual: *c.Stmt,
    path: []const u8,
    report: *Report,
) error{Failed} {
    const expected_name = name_of_row(expected);
    const actual_name = name_of_row(actual);
    if (std.mem.eql(u8, expected_name, actual_name)) {
        return report.fail(.failed, "{s} is not as schema.sql makes it: `{s}` differs", .{
            path, expected_name,
        });
    }
    return report.fail(.failed, "{s} is not as schema.sql makes it: `{s}` in schema.sql, " ++
        "`{s}` in the database", .{ path, expected_name, actual_name });
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
/// FIFO: a waiter woken may lose to one arriving (not yet measured).
pub const WriterLock = struct {
    /// 0 free, 1 held.
    state: std.atomic.Value(u32) = .init(0),
    waiting: std.atomic.Value(u32) = .init(0),

    pub fn acquire(lock: *WriterLock, io: Io, limits: Limits, report: *Report) error{Failed}!void {
        if (lock.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) return;
        // Sequentially consistent with `release`: a waiter counted before
        // it reads the lock, a release frees it before it reads the count,
        // so no release misses a waiter that then sleeps.
        if (lock.waiting.fetchAdd(1, .seq_cst) >= limits.writers_waiting) {
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
            if (lock.state.cmpxchgStrong(0, 1, .seq_cst, .seq_cst) == null) return;
            if (Io.Timestamp.now(io, .awake).nanoseconds >= deadline.nanoseconds) break;
            const timeout: Io.Timeout = .{ .deadline = deadline.withClock(.awake) };
            io.futexWaitTimeout(u32, &lock.state.raw, 1, timeout) catch break;
        }
        return report.fail(.writer_busy, "the writer stayed busy for {d} ms", .{
            limits.write_wait_ms,
        });
    }

    pub fn release(lock: *WriterLock, io: Io) void {
        const was = lock.state.swap(0, .seq_cst);
        assert(was == 1);
        // A wake is a system call: only for a request that waits. One that
        // starts waiting after this load finds the lock free first.
        if (lock.waiting.load(.seq_cst) > 0) io.futexWake(u32, &lock.state.raw, 1);
    }
};
