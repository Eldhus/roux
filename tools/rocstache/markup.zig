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

/// What a template's markup gets wrong, at most this many.
pub const problems_max = 64;

/// A problem in the markup, by SuperHTML's rules (all of them).
pub const Problem = struct {
    offset: u32,
    length: u32,
    message: []const u8,
    /// SuperHTML's warnings (an unsupported doctype, a duplicate class);
    /// the rest are errors.
    warning: bool,
};

/// The markup's problems, less any on a tag: SuperHTML sees a tag as
/// spaces, so what it says of one (an attribute's value "cannot be
/// empty") is about what roux fills in, which it cannot judge. The
/// template alone; pages.zig checks it as the pages that render it.
pub fn check(arena: Allocator, source: []const u8) Allocator.Error![]const Problem {
    const blanked = try arena.alloc(u8, source.len);
    blank(source, blanked);
    var problems: std.ArrayList(Problem) = .empty;
    for (try problems_in(arena, blanked)) |problem| {
        const end = problem.offset + problem.length;
        if (!on_tag(source, problem.offset, end)) try problems.append(arena, problem);
    }
    return problems.items;
}

/// SuperHTML's problems in markup whose tags are blanked (a template's,
/// or a page's with its partials in place), at most `problems_max`.
pub fn problems_in(arena: Allocator, blanked: []const u8) Allocator.Error![]const Problem {
    const ast = try superhtml.html.Ast.init(arena, blanked, .html, false);
    const count = @min(ast.errors.len, problems_max);
    const problems = try arena.alloc(Problem, count);
    for (ast.errors[0..count], problems) |err, *problem| {
        const location = err.main_location;
        assert(location.start <= location.end and location.end <= blanked.len);
        problem.* = .{
            .offset = location.start,
            .length = location.end - location.start,
            .message = try std.fmt.allocPrint(arena, "{f}", .{err.tag.fmt(blanked)}),
            .warning = switch (err.tag) {
                .unsupported_doctype, .duplicate_class => true,
                else => false,
            },
        };
    }
    return problems;
}

/// Whether `start..end` (a point when empty) touches a tag or the block.
pub fn on_tag(source: []const u8, start: u32, end: u32) bool {
    var tags: parse.Tags = .{ .source = source };
    while (tags.next()) |found| {
        const tag_end: u32 = found.span.end orelse @intCast(source.len);
        if (start == end) {
            if (found.span.start <= start and start < tag_end) return true;
        } else if (start < tag_end and found.span.start < end) return true;
    }
    return false;
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

test "markup: problems by SuperHTML's rules, none on a tag" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A value roux fills in is not judged: blanked, it would be empty.
    const filled = "<img src=\"{{ url }}\" alt=\"\"><p id=\"{{ id }}\">x</p>";
    try testing.expectEqual(@as(usize, 0), (try check(arena, filled)).len);
    // An unclosed element, past a tag: on the `<p`.
    const unclosed = "<div>{{ a }}<p>x</div>";
    const problems = try check(arena, unclosed);
    try testing.expectEqual(@as(usize, 1), problems.len);
    try testing.expectEqual(@as(u32, 13), problems[0].offset);
    try testing.expectEqualStrings("missing end tag", problems[0].message);
    try testing.expect(!problems[0].warning);
    // An element's rules: a required attribute missing.
    const no_alt = "{{#xs |x|}}<img src=\"/a.png\">{{/xs}}";
    const missing = try check(arena, no_alt);
    try testing.expectEqual(@as(usize, 1), missing.len);
    try testing.expect(std.mem.indexOf(u8, missing[0].message, "alt") != null);
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
