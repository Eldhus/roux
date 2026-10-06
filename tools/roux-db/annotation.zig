//! The comments before a statement: where the statement begins, and the
//! annotations among them. Pure.
//!
//! Before a statement SQLite's tokenizer allows only whitespace, `--`
//! comments (to the end of the line), `/* */` comments and `;`. `scan`
//! follows exactly those rules (tokenize.c: `aiClass`, CC_SPACE, CC_MINUS,
//! CC_SLASH, CC_SEMI), and the caller has SQLite confirm the stretch it
//! found prepares to no statement, so the two cannot drift apart unseen.
//!
//! Annotations are `--` comments, one per line:
//!
//!   -- name: by_id :one          (or `:many(200)`, or `:exec`)
//!   -- @param id : I64
//!   -- @column n : I64
//!
//! Any other comment is prose. A `--` comment beginning with `@` that is
//! not one of these is an error, so a misspelt annotation is never prose.

const std = @import("std");
const assert = std.debug.assert;
const types = @import("sqlite").types;
const names = @import("names.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;

/// Parameters, or result columns, of one statement.
pub const fields_max = 64;
/// The most rows a `:many` query may say it returns.
pub const rows_max_limit = 100_000;
/// Words on an annotation line: `@param id : Nullable(I64)` has four.
const words_max = 8;

pub const Kind = enum {
    /// At most one row: the function returns it, or `NotFound`.
    one,
    /// At most `rows_max` rows; more is an error, never a silent cut.
    many,
    /// No rows.
    exec,
};

pub const Field = struct {
    name: []const u8,
    type: types.Type,
    /// Where the annotation is, in the file.
    offset: u32,
};

pub const Annotations = struct {
    name: ?[]const u8 = null,
    name_offset: u32 = 0,
    kind: Kind = .one,
    /// 1 for `:one`, N for `:many(N)`, 0 for `:exec`.
    rows_max: u32 = 0,
    params: [fields_max]Field = undefined,
    params_count: u32 = 0,
    columns: [fields_max]Field = undefined,
    columns_count: u32 = 0,

    pub fn param_list(annotations: *const Annotations) []const Field {
        return annotations.params[0..annotations.params_count];
    }

    pub fn column_list(annotations: *const Annotations) []const Field {
        return annotations.columns[0..annotations.columns_count];
    }
};

/// Where `scan` reports to: `file` is the index diagnostics name.
pub const Sink = struct {
    annotations: *Annotations,
    diagnostics: *Diagnostics,
    file: u16,
};

/// Scans `text[start..end]` as SQLite does before a statement; returns the
/// offset of the statement's first byte, or `end` when only whitespace,
/// comments and `;` are there. Each `--` comment goes to `parse_line`.
pub fn scan(text: []const u8, start: u32, end: u32, sink: Sink) u32 {
    assert(start <= end and end <= text.len);
    var at = start;
    // Each pass consumes at least one byte.
    for (0..end - start + 1) |_| {
        if (at >= end) return end;
        const byte = text[at];
        if (is_space(byte) or byte == ';') {
            at += 1;
        } else if (byte == '-' and at + 1 < end and text[at + 1] == '-') {
            const newline = std.mem.indexOfScalarPos(u8, text[0..end], at, '\n');
            const line_end: u32 = if (newline) |offset| @intCast(offset) else end;
            parse_line(text[at + 2 .. line_end], at, sink);
            at = line_end;
        } else if (byte == '/' and at + 1 < end and text[at + 1] == '*') {
            const close = std.mem.indexOfPos(u8, text[0..end], at + 2, "*/");
            at = if (close) |offset| @intCast(offset + 2) else end;
        } else {
            return at;
        }
    } else unreachable;
}

/// SQLite's spaces: tab, newline, form feed, carriage return, space; not
/// vertical tab (aiClass, CC_SPACE).
fn is_space(byte: u8) bool {
    return switch (byte) {
        '\t', '\n', 0x0c, '\r', ' ' => true,
        else => false,
    };
}

/// One `--` comment's text, after the dashes; `offset` is the comment's.
fn parse_line(line: []const u8, offset: u32, sink: Sink) void {
    var words_buffer: [words_max][]const u8 = undefined;
    var words_count: u32 = 0;
    var iterator = std.mem.tokenizeAny(u8, line, " \t\r");
    while (iterator.next()) |word| {
        if (words_count == words_max) break;
        words_buffer[words_count] = word;
        words_count += 1;
    }
    const words = words_buffer[0..words_count];
    if (words.len == 0) return;
    if (std.mem.eql(u8, words[0], "name:")) return parse_name(words, offset, sink);
    if (words[0][0] != '@') return; // prose
    if (std.mem.eql(u8, words[0], "@param")) return parse_field(words, offset, sink, .param);
    if (std.mem.eql(u8, words[0], "@column")) return parse_field(words, offset, sink, .column);
    sink.diagnostics.add(sink.file, offset, "unknown annotation {s}: roux-db knows " ++
        "`-- name:`, `-- @param` and `-- @column`", .{words[0]});
}

fn parse_name(words: []const []const u8, offset: u32, sink: Sink) void {
    assert(std.mem.eql(u8, words[0], "name:"));
    const annotations = sink.annotations;
    if (annotations.name != null) {
        sink.diagnostics.add(sink.file, offset, "a second `-- name:` before one statement", .{});
        return;
    }
    if (words.len != 3) {
        sink.diagnostics.add(sink.file, offset, "write `-- name: query_name :one` " ++
            "(or `:many(N)`, or `:exec`)", .{});
        return;
    }
    const name = words[1];
    if (!names.is_snake(name) or names.is_roc_keyword(name)) {
        sink.diagnostics.add(sink.file, offset, "query name `{s}`: snake_case, at most " ++
            "64 bytes, not a Roc keyword", .{name});
        return;
    }
    const kind = parse_kind(words[2]) orelse {
        sink.diagnostics.add(sink.file, offset, "`{s}`: the kind is `:one`, `:many(N)` " ++
            "with N from 1 to 100000, or `:exec`", .{words[2]});
        return;
    };
    annotations.name = name;
    annotations.name_offset = offset;
    annotations.kind = kind.kind;
    annotations.rows_max = kind.rows_max;
}

fn parse_kind(word: []const u8) ?struct { kind: Kind, rows_max: u32 } {
    if (std.mem.eql(u8, word, ":one")) return .{ .kind = .one, .rows_max = 1 };
    if (std.mem.eql(u8, word, ":exec")) return .{ .kind = .exec, .rows_max = 0 };
    const prefix = ":many(";
    if (!std.mem.startsWith(u8, word, prefix) or !std.mem.endsWith(u8, word, ")")) return null;
    const digits = word[prefix.len .. word.len - 1];
    const rows_max = std.fmt.parseInt(u32, digits, 10) catch return null;
    if (rows_max == 0 or rows_max > rows_max_limit) return null;
    return .{ .kind = .many, .rows_max = rows_max };
}

const FieldKind = enum { param, column };

fn parse_field(words: []const []const u8, offset: u32, sink: Sink, kind: FieldKind) void {
    const what = @tagName(kind);
    if (words.len != 4 or !std.mem.eql(u8, words[2], ":")) {
        sink.diagnostics.add(sink.file, offset, "write `-- @{s} name : Type`", .{what});
        return;
    }
    const name = words[1];
    if (!names.is_snake(name) or names.is_roc_keyword(name)) {
        sink.diagnostics.add(sink.file, offset, "@{s} `{s}`: snake_case, at most 64 bytes, " ++
            "not a Roc keyword", .{ what, name });
        return;
    }
    const field_type = types.Type.parse(words[3]) orelse {
        sink.diagnostics.add(sink.file, offset, "@{s} {s}: `{s}` is not I64, F64, Str, " ++
            "List(U8), Bool, or Nullable of one", .{ what, name, words[3] });
        return;
    };
    const annotations = sink.annotations;
    const list = switch (kind) {
        .param => annotations.params[0..annotations.params_count],
        .column => annotations.columns[0..annotations.columns_count],
    };
    for (list) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            sink.diagnostics.add(sink.file, offset, "@{s} {s} twice", .{ what, name });
            return;
        }
    }
    if (list.len == fields_max) {
        sink.diagnostics.add(sink.file, offset, "more than {d} @{s}", .{ fields_max, what });
        return;
    }
    const field: Field = .{ .name = name, .type = field_type, .offset = offset };
    switch (kind) {
        .param => annotations.params[annotations.params_count] = field,
        .column => annotations.columns[annotations.columns_count] = field,
    }
    switch (kind) {
        .param => annotations.params_count += 1,
        .column => annotations.columns_count += 1,
    }
}

const testing = std.testing;

fn scan_test(text: []const u8, annotations: *Annotations, diagnostics: *Diagnostics) u32 {
    const sink: Sink = .{ .annotations = annotations, .diagnostics = diagnostics, .file = 1 };
    return scan(text, 0, @intCast(text.len), sink);
}

test "annotation: a statement's annotations, and where it begins" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diagnostics = Diagnostics.init(arena_state.allocator());
    var annotations: Annotations = .{};
    const text =
        \\;  -- prose before
        \\/* a -- block comment, @param x : I64 is prose here */
        \\-- name: due_soon :many(50)
        \\-- @param days : I64
        \\-- @column n : Nullable(I64)
        \\SELECT 1
    ;
    const start = scan_test(text, &annotations, &diagnostics);
    try testing.expect(diagnostics.ok());
    try testing.expectEqualStrings("SELECT 1", text[start..]);
    try testing.expectEqualStrings("due_soon", annotations.name.?);
    try testing.expectEqual(Kind.many, annotations.kind);
    try testing.expectEqual(50, annotations.rows_max);
    try testing.expectEqualStrings("days", annotations.param_list()[0].name);
    try testing.expectEqual(true, annotations.column_list()[0].type.nullable);
}

test "annotation: misspelt and malformed annotations are errors, not prose" {
    const cases = [_][]const u8{
        "-- @parm id : I64\n",
        "-- @param id: I64\n",
        "-- @param id : U64\n",
        "-- @param Id : I64\n",
        "-- @param match : I64\n",
        "-- @param id : I64\n-- @param id : Str\n",
        "-- name: by_id\n",
        "-- name: by_id :many(0)\n",
        "-- name: by_id :many(100001)\n",
        "-- name: by_id :all\n",
        "-- name: ById :one\n",
        "-- name: a :one\n-- name: b :one\n",
    };
    for (cases) |text| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        var diagnostics = Diagnostics.init(arena_state.allocator());
        var annotations: Annotations = .{};
        _ = scan_test(text, &annotations, &diagnostics);
        testing.expect(!diagnostics.ok()) catch |err| {
            std.debug.print("accepted: {s}", .{text});
            return err;
        };
    }
}

test "annotation: a gap with no statement scans to its end" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diagnostics = Diagnostics.init(arena_state.allocator());
    var annotations: Annotations = .{};
    const text = "  -- only prose\n /* and this */ ; ;\n/* unterminated";
    try testing.expectEqual(text.len, scan_test(text, &annotations, &diagnostics));
    try testing.expect(diagnostics.ok());
    try testing.expectEqual(null, annotations.name);
}
