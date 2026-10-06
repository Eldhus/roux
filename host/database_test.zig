//! The host's database alone, without Roc: opening (the schema created,
//! compared, refused), statements as Database.roc describes them (and
//! misdescribes them), rows against their types, the bounds, the writer
//! and its lock. Files go to a temporary directory; the clock is the
//! testing `Io`'s, and the waits are a test's (`Limits`).

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const Io = std.Io;
const database_module = @import("database.zig");
const Database = database_module.Database;
const Description = database_module.Description;
const Report = database_module.Report;
const Value = database_module.Value;
const types = @import("sqlite").types;

const schema =
    \\CREATE TABLE dish (
    \\  id INTEGER PRIMARY KEY,
    \\  name TEXT NOT NULL UNIQUE,
    \\  price_kr INTEGER NOT NULL,
    \\  note TEXT,
    \\  vegetarian INTEGER NOT NULL DEFAULT 0
    \\) STRICT;
    \\
;

fn code(scalar: types.Scalar, nullable: bool) u8 {
    return (types.Type{ .scalar = scalar, .nullable = nullable }).code();
}

const i64_code = code(.i64, false);
const str_code = code(.str, false);
const str_null_code = code(.str, true);
const bool_code = code(.bool, false);

/// As roux-db would describe these statements.
const statements = [_]database_module.StatementDescription{
    .{
        .name = "Dishes.add",
        .sql = "INSERT INTO dish (name, price_kr, note) VALUES (:name, :price_kr, :note) " ++
            "RETURNING id;",
        .writes = true,
        .rows_max = 1,
        .params = &.{ str_code, i64_code, str_null_code },
        .columns = &.{i64_code},
    },
    .{
        .name = "Dishes.all",
        .sql = "SELECT id, name, note FROM dish ORDER BY id;",
        .writes = false,
        .rows_max = 3,
        .params = &.{},
        .columns = &.{ i64_code, str_code, str_null_code },
    },
    .{
        .name = "Dishes.veg",
        .sql = "SELECT vegetarian FROM dish WHERE id = :id;",
        .writes = false,
        .rows_max = 1,
        .params = &.{i64_code},
        .columns = &.{bool_code},
    },
    .{
        // Narrowed by annotation to never NULL: checked when read.
        .name = "Dishes.notes",
        .sql = "SELECT note FROM dish ORDER BY id;",
        .writes = false,
        .rows_max = 10,
        .params = &.{},
        .columns = &.{str_code},
    },
    .{
        .name = "Dishes.set_veg",
        .sql = "UPDATE dish SET vegetarian = :vegetarian WHERE id = :id;",
        .writes = true,
        .rows_max = 0,
        .params = &.{ i64_code, i64_code },
        .columns = &.{},
    },
    .{
        .name = "Dishes.slow",
        .sql = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) " ++
            "SELECT max(i) FROM n;",
        .writes = false,
        .rows_max = 1,
        .params = &.{},
        .columns = &.{i64_code},
    },
};

const add = 0;
const all = 1;
const veg = 2;
const notes = 3;
const set_veg = 4;
const slow = 5;

const limits: database_module.Limits = .{
    .statement_time_ms = 50,
    .write_wait_ms = 50,
    .writers_waiting = 4,
};

/// The cells a statement gave, row by row.
const Collected = struct {
    arena: std.mem.Allocator,
    rows: u32 = 0,
    cells: std.ArrayList(Value) = .empty,

    pub fn row(collected: *Collected) !void {
        collected.rows += 1;
    }

    pub fn cell(collected: *Collected, value: Value) !void {
        const kept: Value = switch (value) {
            .text => |text| .{ .text = try collected.arena.dupe(u8, text) },
            .blob => |bytes| .{ .blob = try collected.arena.dupe(u8, bytes) },
            else => value,
        };
        try collected.cells.append(collected.arena, kept);
    }
};

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    dir: testing.TmpDir,
    path: []const u8,

    fn init() !Fixture {
        var fixture: Fixture = .{
            .arena_state = .init(testing.allocator),
            .dir = testing.tmpDir(.{}),
            .path = undefined,
        };
        const arena = fixture.arena_state.allocator();
        const dir_path = try fixture.dir.dir.realPathFileAlloc(testing.io, ".", arena);
        fixture.path = try std.fs.path.join(arena, &.{ dir_path, "test.db" });
        return fixture;
    }

    fn deinit(fixture: *Fixture) void {
        fixture.dir.cleanup();
        fixture.arena_state.deinit();
    }

    fn open(
        fixture: *Fixture,
        with_schema: []const u8,
        with: []const database_module.StatementDescription,
        report: *Report,
    ) !*Database {
        const description: Description = .{
            .path = fixture.path,
            .schema = with_schema,
            .statements = with,
        };
        return database_module.open(fixture.arena_state.allocator(), description, limits, report);
    }
};

fn collect(fixture: *Fixture) Collected {
    return .{ .arena = fixture.arena_state.allocator() };
}

fn write_one(database: *Database, index: u32, params: []const Value, collected: *Collected) !void {
    var report: Report = .{};
    try database_module.begin_write(database, testing.io, &report);
    database_module.run(
        database,
        database.writer,
        index,
        params,
        testing.io,
        collected,
        &report,
    ) catch |err| {
        database_module.rollback_write(database, testing.io);
        return err;
    };
    try database_module.commit_write(database, testing.io, &report);
}

test "database: a new file gets the schema, and opens again as it is" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var report: Report = .{};
    const first = try fixture.open(schema, &statements, &report);
    var added = collect(&fixture);
    try write_one(first, add, &.{ .{ .text = "soup" }, .{ .integer = 95 }, .null }, &added);
    try testing.expectEqual(1, added.rows);
    database_module.close(fixture.arena_state.allocator(), first);
    const again = try fixture.open(schema, &statements, &report);
    defer database_module.close(fixture.arena_state.allocator(), again);
    var rows = collect(&fixture);
    try database_module.run(again, again.writer, all, &.{}, testing.io, &rows, &report);
    try testing.expectEqual(1, rows.rows);
    try testing.expectEqualStrings("soup", rows.cells.items[1].text);
    try testing.expectEqual(Value.null, rows.cells.items[2]);
}

test "database: a schema changed since the file was made does not open (no migrations yet)" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var report: Report = .{};
    const first = try fixture.open(schema, &statements, &report);
    database_module.close(fixture.arena_state.allocator(), first);
    const changed = schema ++ "CREATE INDEX dish_by_price ON dish (price_kr);\n";
    try testing.expectError(error.Failed, fixture.open(changed, &statements, &report));
    try testing.expect(std.mem.indexOf(u8, report.message(), "dish_by_price") != null);
    // A change of text alone is a change: SQLite keeps each CREATE as written.
    const respaced = try std.mem.replaceOwned(u8, testing.allocator, schema, "  name", "    name");
    defer testing.allocator.free(respaced);
    try testing.expectError(error.Failed, fixture.open(respaced, &statements, &report));
}

test "database: statements Database.roc misdescribes are refused at open" {
    const Case = struct {
        case: []const u8,
        statement: database_module.StatementDescription,
        says: []const u8,
    };
    const good = statements[all];
    var wrong_writes = good;
    wrong_writes.writes = true;
    var wrong_columns = good;
    wrong_columns.columns = &.{ i64_code, str_code };
    var wrong_params = good;
    wrong_params.params = &.{i64_code};
    var wrong_code = good;
    wrong_code.columns = &.{ i64_code, str_code, 0x47 };
    var pragma = good;
    pragma.sql = "PRAGMA foreign_keys;";
    var missing = good;
    missing.sql = "SELECT a FROM nowhere;";
    var exec_rows = good;
    exec_rows.rows_max = 0;
    const cases = [_]Case{
        .{ .case = "writes", .statement = wrong_writes, .says = "regenerate" },
        .{ .case = "columns", .statement = wrong_columns, .says = "regenerate" },
        .{ .case = "params", .statement = wrong_params, .says = "regenerate" },
        .{ .case = "a type code", .statement = wrong_code, .says = "type code 71" },
        .{ .case = "a PRAGMA", .statement = pragma, .says = "not authorized" },
        .{ .case = "an unknown table", .statement = missing, .says = "no such table" },
        .{ .case = "rows from an :exec", .statement = exec_rows, .says = "regenerate" },
    };
    for (cases) |case| {
        var fixture: Fixture = try .init();
        defer fixture.deinit();
        var report: Report = .{};
        const only = [_]database_module.StatementDescription{case.statement};
        try testing.expectError(error.Failed, fixture.open(schema, &only, &report));
        testing.expect(std.mem.indexOf(u8, report.message(), case.says) != null) catch |err| {
            std.debug.print("{s}: {s}\n", .{ case.case, report.message() });
            return err;
        };
    }
}

test "database: cells are checked against their types; bounds hold" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var report: Report = .{};
    const database = try fixture.open(schema, &statements, &report);
    defer database_module.close(fixture.arena_state.allocator(), database);
    var sink = collect(&fixture);
    for ([_][]const u8{ "a", "b", "c", "d" }) |name| {
        try write_one(database, add, &.{ .{ .text = name }, .{ .integer = 1 }, .null }, &sink);
    }
    // A column narrowed to never NULL, NULL in the data.
    try testing.expectError(error.Failed, database_module.run(
        database,
        database.writer,
        notes,
        &.{},
        testing.io,
        &sink,
        &report,
    ));
    try testing.expectEqual(database_module.Failure.invalid_value, report.failure);
    // :many(3) over four rows: an error, never a silent cut.
    try testing.expectError(error.Failed, database_module.run(
        database,
        database.writer,
        all,
        &.{},
        testing.io,
        &sink,
        &report,
    ));
    try testing.expectEqual(database_module.Failure.too_many_rows, report.failure);
    // A Bool column holding 2.
    try write_one(database, set_veg, &.{ .{ .integer = 2 }, .{ .integer = 1 } }, &sink);
    try testing.expectError(error.Failed, database_module.run(
        database,
        database.writer,
        veg,
        &.{.{ .integer = 1 }},
        testing.io,
        &sink,
        &report,
    ));
    try testing.expectEqual(database_module.Failure.invalid_value, report.failure);
    // A statement past its time.
    try testing.expectError(error.Failed, database_module.run(
        database,
        database.writer,
        slow,
        &.{},
        testing.io,
        &sink,
        &report,
    ));
    try testing.expectEqual(database_module.Failure.timed_out, report.failure);
}

test "database: a misused call is refused, not run" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var report: Report = .{};
    const database = try fixture.open(schema, &statements, &report);
    defer database_module.close(fixture.arena_state.allocator(), database);
    const reader = try database_module.open_reader(
        fixture.arena_state.allocator(),
        database,
        &report,
    );
    defer database_module.close_connection(fixture.arena_state.allocator(), reader);
    var sink = collect(&fixture);
    const io = testing.io;
    // A write on a reader, a statement that is not there, a wrong parameter.
    const add_params = [_]Value{ .{ .text = "x" }, .{ .integer = 1 }, .null };
    try testing.expectError(error.Failed, database_module.run(
        database,
        reader,
        add,
        &add_params,
        io,
        &sink,
        &report,
    ));
    try testing.expectEqual(database_module.Failure.misuse, report.failure);
    try testing.expectError(error.Failed, database_module.run(
        database,
        reader,
        99,
        &.{},
        io,
        &sink,
        &report,
    ));
    try testing.expectEqual(database_module.Failure.misuse, report.failure);
    try testing.expectError(error.Failed, database_module.run(
        database,
        reader,
        veg,
        &.{.{ .text = "1" }},
        io,
        &sink,
        &report,
    ));
    try testing.expectEqual(database_module.Failure.misuse, report.failure);
    try testing.expectEqual(0, sink.rows);
}

test "database: a constraint is a constraint; a rolled-back write is gone" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var report: Report = .{};
    const database = try fixture.open(schema, &statements, &report);
    defer database_module.close(fixture.arena_state.allocator(), database);
    var sink = collect(&fixture);
    const soup = [_]Value{ .{ .text = "soup" }, .{ .integer = 1 }, .null };
    try write_one(database, add, &soup, &sink);
    try testing.expectError(error.Failed, write_one(database, add, &soup, &sink));
    // write_one's own report is gone; run again to read the failure.
    try database_module.begin_write(database, testing.io, &report);
    try testing.expectError(error.Failed, database_module.run(
        database,
        database.writer,
        add,
        &soup,
        testing.io,
        &sink,
        &report,
    ));
    try testing.expectEqual(database_module.Failure.constraint, report.failure);
    const bread = [_]Value{ .{ .text = "bread" }, .{ .integer = 2 }, .null };
    try database_module.run(database, database.writer, add, &bread, testing.io, &sink, &report);
    database_module.rollback_write(database, testing.io);
    var rows = collect(&fixture);
    try database_module.run(database, database.writer, all, &.{}, testing.io, &rows, &report);
    try testing.expectEqual(1, rows.rows); // the soup; no bread
}

test "database: the writer is one request's; others wait their bounded time" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var report: Report = .{};
    const database = try fixture.open(schema, &statements, &report);
    defer database_module.close(fixture.arena_state.allocator(), database);
    try database_module.begin_write(database, testing.io, &report);
    // Held: another waits its 50 ms, then is busy.
    var waited: Report = .{};
    const start = Io.Timestamp.now(testing.io, .awake);
    try testing.expectError(error.Failed, database.lock.acquire(testing.io, limits, &waited));
    try testing.expectEqual(database_module.Failure.writer_busy, waited.failure);
    const waited_ms = start.durationTo(Io.Timestamp.now(testing.io, .awake)).toMilliseconds();
    try testing.expect(waited_ms >= limits.write_wait_ms);
    // The queue full: busy at once.
    database.lock.waiting.store(limits.writers_waiting, .monotonic);
    try testing.expectError(error.Failed, database.lock.acquire(testing.io, limits, &waited));
    database.lock.waiting.store(0, .monotonic);
    // Released by another thread while one waits: the waiter has it.
    const releaser = try std.Thread.spawn(.{}, release_soon, .{database});
    var long_wait = limits;
    long_wait.write_wait_ms = 5_000;
    try database.lock.acquire(testing.io, long_wait, &waited);
    releaser.join();
    database_module.rollback_write(database, testing.io);
    try testing.expectEqual(0, database.lock.state.load(.monotonic));
}

/// Commits the open transaction from another thread, after a moment.
fn release_soon(database: *Database) void {
    testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    var report: Report = .{};
    database_module.commit_write(database, testing.io, &report) catch unreachable;
}
