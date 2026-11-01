//! A template compiled to the bytecode the host's renderer runs
//! (host/templates.zig). The bytecode is data: an
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
//! value's run has its mode in the top byte (escaped, raw).
//!
//! | op | words | rest | what |
//! |---|---|---|---|
//! | TEXT | 1 | | a static run, in the bits above the op |
//! | STR | 2 | | a Str |
//! | INT | 2 | its type | an integer |
//! | LIST | 2, body | body words | each element, the body in its scope; the element's size next |
//! | RECORD | 1, body | body words | the body in the record's scope |
//! | COND | 1, body | body words | the body when the Bool is true, in the same scope |
//! | UNLESS | 1, body | body words | the body when the Bool is false |
//! | EMPTY | 1, body | body words | the body when the list is empty |
//! | CALL | 1 | the template | a called partial, the record its context |
//! | HOLE | 3 + leaves | leaves | a hole of Roc: its tag of `Holes.Hole`, then Roc's Str |
//!
//! A HOLE's third word is the union: the tag's discriminant (16 bits), the
//! discriminant's offset (16) and size (8), the union's size (16). Each
//! leaf word copies one value into the tag's payload: how many scopes up
//! it starts (4 bits), its offset there (24), its size (16), its offset in
//! the payload (16).
//!
//! The scopes are the template's: each section opens one (a list's
//! element, a record), named by its binder; a read's `up` counts the
//! scopes to the one its name is bound in. The code starts with a header:
//! the number of templates, each one's `[start, end)` (by its index,
//! templates sorted by name; a CALL
//! names its partial by that index), then the union (`Union`): its
//! discriminant's offset and size, and each template's discriminant and
//! payload offset. The host finds a rendered template by its tag.

const std = @import("std");
const assert = std.debug.assert;
const parse = @import("parse.zig");
const layout = @import("layout.zig");
const contract_ = @import("contract.zig");
const hole_ = @import("hole.zig");
const Layouts = layout.Layouts;

pub const Op = enum(u4) {
    text,
    str,
    int,
    list,
    record,
    cond,
    unless,
    empty,
    call,
    hole,
};

/// The most a HOLE's union may hold: the renderer builds it in place.
pub const hole_bytes_max = 512;
/// A scope's contract type when the template has no contract.
const no_contract = std.math.maxInt(u16);
pub const Mode = enum(u8) { escaped, raw };
/// An integer's type, in an INT's rest.
pub const Int = enum(u8) { u8, u16, u32, u64, i8, i16, i32, i64 };

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

/// A word holding a run, which moves when its template's text is placed
/// after others' (`assemble`): where it is, and how far up the run sits
/// in it (8 in a TEXT word, 0 in a run word).
pub const Run = struct { at: u32, shift: u6 };

/// One template compiled alone: its code, its own text (runs count from
/// its start), and the words holding runs. Templates compile apart, so a
/// caller can keep each and recompile only the edited ones.
pub const Chunk = struct {
    code: []const u64,
    text: []const u8,
    runs: []const Run,
};

/// What a compile appends to: a template's code and text.
pub const Builder = struct {
    gpa: std.mem.Allocator,
    code: std.ArrayList(u64) = .empty,
    text: std.ArrayList(u8) = .empty,
    runs: std.ArrayList(Run) = .empty,
    /// The static text not yet given to a part.
    pending: std.ArrayList(u8) = .empty,

    /// A run of the text holding `bytes` (appended).
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

    /// A word holding a run (`shift` bits up), noted so it can move.
    fn emit_run(builder: *Builder, value: u64, shift: u6) error{OutOfMemory}!void {
        const at: u32 = @intCast(builder.code.items.len);
        try builder.runs.append(builder.gpa, .{ .at = at, .shift = shift });
        try builder.emit(value);
    }

    /// The pending text, as one run for the next part (long text: TEXT ops
    /// for all but its last 64 KiB).
    fn take(builder: *Builder) error{OutOfMemory}!u64 {
        var bytes = builder.pending.items;
        while (bytes.len > run_bytes_max) {
            try builder.emit_run(text_word(try builder.run(bytes[0..run_bytes_max])), 8);
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
        try builder.emit_run(text_word(ref), 8);
    }
};

pub const Template = struct {
    name: []const u8,
    tree: *const parse.Tree,
    /// Its contract's type in `layouts`, or `nothing`.
    root: u32,
    /// Its contract (a fragment's own): the types its holes' keys name.
    /// Without one (the renderer's tests, over layouts made by hand), a hole
    /// is refused.
    contract: ?*const contract_.Contract = null,
    /// A fragment: the body of its node in the page's tree, from
    /// its scope. A page is the whole tree.
    fragment: ?u16 = null,
};

/// What a compile reads beyond its templates: every template's source (a
/// partial is found by name, rendered alone or not), the layout of the
/// app's holes, and where to build a hole's parameters.
pub const Context = struct {
    sources: []const contract_.Template,
    holes: ?layout.Holes,
    params: *contract_.Contract,
};

pub const Diagnostic = struct {
    template: []const u8 = "",
    offset: u32 = 0,
    message: []const u8 = "",
    subject: []const u8 = "",
};

pub const Error = error{ OutOfMemory, Invalid };

/// Compiles `templates[index]` (its inlined partials into it) alone, in
/// `gpa`'s memory.
pub fn compile(
    gpa: std.mem.Allocator,
    layouts: *const Layouts,
    templates: []const Template,
    index: usize,
    context: Context,
    diagnostic: *Diagnostic,
) Error!Chunk {
    const template = templates[index];
    var builder: Builder = .{ .gpa = gpa };
    errdefer {
        builder.code.deinit(gpa);
        builder.text.deinit(gpa);
        builder.runs.deinit(gpa);
        builder.pending.deinit(gpa);
    }

    var compiler: Compiler = .{
        .builder = &builder,
        .layouts = layouts,
        .templates = templates,
        .diagnostic = diagnostic,
        .template = template.name,
        .contract = template.contract,
        .context = context,
    };
    var scopes: Scopes = .{};
    // A fragment's scope keeps the name its section gave it.
    const binder = if (template.fragment) |node| parse.binder_at(template.tree, node) else "";
    const root_contract = if (template.contract) |c| c.root else no_contract;
    scopes = scopes.push(template.root, root_contract, binder);
    if (template.fragment) |node| {
        const end = template.tree.nodes[node].end;
        try compiler.range(template.tree, node + 1, end, scopes, 0);
    } else {
        try compiler.range(template.tree, 0, template.tree.len, scopes, 0);
    }
    try builder.flush();
    builder.pending.deinit(gpa);
    return .{
        .code = try builder.code.toOwnedSlice(gpa),
        .text = try builder.text.toOwnedSlice(gpa),
        .runs = try builder.runs.toOwnedSlice(gpa),
    };
}

pub const Program = struct { code: []const u64, text: []const u8 };

/// Where the app's `Templates.Template` union keeps which template a value
/// is, and each template's tag: its discriminant and where its contract
/// starts.
pub const Union = struct {
    discriminant_offset: u32 = 0,
    /// 0: one tag, no discriminant.
    discriminant_size: u32 = 0,
    /// By template index.
    tags: []const Tag = &.{},
};
pub const Tag = struct { discriminant: u32, payload_offset: u32 };

/// The header's length in words: the count, each template's `[start,
/// end)`, the union's word, each template's tag word.
pub fn header_words(count: usize) usize {
    return 1 + 2 * count + 1 + count;
}

/// The app's program from its templates' chunks: the header (each
/// template's `[start, end)`; the templates' union: its discriminant's
/// offset and size, then each template's discriminant and payload offset),
/// then each chunk's code, its runs moved past the text placed before it.
pub fn assemble(
    gpa: std.mem.Allocator,
    chunks: []const Chunk,
    templates: Union,
) error{OutOfMemory}!Program {
    assert(templates.tags.len == chunks.len);
    var code_len: usize = header_words(chunks.len);
    var text_len: usize = 0;
    for (chunks) |chunk| {
        code_len += chunk.code.len;
        text_len += chunk.text.len;
    }
    const code = try gpa.alloc(u64, code_len);
    const text = try gpa.alloc(u8, text_len);
    code[0] = chunks.len;
    const union_at = 1 + 2 * chunks.len;
    code[union_at] = templates.discriminant_offset |
        @as(u64, templates.discriminant_size) << 32;
    for (templates.tags, 0..) |tag, index| {
        code[union_at + 1 + index] = tag.payload_offset | @as(u64, tag.discriminant) << 32;
    }
    var code_at: usize = header_words(chunks.len);
    var text_at: usize = 0;
    for (chunks, 0..) |chunk, index| {
        code[1 + 2 * index] = code_at;
        code[2 + 2 * index] = code_at + chunk.code.len;
        const placed = code[code_at..][0..chunk.code.len];
        @memcpy(placed, chunk.code);
        @memcpy(text[text_at..][0..chunk.text.len], chunk.text);
        const moved = @as(u64, text_at) * 65536;
        for (chunk.runs) |r| placed[r.at] += moved << r.shift;
        code_at += chunk.code.len;
        text_at += chunk.text.len;
    }
    assert(code_at == code_len and text_at == text_len);
    return .{ .code = code, .text = text };
}

/// The template's open scopes, innermost last: their types in the layouts,
/// and in the contract, and their binders, pushed where the contract's
/// check pushes them.
const Scopes = struct {
    types: [capacity]u32 = undefined,
    contracts: [capacity]u16 = undefined,
    binders: [capacity][]const u8 = undefined,
    len: u8 = 0,

    const layout_partials = contract_.partial_depth_max;
    const capacity = parse.depth_max * (layout_partials + 1) + 1;

    fn push(scopes: Scopes, type_: u32, contract_type: u16, binder: []const u8) Scopes {
        assert(scopes.len < capacity);
        var result = scopes;
        result.types[result.len] = type_;
        result.contracts[result.len] = contract_type;
        result.binders[result.len] = binder;
        result.len += 1;
        return result;
    }

    /// Where a node's path leads, found as the contract's check finds it.
    fn bound(scopes: *const Scopes, node: *const parse.Node) parse.Bound {
        return parse.bound(scopes.binders[0..scopes.len], node.path_slice());
    }
};

const Compiler = struct {
    builder: *Builder,
    layouts: *const Layouts,
    templates: []const Template,
    diagnostic: *Diagnostic,
    template: []const u8,
    contract: ?*const contract_.Contract,
    context: Context,

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
                .value => if (node.expression.len > 0) {
                    try compiler.hole(tree, node, scopes);
                } else {
                    try compiler.value(node, scopes);
                },
                .section, .inverted, .conditional => try compiler.section(tree, i, scopes, depth),
                .partial => try compiler.partial(tree, i, scopes, depth),
                // In place, the page's scope: one bytecode, no call.
                .fragment => try compiler.range(tree, i + 1, tree.nodes[i].end, scopes, depth),
            }
        }
    }

    /// Where a node's path leads: how many scopes up it starts, the byte
    /// offset from there (a dotted path's records are inline: the sum of
    /// its fields' offsets), and the type it reaches.
    const Target = struct { up: u8, offset: u32, type_: u32 };

    fn target(compiler: *Compiler, node: *const parse.Node, scopes: Scopes) Error!Target {
        const found = scopes.bound(node);
        const up = scopes.len - 1 - found.scope;
        if (up > up_max) return compiler.fail(node, "reads more than 15 scopes up");
        var result: Target = .{
            .up = @intCast(up),
            .offset = 0,
            .type_ = scopes.types[found.scope],
        };
        const empty = "reads a scope that holds nothing";
        for (found.path) |name| {
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
        assert(node.expression.len == 0);
        const b = compiler.builder;
        const t = try compiler.target(node, scopes);
        const text = try b.take();
        if (int_of(compiler.kind(t))) |int| {
            try b.emit(word(.int, t.up, t.offset, @backingInt(int)));
            try b.emit_run(text, 0);
            return;
        }
        if (compiler.kind(t) != .str) return compiler.fail(node, "is neither a Str nor an integer");
        const mode: Mode = if (node.escape) .escaped else .raw;
        try b.emit(word(.str, t.up, t.offset, 0));
        try b.emit_run(text + (@as(u64, @backingInt(mode)) << mode_shift), 0);
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
                else => return compiler.fail(node, "opens neither a list nor a record"),
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
        const c = compiler.contract_target(node, scopes);
        const element = if (compiler.contract) |contract| contract.get(c).element else no_contract;
        const inner = switch (op) {
            .list => scopes.push(type_.element, element, node.binder),
            .record => scopes.push(t.type_, c, node.binder),
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
        if (node.called()) {
            const called = for (compiler.templates, 0..) |t, k| {
                if (std.mem.eql(u8, t.name, node.text)) break k;
            } else unreachable; // the contract found it
            const t = try compiler.target(node, scopes);
            if (compiler.kind(t) != .record) return compiler.fail(node, "is not a record");
            try compiler.builder.flush();
            try compiler.builder.emit(word(.call, t.up, t.offset, called));
            return;
        }
        assert(depth < Scopes.layout_partials);
        const included = for (compiler.context.sources) |t| {
            if (std.mem.eql(u8, t.name, node.text)) break t;
        } else unreachable; // the contract found it
        try compiler.range(included.tree, 0, included.tree.len, scopes, depth + 1);
    }

    /// Where a node's path leads in the contract: the check found it.
    fn contract_target(compiler: *Compiler, node: *const parse.Node, scopes: Scopes) u16 {
        const contract = compiler.contract orelse return no_contract;
        const found = scopes.bound(node);
        var at = scopes.contracts[found.scope];
        for (found.path) |name| at = contract.field(at, name).?;
        return at;
    }

    /// A hole of Roc: its tag of the app's `Holes.Hole`, by the key the
    /// check gave it, and a leaf for each value it reads.
    fn hole(
        compiler: *Compiler,
        tree: *const parse.Tree,
        node: *const parse.Node,
        scopes: Scopes,
    ) Error!void {
        const b = compiler.builder;
        const contract = compiler.contract orelse
            return compiler.fail(node, "is a hole of Roc, in a template without a contract");
        const holes = compiler.context.holes orelse
            return compiler.fail(node, "has no layout for the app's holes (roc glue's)");
        if (holes.size > hole_bytes_max) {
            return compiler.fail(node, "is one of holes whose values take over 512 bytes");
        }
        const parsed = contract_.expression_of(node);
        var leaves: [hole_.reads_max]contract_.Leaf = undefined;
        const params = compiler.context.params;
        const contracts = scopes.contracts[0..scopes.len];
        const binders = scopes.binders[0..scopes.len];
        const count =
            contract_.of_hole(params, contract, contracts, binders, &parsed, &leaves) catch
                return compiler.fail(node, "reads more than its parameters can hold");
        const source = for (compiler.context.sources) |t| {
            if (t.tree == tree) break t.name;
        } else unreachable;
        const key = contract_.hole_key(source, node.expression, params) catch
            return compiler.fail(node, "reads types too long to name");
        var name_buffer: [17]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "H{x:0>16}", .{key}) catch unreachable;
        const tag = for (holes.tag_union.tags) |t| {
            if (std.mem.eql(u8, t.name, name)) break t;
        } else return compiler.fail(node, "is not in the layout of the app's holes (roc glue's)");
        const text = try b.take();
        const mode: Mode = if (node.escape) .escaped else .raw;
        try b.emit(word(.hole, 0, 0, count));
        try b.emit_run(text + (@as(u64, @backingInt(mode)) << mode_shift), 0);
        const u = holes.tag_union;
        try b.emit(@as(u64, tag.discriminant) | @as(u64, u.discriminant_offset) << 16 |
            @as(u64, u.discriminant_size) << 32 | @as(u64, holes.size) << 40);
        for (leaves[0..count]) |*leaf| try b.emit(try compiler.leaf_word(node, scopes, leaf, tag));
    }

    /// A leaf's word: where its value is in the scope, and in the payload.
    fn leaf_word(
        compiler: *Compiler,
        node: *const parse.Node,
        scopes: Scopes,
        leaf_: *const contract_.Leaf,
        tag: layout.Tag,
    ) Error!u64 {
        assert(leaf_.scope < scopes.len);
        var from = scopes.types[leaf_.scope];
        var from_offset: u32 = 0;
        var into = tag.type;
        var into_offset: u32 = tag.payload_offset;
        for (leaf_.read.path_slice(), 0..) |segment, k| {
            // A binder is the scope itself: the payload names it, the
            // scope does not.
            if (!(leaf_.named and k == 0)) {
                const mine = compiler.layouts.field(from, segment) orelse
                    return compiler.fail(node, "is not in the contract's layout (roc glue's)");
                from_offset += mine.offset;
                from = mine.type;
            }
            const theirs = compiler.layouts.field(into, segment) orelse
                return compiler.fail(node, "is not in the layout of the app's holes (roc glue's)");
            into_offset += theirs.offset;
            into = theirs.type;
        }
        const size = compiler.layouts.get(from).size;
        assert(size == compiler.layouts.get(into).size);
        const up = scopes.len - 1 - leaf_.scope;
        if (up > up_max) return compiler.fail(node, "reads more than 15 scopes up");
        if (from_offset > offset_max) return compiler.fail(node, "is 16 MiB into its record");
        assert(into_offset + size <= hole_bytes_max);
        return @as(u64, up) | @as(u64, from_offset) << 4 | @as(u64, size) << 28 |
            @as(u64, into_offset) << 44;
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
        .other, .record, .list, .str, .bool, .tag_union => null,
    };
}

test "bytecode: assembled chunks, their runs moved past the text before them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const run_a = 0 * 65536 + 3; // "abc"
    const run_b = 0 * 65536 + 2; // "de", in its own text
    const str_word = word(.str, 0, 8, 0);
    const chunks = [_]Chunk{
        .{ .code = &.{text_word(run_a)}, .text = "abc", .runs = &.{.{ .at = 0, .shift = 8 }} },
        .{
            .code = &.{ str_word, run_b + (@as(u64, 2) << mode_shift) },
            .text = "de",
            .runs = &.{.{ .at = 1, .shift = 0 }},
        },
    };
    const tags = [_]Tag{
        .{ .discriminant = 0, .payload_offset = 0 },
        .{ .discriminant = 1, .payload_offset = 0 },
    };
    const templates: Union = .{ .discriminant_offset = 24, .discriminant_size = 1, .tags = &tags };
    const program = try assemble(arena.allocator(), &chunks, templates);
    try std.testing.expectEqualStrings("abcde", program.text);
    // The header: two templates, [8, 9) and [9, 11); the union's
    // discriminant at 24, one byte; the tags 0 and 1.
    const union_word = 24 | @as(u64, 1) << 32;
    const header = [_]u64{ 2, 8, 9, 9, 11, union_word, 0, @as(u64, 1) << 32 };
    try std.testing.expectEqualSlices(u64, &header, program.code[0..8]);
    try std.testing.expectEqual(text_word(run_a), program.code[8]);
    try std.testing.expectEqual(str_word, program.code[9]);
    // "de" now starts at 3; its mode, in the top byte, untouched.
    try std.testing.expectEqual(3 * 65536 + 2 + (@as(u64, 2) << mode_shift), program.code[10]);
}
