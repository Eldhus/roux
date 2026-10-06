//! Context-shape inference.
//!
//! The generator decides the *shape* of the context, not its types: which
//! names are records, lists, Bool sections, and which are printed values. A
//! printed value (`{{ x }}`) becomes `x.to_str()` in the generated code and
//! roc works out its type (Str, any number, anything with `to_str`); a value
//! piped into a formatter is whatever that function takes, which roc checks.
//!
//! Every template scope (the root context and each section body) gets a
//! `Shape`. Shapes live in one flat array and are unified with union-find, so
//! the same field used twice, or a partial merged into a scope, resolves to a
//! single node. Nothing here allocates per use beyond appending to the arrays.

const std = @import("std");
const Allocator = std.mem.Allocator;
const m = @import("mustache.zig");

pub const Kind = enum(u8) {
    unknown,
    /// Printed with `to_str`: `{{ x }}`. Its Roc type is roc's business.
    value,
    bool,
    list,
    record,
    /// A `{{#x}}` scope whose element shape is still being discovered.
    /// Resolves to `bool` if nothing inside touches the element, else `list`.
    section,
};

pub const none: u32 = std.math.maxInt(u32);

pub const Shape = struct {
    kind: Kind = .unknown,
    text: []const u8 = "",
    elem: u32 = 0,
    /// record: head of this record's field chain (index into `fields`).
    first: u32 = none,
    fwd: u32,
};

pub const Field = struct {
    name: []const u8,
    shape: u32,
    /// Next field of the same record, or `none`.
    next: u32 = none,
};

pub const Error = error{ TypeError, OutOfMemory };

pub const Infer = struct {
    gpa: Allocator,
    diag: *m.Diagnostic,
    shapes: std.ArrayList(Shape) = .empty,
    fields: std.ArrayList(Field) = .empty,

    pub fn init(gpa: Allocator, diag: *m.Diagnostic) Infer {
        return .{ .gpa = gpa, .diag = diag };
    }

    fn fail(self: *Infer, offset: u32, msg: []const u8) Error {
        self.diag.* = .{ .offset = offset, .message = msg };
        return error.TypeError;
    }

    pub fn new(self: *Infer, kind: Kind) Error!u32 {
        const id: u32 = @intCast(self.shapes.items.len);
        try self.shapes.append(self.gpa, .{ .kind = kind, .fwd = id });
        return id;
    }

    pub fn newSection(self: *Infer) Error!u32 {
        const elem = try self.new(.unknown);
        const id = try self.new(.section);
        self.shapes.items[id].elem = elem;
        return id;
    }

    pub fn find(self: *Infer, id: u32) u32 {
        var cur = id;
        while (self.shapes.items[cur].fwd != cur) cur = self.shapes.items[cur].fwd;
        // Path compression.
        var walk = id;
        while (self.shapes.items[walk].fwd != walk) {
            const next = self.shapes.items[walk].fwd;
            self.shapes.items[walk].fwd = cur;
            walk = next;
        }
        return cur;
    }

    pub fn get(self: *Infer, id: u32) Shape {
        return self.shapes.items[self.find(id)];
    }

    /// The kind a shape will be emitted as (sections resolved).
    pub fn resolvedKind(self: *Infer, id: u32) Kind {
        const s = self.get(id);
        if (s.kind != .section) return s.kind;
        return if (self.get(s.elem).kind == .unknown) .bool else .list;
    }

    pub fn field(self: *Infer, owner: u32, name: []const u8) ?u32 {
        var cur = self.shapes.items[self.find(owner)].first;
        while (cur != none) : (cur = self.fields.items[cur].next) {
            const f = self.fields.items[cur];
            if (std.mem.eql(u8, f.name, name)) return f.shape;
        }
        return null;
    }

    fn addField(self: *Infer, owner_root: u32, name: []const u8, shape: u32) Error!void {
        const idx: u32 = @intCast(self.fields.items.len);
        try self.fields.append(self.gpa, .{ .name = name, .shape = shape, .next = self.shapes.items[owner_root].first });
        self.shapes.items[owner_root].first = idx;
    }

    /// Fields of a record, sorted by name (deterministic output).
    pub fn sortedFields(self: *Infer, owner: u32) Error![]Field {
        const root = self.find(owner);
        var out: std.ArrayList(Field) = .empty;
        var cur = self.shapes.items[root].first;
        while (cur != none) : (cur = self.fields.items[cur].next) try out.append(self.gpa, self.fields.items[cur]);
        std.mem.sort(Field, out.items, {}, struct {
            fn lt(_: void, a: Field, b: Field) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lt);
        return out.toOwnedSlice(self.gpa);
    }

    /// Makes `owner` a record (if it was unknown) and returns the named field,
    /// creating it as `unknown` on first use.
    pub fn getOrAddField(self: *Infer, owner: u32, name: []const u8, offset: u32) Error!u32 {
        const root = self.find(owner);
        const s = &self.shapes.items[root];
        switch (s.kind) {
            .unknown => s.kind = .record,
            .record => {},
            .value => return self.fail(offset, "this value is printed elsewhere (`{{ x }}`), so it has no fields"),
            .bool => return self.fail(offset, "this value is used as a boolean section elsewhere, so it has no fields"),
            .list, .section => return self.fail(offset, "this value is a list; open it with `{{#name}}` before using its fields"),
        }
        if (self.field(root, name)) |f| return f;
        const fs = try self.new(.unknown);
        try self.addField(root, name, fs);
        return fs;
    }

    pub fn unify(self: *Infer, a_id: u32, b_id: u32, offset: u32) Error!void {
        const a = self.find(a_id);
        const b = self.find(b_id);
        if (a == b) return;
        const sa = self.shapes.items[a];
        const sb = self.shapes.items[b];
        if (sa.kind == .unknown) return self.forward(a, b);
        if (sb.kind == .unknown) return self.forward(b, a);
        if (sa.kind == sb.kind) switch (sa.kind) {
            .value, .bool => return self.forward(b, a),
            .list, .section => {
                try self.unify(sa.elem, sb.elem, offset);
                return self.forward(b, a);
            },
            .record => {
                // Move b's fields into a, unifying duplicates.
                var cur = sb.first;
                while (cur != none) {
                    const next = self.fields.items[cur].next;
                    const f = self.fields.items[cur];
                    if (self.field(a, f.name)) |existing| {
                        try self.unify(existing, f.shape, offset);
                    } else {
                        self.fields.items[cur].next = self.shapes.items[a].first;
                        self.shapes.items[a].first = cur;
                    }
                    cur = next;
                }
                self.shapes.items[b].first = none;
                return self.forward(b, a);
            },
            .unknown => unreachable,
        };
        // section ~ bool / list
        if (sa.kind == .section) return self.unifySection(a, b, offset);
        if (sb.kind == .section) return self.unifySection(b, a, offset);
        if (sa.kind == .value or sb.kind == .value) {
            const other = if (sa.kind == .value) sb.kind else sa.kind;
            return self.fail(offset, switch (other) {
                .bool => "a Bool cannot be printed; use it as a section (`{{?x}}`) or pipe it (`| yes_no`)",
                .list => "a list cannot be printed; loop over it with `{{#x}}` or pipe it (`| join \", \"`)",
                else => "a record cannot be printed; print its fields (`{{ x.name }}`)",
            });
        }
        return self.fail(offset, "conflicting uses of the same value (Bool vs list/record)");
    }

    fn unifySection(self: *Infer, sec: u32, other: u32, offset: u32) Error!void {
        const ss = self.shapes.items[sec];
        const so = self.shapes.items[other];
        switch (so.kind) {
            .bool => {
                if (self.get(ss.elem).kind != .unknown) return self.fail(offset, "section is iterated as a list here but used as a boolean elsewhere");
                return self.forward(sec, other);
            },
            .list => {
                try self.unify(ss.elem, so.elem, offset);
                return self.forward(sec, other);
            },
            .value => return self.fail(offset, "a section's value cannot also be printed; pipe it through a formatter instead"),
            else => return self.fail(offset, "conflicting uses of the same value (section vs record)"),
        }
    }

    fn forward(self: *Infer, from: u32, to: u32) void {
        self.shapes.items[from].fwd = to;
    }

    pub fn constrain(self: *Infer, id: u32, kind: Kind, text: []const u8, offset: u32) Error!void {
        const fresh = try self.new(kind);
        self.shapes.items[fresh].text = text;
        try self.unify(id, fresh, offset);
    }

    /// Deep-copies a shape graph (used to instantiate a partial's context per use).
    pub fn clone(self: *Infer, id: u32) Error!u32 {
        const root = self.find(id);
        const s = self.shapes.items[root];
        const out = try self.new(s.kind);
        self.shapes.items[out].text = s.text;
        switch (s.kind) {
            .list, .section => {
                const e = try self.clone(s.elem);
                self.shapes.items[out].elem = e;
            },
            .record => {
                const fs = try self.sortedFields(root);
                for (fs) |f| {
                    const c = try self.clone(f.shape);
                    try self.addField(out, f.name, c);
                }
            },
            else => {},
        }
        return out;
    }

    /// Structural equality of two resolved shapes.
    pub fn equal(self: *Infer, a_id: u32, b_id: u32) Error!bool {
        const a = self.find(a_id);
        const b = self.find(b_id);
        if (a == b) return true;
        const ka = self.resolvedKind(a);
        const kb = self.resolvedKind(b);
        if (ka != kb) return false;
        const sa = self.shapes.items[a];
        const sb = self.shapes.items[b];
        return switch (ka) {
            .unknown, .value, .bool => true,
            .list => self.equal(sa.elem, sb.elem),
            .record => blk: {
                const fa = try self.sortedFields(a);
                const fb = try self.sortedFields(b);
                if (fa.len != fb.len) break :blk false;
                for (fa, fb) |x, y| {
                    if (!std.mem.eql(u8, x.name, y.name)) break :blk false;
                    if (!try self.equal(x.shape, y.shape)) break :blk false;
                }
                break :blk true;
            },
            .section => unreachable,
        };
    }

    /// Writes a shape in Roc type syntax, for people (hovers): a printed
    /// value, or a value only used through formatters, is `_` (roc infers
    /// it), and records are open, since any record with these fields fits.
    pub fn writeType(self: *Infer, w: *std.Io.Writer, id: u32) (Error || std.Io.Writer.Error)!void {
        const root = self.find(id);
        const s = self.shapes.items[root];
        switch (self.resolvedKind(root)) {
            .unknown, .value => try w.writeAll("_"),
            .bool => try w.writeAll("Bool"),
            .list => {
                try w.writeAll("List(");
                try self.writeType(w, s.elem);
                try w.writeAll(")");
            },
            .record => {
                const fs = try self.sortedFields(root);
                if (fs.len == 0) return w.writeAll("{ .. }");
                try w.writeAll("{ ");
                for (fs, 0..) |f, i| {
                    if (i != 0) try w.writeAll(", ");
                    try w.writeAll(f.name);
                    try w.writeAll(" : ");
                    try self.writeType(w, f.shape);
                }
                try w.writeAll(", .. }");
            },
            .section => unreachable,
        }
    }
};

/// Resolves a dotted path against a scope, returning the leaf shape. Creates
/// intermediate record fields as needed. An empty path is the scope itself.
pub fn resolvePath(inf: *Infer, scope: u32, path: []const []const u8, offset: u32) Error!u32 {
    var cur = scope;
    for (path) |seg| cur = try inf.getOrAddField(cur, seg, offset);
    return cur;
}

/// Like `resolvePath`, against a stack of enclosing scopes: leading `..`
/// segments pick the scope, the rest is a normal path.
pub fn resolveScoped(inf: *Infer, root: u32, scopes: []const u32, path: []const []const u8, offset: u32) Error!u32 {
    if (m.isRootPath(path)) return resolvePath(inf, root, path[1..], offset);
    const hops = m.parentHops(path);
    if (hops >= scopes.len) return inf.fail(offset, "`..` goes above the template's own context (there is no enclosing scope here)");
    return resolvePath(inf, scopes[scopes.len - 1 - hops], path[hops..], offset);
}

/// Walks a template's nodes, inferring the shape of `scope` (the root context).
/// `partial_root` is called for each `{{> Name}}` and must return a *fresh*
/// (cloned) shape for that partial's context, which is then unified into the
/// current scope.
pub fn inferTemplate(
    inf: *Infer,
    tpl: *const m.Template,
    scope: u32,
    root: u32,
    ctx: anytype,
    comptime partialRoot: fn (@TypeOf(ctx), *Infer, []const u8, u32) anyerror!u32,
) anyerror!void {
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(inf.gpa);
    // (node index that closes the block, whether it pushed a scope)
    var ends: std.ArrayList(struct { at: u32, pushed: bool }) = .empty;
    defer ends.deinit(inf.gpa);
    try stack.append(inf.gpa, scope);

    var i: u32 = 0;
    while (i < tpl.nodes.len) : (i += 1) {
        while (ends.items.len > 0 and ends.items[ends.items.len - 1].at == i) {
            const e = ends.pop().?;
            if (e.pushed) _ = stack.pop();
        }
        const node = tpl.nodes[i];
        const cur = stack.items[stack.items.len - 1];
        switch (node.kind) {
            .text => {},
            .variable => {
                const e = tpl.exprs[node.expr];
                const leaf = try resolveScoped(inf, root, stack.items, tpl.path(e.path_start, e.path_len), e.offset);
                // Printed as it is: `to_str`. Through formatters: whatever
                // they take, so no constraint here (roc checks the calls).
                if (e.fmt_len == 0) try inf.constrain(leaf, .value, "", e.offset);
                for (tpl.fmts[e.fmt_start .. e.fmt_start + e.fmt_len]) |f| {
                    for (tpl.args[f.arg_start .. f.arg_start + f.arg_len]) |a| {
                        if (a.kind == .path) _ = try resolveScoped(inf, root, stack.items, tpl.path(a.path_start, a.path_len), a.offset);
                    }
                }
            },
            .section, .inverted => {
                const e = tpl.exprs[node.expr];
                const leaf = try resolveScoped(inf, root, stack.items, tpl.path(e.path_start, e.path_len), e.offset);
                const sec = try inf.newSection();
                try inf.unify(leaf, sec, e.offset);
                const elem = inf.get(leaf).elem;
                try stack.append(inf.gpa, elem);
                try ends.append(inf.gpa, .{ .at = node.close, .pushed = true });
            },
            .conditional => {
                // A Bool guard; the body sees the same scope as the guard.
                const e = tpl.exprs[node.expr];
                const leaf = try resolveScoped(inf, root, stack.items, tpl.path(e.path_start, e.path_len), e.offset);
                try inf.constrain(leaf, .bool, "", e.offset);
                try ends.append(inf.gpa, .{ .at = node.close, .pushed = false });
            },
            .partial => {
                const name = tpl.partials[node.expr];
                const fresh = try partialRoot(ctx, inf, name, node.start);
                try inf.unify(cur, fresh, node.start);
            },
        }
    }
}

const TestCtx = struct {};
fn noPartials(_: TestCtx, inf: *Infer, _: []const u8, offset: u32) anyerror!u32 {
    return inf.fail(offset, "no partials in this test");
}

fn inferSrc(arena: Allocator, src: []const u8) ![]const u8 {
    var diag: m.Diagnostic = .{};
    const tpl = try m.parse(arena, src, &diag);
    var inf = Infer.init(arena, &diag);
    const root = try inf.new(.record);
    inferTemplate(&inf, &tpl, root, root, TestCtx{}, noPartials) catch |err| {
        std.debug.print("infer error: {s} at {d}\n", .{ diag.message, diag.offset });
        return err;
    };
    var aw: std.Io.Writer.Allocating = .init(arena);
    try inf.writeType(&aw.writer, root);
    return aw.written();
}

test "infers records, lists, bools, dot paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try inferSrc(arena.allocator(),
        \\{{title}}{{#show}}x{{/show}}{{#items}}{{name}} {{owner.email}}{{/items}}{{^items}}none{{/items}}{{#tags}}{{.}}{{/tags}}{{user.profile.name}}
    );
    try std.testing.expectEqualStrings(
        "{ items : List({ name : _, owner : { email : _, .. }, .. }), show : Bool, tags : List(_), title : _, user : { profile : { name : _, .. }, .. }, .. }",
        t,
    );
}

test "formatter inputs and arguments are fields roc types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try inferSrc(arena.allocator(), "{{ price | money currency }} {{ name | upper | pad width }} {{#tags}}{{.}}{{/tags}}{{ tags | join \", \" }}");
    try std.testing.expectEqualStrings("{ currency : _, name : _, price : _, tags : List(_), width : _, .. }", t);
}

test "conflicts are errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.TypeError, inferSrcQuiet(a, "{{x}}{{#x}}y{{/x}}"));
    try std.testing.expectError(error.TypeError, inferSrcQuiet(a, "{{#x}}{{.}}{{a}}{{/x}}"));
    try std.testing.expectError(error.TypeError, inferSrcQuiet(a, "{{?flag}}y{{/flag}}{{ flag }}"));
    try std.testing.expectError(error.TypeError, inferSrcQuiet(a, "{{#x}}{{y}}{{/x}}{{#x}}{{/x}}{{^x}}{{/x}}{{#z}}{{/z}}{{z}}"));
}

fn inferSrcQuiet(arena: Allocator, src: []const u8) ![]const u8 {
    var diag: m.Diagnostic = .{};
    const tpl = try m.parse(arena, src, &diag);
    var inf = Infer.init(arena, &diag);
    const root = try inf.new(.record);
    try inferTemplate(&inf, &tpl, root, root, TestCtx{}, noPartials);
    return "";
}
