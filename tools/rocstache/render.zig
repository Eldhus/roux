//! A rocstache template compiled by Zig: `Compiled(registry, index)`.
//!
//! The template's source is a comptime string. This file parses it while
//! Zig compiles (parse.zig, the parser everything else uses), checks each
//! name it reads against the contract `Ctx` (the `extern struct`s roc
//! glue emits, so the layout is the Roc compiler's), and walks the tree
//! with `inline` loops: each step runs in the compiler and leaves behind
//! only the code for its node. Static text becomes a fixed-size copy, a
//! value a load at a fixed offset and an escape, a section a loop. Nothing
//! is interpreted at run time.
//!
//! Rendering is two passes over the same tree: `measure` counts the bytes
//! exactly, `render` writes them into one buffer of that size.
//!
//! A registry is a type with `pub const all = [_]Entry{...}`, each entry
//! `.{ .name, .id, .Ctx, .source }` (the generated templates.zig).
//! Partials are found in it by name and compiled inline, in the scope that
//! includes them. roux build has checked every template against its
//! contract already; the `@compileError`s here are a backstop.

const std = @import("std");
const assert = std.debug.assert;
const parse = @import("parse.zig");
const out_ = @import("out.zig");
const symbols = @import("symbols.zig");
pub const Out = out_.Out;

pub fn Compiled(comptime registry: type, comptime index: usize) type {
    const entry = registry.all[index];
    const t = template(registry, entry.name);
    return struct {
        pub const Ctx = entry.Ctx;

        /// The bytes `render` writes for `ctx`, exactly.
        pub fn measure(ctx: *const Ctx) usize {
            return measure_range(t, 0, t.tree.len, .{ctx});
        }

        /// Renders into `out`, which has room for `measure(ctx)` bytes.
        pub fn render(ctx: *const Ctx, out: *Out) void {
            render_range(t, 0, t.tree.len, .{ctx}, out);
        }
    };
}

const Template = struct {
    registry: type,
    name: []const u8,
    source: []const u8,
    tree: *const parse.Tree,

    fn fail(
        comptime t: Template,
        comptime node: parse.Node,
        comptime message: []const u8,
    ) noreturn {
        const d: parse.Diagnostic = .{ .offset = node.offset };
        @compileError(std.fmt.comptimePrint("{s}.rocstache:{d}: `{s}` {s}", .{
            t.name, d.line(t.source), node.text, message,
        }));
    }
};

fn template(comptime registry: type, comptime name: []const u8) Template {
    for (registry.all) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return .{
            .registry = registry,
            .name = name,
            .source = entry.source,
            .tree = &Parsed(name, entry.source).tree,
        };
    }
    @compileError("no template named " ++ name);
}

/// A partial called with its own context (`{{> Top frame}}`): compiled
/// once, in its own object (part.zig), and reached by its symbols, so an
/// edit to it recompiles only it. Its context is the includer's field,
/// whose glue type is another Zig type with the partial's `Ctx` layout
/// (the same Roc record; the contract checked they are equal).
fn Called(comptime t: Template, comptime node: parse.Node) type {
    const entry = for (t.registry.all) |e| {
        if (std.mem.eql(u8, e.name, node.text)) break e;
    } else @compileError("no template named " ++ node.text);
    return struct {
        const Ctx = entry.Ctx;
        const measure = symbols.Extern(Ctx, entry.id).measure;
        const draw = symbols.Extern(Ctx, entry.id).draw;

        inline fn context(field: anytype) *const Ctx {
            comptime assert(@sizeOf(@TypeOf(field.*)) == @sizeOf(Ctx));
            comptime assert(@alignOf(@TypeOf(field.*)) == @alignOf(Ctx));
            return @ptrCast(field);
        }
    };
}

/// One parse per template, however many include it (Zig memoizes the type).
fn Parsed(comptime name: []const u8, comptime source: []const u8) type {
    return struct {
        const tree = blk: {
            @setEvalBranchQuota(10_000_000);
            var t: parse.Tree = .{};
            var d: parse.Diagnostic = .{};
            parse.parse(source, &t, &d) catch @compileError(std.fmt.comptimePrint(
                "{s}.rocstache:{d}: `{s}` {s}",
                .{ name, d.line(source), d.subject, d.message },
            ));
            break :blk t;
        };
    };
}

// ---- the contract's types, seen from Zig -----------------------------------------

const Shape = enum { str, int, bool, list, record, other };

fn shape_of(comptime T: type) Shape {
    if (T == bool) return .bool;
    return switch (@typeInfo(T)) {
        .int => .int,
        .@"struct" => if (@hasDecl(T, "asSlice") and @hasField(T, "capacity_or_alloc_ptr"))
            .str
        else if (@hasField(T, "elements_ptr")) .list else .record,
        else => .other,
    };
}

fn items(list: anytype) []const Element(@TypeOf(list.*)) {
    const ptr = list.elements_ptr orelse return &.{};
    return ptr[0..list.length];
}

fn Element(comptime List: type) type {
    return @typeInfo(@typeInfo(@FieldType(List, "elements_ptr")).optional.child).pointer.child;
}

/// The value a node's path names: a pointer into the contract.
fn resolve(
    comptime t: Template,
    comptime node: parse.Node,
    scopes: anytype,
) Resolved(t, node, @TypeOf(scopes)) {
    return walk(node.path_slice(), scopes[scopes.len - 1 - node.up]);
}

fn Resolved(comptime t: Template, comptime node: parse.Node, comptime Scopes: type) type {
    const types = @typeInfo(Scopes).@"struct".field_types;
    if (node.up >= types.len) t.fail(node, "climbs above the template's context");
    var T = @typeInfo(types[types.len - 1 - node.up]).pointer.child;
    for (node.path_slice()) |field| {
        if (@typeInfo(T) != .@"struct" or !@hasField(T, field)) {
            t.fail(node, "names a field the contract does not have: run roux build");
        }
        T = @FieldType(T, field);
    }
    return *const T;
}

fn walk(comptime path: []const []const u8, ptr: anytype) Walked(path, @TypeOf(ptr)) {
    if (path.len == 0) return ptr;
    return walk(path[1..], &@field(ptr.*, path[0]));
}

fn Walked(comptime path: []const []const u8, comptime P: type) type {
    var T = @typeInfo(P).pointer.child;
    for (path) |field| T = @FieldType(T, field);
    return *const T;
}

// ---- the two passes ------------------------------------------------------------

fn measure_range(
    comptime t: Template,
    comptime from: u16,
    comptime to: u16,
    scopes: anytype,
) usize {
    var total: usize = 0;
    comptime var i = from;
    inline while (i < to) : (i = t.tree.nodes[i].end) {
        const node = comptime t.tree.nodes[i];
        switch (node.kind) {
            .text => total += node.text.len,
            .value => total += measure_value(t, node, resolve(t, node, scopes)),
            .partial => if (comptime node.called()) {
                const C = Called(t, node);
                total += C.measure(C.context(resolve(t, node, scopes)));
            } else {
                const included = comptime template(t.registry, node.text);
                total += measure_range(included, 0, included.tree.len, scopes);
            },
            .section, .inverted, .conditional => {
                const v = resolve(t, node, scopes);
                switch (comptime body(t, node, @TypeOf(v.*))) {
                    .skip => {},
                    .same => if (shown(node, v)) {
                        total += measure_range(t, i + 1, node.end, scopes);
                    },
                    .inner => if (shown(node, v)) {
                        total += measure_range(t, i + 1, node.end, scopes ++ .{v});
                    },
                    .each => for (items(v)) |*item| {
                        total += measure_range(t, i + 1, node.end, scopes ++ .{item});
                    },
                }
            },
        }
    }
    return total;
}

fn render_range(
    comptime t: Template,
    comptime from: u16,
    comptime to: u16,
    scopes: anytype,
    out: *Out,
) void {
    comptime var i = from;
    inline while (i < to) : (i = t.tree.nodes[i].end) {
        const node = comptime t.tree.nodes[i];
        switch (node.kind) {
            .text => out.write_static(node.text),
            .value => render_value(node, resolve(t, node, scopes), out),
            .partial => if (comptime node.called()) {
                const C = Called(t, node);
                C.draw(C.context(resolve(t, node, scopes)), out);
            } else {
                const included = comptime template(t.registry, node.text);
                render_range(included, 0, included.tree.len, scopes, out);
            },
            .section, .inverted, .conditional => {
                const v = resolve(t, node, scopes);
                const end = node.end;
                switch (comptime body(t, node, @TypeOf(v.*))) {
                    .skip => {},
                    .same => if (shown(node, v)) render_range(t, i + 1, end, scopes, out),
                    .inner => if (shown(node, v)) render_range(t, i + 1, end, scopes ++ .{v}, out),
                    .each => for (items(v)) |*item| {
                        render_range(t, i + 1, end, scopes ++ .{item}, out);
                    },
                }
            },
        }
    }
}

/// How a section's body is reached, decided at comptime: once per element
/// (`each`), once in a new scope (`inner`: a record, or a Bool's scope as
/// contract.zig defines it), once in the same scope (`same`).
const Body = enum { skip, same, inner, each };

fn body(comptime t: Template, comptime node: parse.Node, comptime T: type) Body {
    const shape = shape_of(T);
    return switch (node.kind) {
        .section => switch (shape) {
            .list => .each,
            .bool, .record => .inner,
            .str, .int, .other => t.fail(node, "a section takes a list, a record or a Bool"),
        },
        .inverted => switch (shape) {
            .list, .bool => .same,
            .str, .int, .record, .other => t.fail(node, "`{{^}}` takes a list or a Bool"),
        },
        .conditional => if (shape == .bool) .same else t.fail(node, "`{{?}}` takes a Bool"),
        .text, .value, .partial => unreachable,
    };
}

/// Whether a section's body shows, for the cases that show it at most once.
inline fn shown(comptime node: parse.Node, v: anytype) bool {
    const T = @TypeOf(v.*);
    return switch (comptime shape_of(T)) {
        .bool => v.* == (node.kind != .inverted),
        .list => v.length == 0,
        .record => true,
        .str, .int, .other => unreachable,
    };
}

fn measure_value(comptime t: Template, comptime node: parse.Node, v: anytype) usize {
    const shape = comptime shape_of(@TypeOf(v.*));
    const pipes = comptime node.pipe_slice();
    if (pipes.len == 0) return switch (shape) {
        .str => if (node.escape) out_.escaped_bytes(v.asSlice()) else v.asSlice().len,
        .int => out_.int_bytes(v.*),
        .bool, .list, .record, .other => t.fail(node, "prints only a Str or an integer"),
    };
    const last = pipes[pipes.len - 1];
    return switch (last.formatter) {
        .len => out_.int_bytes(list_of(t, node, v).length),
        .plural => {
            const n = count_of(t, node, v);
            const noun = comptime nouns(node, last);
            return out_.int_bytes(n) + 1 + (if (n == 1) noun[0].len else noun[1].len);
        },
        .upper, .lower => if (node.escape)
            out_.escaped_bytes(str_of(t, node, v))
        else
            str_of(t, node, v).len,
        .url => out_.percent_encoded_bytes(str_of(t, node, v)),
    };
}

fn render_value(comptime node: parse.Node, v: anytype, out: *Out) void {
    const shape = comptime shape_of(@TypeOf(v.*));
    const pipes = comptime node.pipe_slice();
    if (pipes.len == 0) return switch (shape) {
        .str => if (node.escape) out_.escape(v.asSlice(), out) else out.write(v.asSlice()),
        .int => out_.write_int(v.*, out),
        .bool, .list, .record, .other => unreachable,
    };
    const last = pipes[pipes.len - 1];
    switch (last.formatter) {
        .len => out_.write_int(v.length, out),
        .plural => {
            const n: u64 = if (shape == .list) v.length else @intCast(v.*);
            const noun = comptime nouns(node, last);
            out_.write_int(n, out);
            out.write_static(" ");
            if (n == 1) out.write_static(noun[0]) else out.write_static(noun[1]);
        },
        .upper => out_.write_case(v.asSlice(), .upper, node.escape, out),
        .lower => out_.write_case(v.asSlice(), .lower, node.escape, out),
        .url => out_.percent_encode(v.asSlice(), out),
    }
}

/// `plural`'s two nouns, escaped at comptime when the tag escapes.
fn nouns(comptime node: parse.Node, comptime pipe: parse.Pipe) [2][]const u8 {
    if (!node.escape) return pipe.args;
    var result: [2][]const u8 = undefined;
    for (pipe.args, 0..) |arg, k| {
        var escaped: []const u8 = "";
        for (arg) |b| {
            const e = out_.entity(b);
            escaped = escaped ++ (if (e.len > 0) e else &[_]u8{b});
        }
        result[k] = escaped;
    }
    return result;
}

fn list_of(comptime t: Template, comptime node: parse.Node, v: anytype) @TypeOf(v) {
    if (comptime shape_of(@TypeOf(v.*)) != .list) t.fail(node, "`len` takes a list");
    return v;
}

fn str_of(comptime t: Template, comptime node: parse.Node, v: anytype) []const u8 {
    if (comptime shape_of(@TypeOf(v.*)) != .str) t.fail(node, "takes a Str for its formatter");
    return v.asSlice();
}

fn count_of(comptime t: Template, comptime node: parse.Node, v: anytype) u64 {
    return switch (comptime shape_of(@TypeOf(v.*))) {
        .list => v.length,
        .int => @intCast(v.*),
        .str, .bool, .record, .other => t.fail(node, "`plural` takes a number"),
    };
}

// ---- tests: contracts as glue lays them out, by hand -------------------------------

const testing = std.testing;

/// The glue's string, as far as the renderer cares (its real one is the same
/// `extern struct`, with more methods).
const TestStr = extern struct {
    bytes: ?[*]const u8,
    capacity_or_alloc_ptr: usize,
    length: usize,

    fn of(text: []const u8) TestStr {
        return .{
            .bytes = text.ptr,
            .capacity_or_alloc_ptr = text.len << 1,
            .length = text.len,
        };
    }

    pub fn asSlice(s: *const TestStr) []const u8 {
        return s.bytes.?[0..s.length];
    }
};

fn TestList(comptime T: type) type {
    return extern struct {
        elements_ptr: ?[*]const T,
        length: usize,
        capacity_or_alloc_ptr: usize,

        fn of(elements: []const T) @This() {
            return .{
                .elements_ptr = elements.ptr,
                .length = elements.len,
                .capacity_or_alloc_ptr = 0,
            };
        }
    };
}

const Dish = extern struct { name: TestStr, price: u32 };
const MenuCtx = extern struct { dishes: TestList(Dish) };
const PageCtx = extern struct {
    items: TestList(Dish),
    nav: TestList(TestStr),
    title: TestStr,
    vegan: bool,
};

const test_registry = struct {
    pub const all = .{
        .{
            .name = "Menu",
            .Ctx = MenuCtx,
            .source = "<table>{{#dishes}}<tr><td>{{ name }}</td><td>{{ price }}</td></tr>\n" ++
                "{{/dishes}}</table>",
        },
        .{
            .name = "Top",
            .Ctx = PageCtx,
            .source = "<title>{{ title }}</title>{{#nav}}<a>{{.}}</a>{{/nav}}",
        },
        .{
            .name = "Page",
            .Ctx = PageCtx,
            .source = "{{> Top}}<h1>{{ title | upper }}</h1>" ++
                "<p>{{ items | len | plural \"dish\" \"dishes\" }}" ++
                "{{?vegan}}, vegan{{/vegan}}</p>" ++
                "{{#items}}<a href=\"/d/{{ name | url }}\">{{ name }}" ++
                "{{#../vegan}}!{{/../vegan}}</a>{{/items}}{{^items}}closed{{/items}}",
        },
    };
};

fn rendered(comptime index: usize, ctx: anytype, buffer: []u8) ![]const u8 {
    const T = Compiled(test_registry, index);
    const size = T.measure(ctx);
    var out: Out = .{ .buffer = buffer.ptr, .capacity = size };
    T.render(ctx, &out);
    try testing.expectEqual(size, out.len);
    return buffer[0..out.len];
}

test "render: the race's menu" {
    var buffer: [512]u8 = undefined;
    const dishes = [_]Dish{
        .{ .name = .of("Roux"), .price = 120 },
        .{ .name = .of("Fish & <chips>"), .price = 95 },
    };
    const ctx: MenuCtx = .{ .dishes = .of(&dishes) };
    try testing.expectEqualStrings(
        "<table><tr><td>Roux</td><td>120</td></tr>\n" ++
            "<tr><td>Fish &amp; &lt;chips&gt;</td><td>95</td></tr>\n</table>",
        try rendered(0, &ctx, &buffer),
    );
}

test "render: partials, formatters, conditionals, parents, an empty list" {
    var buffer: [512]u8 = undefined;
    const dishes = [_]Dish{.{ .name = .of("Pâté & co"), .price = 1 }};
    const nav = [_]TestStr{ .of("home"), .of("menu") };
    var ctx: PageCtx = .{
        .items = .of(&dishes),
        .nav = .of(&nav),
        .title = .of("Eldhús <menu>"),
        .vegan = true,
    };
    const top = "<title>Eldhús &lt;menu&gt;</title><a>home</a><a>menu</a>" ++
        "<h1>ELDHúS &lt;MENU&gt;</h1>";
    try testing.expectEqualStrings(
        top ++ "<p>1 dish, vegan</p><a href=\"/d/P%C3%A2t%C3%A9%20%26%20co\">Pâté &amp; co!</a>",
        try rendered(2, &ctx, &buffer),
    );
    ctx.items = .of(&.{});
    ctx.vegan = false;
    try testing.expectEqualStrings(top ++ "<p>0 dishes</p>closed", try rendered(2, &ctx, &buffer));
}
