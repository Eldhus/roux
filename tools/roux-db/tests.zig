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
