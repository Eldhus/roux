//! roux-db: an app's typed queries, generated as rocstache compiles
//! templates.
//!
//!   roux-db gen DIR
//!
//! DIR holds `schema.sql` (CREATE statements, STRICT tables) and query
//! files, `Module.sql` each; roux-db writes `Module.roc` beside each and
//! `Database.roc`, leaving a file untouched when its text would not change.
//! Problems are printed as `DIR/file:line:column: message`, all of them,
//! and nothing is written. No migrations yet (TODO.md, M5).

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const gen = @import("gen.zig");
const compile = @import("compile.zig");
const diagnostics_module = @import("diagnostics.zig");
const Diagnostics = diagnostics_module.Diagnostics;

const usage = "usage: roux-db gen DIR\n";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3 or !std.mem.eql(u8, args[1], "gen")) fatal(usage, .{});
    const dir_path = args[2];
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err|
        fatal("roux-db: {s}: {t}\n", .{ dir_path, err });
    defer dir.close(io);
    const schema_text = try read(io, arena, dir, "schema.sql");
    const schema: gen.Input = .{ .name = "schema.sql", .text = schema_text };
    const queries = try read_queries(io, arena, dir);
    var diagnostics = Diagnostics.init(arena);
    const outputs = try gen.generate(arena, schema, queries, &diagnostics);
    if (!diagnostics.ok()) {
        report(dir_path, schema, queries, &diagnostics);
        std.process.exit(1);
    }
    for (outputs) |output| try write_if_changed(io, arena, dir, output);
}

fn read(io: Io, arena: Allocator, dir: Io.Dir, name: []const u8) ![]const u8 {
    return dir.readFileAlloc(io, name, arena, .limited(compile.file_bytes_max)) catch |err|
        switch (err) {
            error.FileNotFound => fatal("roux-db: no {s}\n", .{name}),
            error.StreamTooLong => fatal("roux-db: {s}: over {d} bytes\n", .{
                name, compile.file_bytes_max,
            }),
            else => return err,
        };
}

/// Every `*.sql` but schema.sql, sorted by name, so statements are
/// numbered the same on every machine.
fn read_queries(io: Io, arena: Allocator, dir: Io.Dir) ![]const gen.Input {
    var list: std.ArrayList(gen.Input) = try .initCapacity(arena, compile.files_max);
    var iterator = dir.iterate();
    // A directory of more entries than this is not a database directory.
    const entries_max = 4096;
    for (0..entries_max) |_| {
        const entry = try iterator.next(io) orelse break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sql")) continue;
        if (std.mem.eql(u8, entry.name, "schema.sql")) continue;
        if (list.items.len == compile.files_max) {
            fatal("roux-db: more than {d} query files\n", .{compile.files_max});
        }
        const name = try arena.dupe(u8, entry.name);
        list.appendAssumeCapacity(.{ .name = name, .text = try read(io, arena, dir, name) });
    } else fatal("roux-db: more than {d} entries in the directory\n", .{entries_max});
    std.mem.sort(gen.Input, list.items, {}, by_name);
    return list.items;
}

fn by_name(_: void, a: gen.Input, b: gen.Input) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn report(
    dir_path: []const u8,
    schema: gen.Input,
    queries: []const gen.Input,
    diagnostics: *const Diagnostics,
) void {
    for (diagnostics.items()) |diagnostic| {
        const input = if (diagnostic.file == 0) schema else queries[diagnostic.file - 1];
        const at = diagnostics_module.position(input.text, diagnostic.offset);
        std.debug.print("{s}/{s}:{d}:{d}: {s}\n", .{
            dir_path, input.name, at.line, at.column, diagnostic.message,
        });
    }
    if (diagnostics.dropped > 0) std.debug.print("...and {d} more\n", .{diagnostics.dropped});
}

/// Writes through a temporary file renamed over the old one, and not at
/// all when the text is the same (so a build sees no change).
fn write_if_changed(io: Io, arena: Allocator, dir: Io.Dir, output: gen.Output) !void {
    const limit: Io.Limit = .limited(compile.file_bytes_max * 4);
    const old = dir.readFileAlloc(io, output.name, arena, limit) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (old) |text| if (std.mem.eql(u8, text, output.text)) return;
    const temporary = try std.fmt.allocPrint(arena, "{s}.tmp", .{output.name});
    try dir.writeFile(io, .{ .sub_path = temporary, .data = output.text });
    errdefer dir.deleteFile(io, temporary) catch {};
    try dir.rename(temporary, dir, output.name, io);
}

fn fatal(comptime format: []const u8, arguments: anytype) noreturn {
    std.debug.print(format, arguments);
    std.process.exit(2);
}
