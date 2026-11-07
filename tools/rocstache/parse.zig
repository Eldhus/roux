//! The rocstache parser, one for every use: the contract (contract.zig),
//! the bytecode (bytecode.zig) and the language server. It allocates
//! nothing: the tree is fixed-capacity arrays.
//!
//! The tree is flat, in source order: a section's body is the nodes after
//! it up to its `end`, so a walk jumps from a node to `node.end`.

const std = @import("std");
const assert = std.debug.assert;
const hole = @import("hole.zig");

pub const nodes_max = 1024;
pub const path_max = 4;
pub const depth_max = 16;
pub const source_bytes_max = 1 << 20;

/// `fragment`: `{{$Row}} … {{/Row}}`, a part of the page that renders in
/// place and also alone, its contract what it reads of the scope where it
/// stands.
pub const Kind = enum(u8) { text, value, section, inverted, conditional, partial, fragment };

pub const Node = struct {
    kind: Kind,
    /// `text`: the bytes. `partial`: the template's name. Otherwise the
    /// tag's path as written.
    text: []const u8,
    /// Byte offset of the tag in the source, for messages.
    offset: u32,
    /// The tag's bytes, braces included, or the text's: what the language
    /// server underlines, and finds under the cursor.
    length: u32 = 0,
    /// `section`: the name it gives its element (`{{#dishes |dish|}}`).
    binder: []const u8 = "",
    /// Its head is a section's binder, or a field of the page's `Ctx`
    /// (`bound` finds which).
    path: [path_max][]const u8 = @splat(""),
    path_len: u8 = 0,
    escape: bool = true,
    /// A value that is a Roc expression (`dish.id.to_str()`), as written:
    /// compiled by Roc. Empty for a path, which the renderer reads.
    expression: []const u8 = "",
    /// Index one past this node's subtree (`index + 1` for a leaf).
    end: u16 = 0,

    pub fn path_slice(node: *const Node) []const []const u8 {
        return node.path[0..node.path_len];
    }

    /// A partial given its own context (`{{> Top frame}}`): compiled once,
    /// with its own contract, and called; else it is inlined.
    pub fn called(node: *const Node) bool {
        assert(node.kind == .partial);
        return node.path_len > 0;
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

/// Where a path's head leads: the open scope whose section names it, the
/// rest of the path read from there; else a field of the outermost scope,
/// the page's `Ctx`, the whole path read from it.
pub const Bound = struct {
    scope: usize,
    path: []const []const u8,
    /// The head is a binder (the scope's element), not a field.
    named: bool,
};

/// `binders`: each open scope's, outermost first ("" for the page's).
/// Binders shadow nothing (contract.zig refuses it), so the first found
/// is the only one.
pub fn bound(binders: []const []const u8, path: []const []const u8) Bound {
    assert(binders.len > 0);
    assert(path.len > 0);
    var k = binders.len;
    while (k > 0) {
        k -= 1;
        if (binders[k].len > 0 and std.mem.eql(u8, binders[k], path[0])) {
            return .{ .scope = k, .path = path[1..], .named = true };
        }
    }
    return .{ .scope = 0, .path = path, .named = false };
}

/// The binder of the scope a template's node stands in: its innermost
/// section's, or "" at the template's top.
pub fn binder_at(tree: *const Tree, index: u16) []const u8 {
    assert(index < tree.len);
    var binder: []const u8 = "";
    for (tree.nodes[0..index]) |node| {
        if (node.kind == .section and node.end > index) binder = node.binder;
    }
    return binder;
}

pub fn parse(source: []const u8, tree: *Tree, diagnostic: *Diagnostic) Error!void {
    if (source.len > source_bytes_max) return fail(diagnostic, 0, "the template is too large", "");
    // The header only: nodes are written as they are pushed (a whole `.{}`
    // would write all 1,024 of them in a safe build).
    tree.len = 0;
    tree.block = "";
    tree.block_offset = 0;
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
        const pushed = tree.len;
        try add_tag(found, tag_start, tree, &open, &open_len, diagnostic);
        // A comment or a closing tag pushes nothing; any other tag, one node.
        if (tree.len > pushed) {
            assert(tree.len == pushed + 1);
            tree.nodes[pushed].length = @intCast(found.end - tag_start);
        }
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

/// A tag's bytes: from its `{{` to after its closing braces; no end when
/// it never closes.
pub const Span = struct { start: u32, end: ?u32 };

/// The tag around `offset` (after its `{{`, up to its closing braces),
/// found as `parse` finds tags; null in text or in the `{{% %}}` block.
/// For the language server, whose cursor is often in a tag still being
/// typed, in a template that does not parse.
pub fn tag_at(source: []const u8, offset: u32) ?Span {
    assert(offset <= source.len);
    if (source.len > source_bytes_max) return null;
    var at: usize = 0;
    if (std.mem.startsWith(u8, source, "{{%")) {
        const block_end = std.mem.indexOfPos(u8, source, 3, "%}}") orelse return null;
        at = block_end + 3;
        if (offset < at) return null;
    }
    while (std.mem.indexOfPos(u8, source, at, "{{")) |start| {
        if (start >= offset) return null;
        const triple = std.mem.startsWith(u8, source[start..], "{{{");
        const close: []const u8 = if (triple) "}}}" else "}}";
        const inner_end = std.mem.indexOfPos(u8, source, start + close.len, close) orelse
            return .{ .start = @intCast(start), .end = null };
        const end = inner_end + close.len;
        if (offset <= inner_end) return .{ .start = @intCast(start), .end = @intCast(end) };
        assert(end > at);
        at = end;
    }
    return null;
}

/// Where the section the tag `opener` opens ends: after the closing tag
/// that pairs with it by nesting, tags found as `parse` finds them. Null
/// when the tag opens no section, or nothing closes it. For the language
/// server, where an opener being retyped no longer names its closing tag.
pub fn section_end(source: []const u8, opener: Span) ?u32 {
    const opener_end = opener.end orelse return null;
    var diagnostic: Diagnostic = .{};
    const found = bounds(source, opener.start, &diagnostic) catch return null;
    assert(found.end == opener_end);
    switch (found.inner[0]) {
        '#', '^', '?', '$' => {},
        else => return null,
    }
    var depth: u32 = 1;
    var at: usize = opener_end;
    while (std.mem.indexOfPos(u8, source, at, "{{")) |start| {
        const tag = bounds(source, start, &diagnostic) catch return null;
        switch (tag.inner[0]) {
            '#', '^', '?', '$' => depth += 1,
            '/' => {
                depth -= 1;
                if (depth == 0) return @intCast(tag.end);
            },
            else => {},
        }
        assert(tag.end > at);
        at = tag.end;
    }
    return null;
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
    /// Where `inner` starts in the source.
    inner_offset: usize,
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
    const between = source[inner_start..inner_end];
    const inner = std.mem.trim(u8, between, " \t");
    if (inner.len == 0) return fail(diagnostic, start, "an empty tag", "");
    const leading = std.mem.indexOfNone(u8, between, " \t").?;
    return .{
        .inner = inner,
        .inner_offset = inner_start + leading,
        .end = inner_end + close.len,
        .triple = triple,
    };
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
        '#', '^', '?', '/', '!', '>', '$' => {},
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
    if (triple and std.mem.indexOfScalar(u8, "#^?/>$%", inner[0]) != null) {
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
            const bar = std.mem.indexOfScalar(u8, rest, '|') orelse rest.len;
            var node = try path_node(std.mem.trimEnd(u8, rest[0..bar], " \t"), start, diagnostic);
            node.kind = switch (inner[0]) {
                '#' => .section,
                '^' => .inverted,
                '?' => .conditional,
                else => unreachable,
            };
            node.binder = try binder_of(node.kind, rest[bar..], start, diagnostic, node.text);
            open[open_len.*] = tree.len;
            open_len.* += 1;
            try push(tree, node, diagnostic);
        },
        '$' => {
            if (open_len.* == depth_max) {
                return fail(diagnostic, start, "sections nest too deep", rest);
            }
            if (!is_type_name(rest)) {
                const message = "a fragment's name is a type name, like `Row`";
                return fail(diagnostic, start, message, rest);
            }
            open[open_len.*] = tree.len;
            open_len.* += 1;
            const node: Node = .{ .kind = .fragment, .text = rest, .offset = @intCast(start) };
            try push(tree, node, diagnostic);
        },
        '>' => try push(tree, try partial_node(tree, rest, start, diagnostic), diagnostic),
        else => {
            var node = try value_node(found, start, diagnostic);
            node.escape = !triple;
            node.end = tree.len + 1;
            try push(tree, node, diagnostic);
        },
    }
}

/// A section's `|dish|`, Roc's way of naming a value: every `{{#}}` names
/// its element, so a name reads one value wherever it stands. `{{^}}` and
/// `{{?}}` open no scope, and name nothing.
fn binder_of(
    kind: Kind,
    written: []const u8,
    offset: usize,
    diagnostic: *Diagnostic,
    path: []const u8,
) Error![]const u8 {
    assert(written.len == 0 or written[0] == '|');
    if (kind != .section) {
        if (written.len == 0) return "";
        const message = "opens no scope, so it names nothing: `{{^x}}`, `{{?x}}`";
        return fail(diagnostic, offset, message, written);
    }
    if (written.len == 0) {
        const message = "a section names its element, as `{{#dishes |dish|}}` does " ++
            "(a Bool is `{{?flag}}`)";
        return fail(diagnostic, offset, message, path);
    }
    const trimmed = std.mem.trim(u8, written, " \t");
    const name = if (trimmed.len >= 2 and trimmed[trimmed.len - 1] == '|')
        std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t")
    else
        return fail(diagnostic, offset, "a section's name is written `|dish|`", written);
    if (!is_field_name(name)) {
        return fail(diagnostic, offset, "is not a name for a value (like `dish`)", name);
    }
    if (is_keyword(name)) return fail(diagnostic, offset, "is a Roc keyword", name);
    return name;
}

/// `{{> Top}}`: Top reads the names in scope where it stands, as if its
/// text were written there.
fn partial_node(
    tree: *const Tree,
    rest: []const u8,
    start: usize,
    diagnostic: *Diagnostic,
) Error!Node {
    const name_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
    const name = rest[0..name_end];
    if (!is_type_name(name)) {
        return fail(diagnostic, start, "a partial is a template's name, like `Top`", name);
    }
    const context = std.mem.trim(u8, rest[name_end..], " \t");
    if (context.len > 0) {
        const message = "a partial takes no context: it reads the names in scope " ++
            "where it stands (`{{#frames |frame|}}{{> Top}}{{/frames}}`, Top reading `frame`)";
        return fail(diagnostic, start, message, context);
    }
    return .{ .kind = .partial, .text = name, .offset = @intCast(start), .end = tree.len + 1 };
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
        .length = @intCast(text.len),
        .end = tree.len + 1,
    }, diagnostic);
}

/// A path, or a Roc expression of type Str (hole.zig), kept as written. A
/// path then `|` was a formatter: refused, with the Roc that replaces it.
fn value_node(found: Bounds, offset: usize, diagnostic: *Diagnostic) Error!Node {
    const inner = found.inner;
    const bar = std.mem.indexOfScalar(u8, inner, '|');
    const head = std.mem.trim(u8, inner[0 .. bar orelse inner.len], " \t");
    if (path_like(head)) {
        if (bar) |at| return refuse_formatter(inner[at + 1 ..], offset, diagnostic);
        return path_node(head, offset, diagnostic);
    }
    var refused: Diagnostic = .{};
    _ = hole.of(inner, &refused) catch {
        diagnostic.* = refused;
        diagnostic.offset += @intCast(found.inner_offset);
        return error.Invalid;
    };
    return .{ .kind = .value, .text = inner, .expression = inner, .offset = @intCast(offset) };
}

/// Only a path's bytes, `../a.b` or `.`: read as a path, its mistakes a
/// path's (a keyword, too long), never an expression's.
fn path_like(text: []const u8) bool {
    if (text.len == 0) return true;
    if (!is_path_start(text[0])) return false;
    for (text) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '/')) return false;
    }
    return true;
}

/// `path | formatter`, the formatters roux had: each is Roc now, and the
/// message says which Roc.
fn refuse_formatter(after: []const u8, offset: usize, diagnostic: *Diagnostic) Error {
    const rest = std.mem.trim(u8, after, " \t");
    const name = rest[0 .. std.mem.indexOfAny(u8, rest, " \t|") orelse rest.len];
    const replacements = [_][2][]const u8{
        .{ "len", "`| len` is gone: write Roc, `{{ items.len().to_str() }}`" },
        .{ "plural", "`| plural` is gone: write it as a Roc function of your own, " ++
            "`{{ Fmt.plural(items.len(), \"dish\", \"dishes\") }}`" },
        .{ "upper", "`| upper` is gone: write Roc, `{{ name.with_ascii_uppercased() }}`" },
        .{ "lower", "`| lower` is gone: write Roc, `{{ name.with_ascii_lowercased() }}`" },
        .{ "url", "`| url` is gone: percent-encode it in a Roc function of your own, " ++
            "`{{ Fmt.url(query) }}`" },
    };
    for (replacements) |r| {
        if (std.mem.eql(u8, r[0], name)) return fail(diagnostic, offset, r[1], name);
    }
    const message = "a formatter is a Roc function now: `{{ Fmt.name(value) }}`";
    return fail(diagnostic, offset, message, name);
}

fn path_node(written: []const u8, offset: usize, diagnostic: *Diagnostic) Error!Node {
    var node: Node = .{ .kind = .value, .text = written, .offset = @intCast(offset) };
    if (std.mem.startsWith(u8, written, "../")) {
        const message = "`../` is gone: the names around a section stay in scope, " ++
            "so write the one meant (`title`, `dish.name`)";
        return fail(diagnostic, offset, message, written);
    }
    if (written.len == 0) return fail(diagnostic, offset, "a tag with no name", written);
    if (std.mem.eql(u8, written, ".")) {
        const message = "`.` is gone: read the element by the name its section gives it " ++
            "(`{{#tags |tag|}}{{ tag }}{{/tags}}`)";
        return fail(diagnostic, offset, message, written);
    }
    var parts = std.mem.splitScalar(u8, written, '.');
    while (parts.next()) |part| {
        if (node.path_len == path_max) return fail(diagnostic, offset, "a path too long", written);
        if (!is_field_name(part)) {
            return fail(diagnostic, offset, "is not a field name (like `title`)", written);
        }
        if (is_keyword(part)) return fail(diagnostic, offset, keyword_message, written);
        node.path[node.path_len] = part;
        node.path_len += 1;
    }
    return node;
}

fn is_path_start(c: u8) bool {
    return std.ascii.isLower(c) or c == '_' or c == '.';
}

pub fn is_field_name(s: []const u8) bool {
    if (s.len == 0 or !(std.ascii.isLower(s[0]) or s[0] == '_')) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

/// Roc's keywords (src/parse/tokenize.zig's `keywords` at the pinned
/// nightly, ad3a5d2): none can name a record's field, so a contract that
/// had one would reach roc as a syntax error in a generated file. Each
/// checked on the pinned roc as a field in a type, a literal and an
/// access.
const keywords = [_][]const u8{
    "and",       "app",      "as",         "crash",  "dbg",       "else",
    "expect",    "exposes",  "exposing",   "for",    "generates", "has",
    "hosted",    "if",       "implements", "import", "imports",   "in",
    "interface", "match",    "module",     "or",     "package",   "packages",
    "platform",  "provides", "requires",   "return", "targets",   "var",
    "where",     "while",    "with",       "break",
};

pub const keyword_message = "is a Roc keyword, which cannot name a field";

pub fn is_keyword(s: []const u8) bool {
    for (keywords) |k| if (std.mem.eql(u8, k, s)) return true;
    return false;
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
        "<p>{{#a |x|}}{{ x.b.c }}{{/a}}{{^a}}none{{/a}}</p>";
    try parse(source, &tree, &diagnostic);
    const n = tree.slice();
    try testing.expectEqual(@as(usize, 6), n.len);
    try testing.expectEqualStrings("\nCtx : { a : List({ b : { c : Str } }) }\n", tree.block);
    try testing.expectEqualStrings("<p>", n[0].text);
    try testing.expectEqual(Kind.section, n[1].kind);
    try testing.expectEqualStrings("a", n[1].text);
    try testing.expectEqualStrings("x", n[1].binder);
    try testing.expectEqual(@as(u16, 3), n[1].end);
    try testing.expectEqualStrings("c", n[2].path_slice()[2]);
    try testing.expectEqualStrings("", n[3].binder);
    try testing.expectEqual(Kind.inverted, n[3].kind);
    try testing.expectEqual(@as(u16, 5), n[3].end);
}

test "parse: partials, conditionals, raw values, binders, expressions with spaces" {
    var tree: Tree = .{};
    var diagnostic: Diagnostic = .{};
    const source = "{{> Top}}{{?home}}{{{ html }}}{{/home}}" ++
        "{{#xs | x |}}{{ Fmt.plural(n, \"a dish\", \"dishes\") }}" ++
        "{{#x.ys |y|}}{{ y }}{{/x.ys}}{{/xs}}{{! note }}";
    try parse(source, &tree, &diagnostic);
    const n = tree.slice();
    try testing.expectEqual(@as(usize, 7), n.len);
    try testing.expectEqual(Kind.partial, n[0].kind);
    try testing.expectEqualStrings("Top", n[0].text);
    try testing.expectEqual(Kind.conditional, n[1].kind);
    try testing.expect(!n[2].escape);
    try testing.expectEqualStrings("x", n[3].binder);
    try testing.expectEqualStrings("Fmt.plural(n, \"a dish\", \"dishes\")", n[4].expression);
    try testing.expectEqualStrings("x.ys", n[5].text);
    // The scope each node stands in is named by its innermost section.
    try testing.expectEqualStrings("", binder_at(&tree, 3));
    try testing.expectEqualStrings("x", binder_at(&tree, 4));
    try testing.expectEqualStrings("y", binder_at(&tree, 6));
}

test "parse: a path's head is the innermost binder of that name, else the page's field" {
    const binders = [_][]const u8{ "", "dish", "side" };
    const dish_name = [_][]const u8{ "dish", "name" };
    const at_dish = bound(&binders, &dish_name);
    try testing.expectEqual(@as(usize, 1), at_dish.scope);
    try testing.expectEqual(@as(usize, 1), at_dish.path.len);
    try testing.expect(at_dish.named);
    const side = [_][]const u8{"side"};
    const at_side = bound(&binders, &side);
    try testing.expectEqual(@as(usize, 2), at_side.scope);
    try testing.expectEqual(@as(usize, 0), at_side.path.len);
    const title = [_][]const u8{ "title", "text" };
    const at_title = bound(&binders, &title);
    try testing.expectEqual(@as(usize, 0), at_title.scope);
    try testing.expectEqual(@as(usize, 2), at_title.path.len);
    try testing.expect(!at_title.named);
}

test "parse: a node's length spans its tag, braces included, or its text" {
    var tree: Tree = .{};
    var diagnostic: Diagnostic = .{};
    const source = "<p>{{{ raw }}}{{#xs |x|}}{{ x.to_str() }}{{/xs}}{{! c }}{{> Top}}" ++
        "{{$Row}}r{{/Row}}</p>";
    try parse(source, &tree, &diagnostic);
    const expected = [_][]const u8{
        "<p>",       "{{{ raw }}}", "{{#xs |x|}}", "{{ x.to_str() }}",
        "{{> Top}}", "{{$Row}}",    "r",           "</p>",
    };
    try testing.expectEqual(expected.len, tree.len);
    for (tree.slice(), expected) |node, written| {
        try testing.expectEqualStrings(written, source[node.offset..][0..node.length]);
    }
    const row = tree.slice()[5];
    try testing.expectEqual(Kind.fragment, row.kind);
    try testing.expectEqualStrings("Row", row.text);
    try testing.expectEqual(@as(u16, 7), row.end);
}

test "parse: fragments nest, pair by name, and take their line" {
    var tree: Tree = .{};
    var diagnostic: Diagnostic = .{};
    const source = "<ul>\n{{$ List }}\n{{#xs |x|}}{{$Row}}<li>{{ x }}</li>{{/Row}}{{/xs}}\n" ++
        "{{/List}}\n</ul>";
    try parse(source, &tree, &diagnostic);
    const n = tree.slice();
    try testing.expectEqualStrings("<ul>\n", n[0].text);
    try testing.expectEqual(Kind.fragment, n[1].kind);
    try testing.expectEqualStrings("List", n[1].text);
    try testing.expectEqual(tree.len - 1, n[1].end); // the closing line is gone
    try testing.expectEqual(Kind.fragment, n[3].kind);
    try testing.expectEqualStrings("</ul>", n[tree.len - 1].text);
    // The language server pairs `{{$Row}}` with its end as a section's.
    const row_at: u32 = @intCast(std.mem.indexOf(u8, source, "{{$Row}}").? + 3);
    const row_end: u32 = @intCast(std.mem.indexOf(u8, source, "{{/Row}}").? + "{{/Row}}".len);
    try testing.expectEqual(@as(?u32, row_end), section_end(source, tag_at(source, row_at).?));
}

test "parse: tag_at finds the tag around an offset as parse does, closed or not" {
    const source = "{{% Ctx : {} %}}<p>{{ a.b.cdefg }}</p>{{{ b }}}{{#c";
    const none: ?Span = null;
    try testing.expectEqual(none, tag_at(source, 5)); // the block
    try testing.expectEqual(none, tag_at(source, 17)); // text
    // `{{ a.b.cdefg }}` is 19..34: inside from after `{{` to before `}}`.
    try testing.expectEqual(Span{ .start = 19, .end = 34 }, tag_at(source, 21).?);
    try testing.expectEqual(Span{ .start = 19, .end = 34 }, tag_at(source, 32).?);
    try testing.expectEqual(none, tag_at(source, 33));
    try testing.expectEqual(Span{ .start = 38, .end = 47 }, tag_at(source, 41).?);
    try testing.expectEqual(Span{ .start = 47, .end = null }, tag_at(source, source.len).?);
    // A path's segment is a slice of the source.
    var tree: Tree = .{};
    var diagnostic: Diagnostic = .{};
    try parse(source[0..38], &tree, &diagnostic);
    const segment = tree.slice()[1].path_slice()[2];
    try testing.expectEqual(@as(usize, 26), @intFromPtr(segment.ptr) - @intFromPtr(source.ptr));
}

test "parse: section_end pairs an opener with its closing tag by nesting, not by name" {
    const source = "{{#it}}{{^b}}{{ x }}{{/b}}{{! }}{{/items}}{{ y }}{{#z";
    const none: ?u32 = null;
    // `{{/items}}` ends at 42, though `it` does not name it.
    try testing.expectEqual(@as(?u32, 42), section_end(source, tag_at(source, 3).?));
    try testing.expectEqual(@as(?u32, 26), section_end(source, tag_at(source, 10).?));
    try testing.expectEqual(none, section_end(source, tag_at(source, 44).?)); // a value
    try testing.expectEqual(none, section_end(source, tag_at(source, source.len).?)); // unclosed
    try testing.expectEqual(none, section_end("{{#a}}{{ b }}", tag_at("{{#a}}", 3).?));
}

test "parse: a tag alone on its line takes the line with it" {
    var tree: Tree = .{};
    var diagnostic: Diagnostic = .{};
    // Standalone: `{{#a}}`, `  {{/a}}` (indented), `{{> Bottom}}` at the
    // end. Not: `{{ x }}` (a value), `<p>{{#b}}` (text before it).
    const source = "{{#a |i|}}\n<li>{{ x }}</li>\n  {{/a}}\n<p>{{?b}}y{{/b}}</p>\n{{> Bottom}}\n";
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
        .{ .source = "a\n{{#x |i|}}b", .line = 2, .subject = "x" },
        .{ .source = "{{#x |i|}}{{/y}}", .line = 1, .subject = "y" },
        // Every section names its element; nothing else names anything.
        .{ .source = "\n{{#xs}}{{/xs}}", .line = 2, .subject = "xs" },
        .{ .source = "{{#xs |x}}{{/xs}}", .line = 1, .subject = "|x" },
        .{ .source = "{{#xs |X|}}{{/xs}}", .line = 1, .subject = "X" },
        .{ .source = "{{#xs |if|}}{{/xs}}", .line = 1, .subject = "if" },
        .{ .source = "{{^xs |x|}}{{/xs}}", .line = 1, .subject = "|x|" },
        .{ .source = "{{?on |x|}}{{/on}}", .line = 1, .subject = "|x|" },
        // `../` and `.` are gone, each message saying what replaces it.
        .{ .source = "{{#xs |x|}}\n{{ ../n }}{{/xs}}", .line = 2, .subject = "../n" },
        .{ .source = "{{#xs |x|}}\n{{ . }}{{/xs}}", .line = 2, .subject = "." },
        .{ .source = "{{?.}}{{/.}}", .line = 1, .subject = "." },
        // The formatters are gone, each message naming the Roc to write.
        .{ .source = "\n\n{{ x | bold }}", .line = 3, .subject = "bold" },
        .{ .source = "{{ items | len }}", .line = 1, .subject = "len" },
        .{ .source = "{{ n | plural \"a\" \"b\" }}", .line = 1, .subject = "plural" },
        .{ .source = "{{{ name | upper }}}", .line = 1, .subject = "upper" },
        .{ .source = "{{ items | len | plural \"a\" \"b\" }}", .line = 1, .subject = "len" },
        .{ .source = "{{ [x] }}", .line = 1, .subject = "[" },
        .{ .source = "\n\n{{ a +\n [b] }}", .line = 4, .subject = "[" },
        .{ .source = "{{ a.b.to_str() | upper }}", .line = 1, .subject = "|" },
        .{ .source = "{{> top}}", .line = 1, .subject = "top" },
        .{ .source = "x\n{{% Ctx : {} %}}", .line = 2, .subject = "" },
        .{ .source = "\n{{ if }}", .line = 2, .subject = "if" },
        .{ .source = "{{#a.match}}{{/a.match}}", .line = 1, .subject = "a.match" },
        .{ .source = "\n{{> Top frame}}", .line = 2, .subject = "frame" },
        .{ .source = "{{$row}}x{{/row}}", .line = 1, .subject = "row" },
        .{ .source = "{{$Row.A}}x{{/Row.A}}", .line = 1, .subject = "Row.A" },
        .{ .source = "{{$Row}}x\n{{/Rows}}", .line = 2, .subject = "Rows" },
        .{ .source = "{{$Row}}x", .line = 1, .subject = "Row" },
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
