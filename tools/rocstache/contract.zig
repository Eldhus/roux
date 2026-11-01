//! A template's contract: the record it reads, as a Roc type.
//!
//! It is the template's declared `Ctx`, when its `{{% %}}` block has one;
//! otherwise it is inferred from the tags: dotted paths are records, a
//! section (`{{#dishes |dish|}}`) is a list of what its body reads of its
//! binder, `{{^x}}` and `{{?x}}` alone make a Bool, `len` makes a list, a
//! value piped into `plural` is a `U64`, and every other value a `Str`.
//! A name is a section's binder or a field of the page's `Ctx`. A partial
//! (`{{> Top}}`) reads the names in scope where it is included, so its
//! fields are its includer's.
//!
//! Either way the template is then checked against the contract
//! (`check`), so a mistake is the generator's message naming the line,
//! never a wrong read in the host's renderer.

const std = @import("std");
const assert = std.debug.assert;
const parse = @import("parse.zig");
const hole = @import("hole.zig");

pub const types_max = 1024;
pub const fields_max = 2048;
/// Partials included within partials, at most.
pub const partial_depth_max = 8;
const none = std.math.maxInt(u16);

pub const Kind = enum(u8) { unknown, str, int, bool, list, record, other };

pub const Type = struct {
    kind: Kind = .unknown,
    /// int and other: the Roc type's name (`U32`, `F64`).
    name: []const u8 = "",
    /// list: the element's type.
    element: u16 = none,
    /// record: the first field (a chain through `Field.next`).
    first: u16 = none,
    /// Where it was first used, for messages.
    offset: u32 = 0,
    /// record: the partial whose contract this is (`Top` for a field a
    /// `{{> Top frame}}` gives), so the module writes `Top.Ctx`.
    alias: []const u8 = "",
};

/// A `{{$Row}}` of the template: its node, its scope's type and that
/// scope's place on the stack. The scope's fields it reads are its
/// contract when it renders alone.
pub const Fragment = struct { name: []const u8, node: u16, scope: u16, frame: u16 };
pub const fragments_max = 32;
pub const imports_max = 16;

/// `used`: a bit per fragment (its index) that reads the field from the
/// fragment's own scope, itself or through a partial.
pub const Field = struct { name: []const u8, type: u16, next: u16 = none, used: u32 = 0 };

/// A template the contract can reach: itself and its partials.
pub const Template = struct {
    name: []const u8,
    source: []const u8,
    tree: *const parse.Tree,
    /// Its own contract, once known: what a `{{> Name field}}` that calls
    /// it gives `field` (generate.zig computes the called partials first).
    contract: ?*const Contract = null,
};

pub const Diagnostic = struct {
    /// The template the message is about (a partial's, when it is in one).
    template: []const u8 = "",
    offset: u32 = 0,
    message: []const u8 = "",
    subject: []const u8 = "",
};

pub const Error = error{Invalid};

/// Where a hole's free name and its path lead: the open scope it is a field
/// of, by its place on the stack, and the path's type.
pub const Resolved = struct { scope: u8, type: u16 };

/// A read a hole's parameters keep (none other covers it): the renderer
/// copies its value, from the open scope at `scope`. `named`: its head is
/// that scope's binder, so the path below it is read from the scope.
pub const Leaf = struct { read: hole.Read, scope: u8, named: bool };

pub const holes_max = 256;

/// A distinct hole of a page, as its walk met it: the template whose text
/// holds it, its node there, and the open scopes' types and binders, from
/// which its parameters are built again (`of_hole`). `key` names its Roc
/// function.
pub const HoleSite = struct {
    key: u64,
    template: []const u8,
    node: u16,
    scopes: [parse.depth_max]u16,
    binders: [parse.depth_max][]const u8,
    scopes_len: u8,

    pub fn scope_slice(site: *const HoleSite) []const u16 {
        return site.scopes[0..site.scopes_len];
    }

    pub fn binder_slice(site: *const HoleSite) []const []const u8 {
        return site.binders[0..site.scopes_len];
    }
};

/// Where `of_hole` builds a hole's parameters while a walk checks it.
var hole_buffer: Contract = undefined;

/// A hole's parameters, as a record: each free name a field, narrowed to
/// the paths the expression reads below it, each read's value whole. A read
/// another covers (a shorter path to it, or the same one earlier) is that
/// one's. The reads kept are the leaves, which the renderer copies: their
/// count is returned. `scopes` are the open scopes' types in `page`, and
/// `binders` their names, where the check found each name.
pub fn of_hole(
    into: *Contract,
    page: *const Contract,
    scopes: []const u16,
    binders: []const []const u8,
    parsed: *const hole.Hole,
    leaves: *[hole.reads_max]Leaf,
) Error!u8 {
    assert(scopes.len == binders.len);
    into.types_len = 0;
    into.fields_len = 0;
    into.declared = true;
    into.alone = true;
    into.docs = "";
    into.fragments_len = 0;
    into.imports_len = 0;
    into.holes_len = 0;
    var diagnostic: Diagnostic = .{};
    var walker: Walker = .{ .contract = into, .templates = &.{}, .diagnostic = &diagnostic };
    into.root = try walker.new(.record, 0);
    var count: u8 = 0;
    for (parsed.read_slice(), 0..) |*read, index| {
        if (covered(parsed, index)) continue;
        const found = parse.bound(binders, read.path_slice());
        leaves[count] = .{ .read = read.*, .scope = @intCast(found.scope), .named = found.named };
        count += 1;
        var from = scopes[found.scope];
        var at = into.root;
        for (read.path_slice(), 1..) |segment, length| {
            // A binder is the scope itself; a field is read below it.
            if (!(found.named and length == 1)) from = page.field(from, segment).?;
            const last = length == read.path_len;
            if (into.field(at, segment)) |existing| {
                // A shorter read would have covered this one.
                assert(!last);
                at = existing;
                continue;
            }
            const child = try walker.new(if (last) .unknown else .record, 0);
            try into.add_field(at, segment, child);
            if (last) try walker.copy(page, from, child, 1);
            at = child;
        }
    }
    assert(count > 0 or parsed.reads_len == 0);
    return count;
}

/// Whether another read of the hole covers read `index`: its path is a
/// shorter start of this one's, or the same path read earlier.
fn covered(parsed: *const hole.Hole, index: usize) bool {
    const mine = parsed.reads[index].path_slice();
    for (parsed.read_slice(), 0..) |*other, k| {
        if (k == index) continue;
        const theirs = other.path_slice();
        if (theirs.len > mine.len or (theirs.len == mine.len and k > index)) continue;
        const starts = for (theirs, mine[0..theirs.len]) |a, b| {
            if (!std.mem.eql(u8, a, b)) break false;
        } else true;
        if (starts) return true;
    }
    return false;
}

/// A hole's name: its template, its expression as written and its
/// parameters' Roc type. A markup change that keeps all three keeps it.
pub fn hole_key(template: []const u8, expression: []const u8, params: *const Contract) !u64 {
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try write_line(params, params.root, &writer);
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(template);
    hasher.update(&.{0});
    hasher.update(expression);
    hasher.update(&.{0});
    hasher.update(writer.buffered());
    return hasher.final();
}

/// A value node's Roc expression, parsed again: parse.zig checked it.
pub fn expression_of(node: *const parse.Node) hole.Hole {
    assert(node.kind == .value);
    assert(node.expression.len > 0);
    var refused: parse.Diagnostic = .{};
    return hole.of(node.expression, &refused) catch unreachable;
}

/// Types and fields in fixed arrays: a contract is small, and bounded.
pub const Contract = struct {
    types: [types_max]Type = undefined,
    types_len: u16 = 0,
    fields: [fields_max]Field = undefined,
    fields_len: u16 = 0,
    root: u16 = none,
    declared: bool = false,
    /// Whether it renders alone. Not when inferred and a Roc expression in
    /// it (or in a partial it includes) reads the scope: those reads are
    /// typed only where it is included, by the includer's contract.
    alone: bool = true,
    /// The `##` lines above a declared `Ctx`.
    docs: []const u8 = "",
    fragments: [fragments_max]Fragment = undefined,
    fragments_len: u8 = 0,
    /// The block's `import` lines (`Fmt`, `pf.Url`): the modules its holes'
    /// Roc may name, imported by its generated module.
    imports: [imports_max][]const u8 = undefined,
    imports_len: u8 = 0,
    /// Its distinct holes whose Roc the build compiles, its partials'
    /// included here among them.
    holes: [holes_max]HoleSite = undefined,
    holes_len: u16 = 0,

    pub fn fragment_slice(contract: *const Contract) []const Fragment {
        return contract.fragments[0..contract.fragments_len];
    }

    pub fn import_slice(contract: *const Contract) []const []const u8 {
        return contract.imports[0..contract.imports_len];
    }

    pub fn hole_slice(contract: *const Contract) []const HoleSite {
        return contract.holes[0..contract.holes_len];
    }

    pub fn get(contract: *const Contract, index: u16) *const Type {
        assert(index < contract.types_len);
        return &contract.types[index];
    }

    fn new(contract: *Contract, kind: Kind, offset: u32) Error!u16 {
        if (contract.types_len == types_max) return error.Invalid;
        contract.types[contract.types_len] = .{ .kind = kind, .offset = offset };
        contract.types_len += 1;
        return contract.types_len - 1;
    }

    pub fn field(contract: *const Contract, record: u16, name: []const u8) ?u16 {
        var at = contract.get(record).first;
        while (at != none) : (at = contract.fields[at].next) {
            if (std.mem.eql(u8, contract.fields[at].name, name)) return contract.fields[at].type;
        }
        return null;
    }

    /// Adds a field to a record's chain, which is kept sorted by name.
    fn add_field(contract: *Contract, record: u16, name: []const u8, child: u16) Error!void {
        if (contract.fields_len == fields_max) return error.Invalid;
        const type_ = &contract.types[record];
        assert(type_.kind == .record);
        var link = &type_.first;
        while (link.* != none and std.mem.lessThan(u8, contract.fields[link.*].name, name)) {
            link = &contract.fields[link.*].next;
        }
        contract.fields[contract.fields_len] = .{ .name = name, .type = child, .next = link.* };
        link.* = contract.fields_len;
        contract.fields_len += 1;
    }

    /// A record's fields, sorted by name.
    pub fn fields_of(contract: *const Contract, record: u16) Fields {
        return .{ .contract = contract, .at = contract.get(record).first };
    }

    pub const Fields = struct {
        contract: *const Contract,
        at: u16,

        pub fn next(fields: *Fields) ?Field {
            if (fields.at == none) return null;
            const f = fields.contract.fields[fields.at];
            fields.at = f.next;
            return f;
        }
    };
};

/// The contract of `templates[0]`, checked; its partials are found among
/// `templates` by name.
pub fn of(
    contract: *Contract,
    templates: []const Template,
    diagnostic: *Diagnostic,
) Error!void {
    assert(templates.len > 0);
    // The header only: the arrays are filled as they grow (a whole `.{}`
    // would write all of them, ~200 KB, in a safe build).
    contract.types_len = 0;
    contract.fields_len = 0;
    contract.root = none;
    contract.declared = false;
    contract.alone = true;
    contract.docs = "";
    contract.fragments_len = 0;
    contract.imports_len = 0;
    contract.holes_len = 0;
    const self = templates[0];
    var walker: Walker = .{
        .contract = contract,
        .templates = templates,
        .diagnostic = diagnostic,
    };
    // The block's imports, then its `Ctx` if it has one.
    if (std.mem.trim(u8, self.tree.block, " \t\n").len > 0) {
        try @import("declared.zig").read(contract, self, diagnostic);
    }
    if (!contract.declared) {
        contract.root = try walker.new(.record, 0);
        try walker.infer(self, 0, self.tree.len, &.{contract.root}, 0);
    }
    try walker.check(self, 0, self.tree.len, &.{contract.root}, 0);
}

/// A fragment's own contract: the fields of its scope it reads, each of
/// the type it has in the page. Narrowed at the top only: a list it reads
/// keeps its elements' whole type. Always its own record: the page spells
/// its scope out, so reading one field more or less changes this type
/// alone.
pub fn of_fragment(contract: *Contract, page: *const Contract, k: u5) Error!void {
    const fragment = page.fragments[k];
    contract.types_len = 0;
    contract.fields_len = 0;
    contract.declared = page.declared;
    contract.alone = true;
    contract.docs = "";
    contract.fragments_len = 0;
    contract.imports_len = 0;
    contract.holes_len = 0;
    var diagnostic: Diagnostic = .{};
    var walker: Walker = .{ .contract = contract, .templates = &.{}, .diagnostic = &diagnostic };
    contract.root = try walker.new(.record, 0);
    var at = page.get(fragment.scope).first;
    while (at != none) : (at = page.fields[at].next) {
        const field_ = page.fields[at];
        if (field_.used & (@as(u32, 1) << k) == 0) continue;
        const child = try walker.new(.unknown, 0);
        try contract.add_field(contract.root, field_.name, child);
        try walker.copy(page, field_.type, child, 1);
    }
}

fn declares(template: Template) bool {
    return @import("declared.zig").has_ctx(template.tree.block);
}

/// A partial's declared `Ctx`, read for an includer whose contract is
/// inferred: the types it states are the includer's where the includer's
/// own tags say nothing. Static: read, merged, and done with before the
/// next include.
var declared_buffer: Contract = undefined;

fn declared_of(included: Template, diagnostic: *Diagnostic) Error!*const Contract {
    assert(declares(included));
    const contract = &declared_buffer;
    contract.types_len = 0;
    contract.fields_len = 0;
    contract.declared = false;
    contract.alone = true;
    contract.docs = "";
    contract.fragments_len = 0;
    contract.imports_len = 0;
    contract.holes_len = 0;
    try @import("declared.zig").read(contract, included, diagnostic);
    assert(contract.declared);
    return contract;
}

/// The contract as one line of Roc, fields by name, every type spelled out
/// (what glue reads).
pub fn write_line(
    contract: *const Contract,
    index: u16,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    return write_line_as(contract, index, writer, .spelled);
}

/// `.spelled` writes every type out (what glue reads);
/// `.named` writes a called partial's contract as `Top.Ctx` (the module).
pub fn write_line_as(
    contract: *const Contract,
    index: u16,
    writer: *std.Io.Writer,
    how: enum { spelled, named },
) std.Io.Writer.Error!void {
    const type_ = contract.get(index);
    if (how == .named and index != contract.root and type_.alias.len > 0) {
        return writer.print("{s}.Ctx", .{type_.alias});
    }
    switch (type_.kind) {
        .unknown, .str => try writer.writeAll("Str"),
        .bool => try writer.writeAll("Bool"),
        .int, .other => try writer.writeAll(type_.name),
        .list => {
            try writer.writeAll("List(");
            try write_line_as(contract, type_.element, writer, how);
            try writer.writeAll(")");
        },
        .record => {
            var fields = contract.fields_of(index);
            var k: usize = 0;
            while (fields.next()) |f| : (k += 1) {
                try writer.writeAll(if (k == 0) "{ " else ", ");
                try writer.print("{s} : ", .{f.name});
                try write_line_as(contract, f.type, writer, how);
            }
            try writer.writeAll(if (k == 0) "{}" else " }");
        },
    }
}

/// Whether two contracts' types are the same Roc type (an unknown leaf is
/// a `Str`, as it is written).
pub fn equal(a: *const Contract, ai: u16, b: *const Contract, bi: u16, depth: u8) bool {
    if (depth == 32) return false;
    const x = a.get(ai);
    const y = b.get(bi);
    const kx: Kind = if (x.kind == .unknown) .str else x.kind;
    const ky: Kind = if (y.kind == .unknown) .str else y.kind;
    if (kx != ky) return false;
    return switch (kx) {
        .str, .bool => true,
        .int, .other => std.mem.eql(u8, x.name, y.name),
        .list => equal(a, x.element, b, y.element, depth + 1),
        .record => blk: {
            var count_x: usize = 0;
            var at = x.first;
            while (at != none) : (at = a.fields[at].next) {
                const f = a.fields[at];
                const other = b.field(bi, f.name) orelse break :blk false;
                if (!equal(a, f.type, b, other, depth + 1)) break :blk false;
                count_x += 1;
            }
            var count_y: usize = 0;
            at = y.first;
            while (at != none) : (at = b.fields[at].next) count_y += 1;
            break :blk count_x == count_y;
        },
        .unknown => unreachable,
    };
}

/// Whether every partial a tree calls (through the partials it inlines,
/// too) has its contract: whether `of` can run on it yet. One that does
/// not exist counts as known: the check reports it. generate.zig and the
/// language server order the contracts by it.
pub fn calls_known(templates: []const Template, tree: *const parse.Tree, depth: u8) bool {
    if (depth > partial_depth_max) return true; // the check reports the depth
    for (tree.slice()) |node| {
        if (node.kind != .partial) continue;
        const target = for (templates) |t| {
            if (std.mem.eql(u8, t.name, node.text)) break t;
        } else continue;
        if (node.called()) {
            if (target.contract == null) return false;
        } else if (!calls_known(templates, target.tree, depth + 1)) return false;
    }
    return true;
}

pub const int_names = [_][]const u8{ "U8", "U16", "U32", "U64", "I8", "I16", "I32", "I64" };

pub fn is_int_name(name: []const u8) bool {
    for (int_names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

pub fn new_type(contract: *Contract, kind: Kind, offset: u32) Error!u16 {
    return contract.new(kind, offset);
}

pub fn new_field(contract: *Contract, record: u16, name: []const u8, child: u16) Error!void {
    return contract.add_field(record, name, child);
}

const outside = "reads outside its fragment, which renders alone with its own scope only";

/// Names a fragment may not have: nested in its page's module, it would
/// hide the page's `Ctx` or a type Roc's builtins expose (Builtin.roc of
/// nightly-2026-10-24; the Roc bump re-reads its top-level types).
const reserved = [_][]const u8{
    "Ctx",    "Bool", "Box",    "Crypto", "Dec", "Dict", "Encoding", "F32",  "F64",
    "Hasher", "I8",   "I16",    "I32",    "I64", "I128", "Iter",     "List", "Num",
    "Set",    "Str",  "Stream", "Try",    "U8",  "U16",  "U32",      "U64",  "U128",
};

const Walker = struct {
    contract: *Contract,
    templates: []const Template,
    diagnostic: *Diagnostic,
    /// The template being walked, for messages.
    template: []const u8 = "",
    /// Inside a fragment: the first scope it may read, its own.
    floor: usize = 0,
    /// The fragments being checked, a bit each, whose reads are noted.
    active: u32 = 0,
    /// Each open scope's binder, by its place on the stack: the walk sets
    /// a section's as it opens it, so the first `scopes.len` are the open
    /// scopes'. The page's own scope is unnamed: its fields are the names.
    binders: [parse.depth_max + 1][]const u8 = @splat(""),

    fn fail(walker: *Walker, offset: u32, message: []const u8, subject: []const u8) Error {
        walker.diagnostic.* = .{
            .template = walker.template,
            .offset = offset,
            .message = message,
            .subject = subject,
        };
        return error.Invalid;
    }

    /// A message about a tag, named as written.
    fn fail_at(walker: *Walker, node: *const parse.Node, message: []const u8) Error {
        return walker.fail(node.offset, message, node.text);
    }

    fn new(walker: *Walker, kind: Kind, offset: u32) Error!u16 {
        return walker.contract.new(kind, offset) catch
            walker.fail(offset, "the contract has too many types", "");
    }

    fn partial(walker: *Walker, node: *const parse.Node, depth: u8) Error!Template {
        if (depth == partial_depth_max) {
            return walker.fail_at(node, "partials include each other too deep (a cycle?)");
        }
        for (walker.templates) |t| if (std.mem.eql(u8, t.name, node.text)) return t;
        return walker.fail_at(node, "is not a template here (no such .rocstache)");
    }

    /// A called partial's contract becomes the type of the field that holds
    /// its context, unless the field has a type already (the check then
    /// compares the two).
    fn adopt(walker: *Walker, node: *const parse.Node, included: Template, target: u16) Error!void {
        const theirs = included.contract orelse
            return walker.fail_at(node, "is a partial that calls back into this one (a cycle)");
        if (walker.contract.types[target].kind != .unknown) return;
        try walker.copy(theirs, theirs.root, target, 0);
        walker.contract.types[target].alias = included.name;
    }

    /// `theirs`'s type `from` into this contract's `into`, recursively.
    fn copy(walker: *Walker, theirs: *const Contract, from: u16, into: u16, depth: u8) Error!void {
        if (depth == 32) return walker.fail(0, "the contract nests too deep", "");
        const source = theirs.get(from);
        const offset = walker.contract.types[into].offset;
        walker.contract.types[into] = .{
            .kind = source.kind,
            .name = source.name,
            .offset = offset,
            .alias = source.alias,
        };
        switch (source.kind) {
            .list => {
                const element = try walker.new(.unknown, offset);
                walker.contract.types[into].element = element;
                try walker.copy(theirs, source.element, element, depth + 1);
            },
            .record => {
                var at = source.first;
                while (at != none) : (at = theirs.fields[at].next) {
                    const field_ = theirs.fields[at];
                    const child = try walker.new(.unknown, offset);
                    walker.contract.add_field(into, field_.name, child) catch
                        return walker.fail(offset, "the contract has too many fields", field_.name);
                    try walker.copy(theirs, field_.type, child, depth + 1);
                }
            },
            .unknown, .str, .int, .bool, .other => {},
        }
    }

    // ---- inference: the contract from the tags -----------------------------

    fn infer(
        walker: *Walker,
        template: Template,
        from: u16,
        to: u16,
        scopes: []const u16,
        depth: u8,
    ) Error!void {
        walker.template = template.name;
        var i = from;
        while (i < to) : (i = template.tree.nodes[i].end) {
            const node = &template.tree.nodes[i];
            switch (node.kind) {
                .text => {},
                .value => try walker.infer_value(node, scopes),
                .conditional => {
                    const target = try walker.reach(node, scopes);
                    try walker.settle(target, .bool, node);
                    try walker.infer(template, i + 1, node.end, scopes, depth);
                },
                .section, .inverted => try walker.infer_section(template, i, scopes, depth),
                .fragment => {
                    const floor = walker.floor;
                    walker.floor = scopes.len - 1;
                    try walker.infer(template, i + 1, node.end, scopes, depth);
                    walker.floor = floor;
                },
                .partial => {
                    const included = try walker.partial(node, depth);
                    if (node.called()) {
                        try walker.adopt(node, included, try walker.reach(node, scopes));
                    } else {
                        try walker.infer_include(template, node, included, scopes, depth);
                    }
                },
            }
        }
    }

    fn infer_value(walker: *Walker, node: *const parse.Node, scopes: []const u16) Error!void {
        if (node.expression.len > 0) {
            // Its reads' types are not the tags': the template renders only
            // where it is included, its reads typed there.
            if (expression_of(node).reads_len > 0) walker.contract.alone = false;
            return;
        }
        const target = try walker.reach(node, scopes);
        const pipes = node.pipe_slice();
        const kind: Kind = if (pipes.len == 0) .str else switch (pipes[0].formatter) {
            .len => .list,
            .plural => .int,
            .upper, .lower, .url => .str,
        };
        try walker.settle(target, kind, node);
        const type_ = &walker.contract.types[target];
        if (kind == .int and type_.name.len == 0) type_.name = "U64";
        if (kind == .list and type_.element == none) {
            type_.element = try walker.new(.unknown, node.offset);
        }
    }

    fn infer_section(
        walker: *Walker,
        template: Template,
        index: u16,
        scopes: []const u16,
        depth: u8,
    ) Error!void {
        const node = &template.tree.nodes[index];
        const target = try walker.reach(node, scopes);
        if (node.kind == .inverted) {
            // `{{^x}}` opens no scope: x is a Bool, unless a section makes
            // it a list.
            try walker.infer(template, index + 1, node.end, scopes, depth);
            walker.template = template.name;
            const type_ = &walker.contract.types[target];
            if (type_.kind == .unknown) type_.kind = .bool;
            return;
        }
        if (scopes.len == parse.depth_max) return walker.fail_at(node, "sections nest too deep");
        const known = walker.contract.types[target];
        // The element's type: what the body reads of its binder.
        const element = if (known.kind == .list)
            known.element
        else
            try walker.new(.unknown, node.offset);
        var inner: [parse.depth_max + 1]u16 = undefined;
        @memcpy(inner[0..scopes.len], scopes);
        inner[scopes.len] = element;
        walker.binders[scopes.len] = node.binder;
        try walker.infer(template, index + 1, node.end, inner[0 .. scopes.len + 1], depth);
        walker.template = template.name;
        try walker.settle(target, .list, node);
        walker.contract.types[target].element = element;
    }

    /// Where a node's path leads: the open scope its head names, by its
    /// place on the stack, and the path below it.
    fn bound(walker: *Walker, node: *const parse.Node, scopes: []const u16) Error!parse.Bound {
        assert(node.path_len > 0);
        const found = parse.bound(walker.binders[0..scopes.len], node.path_slice());
        if (found.scope < walker.floor) return walker.fail_at(node, outside);
        return found;
    }

    /// The type a node's path names, creating fields as it goes.
    fn reach(walker: *Walker, node: *const parse.Node, scopes: []const u16) Error!u16 {
        const found = try walker.bound(node, scopes);
        var at = scopes[found.scope];
        for (found.path) |name| {
            try walker.settle(at, .record, node);
            at = walker.contract.field(at, name) orelse blk: {
                const child = try walker.new(.unknown, node.offset);
                walker.contract.add_field(at, name, child) catch
                    return walker.fail(node.offset, "the contract has too many fields", name);
                break :blk child;
            };
        }
        return at;
    }

    /// `index` is used as `kind`: fine if it was unknown or already that.
    fn settle(walker: *Walker, index: u16, kind: Kind, node: *const parse.Node) Error!void {
        const type_ = &walker.contract.types[index];
        if (type_.kind == .unknown) {
            type_.kind = kind;
            return;
        }
        if (type_.kind == kind) return;
        // `{{^x}}` took x for a Bool; a section over it makes it a list.
        if (type_.kind == .bool and kind == .list) {
            type_.kind = .list;
            return;
        }
        assert(type_.kind != .unknown and type_.kind != .other);
        const message = conflicts[@backingInt(type_.kind)][@backingInt(kind)];
        return walker.fail(node.offset, message, node.text);
    }

    /// "is a list elsewhere, and a record here", for each pair of kinds.
    const conflicts = blk: {
        const count = @backingInt(Kind.other) + 1; // `other` is the last
        const names = [count][]const u8{
            "?", "a Str", "a number", "a Bool", "a list", "a record", "?",
        };
        var table: [count][count][]const u8 = undefined;
        for (0..count) |was| for (0..count) |now| {
            table[was][now] = "is " ++ names[was] ++ " elsewhere, and " ++ names[now] ++ " here";
        };
        break :blk table;
    };

    // ---- checking: every tag against the contract -----------------------------

    fn check(
        walker: *Walker,
        template: Template,
        from: u16,
        to: u16,
        scopes: []const u16,
        depth: u8,
    ) Error!void {
        walker.template = template.name;
        var i = from;
        while (i < to) : (i = template.tree.nodes[i].end) {
            const node = &template.tree.nodes[i];
            switch (node.kind) {
                .text => {},
                .value => if (node.expression.len == 0) {
                    try walker.check_value(node, try walker.lookup(node, scopes));
                } else if (walker.contract.alone) {
                    try walker.check_expression(node, i, scopes);
                },
                .conditional => {
                    const target = try walker.lookup(node, scopes);
                    if (walker.contract.get(target).kind != .bool) {
                        const message = try walker.is_a(target, "`{{?}}` takes a Bool");
                        return walker.fail_at(node, message);
                    }
                    try walker.check(template, i + 1, node.end, scopes, depth);
                },
                .section, .inverted => try walker.check_section(template, i, scopes, depth),
                .fragment => try walker.check_fragment(template, i, scopes, depth),
                .partial => {
                    const included = try walker.partial(node, depth);
                    if (node.called()) {
                        const theirs = included.contract orelse unreachable; // adopt checked it
                        const target = try walker.lookup(node, scopes);
                        if (!equal(walker.contract, target, theirs, theirs.root, 0)) {
                            const message = "is not the partial's contract";
                            return walker.fail_at(node, try walker.is_a(target, message));
                        }
                    } else {
                        // The partial is checked where it stands, its copy
                        // as it will run: what fits is exactly what renders.
                        walker.check(included, 0, included.tree.len, scopes, depth + 1) catch {
                            if (depth > 0) return error.Invalid;
                            return walker.misfit(template, node, scopes[scopes.len - 1]);
                        };
                        walker.template = template.name;
                    }
                },
            }
        }
    }

    fn check_section(
        walker: *Walker,
        template: Template,
        index: u16,
        scopes: []const u16,
        depth: u8,
    ) Error!void {
        const node = &template.tree.nodes[index];
        const target = try walker.lookup(node, scopes);
        const type_ = walker.contract.get(target);
        if (node.kind == .inverted) {
            switch (type_.kind) {
                .bool, .list => {},
                else => return walker.fail_at(
                    node,
                    try walker.is_a(target, "`{{^}}` takes a list or a Bool"),
                ),
            }
            try walker.check(template, index + 1, node.end, scopes, depth);
            walker.template = template.name;
            return;
        }
        assert(node.kind == .section);
        const scope = switch (type_.kind) {
            .list => type_.element,
            .record => target,
            .bool => return walker.fail_at(node, "is a Bool: `{{?x}}` takes it, and names nothing"),
            .unknown, .str, .int, .other => return walker.fail_at(
                node,
                try walker.is_a(target, "a section takes a list or a record"),
            ),
        };
        try walker.named(node, scopes);
        var inner: [parse.depth_max + 1]u16 = undefined;
        @memcpy(inner[0..scopes.len], scopes);
        inner[scopes.len] = scope;
        walker.binders[scopes.len] = node.binder;
        try walker.check(template, index + 1, node.end, inner[0 .. scopes.len + 1], depth);
        walker.template = template.name;
    }

    /// A section's binder names one value: no other name in scope is the
    /// same, an open section's or a field of the page's `Ctx`.
    fn named(walker: *Walker, node: *const parse.Node, scopes: []const u16) Error!void {
        assert(node.binder.len > 0);
        if (scopes.len == parse.depth_max) return walker.fail_at(node, "sections nest too deep");
        for (walker.binders[1..scopes.len]) |binder| {
            if (std.mem.eql(u8, binder, node.binder)) {
                const message = "names its element as an open section does: one name, one value";
                return walker.fail(node.offset, message, node.binder);
            }
        }
        if (walker.contract.field(scopes[0], node.binder) != null) {
            const message = "is a field of the page's `Ctx`: a section's name hides nothing";
            return walker.fail(node.offset, message, node.binder);
        }
    }

    /// A fragment: checked in place, and its scope noted, its contract
    /// when it renders alone. Only the template's own: a partial's
    /// fragments are the partial's, from its own contract.
    fn check_fragment(
        walker: *Walker,
        template: Template,
        index: u16,
        scopes: []const u16,
        depth: u8,
    ) Error!void {
        const node = &template.tree.nodes[index];
        const scope = scopes[scopes.len - 1];
        const active = walker.active;
        if (depth == 0) {
            try walker.fragment_allowed(template, node, scope);
            const contract = walker.contract;
            contract.fragments[contract.fragments_len] = .{
                .name = node.text,
                .node = index,
                .scope = scope,
                .frame = @intCast(scopes.len - 1),
            };
            walker.active |= @as(u32, 1) << @intCast(contract.fragments_len);
            contract.fragments_len += 1;
        }
        const floor = walker.floor;
        walker.floor = scopes.len - 1;
        try walker.check(template, index + 1, node.end, scopes, depth);
        walker.floor = floor;
        walker.active = active;
        walker.template = template.name;
    }

    fn fragment_allowed(
        walker: *Walker,
        template: Template,
        node: *const parse.Node,
        scope: u16,
    ) Error!void {
        const contract = walker.contract;
        // A fragment renders alone, as its page does: inferred or declared,
        // its `Ctx` is in the page's module, so a handler that passes
        // another type is Roc's error. A page that renders only included
        // (its Roc reads fields typed by its includer) has no types to give.
        if (!contract.alone) {
            return walker.fail_at(node, "is in a page that renders only included " ++
                "(its Roc reads fields it does not declare): declare `{{% Ctx : ... %}}`");
        }
        if (contract.get(scope).kind != .record) {
            const message = "a fragment's scope is a record (open a list's elements or a record)";
            return walker.fail_at(node, try walker.is_a(scope, message));
        }
        for (contract.fragment_slice()) |f| {
            if (std.mem.eql(u8, f.name, node.text)) {
                return walker.fail_at(node, "names a second fragment of that name");
            }
        }
        // Nested in the page's module, the name would be the module's own,
        // or hide the page's `Ctx` or one of Roc's types there.
        if (std.mem.eql(u8, template.name, node.text)) {
            return walker.fail_at(node, "is its page's name: the page's module would nest itself");
        }
        for (reserved) |name| {
            if (std.mem.eql(u8, name, node.text)) {
                return walker.fail_at(node, "is a name Roc's own types or the page's Ctx have");
            }
        }
        if (contract.fragments_len == fragments_max) {
            return walker.fail_at(node, "the template has too many fragments");
        }
    }

    /// An include in an inferred contract. A partial that declares its
    /// `Ctx` gives the page's fields those types (its bare names are the
    /// page's), where the includer's tags have not said otherwise; one that
    /// does not adds its reads, as the includer's own tags would.
    fn infer_include(
        walker: *Walker,
        template: Template,
        node: *const parse.Node,
        included: Template,
        scopes: []const u16,
        depth: u8,
    ) Error!void {
        if (declares(included)) {
            const theirs = try declared_of(included, walker.diagnostic);
            try walker.merge(theirs, theirs.root, scopes[0], 0);
            return;
        }
        walker.infer(included, 0, included.tree.len, scopes, depth + 1) catch {
            if (depth > 0) return error.Invalid;
            return walker.misfit(template, node, scopes[scopes.len - 1]);
        };
        walker.template = template.name;
    }

    /// `theirs`'s type `from` into `into` where `into` says nothing yet;
    /// where both have a type, the check compares what the partial reads.
    fn merge(walker: *Walker, theirs: *const Contract, from: u16, into: u16, depth: u8) Error!void {
        if (depth == 32) return walker.fail(0, "the contract nests too deep", "");
        const mine = walker.contract.types[into];
        const source = theirs.get(from);
        if (mine.kind == .unknown) return walker.copy(theirs, from, into, depth);
        if (mine.kind == .list and source.kind == .list) {
            return walker.merge(theirs, source.element, mine.element, depth + 1);
        }
        if (mine.kind != .record or source.kind != .record) return;
        var at = source.first;
        while (at != none) : (at = theirs.fields[at].next) {
            const field_ = theirs.fields[at];
            const child = walker.contract.field(into, field_.name) orelse blk: {
                const child = try walker.new(.unknown, mine.offset);
                walker.contract.add_field(into, field_.name, child) catch {
                    const message = "the contract has too many fields";
                    return walker.fail(mine.offset, message, field_.name);
                };
                break :blk child;
            };
            try walker.merge(theirs, field_.type, child, depth + 1);
        }
    }

    // A misfit's message quotes the partial's own, which may sit in
    // `message_buffer`: it is written here.
    var misfit_buffer: [1024]u8 = undefined;

    /// A partial that does not fit where it is included: the message is at
    /// the include, in the template being written, with the scope there
    /// and where in the partial the read failed.
    fn misfit(walker: *Walker, template: Template, node: *const parse.Node, scope: u16) Error {
        const inner = walker.diagnostic.*;
        const source = for (walker.templates) |t| {
            if (std.mem.eql(u8, t.name, inner.template)) break t.source;
        } else "";
        const at: parse.Diagnostic = .{ .offset = inner.offset };
        var writer: std.Io.Writer = .fixed(&misfit_buffer);
        writer.print("does not fit here: `{s}` {s}\n    this scope  ", .{
            inner.subject, inner.message,
        }) catch {};
        write_line(walker.contract, scope, &writer) catch {};
        writer.print("\n    read at     templates/{s}.rocstache:{d}:{d}", .{
            inner.template, at.line(source), at.column(source),
        }) catch {};
        walker.template = template.name;
        return walker.fail(node.offset, writer.buffered(), node.text);
    }

    /// A read from scope `frame` of field `name` (all of it when the path
    /// is `.`): noted for each fragment being checked whose own scope that
    /// is. Reads deeper in come with the field's type.
    fn note_read(walker: *Walker, frame: usize, record: u16, path: []const []const u8) void {
        const contract = walker.contract;
        var bits = walker.active;
        while (bits != 0) : (bits &= bits - 1) {
            const k: u5 = @intCast(@ctz(bits));
            if (contract.fragments[k].frame != frame) continue;
            var at = contract.get(record).first;
            while (at != none) : (at = contract.fields[at].next) {
                const f = &contract.fields[at];
                if (path.len == 0 or std.mem.eql(u8, f.name, path[0])) f.used |= @as(u32, 1) << k;
            }
        }
    }

    fn check_value(walker: *Walker, node: *const parse.Node, target: u16) Error!void {
        var kind = walker.contract.get(target).kind;
        for (node.pipe_slice()) |pipe| {
            const takes: Kind, const gives: Kind = switch (pipe.formatter) {
                .len => .{ .list, .int },
                .plural => .{ .int, .str },
                .upper, .lower, .url => .{ .str, .str },
            };
            if (kind != takes) {
                return walker.fail_at(node, switch (pipe.formatter) {
                    .len => "`len` takes a list",
                    .plural => "`plural` takes a number",
                    .upper, .lower, .url => "`upper`, `lower` and `url` take a Str",
                });
            }
            kind = gives;
        }
        switch (kind) {
            .str, .int => {},
            .unknown => unreachable,
            .bool => return walker.fail_at(node, "is a Bool: use it as `{{?x}}`"),
            .list => return walker.fail_at(node, "is a list: print its elements, or `| len`"),
            .record => return walker.fail_at(node, "is a record: print its fields"),
            .other => return walker.fail_at(node, try walker.is_a(
                target,
                "a template prints a Str or an integer; format it in Roc, into a Str field",
            )),
        }
    }

    /// The type a node's path names in the finished contract.
    /// Each free name of a Roc expression, found where `resolve` finds it;
    /// then the hole, kept once for each distinct key.
    fn check_expression(
        walker: *Walker,
        node: *const parse.Node,
        index: u16,
        scopes: []const u16,
    ) Error!void {
        assert(walker.contract.alone);
        const parsed = expression_of(node);
        for (parsed.read_slice()) |*read| _ = try walker.resolve(node, scopes, read);
        var leaves: [hole.reads_max]Leaf = undefined;
        const binders = walker.binders[0..scopes.len];
        _ = try of_hole(&hole_buffer, walker.contract, scopes, binders, &parsed, &leaves);
        const key = hole_key(walker.template, node.expression, &hole_buffer) catch
            return walker.fail(node.offset, "reads types too long to name", node.text);
        const contract = walker.contract;
        for (contract.hole_slice()) |site| if (site.key == key) return;
        if (contract.holes_len == holes_max) {
            return walker.fail(node.offset, "the page has too many holes of Roc", node.text);
        }
        var site: HoleSite = .{
            .key = key,
            .template = walker.template,
            .node = index,
            .scopes = undefined,
            .binders = undefined,
            .scopes_len = @intCast(scopes.len),
        };
        @memcpy(site.scopes[0..scopes.len], scopes);
        @memcpy(site.binders[0..scopes.len], binders);
        contract.holes[contract.holes_len] = site;
        contract.holes_len += 1;
    }

    /// A free name and its path: the open section that names it, else the
    /// page's `Ctx` (`parse.bound`), then its fields. Noted as read, as a
    /// path's are, for the fragment around.
    pub fn resolve(
        walker: *Walker,
        node: *const parse.Node,
        scopes: []const u16,
        read: *const hole.Read,
    ) Error!Resolved {
        const found = parse.bound(walker.binders[0..scopes.len], read.path_slice());
        if (found.scope < walker.floor) return walker.fail(node.offset, outside, read.path[0]);
        const at = try walker.walk(node.offset, scopes, found);
        return .{ .scope = @intCast(found.scope), .type = at };
    }

    fn lookup(walker: *Walker, node: *const parse.Node, scopes: []const u16) Error!u16 {
        return walker.walk(node.offset, scopes, try walker.bound(node, scopes));
    }

    /// The type a bound path names in the finished contract, its read
    /// noted for the fragments around.
    fn walk(walker: *Walker, offset: u32, scopes: []const u16, found: parse.Bound) Error!u16 {
        var at = scopes[found.scope];
        if (walker.contract.get(at).kind == .record) {
            walker.note_read(found.scope, at, found.path);
        }
        for (found.path, 0..) |name, k| {
            if (walker.contract.get(at).kind != .record) {
                return walker.fail(offset, try walker.is_a(at, "has no fields"), name);
            }
            const message = if (k == 0 and !found.named)
                "is neither a field of the page's `Ctx` nor a section's name"
            else
                "the contract has no such field here";
            at = walker.contract.field(at, name) orelse
                return walker.fail(offset, try walker.has(at, message), name);
        }
        return at;
    }

    // Messages that name types live in a per-walk buffer: one message at a time.
    var message_buffer: [512]u8 = undefined;

    fn is_a(walker: *Walker, index: u16, message: []const u8) Error![]const u8 {
        var writer: std.Io.Writer = .fixed(&message_buffer);
        writer.print("{s} (it is ", .{message}) catch return message;
        write_line(walker.contract, index, &writer) catch return message;
        writer.writeAll(")") catch return message;
        return writer.buffered();
    }

    fn has(walker: *Walker, record: u16, message: []const u8) Error![]const u8 {
        var writer: std.Io.Writer = .fixed(&message_buffer);
        writer.print("{s} (it has: ", .{message}) catch return message;
        var fields = walker.contract.fields_of(record);
        var k: usize = 0;
        while (fields.next()) |f| : (k += 1) {
            writer.print("{s}{s}", .{ if (k == 0) "" else ", ", f.name }) catch return message;
        }
        writer.writeAll(")") catch return message;
        return writer.buffered();
    }
};

const testing = std.testing;

fn contract_line(source: []const u8, partials: []const [2][]const u8, buffer: []u8) ![]const u8 {
    var trees: [4]parse.Tree = undefined;
    var templates: [4]Template = undefined;
    var d: parse.Diagnostic = .{};
    try parse.parse(source, &trees[0], &d);
    templates[0] = .{ .name = "T", .source = source, .tree = &trees[0] };
    for (partials, 1..) |p, k| {
        try parse.parse(p[1], &trees[k], &d);
        templates[k] = .{ .name = p[0], .source = p[1], .tree = &trees[k] };
    }
    const contract = try testing.allocator.create(Contract);
    defer testing.allocator.destroy(contract);
    var diagnostic: Diagnostic = .{};
    of(contract, templates[0 .. partials.len + 1], &diagnostic) catch |err| {
        std.debug.print("{s} `{s}` {s}\n", .{
            diagnostic.template,
            diagnostic.subject,
            diagnostic.message,
        });
        return err;
    };
    var writer: std.Io.Writer = .fixed(buffer);
    try write_line(contract, contract.root, &writer);
    return writer.buffered();
}

test "contract: inferred, every shape" {
    var buffer: [512]u8 = undefined;
    const cases = [_][2][]const u8{
        .{
            "<table>{{#dishes |dish|}}<tr><td>{{ dish.name }}</td><td>{{ dish.price }}</td>" ++
                "</tr>{{/dishes}}</table>",
            "{ dishes : List({ name : Str, price : Str }) }",
        },
        .{
            "<title>{{ title }}</title>{{ items | len | plural \"dish\" \"dishes\" }}" ++
                "{{#items |item|}}{{ item.name }}{{/items}}{{^items}}none{{/items}}" ++
                "{{?admin}}<a>{{ user.name }}</a>{{/admin}}{{#tags |tag|}}{{ tag }}{{/tags}}" ++
                "{{?home}}h{{/home}}{{ n | plural \"a\" \"b\" }}{{^off}}on{{/off}}",
            "{ admin : Bool, home : Bool, items : List({ name : Str }), n : U64, " ++
                "off : Bool, tags : List(Str), title : Str, user : { name : Str } }",
        },
        // Nested, the outer binder read inside; a binder never read.
        .{
            "{{#rows |row|}}{{#row.cells |cell|}}{{ row.id }}{{ cell }}{{/row.cells}}{{/rows}}" ++
                "{{#xs |x|}}-{{/xs}}",
            "{ rows : List({ cells : List(Str), id : Str }), xs : List(Str) }",
        },
        .{ "static", "{}" },
    };
    for (cases) |case| {
        try testing.expectEqualStrings(case[1], try contract_line(case[0], &.{}, &buffer));
    }
}

/// The page's contract, then each fragment's (`{ … } | Row: { … }`); or
/// what refused it: `Template `subject` message`.
fn outcome(page: []const u8, partials: []const [2][]const u8, buffer: []u8) ![]const u8 {
    var trees: [4]parse.Tree = undefined;
    var templates: [4]Template = undefined;
    var d: parse.Diagnostic = .{};
    try parse.parse(page, &trees[0], &d);
    templates[0] = .{ .name = "Page", .source = page, .tree = &trees[0] };
    for (partials, 1..) |p, k| {
        try parse.parse(p[1], &trees[k], &d);
        templates[k] = .{ .name = p[0], .source = p[1], .tree = &trees[k] };
    }
    const contract = try testing.allocator.create(Contract);
    defer testing.allocator.destroy(contract);
    const fragment = try testing.allocator.create(Contract);
    defer testing.allocator.destroy(fragment);
    var diagnostic: Diagnostic = .{};
    var writer: std.Io.Writer = .fixed(buffer);
    of(contract, templates[0 .. partials.len + 1], &diagnostic) catch {
        try writer.print("{s} `{s}` {s}", .{
            diagnostic.template, diagnostic.subject, diagnostic.message,
        });
        return writer.buffered();
    };
    try write_line(contract, contract.root, &writer);
    for (contract.fragment_slice(), 0..) |f, k| {
        try of_fragment(fragment, contract, @intCast(k));
        try writer.print(" | {s}: ", .{f.name});
        try write_line(fragment, fragment.root, &writer);
    }
    return writer.buffered();
}

const declared_page = "{{% Ctx : { title : Str, n : U32, on : Bool, tags : List(Str), " ++
    "items : List({ id : U64, name : Str, price : U32 }), meta : { label : Str, n : U64 } } %}}";
const declared_line = "{ items : List({ id : U64, name : Str, price : U32 }), " ++
    "meta : { label : Str, n : U64 }, n : U32, on : Bool, tags : List(Str), title : Str }";

test "contract: an include fits where its partial's tags fit, as the copy will run" {
    var buffer: [1024]u8 = undefined;
    const fit = [_][2][]const u8{
        .{ "{{#items |item|}}{{> P}}{{/items}}", "{{ item.price }}" },
        .{ "{{> P}}", "{{ title | upper }}" },
        .{ "{{#meta |m|}}{{> P}}{{/meta}}", "{{ m.n | plural \"a\" \"b\" }}" },
        .{ "{{> P}}", "{{ tags | len }}" },
        .{ "{{> P}}", "{{ items | len }}" },
        .{ "{{> P}}", "{{?on}}y{{/on}}" },
        .{ "{{> P}}", "{{ meta.label }}" },
        .{ "{{> P}}", "{{^items}}none{{/items}}" },
        .{ "{{> P}}", "{{#meta |m|}}{{ m.label }}{{/meta}}" },
        .{ "{{> P}}", "{{#meta |m|}}x{{/meta}}" },
        .{ "{{?on}}{{> P}}{{/on}}", "<footer>hi</footer>" },
        // One partial, two scopes: the page's names stay in scope in both.
        .{ "{{#items |item|}}{{> P}}{{/items}}{{#meta |m|}}{{> P}}{{/meta}}", "{{ title }}" },
        // One name for two sections side by side: neither hides the other.
        .{ "{{#items |x|}}{{> P}}{{/items}}{{#meta |x|}}{{> P}}{{/meta}}", "{{?on}}{{/on}}" },
    };
    for (fit) |case| {
        errdefer std.debug.print("case {s} / {s}\n", .{ case[0], case[1] });
        const page = try std.mem.concat(testing.allocator, u8, &.{ declared_page, case[0] });
        defer testing.allocator.free(page);
        const result = try outcome(page, &.{.{ "P", case[1] }}, &buffer);
        try testing.expectEqualStrings(declared_line, result);
    }
    const misfit = [_][3][]const u8{
        .{ "{{> P}}", "{{ n | upper }}", "`n` `upper`, `lower` and `url` take a Str" },
        .{ "{{> P}}", "{{ missing }}", "`missing` is neither a field of the page's `Ctx`" },
        .{ "{{#items |item|}}{{> P}}{{/items}}", "{{ item.nope }}", "`nope` the contract has" },
        .{ "{{> P}}", "{{?items}}x{{/items}}", "`items` `{{?}}` takes a Bool" },
        .{ "{{> P}}", "{{ meta }}", "`meta` is a record" },
        // Where its includer does not bind the name it reads.
        .{ "{{#items |item|}}{{> P}}{{/items}}{{> P}}", "{{ item.id }}", "`item` is neither" },
        // The same name bound to another record.
        .{ "{{#items |x|}}{{> P}}{{/items}}{{#meta |x|}}{{> P}}{{/meta}}", "{{ x.id }}", "`id`" },
        // A partial's section may not hide its includer's names.
        .{ "{{#items |item|}}{{> P}}{{/items}}", "{{#tags |item|}}{{/tags}}", "`item` names" },
    };
    for (misfit) |case| {
        errdefer std.debug.print("case {s} / {s}\n", .{ case[0], case[1] });
        const page = try std.mem.concat(testing.allocator, u8, &.{ declared_page, case[0] });
        defer testing.allocator.free(page);
        const result = try outcome(page, &.{.{ "P", case[1] }}, &buffer);
        const expected = try std.mem.concat(testing.allocator, u8, &.{
            "Page `P` does not fit here: ", case[2],
        });
        defer testing.allocator.free(expected);
        try testing.expect(std.mem.startsWith(u8, result, expected));
    }
}

test "contract: a misfit is said at the include, with the scope and the partial's line" {
    var buffer: [1024]u8 = undefined;
    // Through a partial: the include in the page, the line in the last one.
    const page = declared_page ++ "{{#meta |m|}}{{> P}}{{/meta}}";
    const result = try outcome(page, &.{
        .{ "P", "<b>\n{{> Q}}</b>" },
        .{ "Q", "x {{ m.price }}" },
    }, &buffer);
    try testing.expectEqualStrings("Page `P` does not fit here: `price` the contract has no " ++
        "such field here (it has: label, n)\n" ++
        "    this scope  { label : Str, n : U64 }\n" ++
        "    read at     templates/Q.rocstache:1:3", result);
    // Inferred, a clash between the page's reads and the partial's.
    const clash = try outcome("{{ price | upper }}{{> P}}", &.{
        .{ "P", "{{ price | plural \"a\" \"b\" }}" },
    }, &buffer);
    try testing.expect(std.mem.startsWith(u8, clash, "Page `P` does not fit here: " ++
        "`price` is a Str elsewhere, and a number here"));
}

test "contract: an inferred includer takes a declared partial's types" {
    var buffer: [512]u8 = undefined;
    const d = .{
        "D",
        "{{% Ctx : { price : U32, tags : List(Str) } %}}{{ price }}{{ tags | len }}",
    };
    // Its bare names are the page's fields, wherever it stands.
    const cases = [_][2][]const u8{
        .{ "{{#items |item|}}{{> D}}{{/items}}", "{ items : List(Str), price : U32, " ++
            "tags : List(Str) }" },
        // The page's own read came first: the copy prints a Str as well.
        .{ "{{ price }}{{> D}}", "{ price : Str, tags : List(Str) }" },
    };
    for (cases) |case| {
        try testing.expectEqualStrings(case[1], try outcome(case[0], &.{d}, &buffer));
    }
}

test "contract: a fragment's contract is the fields of its scope it reads" {
    var buffer: [1024]u8 = undefined;
    const price = .{ "Price", "{{ item.price }}" };
    const cases = [_][2][]const u8{
        .{ "{{$Hello}}x{{/Hello}}", " | Hello: {}" },
        .{ "{{$Total}}{{ n }}{{/Total}}", " | Total: { n : U32 }" },
        .{ "{{#items |item|}}{{$Row}}{{ item.name }}{{/Row}}{{/items}}", " | Row: { name : Str }" },
        .{
            "{{#items |item|}}{{$Row}}{{ item.id }}{{ item.name }}{{ item.price }}{{/Row}}" ++
                "{{/items}}",
            " | Row: { id : U64, name : Str, price : U32 }",
        },
        .{ "{{#meta |m|}}{{$M}}{{ m.label }}{{/M}}{{/meta}}", " | M: { label : Str }" },
        // A field read comes whole.
        .{
            "{{$Top}}{{#meta |m|}}{{ m.n }}{{/meta}}{{/Top}}",
            " | Top: { meta : { label : Str, n : U64 } }",
        },
        // A page's name read in a section inside the fragment.
        .{
            "{{$All}}{{#items |item|}}{{ title }}{{/items}}{{/All}}",
            " | All: { items : List({ id : U64, name : Str, price : U32 }), title : Str }",
        },
        .{
            "{{$Outer}}{{ title }}{{#items |item|}}{{$Inner}}{{ item.id }}{{/Inner}}{{/items}}" ++
                "{{/Outer}}",
            " | Outer: { items : List({ id : U64, name : Str, price : U32 }), title : Str }" ++
                " | Inner: { id : U64 }",
        },
        // Through a partial.
        .{
            "{{#items |item|}}{{$Row}}{{ item.id }}{{> Price}}{{/Row}}{{/items}}",
            " | Row: { id : U64, price : U32 }",
        },
        .{ "{{?on}}{{$X}}{{ title }}{{/X}}{{/on}}", " | X: { title : Str }" },
        .{ "{{^tags}}{{$X}}{{ title }}{{/X}}{{/tags}}", " | X: { title : Str }" },
        // Two in one scope, each its own.
        .{
            "{{#items |item|}}{{$A}}{{ item.id }}{{/A}}{{$B}}{{ item.name }}{{/B}}{{/items}}",
            " | A: { id : U64 } | B: { name : Str }",
        },
    };
    for (cases) |case| {
        errdefer std.debug.print("case {s}\n", .{case[0]});
        const page = try std.mem.concat(testing.allocator, u8, &.{ declared_page, case[0] });
        defer testing.allocator.free(page);
        const expected = try std.mem.concat(testing.allocator, u8, &.{ declared_line, case[1] });
        defer testing.allocator.free(expected);
        try testing.expectEqualStrings(expected, try outcome(page, &.{price}, &buffer));
    }
}

test "contract: a hole's Roc reads the fields of the open scopes, by name" {
    var buffer: [1024]u8 = undefined;
    const price = .{ "Price", "{{ Fmt.kr(item.price) }}" };
    const cases = [_][2][]const u8{
        .{ "{{ title.len().to_str() }}", "" },
        .{ "{{#items |item|}}{{ title.len().to_str() }}{{/items}}", "" },
        .{
            "{{#items |item|}}{{$Row}}{{ Fmt.kr(item.price) }}{{/Row}}{{/items}}",
            " | Row: { price : U32 }",
        },
        .{
            "{{#items |item|}}{{$Row}}{{ \"${item.name} (${item.id.to_str()})\" }}{{/Row}}" ++
                "{{/items}}",
            " | Row: { id : U64, name : Str }",
        },
        .{ "{{#items |item|}}{{$Row}}{{> Price}}{{/Row}}{{/items}}", " | Row: { price : U32 }" },
        // The element whole.
        .{ "{{#items |item|}}{{$Row}}{{ Fmt.show(item) }}{{/Row}}{{/items}}", " | Row: " ++
            "{ id : U64, name : Str, price : U32 }" },
        .{ "{{$M}}{{ meta.label }}{{ Str.concat(meta.label, \"!\") }}{{/M}}", " | M: { meta : " ++
            "{ label : Str, n : U64 } }" },
    };
    for (cases) |case| {
        errdefer std.debug.print("case {s}\n", .{case[0]});
        const page = try std.mem.concat(testing.allocator, u8, &.{ declared_page, case[0] });
        defer testing.allocator.free(page);
        const expected = try std.mem.concat(testing.allocator, u8, &.{ declared_line, case[1] });
        defer testing.allocator.free(expected);
        try testing.expectEqualStrings(expected, try outcome(page, &.{price}, &buffer));
    }
    const refusals = [_][2][]const u8{
        // A name names one value: a binder hides no other name.
        .{ "{{#items |title|}}{{/items}}", "Page `title` is a field of the page's `Ctx`" },
        .{
            "{{#items |x|}}{{#tags |x|}}{{/tags}}{{/items}}",
            "Page `x` names its element as an open section does",
        },
        .{
            "{{ nope.to_str() }}",
            "Page `nope` is neither a field of the page's `Ctx` nor a section's name",
        },
        .{ "{{#items |item|}}{{/items}}{{ item.id.to_str() }}", "Page `item` is neither" },
        .{ "{{ title.x.to_str() }}", "Page `x` has no fields" },
        .{ "{{ meta.zip.to_str() }}", "Page `zip` the contract has no such field here" },
        .{
            "{{#items |item|}}{{$Row}}{{ title.len().to_str() }}{{/Row}}{{/items}}",
            "Page `title` reads outside its fragment",
        },
    };
    for (refusals) |case| {
        errdefer std.debug.print("case {s}\n", .{case[0]});
        const page = try std.mem.concat(testing.allocator, u8, &.{ declared_page, case[0] });
        defer testing.allocator.free(page);
        const said = try outcome(page, &.{price}, &buffer);
        if (!std.mem.startsWith(u8, said, case[1])) {
            std.debug.print("said: {s}\n", .{said});
            return error.TestUnexpectedResult;
        }
    }
}

/// Each hole the page keeps: `Template: { params }`, comma separated.
fn holes_text(page: []const u8, partial: []const u8, buffer: []u8) ![]const u8 {
    var trees: [2]parse.Tree = undefined;
    var d: parse.Diagnostic = .{};
    try parse.parse(page, &trees[0], &d);
    try parse.parse(partial, &trees[1], &d);
    const templates = [_]Template{
        .{ .name = "Page", .source = page, .tree = &trees[0] },
        .{ .name = "P", .source = partial, .tree = &trees[1] },
    };
    const contract = try testing.allocator.create(Contract);
    defer testing.allocator.destroy(contract);
    const params = try testing.allocator.create(Contract);
    defer testing.allocator.destroy(params);
    var diagnostic: Diagnostic = .{};
    try of(contract, &templates, &diagnostic);
    var writer: std.Io.Writer = .fixed(buffer);
    for (contract.hole_slice(), 0..) |*site, k| {
        const tree = if (std.mem.eql(u8, site.template, "P")) &trees[1] else &trees[0];
        const parsed = expression_of(&tree.nodes[site.node]);
        var leaves: [hole.reads_max]Leaf = undefined;
        const scopes = site.scope_slice();
        _ = try of_hole(params, contract, scopes, site.binder_slice(), &parsed, &leaves);
        const expression = tree.nodes[site.node].expression;
        try testing.expectEqual(site.key, try hole_key(site.template, expression, params));
        try writer.print("{s}{s}: ", .{ if (k == 0) "" else ", ", site.template });
        try write_line(params, params.root, &writer);
    }
    return writer.buffered();
}

test "contract: each distinct hole is kept once, its parameters narrowed to what it reads" {
    var buffer: [1024]u8 = undefined;
    const lists = "{{% Ctx : { a : List({ x : U32 }), b : List({ x : U64 }), " ++
        "m : { label : Str, n : U64 } } %}}";
    const cases = [_][3][]const u8{
        .{
            "{{#a |e|}}{{> P}}{{/a}}{{#b |e|}}{{> P}}{{/b}}{{#a |e|}}{{> P}}{{/a}}",
            "{{ e.x.to_str() }}",
            "P: { e : { x : U32 } }, P: { e : { x : U64 } }",
        },
        .{
            "{{ m.label.len().to_str() }}{{ m.label.len().to_str() }}",
            "",
            "Page: { m : { label : Str } }",
        },
        .{
            "{{ \"${m.label}${m.n.to_str()}\" }}",
            "",
            "Page: { m : { label : Str, n : U64 } }",
        },
        .{ "{{ Fmt.both(m.label, m) }}", "", "Page: { m : { label : Str, n : U64 } }" },
        .{
            "{{#a |e|}}{{ \"${e.x.to_str()}/${m.n.to_str()}\" }}{{/a}}",
            "",
            "Page: { e : { x : U32 }, m : { n : U64 } }",
        },
        // A binder read whole covers its fields' reads.
        .{ "{{#a |e|}}{{ Fmt.both(e.x, e) }}{{/a}}", "", "Page: { e : { x : U32 } }" },
        .{ "{{ \"static\" }}", "", "Page: {}" },
    };
    for (cases) |case| {
        errdefer std.debug.print("case {s}\n", .{case[0]});
        const page = try std.mem.concat(testing.allocator, u8, &.{ lists, case[0] });
        defer testing.allocator.free(page);
        try testing.expectEqualStrings(case[2], try holes_text(page, case[1], &buffer));
    }
}

test "contract: an inferred template whose Roc reads the scope renders only included" {
    const cases = [_]struct { source: []const u8, alone: bool }{
        .{ .source = "{{ Fmt.kr(price) }}", .alone = false },
        .{ .source = "{{% import Fmt %}}<b>{{ Fmt.kr(dish.price) }}</b>", .alone = false },
        .{ .source = "{{ \"static\" }}{{ title }}", .alone = true },
        .{ .source = "{{#items |item|}}{{> Price}}{{/items}}", .alone = false },
    };
    const price = "{{ Fmt.kr(item.price) }}";
    for (cases) |case| {
        var trees: [2]parse.Tree = undefined;
        var d: parse.Diagnostic = .{};
        try parse.parse(case.source, &trees[0], &d);
        try parse.parse(price, &trees[1], &d);
        const templates = [_]Template{
            .{ .name = "T", .source = case.source, .tree = &trees[0] },
            .{ .name = "Price", .source = price, .tree = &trees[1] },
        };
        const contract = try testing.allocator.create(Contract);
        defer testing.allocator.destroy(contract);
        var diagnostic: Diagnostic = .{};
        try of(contract, &templates, &diagnostic);
        try testing.expectEqual(case.alone, contract.alone);
    }
}

test "contract: a fragment's refusals" {
    var buffer: [1024]u8 = undefined;
    const reads_title = .{ "P", "{{ title }}" };
    const cases = [_][3][]const u8{
        .{ "{{$Row}}a{{/Row}}{{#meta |m|}}{{$Row}}b{{/Row}}{{/meta}}", "Row", "names a second" },
        .{ "{{$Ctx}}x{{/Ctx}}", "Ctx", "is a name Roc's own types" },
        .{ "{{$Str}}x{{/Str}}", "Str", "is a name Roc's own types" },
        .{ "{{$Iter}}x{{/Iter}}", "Iter", "is a name Roc's own types" },
        .{ "{{$Page}}x{{/Page}}", "Page", "is its page's name" },
        .{
            "{{#tags |tag|}}{{$Row}}{{ tag }}{{/Row}}{{/tags}}",
            "Row",
            "a fragment's scope is a record",
        },
        .{ "{{#on |o|}}{{$Row}}x{{/Row}}{{/on}}", "on", "is a Bool: `{{?x}}` takes it" },
        .{ "{{#items |item|}}{{$Row}}{{ title }}{{/Row}}{{/items}}", "title", "reads outside" },
        .{ "{{#items |item|}}{{$Row}}{{> P}}{{/Row}}{{/items}}", "P", "does not fit here: " ++
            "`title` reads outside its fragment" },
    };
    for (cases) |case| {
        errdefer std.debug.print("case {s}\n", .{case[0]});
        const page = try std.mem.concat(testing.allocator, u8, &.{ declared_page, case[0] });
        defer testing.allocator.free(page);
        const result = try outcome(page, &.{reads_title}, &buffer);
        const expected = try std.fmt.allocPrint(testing.allocator, "Page `{s}` {s}", .{
            case[1], case[2],
        });
        defer testing.allocator.free(expected);
        try testing.expect(std.mem.startsWith(u8, result, expected));
    }
    // In an inferred page, a fragment's `Ctx` is what its tags infer.
    const inferred_page = "{{#items |item|}}{{$Row}}{{ item.id }}{{ title }}{{/Row}}{{/items}}";
    const inferred = try outcome(inferred_page, &.{}, &buffer);
    try testing.expectEqualStrings("Page `title` reads outside its fragment", inferred[0..39]);
    const inferred_row = try outcome("{{#items |item|}}{{$Row}}{{ item.id }}{{?item.on}}" ++
        "x{{/item.on}}{{/Row}}{{/items}}", &.{}, &buffer);
    try testing.expectEqualStrings("{ items : List({ id : Str, on : Bool }) } | Row: " ++
        "{ id : Str, on : Bool }", inferred_row);
    // In a page that renders only included: refused, its reads are untyped.
    const included_only = try outcome("{{$Row}}{{ Fmt.kr(price) }}{{/Row}}", &.{}, &buffer);
    try testing.expect(std.mem.startsWith(u8, included_only, "Page `Row` is in a page that " ++
        "renders only included"));
    // More than a contract holds.
    var source: std.Io.Writer.Allocating = .init(testing.allocator);
    defer source.deinit();
    try source.writer.writeAll(declared_page);
    for (0..fragments_max + 1) |k| {
        try source.writer.print("{{{{$Part{d}}}}}x{{{{/Part{d}}}}}", .{ k, k });
    }
    const many = try outcome(source.written(), &.{}, &buffer);
    try testing.expect(std.mem.endsWith(u8, many, "the template has too many fragments"));
}

test "contract: a partial's fields are its includer's" {
    var buffer: [512]u8 = undefined;
    const line = try contract_line(
        "{{> Top}}<p>{{ body }}</p>{{> Bottom}}",
        &.{
            .{ "Top", "<title>{{ title }}</title>{{#nav |link|}}{{ link.label }}{{/nav}}" },
            .{ "Bottom", "</html>" },
        },
        &buffer,
    );
    const expected = "{ body : Str, nav : List({ label : Str }), title : Str }";
    try testing.expectEqualStrings(expected, line);
}

test "contract: conflicts and mistakes name the tag" {
    const cases = [_]struct { source: []const u8, subject: []const u8 }{
        .{ .source = "{{ a }}{{ a.b }}", .subject = "a.b" },
        .{ .source = "{{#xs |x|}}{{ x.y }}{{/xs}}{{ xs }}", .subject = "xs" },
        .{ .source = "{{ n | upper }}{{ n | plural \"a\" \"b\" }}", .subject = "n" },
        .{ .source = "{{?flag}}x{{/flag}}{{#flag |f|}}{{ f.y }}{{/flag}}", .subject = "flag" },
        // A binder hides nothing: not an open section's, nor a page's field.
        .{ .source = "{{#xs |x|}}{{#x.ys |x|}}{{/x.ys}}{{/xs}}", .subject = "x" },
        .{ .source = "{{ title }}{{#xs |title|}}{{/xs}}", .subject = "title" },
        .{ .source = "{{> Missing}}", .subject = "Missing" },
    };
    for (cases) |case| {
        var tree: parse.Tree = .{};
        var d: parse.Diagnostic = .{};
        try parse.parse(case.source, &tree, &d);
        const templates = [_]Template{.{ .name = "T", .source = case.source, .tree = &tree }};
        const contract = try testing.allocator.create(Contract);
        defer testing.allocator.destroy(contract);
        var diagnostic: Diagnostic = .{};
        errdefer std.debug.print("case {s}\n", .{case.source});
        try testing.expectError(error.Invalid, of(contract, &templates, &diagnostic));
        try testing.expectEqualStrings(case.subject, diagnostic.subject);
    }
}
