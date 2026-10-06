//! What a statement may do, decided by SQLite's own authorizer: while a
//! statement is prepared, SQLite names every action it takes (create a
//! table, read a column, begin a transaction, ...), so roux never reads
//! SQL to classify it. An interface file: the callback is C's.
//!
//! Two policies. `schema.sql` creates tables, indices, views and triggers,
//! nothing else. A query reads and writes rows; transactions, PRAGMAs,
//! ATTACH and every change to the schema are the platform's, never a
//! query's. Anything SQLite adds later is refused until named here.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig");

pub const Policy = enum { schema, query };

/// SQLite's action codes (sqlite3.h, "Authorizer Action Codes").
pub const Action = enum(c_int) {
    create_index = 1,
    create_table = 2,
    create_temp_index = 3,
    create_temp_table = 4,
    create_temp_trigger = 5,
    create_temp_view = 6,
    create_trigger = 7,
    create_view = 8,
    delete = 9,
    drop_index = 10,
    drop_table = 11,
    drop_temp_index = 12,
    drop_temp_table = 13,
    drop_temp_trigger = 14,
    drop_temp_view = 15,
    drop_trigger = 16,
    drop_view = 17,
    insert = 18,
    pragma = 19,
    read = 20,
    select = 21,
    transaction = 22,
    update = 23,
    attach = 24,
    detach = 25,
    alter_table = 26,
    reindex = 27,
    analyze = 28,
    create_vtable = 29,
    drop_vtable = 30,
    function = 31,
    savepoint = 32,
    recursive = 33,
    _,
};

/// What the authorizer saw of one statement. Reset it before each prepare.
pub const Verdict = struct {
    policy: Policy,
    /// The first action refused; SQLite then fails the prepare with
    /// `SQLITE_AUTH`, and this says which action it was.
    refused: ?Action = null,
    /// CREATE TABLE, INDEX, VIEW or TRIGGER: a schema statement makes one,
    /// and SQLite may add indices of its own (a WITHOUT ROWID table's key).
    creates: u32 = 0,
    /// SELECT, INSERT, UPDATE or DELETE: a query does at least one.
    data: u32 = 0,
    /// What the first CREATE made, and its name (cut at `created_bytes_max`).
    created: ?Action = null,
    created_name_buffer: [created_bytes_max]u8 = undefined,
    created_name_length: u32 = 0,

    pub const created_bytes_max = 128;

    pub fn reset(verdict: *Verdict) void {
        verdict.* = .{ .policy = verdict.policy };
    }

    pub fn created_name(verdict: *const Verdict) []const u8 {
        assert(verdict.created_name_length <= created_bytes_max);
        return verdict.created_name_buffer[0..verdict.created_name_length];
    }
};

/// Installs the authorizer on `db`; every prepare until the next install
/// reports to `verdict`, which must outlive those prepares.
pub fn install(db: *c.Db, verdict: *Verdict) void {
    assert(verdict.refused == null);
    const result = c.sqlite3_set_authorizer(db, authorize, verdict);
    assert(result == c.ok);
}

/// Removes the authorizer: for roux's own statements (introspection).
pub fn uninstall(db: *c.Db) void {
    const result = c.sqlite3_set_authorizer(db, null, null);
    assert(result == c.ok);
}

fn authorize(
    user: ?*anyopaque,
    code: c_int,
    first: ?[*:0]const u8,
    second: ?[*:0]const u8,
    database: ?[*:0]const u8,
    trigger: ?[*:0]const u8,
) callconv(.c) c_int {
    _ = second;
    _ = database;
    _ = trigger;
    const verdict: *Verdict = @ptrCast(@alignCast(user.?));
    const action: Action = @fromBackingInt(@intCast(code));
    const allowed = switch (verdict.policy) {
        .schema => allowed_in_schema(action, first),
        .query => allowed_in_query(action),
    };
    if (!allowed) {
        if (verdict.refused == null) verdict.refused = action;
        return c.deny;
    }
    switch (action) {
        .create_table, .create_index, .create_view, .create_trigger => {
            verdict.creates += 1;
            if (verdict.created == null) record_created(verdict, action, first);
        },
        .select, .insert, .update, .delete => verdict.data += 1,
        else => {},
    }
    return c.ok;
}

fn record_created(verdict: *Verdict, action: Action, name: ?[*:0]const u8) void {
    assert(verdict.created == null);
    const text = std.mem.span(name orelse "");
    const length: u32 = @intCast(@min(text.len, Verdict.created_bytes_max));
    @memcpy(verdict.created_name_buffer[0..length], text[0..length]);
    verdict.created_name_length = length;
    verdict.created = action;
}

/// A schema statement creates, and SQLite records it in `sqlite_schema`
/// (an insert, updates and reads of that table), reading the columns an
/// index or a view names.
fn allowed_in_schema(action: Action, first: ?[*:0]const u8) bool {
    return switch (action) {
        .create_table, .create_index, .create_view, .create_trigger => true,
        .read, .select, .function, .recursive, .reindex => true,
        .insert, .update, .delete => is_schema_table(first),
        else => false,
    };
}

fn allowed_in_query(action: Action) bool {
    return switch (action) {
        .select, .read, .insert, .update, .delete, .function, .recursive => true,
        else => false,
    };
}

/// The tables SQLite records the schema in; a TEMP object goes to the
/// temporary one, and is refused by its own action (`create_temp_*`).
fn is_schema_table(name: ?[*:0]const u8) bool {
    const table = std.mem.span(name orelse return false);
    const schema_tables = [_][]const u8{ "sqlite_master", "sqlite_schema", "sqlite_temp_master" };
    for (schema_tables) |schema_table| {
        if (std.mem.eql(u8, table, schema_table)) return true;
    }
    return false;
}

/// What a refused action is, for a person.
pub fn describe(action: Action) []const u8 {
    return switch (action) {
        .transaction, .savepoint => "a transaction (the platform begins and ends them)",
        .pragma => "a PRAGMA (the platform sets them)",
        .attach, .detach => "ATTACH or DETACH (one database per app)",
        .create_temp_index,
        .create_temp_table,
        .create_temp_trigger,
        .create_temp_view,
        => "a TEMP object",
        .create_index, .create_table, .create_trigger, .create_view => "a change to the schema",
        .drop_index, .drop_table, .drop_trigger, .drop_view => "a DROP (no migrations yet)",
        .drop_temp_index, .drop_temp_table, .drop_temp_trigger, .drop_temp_view => "a DROP",
        .alter_table => "ALTER TABLE (no migrations yet)",
        .create_vtable, .drop_vtable => "a virtual table",
        .analyze, .reindex => "ANALYZE or REINDEX (maintenance is the platform's)",
        .insert, .update, .delete => "a write to a table (schema.sql only creates)",
        .read, .select, .function, .recursive => "a read",
        _ => "an action this SQLite has and roux does not know",
    };
}
