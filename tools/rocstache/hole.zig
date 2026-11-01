//! A hole's expression, `{{ Fmt.kr(dish.price) }}`: Roc, of the small
//! subset a hole may hold, read for its free names and the paths it reads
//! under them. The build pastes the expression as written into a Roc
//! function whose parameters are those names, so Roc checks and compiles
//! it, and Roc's errors quote it; this parser only has to find, exactly,
//! what the expression reads of the scope.
//!
//! The subset: number and string literals (`${}` interpolation included),
//! names, `Module.name` and tags, `.field` access, calls `f(x)` and method
//! calls `x.f(y)`, Roc's binary operators (`* / // % + - ?? == != < <= > >=
//! and or`), prefix `-` and `!`, and parentheses. Anything else is refused
//! at its byte: a hole holds a small expression, and the rest goes in a
//! function.
//!
//! A free name is a lowercase name that is not a field or a method: the
//! scope's field or a section's binder. The fields after it, up to a method
//! call, are the path it reads (`dish.name` of `dish.name.len()`).
//!
//! It allocates nothing and does not recurse: brackets, calls, strings and
//! their interpolations are an explicit stack, bounded.

const std = @import("std");
const assert = std.debug.assert;
const parse = @import("parse.zig");

pub const bytes_max = 1024;
pub const reads_max = 16;
pub const depth_max = 16;

comptime {
    assert(bytes_max <= std.math.maxInt(u16));
    assert(reads_max <= std.math.maxInt(u8));
    assert(depth_max <= std.math.maxInt(u8));
}

pub const small = "a hole holds a small expression; put the rest in a function";
const effect = "is an effect, which a hole cannot run";

/// A free name and the fields read after it, `dish.price`.
pub const Read = struct {
    path: [parse.path_max][]const u8 = @splat(""),
    path_len: u8 = 0,
    /// The name's byte offset in the expression.
    offset: u16,

    pub fn path_slice(read: *const Read) []const []const u8 {
        return read.path[0..read.path_len];
    }
};

pub const Hole = struct {
    /// The expression is one path and nothing more (`dish.name`).
    bare: bool = false,
    /// The expression is one path and its `.to_str()`, nothing more
    /// (`dish.price.to_str()`): an integer's, the renderer prints itself.
    to_str: bool = false,
    reads: [reads_max]Read = undefined,
    reads_len: u8 = 0,

    pub fn read_slice(hole: *const Hole) []const Read {
        return hole.reads[0..hole.reads_len];
    }
};

/// What is open where the parser stands: each pushed on its opening byte,
/// popped on its closing one.
const Frame = enum { paren, call, string, interpolation };

/// What the next token may be.
const State = enum { operand, operator };

/// Each binary operator, the longer before the shorter it starts with.
const operators = [_][]const u8{
    "//", "??", "==", "!=", "<=", ">=", "+", "-", "*", "/", "%", "<", ">",
};

pub fn of(text: []const u8, diagnostic: *parse.Diagnostic) parse.Error!Hole {
    if (text.len > bytes_max) return refuse(diagnostic, 0, "is too long for a hole: " ++ small, "");
    var p: Parser = .{ .text = text, .diagnostic = diagnostic };
    // Every step consumes at least one byte.
    for (0..text.len + 1) |_| {
        if (p.at == text.len) break;
        const before = p.at;
        if (p.top() == .string) {
            try p.string_byte();
        } else switch (p.state) {
            .operand => try p.operand(),
            .operator => try p.operator(),
        }
        assert(p.at > before);
    } else unreachable;
    assert(p.at == text.len);
    if (p.frames_len > 0) return p.fail(text.len, switch (p.top().?) {
        .paren, .call => "is missing a `)`",
        .string => "is missing a string's closing `\"`",
        .interpolation => "is missing an interpolation's `}`",
    }, "");
    if (p.state == .operand) return p.fail(text.len, "ends where a value should follow", "");
    p.hole.bare = p.tokens == 1 and p.hole.reads_len == 1;
    p.hole.to_str = p.hole.reads_len == 1 and printed(text, &p.hole.reads[0]);
    assert(!(p.hole.bare and p.hole.to_str));
    assert(p.hole.reads_len <= reads_max);
    return p.hole;
}

/// Whether the parsed `text` is the read's path and then `.to_str()`. A
/// read's path stops where its first method starts (`free_name`), so after
/// a parse that accepted the whole expression, these bytes following the
/// path can only be that one call.
fn printed(text: []const u8, read: *const Read) bool {
    assert(read.path_len > 0);
    const space = " \t\r\n";
    if (std.mem.trimStart(u8, text[0..read.offset], space).len > 0) return false;
    const last = read.path[read.path_len - 1];
    const end = @intFromPtr(last.ptr) + last.len - @intFromPtr(text.ptr);
    assert(end <= text.len);
    return std.mem.eql(u8, std.mem.trimEnd(u8, text[end..], space), ".to_str()");
}

const Parser = struct {
    text: []const u8,
    at: u16 = 0,
    state: State = .operand,
    frames: [depth_max]Frame = undefined,
    frames_len: u8 = 0,
    /// Whitespace came right before this byte.
    spaced: bool = false,
    /// Operands and operators read: a bare path is one.
    tokens: u16 = 0,
    hole: Hole = .{},
    diagnostic: *parse.Diagnostic,

    fn top(p: *const Parser) ?Frame {
        return if (p.frames_len == 0) null else p.frames[p.frames_len - 1];
    }

    fn push(p: *Parser, frame: Frame) parse.Error!void {
        if (p.frames_len == depth_max) return p.fail(p.at, "nests too deep: " ++ small, "");
        p.frames[p.frames_len] = frame;
        p.frames_len += 1;
    }

    fn pop(p: *Parser, frame: Frame) void {
        assert(p.top() == frame);
        p.frames_len -= 1;
    }

    fn fail(p: *Parser, offset: usize, message: []const u8, subject: []const u8) parse.Error {
        return refuse(p.diagnostic, offset, message, subject);
    }

    fn byte(p: *const Parser, offset: usize) u8 {
        return if (offset < p.text.len) p.text[offset] else 0;
    }

    /// Where a value may start.
    fn operand(p: *Parser) parse.Error!void {
        const c = p.text[p.at];
        if (is_space(c)) {
            p.at += 1;
            return;
        }
        p.tokens += 1;
        switch (c) {
            '-', '!' => p.at += 1, // prefix: a value still follows
            '(' => {
                try p.push(.paren);
                p.at += 1;
            },
            ')' => try p.call_closed_empty(),
            ',' => return p.fail(p.at, "is where a value should be", ","),
            '"' => {
                if (std.mem.startsWith(u8, p.text[p.at..], "\"\"\"")) {
                    return p.fail(p.at, "is a multi-line string: " ++ small, "");
                }
                // What follows the closed string is an operator's place.
                p.state = .operator;
                try p.push(.string);
                p.at += 1;
            },
            '0'...'9' => try p.number(),
            'a'...'z', '_' => try p.free_name(),
            'A'...'Z' => try p.qualified(),
            else => return p.fail(p.at, small, p.text[p.at .. p.at + 1]),
        }
    }

    /// `f()` or `f(x,)`: a call's `)` where its next argument would be.
    fn call_closed_empty(p: *Parser) parse.Error!void {
        const before = std.mem.trimEnd(u8, p.text[0..p.at], " \t\r\n");
        const after_open = before.len > 0 and (before[before.len - 1] == '(' or
            before[before.len - 1] == ',');
        if (p.top() != .call or !after_open) return p.fail(p.at, "is where a value should be", ")");
        p.pop(.call);
        p.at += 1;
        p.state = .operator;
    }

    fn number(p: *Parser) parse.Error!void {
        const start = p.at;
        const base = std.mem.indexOfScalar(u8, "xob", p.byte(p.at + 1));
        const prefixed = p.text[p.at] == '0' and base != null;
        if (prefixed) p.at += 2;
        const digits_start = p.at;
        p.skip_word();
        if (p.at == digits_start) return p.fail(start, "is a number without digits", "");
        if (!prefixed and p.byte(p.at) == '.' and std.ascii.isDigit(p.byte(p.at + 1))) {
            p.at += 1;
            p.skip_word();
        }
        const written = p.text[start..p.at];
        const valid = for (written[if (prefixed) 2 else 0..]) |c| {
            const digit = if (prefixed) std.ascii.isHex(c) else std.ascii.isDigit(c) or c == '.';
            if (!(digit or c == '_')) break false;
        } else true;
        if (!valid) return p.fail(start, "is a number with a suffix: " ++ small, written);
        p.state = .operator;
    }

    /// A name's bytes, `[A-Za-z0-9_]*`, from where the parser stands.
    fn skip_word(p: *Parser) void {
        while (p.at < p.text.len and is_word(p.text[p.at])) p.at += 1;
    }

    /// A name of the scope, then the fields read after it up to a method.
    fn free_name(p: *Parser) parse.Error!void {
        const start = p.at;
        p.skip_word();
        const name = p.text[start..p.at];
        if (p.byte(p.at) == '!') return p.fail(start, effect, name);
        if (parse.is_keyword(name)) return p.fail(start, small, name);
        if (p.hole.reads_len == reads_max) {
            return p.fail(start, "reads too many names: " ++ small, name);
        }
        var read: Read = .{ .offset = start };
        read.path[0] = name;
        read.path_len = 1;
        while (p.byte(p.at) == '.' and is_lower(p.byte(p.at + 1))) {
            var end = p.at + 1;
            while (end < p.text.len and is_word(p.text[end])) end += 1;
            // A method call, or an effect the operator refuses.
            if (p.byte(end) == '(' or p.byte(end) == '!') break;
            if (read.path_len == parse.path_max) {
                return p.fail(p.at + 1, "reads a path too deep for a hole: " ++ small, name);
            }
            read.path[read.path_len] = p.text[p.at + 1 .. end];
            read.path_len += 1;
            p.at = end;
        }
        p.hole.reads[p.hole.reads_len] = read;
        p.hole.reads_len += 1;
        p.state = .operator;
    }

    /// `Fmt.kr`, `Bool.True`, `Ok`: a module's value, or a tag.
    fn qualified(p: *Parser) parse.Error!void {
        const start = p.at;
        p.skip_word();
        while (p.byte(p.at) == '.' and std.ascii.isAlphabetic(p.byte(p.at + 1))) {
            const lower = is_lower(p.byte(p.at + 1));
            p.at += 1;
            p.skip_word();
            if (lower) break; // a module's value ends the name
        }
        if (p.byte(p.at) == '!') {
            return p.fail(start, effect, p.text[start..p.at]);
        }
        p.state = .operator;
    }

    /// Where an operator, a call, a field or a closing bracket may stand.
    fn operator(p: *Parser) parse.Error!void {
        const c = p.text[p.at];
        const spaced = p.spaced;
        p.spaced = false;
        if (is_space(c)) {
            p.spaced = true;
            p.at += 1;
            return;
        }
        switch (c) {
            '.' => try p.field(spaced),
            '(' => {
                if (spaced) {
                    return p.fail(p.at, "is a call's `(`, which follows its function", "(");
                }
                p.tokens += 1;
                try p.push(.call);
                p.at += 1;
                p.state = .operand;
            },
            ')' => {
                const frame = p.top();
                if (frame != .paren and frame != .call) return p.fail(p.at, "has no `(`", ")");
                p.pop(frame.?);
                p.at += 1;
            },
            ',' => {
                if (p.top() != .call) return p.fail(p.at, small, ",");
                p.at += 1;
                p.state = .operand;
            },
            '}' => {
                if (p.top() != .interpolation) return p.fail(p.at, small, "}");
                p.pop(.interpolation);
                p.at += 1;
            },
            '?' => {
                if (p.byte(p.at + 1) == '?') return p.binary();
                return p.fail(p.at, "returns early, which a hole cannot", "?");
            },
            else => try p.binary(),
        }
    }

    /// `.name` after a value: a field, or a method the next `(` calls.
    fn field(p: *Parser, spaced: bool) parse.Error!void {
        if (spaced) return p.fail(p.at, "is a field or method, which follows its value", ".");
        const start = p.at + 1;
        if (std.ascii.isDigit(p.byte(start))) {
            return p.fail(start, "is a tuple's element: a hole reads fields by name", "");
        }
        if (!is_lower(p.byte(start))) return p.fail(p.at, small, ".");
        p.at += 1;
        p.skip_word();
        const name = p.text[start..p.at];
        if (p.byte(p.at) == '!') return p.fail(start, effect, name);
        p.tokens += 1;
    }

    fn binary(p: *Parser) parse.Error!void {
        const rest = p.text[p.at..];
        const symbol: ?[]const u8 = for (operators) |o| {
            if (std.mem.startsWith(u8, rest, o)) break o;
        } else null;
        const word = for ([_][]const u8{ "and", "or" }) |w| {
            const whole = !is_word(p.byte(p.at + w.len));
            if (std.mem.startsWith(u8, rest, w) and whole) break w;
        } else null;
        const taken = symbol orelse word orelse {
            const end = p.at + @as(u16, @intFromBool(p.at < p.text.len));
            return p.fail(p.at, small, p.text[p.at..end]);
        };
        p.at += @intCast(taken.len);
        p.tokens += 1;
        p.state = .operand;
    }

    /// Inside a string: its bytes, escapes and interpolations.
    fn string_byte(p: *Parser) parse.Error!void {
        switch (p.text[p.at]) {
            '"' => {
                p.pop(.string);
                p.at += 1;
                p.state = .operator;
            },
            '\n' => return p.fail(p.at, "is a string that does not end on its line", ""),
            '\\' => try p.escape(),
            '$' => {
                if (p.byte(p.at + 1) != '{') {
                    p.at += 1;
                    return;
                }
                try p.push(.interpolation);
                p.at += 2;
                p.state = .operand;
            },
            else => p.at += 1,
        }
    }

    /// `\\`, `\"`, `\n`, `\r`, `\t`, `\$` or `\u(` hex digits `)`.
    fn escape(p: *Parser) parse.Error!void {
        const start = p.at;
        const c = p.byte(p.at + 1);
        if (std.mem.indexOfScalar(u8, "\\\"nrt$", c) != null) {
            p.at += 2;
            return;
        }
        if (c == 'u' and p.byte(p.at + 2) == '(') {
            var end = p.at + 3;
            while (end < p.text.len and std.ascii.isHex(p.text[end])) end += 1;
            if (end > p.at + 3 and end - (p.at + 3) <= 6 and p.byte(end) == ')') {
                p.at = end + 1;
                return;
            }
        }
        const end = @min(p.text.len, start + 2);
        return p.fail(start, "is not one of Roc's escapes", p.text[start..end]);
    }
};

fn refuse(
    diagnostic: *parse.Diagnostic,
    offset: usize,
    message: []const u8,
    subject: []const u8,
) parse.Error {
    diagnostic.* = .{ .offset = @intCast(offset), .message = message, .subject = subject };
    return error.Invalid;
}

fn is_space(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn is_word(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn is_lower(c: u8) bool {
    return std.ascii.isLower(c) or c == '_';
}

const testing = std.testing;

/// `text` `count` times, called at comptime.
fn repeat(comptime text: []const u8, comptime count: usize) []const u8 {
    @setEvalBranchQuota(4 * count);
    var out: []const u8 = "";
    for (0..count) |_| out = out ++ text;
    return out;
}

fn expect_reads(text: []const u8, bare: bool, expected: []const []const u8) !void {
    var diagnostic: parse.Diagnostic = .{};
    const hole = of(text, &diagnostic) catch |err| {
        const at = diagnostic.offset;
        std.debug.print("`{s}` refused at {d}: {s}\n", .{ text, at, diagnostic.message });
        return err;
    };
    try testing.expectEqual(bare, hole.bare);
    try testing.expectEqual(expected.len, hole.reads_len);
    for (hole.read_slice(), expected) |read, path| {
        var joined: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&joined);
        for (read.path_slice(), 0..) |segment, i| {
            if (i > 0) try writer.writeByte('.');
            try writer.writeAll(segment);
        }
        try testing.expectEqualStrings(path, writer.buffered());
        try testing.expectEqualStrings(read.path[0], text[read.offset..][0..read.path[0].len]);
    }
}

fn expect_refused(text: []const u8, offset: u32, message: []const u8) !void {
    var diagnostic: parse.Diagnostic = .{};
    if (of(text, &diagnostic)) |_| {
        std.debug.print("`{s}` was not refused\n", .{text});
        return error.TestUnexpectedResult;
    } else |_| {}
    try testing.expectEqual(offset, diagnostic.offset);
    try testing.expect(std.mem.indexOf(u8, diagnostic.message, message) != null);
}

test "hole: a path alone is bare; its fields are what it reads" {
    try expect_reads("title", true, &.{"title"});
    try expect_reads(" dish.name ", true, &.{"dish.name"});
    try expect_reads("a.b.c.d", true, &.{"a.b.c.d"});
    try expect_reads("(dish.name)", false, &.{"dish.name"});
    try expect_reads("_x", true, &.{"_x"});
}

test "hole: free names and their paths, up to a method" {
    try expect_reads("dish.id.to_str()", false, &.{"dish.id"});
    try expect_reads("dishes.len().to_str()", false, &.{"dishes"});
    try expect_reads("Fmt.kr(dish.price)", false, &.{"dish.price"});
    try expect_reads("Fmt.plural(dishes.len(), \"dish\", \"dishes\")", false, &.{"dishes"});
    try expect_reads("a.b.c(d.e, f).g.h()", false, &.{ "a.b", "d.e", "f" });
    try expect_reads("Str.concat(first, Str.concat(\" \", last))", false, &.{ "first", "last" });
    try expect_reads("f()", false, &.{"f"});
    try expect_reads("Fmt.kr(x,)", false, &.{"x"});
    try expect_reads("Bool.True", false, &.{});
    try expect_reads("Ok(x).with_default(y)", false, &.{ "x", "y" });
    try expect_reads("\"plain\"", false, &.{});
}

test "hole: a path's `.to_str()` alone is marked, nothing else" {
    const marked = [_][]const u8{ "price.to_str()", " dish.price.to_str() ", "a.b.c.d.to_str()" };
    const unmarked = [_][]const u8{
        "price",
        "(price).to_str()",
        "price.to_str().trim()",
        "price.to_str() == x",
        "price.to_str(x)",
        "\"${price.to_str()}\"",
        "-price.to_str()",
        "price.len().to_str()",
        "Num.to_str(price)",
        "(a + b).to_str()",
        "price.to_utf8()",
        "f(price).to_str()",
    };
    for (marked ++ unmarked, 0..) |text, k| {
        var diagnostic: parse.Diagnostic = .{};
        const hole = of(text, &diagnostic) catch |err| {
            std.debug.print("`{s}` refused: {s}\n", .{ text, diagnostic.message });
            return err;
        };
        errdefer std.debug.print("case `{s}`\n", .{text});
        try testing.expectEqual(k < marked.len, hole.to_str);
    }
}

test "hole: operators, prefixes, numbers" {
    try expect_reads("(a + b * 2).to_str()", false, &.{ "a", "b" });
    try expect_reads("if_x // 2 % 3 - -n", false, &.{ "if_x", "n" });
    try expect_reads("(x ?? 0).to_str()", false, &.{"x"});
    try expect_reads("(a.n >= 1 and !b or c != d).to_str()", false, &.{ "a.n", "b", "c", "d" });
    try expect_reads("a<b", false, &.{ "a", "b" });
    try expect_reads("(1_000 + 2.5 + 0xff + 0b1 + 0o7).to_str()", false, &.{});
    try expect_reads("orange and android", false, &.{ "orange", "android" });
}

test "hole: strings, escapes and interpolations, nested" {
    try expect_reads("\"${price.to_str()} kr\"", false, &.{"price"});
    try expect_reads("\"${a} and ${\"${b.c}\"}\"", false, &.{ "a", "b.c" });
    try expect_reads("\"\\\" \\\\ \\n \\t \\$ \\u(1F600) $5\"", false, &.{});
    try expect_reads("\"{ } ( ) , ? | #\"", false, &.{});
}

test "hole: what the subset leaves out is refused at its byte" {
    try expect_refused("", 0, "ends where a value should follow");
    try expect_refused("   ", 3, "ends where a value should follow");
    try expect_refused("a +", 3, "ends where a value should follow");
    try expect_refused("if a then b else c", 0, small);
    try expect_refused("match x { }", 0, small);
    try expect_refused("|x| x", 0, small);
    try expect_refused("{ a: 1 }", 0, small);
    try expect_refused("[1, 2]", 0, small);
    try expect_refused("x |> f", 2, small);
    try expect_refused("a = b", 2, small);
    try expect_refused("x # a comment", 2, small);
    try expect_refused("'a'", 0, small);
    try expect_refused("a b", 2, small);
    try expect_refused("1..<5", 1, small);
    try expect_refused("x.f(y)?", 6, "returns early");
    try expect_refused("Try.ok(x) ? E", 10, "returns early");
}

test "hole: spacing, brackets and names Roc would read otherwise" {
    try expect_refused("f (x)", 2, "follows its function");
    try expect_refused("dish .name", 5, "follows its value");
    try expect_refused("dish.", 4, small);
    try expect_refused("t.0", 2, "a tuple's element");
    try expect_refused("(a", 2, "is missing a `)`");
    try expect_refused("f(a, b", 6, "is missing a `)`");
    try expect_refused("a)", 1, "has no `(`");
    try expect_refused("(a,b)", 2, small);
    try expect_refused("f(,)", 2, "where a value should be");
    try expect_refused("()", 1, "where a value should be");
    try expect_refused("a}", 1, small);
    try expect_refused("a.b.c.d.e", 8, "too deep");
}

test "hole: effects, literals and strings it cannot hold" {
    try expect_refused("read!(x)", 0, "an effect");
    try expect_refused("Stdout.line!(x)", 0, "an effect");
    try expect_refused("x.save!()", 2, "an effect");
    try expect_refused("a.b.write!()", 4, "an effect");
    try expect_refused("5u8", 0, "a suffix");
    try expect_refused("0x", 0, "without digits");
    try expect_refused("0xfg", 0, "a suffix");
    try expect_refused("\"open", 5, "closing `\"`");
    try expect_refused("\"${a\"", 4, small);
    try expect_refused("\"${a", 4, "interpolation's `}`");
    try expect_refused("\"a\nb\"", 2, "does not end on its line");
    try expect_refused("\"\\q\"", 1, "Roc's escapes");
    try expect_refused("\"\\u(\"", 1, "Roc's escapes");
    try expect_refused("\"\"\"a\"\"\"", 0, "multi-line");
}

test "hole: its bounds" {
    const over = depth_max + 1;
    const too_deep = comptime repeat("(", over) ++ "a" ++ repeat(")", over);
    try expect_refused(too_deep, depth_max, "nests too deep");
    const deepest = comptime repeat("(", depth_max) ++ "a" ++ repeat(")", depth_max);
    try expect_reads(deepest, false, &.{"a"});
    const names = comptime repeat("a + ", reads_max) ++ "a";
    try expect_refused(names, reads_max * 4, "too many names");
    try expect_refused(comptime repeat("a", bytes_max + 1), 0, "too long");
}
