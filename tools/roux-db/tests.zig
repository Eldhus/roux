//! roux-db's tests: every file's own, and the whole generator run on
//! inputs in memory: what it writes for a small database, and a named
//! case for every refusal (the negative space).

const std = @import("std");
const testing = std.testing;
const gen = @import("gen.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;

test {
    _ = @import("annotation.zig");
    _ = @import("compile.zig");
    _ = @import("diagnostics.zig");
    _ = @import("emit.zig");
    _ = @import("gen.zig");
    _ = @import("main.zig");
    _ = @import("names.zig");
    _ = @import("sqlite").types;
}

const schema_text =
    \\CREATE TABLE dish (
    \\  id INTEGER PRIMARY KEY,
    \\  name TEXT NOT NULL,
    \\  price_kr INTEGER NOT NULL,
    \\  note TEXT,
    \\  vegetarian INTEGER NOT NULL DEFAULT 0
    \\) STRICT;
    \\CREATE INDEX dish_by_name ON dish (name);
    \\CREATE TABLE tag (dish_id INTEGER NOT NULL REFERENCES dish (id), label TEXT NOT NULL,
    \\  PRIMARY KEY (dish_id, label)) STRICT, WITHOUT ROWID;
    \\
;

const Run = struct {
    arena: std.heap.ArenaAllocator,
    diagnostics: Diagnostics,
    outputs: []const gen.Output,

    fn deinit(run: *Run) void {
        run.arena.deinit();
    }

    fn output(run: *const Run, name: []const u8) []const u8 {
        for (run.outputs) |o| {
            if (std.mem.eql(u8, o.name, name)) return o.text;
        }
        unreachable;
    }

    /// Whether some diagnostic's message holds `text`.
    fn says(run: *const Run, text: []const u8) bool {
        for (run.diagnostics.items()) |diagnostic| {
            if (std.mem.indexOf(u8, diagnostic.message, text) != null) return true;
        }
        return false;
    }
};

fn run_generator(schema: []const u8, query_name: []const u8, query: []const u8) !*Run {
    const run = try testing.allocator.create(Run);
    run.arena = .init(testing.allocator);
    const arena = run.arena.allocator();
    run.diagnostics = .init(arena);
    const queries = [_]gen.Input{.{ .name = query_name, .text = query }};
    run.outputs = try gen.generate(
        arena,
        .{ .name = "schema.sql", .text = schema },
        &queries,
        &run.diagnostics,
    );
    return run;
}

fn free(run: *Run) void {
    run.deinit();
    testing.allocator.destroy(run);
}

fn run_directory(schema: []const u8, queries: []const gen.Input) !*Run {
    const run = try testing.allocator.create(Run);
    run.arena = .init(testing.allocator);
    run.diagnostics = .init(run.arena.allocator());
    run.outputs = try gen.generate(
        run.arena.allocator(),
        .{ .name = "schema.sql", .text = schema },
        queries,
        &run.diagnostics,
    );
    return run;
}

test "roux-db: testdata/ generates the Roc committed beside it" {
    // To update after a deliberate change: `zig build tools`, then
    // `zig-out/bin/roux-db gen tools/roux-db/testdata`, and read the diff.
    const queries = [_]gen.Input{
        .{ .name = "Dishes.sql", .text = @embedFile("testdata/Dishes.sql") },
        .{ .name = "Tags.sql", .text = @embedFile("testdata/Tags.sql") },
    };
    const run = try run_directory(@embedFile("testdata/schema.sql"), &queries);
    defer free(run);
    try testing.expect(run.diagnostics.ok());
    try testing.expectEqualStrings(@embedFile("testdata/Dishes.roc"), run.output("Dishes.roc"));
    try testing.expectEqualStrings(@embedFile("testdata/Tags.roc"), run.output("Tags.roc"));
    try testing.expectEqualStrings(@embedFile("testdata/Database.roc"), run.output("Database.roc"));
}

test "roux-db: only the rowid is never NULL; other columns as declared" {
    const run = try run_generator(
        \\CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER, m INTEGER NOT NULL) STRICT;
        \\CREATE TABLE u (id INT PRIMARY KEY, v TEXT) STRICT;
        \\CREATE TABLE w (a INTEGER, b INTEGER, PRIMARY KEY (a, b)) STRICT;
    , "Rows.sql",
        \\-- name: t :many(9)
        \\SELECT id, n, m FROM t;
        \\-- name: u :many(9)
        \\SELECT id, v FROM u;
        \\-- name: w :many(9)
        \\SELECT a, b FROM w;
    );
    defer free(run);
    try testing.expect(run.diagnostics.ok());
    const module = run.output("Rows.roc");
    const expected = [_][]const u8{
        "T : { id : I64, n : Sqlite.Nullable(I64), m : I64 }",
        // A STRICT table's key is NOT NULL, as SQLite reports it.
        "U : { id : I64, v : Sqlite.Nullable(Str) }",
        "W : { a : I64, b : I64 }",
    };
    for (expected) |line| {
        testing.expect(std.mem.indexOf(u8, module, line) != null) catch |err| {
            std.debug.print("missing: {s}\n{s}\n", .{ line, module });
            return err;
        };
    }
}

test "roux-db: whitespace before a statement is what SQLite skips, no more, no less" {
    // After a newline a vertical tab continues SQLite's run of spaces.
    const query = "-- name: q :exec\n\x0bDELETE FROM tag;";
    const run = try run_generator(schema_text, "Dishes.sql", query);
    defer free(run);
    try testing.expect(run.diagnostics.ok());
    const entry = "sql: \"DELETE FROM tag;\"";
    try testing.expect(std.mem.indexOf(u8, run.output("Database.roc"), entry) != null);
}

const Refusal = struct {
    /// What the case is about.
    case: []const u8,
    schema: []const u8 = schema_text,
    file: []const u8 = "Dishes.sql",
    query: []const u8 = "",
    /// Part of the message expected.
    says: []const u8,
};

const refusals = [_]Refusal{
    .{
        .case = "a vertical tab beginning a file (not a space to SQLite there)",
        .query = "\x0b-- name: q :exec\nDELETE FROM dish;",
        .says = "unrecognized token",
    },
    .{
        .case = "a table not STRICT",
        .schema = "CREATE TABLE t (id INTEGER PRIMARY KEY);",
        .says = "not STRICT",
    },
    .{
        .case = "a write in the schema",
        .schema = schema_text ++ "INSERT INTO dish (name, price_kr) VALUES ('x', 1);",
        .says = "a write to a table",
    },
    .{
        .case = "a PRAGMA in the schema",
        .schema = schema_text ++ "PRAGMA foreign_keys = ON;",
        .says = "a PRAGMA",
    },
    .{
        .case = "a TEMP table in the schema",
        .schema = schema_text ++ "CREATE TEMP TABLE x (a INTEGER) STRICT;",
        .says = "a TEMP object",
    },
    .{
        .case = "annotations in the schema",
        .schema = "-- name: x :one\n" ++ schema_text,
        .says = "annotations belong",
    },
    .{
        .case = "bad SQL in the schema",
        .schema = "CREATE TABLE (;",
        .says = "syntax error",
    },
    .{
        .case = "an unnamed query",
        .query = "SELECT 1 AS one;",
        .says = "is named",
    },
    .{
        .case = "a transaction",
        .query = "-- name: b :exec\nBEGIN;",
        .says = "a transaction",
    },
    .{
        .case = "a PRAGMA query",
        .query = "-- name: p :one\nPRAGMA foreign_keys;",
        .says = "a PRAGMA",
    },
    .{
        .case = "DDL in a query",
        .query = "-- name: c :exec\nCREATE TABLE x (a INTEGER) STRICT;",
        .says = "a change to the schema",
    },
    .{
        .case = "a DROP",
        .query = "-- name: d :exec\nDROP TABLE tag;",
        .says = "a DROP",
    },
    .{
        .case = "ATTACH",
        .query = "-- name: a :exec\nATTACH 'x.db' AS x;",
        .says = "ATTACH",
    },
    .{
        .case = "a positional parameter",
        .query = "-- name: q :one\nSELECT name FROM dish WHERE id = ?;",
        .says = "name it `:name`",
    },
    .{
        .case = "a $ parameter",
        .query = "-- name: q :one\n-- @param id : I64\nSELECT name FROM dish WHERE id = $id;",
        .says = "name it `:name`",
    },
    .{
        .case = "a parameter with no type",
        .query = "-- name: q :one\nSELECT name FROM dish WHERE id = :id;",
        .says = "has no `-- @param id",
    },
    .{
        .case = "a typed parameter not in the SQL",
        .query = "-- name: q :one\n-- @param id : I64\nSELECT name FROM dish;",
        .says = "the statement has no :id",
    },
    .{
        .case = "an expression column with no type",
        .query = "-- name: q :one\nSELECT count(*) AS n FROM dish;",
        .says = "an expression",
    },
    .{
        .case = "a typed column not in the result",
        .query = "-- name: q :one\n-- @column x : I64\nSELECT name FROM dish;",
        .says = "no column x",
    },
    .{
        .case = "an annotation against the table",
        .query = "-- name: q :one\n-- @column name : I64\nSELECT name FROM dish;",
        .says = "the column is text",
    },
    .{
        .case = ":exec returning rows",
        .query = "-- name: q :exec\nSELECT name FROM dish;",
        .says = "returns rows",
    },
    .{
        .case = ":one returning nothing",
        .query = "-- name: q :one\nDELETE FROM dish;",
        .says = "returns no rows",
    },
    .{
        .case = "two columns of one name",
        .query = "-- name: q :one\nSELECT name, name FROM dish;",
        .says = "two columns named name",
    },
    .{
        .case = "a column not snake_case",
        .query = "-- name: q :one\nSELECT name AS Name FROM dish;",
        .says = "snake_case",
    },
    .{
        .case = "a column named as a keyword",
        .query = "-- name: q :one\nSELECT name AS match FROM dish;",
        .says = "snake_case",
    },
    .{
        .case = "two queries of one name",
        .query = "-- name: q :exec\nDELETE FROM tag;\n-- name: q :exec\nDELETE FROM tag;",
        .says = "a second query named q",
    },
    .{
        .case = "an unknown table",
        .query = "-- name: q :one\nSELECT a FROM nowhere;",
        .says = "no such table",
    },
    .{
        .case = "a name with no statement",
        .query = "-- name: q :one\n",
        .says = "no statement after it",
    },
    .{
        .case = "a module named in lower case",
        .file = "dishes.sql",
        .query = "-- name: q :exec\nDELETE FROM tag;",
        .says = "PascalCase",
    },
    .{
        .case = "a module named Database",
        .file = "Database.sql",
        .query = "-- name: q :exec\nDELETE FROM tag;",
        .says = "PascalCase",
    },
    .{
        .case = "a column declared ANY",
        .schema = "CREATE TABLE t (id INTEGER PRIMARY KEY, v ANY) STRICT;",
        .query = "-- name: q :one\nSELECT v FROM t;",
        .says = "declared ANY",
    },
};

test "roux-db: every refusal, by name" {
    for (refusals) |refusal| {
        const any_query = "-- name: q :exec\nDELETE FROM dish;";
        const query = if (refusal.query.len > 0) refusal.query else any_query;
        const run = try run_generator(refusal.schema, refusal.file, query);
        defer free(run);
        if (!run.says(refusal.says)) {
            std.debug.print("case \"{s}\": expected \"{s}\", got:\n", .{
                refusal.case, refusal.says,
            });
            for (run.diagnostics.items()) |d| std.debug.print("  {s}\n", .{d.message});
            return error.TestUnexpectedResult;
        }
        try testing.expectEqual(0, run.outputs.len);
    }
}

const sqlite = @import("sqlite");
const compile = @import("compile.zig");

/// A query shape, and whether each result column can be NULL.
const Shape = struct { sql: []const u8, nullable: []const bool };

const join_schema =
    \\CREATE TABLE a (id INTEGER PRIMARY KEY, x TEXT NOT NULL) STRICT;
    \\CREATE TABLE b (id INTEGER PRIMARY KEY, a_id INTEGER NOT NULL, y TEXT NOT NULL) STRICT;
    \\CREATE VIEW ab AS SELECT a.id AS aid, b.y AS y FROM a LEFT JOIN b ON b.a_id = a.id;
    \\
;

/// Every shape meets a row with no partner: `a` 2 has no `b`, `b` 11
/// points at no `a`.
const join_data =
    \\INSERT INTO a (id, x) VALUES (1, 'one'), (2, 'two');
    \\INSERT INTO b (id, a_id, y) VALUES (10, 1, 'ten'), (11, 3, 'orphan');
;

const shapes = [_]Shape{
    .{ .sql = "SELECT a.x, b.y FROM a JOIN b ON b.a_id = a.id", .nullable = &.{ false, false } },
    .{
        .sql = "SELECT a.x, b.y FROM a LEFT JOIN b ON b.a_id = a.id",
        .nullable = &.{ false, true },
    },
    .{
        .sql = "SELECT a.x, b.y FROM a RIGHT JOIN b ON b.a_id = a.id",
        .nullable = &.{ true, false },
    },
    .{ .sql = "SELECT a.x, b.y FROM a FULL JOIN b ON b.a_id = a.id", .nullable = &.{ true, true } },
    .{
        .sql = "SELECT b.y, a.x FROM b LEFT JOIN a ON a.id = b.a_id",
        .nullable = &.{ false, true },
    },
    .{ .sql = "SELECT aid, y FROM ab", .nullable = &.{ false, true } },
    .{
        .sql = "SELECT s.y FROM a LEFT JOIN (SELECT a_id, y FROM b) AS s ON s.a_id = a.id",
        .nullable = &.{true},
    },
    .{ .sql = "SELECT (SELECT y FROM b WHERE b.a_id = a.id) AS y FROM a", .nullable = &.{true} },
    .{
        .sql = "WITH c AS (SELECT a.id, b.y FROM a LEFT JOIN b ON b.a_id = a.id) SELECT y FROM c",
        .nullable = &.{true},
    },
    .{ .sql = "SELECT x FROM a UNION ALL SELECT 'literal'", .nullable = &.{false} },
    .{ .sql = "SELECT x FROM a UNION ALL SELECT NULL", .nullable = &.{true} },
    .{ .sql = "SELECT y FROM b UNION SELECT y FROM ab", .nullable = &.{true} },
};

test "roux-db: nullability from SQLite's resolver, against the rows the shapes return" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var text: std.Io.Writer.Allocating = .init(arena);
    for (shapes, 0..) |shape, i| {
        try text.writer.print("-- name: q{d} :many(100)\n{s};\n", .{ i, shape.sql });
    }
    var diagnostics = Diagnostics.init(arena);
    const queries = [_]compile.Input{.{ .name = "Shapes.sql", .text = text.written() }};
    const schema: compile.Input = .{ .name = "schema.sql", .text = join_schema };
    const compiled = try compile.compile(arena, schema, &queries, &diagnostics);
    for (diagnostics.items()) |d| std.debug.print("{s}\n", .{d.message});
    try testing.expect(diagnostics.ok());
    try testing.expectEqual(shapes.len, compiled.statements.len);
    const db = try open_with_rows();
    defer _ = sqlite.c.sqlite3_close_v2(db);
    for (shapes, compiled.statements) |shape, statement| {
        for (shape.nullable, statement.columns) |expected, column| {
            testing.expectEqual(expected, column.type.nullable) catch |err| {
                std.debug.print("{s}: column {s}\n", .{ shape.sql, column.name });
                return err;
            };
        }
        try expect_nulls_where_typed(db, shape);
    }
}

fn open_with_rows() !*sqlite.c.Db {
    var db: ?*sqlite.c.Db = null;
    const c = sqlite.c;
    const flags = c.open_readwrite | c.open_create | c.open_memory | c.open_exrescode;
    if (c.sqlite3_open_v2(":memory:", &db, flags, null) != c.ok) return error.Sqlite;
    try sqlite.exec(db.?, join_schema ++ join_data);
    return db.?;
}

/// Runs the shape: a column typed never NULL is never NULL, and one typed
/// nullable is NULL in some row (the data exercises it).
fn expect_nulls_where_typed(db: *sqlite.c.Db, shape: Shape) !void {
    const c = sqlite.c;
    var statement: ?*c.Stmt = null;
    const length: c_int = @intCast(shape.sql.len);
    if (c.sqlite3_prepare_v3(db, shape.sql.ptr, length, 0, &statement, null) != c.ok) {
        return error.Sqlite;
    }
    defer _ = c.sqlite3_finalize(statement);
    var seen_null: [8]bool = @splat(false);
    for (0..100) |_| {
        const result = c.sqlite3_step(statement.?);
        if (result == c.done) break;
        try testing.expectEqual(c.row, result);
        for (shape.nullable, 0..) |nullable, column| {
            const is_null = c.sqlite3_column_type(statement.?, @intCast(column)) == c.null_type;
            if (is_null) seen_null[column] = true;
            if (is_null and !nullable) {
                std.debug.print("{s}: column {d} typed never NULL is NULL\n", .{
                    shape.sql, column,
                });
                return error.TestUnexpectedResult;
            }
        }
    } else unreachable;
    for (shape.nullable, seen_null[0..shape.nullable.len]) |nullable, seen| {
        if (nullable and !seen) {
            std.debug.print("{s}: typed nullable, never NULL in the data\n", .{shape.sql});
            return error.TestUnexpectedResult;
        }
    }
}
