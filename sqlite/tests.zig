//! The tests of roux's SQLite build: that it is the build `options.zig`
//! says, and that it works. Run by `zig build test`, in Debug, with
//! SQLite's own assertions on (`SQLITE_DEBUG`).

const std = @import("std");
const assert = std.debug.assert;
const sqlite = @import("sqlite.zig");
const c = @import("c.zig");
const options = @import("options.zig");

test {
    _ = @import("authorizer.zig");
    _ = @import("types.zig");
    _ = @import("vfs.zig");
    _ = @import("mutex.zig");
}

test "sqlite: the linked SQLite is the vendored release" {
    try sqlite.initialize();
    const linked = std.mem.span(c.sqlite3_libversion());
    try std.testing.expectEqualStrings(options.version, linked);
}

test "sqlite: the build has every option options.zig names" {
    try sqlite.initialize();
    var checked: u32 = 0;
    for (options.options) |option| {
        const reported = option.reported orelse continue;
        if (c.sqlite3_compileoption_used(reported) != 1) {
            std.debug.print("not in the build: {s}\n", .{option.define});
            return error.TestUnexpectedResult;
        }
        checked += 1;
    }
    try std.testing.expect(checked > 0);
    // The negative space: SQLite does not answer yes to anything.
    try std.testing.expectEqual(0, c.sqlite3_compileoption_used("THREADSAFE=0"));
    try std.testing.expectEqual(0, c.sqlite3_compileoption_used("ENABLE_FTS5"));
    // These tests run with SQLite's own assertions (options.flags_debug).
    try std.testing.expectEqual(1, c.sqlite3_compileoption_used("DEBUG"));
}

test "sqlite: a STRICT table refuses a value of the wrong type" {
    try sqlite.initialize();
    const db = try open_memory();
    defer _ = c.sqlite3_close_v2(db);
    try sqlite.exec(db,
        \\CREATE TABLE dish (id INTEGER PRIMARY KEY, price_kr INTEGER NOT NULL) STRICT;
        \\INSERT INTO dish (price_kr) VALUES (95);
    );
    try std.testing.expectError(
        error.Sqlite,
        sqlite.exec(db, "INSERT INTO dish (price_kr) VALUES ('ninety-five');"),
    );
    try std.testing.expectEqual(1, try count_rows(db));
}

test "sqlite: double quotes are identifiers, never strings (DQS=0)" {
    try sqlite.initialize();
    const db = try open_memory();
    defer _ = c.sqlite3_close_v2(db);
    try sqlite.exec(db, "CREATE TABLE dish (id INTEGER PRIMARY KEY) STRICT;");
    try std.testing.expectError(error.Sqlite, sqlite.exec(db, "SELECT \"no_such\" FROM dish;"));
}

fn open_memory() !*c.Db {
    var db: ?*c.Db = null;
    const flags = c.open_readwrite | c.open_create | c.open_memory | c.open_exrescode;
    if (c.sqlite3_open_v2(":memory:", &db, flags, null) != c.ok) {
        _ = c.sqlite3_close_v2(db);
        return error.Sqlite;
    }
    return db.?;
}

fn count_rows(db: *c.Db) !i64 {
    var stmt: ?*c.Stmt = null;
    const sql = "SELECT count(*) FROM dish";
    if (c.sqlite3_prepare_v3(db, sql, sql.len, 0, &stmt, null) != c.ok) return error.Sqlite;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt.?) != c.row) return error.Sqlite;
    assert(c.sqlite3_column_count(stmt.?) == 1);
    return c.sqlite3_column_int64(stmt.?, 0);
}

// --- roux's VFS (vfs.zig) -----------------------------------------------------

const Io = std.Io;

fn open_file(path: [:0]const u8) !*c.Db {
    var db: ?*c.Db = null;
    const flags = c.open_readwrite | c.open_create | c.open_exrescode;
    if (c.sqlite3_open_v2(path, &db, flags, null) != c.ok) {
        _ = c.sqlite3_close_v2(db);
        return error.Sqlite;
    }
    return db.?;
}

fn temporary_path(dir: *testing_dir, buffer: []u8, file_name: []const u8) ![:0]const u8 {
    var dir_buffer: [512]u8 = undefined;
    const length = try dir.dir.realPath(std.testing.io, &dir_buffer);
    return std.fmt.bufPrintSentinel(buffer, "{s}/{s}", .{ dir_buffer[0..length], file_name }, 0);
}

const testing_dir = std.testing.TmpDir;

test "vfs: another process's lock on the database is refused" {
    try sqlite.initialize();
    sqlite.vfs.thread_io = std.testing.io;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var path_buffer: [512]u8 = undefined;
    const path = try temporary_path(&dir, &path_buffer, "owned.db");
    const db = try open_file(path);
    defer _ = c.sqlite3_close_v2(db);
    try sqlite.exec(db, "PRAGMA journal_mode = WAL; CREATE TABLE t (a INTEGER) STRICT;");
    // A process lock (fcntl, as SQLite's unix VFS takes one) on another
    // description of the file conflicts with the open file description
    // lock roux's VFS holds.
    const file = try Io.Dir.cwd().openFile(std.testing.io, path, .{ .mode = .read_write });
    defer file.close(std.testing.io);
    const Flock = extern struct { type: i16, whence: i16, start: i64, length: i64, pid: i32 };
    var shared: Flock = .{ .type = 0, .whence = 0, .start = 0, .length = 1, .pid = 0 }; // F_RDLCK
    const set_lock = 6; // F_SETLK
    const linux = std.os.linux;
    const result = linux.fcntl(file.handle, set_lock, @intFromPtr(&shared));
    try std.testing.expect(linux.errno(result) == .AGAIN or linux.errno(result) == .ACCES);
}

test "vfs: one writer at a time; a reader sees what was committed" {
    try sqlite.initialize();
    sqlite.vfs.thread_io = std.testing.io;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var path_buffer: [512]u8 = undefined;
    const path = try temporary_path(&dir, &path_buffer, "two.db");
    const writer = try open_file(path);
    defer _ = c.sqlite3_close_v2(writer);
    try sqlite.exec(writer, "PRAGMA journal_mode = WAL; CREATE TABLE t (a INTEGER) STRICT;");
    const other = try open_file(path);
    defer _ = c.sqlite3_close_v2(other);
    try sqlite.exec(writer, "BEGIN IMMEDIATE; INSERT INTO t VALUES (1);");
    // The writer is taken: a second is busy at once (no busy timeout).
    try std.testing.expectError(error.Sqlite, sqlite.exec(other, "BEGIN IMMEDIATE;"));
    try std.testing.expectEqual(0, try count(other));
    try sqlite.exec(writer, "COMMIT;");
    try std.testing.expectEqual(1, try count(other));
    try sqlite.exec(other, "BEGIN IMMEDIATE; INSERT INTO t VALUES (2); COMMIT;");
    try std.testing.expectEqual(2, try count(writer));
    try std.testing.expectEqual(0, sqlite.mutex.held);
}

test "vfs: a WAL left by a crash is recovered into a fresh index" {
    try sqlite.initialize();
    sqlite.vfs.thread_io = std.testing.io;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var path_buffer: [512]u8 = undefined;
    const path = try temporary_path(&dir, &path_buffer, "live.db");
    const db = try open_file(path);
    try sqlite.exec(db, "PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;" ++
        "CREATE TABLE t (a INTEGER) STRICT; INSERT INTO t VALUES (1), (2), (3);");
    // The files as a crash would leave them: the commits only in the WAL.
    const io = std.testing.io;
    try Io.Dir.copyFile(dir.dir, "live.db", dir.dir, "copy.db", io, .{});
    try Io.Dir.copyFile(dir.dir, "live.db-wal", dir.dir, "copy.db-wal", io, .{});
    _ = c.sqlite3_close_v2(db);
    var copy_buffer: [512]u8 = undefined;
    const copy_path = try temporary_path(&dir, &copy_buffer, "copy.db");
    const copy = try open_file(copy_path);
    defer _ = c.sqlite3_close_v2(copy);
    try std.testing.expectEqual(3, try count(copy));
}

fn count(db: *c.Db) !i64 {
    var stmt: ?*c.Stmt = null;
    const sql = "SELECT count(*) FROM t";
    if (c.sqlite3_prepare_v3(db, sql, sql.len, 0, &stmt, null) != c.ok) return error.Sqlite;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt.?) != c.row) return error.Sqlite;
    return c.sqlite3_column_int64(stmt.?, 0);
}

test "vfs: the database file's locks, as a rollback journal uses them" {
    try sqlite.initialize();
    sqlite.vfs.thread_io = std.testing.io;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var path_buffer: [512]u8 = undefined;
    const path = try temporary_path(&dir, &path_buffer, "journal.db");
    const a = try open_file(path);
    defer _ = c.sqlite3_close_v2(a);
    try sqlite.exec(a, "PRAGMA journal_mode = DELETE; CREATE TABLE t (a INTEGER) STRICT;");
    const b = try open_file(path);
    defer _ = c.sqlite3_close_v2(b);
    // RESERVED is one connection's.
    try sqlite.exec(a, "BEGIN IMMEDIATE;");
    try std.testing.expectError(error.Sqlite, sqlite.exec(b, "BEGIN IMMEDIATE;"));
    try std.testing.expectEqual(0, try count(b)); // SHARED beside RESERVED
    try sqlite.exec(a, "INSERT INTO t VALUES (1); COMMIT;");
    // EXCLUSIVE keeps every reader out.
    try sqlite.exec(a, "BEGIN EXCLUSIVE;");
    try std.testing.expectError(error.Sqlite, count(b));
    try sqlite.exec(a, "COMMIT;");
    try std.testing.expectEqual(1, try count(b));
    try std.testing.expectEqual(0, sqlite.mutex.held);
}

test "vfs: a connection closing leaves the WAL to the others" {
    try sqlite.initialize();
    sqlite.vfs.thread_io = std.testing.io;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var path_buffer: [512]u8 = undefined;
    const path = try temporary_path(&dir, &path_buffer, "wal.db");
    const stays = try open_file(path);
    defer _ = c.sqlite3_close_v2(stays);
    try sqlite.exec(stays, "PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;" ++
        "CREATE TABLE t (a INTEGER) STRICT; INSERT INTO t VALUES (1);");
    const leaves = try open_file(path);
    try sqlite.exec(leaves, "INSERT INTO t VALUES (2);");
    // Not the last: it may not take EXCLUSIVE to checkpoint and delete the WAL.
    _ = c.sqlite3_close_v2(leaves);
    var wal_buffer: [512]u8 = undefined;
    const wal = try temporary_path(&dir, &wal_buffer, "wal.db-wal");
    try Io.Dir.cwd().access(std.testing.io, wal, .{});
    try std.testing.expectEqual(2, try count(stays));
}

test "sqlite: roux's mutexes are SQLite's, and count what a thread holds" {
    try sqlite.initialize();
    sqlite.vfs.thread_io = std.testing.io;
    const db = try open_memory();
    defer _ = c.sqlite3_close_v2(db);
    // sqlite3_randomness takes SQLite's PRNG mutex: held while it runs,
    // given back after (SQLite's default here would be a no-op).
    var bytes: [16]u8 = undefined;
    c.sqlite3_randomness(bytes.len, &bytes);
    try std.testing.expectEqual(0, sqlite.mutex.held);
}
