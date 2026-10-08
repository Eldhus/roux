//! A template compiled to the bytecode its generated Roc walkers run
//! (DESIGN.md, Templates). The bytecode is data: an edit to a template's
//! markup changes it and no Roc; the walkers depend only on the contract.
//!
//! A word is a `u64`: the op in the low 4 bits, a selector (16 bits: how
//! many scopes up, 4 bits; the field's index in its record's fields sorted
//! by name, 12 bits; 4095 is the scope itself), then the rest: a TEXT's
//! run, a section's body length in words. A value's op is followed by the
//! static run before it, one word, so text and value are one part
//! (fused). A run is `offset * 65536 + length` into the app's text, which
//! all templates share; a Str value's run has its mode in the top byte
//! (escaped, raw, upper, lower, url), for the host: the walker hands the
//! word on unread.
//!
//! | op | words | what |
//! |---|---|---|
//! | TEXT | 1 (the run in the rest) | a static run |
//! | STR | 2 | a Str field |
//! | NUM | 2 | an integer field |
//! | SECTION len | 1 | a list's elements, a record, a Bool when true: the body in that scope |
//! | INVERTED len | 1 | the body when the list is empty or the Bool false |
//! | COND len | 1 | the body when the Bool is true, in the same scope |
//! | LEN | 2 | a list's length |
//! | PLURAL | 4 | a count, then the singular or plural noun's run |
//! | CALL | 1 | a called partial, the field its context |
//!
//! The code starts with a header: the number of templates, then each
//! one's `[start, end)` (by its index among the app's templates, sorted by
//! name), so a template's Roc names only its index.
//!
//! The walkers are one per scope of the contract (a record, a list's
//! element, a Bool a section opens), each given the scopes enclosing it in
//! the contract: so `../` is counted in the contract, not in the template
//! (the two differ when a section opens a sibling's field: `{{#a}}{{#../b}}`
//! puts b's element under a in the template, under the root in the
//! contract). A template reading a scope the contract does not enclose
//! the current one in is refused.

const std = @import("std");
const assert = std.debug.assert;
const parse = @import("parse.zig");
const contract_ = @import("contract.zig");
const Contract = contract_.Contract;

pub const Op = enum(u4) { text, str, num, section, inverted, cond, len, plural, call };
pub const Mode = enum(u8) { escaped, raw, upper, lower, url, upper_raw, lower_raw };

pub const field_self = 4095;
pub const run_bytes_max = 65535;
pub const none = std.math.maxInt(u16);
/// What the walkers divide by: the selector's place, the rest's.
pub const selector_unit = 16;
pub const rest_unit = 1048576;
pub const mode_shift = 56;

pub fn word(op: Op, selector_: u16, rest: u64) u64 {
    assert(rest < (1 << 44));
    return @as(u64, @backingInt(op)) + selector_unit * @as(u64, selector_) + rest_unit * rest;
}

pub fn selector(up: u8, field: u16) u16 {
    assert(up < 16 and field <= field_self);
    return @as(u16, up) * 4096 + field;
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
            try builder.emit(word(.text, 0, try builder.run(bytes[0..run_bytes_max])));
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
        try builder.emit(word(.text, 0, ref));
    }
};

pub const Template = struct {
    name: []const u8,
    tree: *const parse.Tree,
    contract: *const Contract,
};

pub const Diagnostic = struct {
    template: []const u8 = "",
    offset: u32 = 0,
    message: []const u8 = "",
    subject: []const u8 = "",
};

pub const Error = error{ OutOfMemory, Invalid };

/// Each type's enclosing scope in the contract: the record a field is in;
/// a list's element's is the record the list is a field of. `none` for
/// the root and for a type that is no scope's field.
pub fn scope_parents(contract: *const Contract, parents: []u16) void {
    assert(parents.len >= contract.types_len);
    @memset(parents[0..contract.types_len], none);
    for (contract.types[0..contract.types_len], 0..) |type_, index| {
        if (type_.kind != .record) continue;
        var at = type_.first;
        while (at != none) : (at = contract.fields[at].next) {
            const field = contract.fields[at];
            parents[field.type] = @intCast(index);
            const child = contract.get(field.type);
            if (child.kind == .list) parents[child.element] = @intCast(index);
        }
    }
}

/// Whether a type is a scope a walker runs in: the root, a record field, a
/// list's element, a Bool field (a section on it opens a scope).
pub fn is_scope(contract: *const Contract, parents: []const u16, type_: u16) bool {
    if (type_ == contract.root) return true;
    if (parents[type_] == none) return false;
    return switch (contract.get(type_).kind) {
        .record, .bool => true,
        .list => false,
        .str, .unknown, .int, .other => is_element(contract, type_),
    };
}

pub fn is_element(contract: *const Contract, type_: u16) bool {
    for (contract.types[0..contract.types_len]) |t| {
        if (t.kind == .list and t.element == type_) return true;
    }
    return false;
}

/// How many scopes up `target` is from `from` in the contract, or null
/// when it does not enclose it.
pub fn distance(parents: []const u16, from: u16, target: u16) ?u8 {
    var at = from;
    var up: u8 = 0;
    while (up < 16) : (up += 1) {
        if (at == target) return up;
        if (parents[at] == none) return null;
        at = parents[at];
    }
    return null;
}

/// A field's index among its record's fields sorted by name: what the
/// walkers match on.
pub fn field_index(contract: *const Contract, record: u16, name: []const u8) u16 {
    var buffer: [contract_.fields_max]contract_.Field = undefined;
    for (contract.sorted_fields(record, &buffer), 0..) |f, k| {
        if (std.mem.eql(u8, f.name, name)) return @intCast(k);
    }
    unreachable; // the contract has it: it was checked
}

/// Compiles `templates[index]` (its inlined partials into it) and returns
/// its code's `[start, end)` in the builder.
pub fn compile(
    builder: *Builder,
    templates: []const Template,
    index: usize,
    diagnostic: *Diagnostic,
) Error![2]usize {
    const template = templates[index];
    const start = builder.code.items.len;
    var compiler: Compiler = .{
        .builder = builder,
        .templates = templates,
        .contract = template.contract,
        .diagnostic = diagnostic,
        .template = template.name,
    };
    scope_parents(template.contract, &compiler.parents);
    var scopes: Scopes = .{};
    scopes = scopes.push(template.contract.root);
    try compiler.range(template.tree, 0, template.tree.len, scopes, 0);
    try builder.flush();
    return .{ start, builder.code.items.len };
}

/// Every template's code after the header (which it fills in).
pub fn program(builder: *Builder, templates: []const Template, diagnostic: *Diagnostic) Error!void {
    assert(builder.code.items.len == 0);
    try builder.emit(templates.len);
    try builder.code.appendNTimes(builder.gpa, 0, 2 * templates.len);
    for (0..templates.len) |index| {
        const start, const end = try compile(builder, templates, index, diagnostic);
        builder.code.items[1 + 2 * index] = start;
        builder.code.items[2 + 2 * index] = end;
    }
}

/// The template's open scopes, innermost last: their types in the contract.
const Scopes = struct {
    types: [parse.depth_max + parse.path_max + 1]u16 = undefined,
    len: u8 = 0,

    fn push(scopes: Scopes, type_: u16) Scopes {
        var result = scopes;
        result.types[result.len] = type_;
        result.len += 1;
        return result;
    }

    fn innermost(scopes: Scopes) u16 {
        return scopes.types[scopes.len - 1];
    }
};

const Compiler = struct {
    builder: *Builder,
    templates: []const Template,
    contract: *const Contract,
    diagnostic: *Diagnostic,
    template: []const u8,
    parents: [contract_.types_max]u16 = undefined,

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

    /// Where a node's path leads: the scope it reads from (as a selector's
    /// `up`, counted in the contract), and its last field. A dotted path's
    /// records are opened as sections (the walker's scope moves) but are
    /// no scopes of the template's (`../` does not count them).
    const Target = struct {
        selector: u16,
        type_: u16,
        /// The SECTION words opened for the records, to close.
        opened: [parse.path_max]usize = undefined,
        opened_len: u8 = 0,
    };

    fn target(compiler: *Compiler, node: *const parse.Node, scopes: Scopes) Error!Target {
        assert(node.up < scopes.len);
        const reads = scopes.types[scopes.len - 1 - node.up];
        const up = distance(&compiler.parents, scopes.innermost(), reads) orelse
            return compiler.fail(node, "reads a scope the contract does not hold this one " ++
                "in (the walkers follow the contract)");
        const path = node.path_slice();
        if (path.len == 0) return .{ .selector = selector(up, field_self), .type_ = reads };
        var result: Target = .{ .selector = 0, .type_ = reads };
        var owner = reads;
        var owner_up = up;
        // `a.b.c`: a and b opened as record sections, c read in b.
        for (path[0 .. path.len - 1]) |name| {
            const b = compiler.builder;
            try b.flush();
            result.opened[result.opened_len] = b.code.items.len;
            result.opened_len += 1;
            const record = compiler.contract.field(owner, name).?;
            const index = field_index(compiler.contract, owner, name);
            try b.emit(word(.section, selector(owner_up, index), 0));
            owner = record;
            owner_up = 0;
        }
        const last = path[path.len - 1];
        result.selector = selector(owner_up, field_index(compiler.contract, owner, last));
        result.type_ = compiler.contract.field(owner, last).?;
        return result;
    }

    /// The record sections a dotted path opened, closed (their lengths).
    fn close(compiler: *Compiler, t: Target) Error!void {
        const b = compiler.builder;
        try b.flush();
        var k = t.opened_len;
        while (k > 0) {
            k -= 1;
            const at = t.opened[k];
            b.code.items[at] += rest_unit * (b.code.items.len - at - 1);
        }
    }

    fn value(compiler: *Compiler, node: *const parse.Node, scopes: Scopes) Error!void {
        const b = compiler.builder;
        const t = try compiler.target(node, scopes);
        const kind = compiler.contract.get(t.type_).kind;
        const pipes = node.pipe_slice();
        const text = try b.take();
        if (pipes.len > 0 and pipes[pipes.len - 1].formatter == .plural) {
            const nouns = pipes[pipes.len - 1].args;
            try b.emit(word(.plural, t.selector, 0));
            try b.emit(text);
            try b.emit(try b.run(try noun(b.gpa, nouns[0], node.escape)));
            try b.emit(try b.run(try noun(b.gpa, nouns[1], node.escape)));
        } else if (pipes.len > 0 and pipes[0].formatter == .len) {
            try b.emit(word(.len, t.selector, 0));
            try b.emit(text);
        } else if (kind == .int) {
            try b.emit(word(.num, t.selector, 0));
            try b.emit(text);
        } else {
            const mode: Mode = if (pipes.len == 0)
                (if (node.escape) .escaped else .raw)
            else switch (pipes[0].formatter) {
                .upper => if (node.escape) .upper else .upper_raw,
                .lower => if (node.escape) .lower else .lower_raw,
                .url => .url,
                .len, .plural => unreachable,
            };
            try b.emit(word(.str, t.selector, 0));
            try b.emit(text + (@as(u64, @backingInt(mode)) << mode_shift));
        }
        try compiler.close(t);
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
        const type_ = compiler.contract.get(t.type_);
        const op: Op = switch (node.kind) {
            .section => .section,
            .inverted => .inverted,
            .conditional => .cond,
            else => unreachable,
        };
        const at = b.code.items.len;
        try b.emit(0); // the op, once the body's length is known
        const inner = switch (op) {
            .section => scopes.push(if (type_.kind == .list) type_.element else t.type_),
            else => scopes,
        };
        try compiler.range(tree, index + 1, node.end, inner, depth);
        try b.flush();
        b.code.items[at] = word(op, t.selector, b.code.items.len - at - 1);
        try compiler.close(t);
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
            try compiler.builder.flush();
            try compiler.builder.emit(word(.call, t.selector, 0));
            try compiler.close(t);
            return;
        }
        assert(depth < contract_.partial_depth_max);
        const included = compiler.templates[called];
        try compiler.range(included.tree, 0, included.tree.len, scopes, depth + 1);
    }
};

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
