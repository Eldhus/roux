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
