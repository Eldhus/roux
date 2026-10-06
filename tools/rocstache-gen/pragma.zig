//! The leading `{{% ... %}}` block of a template: Roc source that the
//! generator copies into the generated module as it is. The generator does
//! not parse Roc; it reads its statements from Roc tokens (roctok.zig:
//! strings and comments are never code) for what it needs to know:
//!
//! - which bare names a `| formatter` may use: names exposed by an
//!   `import Module exposing [a, b]` line, and the block's own top-level
//!   definitions (`name = ...` or `name : ...` at column 0);
//! - whether the block declares `Ctx`, the type `render` then takes.
//!
//! Type checking is left to roc.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const roctok = @import("roctok.zig");

pub const Import = struct {
    /// As written: `pf.Rocstache`, `../Formatters`, `../db/Links`.
    module: []const u8,
    exposing: []const []const u8,
    /// The name the module goes by in the template: the `as` alias, else
    /// the last segment (`Links` for `../db/Links`).
    name: []const u8,
};

pub const Pragma = struct {
    imports: []const Import = &.{},
    /// Top-level definitions of the block itself (local formatters, helpers).
    locals: []const []const u8 = &.{},
    /// The block defines `Ctx` (`Ctx : ...` or `Ctx(a) : ...`).
    declares_ctx: bool = false,
    /// How many type parameters `Ctx` has: `Ctx(others) : { ..., ..others }`
    /// is open, so `render` takes `Ctx(_)`, a record with at least those
    /// fields. 0 for a closed `Ctx`.
    ctx_params: usize = 0,
    /// Byte range of the `Ctx` definition in the block, with the `##` doc
    /// lines above it and its continuation lines: the generator moves it
    /// into the module, so apps can name it (`Grid.Ctx`).
    ctx_start: usize = 0,
    ctx_end: usize = 0,

    /// Whether a bare formatter name is in scope.
    pub fn defines(p: Pragma, name: []const u8) bool {
        for (p.locals) |l| if (std.mem.eql(u8, l, name)) return true;
        for (p.imports) |imp| for (imp.exposing) |e| if (std.mem.eql(u8, e, name)) return true;
        return false;
    }

    /// The import that exposes `name`, if any.
    pub fn importOf(p: Pragma, name: []const u8) ?Import {
        for (p.imports) |imp| for (imp.exposing) |e| if (std.mem.eql(u8, e, name)) return imp;
        return null;
    }
};

pub fn parse(gpa: Allocator, src: []const u8) !Pragma {
    const tokens = try roctok.tokenize(gpa, src);
    var imports: std.ArrayList(Import) = .empty;
    var locals: std.ArrayList([]const u8) = .empty;
    var p: Pragma = .{};
    for (try roctok.statements(gpa, tokens, 0, tokens.len, 0)) |st| {
        const code = try st.code(gpa);
        if (code.len == 0) continue;
        if (roctok.isLower(code[0], "import")) {
            try imports.append(gpa, try parseImport(gpa, code));
        } else if (code[0].kind == .upper and std.mem.eql(u8, code[0].text, "Ctx") and code.len > 1 and (roctok.isPunct(code[1], ":") or roctok.isPunct(code[1], "("))) {
            p.declares_ctx = true;
            if (roctok.isPunct(code[1], "(")) {
                const close = roctok.matching(code, 1) orelse code.len;
                for (code[2..close]) |t| {
                    if (t.kind == .lower) p.ctx_params += 1;
                }
            }
            // Its doc lines, through the end of its last line.
            p.ctx_start = lineStart(src, if (st.doc.len != 0) st.doc[0].offset else code[0].offset);
            const last = st.tokens[st.tokens.len - 1];
            p.ctx_end = @min((std.mem.indexOfScalarPos(u8, src, last.offset, '\n') orelse src.len) + 1, src.len);
        } else if (code[0].kind == .lower and code.len > 1 and (roctok.isPunct(code[1], ":") or roctok.isPunct(code[1], "="))) {
            var seen = false;
            for (locals.items) |l| if (std.mem.eql(u8, l, code[0].text)) {
                seen = true;
            };
            if (!seen) try locals.append(gpa, code[0].text);
        }
    }
    p.imports = try imports.toOwnedSlice(gpa);
    p.locals = try locals.toOwnedSlice(gpa);
    return p;
}

/// `import M`, `import M as N`, `import M exposing [a, b]`, in any layout.
fn parseImport(gpa: Allocator, code: []const roctok.Token) !Import {
    assert(roctok.isLower(code[0], "import"));
    var end: usize = 1;
    while (end < code.len and !roctok.isLower(code[end], "as") and !roctok.isLower(code[end], "exposing")) end += 1;
    const module = try roctok.text(gpa, code[1..end]);
    var name = module[if (std.mem.lastIndexOfAny(u8, module, "/.")) |cut| cut + 1 else 0..];
    var exposing: std.ArrayList([]const u8) = .empty;
    var i = end;
    while (i < code.len) : (i += 1) {
        if (roctok.isLower(code[i], "as") and i + 1 < code.len) name = code[i + 1].text;
        if (roctok.isLower(code[i], "exposing") and i + 1 < code.len and roctok.isPunct(code[i + 1], "[")) {
            const close = roctok.matching(code, i + 1) orelse code.len;
            for (code[i + 2 .. close]) |t| if (t.kind == .lower) try exposing.append(gpa, t.text);
            i = close;
        }
    }
    return .{ .module = module, .exposing = try exposing.toOwnedSlice(gpa), .name = name };
}

fn lineStart(src: []const u8, at: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, src[0..at], '\n')) |nl| nl + 1 else 0;
}

/// For completion while editing: when `src` (the block up to the cursor)
/// ends inside the `[` of an `import M exposing [`, the module and the
/// name being typed there.
pub fn openExposing(gpa: Allocator, src: []const u8) !?struct { module: []const u8, typed: []const u8 } {
    const tokens = try roctok.tokenize(gpa, src);
    const sts = try roctok.statements(gpa, tokens, 0, tokens.len, 0);
    if (sts.len == 0) return null;
    const code = try sts[sts.len - 1].code(gpa);
    if (code.len < 3 or !roctok.isLower(code[0], "import")) return null;
    var k: usize = 1;
    while (k + 1 < code.len and !roctok.isLower(code[k], "exposing")) k += 1;
    if (k + 1 >= code.len or !roctok.isPunct(code[k + 1], "[") or roctok.matching(code, k + 1) != null) return null;
    var module_end: usize = 1;
    while (module_end < k and !roctok.isLower(code[module_end], "as")) module_end += 1;
    const last = code[code.len - 1];
    const typed = if (last.kind == .lower and last.offset + last.text.len == src.len) last.text else "";
    return .{ .module = try roctok.text(gpa, code[1..module_end]), .typed = typed };
}

/// Where a top-level definition of `name` starts in the block, for errors.
pub fn definitionOffset(gpa: Allocator, src: []const u8, name: []const u8) !usize {
    const tokens = try roctok.tokenize(gpa, src);
    for (try roctok.statements(gpa, tokens, 0, tokens.len, 0)) |st| {
        const code = try st.code(gpa);
        if (code.len != 0 and std.mem.eql(u8, code[0].text, name)) return code[0].offset;
    }
    return 0;
}

/// The file a relative import names, from the template's directory:
/// `../Formatters` is `<dir>/../Formatters.roc`. Null for package imports
/// (`pf.Rocstache`).
pub fn relativeFile(gpa: Allocator, dir: []const u8, module: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, module, '.') != null and !std.mem.startsWith(u8, module, "../") and !std.mem.startsWith(u8, module, "./")) return null;
    return try std.fmt.allocPrint(gpa, "{s}/{s}.roc", .{ dir, module });
}

test "names a block brings into scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(),
        \\import pf.Rocstache exposing [plural, field]
        \\import ../Formatters exposing [
        \\    money,
        \\    ago,
        \\]
        \\import ../db/Links
        \\
        \\Ctx : { links : List(Links.Ranked) }
        \\
        \\## The host of a URL.
        \\host : Str -> Str
        \\host = |url|
        \\    url
        \\
    );
    try std.testing.expectEqual(@as(usize, 3), p.imports.len);
    try std.testing.expectEqualStrings("pf.Rocstache", p.imports[0].module);
    try std.testing.expectEqualStrings("../Formatters", p.imports[1].module);
    try std.testing.expectEqual(@as(usize, 2), p.imports[1].exposing.len);
    try std.testing.expect(p.defines("plural") and p.defines("ago") and p.defines("host"));
    try std.testing.expect(!p.defines("url"));
    try std.testing.expect(p.declares_ctx);
    try std.testing.expectEqualStrings("../Formatters", p.importOf("money").?.module);
    try std.testing.expectEqualStrings("Links", p.imports[2].name);
    const q = try parse(arena.allocator(), "import ../db/Events as Ev exposing [x]\n");
    try std.testing.expectEqualStrings("Ev", q.imports[0].name);
}

test "the Ctx definition's range, with its doc lines and continuations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\import ../db/Links
        \\
        \\## The page's links.
        \\Ctx : {
        \\    links : List(Links.Ranked),
        \\}
        \\Day : Str
        \\
    ;
    const p = try parse(arena.allocator(), src);
    try std.testing.expectEqualStrings("## The page's links.\nCtx : {\n    links : List(Links.Ranked),\n}\n", src[p.ctx_start..p.ctx_end]);
}

test "statements, not lines: blank lines, comments and strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\import ../Formatters exposing [
        \\    money, # not ] the end
        \\    ago,
        \\]
        \\
        \\Ctx : {
        \\    links : List(Str),
        \\
        \\    title : Str,
        \\}
        \\label = |x|
        \\    "import nope exposing [bad]
        \\note = "Ctx : ${label("a")}"
        \\
    ;
    const p = try parse(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 1), p.imports.len);
    try std.testing.expect(p.defines("money") and p.defines("ago") and p.defines("label") and p.defines("note"));
    try std.testing.expect(!p.defines("bad") and !p.defines("x"));
    try std.testing.expectEqualStrings("Ctx : {\n    links : List(Str),\n\n    title : Str,\n}\n", src[p.ctx_start..p.ctx_end]);
    try std.testing.expectEqual(std.mem.indexOf(u8, src, "Ctx :").?, try definitionOffset(arena.allocator(), src, "Ctx"));
}

test "completing inside an open exposing list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const open = (try openExposing(a, "import ../Other\nimport ../Formatters exposing [\n    money, # ] not closed\n    ag")).?;
    try std.testing.expectEqualStrings("../Formatters", open.module);
    try std.testing.expectEqualStrings("ag", open.typed);
    try std.testing.expect((try openExposing(a, "import ../Formatters exposing [money]\n")) == null);
    try std.testing.expectEqualStrings("", (try openExposing(a, "import pf.Rocstache exposing [")).?.typed);
}
