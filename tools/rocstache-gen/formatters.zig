//! Reads function signatures out of Roc source, for the language server's
//! hovers and completions (the generator itself needs no types): the
//! statements of the form `name : A, B, C -> Ret`, in any layout, among a
//! module's members (its `.{ ... }` block) or at the top of a template's
//! `{{% %}}` block. Statements come from Roc tokens (roctok.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;
const roctok = @import("roctok.zig");

pub const Sig = struct {
    name: []const u8,
    params: []const []const u8,
    ret: []const u8,
    offset: u32,
    /// Doc comment lines (`## ...`) right above the annotation, joined.
    doc: []const u8 = "",
};

/// Source of the platform's `Rocstache.roc`: `import pf.Rocstache`.
pub const builtin_src = @embedFile("builtin_formatters");

pub const Table = struct {
    sigs: []const Sig,

    pub fn find(t: Table, name: []const u8) ?Sig {
        for (t.sigs) |s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }

    pub const empty: Table = .{ .sigs = &.{} };
};

/// Returns true for type variables (`a`, `elem`) and anything starting with a
/// lowercase letter, which cannot be used in a monomorphic context record.
pub fn isGenericType(text: []const u8) bool {
    return text.len == 0 or std.ascii.isLower(text[0]) or text[0] == '_';
}

/// Signatures in a module's `Name :: [].{ ... }` block (what the module
/// exposes; top-level helpers after it are private).
pub fn parse(gpa: Allocator, src: []const u8) !Table {
    const tokens = try roctok.tokenize(gpa, src);
    // The first `{` opened at depth 0 after `::` holds the module's members.
    var i: usize = 0;
    var seen_type = false;
    while (i < tokens.len) : (i += 1) {
        if (tokens[i].depth == 0 and roctok.isPunct(tokens[i], "::")) seen_type = true;
        if (seen_type and tokens[i].depth == 0 and roctok.isPunct(tokens[i], "{")) break;
    }
    if (i == tokens.len) return .empty;
    const close = roctok.matching(tokens, i) orelse tokens.len;
    return signatures(gpa, try roctok.statements(gpa, tokens, i + 1, close, 1));
}

/// Signatures at the top level (a template's `{{% %}}` block).
pub fn parseTopLevel(gpa: Allocator, src: []const u8) !Table {
    const tokens = try roctok.tokenize(gpa, src);
    return signatures(gpa, try roctok.statements(gpa, tokens, 0, tokens.len, 0));
}

/// The statements that are `name : A, B -> Ret` (any layout; a `where`
/// clause is dropped).
fn signatures(gpa: Allocator, statements: []const roctok.Statement) !Table {
    var sigs: std.ArrayList(Sig) = .empty;
    for (statements) |st| {
        const code = try st.code(gpa);
        if (code.len < 3 or code[0].kind != .lower or !roctok.isPunct(code[1], ":")) continue;
        const d = code[1].depth;
        var end = code.len;
        for (code[2..], 2..) |t, k| if (t.depth == d and roctok.isLower(t, "where")) {
            end = k;
            break;
        };
        // The last `->` at the signature's own depth separates params from the return type.
        var arrow: ?usize = null;
        for (code[2..end], 2..) |t, k| if (t.depth == d and roctok.isPunct(t, "->")) {
            arrow = k;
        };
        const a = arrow orelse continue;
        var params: std.ArrayList([]const u8) = .empty;
        var start: usize = 2;
        for (code[2 .. a + 1], 2..) |t, k| if (k == a or (t.depth == d and roctok.isPunct(t, ","))) {
            if (k > start) try params.append(gpa, try roctok.text(gpa, code[start..k]));
            start = k + 1;
        };
        // `() -> Ret` takes nothing.
        if (params.items.len == 1 and std.mem.eql(u8, params.items[0], "()")) params.clearRetainingCapacity();
        try sigs.append(gpa, .{ .name = code[0].text, .params = params.items, .ret = try roctok.text(gpa, code[a + 1 .. end]), .offset = code[0].offset, .doc = try docText(gpa, st.doc) });
    }
    return .{ .sigs = try sigs.toOwnedSlice(gpa) };
}

/// The `## ...` lines above a statement, without the `## `.
fn docText(gpa: Allocator, doc: []const roctok.Token) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    for (doc) |t| try lines.append(gpa, std.mem.trim(u8, t.text[2..], " \r"));
    return std.mem.join(gpa, "\n", lines.items);
}

test "parse signatures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\Formatters :: [].{
        \\    ## Escape.
        \\    escape : Str -> Str
        \\    escape = |s| s
        \\
        \\    money : Dec, Str -> Str
        \\    money = |d, cur| cur
        \\
        \\    pick : List({ a : Str, b : U64 }), U64 -> Str
        \\    pick = |l, i| ""
        \\
        \\    inspect : a -> Str where [a.to_str : a -> Str]
        \\    inspect = |v| v.to_str()
        \\}
        \\helper : Str -> Str
        \\helper = |s| s
    ;
    const t = try parse(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 4), t.sigs.len);
    try std.testing.expect(t.find("helper") == null);
    const money = t.find("money").?;
    try std.testing.expectEqual(@as(usize, 2), money.params.len);
    try std.testing.expectEqualStrings("Dec", money.params[0]);
    try std.testing.expectEqualStrings("Str", money.params[1]);
    try std.testing.expectEqualStrings("Str", money.ret);
    const pick = t.find("pick").?;
    try std.testing.expectEqualStrings("List({ a : Str, b : U64 })", pick.params[0]);
    try std.testing.expectEqualStrings("U64", pick.params[1]);
    const insp = t.find("inspect").?;
    try std.testing.expect(isGenericType(insp.params[0]));
    try std.testing.expect(t.find("nope") == null);
}

test "signatures are statements: multi-line ones count, look-alikes do not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\Formatters :: [].{
        \\    ## Joins a list.
        \\    ## With commas.
        \\    join :
        \\        List(Str),
        \\        Str
        \\        -> Str
        \\    join = |items, sep| {
        \\        inner : Str -> Str
        \\        inner = |s| s
        \\        Str.join_with(items.map(inner), sep)
        \\    }
        \\
        \\    note = "fake : Str -> Str"
        \\}
    ;
    const t = try parse(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 1), t.sigs.len);
    const join = t.find("join").?;
    try std.testing.expectEqual(@as(usize, 2), join.params.len);
    try std.testing.expectEqualStrings("List(Str)", join.params[0]);
    try std.testing.expectEqualStrings("Str", join.ret);
    try std.testing.expectEqualStrings("Joins a list.\nWith commas.", join.doc);
}
