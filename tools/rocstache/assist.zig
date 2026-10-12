//! What the language server says about a point of a template, read from
//! its analysis (analysis.zig): the contract decides every type, as it
//! does for `roux build`. A hover's text: the type of the path segment
//! under the cursor, what a formatter does, what a partial reads.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");
const contract_ = @import("contract.zig");
const analysis = @import("analysis.zig");

/// Markdown about what is at `offset` of the checked template. Null over
/// text, and when the template has a problem: no contract to read from.
pub fn hover(arena: Allocator, result: analysis.Analysis, offset: u32) Allocator.Error!?[]const u8 {
    const contract = result.contract orelse return null;
    const self = result.templates[0];
    assert(offset <= self.source.len);
    const node = for (self.tree.slice()) |*node| {
        if (node.kind == .text) continue;
        if (node.offset <= offset and offset < node.offset + node.length) break node;
    } else return null;
    const scopes = analysis.scopes_at(contract, self.tree, self.source, node.offset);
    const path = node.path_slice();
    for (path, 0..) |segment, k| {
        if (!within(self.source, segment, offset)) continue;
        const target = analysis.lookup(contract, scopes.slice(), node.up, path[0 .. k + 1]) orelse
            return null;
        return try typed(arena, contract, segment, target);
    }
    for (node.pipe_slice()) |pipe| {
        if (within(self.source, pipe.name, offset)) return formatter_text(pipe.formatter);
    }
    if (node.kind == .partial) return try partial_text(arena, result, node);
    // Elsewhere in the tag (its braces, `#`, `../`): the whole path's type.
    const target = analysis.lookup(contract, scopes.slice(), node.up, path) orelse return null;
    return try typed(arena, contract, node.text, target);
}

/// Whether `offset` is on `piece`, a slice of `source`, or just after it.
fn within(source: []const u8, piece: []const u8, offset: u32) bool {
    if (piece.len == 0) return false;
    const start = @intFromPtr(piece.ptr) - @intFromPtr(source.ptr);
    assert(start + piece.len <= source.len);
    return offset >= start and offset <= start + piece.len;
}

/// `label : Type`, as Roc writes it.
fn typed(
    arena: Allocator,
    contract: *const contract_.Contract,
    label: []const u8,
    index: u16,
) Allocator.Error![]const u8 {
    var line: std.Io.Writer.Allocating = .init(arena);
    contract_.write_line(contract, index, &line.writer) catch return error.OutOfMemory;
    return arena.print("```roc\n{s} : {s}\n```", .{ label, line.written() });
}

fn formatter_text(formatter: parse.Formatter) []const u8 {
    return switch (formatter) {
        .len => "`len`: a list's length, a number; `| len | plural \"dish\" \"dishes\"` " ++
            "names it.",
        .plural => "`plural \"one\" \"many\"`: the number, a space, and the noun that fits " ++
            "it: `1 dish`, `3 dishes`.",
        .upper => "`upper`: the Str in upper case.",
        .lower => "`lower`: the Str in lower case.",
        .url => "`url`: the Str percent-encoded, for a URL's path segment or query value.",
    };
}

/// An inlined partial reads this scope; a called one has its own contract.
fn partial_text(
    arena: Allocator,
    result: analysis.Analysis,
    node: *const parse.Node,
) Allocator.Error![]const u8 {
    assert(node.kind == .partial);
    if (!node.called()) {
        return arena.print("`{s}.rocstache`, inlined: its tags read this scope, so what " ++
            "it reads is in this template's contract.", .{node.text});
    }
    const included = for (result.templates) |t| {
        if (std.mem.eql(u8, t.name, node.text)) break t;
    } else unreachable; // the analysis found it, or it would have a problem
    const theirs = included.contract.?;
    var line: std.Io.Writer.Allocating = .init(arena);
    contract_.write_line(theirs, theirs.root, &line.writer) catch return error.OutOfMemory;
    const up = try arena.alloc(u8, 3 * @as(usize, node.up));
    for (0..node.up) |k| @memcpy(up[3 * k ..][0..3], "../");
    const path = try std.mem.join(arena, ".", node.path_slice());
    return arena.print("`{s}.rocstache`, called with `{s}{s}` as its context:\n" ++
        "```roc\n{s}.Ctx : {s}\n```", .{ node.text, up, path, node.text, line.written() });
}

const testing = std.testing;

test "assist: hover shows the segment's type, a formatter, a partial" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const top: analysis.Buffer = .{
        .path = "/app/templates/Top.rocstache",
        .text = "<title>{{ title }}</title>",
    };
    const page = "{{> Top frame}}{{#items}}{{ name.first | upper }}{{ ../n | len }}" ++
        "{{/items}}{{> Top frame}}";
    const result = try analysis.analyze(arena, testing.io, .{
        .path = "/app/templates/Page.rocstache",
        .source = page,
        .buffers = &.{top},
    });
    const cases = [_]struct { on: []const u8, expected: []const u8 }{
        .{ .on = "items", .expected = "```roc\nitems : List({ name : { first : Str } })\n```" },
        .{ .on = "name", .expected = "```roc\nname : { first : Str }\n```" },
        .{ .on = "first", .expected = "```roc\nfirst : Str\n```" },
        .{ .on = "upper", .expected = "`upper`: the Str in upper case." },
        .{ .on = "{{ ../n", .expected = "```roc\n../n : List(Str)\n```" },
        .{ .on = "frame", .expected = "```roc\nframe : { title : Str }\n```" },
        .{
            .on = "Top",
            .expected = "`Top.rocstache`, called with `frame` as its context:\n" ++
                "```roc\nTop.Ctx : { title : Str }\n```",
        },
    };
    for (cases) |case| {
        const offset: u32 = @intCast(std.mem.indexOf(u8, page, case.on).? + 1);
        const text = (try hover(arena, result, offset)).?;
        try testing.expectEqualStrings(case.expected, text);
    }
}

test "assist: no hover over text, nor in a template with a problem" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const options = [_]analysis.Options{
        .{ .path = "/app/templates/Page.rocstache", .source = "<p>{{ a }}</p>", .buffers = &.{} },
        .{ .path = "/app/templates/Page.rocstache", .source = "{{ a }}{{ a.b }}", .buffers = &.{} },
    };
    for (options) |option| {
        const result = try analysis.analyze(arena, testing.io, option);
        try testing.expectEqual(@as(?[]const u8, null), try hover(arena, result, 1));
    }
}
