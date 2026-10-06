//! Roc tokens, for the few things the generator and the language server
//! read out of Roc source (a template's `{{% %}}` block, a formatter
//! module's signatures). It follows roc's own lexical rules
//! (`src/parse/tokenize.zig`): `#` comments, `"..."` strings that end at
//! their quote or the line, `"""` and `\\` strings that run to the end of
//! the line, `${...}` interpolation (nested), `'c'` characters. A string or
//! character, interpolations included, is one token, so nothing inside it
//! counts as code. It does not parse: statements are read from bracket
//! depth and from where lines begin, as `roc fmt` lays them out.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const source_bytes_max: u32 = 16 * 1024 * 1024;
pub const tokens_max: u32 = 4 * 1024 * 1024;
/// Interpolations inside strings inside interpolations...
pub const nesting_max: u32 = 64;

pub const Kind = enum { lower, upper, number, string, char, comment, punct };

pub const Token = struct {
    kind: Kind,
    text: []const u8,
    offset: u32,
    /// Byte column of its first character.
    col: u32,
    /// Nothing but whitespace before it on its line.
    first_on_line: bool,
    /// Bracket depth it sits at; a bracket sits at the depth outside it.
    depth: u32,
};

const operators = [_][]const u8{ "->", "=>", "::", "..", "==", "!=", "<=", ">=", "&&", "||", "|>" };

pub fn tokenize(gpa: Allocator, src: []const u8) ![]const Token {
    if (src.len > source_bytes_max) return error.SourceTooLarge;
    var out: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    var line_start: usize = 0;
    var line_has_token = false;
    var depth: u32 = 0;
    while (i < src.len) {
        if (out.items.len == tokens_max) return error.TooManyTokens;
        const c = src[i];
        if (c == '\n') {
            i += 1;
            line_start = i;
            line_has_token = false;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\r') {
            i += 1;
            continue;
        }
        const start = i;
        const kind = try scan(src, &i);
        assert(i > start);
        const slice = src[start..i];
        const closes = kind == .punct and slice.len == 1 and (c == ')' or c == ']' or c == '}');
        if (closes) depth -|= 1;
        try out.append(gpa, .{ .kind = kind, .text = slice, .offset = @intCast(start), .col = @intCast(start - line_start), .first_on_line = !line_has_token, .depth = depth });
        if (kind == .punct and slice.len == 1 and (c == '(' or c == '[' or c == '{')) depth += 1;
        line_has_token = true;
        // A token that spans lines (none does but a comment's newline, which
        // is not part of it) leaves `line_start` where it was.
        assert(std.mem.indexOfScalar(u8, slice, '\n') == null);
    }
    return out.items;
}

fn scan(src: []const u8, i: *usize) !Kind {
    const start = i.*;
    const c = src[start];
    if (c == '#') {
        i.* = std.mem.indexOfScalarPos(u8, src, start, '\n') orelse src.len;
        return .comment;
    }
    if (c == '"' or (c == '\\' and start + 1 < src.len and src[start + 1] == '\\')) {
        i.* = try stringEnd(src, start);
        return .string;
    }
    if (c == '\'') {
        i.* = charEnd(src, start);
        return .char;
    }
    if (std.ascii.isDigit(c)) {
        while (i.* < src.len and (std.ascii.isAlphanumeric(src[i.*]) or src[i.*] == '_' or (src[i.*] == '.' and i.* + 1 < src.len and std.ascii.isDigit(src[i.* + 1])))) i.* += 1;
        return .number;
    }
    if (std.ascii.isAlphabetic(c) or c == '_') {
        while (i.* < src.len and (std.ascii.isAlphanumeric(src[i.*]) or src[i.*] == '_')) i.* += 1;
        if (i.* < src.len and src[i.*] == '!') i.* += 1;
        return if (std.ascii.isUpper(c)) .upper else .lower;
    }
    for (operators) |op| if (std.mem.startsWith(u8, src[start..], op)) {
        i.* += op.len;
        return .punct;
    };
    i.* += 1;
    return .punct;
}

/// Where the string starting at `start` ends, interpolations included: a
/// `"..."` at its closing quote or the end of the line (unclosed; roc
/// reports it), a `"""` or `\\` string at the end of the line.
fn stringEnd(src: []const u8, start: usize) !usize {
    const Frame = struct { multi: bool, in_code: bool, curly: u32 };
    var stack: [nesting_max]Frame = undefined;
    var top: u32 = 0;
    var i = start;
    stack[0] = .{ .multi = false, .in_code = false, .curly = 0 };
    if (src[i] == '\\' or std.mem.startsWith(u8, src[i..], "\"\"\"")) {
        stack[0].multi = true;
        i += if (src[i] == '\\') 2 else 3;
    } else i += 1;
    while (i < src.len) {
        const f = &stack[top];
        const c = src[i];
        if (!f.in_code) {
            if (c == '\n') return i; // a single-line string left unclosed, or a line string's end
            if (c == '\\' and i + 1 < src.len) {
                i += 2;
                continue;
            }
            if (!f.multi and c == '"') {
                if (top == 0) return i + 1;
                top -= 1; // back in the interpolation's code
                i += 1;
                continue;
            }
            if (c == '$' and i + 1 < src.len and src[i + 1] == '{') {
                f.in_code = true;
                f.curly = 0;
                i += 2;
                continue;
            }
            i += 1;
            continue;
        }
        // Code inside `${ }`.
        if (c == '\n') return i; // roc reports the unclosed interpolation
        if (c == '{') f.curly += 1;
        if (c == '}') {
            if (f.curly == 0) f.in_code = false else f.curly -= 1;
        }
        if (c == '"') {
            if (top + 1 == nesting_max) return error.TooDeeplyNested;
            top += 1;
            stack[top] = .{ .multi = false, .in_code = false, .curly = 0 };
        }
        i += 1;
    }
    return i;
}

fn charEnd(src: []const u8, start: usize) usize {
    var i = start + 1;
    while (i < src.len and src[i] != '\n') : (i += 1) {
        if (src[i] == '\\') {
            i += 1;
            continue;
        }
        if (src[i] == '\'') return i + 1;
    }
    return i;
}

pub fn isPunct(t: Token, p: []const u8) bool {
    return t.kind == .punct and std.mem.eql(u8, t.text, p);
}

pub fn isLower(t: Token, w: []const u8) bool {
    return t.kind == .lower and std.mem.eql(u8, t.text, w);
}

/// One statement of a block: its tokens (comments included), and the
/// `##` doc lines right above it.
pub const Statement = struct {
    tokens: []const Token,
    doc: []const Token,

    /// The code tokens.
    pub fn code(st: Statement, gpa: Allocator) ![]const Token {
        var out: std.ArrayList(Token) = .empty;
        for (st.tokens) |t| if (t.kind != .comment) try out.append(gpa, t);
        return out.items;
    }
};

/// The statements at bracket depth `depth` in `tokens[from..to]`: each
/// begins with a code token first on its line at `depth` and at the
/// column of the block's first statement (roc fmt's layout: continuation
/// lines are indented further, closing brackets and blank lines do not
/// begin a statement).
pub fn statements(gpa: Allocator, tokens: []const Token, from: usize, to: usize, depth: u32) ![]const Statement {
    var out: std.ArrayList(Statement) = .empty;
    var col: ?u32 = null;
    var begin: ?usize = null;
    var i = from;
    while (i < to) : (i += 1) {
        const t = tokens[i];
        const opens = t.first_on_line and t.depth == depth and t.kind != .comment and !isClosing(t) and (col == null or t.col == col.?);
        if (!opens) continue;
        if (col == null) col = t.col;
        if (begin) |b| try out.append(gpa, try statement(tokens, from, b, i));
        begin = i;
    }
    if (begin) |b| try out.append(gpa, try statement(tokens, from, b, to));
    return out.items;
}

fn isClosing(t: Token) bool {
    return isPunct(t, ")") or isPunct(t, "]") or isPunct(t, "}");
}

/// Tokens `[b, end)` without the comments that lead the next statement,
/// and the doc lines above `b`.
fn statement(tokens: []const Token, from: usize, b: usize, end_in: usize) !Statement {
    var end = end_in;
    while (end > b + 1 and tokens[end - 1].kind == .comment and tokens[end - 1].first_on_line) end -= 1;
    var doc_start = b;
    while (doc_start > from and tokens[doc_start - 1].kind == .comment and tokens[doc_start - 1].first_on_line and std.mem.startsWith(u8, tokens[doc_start - 1].text, "##")) doc_start -= 1;
    return .{ .tokens = tokens[b..end], .doc = tokens[doc_start..b] };
}

/// The index of the bracket that closes the one at `open`, or null.
pub fn matching(tokens: []const Token, open: usize) ?usize {
    const d = tokens[open].depth;
    var i = open + 1;
    while (i < tokens.len) : (i += 1) if (tokens[i].depth == d and isClosing(tokens[i])) return i;
    return null;
}

/// The source of `tokens` with each run of whitespace or comments between
/// two of them as one space: a multi-line type reads as one line.
pub fn text(gpa: Allocator, tokens: []const Token) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var prev_end: ?usize = null;
    for (tokens) |t| {
        if (t.kind == .comment) continue;
        if (prev_end) |e| if (t.offset != e) try out.append(gpa, ' ');
        try out.appendSlice(gpa, t.text);
        prev_end = t.offset + t.text.len;
    }
    return out.items;
}

test "strings, interpolations, comments and brackets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const toks = try tokenize(a, "x = \"a ] ${f(\"}\")} b\" # ] c\ny = '\\'' \\\\ line ] \"\nz = [\n    1,\n]\n");
    const want = [_]struct { Kind, []const u8, u32 }{
        .{ .lower, "x", 0 }, .{ .punct, "=", 0 }, .{ .string, "\"a ] ${f(\"}\")} b\"", 0 }, .{ .comment, "# ] c", 0 },
        .{ .lower, "y", 0 }, .{ .punct, "=", 0 }, .{ .char, "'\\''", 0 },                   .{ .string, "\\\\ line ] \"", 0 },
        .{ .lower, "z", 0 }, .{ .punct, "=", 0 }, .{ .punct, "[", 0 },                      .{ .number, "1", 1 },
        .{ .punct, ",", 1 }, .{ .punct, "]", 0 },
    };
    try std.testing.expectEqual(want.len, toks.len);
    for (want, toks) |w, t| {
        try std.testing.expectEqual(w[0], t.kind);
        try std.testing.expectEqualStrings(w[1], t.text);
        try std.testing.expectEqual(w[2], t.depth);
    }
    const sts = try statements(a, toks, 0, toks.len, 0);
    try std.testing.expectEqual(@as(usize, 3), sts.len);
    try std.testing.expectEqualStrings("z", sts[2].tokens[0].text);
    try std.testing.expectEqual(@as(usize, 6), sts[2].tokens.len);
}
