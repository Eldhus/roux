//! A template's `{{% %}}` block: `import` lines (`import Fmt`, `import
//! pf.Url`), the modules its holes' Roc may name, then its declared
//! contract, `Ctx : <type>`, and nothing else but `#` comments (the `##`
//! lines right above `Ctx` are its documentation, copied into the
//! generated module). A block of imports alone leaves the contract inferred.
//!
//! The types a contract may spell: `Str`, `Bool`, the integers `U8` to
//! `I64`, `List(T)`, records `{ name : T, ... }`, and any other type name
//! (`F64`, `Dec`), which a template may carry but not print. A type from
//! another module is refused: the contract is spelled out, since glue lays
//! it out alone.

const std = @import("std");
const assert = std.debug.assert;
const parse = @import("parse.zig");
const contract_ = @import("contract.zig");
const Contract = contract_.Contract;
const Error = contract_.Error;

const depth_max = 32;

const Token = struct {
    kind: enum { name, punct, end },
    text: []const u8,
    offset: u32,
};

const Reader = struct {
    block: []const u8,
    /// The block's offset in the template, so messages point into the file.
    base: u32,
    at: usize = 0,
    diagnostic: *contract_.Diagnostic,
    template: []const u8,

    fn fail(reader: *Reader, offset: u32, message: []const u8, subject: []const u8) Error {
        reader.diagnostic.* = .{
            .template = reader.template,
            .offset = reader.base + offset,
            .message = message,
            .subject = subject,
        };
        return error.Invalid;
    }

    fn fail_token(reader: *Reader, token: Token, message: []const u8) Error {
        return reader.fail(token.offset, message, token.text);
    }

    /// The next token, skipping space and `#` comments.
    fn next(reader: *Reader) Token {
        const block = reader.block;
        while (reader.at < block.len) {
            const c = block[reader.at];
            if (c == '#') {
                reader.at = std.mem.indexOfScalarPos(u8, block, reader.at, '\n') orelse block.len;
            } else if (std.ascii.isWhitespace(c)) {
                reader.at += 1;
            } else break;
        }
        const start = reader.at;
        if (start == block.len) return .{ .kind = .end, .text = "", .offset = @intCast(start) };
        const name = std.ascii.isAlphabetic(block[start]) or block[start] == '_';
        if (name) {
            while (reader.at < block.len and name_byte(block[reader.at])) reader.at += 1;
        } else {
            reader.at += 1;
        }
        return .{
            .kind = if (name) .name else .punct,
            .text = block[start..reader.at],
            .offset = @intCast(start),
        };
    }

    fn expect(reader: *Reader, text: []const u8) Error!Token {
        const token = reader.next();
        if (!std.mem.eql(u8, token.text, text)) {
            return reader.fail(token.offset, "the contract expects something else here", text);
        }
        return token;
    }

    fn type_(reader: *Reader, contract: *Contract, depth: u8) Error!u16 {
        if (depth == depth_max) {
            return reader.fail(@intCast(reader.at), "the contract nests too deep", "");
        }
        const token = reader.next();
        const offset = reader.base + token.offset;
        if (std.mem.eql(u8, token.text, "{")) return reader.record(contract, offset, depth);
        if (token.kind != .name or !std.ascii.isUpper(token.text[0])) {
            return reader.fail_token(token, "expected a type (`Str`, `List(…)`, `{ … }`)");
        }
        if (std.mem.indexOfScalar(u8, token.text, '.') != null) {
            return reader.fail_token(token, "spell the type out: glue lays out the contract alone");
        }
        if (std.mem.eql(u8, token.text, "List")) {
            _ = try reader.expect("(");
            const list = try reader.new(contract, .list, offset);
            const element = try reader.type_(contract, depth + 1);
            contract.types[list].element = element;
            _ = try reader.expect(")");
            return list;
        }
        const kind: contract_.Kind = if (std.mem.eql(u8, token.text, "Str"))
            .str
        else if (std.mem.eql(u8, token.text, "Bool"))
            .bool
        else if (contract_.is_int_name(token.text)) .int else .other;
        const index = try reader.new(contract, kind, offset);
        contract.types[index].name = token.text;
        return index;
    }

    fn record(reader: *Reader, contract: *Contract, offset: u32, depth: u8) Error!u16 {
        const index = try reader.new(contract, .record, offset);
        for (0..contract_.fields_max + 1) |_| {
            const name = reader.next();
            if (std.mem.eql(u8, name.text, "}")) return index;
            if (name.kind != .name or !parse.is_field_name(name.text)) {
                return reader.fail_token(name, "expected a field name");
            }
            if (parse.is_keyword(name.text)) return reader.fail_token(name, parse.keyword_message);
            if (contract.field(index, name.text) != null) {
                return reader.fail_token(name, "is a field twice");
            }
            _ = try reader.expect(":");
            const child = try reader.type_(contract, depth + 1);
            contract_.new_field(contract, index, name.text, child) catch
                return reader.fail_token(name, "the contract has too many fields");
            const after = reader.next();
            if (std.mem.eql(u8, after.text, "}")) return index;
            if (!std.mem.eql(u8, after.text, ",")) {
                return reader.fail_token(after, "expected `,` or `}`");
            }
        }
        return reader.fail(offset - reader.base, "the contract has too many fields", "");
    }

    /// `import Fmt` or `import pf.Url`, after the `import`.
    fn import(reader: *Reader, contract: *Contract) Error!void {
        const name = reader.next();
        const module = if (std.mem.startsWith(u8, name.text, "pf.")) name.text[3..] else name.text;
        if (name.kind != .name or !parse.is_type_name(module)) {
            return reader.fail_token(name, "expected a module's name, like `Fmt` or `pf.Url`");
        }
        for (contract.import_slice()) |earlier| {
            if (std.mem.eql(u8, earlier, name.text)) {
                return reader.fail_token(name, "is imported twice");
            }
        }
        if (contract.imports_len == contract_.imports_max) {
            return reader.fail_token(name, "the block imports too many modules");
        }
        contract.imports[contract.imports_len] = name.text;
        contract.imports_len += 1;
    }

    fn new(reader: *Reader, contract: *Contract, kind: contract_.Kind, offset: u32) Error!u16 {
        return contract_.new_type(contract, kind, offset) catch
            reader.fail(offset - reader.base, "the contract has too many types", "");
    }
};

fn name_byte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b == '.';
}

pub fn read(
    contract: *Contract,
    template: contract_.Template,
    diagnostic: *contract_.Diagnostic,
) Error!void {
    const tree = template.tree;
    var reader: Reader = .{
        .block = tree.block,
        .base = tree.block_offset,
        .diagnostic = diagnostic,
        .template = template.name,
    };
    var first = reader.next();
    // At most one more than fits: `import` refuses that one.
    for (0..contract_.imports_max + 1) |_| {
        if (!std.mem.eql(u8, first.text, "import")) break;
        try reader.import(contract);
        first = reader.next();
    } else unreachable;
    // Imports alone: the contract is inferred from the tags.
    if (first.kind == .end) return;
    if (!std.mem.eql(u8, first.text, "Ctx")) {
        return reader.fail_token(first, block_holds);
    }
    _ = try reader.expect(":");
    contract.root = try reader.type_(contract, 0);
    if (contract.get(contract.root).kind != .record) {
        return reader.fail(first.offset, "the contract is a record, `Ctx : { … }`", "Ctx");
    }
    const end = reader.next();
    if (end.kind != .end) return reader.fail_token(end, block_holds);
    contract.docs = docs_above(tree.block, first.offset);
    contract.declared = true;
}

const block_holds = "the `{{%` block holds `import` lines, then the contract, `Ctx : { … }`";

/// Whether the block declares `Ctx` after its imports. Lenient: a block
/// that is neither is read, and refused, when its own template is.
pub fn has_ctx(block: []const u8) bool {
    var diagnostic: contract_.Diagnostic = .{};
    var reader: Reader = .{ .block = block, .base = 0, .diagnostic = &diagnostic, .template = "" };
    var token = reader.next();
    for (0..contract_.imports_max + 1) |_| {
        if (!std.mem.eql(u8, token.text, "import")) break;
        _ = reader.next();
        token = reader.next();
    }
    return token.kind != .end;
}

/// The `##` lines right above `Ctx`.
fn docs_above(block: []const u8, ctx_offset: u32) []const u8 {
    const before = block[0..ctx_offset];
    var start = before.len;
    var lines = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, before, " \t\n"), '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), "##")) break;
        start = @intFromPtr(line.ptr) - @intFromPtr(block.ptr);
    }
    return std.mem.trimEnd(u8, before[@min(start, before.len)..], " \t\n");
}

const testing = std.testing;

fn declared(source: []const u8, buffer: []u8, diagnostic: *contract_.Diagnostic) ![]const u8 {
    var tree: parse.Tree = .{};
    var d: parse.Diagnostic = .{};
    try parse.parse(source, &tree, &d);
    const contract = try testing.allocator.create(Contract);
    defer testing.allocator.destroy(contract);
    const templates = [_]contract_.Template{.{ .name = "T", .source = source, .tree = &tree }};
    try contract_.of(contract, &templates, diagnostic);
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.print("{s}|", .{contract.docs});
    try contract_.write_line(contract, contract.root, &writer);
    return writer.buffered();
}

test "declared: the block's Ctx is the contract, with its docs" {
    var buffer: [512]u8 = undefined;
    var diagnostic: contract_.Diagnostic = .{};
    const source = "{{%\n# a note\n## The race's menu.\n## Prices are numbers.\nCtx : {\n" ++
        "\tdishes : List({ name : Str, price : U32 }),\n\tspare : F64,\n}\n%}}\n" ++
        "<p>{{#dishes}}{{ price }}{{/dishes}}</p>";
    try testing.expectEqualStrings(
        "## The race's menu.\n## Prices are numbers.|" ++
            "{ dishes : List({ name : Str, price : U32 }), spare : F64 }",
        try declared(source, &buffer, &diagnostic),
    );
}

test "declared: imports, before the contract or alone" {
    const gpa = testing.allocator;
    const contract = try gpa.create(Contract);
    defer gpa.destroy(contract);
    var diagnostic: contract_.Diagnostic = .{};
    const cases = [_]struct { source: []const u8, declared: bool }{
        .{
            .source = "{{%\nimport Fmt\nimport pf.Url\n## Docs.\nCtx : { a : Str }\n%}}",
            .declared = true,
        },
        .{ .source = "{{% import Fmt\n# a note\nimport pf.Url %}}{{ a }}", .declared = false },
    };
    for (cases) |case| {
        var tree: parse.Tree = .{};
        var d: parse.Diagnostic = .{};
        try parse.parse(case.source, &tree, &d);
        const template: contract_.Template = .{ .name = "T", .source = case.source, .tree = &tree };
        const templates = [_]contract_.Template{template};
        try contract_.of(contract, &templates, &diagnostic);
        try testing.expectEqual(case.declared, contract.declared);
        try testing.expectEqual(case.declared, has_ctx(tree.block));
        try testing.expectEqual(@as(usize, 2), contract.imports_len);
        try testing.expectEqualStrings("Fmt", contract.imports[0]);
        try testing.expectEqualStrings("pf.Url", contract.imports[1]);
    }
}

test "declared: what the template reads is checked against it" {
    const cases = [_]struct { source: []const u8, subject: []const u8, line: u32 }{
        .{ .source = "{{% Ctx : { a : Str } %}}\n\n{{ b }}", .subject = "b", .line = 3 },
        .{ .source = "{{% Ctx : { a : F64 } %}}{{ a }}", .subject = "a", .line = 1 },
        .{ .source = "{{% Ctx : { a : Str } %}}{{#a}}x{{/a}}", .subject = "a", .line = 1 },
        .{ .source = "{{%\nCtx : { a : View.Row }\n%}}", .subject = "View.Row", .line = 2 },
        .{ .source = "{{%\nimport fmt\n%}}", .subject = "fmt", .line = 2 },
        .{ .source = "{{%\nimport Fmt\nimport Fmt\n%}}", .subject = "Fmt", .line = 3 },
        .{
            .source = "{{%\nimport Fmt\nCtx : { a : Str }\nimport X\n%}}",
            .subject = "import",
            .line = 4,
        },
        .{ .source = "{{%\nimport\n%}}", .subject = "", .line = 3 },
        .{ .source = "{{% Ctx : { a : Str, a : Str } %}}", .subject = "a", .line = 1 },
        .{ .source = "{{%\nCtx : { where : Str }\n%}}", .subject = "where", .line = 2 },
    };
    for (cases) |case| {
        var buffer: [512]u8 = undefined;
        var diagnostic: contract_.Diagnostic = .{};
        try testing.expectError(error.Invalid, declared(case.source, &buffer, &diagnostic));
        try testing.expectEqualStrings(case.subject, diagnostic.subject);
        const d: parse.Diagnostic = .{ .offset = diagnostic.offset };
        try testing.expectEqual(case.line, d.line(case.source));
    }
}
