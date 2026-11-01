//! A template's contract: the record it reads, as a Roc type.
//!
//! It is the template's declared `Ctx`, when its `{{% %}}` block has one;
//! otherwise it is inferred from the tags: dotted paths are records, a
//! section whose body reads its element is a list, one that does not is a
//! Bool, `{{.}}` in a section makes a list of values, `len` makes a list,
//! a value piped into `plural` is a `U64`, and every other value a `Str`.
//! A partial (`{{> Top}}`) reads from the scope it is included in, so its
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

    pub fn fragment_slice(contract: *const Contract) []const Fragment {
        return contract.fragments[0..contract.fragments_len];
    }

    pub fn import_slice(contract: *const Contract) []const []const u8 {
        return contract.imports[0..contract.imports_len];
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

const above = "climbs above the template's context";
const outside = "climbs out of its fragment, which renders alone with its own scope only";

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
        if (scopes.len == parse.depth_max) return walker.fail_at(node, "sections nest too deep");
        const known = walker.contract.types[target];
        // The element's scope: what the body reads decides list or Bool.
        const element = if (known.kind == .list)
            known.element
        else
            try walker.new(.unknown, node.offset);
        var inner: [parse.depth_max + 1]u16 = undefined;
        @memcpy(inner[0..scopes.len], scopes);
        inner[scopes.len] = element;
        const body_scopes = if (node.kind == .section) inner[0 .. scopes.len + 1] else scopes;
        try walker.infer(template, index + 1, node.end, body_scopes, depth);
        walker.template = template.name;
        const type_ = &walker.contract.types[target];
        if (walker.contract.types[element].kind != .unknown) {
            try walker.settle(target, .list, node);
            type_.element = element;
        } else if (type_.kind == .unknown) {
            type_.kind = .bool;
        }
    }

    /// The type a node's path names, creating fields as it goes.
    fn reach(walker: *Walker, node: *const parse.Node, scopes: []const u16) Error!u16 {
        if (node.up >= scopes.len) return walker.fail_at(node, above);
        if (scopes.len - 1 - node.up < walker.floor) return walker.fail_at(node, outside);
        var at = scopes[scopes.len - 1 - node.up];
        for (node.path_slice()) |name| {
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
        // A Bool section's scope is the element scope of nothing: a later
        // read inside makes it a list (infer_section decides).
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
                    try walker.check_expression(node, scopes);
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
        var inner: [parse.depth_max + 1]u16 = undefined;
        @memcpy(inner[0..scopes.len], scopes);
        const body_scopes = switch (type_.kind) {
            // `{{#flag}}` opens a scope as a list does (the Bool itself, with
            // no fields), so `../` counts the same whatever `flag` turns out
            // to be; `{{?flag}}` is the one that keeps the scope.
            .bool => blk: {
                if (node.kind == .inverted) break :blk scopes;
                inner[scopes.len] = target;
                break :blk inner[0 .. scopes.len + 1];
            },
            .list => blk: {
                if (node.kind == .inverted) break :blk scopes;
                inner[scopes.len] = type_.element;
                break :blk inner[0 .. scopes.len + 1];
            },
            .record => blk: {
                if (node.kind == .inverted) {
                    return walker.fail_at(node, "`{{^}}` takes a list or a Bool, not a record");
                }
                inner[scopes.len] = target;
                break :blk inner[0 .. scopes.len + 1];
            },
            .unknown, .str, .int, .other => return walker.fail_at(
                node,
                try walker.is_a(target, "a section takes a list, a record or a Bool"),
            ),
        };
        try walker.check(template, index + 1, node.end, body_scopes, depth);
        walker.template = template.name;
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
        // Rendered alone, a fragment's fields are typed by a handler: an
        // inferred page would give it `Str` where an integer was meant.
        if (!contract.declared) {
            return walker.fail_at(node, "is in a page with an inferred contract: " ++
                "a fragment renders alone, so its page declares `{{% Ctx : ... %}}`");
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
    /// `Ctx` gives the scope those types, where the includer's tags have
    /// not said otherwise; one that does not adds its reads, as the
    /// includer's own tags would.
    fn infer_include(
        walker: *Walker,
        template: Template,
        node: *const parse.Node,
        included: Template,
        scopes: []const u16,
        depth: u8,
    ) Error!void {
        const scope = scopes[scopes.len - 1];
        if (declares(included)) {
            const theirs = try declared_of(included, walker.diagnostic);
            try walker.merge(theirs, theirs.root, scope, 0);
            return;
        }
        walker.infer(included, 0, included.tree.len, scopes, depth + 1) catch {
            if (depth > 0) return error.Invalid;
            return walker.misfit(template, node, scope);
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
    /// Each free name of a Roc expression, found where `resolve` finds it.
    fn check_expression(walker: *Walker, node: *const parse.Node, scopes: []const u16) Error!void {
        assert(walker.contract.alone);
        const parsed = expression_of(node);
        for (parsed.read_slice()) |*read| _ = try walker.resolve(node, scopes, read);
    }

    /// A free name and its path: the nearest open scope whose record has the
    /// name (the only one: a name two open scopes have is refused), then
    /// its fields. Noted as read, as a path's are, for the fragment around.
    pub fn resolve(
        walker: *Walker,
        node: *const parse.Node,
        scopes: []const u16,
        read: *const hole.Read,
    ) Error!Resolved {
        const name = read.path[0];
        var found: ?usize = null;
        for (0..scopes.len) |k| {
            const scope = walker.contract.get(scopes[k]);
            if (scope.kind != .record or walker.contract.field(scopes[k], name) == null) continue;
            if (found != null) {
                return walker.fail(node.offset, "is a field of two open scopes: a hole's Roc " ++
                    "reads the scope's fields by name, so one name a scope", name);
            }
            found = k;
        }
        const depth = found orelse
            return walker.fail(node.offset, try walker.has(scopes[scopes.len - 1], absent), name);
        if (depth < walker.floor) return walker.fail(node.offset, outside, name);
        walker.note_read(depth, scopes[depth], read.path_slice());
        var at = scopes[depth];
        for (read.path_slice()) |segment| {
            if (walker.contract.get(at).kind != .record) {
                return walker.fail(node.offset, try walker.is_a(at, "has no fields"), segment);
            }
            at = walker.contract.field(at, segment) orelse return walker.fail(
                node.offset,
                try walker.has(at, "the contract has no such field here"),
                segment,
            );
        }
        return .{ .scope = @intCast(depth), .type = at };
    }

    const absent = "is not a field of any open scope";

    fn lookup(walker: *Walker, node: *const parse.Node, scopes: []const u16) Error!u16 {
        if (node.up >= scopes.len) return walker.fail_at(node, above);
        if (scopes.len - 1 - node.up < walker.floor) return walker.fail_at(node, outside);
        var at = scopes[scopes.len - 1 - node.up];
        if (walker.contract.get(at).kind == .record) {
            walker.note_read(scopes.len - 1 - node.up, at, node.path_slice());
        }
        for (node.path_slice()) |name| {
            if (walker.contract.get(at).kind != .record) {
                return walker.fail(node.offset, try walker.is_a(at, "has no fields"), name);
            }
            at = walker.contract.field(at, name) orelse return walker.fail(
                node.offset,
                try walker.has(at, "the contract has no such field here"),
                name,
            );
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
            "<table>{{#dishes}}<tr><td>{{ name }}</td><td>{{ price }}</td></tr>{{/dishes}}</table>",
            "{ dishes : List({ name : Str, price : Str }) }",
        },
        .{
            "<title>{{ title }}</title>{{ items | len | plural \"dish\" \"dishes\" }}" ++
                "{{#items}}{{ name }}{{/items}}{{^items}}none{{/items}}" ++
                "{{#admin}}<a>{{ ../user.name }}</a>{{/admin}}{{#tags}}{{.}}{{/tags}}" ++
                "{{?home}}h{{/home}}{{ n | plural \"a\" \"b\" }}",
            "{ admin : Bool, home : Bool, items : List({ name : Str }), n : U64, " ++
                "tags : List(Str), title : Str, user : { name : Str } }",
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
        .{ "{{#items}}{{> P}}{{/items}}", "{{ price }}" },
        .{ "{{> P}}", "{{ title | upper }}" },
        .{ "{{#meta}}{{> P}}{{/meta}}", "{{ n | plural \"a\" \"b\" }}" },
        .{ "{{> P}}", "{{ tags | len }}" },
        .{ "{{> P}}", "{{ items | len }}" },
        .{ "{{> P}}", "{{#on}}y{{/on}}" },
        .{ "{{> P}}", "{{ meta.label }}" },
        .{ "{{> P}}", "{{^items}}none{{/items}}" },
        .{ "{{> P}}", "{{#meta}}{{ label }}{{/meta}}" },
        .{ "{{> P}}", "{{#meta}}x{{/meta}}" },
        .{ "{{#on}}{{> P}}{{/on}}", "<footer>hi</footer>" },
        // One partial, two scopes: each copy for its own.
        .{ "{{#items}}{{> P}}{{/items}}{{#meta}}{{> P}}{{/meta}}", "{{ ../title }}" },
        // `n` a U32 at the root, a U64 in `meta`.
        .{ "{{> P}}{{#meta}}{{> P}}{{/meta}}", "{{ n }}" },
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
        .{ "{{> P}}", "{{ missing }}", "`missing` the contract has no such field here" },
        .{ "{{#items}}{{> P}}{{/items}}", "{{ nope }}", "`nope` the contract has no such" },
        .{ "{{> P}}", "{{?items}}x{{/items}}", "`items` `{{?}}` takes a Bool" },
        .{ "{{> P}}", "{{ meta }}", "`meta` is a record" },
        .{ "{{> P}}", "{{ ../x }}", "`../x` climbs above the template's context" },
        .{ "{{#items}}{{> P}}{{/items}}{{> P}}", "{{ id }}", "`id` the contract has no such" },
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
    const page = declared_page ++ "{{#meta}}{{> P}}{{/meta}}";
    const result = try outcome(page, &.{
        .{ "P", "<b>\n{{> Q}}</b>" },
        .{ "Q", "x {{ price }}" },
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
    const cases = [_][2][]const u8{
        .{ "{{#items}}{{> D}}{{/items}}", "{ items : List({ price : U32, tags : List(Str) }) }" },
        // The page's own read came first: the copy prints a Str as well.
        .{
            "{{#items}}{{ price }}{{> D}}{{/items}}",
            "{ items : List({ price : Str, tags : List(Str) }) }",
        },
    };
    for (cases) |case| {
        try testing.expectEqualStrings(case[1], try outcome(case[0], &.{d}, &buffer));
    }
}

test "contract: a fragment's contract is the fields of its scope it reads" {
    var buffer: [1024]u8 = undefined;
    const price = .{ "Price", "{{ price }}" };
    const cases = [_][2][]const u8{
        .{ "{{$Hello}}x{{/Hello}}", " | Hello: {}" },
        .{ "{{$Total}}{{ n }}{{/Total}}", " | Total: { n : U32 }" },
        .{ "{{#items}}{{$Row}}{{ name }}{{/Row}}{{/items}}", " | Row: { name : Str }" },
        .{
            "{{#items}}{{$Row}}{{ id }}{{ name }}{{ price }}{{/Row}}{{/items}}",
            " | Row: { id : U64, name : Str, price : U32 }",
        },
        .{ "{{#meta}}{{$M}}{{ label }}{{/M}}{{/meta}}", " | M: { label : Str }" },
        // A field read comes whole.
        .{
            "{{$Top}}{{#meta}}{{ n }}{{/meta}}{{/Top}}",
            " | Top: { meta : { label : Str, n : U64 } }",
        },
        // `../` that stays inside the fragment.
        .{
            "{{$All}}{{#items}}{{ ../title }}{{/items}}{{/All}}",
            " | All: { items : List({ id : U64, name : Str, price : U32 }), title : Str }",
        },
        .{
            "{{$Outer}}{{ title }}{{#items}}{{$Inner}}{{ id }}{{/Inner}}{{/items}}{{/Outer}}",
            " | Outer: { items : List({ id : U64, name : Str, price : U32 }), title : Str }" ++
                " | Inner: { id : U64 }",
        },
        // Through a partial.
        .{
            "{{#items}}{{$Row}}{{ id }}{{> Price}}{{/Row}}{{/items}}",
            " | Row: { id : U64, price : U32 }",
        },
        .{ "{{?on}}{{$X}}{{ title }}{{/X}}{{/on}}", " | X: { title : Str }" },
        .{ "{{^tags}}{{$X}}{{ title }}{{/X}}{{/tags}}", " | X: { title : Str }" },
        // Two in one scope, each its own.
        .{
            "{{#items}}{{$A}}{{ id }}{{/A}}{{$B}}{{ name }}{{/B}}{{/items}}",
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
    const price = .{ "Price", "{{ Fmt.kr(price) }}" };
    const cases = [_][2][]const u8{
        .{ "{{ title.len().to_str() }}", "" },
        .{ "{{#items}}{{ title.len().to_str() }}{{/items}}", "" },
        .{ "{{#items}}{{$Row}}{{ Fmt.kr(price) }}{{/Row}}{{/items}}", " | Row: { price : U32 }" },
        .{
            "{{#items}}{{$Row}}{{ \"${name} (${id.to_str()})\" }}{{/Row}}{{/items}}",
            " | Row: { id : U64, name : Str }",
        },
        .{ "{{#items}}{{$Row}}{{> Price}}{{/Row}}{{/items}}", " | Row: { price : U32 }" },
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
        .{ "{{#meta}}{{ n.to_str() }}{{/meta}}", "Page `n` is a field of two open scopes" },
        .{ "{{ nope.to_str() }}", "Page `nope` is not a field of any open scope" },
        .{ "{{ title.x.to_str() }}", "Page `x` has no fields" },
        .{ "{{ meta.zip.to_str() }}", "Page `zip` the contract has no such field here" },
        .{
            "{{#items}}{{$Row}}{{ title.len().to_str() }}{{/Row}}{{/items}}",
            "Page `title` climbs out of its fragment",
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

test "contract: an inferred template whose Roc reads the scope renders only included" {
    const cases = [_]struct { source: []const u8, alone: bool }{
        .{ .source = "{{ Fmt.kr(price) }}", .alone = false },
        .{ .source = "{{% import Fmt %}}<b>{{ Fmt.kr(dish.price) }}</b>", .alone = false },
        .{ .source = "{{ \"static\" }}{{ title }}", .alone = true },
        .{ .source = "{{#items}}{{> Price}}{{/items}}", .alone = false },
    };
    const price = "{{ Fmt.kr(price) }}";
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
    const climbs = .{ "P", "{{ ../title }}" };
    const cases = [_][3][]const u8{
        .{ "{{$Row}}a{{/Row}}{{#meta}}{{$Row}}b{{/Row}}{{/meta}}", "Row", "names a second" },
        .{ "{{$Ctx}}x{{/Ctx}}", "Ctx", "is a name Roc's own types" },
        .{ "{{$Str}}x{{/Str}}", "Str", "is a name Roc's own types" },
        .{ "{{$Iter}}x{{/Iter}}", "Iter", "is a name Roc's own types" },
        .{ "{{$Page}}x{{/Page}}", "Page", "is its page's name" },
        .{ "{{#tags}}{{$Row}}{{ . }}{{/Row}}{{/tags}}", "Row", "a fragment's scope is a record" },
        .{ "{{#on}}{{$Row}}x{{/Row}}{{/on}}", "Row", "a fragment's scope is a record" },
        .{ "{{#items}}{{$Row}}{{ ../title }}{{/Row}}{{/items}}", "../title", "climbs out" },
        .{ "{{#items}}{{$Row}}{{> P}}{{/Row}}{{/items}}", "P", "does not fit here: " ++
            "`../title` climbs out of its fragment" },
    };
    for (cases) |case| {
        errdefer std.debug.print("case {s}\n", .{case[0]});
        const page = try std.mem.concat(testing.allocator, u8, &.{ declared_page, case[0] });
        defer testing.allocator.free(page);
        const result = try outcome(page, &.{climbs}, &buffer);
        const expected = try std.fmt.allocPrint(testing.allocator, "Page `{s}` {s}", .{
            case[1], case[2],
        });
        defer testing.allocator.free(expected);
        try testing.expect(std.mem.startsWith(u8, result, expected));
    }
    // In an inferred page: refused, its types would be guesses.
    const inferred = try outcome("{{#items}}{{$Row}}{{ id }}{{/Row}}{{/items}}", &.{}, &buffer);
    try testing.expect(std.mem.startsWith(u8, inferred, "Page `Row` is in a page with an " ++
        "inferred contract"));
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
            .{ "Top", "<title>{{ title }}</title>{{#nav}}{{ label }}{{/nav}}" },
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
        .{ .source = "{{#xs}}{{ x }}{{/xs}}{{ xs }}", .subject = "xs" },
        .{ .source = "{{ n | upper }}{{ n | plural \"a\" \"b\" }}", .subject = "n" },
        .{ .source = "{{?flag}}x{{/flag}}{{#flag}}{{ y }}{{/flag}}", .subject = "flag" },
        .{ .source = "{{#a}}{{ ../../b }}{{/a}}", .subject = "../../b" },
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
