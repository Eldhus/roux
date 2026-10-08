//! A template compiled to the bytecode the host's renderer runs
//! (DESIGN.md, Templates; host/templates.zig). The bytecode is data: an
//! edit to a template's markup changes it and no Roc. Every read is a byte
//! offset into a record, as Roc's compiler laid it out (layout.zig), so
//! the renderer reads the app's record where it is, with no Roc between.
//!
//! A word is a `u64`: the op in the low 4 bits, then how many scopes up the
//! read starts (4 bits), the byte offset from that scope (24 bits: a dotted
//! path's records are inline, so `a.b.c` is one sum), and the rest (32
//! bits). A value's op is followed by the static run before it, one word,
//! so text and value are written together (fused). A run is `offset *
//! 65536 + length` into the app's text, which all templates share; a Str
//! value's run has its mode in the top byte (escaped, raw, upper, lower,
//! url).
//!
//! | op | words | rest | what |
//! |---|---|---|---|
//! | TEXT | 1 | | a static run, in the bits above the op |
//! | STR | 2 | | a Str |
//! | INT | 2 | its type | an integer |
//! | LEN | 2 | | a list's length |
//! | PLURAL | 4 | the count's type | a count, then the singular or plural noun's run |
//! | LIST | 2, body | body words | each element, the body in its scope; the element's size next |
//! | RECORD | 1, body | body words | the body in the record's scope |
//! | WHEN | 1, body | body words | a Bool's section: the body, when true, in a scope of its own |
//! | COND | 1, body | body words | the body when the Bool is true, in the same scope |
//! | UNLESS | 1, body | body words | the body when the Bool is false |
//! | EMPTY | 1, body | body words | the body when the list is empty |
//! | CALL | 1 | the template | a called partial, the record its context |
//!
//! The scopes are the template's: each section opens one (a list's
//! element, a record, a Bool), and `../` counts them, as the template
//! does. The code starts with a header: the number of templates, then
//! each one's `[start, end)` (by its index among the app's templates,
//! sorted by name), so a template's Roc names only its index.

const std = @import("std");
const assert = std.debug.assert;
const parse = @import("parse.zig");
const layout = @import("layout.zig");
const Layouts = layout.Layouts;

pub const Op = enum(u4) {
    text,
    str,
    int,
    len,
    plural,
    list,
    record,
    when,
    cond,
    unless,
    empty,
    call,
};
pub const Mode = enum(u8) { escaped, raw, upper, lower, url, upper_raw, lower_raw };
/// An integer's type, in an INT's or PLURAL's rest; `list` counts a list.
pub const Int = enum(u8) { u8, u16, u32, u64, i8, i16, i32, i64, list };

pub const run_bytes_max = 65535;
pub const mode_shift = 56;
pub const offset_max = (1 << 24) - 1;
pub const up_max = 15;
/// A scope's type when it holds nothing (a contract of `{}`).
pub const nothing = std.math.maxInt(u32);

pub fn word(op: Op, up: u8, offset: u32, rest: u64) u64 {
    assert(op != .text);
    assert(up <= up_max and offset <= offset_max and rest < (1 << 32));
    return @as(u64, @backingInt(op)) | @as(u64, up) << 4 | @as(u64, offset) << 8 | rest << 32;
}

fn text_word(run: u64) u64 {
    assert(run < (1 << 56));
    return @as(u64, @backingInt(Op.text)) | run << 8;
}

/// What compiles append to: the app's code and text.
pub const Builder = struct {
    gpa: std.mem.Allocator,
    code: std.ArrayList(u64) = .empty,
    text: std.ArrayList(u8) = .empty,
    /// The static text not yet given to a part.
    pending: std.ArrayList(u8) = .empty,

    /// A run of the app's text holding `bytes` (appended).
    fn run(builder: *Builder, bytes: []const u8) error{OutOfMemory}!u64 {
        assert(bytes.len <= run_bytes_max);
        if (bytes.len == 0) return 0;
        const offset = builder.text.items.len;
        try builder.text.appendSlice(builder.gpa, bytes);
        return @as(u64, offset) * 65536 + bytes.len;
    }

    fn emit(builder: *Builder, value: u64) error{OutOfMemory}!void {
        try builder.code.append(builder.gpa, value);
    }

    /// The pending text, as one run for the next part (long text: TEXT ops
    /// for all but its last 64 KiB).
    fn take(builder: *Builder) error{OutOfMemory}!u64 {
        var bytes = builder.pending.items;
        while (bytes.len > run_bytes_max) {
            try builder.emit(text_word(try builder.run(bytes[0..run_bytes_max])));
            bytes = bytes[run_bytes_max..];
        }
        const ref = try builder.run(bytes);
        builder.pending.clearRetainingCapacity();
        return ref;
    }

    /// The pending text as a TEXT op: before a section, a call, the end.
    fn flush(builder: *Builder) error{OutOfMemory}!void {
        if (builder.pending.items.len == 0) return;
        const ref = try builder.take();
        try builder.emit(text_word(ref));
    }
};

pub const Template = struct {
    name: []const u8,
    tree: *const parse.Tree,
    /// Its contract's type in `layouts`, or `nothing`.
    root: u32,
};

pub const Diagnostic = struct {
    template: []const u8 = "",
    offset: u32 = 0,
    message: []const u8 = "",
    subject: []const u8 = "",
};

pub const Error = error{ OutOfMemory, Invalid };

/// Compiles `templates[index]` (its inlined partials into it) and returns
/// its code's `[start, end)` in the builder.
pub fn compile(
    builder: *Builder,
    layouts: *const Layouts,
    templates: []const Template,
    index: usize,
    diagnostic: *Diagnostic,
) Error![2]usize {
    const template = templates[index];
    const start = builder.code.items.len;
    var compiler: Compiler = .{
        .builder = builder,
        .layouts = layouts,
        .templates = templates,
        .diagnostic = diagnostic,
        .template = template.name,
    };
    var scopes: Scopes = .{};
    scopes = scopes.push(template.root);
    try compiler.range(template.tree, 0, template.tree.len, scopes, 0);
    try builder.flush();
    return .{ start, builder.code.items.len };
}

/// Every template's code after the header (which it fills in).
pub fn program(
    builder: *Builder,
    layouts: *const Layouts,
    templates: []const Template,
    diagnostic: *Diagnostic,
) Error!void {
    assert(builder.code.items.len == 0);
    try builder.emit(templates.len);
    try builder.code.appendNTimes(builder.gpa, 0, 2 * templates.len);
    for (0..templates.len) |index| {
        const start, const end = try compile(builder, layouts, templates, index, diagnostic);
        builder.code.items[1 + 2 * index] = start;
        builder.code.items[2 + 2 * index] = end;
    }
}

/// The template's open scopes, innermost last: their types in the layouts.
const Scopes = struct {
    types: [parse.depth_max * (layout_partials + 1) + 1]u32 = undefined,
    len: u8 = 0,

    const layout_partials = @import("contract.zig").partial_depth_max;

    fn push(scopes: Scopes, type_: u32) Scopes {
        assert(scopes.len < scopes.types.len);
        var result = scopes;
        result.types[result.len] = type_;
        result.len += 1;
        return result;
    }
};

const Compiler = struct {
    builder: *Builder,
    layouts: *const Layouts,
    templates: []const Template,
    diagnostic: *Diagnostic,
    template: []const u8,

    fn fail(compiler: *Compiler, node: *const parse.Node, message: []const u8) Error {
        compiler.diagnostic.* = .{
            .template = compiler.template,
            .offset = node.offset,
            .message = message,
            .subject = node.text,
        };
        return error.Invalid;
    }

    fn range(
        compiler: *Compiler,
        tree: *const parse.Tree,
        from: u16,
        to: u16,
        scopes: Scopes,
        depth: u8,
    ) Error!void {
        var i = from;
        while (i < to) : (i = tree.nodes[i].end) {
            const node = &tree.nodes[i];
            switch (node.kind) {
                .text => try compiler.builder.pending.appendSlice(compiler.builder.gpa, node.text),
                .value => try compiler.value(node, scopes),
                .section, .inverted, .conditional => try compiler.section(tree, i, scopes, depth),
                .partial => try compiler.partial(tree, i, scopes, depth),
            }
        }
    }

    /// Where a node's path leads: how many scopes up it starts, the byte
    /// offset from there (a dotted path's records are inline: the sum of
    /// its fields' offsets), and the type it reaches.
    const Target = struct { up: u8, offset: u32, type_: u32 };

    fn target(compiler: *Compiler, node: *const parse.Node, scopes: Scopes) Error!Target {
        assert(node.up < scopes.len);
        if (node.up > up_max) return compiler.fail(node, "reads more than 15 scopes up");
        var result: Target = .{
            .up = node.up,
            .offset = 0,
            .type_ = scopes.types[scopes.len - 1 - node.up],
        };
        const empty = "reads a scope that holds nothing";
        for (node.path_slice()) |name| {
            if (result.type_ == nothing) return compiler.fail(node, empty);
            const field = compiler.layouts.field(result.type_, name) orelse
                return compiler.fail(node, "is not in the contract's layout (roc glue's)");
            result.offset += field.offset;
            result.type_ = field.type;
        }
        if (result.offset > offset_max) return compiler.fail(node, "is 16 MiB into its record");
        if (result.type_ == nothing) return compiler.fail(node, empty);
        return result;
    }

    fn kind(compiler: *Compiler, t: Target) layout.Kind {
        return compiler.layouts.get(t.type_).kind;
    }

    fn value(compiler: *Compiler, node: *const parse.Node, scopes: Scopes) Error!void {
        const b = compiler.builder;
        const t = try compiler.target(node, scopes);
        const pipes = node.pipe_slice();
        const text = try b.take();
        if (pipes.len > 0 and pipes[pipes.len - 1].formatter == .plural) {
            const count = int_of(compiler.kind(t)) orelse
                return compiler.fail(node, "counts neither an integer nor a list");
            const nouns = pipes[pipes.len - 1].args;
            try b.emit(word(.plural, t.up, t.offset, @backingInt(count)));
            try b.emit(text);
            try b.emit(try b.run(try noun(b.gpa, nouns[0], node.escape)));
            try b.emit(try b.run(try noun(b.gpa, nouns[1], node.escape)));
        } else if (pipes.len > 0 and pipes[0].formatter == .len) {
            if (compiler.kind(t) != .list) return compiler.fail(node, "is not a list");
            try b.emit(word(.len, t.up, t.offset, 0));
            try b.emit(text);
        } else if (int_of(compiler.kind(t))) |int| {
            if (int == .list) return compiler.fail(node, "is a list: write it with a section");
            try b.emit(word(.int, t.up, t.offset, @backingInt(int)));
            try b.emit(text);
        } else {
            if (compiler.kind(t) != .str) {
                return compiler.fail(node, "is neither a Str nor an integer");
            }
            const mode: Mode = if (pipes.len == 0)
                (if (node.escape) .escaped else .raw)
            else switch (pipes[0].formatter) {
                .upper => if (node.escape) .upper else .upper_raw,
                .lower => if (node.escape) .lower else .lower_raw,
                .url => .url,
                .len, .plural => unreachable,
            };
            try b.emit(word(.str, t.up, t.offset, 0));
            try b.emit(text + (@as(u64, @backingInt(mode)) << mode_shift));
        }
    }

    fn section(
        compiler: *Compiler,
        tree: *const parse.Tree,
        index: u16,
        scopes: Scopes,
        depth: u8,
    ) Error!void {
        const b = compiler.builder;
        const node = &tree.nodes[index];
        try b.flush();
        const t = try compiler.target(node, scopes);
        const type_ = compiler.layouts.get(t.type_);
        const op: Op = switch (node.kind) {
            .section => switch (type_.kind) {
                .list => .list,
                .record => .record,
                .bool => .when,
                else => return compiler.fail(node, "opens neither a list, a record nor a Bool"),
            },
            .inverted => switch (type_.kind) {
                .list => .empty,
                .bool => .unless,
                else => return compiler.fail(node, "is neither a list nor a Bool"),
            },
            .conditional => switch (type_.kind) {
                .bool => .cond,
                else => return compiler.fail(node, "is not a Bool"),
            },
            else => unreachable,
        };
        const at = b.code.items.len;
        try b.emit(0); // the op, once the body's length is known
        if (op == .list) try b.emit(compiler.layouts.get(type_.element).size);
        const head = b.code.items.len - at;
        const inner = switch (op) {
            .list => scopes.push(type_.element),
            .record, .when => scopes.push(t.type_),
            else => scopes,
        };
        try compiler.range(tree, index + 1, node.end, inner, depth);
        try b.flush();
        const body = b.code.items.len - at - head;
        if (body >= (1 << 32)) return compiler.fail(node, "has a body past 2^32 words");
        b.code.items[at] = word(op, t.up, t.offset, body);
    }

    fn partial(
        compiler: *Compiler,
        tree: *const parse.Tree,
        index: u16,
        scopes: Scopes,
        depth: u8,
    ) Error!void {
        const node = &tree.nodes[index];
        const called = for (compiler.templates, 0..) |t, k| {
            if (std.mem.eql(u8, t.name, node.text)) break k;
        } else unreachable; // the contract found it
        if (node.called()) {
            const t = try compiler.target(node, scopes);
            if (compiler.kind(t) != .record) return compiler.fail(node, "is not a record");
            try compiler.builder.flush();
            try compiler.builder.emit(word(.call, t.up, t.offset, called));
            return;
        }
        assert(depth < Scopes.layout_partials);
        const included = compiler.templates[called];
        try compiler.range(included.tree, 0, included.tree.len, scopes, depth + 1);
    }
};

fn int_of(kind: layout.Kind) ?Int {
    return switch (kind) {
        .u8 => .u8,
        .u16 => .u16,
        .u32 => .u32,
        .u64 => .u64,
        .i8 => .i8,
        .i16 => .i16,
        .i32 => .i32,
        .i64 => .i64,
        .list => .list,
        .other, .record, .str, .bool => null,
    };
}

/// A plural's noun: a space, then the noun, HTML-escaped when the tag
/// escapes (it is static, so it is escaped here).
fn noun(gpa: std.mem.Allocator, bytes: []const u8, escape: bool) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(gpa, ' ');
    if (!escape) {
        try out.appendSlice(gpa, bytes);
        return out.items;
    }
    for (bytes) |c| switch (c) {
        '&' => try out.appendSlice(gpa, "&amp;"),
        '<' => try out.appendSlice(gpa, "&lt;"),
        '>' => try out.appendSlice(gpa, "&gt;"),
        '"' => try out.appendSlice(gpa, "&quot;"),
        '\'' => try out.appendSlice(gpa, "&#39;"),
        else => try out.append(gpa, c),
    };
    return out.items;
}
