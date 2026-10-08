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

pub const Field = struct { name: []const u8, type: u16, next: u16 = none };

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

/// Types and fields in fixed arrays: a contract is small, and bounded.
pub const Contract = struct {
    types: [types_max]Type = undefined,
    types_len: u16 = 0,
    fields: [fields_max]Field = undefined,
    fields_len: u16 = 0,
    root: u16 = none,
    declared: bool = false,
    /// The `##` lines above a declared `Ctx`.
    docs: []const u8 = "",

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

    fn add_field(contract: *Contract, record: u16, name: []const u8, child: u16) Error!void {
        if (contract.fields_len == fields_max) return error.Invalid;
        const type_ = &contract.types[record];
        assert(type_.kind == .record);
        contract.fields[contract.fields_len] = .{
            .name = name,
            .type = child,
            .next = type_.first,
        };
        type_.first = contract.fields_len;
        contract.fields_len += 1;
    }

    /// A record's fields sorted by name, into `buffer`.
    pub fn sorted_fields(contract: *const Contract, record: u16, buffer: []Field) []Field {
        var len: usize = 0;
        var at = contract.get(record).first;
        while (at != none) : (at = contract.fields[at].next) {
            buffer[len] = contract.fields[at];
            len += 1;
        }
        std.mem.sort(Field, buffer[0..len], {}, field_less);
        return buffer[0..len];
    }
};

fn field_less(_: void, a: Field, b: Field) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// The contract of `templates[0]`, checked; its partials are found among
/// `templates` by name.
pub fn of(
    contract: *Contract,
    templates: []const Template,
    diagnostic: *Diagnostic,
) Error!void {
    assert(templates.len > 0);
    contract.* = .{};
    const self = templates[0];
    var walker: Walker = .{
        .contract = contract,
        .templates = templates,
        .diagnostic = diagnostic,
    };
    if (std.mem.trim(u8, self.tree.block, " \t\n").len > 0) {
        try @import("declared.zig").read(contract, self, diagnostic);
        contract.declared = true;
    } else {
        contract.root = try walker.new(.record, 0);
        try walker.infer(self, 0, self.tree.len, &.{contract.root}, 0);
    }
    try walker.check(self, 0, self.tree.len, &.{contract.root}, 0);
}

/// The contract as one line of Roc, fields by name: what the id hashes.
pub fn write_line(
    contract: *const Contract,
    index: u16,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    return write_line_as(contract, index, writer, .spelled);
}

/// `.spelled` writes every type out (what the id hashes and glue reads);
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
            var buffer: [fields_max]Field = undefined;
            const fields = contract.sorted_fields(index, &buffer);
            if (fields.len == 0) return writer.writeAll("{}");
            try writer.writeAll("{ ");
            for (fields, 0..) |f, k| {
                if (k > 0) try writer.writeAll(", ");
                try writer.print("{s} : ", .{f.name});
                try write_line_as(contract, f.type, writer, how);
            }
            try writer.writeAll(" }");
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

pub fn id(name: []const u8, line: []const u8) u64 {
    var hash = std.hash.Fnv1a_64.init();
    hash.update(name);
    hash.update("\x00");
    hash.update(line);
    return hash.final();
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

const Walker = struct {
    contract: *Contract,
    templates: []const Template,
    diagnostic: *Diagnostic,
    /// The template being walked, for messages.
    template: []const u8 = "",

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
                .partial => {
                    const included = try walker.partial(node, depth);
                    if (node.called()) {
                        try walker.adopt(node, included, try walker.reach(node, scopes));
                    } else {
                        try walker.infer(included, 0, included.tree.len, scopes, depth + 1);
                        walker.template = template.name;
                    }
                },
            }
        }
    }

    fn infer_value(walker: *Walker, node: *const parse.Node, scopes: []const u16) Error!void {
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
        return walker.fail(node.offset, switch (type_.kind) {
            .str => "is printed elsewhere as a Str, so it cannot be used so here",
            .int => "is a number elsewhere, so it cannot be used so here",
            .bool => "is a Bool elsewhere, so it cannot be used so here",
            .list => "is a list elsewhere, so it cannot be used so here",
            .record => "is a record elsewhere, so it cannot be used so here",
            .unknown, .other => unreachable,
        }, node.text);
    }

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
                .value => try walker.check_value(node, try walker.lookup(node, scopes)),
                .conditional => {
                    const target = try walker.lookup(node, scopes);
                    if (walker.contract.get(target).kind != .bool) {
                        const message = try walker.is_a(target, "`{{?}}` takes a Bool");
                        return walker.fail_at(node, message);
                    }
                    try walker.check(template, i + 1, node.end, scopes, depth);
                },
                .section, .inverted => try walker.check_section(template, i, scopes, depth),
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
                        try walker.check(included, 0, included.tree.len, scopes, depth + 1);
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
    fn lookup(walker: *Walker, node: *const parse.Node, scopes: []const u16) Error!u16 {
        if (node.up >= scopes.len) return walker.fail_at(node, above);
        var at = scopes[scopes.len - 1 - node.up];
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
        var buffer: [fields_max]Field = undefined;
        for (walker.contract.sorted_fields(record, &buffer), 0..) |f, k| {
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

test "contract: a called partial has its own contract, its includer's field that type" {
    const top_source = "<title>{{ title }}</title>{{#nav}}{{ label }}{{/nav}}";
    var trees: [2]parse.Tree = undefined;
    var d: parse.Diagnostic = .{};
    try parse.parse(top_source, &trees[0], &d);
    const top = try testing.allocator.create(Contract);
    defer testing.allocator.destroy(top);
    var diagnostic: Diagnostic = .{};
    try of(top, &.{.{ .name = "Top", .source = top_source, .tree = &trees[0] }}, &diagnostic);

    const page = try testing.allocator.create(Contract);
    defer testing.allocator.destroy(page);
    const sources = [_][]const u8{
        "{{> Top frame}}<p>{{ body }}</p>",
        "{{% Ctx : { frame : { title : Str }, body : Str } %}}{{> Top frame}}",
    };
    // Inferred: `frame` takes Top's contract, named for the module.
    try parse.parse(sources[0], &trees[1], &d);
    const templates = [_]Template{
        .{ .name = "Page", .source = sources[0], .tree = &trees[1] },
        .{ .name = "Top", .source = top_source, .tree = &trees[0], .contract = top },
    };
    try of(page, &templates, &diagnostic);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try write_line(page, page.root, &writer);
    try testing.expectEqualStrings(
        "{ body : Str, frame : { nav : List({ label : Str }), title : Str } }",
        writer.buffered(),
    );
    try testing.expectEqualStrings("Top", page.get(page.field(page.root, "frame").?).alias);
    // Declared otherwise: refused.
    try parse.parse(sources[1], &trees[1], &d);
    const declared = [_]Template{
        .{ .name = "Page", .source = sources[1], .tree = &trees[1] },
        .{ .name = "Top", .source = top_source, .tree = &trees[0], .contract = top },
    };
    try testing.expectError(error.Invalid, of(page, &declared, &diagnostic));
    try testing.expectEqualStrings("Top", diagnostic.subject);
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
