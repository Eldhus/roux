//! A database directory's generated Roc, from its files' contents: the
//! compiler, then the emitter. No I/O (main.zig reads and writes).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const compile = @import("compile.zig");
const emit = @import("emit.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;

pub const Input = compile.Input;

pub const Output = struct {
    /// `Module.roc`, beside its `Module.sql`; `Database.roc`.
    name: []const u8,
    text: []const u8,
};

/// The modules for `queries` (each `Module.sql`, sorted by name) against
/// `schema`, and `Database.roc` last; empty when `diagnostics` is not ok.
pub fn generate(
    arena: Allocator,
    schema: Input,
    queries: []const Input,
    diagnostics: *Diagnostics,
) ![]const Output {
    assert(std.mem.eql(u8, schema.name, "schema.sql"));
    for (queries[0..queries.len -| 1], 1..) |query, next| {
        assert(std.mem.order(u8, query.name, queries[next].name) == .lt);
    }
    const compiled = try compile.compile(arena, schema, queries, diagnostics);
    if (!diagnostics.ok()) return &.{};
    const statements = compiled.statements;
    const outputs = try arena.alloc(Output, queries.len + 1);
    var first: u32 = 0;
    for (queries, 1.., outputs[0..queries.len]) |query, file, *output| {
        var end = first;
        while (end < statements.len and statements[end].file == file) end += 1;
        var text: std.Io.Writer.Allocating = .init(arena);
        try emit.write_module(&text.writer, query, statements[first..end], first);
        const module = query.name[0 .. query.name.len - ".sql".len];
        const name = try std.fmt.allocPrint(arena, "{s}.roc", .{module});
        output.* = .{ .name = name, .text = text.written() };
        first = end;
    }
    assert(first == statements.len); // every statement belongs to a file
    var database: std.Io.Writer.Allocating = .init(arena);
    try emit.write_database(&database.writer, schema, queries, statements);
    outputs[queries.len] = .{ .name = "Database.roc", .text = database.written() };
    return outputs;
}
