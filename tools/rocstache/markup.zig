//! The markup between a template's tags, answered by SuperHTML
//! (vendor/superhtml), for the language server: HTML's elements and
//! attributes, completed and described.
//!
//! SuperHTML reads the template with every tag and the `{{% %}}` block
//! blanked to spaces, line breaks kept, so a byte offset means the same in
//! both; what it answers carries no offsets, so nothing is mapped back.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const superhtml = @import("superhtml");
const parse = @import("parse.zig");

/// A completion, as SuperHTML's own server sends it.
pub const Item = struct {
    label: []const u8,
    /// Markdown; empty when SuperHTML has none.
    description: []const u8,
    /// What is inserted, when not the label.
    insert: ?[]const u8,
    /// An element's opening or closing; else an attribute or its value.
    element: bool,
    /// An element's opening: `insert` is a snippet.
    snippet: bool,
};

/// The source with its tags and block blanked: `out` is as long as it.
pub fn blank(source: []const u8, out: []u8) void {
    assert(out.len == source.len);
    @memcpy(out, source);
    var tags: parse.Tags = .{ .source = source };
    while (tags.next()) |found| {
        const end = found.span.end orelse source.len;
        assert(found.span.start < end);
        for (out[found.span.start..end]) |*byte| {
            if (byte.* != '\n' and byte.* != '\r') byte.* = ' ';
        }
    }
}

/// HTML's completions at `offset`, in markup; none in a tag.
pub fn complete(arena: Allocator, source: []const u8, offset: u32) Allocator.Error![]const Item {
    assert(offset <= source.len);
    if (parse.tag_at(source, offset) != null) return &.{};
    const blanked = try arena.alloc(u8, source.len);
    blank(source, blanked);
    const ast = try superhtml.html.Ast.init(arena, blanked, .html, false);
    const found = try ast.completions(arena, blanked, offset);
    const items = try arena.alloc(Item, found.len);
    for (found, items) |completion, *item| {
        const opening = completion.kind == .element_open;
        item.* = .{
            .label = completion.label,
            .description = completion.desc,
            .insert = insert_text(blanked, offset, completion),
            .element = completion.kind != .attribute,
            .snippet = opening and completion.value != null,
        };
    }
    return items;
}

/// SuperHTML's rule (its server's completion handler): an element's
/// snippet brings its `>` and closing tag, unless a `>` already follows
/// on the line, when the name alone is inserted.
fn insert_text(
    source: []const u8,
    offset: u32,
    completion: superhtml.html.Ast.Completion,
) ?[]const u8 {
    const value = completion.value orelse return null;
    if (completion.kind != .element_open) return value;
    const rest = source[offset..];
    const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    if (std.mem.indexOfScalar(u8, rest[0..line_end], '>') == null) return value;
    assert(completion.label.len <= value.len);
    return value[0..completion.label.len];
}

/// What the element or attribute at `offset` is, as markdown; null in a
/// tag or elsewhere.
pub fn describe(arena: Allocator, source: []const u8, offset: u32) Allocator.Error!?[]const u8 {
    assert(offset <= source.len);
    if (parse.tag_at(source, offset) != null) return null;
    const blanked = try arena.alloc(u8, source.len);
    blank(source, blanked);
    const ast = try superhtml.html.Ast.init(arena, blanked, .html, false);
    return ast.description(blanked, offset);
}

const testing = std.testing;

test "markup: tags and the block blanked, line breaks kept" {
    const source = "{{% x %}}\n<p a=\"{{ v }}\">\n{{#xs |x|}}<i>{{ x }}</i>{{/xs}}\n{{ y";
    var out: [source.len]u8 = undefined;
    blank(source, &out);
    try testing.expectEqualStrings(
        "         \n<p a=\"       \">\n           <i>       </i>       \n    ",
        &out,
    );
}

test "markup: elements and attributes completed and described, never in a tag" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // An element's attributes, after a tag in its value.
    const attributes = "<ul>{{#xs |x|}}<li class=\"{{ x }}\" ></li>{{/xs}}</ul>";
    const at: u32 = @intCast(std.mem.indexOf(u8, attributes, "\" >").? + 2);
    const items = try complete(arena, attributes, at);
    try testing.expect(has(items, "id"));
    // Inside a tag, roux answers: nothing here.
    const in_tag: u32 = @intCast(std.mem.indexOf(u8, attributes, "x }}").?);
    try testing.expectEqual(@as(usize, 0), (try complete(arena, attributes, in_tag)).len);
    const described = (try describe(arena, attributes, 1)).?;
    try testing.expect(std.mem.indexOf(u8, described, "list") != null);
    try testing.expectEqual(@as(?[]const u8, null), try describe(arena, attributes, in_tag));
}

test "markup: an element's snippet, or its name alone before a `>`" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const open = "<ul>\n  <\n</ul>";
    const items = try complete(arena, open, 8); // after the `<`
    const li = find(items, "li").?;
    try testing.expect(li.snippet);
    try testing.expect(li.insert.?.len > "li".len);
    const closed = "<ul>\n  <>\n</ul>";
    try testing.expectEqualStrings("li", find(try complete(arena, closed, 8), "li").?.insert.?);
}

fn find(items: []const Item, label: []const u8) ?Item {
    for (items) |item| {
        if (std.mem.eql(u8, item.label, label)) return item;
    }
    return null;
}

fn has(items: []const Item, label: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.label, label)) return true;
    }
    return false;
}
