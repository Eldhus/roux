//! The compiler: `schema.sql` into an in-memory SQLite, then every query
//! file's statements prepared against it, each checked and typed by what
//! SQLite reports of it. Nothing here reads SQL to understand it:
//!
//! - statements are split where `sqlite3_prepare_v3` says one ends;
//! - what a statement does comes from SQLite's authorizer (authorizer.zig);
//! - whether it writes from `sqlite3_stmt_readonly`;
//! - its parameters from `sqlite3_bind_parameter_name`;
//! - its result columns from their origin table and column (column
//!   metadata) and that column's declaration in a STRICT table;
//! - what SQLite cannot say (a parameter's type, an expression's) comes
//!   from the annotations, and an annotation SQLite contradicts is an error.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const c = sqlite.c;
const authorizer = sqlite.authorizer;
const types = sqlite.types;
const annotation = @import("annotation.zig");
const names = @import("names.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;

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
    /// The file's name: `schema.sql`, or `Module.sql`.
    name: []const u8,
    text: []const u8,
};

pub const Compiled = struct {
    /// Every statement, by file in the order given, then by position.
    statements: []const Statement,
};

const Compiler = struct {
    arena: Allocator,
    db: *c.Db,
    diagnostics: *Diagnostics,
    verdict: authorizer.Verdict,
    statements: std.ArrayList(Statement),
    /// A table column's declared type, NOT NULL and place in the primary
    /// key: `?1` table, `?2` column.
    column_lookup: *c.Stmt,
};

/// Compiles `queries` against `schema`; what is wrong goes to
/// `diagnostics`, and the result means something only when it is ok.
pub fn compile(
    arena: Allocator,
    schema: Input,
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
        .column_lookup = undefined,
    };
    load_schema(&compiler, schema.text);
    if (!diagnostics.ok()) return .{ .statements = &.{} };
    compiler.column_lookup = try prepare_own(db,
        \\SELECT type, "notnull", pk FROM pragma_table_xinfo(?1) WHERE name = ?2
    );
    defer _ = c.sqlite3_finalize(compiler.column_lookup);
    compiler.verdict = .{ .policy = .query };
    for (queries, 1..) |query, file| {
        compile_file(&compiler, @intCast(file), query);
    }
    return .{ .statements = compiler.statements.items };
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
    if (verdict.created.? != .create_table) return;
    const table = verdict.created_name();
    if (!is_strict(compiler.db, table)) {
        compiler.diagnostics.add(0, start, "table {s} is not STRICT: roux types a column by " ++
            "its declared type, which only a STRICT table enforces", .{table});
    }
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
    const origin = if (from_table) origin_type(compiler, statement, index) else null;
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
/// table declares it; null for a column declared ANY.
fn origin_type(compiler: *Compiler, statement: *c.Stmt, index: u32) ?Origin {
    // A column with a table has an origin column (column metadata).
    const table = std.mem.span(c.sqlite3_column_table_name(statement, @intCast(index)).?);
    const column = std.mem.span(c.sqlite3_column_origin_name(statement, @intCast(index)).?);
    const lookup = compiler.column_lookup;
    defer _ = c.sqlite3_reset(lookup);
    assert(c.sqlite3_bind_text64(lookup, 1, table.ptr, table.len, null, c.utf8) == c.ok);
    assert(c.sqlite3_bind_text64(lookup, 2, column.ptr, column.len, null, c.utf8) == c.ok);
    // SQLite named this column of this table: it is declared.
    assert(c.sqlite3_step(lookup) == c.row);
    const declared_text = c.sqlite3_column_text(lookup, 0) orelse return null;
    const declared_bytes: u32 = @intCast(c.sqlite3_column_bytes(lookup, 0));
    const storage = types.storage_from_declared(declared_text[0..declared_bytes]) orelse
        return null;
    const not_null = c.sqlite3_column_int64(lookup, 1) == 1;
    const in_key = c.sqlite3_column_int64(lookup, 2) > 0;
    // In a STRICT table every key column is NOT NULL; the one SQLite
    // reports otherwise is the rowid's alias (an INTEGER PRIMARY KEY),
    // which is the rowid and so never NULL either.
    const nullable = !not_null and !in_key;
    const scalar: types.Scalar = switch (storage) {
        .integer => .i64,
        .real => .f64,
        .text => .str,
        .blob => .bytes,
    };
    return .{ .type = .{ .scalar = scalar, .nullable = nullable }, .storage = storage };
}
