//! sqlite-floor: what SQLite costs alone, with nothing of roux around it,
//! so a request's database cost can be split into SQLite's and ours.
//!
//!   sqlite-floor step DIR [N]       a point query, prepared once: bind, step, read, reset
//!   sqlite-floor prepare DIR [N]    the same, prepared and finalized each time
//!   sqlite-floor open DIR [N]       the same on a new connection each time
//!   sqlite-floor open-wide DIR [N]  the same, the schema of twenty tables
//!   sqlite-floor fsync DIR [N]      a 4 KiB write and fdatasync: the disk's physics
//!
//! DIR holds the databases (made on first use: 10,000 rows) and must be on
//! the disk measured, never tmpfs. Prints nanoseconds per operation; wrap
//! a run in `perf stat -e instructions:u` for instructions. Built by
//! `zig build sqlite-floor`, in the host's mode.

const std = @import("std");
const assert = std.debug.assert;
const sqlite = @import("sqlite.zig");
const c = @import("c.zig");
const Io = std.Io;

const Mode = enum { step, prepare, open, @"open-wide", fsync };

const rows = 10_000;
const iterations_max = 10_000_000;
/// Latencies are kept one by one for the percentiles.
const fsync_iterations_max = 100_000;
const fsync_block_bytes = 4096;
/// Over this many blocks, so writes do not land on one page only.
const fsync_blocks = 256;
const point_query = "SELECT id, name, price_kr FROM dish WHERE id = ?1";
/// Tables beside `dish` in the wide schema, each with an index.
const wide_tables = 19;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) fatal("usage: sqlite-floor step|prepare|open|open-wide|fsync DIR [N]");
    const mode = std.meta.stringToEnum(Mode, args[1]) orelse fatal("unknown mode");
    const dir = args[2];
    const iterations: u32 = if (args.len > 3)
        std.fmt.parseInt(u32, args[3], 10) catch fatal("N: a number")
    else switch (mode) {
        .step, .prepare => 1_000_000,
        .open, .@"open-wide" => 20_000,
        .fsync => 2_000,
    };
    if (iterations == 0 or iterations > iterations_max) fatal("N: 1 to 10,000,000");
    try sqlite.initialize();
    const io = init.io;
    sqlite.vfs.thread_io = io;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    switch (mode) {
        .fsync => {
            if (iterations > fsync_iterations_max) fatal("N: at most 100,000 for fsync");
            const path = try std.fmt.bufPrint(&path_buffer, "{s}/fsync.bin", .{dir});
            try run_fsync(io, arena, path, iterations);
        },
        .step, .prepare, .open, .@"open-wide" => {
            const name = if (mode == .@"open-wide") "wide.db" else "floor.db";
            const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/{s}", .{ dir, name }, 0);
            try ensure_database(path, mode == .@"open-wide");
            const before = sqlite.vfs.calls;
            const elapsed_ns = try run_queries(io, mode, path, iterations);
            print("{t}: {d} iterations, {d} ns per operation\n", .{
                mode, iterations, elapsed_ns / iterations,
            });
            print_calls(before, sqlite.vfs.calls, iterations);
        },
    }
}

/// The point queries of `mode`, timed; returns the elapsed nanoseconds.
fn run_queries(io: Io, mode: Mode, path: [:0]const u8, iterations: u32) !u64 {
    assert(mode != .fsync);
    assert(iterations > 0);
    const db = try open(path);
    defer _ = c.sqlite3_close_v2(db);
    const statement = try prepare(db, point_query);
    defer _ = c.sqlite3_finalize(statement);
    var checksum: i64 = 0;
    const start = Io.Timestamp.now(io, .awake);
    for (0..iterations) |i| {
        const id = row_id(@intCast(i));
        checksum +%= switch (mode) {
            .step => try query(statement, id),
            .prepare => try query_prepared(db, id),
            .open, .@"open-wide" => try query_connected(path, id),
            .fsync => unreachable,
        };
    }
    const elapsed = start.durationTo(Io.Timestamp.now(io, .awake));
    // Every id was found: the sum of the prices read is not zero.
    assert(checksum != 0);
    return @intCast(elapsed.nanoseconds);
}

/// Ids walk every row in a fixed order: 7,919 is prime, so coprime with
/// `rows`, and no two neighbouring queries read neighbouring rows.
fn row_id(i: u32) i64 {
    comptime assert(rows % 7_919 != 0);
    const id = (@as(u64, i) * 7_919) % rows + 1;
    assert(id >= 1 and id <= rows);
    return @intCast(id);
}

/// One point query on a prepared statement: bind, step, read the row,
/// step to the end, reset. Returns the price read.
fn query(statement: *c.Stmt, id: i64) !i64 {
    if (c.sqlite3_bind_int64(statement, 1, id) != c.ok) return error.Sqlite;
    defer _ = c.sqlite3_reset(statement);
    if (c.sqlite3_step(statement) != c.row) return error.Sqlite;
    assert(c.sqlite3_column_count(statement) == 3);
    assert(c.sqlite3_column_int64(statement, 0) == id);
    assert(c.sqlite3_column_type(statement, 1) == c.text);
    const name = c.sqlite3_column_text(statement, 1) orelse return error.Sqlite;
    const name_bytes = c.sqlite3_column_bytes(statement, 1);
    assert(name_bytes > 0);
    assert(name[0] == 'd');
    const price = c.sqlite3_column_int64(statement, 2);
    if (c.sqlite3_step(statement) != c.done) return error.Sqlite;
    return price;
}

fn query_prepared(db: *c.Db, id: i64) !i64 {
    const statement = try prepare(db, point_query);
    defer _ = c.sqlite3_finalize(statement);
    return query(statement, id);
}

fn query_connected(path: [:0]const u8, id: i64) !i64 {
    const db = try open(path);
    defer _ = c.sqlite3_close_v2(db);
    return query_prepared(db, id);
}

fn open(path: [:0]const u8) !*c.Db {
    var db: ?*c.Db = null;
    const flags = c.open_readwrite | c.open_create | c.open_exrescode;
    if (c.sqlite3_open_v2(path, &db, flags, null) != c.ok) {
        print("open {s}: {s}\n", .{ path, c.sqlite3_errmsg(db) });
        _ = c.sqlite3_close_v2(db);
        return error.Sqlite;
    }
    return db.?;
}

fn prepare(db: *c.Db, sql: []const u8) !*c.Stmt {
    var statement: ?*c.Stmt = null;
    if (c.sqlite3_prepare_v3(db, sql.ptr, @intCast(sql.len), 0, &statement, null) != c.ok) {
        print("prepare: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.Sqlite;
    }
    return statement.?;
}

/// The floor's database: `dish` with `rows` rows, in WAL mode, as the host
/// will keep it; with `wide`, nineteen more tables and their indices.
/// Made once; a run reuses it.
fn ensure_database(path: [:0]const u8, wide: bool) !void {
    const db = try open(path);
    defer _ = c.sqlite3_close_v2(db);
    const statement = try prepare(db, "SELECT count(*) FROM sqlite_schema");
    const tables = blk: {
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.row) return error.Sqlite;
        break :blk c.sqlite3_column_int64(statement, 0);
    };
    if (tables > 0) return; // made by an earlier run
    try exec(db,
        \\PRAGMA journal_mode = WAL;
        \\PRAGMA synchronous = FULL;
        \\CREATE TABLE dish (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  price_kr INTEGER NOT NULL
        \\) STRICT;
        \\BEGIN;
        \\WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 10000)
        \\INSERT INTO dish (id, name, price_kr) SELECT i, 'dish ' || i, 50 + i % 200 FROM n;
        \\COMMIT;
    );
    if (wide) try add_wide_tables(db);
}

/// Nineteen tables of six columns and an index each: the schema SQLite
/// parses when a connection prepares its first statement.
fn add_wide_tables(db: *c.Db) !void {
    var sql_buffer: [512]u8 = undefined;
    for (0..wide_tables) |table| {
        const sql = try std.fmt.bufPrint(&sql_buffer,
            \\CREATE TABLE extra_{d} (
            \\  id INTEGER PRIMARY KEY, dish_id INTEGER NOT NULL REFERENCES dish (id),
            \\  label TEXT NOT NULL, amount INTEGER NOT NULL, note TEXT, made_at INTEGER NOT NULL
            \\) STRICT;
            \\CREATE INDEX extra_{d}_dish ON extra_{d} (dish_id, made_at);
        , .{ table, table, table });
        try exec(db, sql);
    }
}

fn exec(db: *c.Db, sql: []const u8) !void {
    sqlite.exec(db, sql) catch |err| {
        print("exec: {s}\n", .{c.sqlite3_errmsg(db)});
        return err;
    };
}

/// A 4 KiB write then fdatasync, `iterations` times: the latency of one
/// durable commit on this disk, which bounds one writer's commits per second.
fn run_fsync(io: Io, arena: std.mem.Allocator, path: []const u8, iterations: u32) !void {
    assert(iterations > 0 and iterations <= fsync_iterations_max);
    const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    defer file.close(io);
    const latencies_ns = try arena.alloc(u64, iterations);
    const block: [fsync_block_bytes]u8 = @splat('w');
    for (latencies_ns, 0..) |*latency_ns, i| {
        const offset = (i % fsync_blocks) * fsync_block_bytes;
        const start = Io.Timestamp.now(io, .awake);
        try file.writePositionalAll(io, &block, offset);
        const result = std.os.linux.fdatasync(file.handle);
        if (std.os.linux.errno(result) != .SUCCESS) return error.Fdatasync;
        latency_ns.* = @intCast(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
    }
    std.mem.sort(u64, latencies_ns, {}, std.sort.asc(u64));
    const p50 = latencies_ns[latencies_ns.len / 2];
    const p99 = latencies_ns[latencies_ns.len * 99 / 100];
    const max = latencies_ns[latencies_ns.len - 1];
    assert(p50 <= p99 and p99 <= max);
    print("fsync: {d} writes of 4 KiB + fdatasync, p50 {d} us, p99 {d} us, max {d} us\n", .{
        iterations, p50 / 1000, p99 / 1000, max / 1000,
    });
}

/// The VFS calls of the run, per operation, in hundredths.
fn print_calls(before: sqlite.vfs.Calls, after: sqlite.vfs.Calls, iterations: u32) void {
    print("  VFS calls per 100 operations:", .{});
    inline for (@typeInfo(sqlite.vfs.Calls).@"struct".field_names) |field| {
        const count = @field(after, field) - @field(before, field);
        if (count > 0) print(" {s} {d}", .{ field, count * 100 / iterations });
    }
    print("\n", .{});
}

fn print(comptime format: []const u8, arguments: anytype) void {
    std.debug.print(format, arguments);
}

fn fatal(message: []const u8) noreturn {
    std.debug.print("sqlite-floor: {s}\n", .{message});
    std.process.exit(2);
}
