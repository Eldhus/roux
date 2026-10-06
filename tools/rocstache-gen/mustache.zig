//! Mustache lexer + parser.
//!
//! Produces a flat, document-ordered node array. A section node at index `i`
//! owns the nodes `i+1 .. nodes[i].close` (exclusive), so walking a template
//! is a single linear pass with no pointer chasing. Names, paths and literal
//! text are all `[]const u8` slices into the original source; nothing is
//! copied except unescaped string literals in formatter arguments.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const NodeKind = enum(u8) {
    text,
    variable,
    /// `{{#x}}`: a list (element scope) or, with no field used inside, a Bool.
    section,
    /// `{{^x}}`: rendered when the list is empty or the Bool is false.
    inverted,
    /// `{{?x}}`: rendered when the Bool is true; the body keeps the enclosing scope.
    conditional,
    partial,
};

pub const Node = struct {
    kind: NodeKind,
    /// text: byte range of the literal. variable/section/inverted/partial:
    /// byte range of the tag content, used for diagnostics only.
    start: u32,
    end: u32,
    /// variable/section/inverted: index into `Template.exprs`.
    /// partial: index into `Template.partials`.
    expr: u32 = 0,
    /// variable: whether to HTML-escape (`{{x}}` yes, `{{{x}}}`/`{{& x}}` no).
    escape: bool = true,
    /// section/inverted: one past the index of the last child node.
    close: u32 = 0,
};

/// `path | fmt arg.. | fmt arg..`. `path_len == 0` means the implicit iterator `.`.
pub const Expr = struct {
    path_start: u32,
    path_len: u32,
    fmt_start: u32,
    fmt_len: u32,
    /// Byte offset of the expression in the source, for diagnostics.
    offset: u32,
};

pub const Formatter = struct {
    name: []const u8,
    arg_start: u32,
    arg_len: u32,
    offset: u32,
};

pub const ArgKind = enum(u8) { string, number, path };

pub const Arg = struct {
    kind: ArgKind,
    /// string: unescaped contents. number: literal text. path: unused.
    text: []const u8 = "",
    path_start: u32 = 0,
    path_len: u32 = 0,
    offset: u32,
};

pub const Template = struct {
    src: []const u8,
    nodes: []const Node,
    exprs: []const Expr,
    fmts: []const Formatter,
    args: []const Arg,
    /// Path segments; an `Expr`/`Arg` path is a contiguous run in here.
    segs: []const []const u8,
    /// Partial names, in order of first appearance (deduplicated).
    partials: []const []const u8,
    /// Sum of literal text bytes, used to pre-size the output string.
    static_bytes: u32,
    /// The body of the leading `{{% ... %}}` block: Roc source copied into the
    /// generated module as it is (imports, formatters, a `Ctx` type), or "".
    pragma: []const u8 = "",
    /// Byte offset of `pragma` in `src`.
    pragma_offset: u32 = 0,

    pub fn path(t: *const Template, start: u32, len: u32) []const []const u8 {
        return t.segs[start .. start + len];
    }
};

pub const Error = error{ ParseError, OutOfMemory };

/// Populated on `error.ParseError`.
pub const Diagnostic = struct {
    offset: u32 = 0,
    message: []const u8 = "",
    /// Set by the generator when the error is inside a partial.
    file: []const u8 = "",

    pub fn lineCol(d: Diagnostic, src: []const u8) struct { line: u32, col: u32 } {
        var line: u32 = 1;
        var col: u32 = 1;
        for (src[0..@min(d.offset, src.len)]) |c| {
            if (c == '\n') {
                line += 1;
                col = 1;
            } else col += 1;
        }
        return .{ .line = line, .col = col };
    }
};

const Parser = struct {
    gpa: Allocator,
    src: []const u8,
    diag: *Diagnostic,
    nodes: std.ArrayList(Node) = .empty,
    exprs: std.ArrayList(Expr) = .empty,
    fmts: std.ArrayList(Formatter) = .empty,
    args: std.ArrayList(Arg) = .empty,
    segs: std.ArrayList([]const u8) = .empty,
    partials: std.ArrayList([]const u8) = .empty,
    /// Open sections (node indices).
    stack: std.ArrayList(u32) = .empty,
    static_bytes: u32 = 0,
    pragma: []const u8 = "",
    pragma_offset: u32 = 0,
    open: []const u8 = "{{",
    close: []const u8 = "}}",

    fn fail(p: *Parser, offset: usize, msg: []const u8) Error {
        p.diag.* = .{ .offset = @intCast(offset), .message = msg };
        return error.ParseError;
    }

    fn addText(p: *Parser, start: usize, end: usize) Error!void {
        if (end <= start) return;
        p.static_bytes += @intCast(end - start);
        try p.nodes.append(p.gpa, .{ .kind = .text, .start = @intCast(start), .end = @intCast(end) });
    }

    fn parse(p: *Parser) Error!void {
        const src = p.src;
        var pos: usize = 0;
        // A `{{% ... %}}` block of Roc comes first, before any other output.
        // It ends at `%}}` (its Roc may contain `}}`), and the line break
        // after it is dropped.
        // A UTF-8 byte order mark is not text before the block.
        if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) pos = 3;
        const lead = std.mem.indexOfNonePos(u8, src, pos, " \t\r\n") orelse src.len;
        if (std.mem.startsWith(u8, src[lead..], "{{%")) {
            const body_start = lead + 3;
            const body_end = std.mem.indexOfPos(u8, src, body_start, "%}}") orelse return p.fail(lead, "unclosed `{{%` block (it ends with `%}}`)");
            p.pragma = src[body_start..body_end];
            p.pragma_offset = @intCast(body_start);
            pos = body_end + 3;
            if (pos < src.len and src[pos] == '\r') pos += 1;
            if (pos < src.len and src[pos] == '\n') pos += 1;
        }
        while (pos < src.len) {
            const tag_start = std.mem.indexOfPos(u8, src, pos, p.open) orelse {
                try p.addText(pos, src.len);
                pos = src.len;
                break;
            };
            var content_start = tag_start + p.open.len;
            const default_delims = std.mem.eql(u8, p.open, "{{") and std.mem.eql(u8, p.close, "}}");
            var tag_end: usize = undefined;
            var content_end: usize = undefined;
            var triple = false;
            if (default_delims and content_start < src.len and src[content_start] == '{') {
                triple = true;
                content_start += 1;
                content_end = std.mem.indexOfPos(u8, src, content_start, "}}}") orelse
                    return p.fail(tag_start, "unclosed `{{{` tag");
                tag_end = content_end + 3;
            } else {
                content_end = std.mem.indexOfPos(u8, src, content_start, p.close) orelse
                    return p.fail(tag_start, "unclosed tag");
                tag_end = content_end + p.close.len;
            }
            const raw = src[content_start..content_end];
            const content = std.mem.trim(u8, raw, " \t\r\n");
            const content_off = content_start + (raw.len - std.mem.trimStart(u8, raw, " \t\r\n").len);
            if (content.len == 0) return p.fail(tag_start, "empty tag");

            if (!triple and content[0] == '%') return p.fail(tag_start, "a `{{% %}}` block must be the first thing in the template");
            var sigil: u8 = 0;
            if (!triple) switch (content[0]) {
                '#', '^', '?', '/', '!', '>', '&', '=' => sigil = content[0],
                else => {},
            };
            const standalone_kind = switch (sigil) {
                '#', '^', '?', '/', '!', '>', '=' => true,
                else => false,
            };

            // Standalone-line detection (Mustache spec: the whole line is removed).
            var text_end = tag_start;
            var next_pos = tag_end;
            if (standalone_kind) {
                var line_start = tag_start;
                while (line_start > 0 and src[line_start - 1] != '\n') line_start -= 1;
                const before_ws = std.mem.trim(u8, src[line_start..tag_start], " \t").len == 0;
                var after = tag_end;
                while (after < src.len and (src[after] == ' ' or src[after] == '\t')) after += 1;
                var after_ok = false;
                if (after >= src.len) {
                    after_ok = true;
                } else if (src[after] == '\n') {
                    after_ok = true;
                    after += 1;
                } else if (src[after] == '\r' and after + 1 < src.len and src[after + 1] == '\n') {
                    after_ok = true;
                    after += 2;
                }
                if (before_ws and after_ok and line_start >= pos) {
                    text_end = line_start;
                    next_pos = after;
                }
            }
            try p.addText(pos, text_end);

            const body = if (sigil != 0) std.mem.trimStart(u8, content[1..], " \t\r\n") else content;
            const body_off = content_off + (content.len - body.len);
            switch (sigil) {
                '!' => {},
                '=' => {
                    if (body.len == 0 or body[body.len - 1] != '=') return p.fail(tag_start, "malformed set-delimiter tag, expected `{{=<open> <close>=}}`");
                    var it = std.mem.tokenizeAny(u8, body[0 .. body.len - 1], " \t\r\n");
                    const o = it.next() orelse return p.fail(tag_start, "set-delimiter tag needs two delimiters");
                    const c = it.next() orelse return p.fail(tag_start, "set-delimiter tag needs two delimiters");
                    if (it.next() != null) return p.fail(tag_start, "set-delimiter tag has too many parts");
                    if (std.mem.indexOfScalar(u8, o, '=') != null or std.mem.indexOfScalar(u8, c, '=') != null)
                        return p.fail(tag_start, "delimiters may not contain `=`");
                    p.open = o;
                    p.close = c;
                },
                '#', '^', '?' => {
                    const expr = try p.parseExpr(body, body_off, false);
                    try p.nodes.append(p.gpa, .{
                        .kind = switch (sigil) {
                            '#' => .section,
                            '^' => .inverted,
                            else => .conditional,
                        },
                        .start = @intCast(content_off),
                        .end = @intCast(content_end),
                        .expr = expr,
                    });
                    try p.stack.append(p.gpa, @intCast(p.nodes.items.len - 1));
                },
                '/' => {
                    const open_idx = p.stack.pop() orelse return p.fail(tag_start, "closing tag without an open section");
                    const open_node = &p.nodes.items[open_idx];
                    const open_expr = p.exprs.items[open_node.expr];
                    const open_name = p.joinedPathText(open_expr);
                    var close_name = body;
                    while (std.mem.startsWith(u8, close_name, "../")) close_name = close_name[3..];
                    if (!std.mem.eql(u8, open_name, close_name)) return p.fail(tag_start, "closing tag does not match the open section");
                    open_node.close = @intCast(p.nodes.items.len);
                },
                '>' => {
                    if (!isTypeName(body)) return p.fail(body_off, "partial name must be a capitalized Roc module name, e.g. `{{> Header}}`");
                    var idx: ?u32 = null;
                    for (p.partials.items, 0..) |name, i| if (std.mem.eql(u8, name, body)) {
                        idx = @intCast(i);
                    };
                    if (idx == null) {
                        idx = @intCast(p.partials.items.len);
                        try p.partials.append(p.gpa, body);
                    }
                    try p.nodes.append(p.gpa, .{ .kind = .partial, .start = @intCast(content_off), .end = @intCast(content_end), .expr = idx.? });
                },
                else => {
                    const expr = try p.parseExpr(body, body_off, true);
                    try p.nodes.append(p.gpa, .{
                        .kind = .variable,
                        .start = @intCast(content_off),
                        .end = @intCast(content_end),
                        .expr = expr,
                        .escape = !(triple or sigil == '&'),
                    });
                },
            }
            pos = next_pos;
        }
        if (p.stack.items.len != 0) {
            const n = p.nodes.items[p.stack.items[p.stack.items.len - 1]];
            return p.fail(n.start, "unclosed section");
        }
    }

    /// Reconstructs `a.b.c` for a section expr so `{{/a.b.c}}` can be matched;
    /// `../` hops are left out, so `{{#../items}}` closes with `{{/items}}`.
    fn joinedPathText(p: *Parser, e: Expr) []const u8 {
        if (e.path_len == 0) return ".";
        const hops: u32 = @intCast(pathPrefix(p.segs.items[e.path_start .. e.path_start + e.path_len]));
        if (hops == e.path_len) return "..";
        const first = p.segs.items[e.path_start + hops];
        const last = p.segs.items[e.path_start + e.path_len - 1];
        const start = @intFromPtr(first.ptr) - @intFromPtr(p.src.ptr);
        const end = @intFromPtr(last.ptr) + last.len - @intFromPtr(p.src.ptr);
        return p.src[start..end];
    }

    /// Splits `text` on top-level `|` (outside string literals).
    fn parseExpr(p: *Parser, text: []const u8, offset: usize, allow_fmt: bool) Error!u32 {
        var parts: [64][]const u8 = undefined;
        var part_offs: [64]usize = undefined;
        var n: usize = 0;
        var seg_start: usize = 0;
        var in_str = false;
        var i: usize = 0;
        while (i <= text.len) : (i += 1) {
            const at_end = i == text.len;
            if (!at_end and in_str) {
                if (text[i] == '\\') {
                    i += 1;
                } else if (text[i] == '"') in_str = false;
                continue;
            }
            if (at_end or text[i] == '|') {
                if (n == 64) return p.fail(offset, "too many `|` formatters in one tag");
                parts[n] = text[seg_start..i];
                part_offs[n] = offset + seg_start;
                n += 1;
                seg_start = i + 1;
            } else if (text[i] == '"') in_str = true;
        }
        if (in_str) return p.fail(offset, "unterminated string literal");
        if (n > 1 and !allow_fmt) return p.fail(offset, "formatters are not allowed on section tags");

        const path_text = std.mem.trim(u8, parts[0], " \t\r\n");
        const path_off = part_offs[0] + (parts[0].len - std.mem.trimStart(u8, parts[0], " \t\r\n").len);
        const path = try p.parsePath(path_text, path_off);

        const fmt_start: u32 = @intCast(p.fmts.items.len);
        var k: usize = 1;
        while (k < n) : (k += 1) {
            try p.parseFormatter(parts[k], part_offs[k]);
        }
        try p.exprs.append(p.gpa, .{
            .path_start = path.start,
            .path_len = path.len,
            .fmt_start = fmt_start,
            .fmt_len = @intCast(p.fmts.items.len - fmt_start),
            .offset = @intCast(offset),
        });
        return @intCast(p.exprs.items.len - 1);
    }

    fn parsePath(p: *Parser, text_in: []const u8, offset_in: usize) Error!struct { start: u32, len: u32 } {
        const start: u32 = @intCast(p.segs.items.len);
        var text = text_in;
        var offset = offset_in;
        if (text.len == 0) return p.fail(offset, "expected a name");
        if (std.mem.eql(u8, text, ".")) return .{ .start = start, .len = 0 };
        // `../name` reaches the enclosing scope; each `../` goes one level up.
        while (std.mem.startsWith(u8, text, "../") or std.mem.eql(u8, text, "..")) {
            try p.segs.append(p.gpa, text[0..2]);
            if (text.len == 2) return p.fail(offset, "expected a name after `..` (like `../title`)");
            text = text[3..];
            offset += 3;
        }
        if (text.len == 0) return p.fail(offset, "expected a name after `../`");
        // `@name` is a field of the root context (the record the page's
        // `render` receives), reachable from any depth and inside partials.
        if (text[0] == '@') {
            if (p.segs.items.len != start) return p.fail(offset, "`@` (the root context) cannot follow `../`");
            try p.segs.append(p.gpa, text[0..1]);
            text = text[1..];
            offset += 1;
            if (text.len == 0) return p.fail(offset, "expected a name after `@` (like `@now`)");
        }
        var it = std.mem.splitScalar(u8, text, '.');
        var off = offset;
        while (it.next()) |seg| {
            if (!isFieldName(seg)) return p.fail(off, "not a valid field name (want snake_case: `[a-z][a-z0-9_]*`)");
            try p.segs.append(p.gpa, seg);
            off += seg.len + 1;
        }
        return .{ .start = start, .len = @intCast(p.segs.items.len - start) };
    }

    fn parseFormatter(p: *Parser, text: []const u8, offset: usize) Error!void {
        var i: usize = 0;
        while (i < text.len and isSpace(text[i])) i += 1;
        const name_start = i;
        while (i < text.len and !isSpace(text[i])) i += 1;
        const name = text[name_start..i];
        if (!isFormatterName(name)) return p.fail(offset + name_start, "expected a function after `|`: a name (`money`) or a qualified one (`Str.trim`)");
        const arg_start: u32 = @intCast(p.args.items.len);
        while (true) {
            while (i < text.len and isSpace(text[i])) i += 1;
            if (i >= text.len) break;
            const a0 = i;
            if (text[i] == '"') {
                i += 1;
                var buf: std.ArrayList(u8) = .empty;
                while (true) {
                    if (i >= text.len) return p.fail(offset + a0, "unterminated string literal");
                    const c = text[i];
                    if (c == '"') break;
                    if (c == '\\') {
                        i += 1;
                        if (i >= text.len) return p.fail(offset + a0, "unterminated string literal");
                        switch (text[i]) {
                            'n' => try buf.append(p.gpa, '\n'),
                            't' => try buf.append(p.gpa, '\t'),
                            'r' => try buf.append(p.gpa, '\r'),
                            '\\' => try buf.append(p.gpa, '\\'),
                            '"' => try buf.append(p.gpa, '"'),
                            else => return p.fail(offset + i, "unknown escape in string literal"),
                        }
                    } else try buf.append(p.gpa, c);
                    i += 1;
                }
                i += 1;
                try p.args.append(p.gpa, .{ .kind = .string, .text = try buf.toOwnedSlice(p.gpa), .offset = @intCast(offset + a0) });
            } else if (std.ascii.isDigit(text[i]) or (text[i] == '-' and i + 1 < text.len and std.ascii.isDigit(text[i + 1]))) {
                i += 1;
                while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '.' or text[i] == '_')) i += 1;
                try p.args.append(p.gpa, .{ .kind = .number, .text = text[a0..i], .offset = @intCast(offset + a0) });
            } else {
                while (i < text.len and !isSpace(text[i])) i += 1;
                const path = try p.parsePath(text[a0..i], offset + a0);
                try p.args.append(p.gpa, .{ .kind = .path, .path_start = path.start, .path_len = path.len, .offset = @intCast(offset + a0) });
            }
        }
        try p.fmts.append(p.gpa, .{
            .name = name,
            .arg_start = arg_start,
            .arg_len = @intCast(p.args.items.len - arg_start),
            .offset = @intCast(offset + name_start),
        });
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// Number of leading `..` segments in a path.
pub fn parentHops(path: []const []const u8) usize {
    var n: usize = 0;
    while (n < path.len and std.mem.eql(u8, path[n], "..")) n += 1;
    return n;
}

/// `@name`: the path starts at the root context.
pub fn isRootPath(path: []const []const u8) bool {
    return path.len > 0 and std.mem.eql(u8, path[0], "@");
}

/// Segments before the field names: `..` hops or the `@` root marker.
pub fn pathPrefix(path: []const []const u8) usize {
    return if (isRootPath(path)) 1 else parentHops(path);
}

test "root paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const t = try parse(arena.allocator(), "{{ @now }}{{#items}}{{ at | ago @now }}{{/items}}{{#@rows}}{{ . }}{{/rows}}", &diag);
    const e = t.exprs[t.nodes[0].expr];
    try std.testing.expectEqual(@as(u32, 2), e.path_len);
    try std.testing.expect(isRootPath(t.path(e.path_start, e.path_len)));
    try std.testing.expectEqualStrings("now", t.segs[e.path_start + 1]);
    try std.testing.expectError(error.ParseError, parse(arena.allocator(), "{{ ../@x }}", &diag));
    try std.testing.expectError(error.ParseError, parse(arena.allocator(), "{{ @ }}", &diag));
}

test "conditional sections and parent paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const t = try parse(arena.allocator(), "{{?paid}}{{ ../title }}{{/paid}}{{#items}}{{ ../../root }}{{/items}}", &diag);
    try std.testing.expectEqual(NodeKind.conditional, t.nodes[0].kind);
    const e = t.exprs[t.nodes[1].expr];
    try std.testing.expectEqual(@as(u32, 2), e.path_len);
    try std.testing.expectEqualStrings("..", t.segs[e.path_start]);
    try std.testing.expectEqualStrings("title", t.segs[e.path_start + 1]);
    try std.testing.expectEqual(@as(usize, 2), parentHops(t.path(t.exprs[t.nodes[3].expr].path_start, 3)));
    var bad: Diagnostic = .{};
    try std.testing.expectError(error.ParseError, parse(arena.allocator(), "{{ .. }}", &bad));
}

/// A formatter: `name`, or `Module.name` / `Mod.Sub.name` (capitalized
/// module segments, then a lowercase function name).
pub fn isFormatterName(s: []const u8) bool {
    var it = std.mem.splitScalar(u8, s, '.');
    var last: []const u8 = "";
    var n: usize = 0;
    while (it.next()) |seg| : (n += 1) {
        if (n > 0 and !isTypeName(last)) return false;
        last = seg;
    }
    return isFieldName(last);
}

pub fn isFieldName(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isLower(s[0])) return false;
    for (s[1..]) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return false;
    return true;
}

pub fn isTypeName(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isUpper(s[0])) return false;
    for (s[1..]) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

/// Parses `src`. All returned slices are owned by `gpa` (use an arena).
pub fn parse(gpa: Allocator, src: []const u8, diag: *Diagnostic) Error!Template {
    var p = Parser{ .gpa = gpa, .src = src, .diag = diag };
    try p.parse();
    return .{
        .src = src,
        .nodes = try p.nodes.toOwnedSlice(gpa),
        .exprs = try p.exprs.toOwnedSlice(gpa),
        .fmts = try p.fmts.toOwnedSlice(gpa),
        .args = try p.args.toOwnedSlice(gpa),
        .segs = try p.segs.toOwnedSlice(gpa),
        .partials = try p.partials.toOwnedSlice(gpa),
        .static_bytes = p.static_bytes,
        .pragma = p.pragma,
        .pragma_offset = p.pragma_offset,
    };
}

test "the leading {{% %}} block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const t = try parse(arena.allocator(), "\n{{%\nimport ../Formatters exposing [money]\nr = { a: { b: 1 }}\n%}}\n<p>{{ x | money }}</p>", &diag);
    try std.testing.expectEqualStrings("\nimport ../Formatters exposing [money]\nr = { a: { b: 1 }}\n", t.pragma);
    try std.testing.expectEqual(@as(usize, 3), t.nodes.len);
    try std.testing.expectEqualStrings("<p>", t.src[t.nodes[0].start..t.nodes[0].end]);
    try std.testing.expectError(error.ParseError, parse(arena.allocator(), "<p>{{% x %}}", &diag));
    try std.testing.expectError(error.ParseError, parse(arena.allocator(), "{{% x", &diag));
    const q = try parse(arena.allocator(), "{{ x | Str.trim | Html.Esc.go }}", &diag);
    try std.testing.expectEqualStrings("Str.trim", q.fmts[0].name);
    try std.testing.expectError(error.ParseError, parse(arena.allocator(), "{{ x | str.trim }}", &diag));
}

test "text and variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const t = try parse(arena.allocator(), "Hi {{name}}! {{{raw}}} {{& also.raw }}", &diag);
    try std.testing.expectEqual(@as(usize, 6), t.nodes.len);
    try std.testing.expectEqual(NodeKind.text, t.nodes[0].kind);
    try std.testing.expectEqual(NodeKind.variable, t.nodes[1].kind);
    try std.testing.expect(t.nodes[1].escape);
    try std.testing.expect(!t.nodes[3].escape);
    try std.testing.expect(!t.nodes[5].escape);
    const e = t.exprs[t.nodes[5].expr];
    try std.testing.expectEqual(@as(u32, 2), e.path_len);
    try std.testing.expectEqualStrings("also", t.path(e.path_start, e.path_len)[0]);
    try std.testing.expectEqualStrings("raw", t.path(e.path_start, e.path_len)[1]);
}

test "sections, standalone lines, comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const src = "<ul>\n{{#items}}\n  <li>{{.}}</li>\n{{/items}}\n{{! comment }}\n{{^items}}\n  none\n{{/items}}\n</ul>\n";
    const t = try parse(arena.allocator(), src, &diag);
    // text "<ul>\n", section, text "  <li>", var, text "</li>\n", inverted, text "  none\n", text "</ul>\n"
    try std.testing.expectEqual(@as(usize, 8), t.nodes.len);
    try std.testing.expectEqual(NodeKind.section, t.nodes[1].kind);
    try std.testing.expectEqual(@as(u32, 5), t.nodes[1].close);
    try std.testing.expectEqualStrings("  <li>", src[t.nodes[2].start..t.nodes[2].end]);
    try std.testing.expectEqual(NodeKind.inverted, t.nodes[5].kind);
    try std.testing.expectEqual(@as(u32, 7), t.nodes[5].close);
    try std.testing.expectEqualStrings("</ul>\n", src[t.nodes[7].start..t.nodes[7].end]);
}

test "formatters and arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const t = try parse(arena.allocator(), "{{ price | money \"US|D\" 2 | pad width -1.5 }}", &diag);
    const e = t.exprs[t.nodes[0].expr];
    try std.testing.expectEqual(@as(u32, 2), e.fmt_len);
    const f0 = t.fmts[e.fmt_start];
    try std.testing.expectEqualStrings("money", f0.name);
    try std.testing.expectEqual(@as(u32, 2), f0.arg_len);
    try std.testing.expectEqual(ArgKind.string, t.args[f0.arg_start].kind);
    try std.testing.expectEqualStrings("US|D", t.args[f0.arg_start].text);
    try std.testing.expectEqualStrings("2", t.args[f0.arg_start + 1].text);
    const f1 = t.fmts[e.fmt_start + 1];
    try std.testing.expectEqualStrings("pad", f1.name);
    try std.testing.expectEqual(ArgKind.path, t.args[f1.arg_start].kind);
    try std.testing.expectEqualStrings("-1.5", t.args[f1.arg_start + 1].text);
}

test "set delimiters and partials" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const t = try parse(arena.allocator(), "{{=<% %>=}}<% a %>{{b}}<%> Foo %><%> Foo %>", &diag);
    try std.testing.expectEqual(@as(usize, 4), t.nodes.len);
    try std.testing.expectEqual(NodeKind.variable, t.nodes[0].kind);
    try std.testing.expectEqual(NodeKind.text, t.nodes[1].kind);
    try std.testing.expectEqual(NodeKind.partial, t.nodes[2].kind);
    try std.testing.expectEqual(@as(usize, 1), t.partials.len);
    try std.testing.expectEqualStrings("Foo", t.partials[0]);
}

test "errors carry offsets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.ParseError, parse(arena.allocator(), "a\n{{#x}}\n{{/y}}", &diag));
    try std.testing.expectEqual(@as(u32, 3), diag.lineCol("a\n{{#x}}\n{{/y}}").line);
    try std.testing.expectError(error.ParseError, parse(arena.allocator(), "{{#x}}", &diag));
    try std.testing.expectError(error.ParseError, parse(arena.allocator(), "{{x", &diag));
    try std.testing.expectError(error.ParseError, parse(arena.allocator(), "{{Bad}}", &diag));
    try std.testing.expectError(error.ParseError, parse(arena.allocator(), "{{#x | f}}{{/x}}", &diag));
}

test "fuzz: parser never crashes" {
    try std.testing.fuzz({}, fuzzOne, .{});
}

fn fuzzOne(_: void, smith: *std.testing.Smith) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    const n = smith.valueRangeAtMost(u16, 0, buf.len);
    smith.bytes(buf[0..n]);
    var diag: Diagnostic = .{};
    _ = parse(arena.allocator(), buf[0..n], &diag) catch |err| switch (err) {
        error.ParseError => {},
        else => return err,
    };
}
