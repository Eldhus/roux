//! The rocstache parser, one for every use: Zig runs it at comptime to
//! compile a template (render.zig), and at run time for the contract
//! (contract.zig) and the language server. It allocates nothing: the tree
//! is fixed-capacity arrays, so comptime can build it too.
//!
//! The tree is flat, in source order: a section's body is the nodes after
//! it up to its `end`, so a walk jumps from a node to `node.end`.
//!
//! The language:
//!
//! | tag | what |
//! |---|---|
//! | `{{ a.b }}` | a value, HTML-escaped; `{{{ a }}}` unescaped |
//! | `{{ a \| len \| plural "dish" "dishes" }}` | a value through formatters |
//! | `{{#a}}…{{/a}}` | a list's elements, a record's fields, or a Bool when true |
//! | `{{^a}}…{{/a}}` | when the list is empty or the Bool false |
//! | `{{?a}}…{{/a}}` | when the Bool is true, in the same scope |
//! | `{{> Name}}` | the template `Name.rocstache`, in the same scope |
//! | `{{../a}}`, `{{.}}` | a field of the enclosing scope; the element itself |
//! | `{{! … }}` | a comment |
//! | `{{% … %}}` | first in the file only: the contract, `Ctx : { … }` |

const std = @import("std");
const assert = std.debug.assert;

pub const nodes_max = 1024;
pub const path_max = 4;
pub const pipes_max = 3;
pub const args_max = 2;
pub const depth_max = 16;
pub const source_bytes_max = 1 << 20;

pub const Kind = enum(u8) { text, value, section, inverted, conditional, partial };

pub const Formatter = enum(u8) {
    /// A list's length.
    len,
    /// A count and a noun: `plural "dish" "dishes"`.
    plural,
    upper,
    lower,
    /// Percent-encoded for a URL's path segment or query value.
    url,

    pub fn args_count(formatter: Formatter) u8 {
        return if (formatter == .plural) 2 else 0;
    }
};

pub const formatters_known = "len, plural, upper, lower, url";

pub const Pipe = struct {
    formatter: Formatter,
    args: [args_max][]const u8 = @splat(""),
};

pub const Node = struct {
    kind: Kind,
    /// `text`: the bytes. `partial`: the template's name. Otherwise the
    /// tag's path as written.
    text: []const u8,
    /// Byte offset of the tag in the source, for messages.
    offset: u32,
    /// How many `../` precede the path.
    up: u8 = 0,
    path: [path_max][]const u8 = @splat(""),
    path_len: u8 = 0,
    escape: bool = true,
    pipes: [pipes_max]Pipe = undefined,
    pipes_len: u8 = 0,
    /// Index one past this node's subtree (`index + 1` for a leaf).
    end: u16 = 0,

    pub fn path_slice(node: *const Node) []const []const u8 {
        return node.path[0..node.path_len];
    }

    pub fn pipe_slice(node: *const Node) []const Pipe {
        return node.pipes[0..node.pipes_len];
    }
};

pub const Tree = struct {
    nodes: [nodes_max]Node = undefined,
    len: u16 = 0,
    /// The `{{% %}}` block's inside, or "" when there is none.
    block: []const u8 = "",
    block_offset: u32 = 0,

    pub fn slice(tree: *const Tree) []const Node {
        return tree.nodes[0..tree.len];
    }
};

pub const Diagnostic = struct {
    offset: u32 = 0,
    message: []const u8 = "",
    /// What the message is about, as written (a tag's path, a name).
    subject: []const u8 = "",

    pub fn line(diagnostic: Diagnostic, source: []const u8) u32 {
        const before = source[0..@min(diagnostic.offset, source.len)];
        return @intCast(std.mem.count(u8, before, "\n") + 1);
    }

    pub fn column(diagnostic: Diagnostic, source: []const u8) u32 {
        const before = source[0..@min(diagnostic.offset, source.len)];
        const line_start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |n| n + 1 else 0;
        return @intCast(before.len - line_start + 1);
    }
};

pub const Error = error{Invalid};

pub fn parse(source: []const u8, tree: *Tree, diagnostic: *Diagnostic) Error!void {
    if (source.len > source_bytes_max) return fail(diagnostic, 0, "the template is too large", "");
    tree.* = .{};
    var open: [depth_max]u16 = undefined;
    var open_len: usize = 0;
    var at: usize = try skip_block(source, tree, diagnostic);
    var text_start = at;
    while (std.mem.indexOfPos(u8, source, at, "{{")) |tag_start| {
        const found = try bounds(source, tag_start, diagnostic);
        // A standalone tag takes its whole line with it (Mustache's rule).
        const line = standalone(source, text_start, tag_start, found);
        const text_end = if (line) |l| l.start else tag_start;
        if (text_end > text_start) {
            try push_text(tree, source[text_start..text_end], text_start, diagnostic);
        }
        try add_tag(found, tag_start, tree, &open, &open_len, diagnostic);
        at = if (line) |l| l.after else found.end;
        text_start = at;
    }
    if (open_len != 0) {
        const section = tree.nodes[open[open_len - 1]];
        return fail(diagnostic, section.offset, "is never closed", section.text);
    }
    if (source.len > text_start) {
        try push_text(tree, source[text_start..], text_start, diagnostic);
    }
    assert(tree.len <= nodes_max);
}

/// The `{{% %}}` block, if the file starts with one: recorded, and the
/// newline after it is part of it. Returns where the template's text begins.
fn skip_block(source: []const u8, tree: *Tree, diagnostic: *Diagnostic) Error!usize {
    if (!std.mem.startsWith(u8, source, "{{%")) return 0;
    const end = std.mem.indexOfPos(u8, source, 3, "%}}") orelse
        return fail(diagnostic, 0, "a `{{%` block that never closes", "");
    tree.block = source[3..end];
    tree.block_offset = 3;
    const after = end + 3;
    if (std.mem.startsWith(u8, source[after..], "\r\n")) return after + 2;
    return if (after < source.len and source[after] == '\n') after + 1 else after;
}

const Bounds = struct {
    /// What is between the braces, trimmed.
    inner: []const u8,
    /// The offset after the tag.
    end: usize,
    triple: bool,
};

/// The tag at `start`.
fn bounds(source: []const u8, start: usize, diagnostic: *Diagnostic) Error!Bounds {
    const triple = std.mem.startsWith(u8, source[start..], "{{{");
    const close: []const u8 = if (triple) "}}}" else "}}";
    const inner_start = start + close.len;
    const inner_end = std.mem.indexOfPos(u8, source, inner_start, close) orelse
        return fail(diagnostic, start, "a tag that never closes", "");
    const inner = std.mem.trim(u8, source[inner_start..inner_end], " \t");
    if (inner.len == 0) return fail(diagnostic, start, "an empty tag", "");
    return .{ .inner = inner, .end = inner_end + close.len, .triple = triple };
}

const Line = struct {
    /// Where the tag's line starts.
    start: usize,
    /// After its line break (or the end of the file).
    after: usize,
};

/// The tag's line, when the tag stands alone on it: a section, inverted,
/// conditional or closing tag, a comment or a partial, with only spaces or
/// tabs around it, and no other tag earlier on the line (`text_start` is
/// after the last tag). The template then reads as written in a file, a
/// tag a line, without blank lines where the tags were.
fn standalone(source: []const u8, text_start: usize, tag_start: usize, found: Bounds) ?Line {
    if (found.triple) return null;
    switch (found.inner[0]) {
        '#', '^', '?', '/', '!', '>' => {},
        else => return null,
    }
    const before = source[0..tag_start];
    const line_start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |n| n + 1 else 0;
    if (line_start < text_start) return null;
    if (std.mem.trim(u8, source[line_start..tag_start], " \t").len != 0) return null;
    var after = found.end;
    while (after < source.len and (source[after] == ' ' or source[after] == '\t')) after += 1;
    const rest = source[after..];
    const line_break: usize = if (rest.len == 0)
        0
    else if (rest[0] == '\n')
        1
    else if (std.mem.startsWith(u8, rest, "\r\n")) 2 else return null;
    return .{ .start = line_start, .after = after + line_break };
}

/// The tag `found` at `start`, into the tree.
fn add_tag(
    found: Bounds,
    start: usize,
    tree: *Tree,
    open: *[depth_max]u16,
    open_len: *usize,
    diagnostic: *Diagnostic,
) Error!void {
    const inner = found.inner;
    const triple = found.triple;
    const rest = std.mem.trim(u8, inner[1..], " \t");
    if (triple and inner[0] != '!' and !is_path_start(inner[0])) {
        return fail(diagnostic, start, "`{{{ }}}` takes a value", inner);
    }
    switch (inner[0]) {
        '!' => {},
        '%' => return fail(diagnostic, start, "a `{{%` block must come first in the file", ""),
        '/' => try close_section(tree, open, open_len, rest, start, diagnostic),
        '#', '^', '?' => {
            if (open_len.* == depth_max) {
                return fail(diagnostic, start, "sections nest too deep", rest);
            }
            var node = try path_node(rest, start, diagnostic);
            node.kind = switch (inner[0]) {
                '#' => .section,
                '^' => .inverted,
                '?' => .conditional,
                else => unreachable,
            };
            if (node.kind == .conditional and node.path_len == 0) {
                return fail(diagnostic, start, "`{{?}}` takes a Bool field, not `.`", rest);
            }
            open[open_len.*] = tree.len;
            open_len.* += 1;
            try push(tree, node, diagnostic);
        },
        '>' => {
            if (!is_type_name(rest)) {
                return fail(diagnostic, start, "a partial is a template's name, like `Top`", rest);
            }
            try push(tree, .{
                .kind = .partial,
                .text = rest,
                .offset = @intCast(start),
                .end = tree.len + 1,
            }, diagnostic);
        },
        else => {
            var node = try value_node(inner, start, diagnostic);
            node.escape = !triple;
            node.end = tree.len + 1;
            try push(tree, node, diagnostic);
        },
    }
}

fn close_section(
    tree: *Tree,
    open: *[depth_max]u16,
    open_len: *usize,
    what: []const u8,
    offset: usize,
    diagnostic: *Diagnostic,
) Error!void {
    if (open_len.* == 0) return fail(diagnostic, offset, "closes nothing open", what);
    const section = &tree.nodes[open[open_len.* - 1]];
    if (!std.mem.eql(u8, what, section.text)) {
        return fail(diagnostic, offset, "closes a different section than the one open", what);
    }
    section.end = tree.len;
    open_len.* -= 1;
}

fn push(tree: *Tree, node: Node, diagnostic: *Diagnostic) Error!void {
    if (tree.len == nodes_max) {
        return fail(diagnostic, node.offset, "the template has too many tags", "");
    }
    tree.nodes[tree.len] = node;
    tree.len += 1;
}

fn push_text(tree: *Tree, text: []const u8, offset: usize, diagnostic: *Diagnostic) Error!void {
    assert(text.len > 0);
    try push(tree, .{
        .kind = .text,
        .text = text,
        .offset = @intCast(offset),
        .end = tree.len + 1,
    }, diagnostic);
}

/// `path | formatter "arg" | formatter`.
fn value_node(inner: []const u8, offset: usize, diagnostic: *Diagnostic) Error!Node {
    var pieces = std.mem.splitScalar(u8, inner, '|');
    const head = std.mem.trim(u8, pieces.first(), " \t");
    var node = try path_node(head, offset, diagnostic);
    while (pieces.next()) |piece| {
        if (node.pipes_len == pipes_max) {
            return fail(diagnostic, offset, "too many formatters", head);
        }
        node.pipes[node.pipes_len] = try pipe(std.mem.trim(u8, piece, " \t"), offset, diagnostic);
        node.pipes_len += 1;
    }
    if (!chain_valid(node.pipe_slice())) return fail(diagnostic, offset, chain_message, head);
    return node;
}

const chain_message = "formatters chain as `len`, then `plural`; or one of `upper`, `lower`, `url`";

/// Each formatter writes its output straight into the page, so a chain
/// never builds an intermediate string: `len`, `plural`, `len | plural`,
/// or one of `upper`, `lower`, `url` alone.
fn chain_valid(pipes: []const Pipe) bool {
    if (pipes.len <= 1) return true;
    return pipes.len == 2 and pipes[0].formatter == .len and pipes[1].formatter == .plural;
}

fn path_node(written: []const u8, offset: usize, diagnostic: *Diagnostic) Error!Node {
    var node: Node = .{ .kind = .value, .text = written, .offset = @intCast(offset) };
    var rest = written;
    while (std.mem.startsWith(u8, rest, "../")) {
        if (node.up == depth_max) return fail(diagnostic, offset, "climbs too far", written);
        rest = rest[3..];
        node.up += 1;
    }
    if (rest.len == 0) return fail(diagnostic, offset, "a tag with no name", written);
    if (std.mem.eql(u8, rest, ".")) return node;
    var parts = std.mem.splitScalar(u8, rest, '.');
    while (parts.next()) |part| {
        if (node.path_len == path_max) return fail(diagnostic, offset, "a path too long", written);
        if (!is_field_name(part)) {
            return fail(diagnostic, offset, "is not a field name (like `title`)", written);
        }
        node.path[node.path_len] = part;
        node.path_len += 1;
    }
    return node;
}

/// `name "arg" "arg"`: arguments are string literals, without escapes.
fn pipe(piece: []const u8, offset: usize, diagnostic: *Diagnostic) Error!Pipe {
    const name_end = std.mem.indexOfAny(u8, piece, " \t") orelse piece.len;
    const name = piece[0..name_end];
    if (name.len == 0) return fail(diagnostic, offset, "an empty formatter", "");
    const formatter = std.meta.stringToEnum(Formatter, name) orelse return fail(
        diagnostic,
        offset,
        "is not a formatter (" ++ formatters_known ++ "): compute it in Roc, into a field",
        name,
    );
    var result: Pipe = .{ .formatter = formatter };
    var args_len: u8 = 0;
    var rest = std.mem.trim(u8, piece[name_end..], " \t");
    while (rest.len > 0) {
        if (rest[0] != '"') {
            return fail(diagnostic, offset, "a formatter's argument is a \"string\"", rest);
        }
        const close = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse
            return fail(diagnostic, offset, "a string that never closes", rest);
        if (args_len == args_max) return fail(diagnostic, offset, "too many arguments", name);
        result.args[args_len] = rest[1..close];
        args_len += 1;
        rest = std.mem.trim(u8, rest[close + 1 ..], " \t");
    }
    if (args_len != formatter.args_count()) {
        return fail(diagnostic, offset, "takes another number of arguments", name);
    }
    return result;
}

fn is_path_start(c: u8) bool {
    return std.ascii.isLower(c) or c == '_' or c == '.';
}

pub fn is_field_name(s: []const u8) bool {
    if (s.len == 0 or !(std.ascii.isLower(s[0]) or s[0] == '_')) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

pub fn is_type_name(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isUpper(s[0])) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

fn fail(diagnostic: *Diagnostic, offset: usize, message: []const u8, subject: []const u8) Error {
    diagnostic.* = .{ .offset = @intCast(offset), .message = message, .subject = subject };
    return error.Invalid;
}

const testing = std.testing;

test "parse: sections nest, the block is recorded and skipped" {
    var tree: Tree = .{};
    var diagnostic: Diagnostic = .{};
    const source = "{{%\nCtx : { a : List({ b : { c : Str } }) }\n%}}\n" ++
        "<p>{{#a}}{{ b.c | upper }}{{/a}}{{^a}}none{{/a}}</p>";
    try parse(source, &tree, &diagnostic);
    const n = tree.slice();
    try testing.expectEqual(@as(usize, 6), n.len);
    try testing.expectEqualStrings("\nCtx : { a : List({ b : { c : Str } }) }\n", tree.block);
    try testing.expectEqualStrings("<p>", n[0].text);
    try testing.expectEqual(Kind.section, n[1].kind);
    try testing.expectEqual(@as(u16, 3), n[1].end);
    try testing.expectEqualStrings("c", n[2].path_slice()[1]);
    try testing.expectEqual(Formatter.upper, n[2].pipes[0].formatter);
    try testing.expectEqual(Kind.inverted, n[3].kind);
    try testing.expectEqual(@as(u16, 5), n[3].end);
}

test "parse: partials, conditionals, raw values, parents, arguments with spaces" {
    var tree: Tree = .{};
    var diagnostic: Diagnostic = .{};
    const source = "{{> Top}}{{?home}}{{{ html }}}{{/home}}" ++
        "{{#xs}}{{ ../n | plural \"a dish\" \"dishes\" }}" ++
        "{{.}}{{/xs}}{{! note }}";
    try parse(source, &tree, &diagnostic);
    const n = tree.slice();
    try testing.expectEqual(@as(usize, 6), n.len);
    try testing.expectEqual(Kind.partial, n[0].kind);
    try testing.expectEqualStrings("Top", n[0].text);
    try testing.expectEqual(Kind.conditional, n[1].kind);
    try testing.expect(!n[2].escape);
    try testing.expectEqual(@as(u8, 1), n[4].up);
    try testing.expectEqualStrings("a dish", n[4].pipes[0].args[0]);
    try testing.expectEqual(@as(u8, 0), n[5].path_len);
}

test "parse: a tag alone on its line takes the line with it" {
    var tree: Tree = .{};
    var diagnostic: Diagnostic = .{};
    // Standalone: `{{#a}}`, `  {{/a}}` (indented), `{{> Bottom}}` at the
    // end. Not: `{{ x }}` (a value), `<p>{{#b}}` (text before it).
    const source = "{{#a}}\n<li>{{ x }}</li>\n  {{/a}}\n<p>{{#b}}y{{/b}}</p>\n{{> Bottom}}\n";
    try parse(source, &tree, &diagnostic);
    const n = tree.slice();
    try testing.expectEqualStrings("<li>", n[1].text);
    try testing.expectEqualStrings("</li>\n", n[3].text);
    try testing.expectEqualStrings("<p>", n[4].text);
    try testing.expectEqualStrings("</p>\n", n[7].text);
    try testing.expectEqual(Kind.partial, n[8].kind);
    try testing.expectEqual(@as(u16, 9), tree.len);
}

test "parse: each mistake says where and what" {
    const cases = [_]struct { source: []const u8, line: u32, subject: []const u8 }{
        .{ .source = "a\n{{#x}}b", .line = 2, .subject = "x" },
        .{ .source = "{{#x}}{{/y}}", .line = 1, .subject = "y" },
        .{ .source = "\n\n{{ x | bold }}", .line = 3, .subject = "bold" },
        .{ .source = "{{ X }}", .line = 1, .subject = "X" },
        .{ .source = "{{> top}}", .line = 1, .subject = "top" },
        .{ .source = "{{ n | plural \"one\" }}", .line = 1, .subject = "plural" },
        .{ .source = "{{ n | plural \"a\" \"b\" | upper }}", .line = 1, .subject = "n" },
        .{ .source = "x\n{{% Ctx : {} %}}", .line = 2, .subject = "" },
    };
    for (cases) |case| {
        var tree: Tree = .{};
        var diagnostic: Diagnostic = .{};
        try testing.expectError(error.Invalid, parse(case.source, &tree, &diagnostic));
        try testing.expectEqual(case.line, diagnostic.line(case.source));
        try testing.expectEqualStrings(case.subject, diagnostic.subject);
    }
}

test "parse: at comptime" {
    const tree = comptime blk: {
        var t: Tree = .{};
        var d: Diagnostic = .{};
        parse("<b>{{ x }}</b>", &t, &d) catch unreachable;
        break :blk t;
    };
    try testing.expectEqual(@as(u16, 3), tree.len);
}
