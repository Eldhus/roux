//! The compiler: `schema.sql` into an in-memory SQLite, then every query
//! file's statements prepared against it, each checked and typed by what
//! SQLite reports of it. Nothing here reads SQL to understand it:
//!
//! - statements are split where `sqlite3_prepare_v3` says one ends;
//! - what a statement does comes from SQLite's authorizer (authorizer.zig);
//! - whether it writes from `sqlite3_stmt_readonly`;
//! - its parameters from `sqlite3_bind_parameter_name`;
//! - its result columns from their origin column's declaration in a
//!   STRICT table (column metadata), and whether each can be NULL from our
//!   patch to SQLite (`sqlite3_column_nullable`);
//! - what SQLite cannot say (a parameter's type, an expression's) comes
//!   from the annotations, and an annotation SQLite contradicts is an error.
//!
//! `ledger.sql` is split into its steps, each where `sqlite3_complete` says
//! a statement ends: a step names tables as the database was when it first
//! ran, which schema.sql no longer makes, so it is not prepared here. What
//! a step does is checked as it runs, on a database (the host's policy).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const c = sqlite.c;
const authorizer = sqlite.authorizer;
const types = sqlite.types;
const annotation = @import("annotation.zig");
const names = @import("names.zig");
pub const Diagnostics = @import("diagnostics.zig").Diagnostics;

/// Query files in one database directory.
pub const files_max = 64;
/// Statements across every query file: the host prepares each on every
/// connection, so this bounds its startup too.
pub const statements_max = 1024;
/// The largest `.sql` file.
pub const file_bytes_max = 1 << 20;
/// Statements in one file, including empty ones.
const file_statements_max = 4096;

pub const Field = annotation.Field;

pub const Statement = struct {
    /// The query file's index in the run (0 is schema.sql).
    file: u16,
    name: []const u8,
    /// Where `-- name:` is, and where the SQL begins, in the file.
    name_offset: u32,
    sql_offset: u32,
    sql: []const u8,
    kind: annotation.Kind,
    rows_max: u32,
    writes: bool,
    /// In SQLite's order: the value list binds parameter i + 1 from item i.
    params: []const Field,
    columns: []const Field,
};

pub const Input = struct {
    /// The file's name: `schema.sql`, `ledger.sql`, or `Module.sql`.
    name: []const u8,
    text: []const u8,
};

pub const Compiled = struct {
    /// Every statement, by file in the order given, then by position.
    statements: []const Statement,
    /// ledger.sql's steps, in its order, each a statement as written.
    ledger: []const []const u8 = &.{},
};

/// What diagnostics call ledger.sql: past every query file.
pub const ledger_file: u16 = files_max + 1;

/// Steps in ledger.sql.
pub const ledger_steps_max = 4096;

const Compiler = struct {
    arena: Allocator,
    db: *c.Db,
    diagnostics: *Diagnostics,
    verdict: authorizer.Verdict,
    statements: std.ArrayList(Statement),
    views: std.ArrayList(Made),
    triggers: std.ArrayList(Made),
    tables: std.ArrayList(Made),
};

/// A table, view or trigger of schema.sql, and where its CREATE begins.
const Made = struct { name: []const u8, offset: u32 };

/// Compiles `queries` against `schema`, and splits `ledger` (empty when
/// there is no ledger.sql); what is wrong goes to `diagnostics`, and the
/// result means something only when it is ok.
pub fn compile(
    arena: Allocator,
    schema: Input,
    ledger: Input,
    queries: []const Input,
    diagnostics: *Diagnostics,
) !Compiled {
    assert(queries.len <= files_max);
    try sqlite.initialize();
    const db = try open_memory();
    defer _ = c.sqlite3_close_v2(db);
    var compiler: Compiler = .{
        .arena = arena,
        .db = db,
        .diagnostics = diagnostics,
        .verdict = .{ .policy = .schema },
        .statements = try .initCapacity(arena, statements_max),
        .views = try .initCapacity(arena, file_statements_max),
        .triggers = try .initCapacity(arena, file_statements_max),
        .tables = try .initCapacity(arena, file_statements_max),
    };
    const steps = try split_ledger(&compiler, ledger.text);
    load_schema(&compiler, schema.text);
    if (!diagnostics.ok()) return .{ .statements = &.{} };
    try check_views(&compiler);
    try check_probed(&compiler, schema.text);
    compiler.verdict = .{ .policy = .query };
    for (queries, 1..) |query, file| {
        compile_file(&compiler, @intCast(file), query);
    }
    return .{ .statements = compiler.statements.items, .ledger = steps };
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

/// roux-db's own statements, outside any policy.
fn prepare_own(db: *c.Db, sql: []const u8) !*c.Stmt {
    authorizer.uninstall(db);
    var statement: ?*c.Stmt = null;
    const result = c.sqlite3_prepare_v3(db, sql.ptr, @intCast(sql.len), 0, &statement, null);
    assert(result == c.ok); // ours, fixed
    return statement.?;
}

/// One statement of a file, prepared: `statement` null when the rest of
/// the file is only whitespace, comments and `;`.
const Next = struct {
    statement: ?*c.Stmt,
    /// The statement's first byte, and the byte after its end.
    start: u32,
    end: u32,
};

/// Prepares the next statement of `text` from `at.*`, with the
/// annotations before it in `annotations`; null when `text` ends or the
/// statement does not prepare (a diagnostic says why).
fn next_statement(
    compiler: *Compiler,
    file: u16,
    text: []const u8,
    at: *u32,
    annotations: *annotation.Annotations,
) ?Next {
    if (at.* == text.len) return null;
    compiler.verdict.reset();
    authorizer.install(compiler.db, &compiler.verdict);
    var statement: ?*c.Stmt = null;
    var tail: [*]const u8 = text.ptr + at.*;
    const rest = text[at.*..];
    const length: c_int = @intCast(rest.len);
    const prepared = c.sqlite3_prepare_v3(compiler.db, rest.ptr, length, 0, &statement, &tail);
    // The verdict is the prepare's; what runs after is roux-db's own (a
    // lookup in pragma_table_xinfo runs a PRAGMA inside SQLite).
    authorizer.uninstall(compiler.db);
    if (prepared != c.ok) {
        report_prepare_error(compiler, file, at.*);
        return null;
    }
    const end: u32 = @intCast(@intFromPtr(tail) - @intFromPtr(text.ptr));
    assert(end > at.* and end <= text.len);
    const sink: annotation.Sink = .{
        .annotations = annotations,
        .diagnostics = compiler.diagnostics,
        .file = file,
    };
    const start = annotation.scan(text, at.*, end, sink);
    // SQLite and the scan agree on where the statement begins: what the
    // scan passed over prepares to nothing, and what follows is one whole
    // statement, as the host will prepare it.
    assert(prepares_to_nothing(compiler.db, text[at.*..start]));
    if (statement != null) assert(prepares_whole(compiler.db, text[start..end]));
    assert((statement == null) == (start == end));
    at.* = end;
    return .{ .statement = statement, .start = start, .end = end };
}

fn report_prepare_error(compiler: *Compiler, file: u16, at: u32) void {
    const offset = c.sqlite3_error_offset(compiler.db);
    const where = at + if (offset >= 0) @as(u32, @intCast(offset)) else 0;
    if (compiler.verdict.refused) |action| {
        compiler.diagnostics.add(file, where, "{s} may not hold {s}", .{
            if (compiler.verdict.policy == .schema) "schema.sql" else "a query",
            authorizer.describe(action),
        });
    } else {
        compiler.diagnostics.add(file, where, "{s}", .{c.sqlite3_errmsg(compiler.db)});
    }
}

/// Whether `text` holds no statement, by SQLite's own reading.
fn prepares_to_nothing(db: *c.Db, text: []const u8) bool {
    var rest = text;
    for (0..text.len + 1) |_| {
        if (rest.len == 0) return true;
        var statement: ?*c.Stmt = null;
        var tail: [*]const u8 = rest.ptr;
        const result = c.sqlite3_prepare_v3(db, rest.ptr, @intCast(rest.len), 0, &statement, &tail);
        if (result != c.ok) return false;
        if (statement != null) {
            _ = c.sqlite3_finalize(statement);
            return false;
        }
        const consumed = @intFromPtr(tail) - @intFromPtr(rest.ptr);
        if (consumed == 0) return false;
        rest = rest[consumed..];
    } else unreachable;
}

/// Whether `text` prepares to one statement that is all of it.
fn prepares_whole(db: *c.Db, text: []const u8) bool {
    var statement: ?*c.Stmt = null;
    var tail: [*]const u8 = text.ptr;
    const result = c.sqlite3_prepare_v3(db, text.ptr, @intCast(text.len), 0, &statement, &tail);
    defer _ = c.sqlite3_finalize(statement);
    return result == c.ok and statement != null and tail == text.ptr + text.len;
}

// --- schema.sql -------------------------------------------------------------

fn load_schema(compiler: *Compiler, text: []const u8) void {
    assert(compiler.verdict.policy == .schema);
    var at: u32 = 0;
    for (0..file_statements_max) |_| {
        var annotations: annotation.Annotations = .{};
        const next = next_statement(compiler, 0, text, &at, &annotations) orelse return;
        if (annotations.name != null or annotations.params_count + annotations.columns_count > 0) {
            compiler.diagnostics.add(0, next.start, "annotations belong to query files, " ++
                "not schema.sql", .{});
        }
        const statement = next.statement orelse continue;
        defer _ = c.sqlite3_finalize(statement);
        load_schema_statement(compiler, statement, next.start);
    } else {
        compiler.diagnostics.add(0, at, "more than {d} statements", .{file_statements_max});
    }
}

// --- ledger.sql -------------------------------------------------------------

/// The steps of `text`: each statement from its first byte to its `;`,
/// the comments between them left out (they are prose, free to change).
/// A step ends at the first `;` where `sqlite3_complete` says the text
/// since the last one ends a statement: a `;` in a string, a comment or a
/// trigger's body does not.
fn split_ledger(compiler: *Compiler, text: []const u8) ![]const []const u8 {
    const file = ledger_file;
    const arena = compiler.arena;
    var steps: std.ArrayList([]const u8) = .empty;
    var at: u32 = 0;
    for (0..ledger_steps_max + 1) |_| {
        var annotations: annotation.Annotations = .{};
        const sink: annotation.Sink = .{
            .annotations = &annotations,
            .diagnostics = compiler.diagnostics,
            .file = file,
        };
        const start = annotation.scan(text, at, @intCast(text.len), sink);
        if (annotations.name != null or annotations.params_count + annotations.columns_count > 0) {
            compiler.diagnostics.add(file, at, "annotations belong to query files, " ++
                "not ledger.sql", .{});
        }
        assert(prepares_to_nothing(compiler.db, text[at..start]));
        if (start == text.len) return steps.items;
        const end = try statement_end(arena, text, start) orelse {
            compiler.diagnostics.add(file, start, "a step with no `;` after it: each step " ++
                "of ledger.sql is one statement, ended by `;`", .{});
            return steps.items;
        };
        if (steps.items.len == ledger_steps_max) break;
        try steps.append(arena, text[start..end]);
        at = end;
    }
    compiler.diagnostics.add(file, at, "more than {d} steps", .{ledger_steps_max});
    return steps.items;
}

/// The byte after the `;` that ends the statement at `start`, or null if
/// none does.
fn statement_end(arena: Allocator, text: []const u8, start: u32) !?u32 {
    const rest = try arena.dupeSentinel(u8, text[start..], 0);
    var at: usize = 0;
    for (0..rest.len + 1) |_| {
        const semicolon = std.mem.indexOfScalarPos(u8, rest, at, ';') orelse return null;
        // SQLite reads the text up to here as a C string: cut it there.
        const after = semicolon + 1;
        const saved = if (after < rest.len) rest[after] else 0;
        if (after < rest.len) rest[after] = 0;
        const complete = c.sqlite3_complete(rest.ptr) == 1;
        if (after < rest.len) rest[after] = saved;
        if (complete) return start + @as(u32, @intCast(semicolon + 1));
        at = semicolon + 1;
    } else unreachable;
}

/// Runs one statement of schema.sql: it must create something (the
/// first create named is the statement's own; a key of a WITHOUT ROWID
/// table adds its index), and a table must be STRICT, so its declared
/// types say what it holds.
fn load_schema_statement(compiler: *Compiler, statement: *c.Stmt, start: u32) void {
    const verdict = &compiler.verdict;
    if (verdict.creates == 0) {
        compiler.diagnostics.add(0, start, "a statement of schema.sql creates a table, " ++
            "an index, a view or a trigger", .{});
        return;
    }
    if (c.sqlite3_step(statement) != c.done) {
        compiler.diagnostics.add(0, start, "{s}", .{c.sqlite3_errmsg(compiler.db)});
        return;
    }
    const created = verdict.created.?;
    // A name at the verdict's bound may have been cut: never read.
    const name = verdict.created_name();
    if (name.len >= authorizer.Verdict.created_bytes_max) {
        const bound = authorizer.Verdict.created_bytes_max;
        return compiler.diagnostics.add(0, start, "a name of {d} bytes or more", .{bound});
    }
    if (name.len >= 5 and std.ascii.eqlIgnoreCase(name[0..5], "roux_")) {
        return compiler.diagnostics.add(0, start, "{s}: names starting `roux_` are roux's " ++
            "(its ledger, and a table set aside while it is rebuilt)", .{name});
    }
    const list = switch (created) {
        .create_view => &compiler.views,
        .create_trigger => &compiler.triggers,
        .create_table => &compiler.tables,
        else => return,
    };
    const kept = compiler.arena.dupe(u8, name) catch
        return compiler.diagnostics.add(0, start, "out of memory", .{});
    list.appendAssumeCapacity(.{ .name = kept, .offset = start });
    if (created != .create_table) return;
    const table = kept;
    if (!is_strict(compiler.db, table)) {
        compiler.diagnostics.add(0, start, "table {s} is not STRICT: roux types a column by " ++
            "its declared type, which only a STRICT table enforces", .{table});
    }
}

/// Each view read once schema.sql is whole: SQLite makes a view that names
/// a table or column not there (one dropped, say), and fails only
/// where it is read, at a request.
fn check_views(compiler: *Compiler) !void {
    for (compiler.views.items) |view| {
        const quoted = try std.mem.replaceOwned(u8, compiler.arena, view.name, "\"", "\"\"");
        const sql = try std.fmt.allocPrint(compiler.arena, "SELECT * FROM \"{s}\"", .{quoted});
        authorizer.uninstall(compiler.db);
        var statement: ?*c.Stmt = null;
        const result = c.sqlite3_prepare_v3(
            compiler.db,
            sql.ptr,
            @intCast(sql.len),
            0,
            &statement,
            null,
        );
        defer _ = c.sqlite3_finalize(statement);
        if (result != c.ok) {
            compiler.diagnostics.add(0, view.offset, "view {s}: {s}", .{
                view.name, c.sqlite3_errmsg(compiler.db),
            });
        }
    }
}

/// Each trigger compiled once schema.sql is whole. SQLite makes a trigger
/// whose body names a table or column not there, and fails only at the
/// write that fires it; preparing that write compiles the body, and
/// nothing runs. In a database of its own, one trigger at a time: its
/// siblings on the same table dropped, so a failure is its own, and a view
/// given a do-nothing INSTEAD OF trigger for each write, so each prepares.
/// (A trigger the body's writes fire is compiled too: a broken one is also
/// told under each trigger that fires it.)
///
/// Then each table's REFERENCES, the same way: SQLite makes a table whose
/// foreign key names a table or column not there (one renamed), or a parent
/// column that is not unique, and fails only at the write; preparing an
/// insert with foreign keys on says it, the triggers dropped first.
fn check_probed(compiler: *Compiler, schema: []const u8) !void {
    const probe = try open_memory();
    defer _ = c.sqlite3_close_v2(probe);
    // It loaded once already, under the schema policy.
    sqlite.exec(probe, schema) catch return error.Sqlite;
    for (compiler.triggers.items) |trigger| {
        try sqlite.exec(probe, "SAVEPOINT probe");
        const checked = check_trigger(compiler, probe, trigger);
        try sqlite.exec(probe, "ROLLBACK TO probe; RELEASE probe");
        try checked;
    }
    for (compiler.triggers.items) |trigger| {
        try sqlite.exec(probe, try std.fmt.allocPrint(compiler.arena, "DROP TRIGGER {s}", .{
            try sql_identifier(compiler.arena, trigger.name),
        }));
    }
    try sqlite.exec(probe, "PRAGMA foreign_keys = ON");
    for (compiler.tables.items) |table| try check_references(compiler, probe, table);
}

fn check_references(compiler: *Compiler, probe: *c.Db, table: Made) !void {
    const arena = compiler.arena;
    const keys = try first_rows(arena, probe, try std.fmt.allocPrint(arena, "SELECT count(*) " ++
        "FROM pragma_foreign_key_list({s})", .{try sql_literal(arena, table.name)}), 1);
    if (std.mem.eql(u8, keys[0], "0")) return;
    const write = try std.fmt.allocPrint(arena, "INSERT INTO {s} DEFAULT VALUES", .{
        try sql_identifier(arena, table.name),
    });
    var statement: ?*c.Stmt = null;
    const length: c_int = @intCast(write.len);
    const result = c.sqlite3_prepare_v3(probe, write.ptr, length, 0, &statement, null);
    _ = c.sqlite3_finalize(statement);
    if (result == c.ok) return;
    compiler.diagnostics.add(0, table.offset, "table {s}'s REFERENCES: {s}", .{
        table.name, c.sqlite3_errmsg(probe),
    });
}

fn check_trigger(compiler: *Compiler, probe: *c.Db, trigger: Made) !void {
    const arena = compiler.arena;
    const name = try sql_literal(arena, trigger.name);
    const on = try first_rows(arena, probe, try std.fmt.allocPrint(arena, "SELECT o.name, " ++
        "o.type FROM sqlite_schema AS t JOIN sqlite_schema AS o ON o.name = t.tbl_name " ++
        "WHERE t.type = 'trigger' AND t.name = {s} AND o.type IN ('table', 'view')", .{name}), 2);
    assert(on.len == 2); // the trigger's table or view, and which
    const target = try sql_identifier(arena, on[0]);
    const siblings = try first_rows(arena, probe, try std.fmt.allocPrint(arena, "SELECT name " ++
        "FROM sqlite_schema WHERE type = 'trigger' AND tbl_name = {s} AND name != {s}", .{
        try sql_literal(arena, on[0]), name,
    }), 1);
    for (siblings) |sibling| {
        try sqlite.exec(probe, try std.fmt.allocPrint(arena, "DROP TRIGGER {s}", .{
            try sql_identifier(arena, sibling),
        }));
    }
    const events = [_][]const u8{ "INSERT", "UPDATE", "DELETE" };
    if (std.mem.eql(u8, on[1], "view")) {
        for (events) |event| {
            const probe_trigger = try std.fmt.allocPrint(arena, "CREATE TRIGGER " ++
                "\"roux probe {s}\" INSTEAD OF {s} ON {s} BEGIN SELECT 1; END", .{
                event, event, target,
            });
            sqlite.exec(probe, probe_trigger) catch {
                return compiler.diagnostics.add(0, trigger.offset, "trigger {s}: names " ++
                    "starting `roux probe` are roux-db's, for checking a view's triggers", .{
                    trigger.name,
                });
            };
        }
    }
    // A view SQLite cannot read was told already (check_views).
    const columns = first_rows(arena, probe, try std.fmt.allocPrint(arena, "SELECT name " ++
        "FROM pragma_table_xinfo({s}) WHERE hidden = 0", .{try sql_literal(arena, on[0])}), 1) catch
        return;
    var set: std.Io.Writer.Allocating = .init(arena);
    for (columns, 0..) |column, index| {
        const quoted = try sql_identifier(arena, column);
        try set.writer.print("{s}{s} = {s}", .{ if (index == 0) "" else ", ", quoted, quoted });
    }
    const writes = [_][]const u8{
        try std.fmt.allocPrint(arena, "INSERT INTO {s} DEFAULT VALUES", .{target}),
        try std.fmt.allocPrint(arena, "UPDATE {s} SET {s}", .{ target, set.written() }),
        try std.fmt.allocPrint(arena, "DELETE FROM {s}", .{target}),
    };
    const fired_by = [_][]const u8{ "an INSERT", "an UPDATE", "a DELETE" };
    for (writes, fired_by) |write, event| {
        var statement: ?*c.Stmt = null;
        const length: c_int = @intCast(write.len);
        const result = c.sqlite3_prepare_v3(probe, write.ptr, length, 0, &statement, null);
        _ = c.sqlite3_finalize(statement);
        if (result == c.ok) continue;
        compiler.diagnostics.add(0, trigger.offset, "trigger {s}: {s} (where {s} on {s} " ++
            "fires it)", .{ trigger.name, c.sqlite3_errmsg(probe), event, on[0] });
        return;
    }
}

/// The first `columns` cells of each row, as text, in one list.
fn first_rows(arena: Allocator, db: *c.Db, sql: []const u8, columns: u32) ![]const []const u8 {
    const statement = try prepare_own(db, sql);
    defer _ = c.sqlite3_finalize(statement);
    var cells: std.ArrayList([]const u8) = .empty;
    for (0..file_statements_max + 1) |_| {
        switch (c.sqlite3_step(statement)) {
            c.done => return cells.items,
            c.row => {},
            else => return error.Sqlite,
        }
        for (0..columns) |column| {
            const text = c.sqlite3_column_text(statement, @intCast(column)) orelse "";
            const length: usize = @intCast(c.sqlite3_column_bytes(statement, @intCast(column)));
            try cells.append(arena, try arena.dupe(u8, text[0..length]));
        }
    }
    return error.Sqlite; // more rows than schema.sql has statements
}

fn sql_identifier(arena: Allocator, name: []const u8) ![]const u8 {
    const doubled = try std.mem.replaceOwned(u8, arena, name, "\"", "\"\"");
    return std.fmt.allocPrint(arena, "\"{s}\"", .{doubled});
}

fn sql_literal(arena: Allocator, text: []const u8) ![]const u8 {
    const doubled = try std.mem.replaceOwned(u8, arena, text, "'", "''");
    return std.fmt.allocPrint(arena, "'{s}'", .{doubled});
}

fn is_strict(db: *c.Db, table: []const u8) bool {
    const lookup = prepare_own(db,
        \\SELECT strict FROM pragma_table_list WHERE schema = 'main' AND name = ?1
    ) catch unreachable;
    defer _ = c.sqlite3_finalize(lookup);
    assert(c.sqlite3_bind_text64(lookup, 1, table.ptr, table.len, null, c.utf8) == c.ok);
    // The table was created a moment ago: it is listed.
    assert(c.sqlite3_step(lookup) == c.row);
    return c.sqlite3_column_int64(lookup, 0) == 1;
}

// --- query files ------------------------------------------------------------

fn compile_file(compiler: *Compiler, file: u16, input: Input) void {
    assert(compiler.verdict.policy == .query);
    const module = input.name[0 .. input.name.len - ".sql".len];
    if (!names.is_pascal(module) or std.mem.eql(u8, module, "Database")) {
        compiler.diagnostics.add(file, 0, "{s}: a query file is named as a Roc module, " ++
            "PascalCase (and not Database, which roux-db writes)", .{input.name});
        return;
    }
    var at: u32 = 0;
    const first = compiler.statements.items.len;
    for (0..file_statements_max) |_| {
        var annotations: annotation.Annotations = .{};
        const next = next_statement(compiler, file, input.text, &at, &annotations) orelse break;
        const statement = next.statement orelse {
            if (annotations.name != null) {
                compiler.diagnostics.add(file, annotations.name_offset, "`-- name:` with " ++
                    "no statement after it", .{});
            }
            continue;
        };
        defer _ = c.sqlite3_finalize(statement);
        compile_statement(compiler, file, input.text, next, &annotations);
    } else {
        compiler.diagnostics.add(file, at, "more than {d} statements", .{file_statements_max});
    }
    check_unique_names(compiler, file, compiler.statements.items[first..]);
}

fn check_unique_names(compiler: *Compiler, file: u16, statements: []const Statement) void {
    for (statements, 0..) |statement, i| {
        for (statements[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.name, statement.name)) {
                compiler.diagnostics.add(file, statement.name_offset, "a second query " ++
                    "named {s}", .{statement.name});
            }
        }
    }
}

fn compile_statement(
    compiler: *Compiler,
    file: u16,
    text: []const u8,
    next: Next,
    annotations: *const annotation.Annotations,
) void {
    const statement = next.statement.?;
    const verdict = &compiler.verdict;
    const name = annotations.name orelse {
        compiler.diagnostics.add(file, next.start, "every statement of a query file is " ++
            "named: `-- name: query_name :one` before it", .{});
        return;
    };
    if (verdict.data == 0) {
        compiler.diagnostics.add(file, next.start, "a query reads or writes rows", .{});
        return;
    }
    if (!check_kind(compiler, file, statement, annotations)) return;
    const params = compile_params(compiler, file, statement, annotations) orelse return;
    const columns = compile_columns(compiler, file, statement, annotations) orelse return;
    if (compiler.statements.items.len == statements_max) {
        compiler.diagnostics.add(file, next.start, "more than {d} statements", .{statements_max});
        return;
    }
    compiler.statements.appendAssumeCapacity(.{
        .file = file,
        .name = name,
        .name_offset = annotations.name_offset,
        .sql_offset = next.start,
        .sql = text[next.start..next.end],
        .kind = annotations.kind,
        .rows_max = annotations.rows_max,
        .writes = c.sqlite3_stmt_readonly(statement) == 0,
        .params = params,
        .columns = columns,
    });
}

fn check_kind(
    compiler: *Compiler,
    file: u16,
    statement: *c.Stmt,
    annotations: *const annotation.Annotations,
) bool {
    const returns_rows = c.sqlite3_column_count(statement) > 0;
    const offset = annotations.name_offset;
    if (annotations.kind == .exec and returns_rows) {
        compiler.diagnostics.add(file, offset, "{s} returns rows: `:one` or `:many(N)`, " ++
            "not `:exec`", .{annotations.name.?});
        return false;
    }
    if (annotations.kind != .exec and !returns_rows) {
        compiler.diagnostics.add(file, offset, "{s} returns no rows: `:exec`", .{
            annotations.name.?,
        });
        return false;
    }
    return true;
}

/// The parameters in SQLite's order, each typed by its annotation.
fn compile_params(
    compiler: *Compiler,
    file: u16,
    statement: *c.Stmt,
    annotations: *const annotation.Annotations,
) ?[]const Field {
    const count: u32 = @intCast(c.sqlite3_bind_parameter_count(statement));
    const offset = annotations.name_offset;
    if (count > annotation.fields_max) {
        compiler.diagnostics.add(file, offset, "more than {d} parameters", .{
            annotation.fields_max,
        });
        return null;
    }
    const params = compiler.arena.alloc(Field, count) catch return null;
    var ok = true;
    for (params, 1..) |*param, index| {
        const spelled = parameter_name(statement, @intCast(index));
        if (spelled[0] != ':') {
            compiler.diagnostics.add(file, offset, "parameter {s}: name it `:name` (roux binds " ++
                "by name, one style)", .{spelled});
            ok = false;
            continue;
        }
        param.* = find(annotations.param_list(), spelled[1..]) orelse {
            compiler.diagnostics.add(file, offset, "{s} has no `-- @param {s} : Type`: SQLite " ++
                "cannot say a parameter's type", .{ annotations.name.?, spelled[1..] });
            ok = false;
            continue;
        };
    }
    for (annotations.param_list()) |declared| {
        if (!has_parameter(statement, declared.name)) {
            compiler.diagnostics.add(file, declared.offset, "@param {s}: the statement has " ++
                "no :{s}", .{ declared.name, declared.name });
            ok = false;
        }
    }
    return if (ok) params else null;
}

/// As the SQL spells it (`:id`); `?` for one with no name.
fn parameter_name(statement: *c.Stmt, index: u32) []const u8 {
    assert(index >= 1);
    return std.mem.span(c.sqlite3_bind_parameter_name(statement, @intCast(index)) orelse "?");
}

fn has_parameter(statement: *c.Stmt, name: []const u8) bool {
    const count: u32 = @intCast(c.sqlite3_bind_parameter_count(statement));
    for (1..count + 1) |index| {
        const spelled = parameter_name(statement, @intCast(index));
        if (spelled[0] == ':' and std.mem.eql(u8, spelled[1..], name)) return true;
    }
    return false;
}

fn find(fields: []const Field, name: []const u8) ?Field {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field;
    }
    return null;
}

/// The result columns, each typed by its origin column, or its annotation.
fn compile_columns(
    compiler: *Compiler,
    file: u16,
    statement: *c.Stmt,
    annotations: *const annotation.Annotations,
) ?[]const Field {
    const count: u32 = @intCast(c.sqlite3_column_count(statement));
    const offset = annotations.name_offset;
    if (count > annotation.fields_max) {
        compiler.diagnostics.add(file, offset, "more than {d} columns", .{annotation.fields_max});
        return null;
    }
    const columns = compiler.arena.alloc(Field, count) catch return null;
    var ok = true;
    for (columns, 0..) |*column, index| {
        column.* = compile_column(compiler, file, statement, @intCast(index), annotations) orelse {
            ok = false;
            continue;
        };
        if (find(columns[0..index], column.name) != null) {
            compiler.diagnostics.add(file, offset, "two columns named {s}: name one with AS", .{
                column.name,
            });
            ok = false;
        }
    }
    for (annotations.column_list()) |declared| {
        if (ok and find(columns, declared.name) == null) {
            compiler.diagnostics.add(file, declared.offset, "@column {s}: the statement has " ++
                "no column {s}", .{ declared.name, declared.name });
            ok = false;
        }
    }
    return if (ok) columns else null;
}

fn compile_column(
    compiler: *Compiler,
    file: u16,
    statement: *c.Stmt,
    index: u32,
    annotations: *const annotation.Annotations,
) ?Field {
    const offset = annotations.name_offset;
    const name = std.mem.span(c.sqlite3_column_name(statement, @intCast(index)) orelse "");
    if (!names.is_snake(name) or names.is_roc_keyword(name)) {
        compiler.diagnostics.add(file, offset, "column `{s}` becomes a Roc field: name it " ++
            "snake_case with AS", .{name});
        return null;
    }
    const declared = find(annotations.column_list(), name);
    const from_table = c.sqlite3_column_table_name(statement, @intCast(index)) != null;
    const origin = if (from_table) origin_type(statement, index) else null;
    if (origin == null and declared == null) {
        compiler.diagnostics.add(file, offset, "column {s} is {s}, which SQLite cannot type: " ++
            "annotate `-- @column {s} : Type`", .{
            name, if (from_table) "declared ANY" else "an expression", name,
        });
        return null;
    }
    const field_type = if (declared) |field| field.type else origin.?.type;
    if (origin) |from| {
        if (field_type.scalar.storage() != from.storage) {
            compiler.diagnostics.add(file, declared.?.offset, "@column {s}: the column is " ++
                "{t} in its table, not {s}", .{ name, from.storage, field_type.scalar.roc() });
            return null;
        }
    }
    const kept = compiler.arena.dupe(u8, name) catch return null;
    return .{ .name = kept, .type = field_type, .offset = offset };
}

const Origin = struct { type: types.Type, storage: types.Storage };

/// The type of the table column a result column comes from, as its STRICT
/// table declares it, and whether it can be NULL here (our SQLite patch,
/// `sqlite3_column_nullable`: an outer join, a scalar subquery, an arm of
/// a compound select, or a column not NOT NULL); null for a column
/// declared ANY.
fn origin_type(statement: *c.Stmt, index: u32) ?Origin {
    const column: c_int = @intCast(index);
    // A column with a table has a declared type (column metadata).
    const declared = std.mem.span(c.sqlite3_column_decltype(statement, column).?);
    const storage = types.storage_from_declared(declared) orelse return null;
    // -1 for a column means an arm of a compound select is an expression
    // SQLite cannot prove never NULL (`UNION SELECT NULL`): nullable.
    const nullable = c.sqlite3_column_nullable(statement, column);
    assert(nullable >= -1 and nullable <= 1);
    const scalar: types.Scalar = switch (storage) {
        .integer => .i64,
        .real => .f64,
        .text => .str,
        .blob => .bytes,
    };
    return .{ .type = .{ .scalar = scalar, .nullable = nullable != 0 }, .storage = storage };
}
