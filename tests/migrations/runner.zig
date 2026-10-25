//! The migration cases: each `cases/*.case` holds a database as it was
//! (`== before`: SQL, rows too), the schema.sql it must become (`== after`,
//! its `-- @drop`s too), and what opening it must print: the plan as the
//! host prints it (`== plan`) and why it did not open (`== error`), each
//! empty when absent. Text before the first section says what the case is.
//!
//! A case runs the real path: roux-db reads the after schema (as `roux
//! build` would), main.roc's app opens the database through Sqlite.open!
//! (Migrate.roc plans, the host migrates), then the runner checks what must
//! hold whatever the plan was:
//!
//! - opened: the schema is what schema.sql makes, to the byte; every row
//!   of every table both have is there, by the columns both have; an
//!   AUTOINCREMENT kept goes on from where it was; the database is whole
//!   and its foreign keys hold; opening again plans nothing;
//! - not opened: nothing changed, schema or rows;
//! - a migration that lost a table or a column copied the database first,
//!   whole (`test.db.before-drop/`), and one that lost nothing did not.
//!
//! `== before` runs as plain SQL, with no policy: it may make what
//! schema.sql never could (`ANALYZE`'s `sqlite_stat1`), as a database
//! touched by other tools would hold.
//!
//! `zig build migrations` runs every case; `-Dbless` writes what was
//! printed into the cases instead (read the diff), the checks still on;
//! `-Dcase=TEXT` runs the cases whose name holds TEXT.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const c = sqlite.c;
const roux_db = @import("roux_db");

const cases_dir = "tests/migrations/cases";
const work_dir = ".zig-cache/migrations";
const case_bytes_max = 1 << 20;
const output_bytes_max = 1 << 20;
const cases_max = 1024;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.Usage;
    var bless = false;
    var filter: []const u8 = "";
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--bless")) bless = true else filter = arg;
    }
    // roux's VFS does SQLite's file I/O through the thread's Io. Its lock
    // keeps the app out while a database is open here: each is closed
    // before the app runs.
    sqlite.vfs.thread_io = io;
    try sqlite.initialize();
    try Io.Dir.cwd().createDirPath(io, work_dir);
    const app = try build_app(gpa, io, args[1]);
    defer gpa.free(app);
    const names = try case_names(gpa, io, filter);
    defer {
        for (names) |name| gpa.free(name);
        gpa.free(names);
    }
    var failed: u32 = 0;
    for (names) |name| {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const verdict = run_case(arena_state.allocator(), io, app, name, bless) catch |err|
            Verdict{ .failure = @errorName(err) };
        switch (verdict) {
            .pass => std.debug.print("ok   {s}\n", .{name}),
            .failure => |why| {
                failed += 1;
                std.debug.print("FAIL {s}\n{s}\n", .{ name, why });
            },
        }
    }
    std.debug.print("{d} cases, {d} failed{s}\n", .{
        names.len, failed, if (bless) ", the rest blessed" else "",
    });
    if (failed > 0) std.process.exit(1);
}

/// main.roc's app, built once: its path.
fn build_app(gpa: Allocator, io: Io, roc: []const u8) ![]const u8 {
    const app = try std.fmt.allocPrint(gpa, "{s}/app", .{work_dir});
    errdefer gpa.free(app);
    const output = try std.fmt.allocPrint(gpa, "--output={s}", .{app});
    defer gpa.free(output);
    const ran = try std.process.run(gpa, io, .{
        .argv = &.{ roc, "build", "--opt=dev", output, "tests/migrations/main.roc" },
        .stdout_limit = .limited(output_bytes_max),
        .stderr_limit = .limited(output_bytes_max),
    });
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    if (!ran.term.success()) {
        std.debug.print("roc build failed:\n{s}{s}\n", .{ ran.stdout, ran.stderr });
        return error.AppBuildFailed;
    }
    return app;
}

fn case_names(gpa: Allocator, io: Io, filter: []const u8) ![][]const u8 {
    var dir = try Io.Dir.cwd().openDir(io, cases_dir, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".case")) continue;
        if (std.mem.indexOf(u8, entry.name, filter) == null) continue;
        if (names.items.len == cases_max) return error.TooManyCases;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, less);
    return names.toOwnedSlice(gpa);
}

fn less(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

const Verdict = union(enum) { pass, failure: []const u8 };

// --- a case file ------------------------------------------------------------

const Section = enum { before, after, plan, @"error" };

const Case = struct {
    prose: []const u8 = "",
    sections: [4][]const u8 = @splat(""),

    fn get(case: *const Case, section: Section) []const u8 {
        return case.sections[@intFromEnum(section)];
    }
};

/// Sections begin at a line `== name`; each is its lines, without the
/// blank lines around them.
fn parse(text: []const u8) !Case {
    var case: Case = .{};
    var current: ?Section = null;
    var seen: [4]bool = @splat(false);
    var start: usize = 0;
    var at: usize = 0;
    while (at < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
        const line = text[at..end];
        if (std.mem.startsWith(u8, line, "== ")) {
            close(&case, current, text[start..at]);
            const section = std.meta.stringToEnum(Section, line[3..]) orelse
                return error.UnknownSection;
            if (seen[@intFromEnum(section)]) return error.SectionTwice;
            seen[@intFromEnum(section)] = true;
            current = section;
            start = @min(end + 1, text.len);
        }
        at = end + 1;
    }
    close(&case, current, text[start..]);
    if (!seen[@intFromEnum(Section.before)] or !seen[@intFromEnum(Section.after)]) {
        return error.BeforeAndAfterNeeded;
    }
    return case;
}

fn close(case: *Case, current: ?Section, text: []const u8) void {
    const trimmed = std.mem.trim(u8, text, "\n");
    if (current) |section| case.sections[@intFromEnum(section)] = trimmed else case.prose = trimmed;
}

/// The case as a file: an empty plan or error is left out.
fn render(arena: Allocator, case: Case) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    if (case.prose.len > 0) try w.print("{s}\n\n", .{case.prose});
    for (std.enums.values(Section)) |section| {
        const text = case.get(section);
        if (text.len == 0 and (section == .plan or section == .@"error")) continue;
        if (text.len == 0) try w.print("== {t}\n\n", .{section}) else {
            try w.print("== {t}\n{s}\n\n", .{ section, text });
        }
    }
    const written = out.written();
    return written[0 .. written.len - 1]; // one newline at the end
}

// --- running one ----------------------------------------------------------------

fn run_case(arena: Allocator, io: Io, app: []const u8, name: []const u8, bless: bool) !Verdict {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ cases_dir, name });
    const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(case_bytes_max));
    var case = try parse(text);
    const stem = name[0 .. name.len - ".case".len];
    const dir = try std.fmt.allocPrint(arena, "{s}/{s}", .{ work_dir, stem });
    try Io.Dir.cwd().deleteTree(io, dir);
    try Io.Dir.cwd().createDirPath(io, dir);
    // The database as it was, twice: one to migrate, one to compare with.
    try make_database(arena, dir, "test.db", case.get(.before));
    try make_database(arena, dir, "before.db", case.get(.before));
    const opened = try open(arena, io, app, dir, case.get(.after));
    var problems: std.Io.Writer.Allocating = .init(arena);
    const w = &problems.writer;
    if (opened.opened) {
        try check_opened(arena, dir, case.get(.after), w);
        const again = try open(arena, io, app, dir, case.get(.after));
        if (!again.opened or again.plan.len > 0) {
            try w.print("  opened again, it planned or failed:\n{s}\n{s}\n", .{
                again.plan, again.@"error",
            });
        }
    } else {
        try check_unchanged(arena, dir, w);
    }
    try check_copied(arena, io, dir, opened.opened, w);
    if (bless) {
        case.sections[@intFromEnum(Section.plan)] = opened.plan;
        case.sections[@intFromEnum(Section.@"error")] = opened.@"error";
        const blessed = try render(arena, case);
        if (!std.mem.eql(u8, blessed, text)) {
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = blessed });
        }
    } else {
        try expect_text(w, "plan", case.get(.plan), opened.plan);
        try expect_text(w, "error", case.get(.@"error"), opened.@"error");
    }
    const written = problems.written();
    return if (written.len == 0) .pass else .{ .failure = written };
}

fn expect_text(w: *std.Io.Writer, what: []const u8, expected: []const u8, got: []const u8) !void {
    if (std.mem.eql(u8, expected, got)) return;
    try w.print("  == {s} expected:\n{s}\n  == {s} printed:\n{s}\n", .{
        what, expected, what, got,
    });
}

const Opened = struct {
    opened: bool,
    plan: []const u8,
    @"error": []const u8,
};

/// roux-db over `after`, then the app: whether the database opened, the
/// plan it printed, and why not. roux-db's refusal is the app's too.
fn open(arena: Allocator, io: Io, app: []const u8, dir: []const u8, after: []const u8) !Opened {
    var diagnostics: roux_db.Diagnostics = .init(arena);
    const schema: roux_db.Input = .{ .name = "schema.sql", .text = after };
    const compiled = try roux_db.compile(arena, schema, &.{}, &diagnostics);
    if (!diagnostics.ok()) {
        var said: std.Io.Writer.Allocating = .init(arena);
        for (diagnostics.items()) |diagnostic| try said.writer.print("roux-db: {s}\n", .{
            diagnostic.message,
        });
        const refused = std.mem.trimEnd(u8, said.written(), "\n");
        return .{ .opened = false, .plan = "", .@"error" = refused };
    }
    var drops: std.Io.Writer.Allocating = .init(arena);
    for (compiled.drops) |drop| {
        if (drop.column) |column| {
            try drops.writer.print("column\t{s}\t{s}\n", .{ drop.table, column });
        } else {
            try drops.writer.print("table\t{s}\n", .{drop.table});
        }
    }
    var case_dir = try Io.Dir.cwd().openDir(io, dir, .{});
    defer case_dir.close(io);
    try case_dir.writeFile(io, .{ .sub_path = "schema.sql", .data = after });
    try case_dir.writeFile(io, .{ .sub_path = "drops", .data = drops.written() });
    var environ: std.process.Environ.Map = .init(arena); // no ROUX_DATABASE
    const app_path = try std.fs.path.join(arena, &.{ "..", std.fs.path.basename(app) });
    const ran = try std.process.run(arena, io, .{
        .argv = &.{app_path},
        .cwd = .{ .path = dir },
        .environ_map = &environ,
        .stdout_limit = .limited(output_bytes_max),
        .stderr_limit = .limited(output_bytes_max),
    });
    const code: u8 = switch (ran.term) {
        .exited => |code| code,
        else => return error.AppCrashed,
    };
    if (code > 1) {
        std.debug.print("{s}\n", .{ran.stderr});
        return error.AppFailed;
    }
    return .{
        .opened = code == 0,
        .plan = try plan_of(arena, ran.stdout),
        .@"error" = std.mem.trim(u8, ran.stderr, "\n"),
    };
}

/// What the host printed, without its line once the database is open, and
/// the copy's before a drop, dated (`check_copied` checks the copy).
fn plan_of(arena: Allocator, stdout: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "roux: database ")) continue;
        if (std.mem.startsWith(u8, line, "roux: copied ")) continue;
        try out.writer.print("{s}\n", .{line});
    }
    return std.mem.trim(u8, out.written(), "\n");
}

// --- the checks -------------------------------------------------------------------

fn check_opened(arena: Allocator, dir: []const u8, after: []const u8, w: *std.Io.Writer) !void {
    const db = try open_file(arena, dir, "test.db");
    defer close_db(db);
    const before = try open_file(arena, dir, "before.db");
    defer close_db(before);
    const pristine = try open_memory();
    defer close_db(pristine);
    try sqlite.exec(pristine, after);
    // SQLite's own tables aside (`sqlite_sequence`, `sqlite_stat1`): what
    // ran on the database before may leave them. A key's index is kept.
    const schema_sql = "SELECT type || ' ' || name || ' ' || tbl_name || char(10) || " ++
        "coalesce(sql, '') FROM sqlite_schema " ++
        "WHERE type != 'table' OR name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY type, name";
    const made = try text_of(arena, db, schema_sql);
    const wanted = try text_of(arena, pristine, schema_sql);
    if (!std.mem.eql(u8, made, wanted)) {
        try w.print("  the schema is not what schema.sql makes:\n{s}\n  but:\n{s}\n", .{
            made, wanted,
        });
    }
    const integrity = try text_of(arena, db, "PRAGMA integrity_check");
    if (!std.mem.eql(u8, integrity, "ok")) try w.print("  integrity_check: {s}\n", .{integrity});
    const broken = try text_of(arena, db, "SELECT count(*) FROM pragma_foreign_key_check");
    if (!std.mem.eql(u8, broken, "0")) try w.print("  {s} rows break a foreign key\n", .{broken});
    try check_rows(arena, before, db, w);
    try check_sequences(arena, before, db, w);
}

/// A migration that lost a table or a column copied the database first,
/// whole, into `test.db.before-drop/`; one that lost nothing copied
/// nothing. One that failed may have copied it (the copy comes first).
fn check_copied(
    arena: Allocator,
    io: Io,
    dir: []const u8,
    opened: bool,
    w: *std.Io.Writer,
) !void {
    const copies_dir = try std.fmt.allocPrint(arena, "{s}/test.db.before-drop", .{dir});
    var copy_name: ?[]const u8 = null;
    var copies: u32 = 0;
    if (Io.Dir.cwd().openDir(io, copies_dir, .{ .iterate = true })) |opened_dir| {
        var copies_handle = opened_dir;
        defer copies_handle.close(io);
        var entries = copies_handle.iterate();
        while (try entries.next(io)) |entry| {
            copies += 1;
            copy_name = try arena.dupe(u8, entry.name);
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    if (copies > 1) try w.print("  {d} copies before the drop, not one\n", .{copies});
    const before = try open_file(arena, dir, "before.db");
    defer close_db(before);
    if (opened) {
        const db = try open_file(arena, dir, "test.db");
        defer close_db(db);
        const lost = try lost_any(arena, before, db);
        if (lost and copies == 0) try w.print("  it dropped, with no copy before\n", .{});
        if (!lost and copies > 0) try w.print("  it dropped nothing, and copied\n", .{});
    }
    const name = copy_name orelse return;
    const path = try std.fmt.allocPrint(arena, "test.db.before-drop/{s}", .{name});
    const copy = try open_file(arena, dir, path);
    defer close_db(copy);
    const schema_sql = "SELECT type || ' ' || name || char(10) || coalesce(sql, '') " ++
        "FROM sqlite_schema ORDER BY type, name";
    const copied = try text_of(arena, copy, schema_sql);
    if (!std.mem.eql(u8, copied, try text_of(arena, before, schema_sql))) {
        try w.print("  the copy before the drop has another schema\n", .{});
    }
    try check_rows(arena, before, copy, w);
}

/// Whether `before` had a table or a column of a table `db` has no more.
fn lost_any(arena: Allocator, before: *c.Db, db: *c.Db) !bool {
    const tables_sql = "SELECT name FROM sqlite_schema WHERE type = 'table' " ++
        "AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name";
    const tables = try text_of(arena, before, tables_sql);
    var names = std.mem.tokenizeScalar(u8, tables, '\n');
    while (names.next()) |table| {
        const columns_sql = try std.fmt.allocPrint(arena, "SELECT name FROM " ++
            "pragma_table_xinfo({s}) WHERE hidden = 0", .{try literal(arena, table)});
        const columns = try text_of(arena, before, columns_sql);
        var each = std.mem.tokenizeScalar(u8, columns, '\n');
        while (each.next()) |column| {
            const kept_sql = try std.fmt.allocPrint(arena, "SELECT count(*) FROM " ++
                "pragma_table_xinfo({s}) WHERE hidden = 0 AND name = {s} COLLATE NOCASE", .{
                try literal(arena, table), try literal(arena, column),
            });
            if (std.mem.eql(u8, try text_of(arena, db, kept_sql), "0")) return true;
        }
    }
    return false;
}

/// A table that keeps AUTOINCREMENT keeps the largest key it handed out,
/// even one no row holds now: no key is handed out twice.
fn check_sequences(arena: Allocator, before: *c.Db, db: *c.Db, w: *std.Io.Writer) !void {
    const has_sequence = "SELECT count(*) FROM sqlite_schema WHERE name = 'sqlite_sequence'";
    if (std.mem.eql(u8, try text_of(arena, before, has_sequence), "0")) return;
    const tables = try text_of(arena, before, "SELECT name FROM sqlite_sequence ORDER BY name");
    var names = std.mem.tokenizeScalar(u8, tables, '\n');
    while (names.next()) |table| {
        if (!try autoincrements(arena, db, table)) continue;
        const sql = try std.fmt.allocPrint(arena, "SELECT seq FROM sqlite_sequence " ++
            "WHERE name = {s} COLLATE NOCASE", .{try literal(arena, table)});
        const was = try text_of(arena, before, sql);
        const now = try text_of(arena, db, sql);
        if (!std.mem.eql(u8, was, now)) {
            try w.print("  table {s}'s AUTOINCREMENT: {s}, was {s}\n", .{ table, now, was });
        }
    }
}

/// Whether `db` has `table`, with AUTOINCREMENT on its key.
fn autoincrements(arena: Allocator, db: *c.Db, table: []const u8) !bool {
    const table_z = try arena.dupeSentinel(u8, table, 0);
    const sql = try std.fmt.allocPrint(arena, "SELECT name FROM pragma_table_info({s}) " ++
        "WHERE pk = 1", .{try literal(arena, table)});
    const keys = try text_of(arena, db, sql);
    var each = std.mem.tokenizeScalar(u8, keys, '\n');
    while (each.next()) |key| {
        var flag: c_int = 0;
        const key_z = try arena.dupeSentinel(u8, key, 0);
        const result = c.sqlite3_table_column_metadata(
            db,
            "main",
            table_z,
            key_z,
            null,
            null,
            null,
            null,
            &flag,
        );
        if (result != c.ok) return error.QueryFailed;
        if (flag != 0) return true;
    }
    return false;
}

fn check_unchanged(arena: Allocator, dir: []const u8, w: *std.Io.Writer) !void {
    const db = try open_file(arena, dir, "test.db");
    defer close_db(db);
    const before = try open_file(arena, dir, "before.db");
    defer close_db(before);
    const schema_sql = "SELECT type || ' ' || name || char(10) || coalesce(sql, '') " ++
        "FROM sqlite_schema ORDER BY type, name";
    const now = try text_of(arena, db, schema_sql);
    const was = try text_of(arena, before, schema_sql);
    if (!std.mem.eql(u8, now, was)) {
        try w.print("  it did not open, and the schema changed:\n{s}\n  was:\n{s}\n", .{
            now, was,
        });
    }
    try check_rows(arena, before, db, w);
}

/// Every table of `before` that `db` has (by SQLite's name rules), row for
/// row, by the columns both have that hold values.
fn check_rows(arena: Allocator, before: *c.Db, db: *c.Db, w: *std.Io.Writer) !void {
    const tables_sql = "SELECT name FROM sqlite_schema WHERE type = 'table' " ++
        "AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name";
    const tables = try text_of(arena, before, tables_sql);
    var names = std.mem.tokenizeScalar(u8, tables, '\n');
    while (names.next()) |table| {
        const columns = try common_columns(arena, before, db, table);
        if (columns.len == 0) continue;
        const sql = try rows_sql(arena, table, columns);
        const was = try text_of(arena, before, sql);
        const now = try text_of(arena, db, sql);
        if (!std.mem.eql(u8, was, now)) {
            try w.print("  table {s}'s rows by {s}:\n{s}\n  were:\n{s}\n", .{
                table, columns, now, was,
            });
        }
    }
}

/// `"a", "b"`: the columns holding values in both, as `before` names them.
fn common_columns(arena: Allocator, before: *c.Db, db: *c.Db, table: []const u8) ![]const u8 {
    const sql = try std.fmt.allocPrint(arena, "SELECT name FROM pragma_table_xinfo({s}) " ++
        "WHERE hidden = 0 ORDER BY cid", .{try literal(arena, table)});
    const had = try text_of(arena, before, sql);
    const has = try text_of(arena, db, sql);
    var out: std.Io.Writer.Allocating = .init(arena);
    var columns = std.mem.tokenizeScalar(u8, had, '\n');
    while (columns.next()) |column| {
        var now = std.mem.tokenizeScalar(u8, has, '\n');
        const kept = while (now.next()) |other| {
            if (std.ascii.eqlIgnoreCase(other, column)) break true;
        } else false;
        if (!kept) continue;
        if (out.written().len > 0) try out.writer.writeAll(", ");
        try out.writer.writeAll(try quote(arena, column));
    }
    return out.written();
}

/// Each row as text, its values as text: a value the new table converts
/// as it is copied (an integer into a TEXT column of a STRICT table) is
/// the same value.
fn rows_sql(arena: Allocator, table: []const u8, columns: []const u8) ![]const u8 {
    var cells: std.Io.Writer.Allocating = .init(arena);
    var each = std.mem.splitSequence(u8, columns, ", ");
    while (each.next()) |column| {
        if (cells.written().len > 0) try cells.writer.writeAll(" || '|' || ");
        try cells.writer.print("CASE WHEN {s} IS NULL THEN 'NULL' " ++
            "ELSE quote(CAST({s} AS TEXT)) END", .{ column, column });
    }
    return std.fmt.allocPrint(arena, "SELECT {s} FROM {s} ORDER BY 1", .{
        cells.written(), try quote(arena, table),
    });
}

/// An identifier, quoted as SQL quotes one.
fn quote(arena: Allocator, name: []const u8) ![]const u8 {
    const doubled = try std.mem.replaceOwned(u8, arena, name, "\"", "\"\"");
    return std.fmt.allocPrint(arena, "\"{s}\"", .{doubled});
}

/// A string literal.
fn literal(arena: Allocator, text: []const u8) ![]const u8 {
    const doubled = try std.mem.replaceOwned(u8, arena, text, "'", "''");
    return std.fmt.allocPrint(arena, "'{s}'", .{doubled});
}

// --- SQLite -------------------------------------------------------------------------

fn make_database(arena: Allocator, dir: []const u8, name: []const u8, sql: []const u8) !void {
    const db = try open_file(arena, dir, name);
    defer close_db(db);
    sqlite.exec(db, sql) catch {
        std.debug.print("== before: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.BeforeFailed;
    };
}

fn open_file(arena: Allocator, dir: []const u8, name: []const u8) !*c.Db {
    const path = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ dir, name }, 0);
    var db: ?*c.Db = null;
    const flags = c.open_readwrite | c.open_create | c.open_exrescode;
    if (c.sqlite3_open_v2(path, &db, flags, null) != c.ok) {
        _ = c.sqlite3_close_v2(db);
        return error.OpenFailed;
    }
    return db.?;
}

fn open_memory() !*c.Db {
    var db: ?*c.Db = null;
    const flags = c.open_readwrite | c.open_create | c.open_memory | c.open_exrescode;
    if (c.sqlite3_open_v2(":memory:", &db, flags, null) != c.ok) {
        _ = c.sqlite3_close_v2(db);
        return error.OpenFailed;
    }
    return db.?;
}

fn close_db(db: *c.Db) void {
    const result = c.sqlite3_close_v2(db);
    assert(result == c.ok);
}

/// Each row's first column, a line each.
fn text_of(arena: Allocator, db: *c.Db, sql: []const u8) ![]const u8 {
    var statement: ?*c.Stmt = null;
    if (c.sqlite3_prepare_v3(db, sql.ptr, @intCast(sql.len), 0, &statement, null) != c.ok) {
        std.debug.print("{s}: {s}\n", .{ sql, c.sqlite3_errmsg(db) });
        return error.QueryFailed;
    }
    defer _ = c.sqlite3_finalize(statement);
    var out: std.Io.Writer.Allocating = .init(arena);
    const rows_max = 1 << 20;
    for (0..rows_max) |_| {
        switch (c.sqlite3_step(statement.?)) {
            c.done => break,
            c.row => {},
            else => return error.QueryFailed,
        }
        if (out.written().len > 0) try out.writer.writeAll("\n");
        const bytes = c.sqlite3_column_text(statement.?, 0) orelse continue;
        try out.writer.writeAll(bytes[0..@intCast(c.sqlite3_column_bytes(statement.?, 0))]);
    } else return error.TooManyRows;
    return out.written();
}
