//! The template compiler and the host's VM together, against an oracle
//! (`zig build test`): templates made at random from a seed, compiled to
//! bytecode (tools/rocstache/bytecode.zig), run by the VM (templates.zig)
//! over records laid out in memory as Roc lays out `Str` and `List`, and
//! compared byte for byte with a plain walk of the parse tree over the same
//! values, written here with none of the compiler's or the VM's code.
//!
//! The layouts are laid by hand from the Zig structs' own offsets: this
//! checks that the compiler and the VM agree on what a layout says, not
//! what Roc's compiler would choose (an app's layouts are always glue's).

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const rocstache = @import("rocstache");
const parse = rocstache.parse;
const bytecode = rocstache.bytecode;
const layout = rocstache.layout;
const templates = @import("templates.zig");
const abi = @import("roc_platform_abi.zig");
const Prng = @import("fourneau").prng.Prng;

const List = abi.RocListWith(u8, false);

const Tag = extern struct { label: abi.RocStr };
const Item = extern struct { name: abi.RocStr, tags: List, price: u32, hot: bool };
const Meta = extern struct { label: abi.RocStr, n: u32 };
const Ctx = extern struct {
    title: abi.RocStr,
    note: abi.RocStr,
    items: List,
    meta: Meta,
    delta: i64,
    count: u32,
    open: bool,
};

/// The types' indexes in the hand-laid layouts.
const T = struct {
    const ctx = 0;
    const str = 1;
    const u32_ = 2;
    const i64_ = 3;
    const bool_ = 4;
    const items = 5;
    const item = 6;
    const tags = 7;
    const tag = 8;
    const meta = 9;
};

fn field(comptime S: type, comptime name: []const u8, type_: u32) layout.Field {
    return .{ .name = name, .offset = @offsetOf(S, name), .type = type_ };
}

fn leaf(kind: layout.Kind, size: u32) layout.Type {
    return .{ .kind = kind, .size = size, .element = 0, .fields = &.{} };
}

fn list_of(element: u32) layout.Type {
    return .{ .kind = .list, .size = @sizeOf(List), .element = element, .fields = &.{} };
}

const layouts: layout.Layouts = .{
    .contracts = &.{},
    .types = &.{
        .{ .kind = .record, .size = @sizeOf(Ctx), .element = 0, .fields = &.{
            field(Ctx, "title", T.str),   field(Ctx, "note", T.str),
            field(Ctx, "items", T.items), field(Ctx, "meta", T.meta),
            field(Ctx, "delta", T.i64_),  field(Ctx, "count", T.u32_),
            field(Ctx, "open", T.bool_),
        } },
        leaf(.str, @sizeOf(abi.RocStr)),
        leaf(.u32, 4),
        leaf(.i64, 8),
        leaf(.bool, 1),
        list_of(T.item),
        .{ .kind = .record, .size = @sizeOf(Item), .element = 0, .fields = &.{
            field(Item, "name", T.str),   field(Item, "tags", T.tags),
            field(Item, "price", T.u32_), field(Item, "hot", T.bool_),
        } },
        list_of(T.tag),
        .{ .kind = .record, .size = @sizeOf(Tag), .element = 0, .fields = &.{
            field(Tag, "label", T.str),
        } },
        .{ .kind = .record, .size = @sizeOf(Meta), .element = 0, .fields = &.{
            field(Meta, "label", T.str), field(Meta, "n", T.u32_),
        } },
    },
};

// ---- the values ------------------------------------------------------------

/// A `Str` as Roc holds it: inline when short, else a pointer.
fn roc_str(bytes: []const u8) abi.RocStr {
    if (bytes.len < @sizeOf(abi.RocStr)) {
        var small = abi.RocStr.empty();
        const at: [*]u8 = @ptrCast(&small);
        @memcpy(at[0..bytes.len], bytes);
        at[@sizeOf(abi.RocStr) - 1] = @as(u8, @intCast(bytes.len)) | 0x80;
        return small;
    }
    return .{ .bytes = @constCast(bytes.ptr), .capacity_or_alloc_ptr = 0, .length = bytes.len };
}

fn roc_list(comptime E: type, elements: []const E) List {
    if (elements.len == 0) return .empty();
    return .{
        .elements_ptr = @ptrCast(@constCast(elements.ptr)),
        .length = elements.len,
        .capacity_or_alloc_ptr = elements.len,
    };
}

fn items_of(list: List) []const Item {
    const ptr: [*]const Item = @ptrCast(@alignCast(list.elements_ptr orelse return &.{}));
    return ptr[0..list.length];
}

fn tags_of(list: List) []const Tag {
    const ptr: [*]const Tag = @ptrCast(@alignCast(list.elements_ptr orelse return &.{}));
    return ptr[0..list.length];
}

/// Text the escaping must handle: every special byte, UTF-8, long runs.
fn random_text(random: *Prng, arena: std.mem.Allocator) ![]const u8 {
    const pieces = [_][]const u8{ "a", "Roux", " ", "&", "<", ">", "\"", "'", "é", "x/y?z=1", "%" };
    const count = random.int_less_than(usize, 12);
    var out: std.ArrayList(u8) = .empty;
    for (0..count) |_| try out.appendSlice(arena, pieces[random.int_less_than(usize, pieces.len)]);
    // Sometimes long: past 16 bytes (the escape's one look) and 24 (inline).
    if (random.boolean()) for (0..random.int_less_than(usize, 40)) |_| try out.append(arena, 'k');
    return out.items;
}

fn random_ctx(random: *Prng, arena: std.mem.Allocator) !*Ctx {
    const items = try arena.alloc(Item, random.int_less_than(usize, 4));
    for (items) |*item| {
        const tags = try arena.alloc(Tag, random.int_less_than(usize, 3));
        for (tags) |*t| t.* = .{ .label = roc_str(try random_text(random, arena)) };
        item.* = .{
            .name = roc_str(try random_text(random, arena)),
            .tags = roc_list(Tag, tags),
            .price = @as(u32, @truncate(random.next())) >> random.int_less_than(u5, 31),
            .hot = random.boolean(),
        };
    }
    const ctx = try arena.create(Ctx);
    ctx.* = .{
        .title = roc_str(try random_text(random, arena)),
        .note = roc_str(try random_text(random, arena)),
        .items = roc_list(Item, items),
        .meta = .{
            .label = roc_str(try random_text(random, arena)),
            .n = random.int_less_than(u32, 3),
        },
        .delta = @as(i64, @bitCast(random.next())) >> random.int_less_than(u6, 63),
        .count = random.int_less_than(u32, 3),
        .open = random.boolean(),
    };
    return ctx;
}

// ---- the oracle --------------------------------------------------------------

/// A scope of the walk: the record or element a section opened.
const Scope = union(enum) {
    ctx: *const Ctx,
    item: *const Item,
    tag: *const Tag,
    meta: *const Meta,
    flag,
};

const Value = union(enum) {
    str: []const u8,
    number: i128,
    flag: bool,
    items: []const Item,
    tags: []const Tag,
    meta: *const Meta,
};

fn lookup(scope: Scope, name: []const u8) ?Value {
    const eql = std.mem.eql;
    switch (scope) {
        .ctx => |c| {
            if (eql(u8, name, "title")) return .{ .str = c.title.asSlice() };
            if (eql(u8, name, "note")) return .{ .str = c.note.asSlice() };
            if (eql(u8, name, "items")) return .{ .items = items_of(c.items) };
            if (eql(u8, name, "meta")) return .{ .meta = &c.meta };
            if (eql(u8, name, "delta")) return .{ .number = c.delta };
            if (eql(u8, name, "count")) return .{ .number = c.count };
            if (eql(u8, name, "open")) return .{ .flag = c.open };
        },
        .item => |i| {
            if (eql(u8, name, "name")) return .{ .str = i.name.asSlice() };
            if (eql(u8, name, "tags")) return .{ .tags = tags_of(i.tags) };
            if (eql(u8, name, "price")) return .{ .number = i.price };
            if (eql(u8, name, "hot")) return .{ .flag = i.hot };
        },
        .tag => |t| if (eql(u8, name, "label")) return .{ .str = t.label.asSlice() },
        .meta => |m| {
            if (eql(u8, name, "label")) return .{ .str = m.label.asSlice() };
            if (eql(u8, name, "n")) return .{ .number = m.n };
        },
        .flag => {},
    }
    return null;
}

const Oracle = struct {
    out: std.ArrayList(u8) = .empty,
    arena: std.mem.Allocator,
    sources: []const Source,

    fn resolve(scopes: []const Scope, node: *const parse.Node) Value {
        var scope = scopes[scopes.len - 1 - node.up];
        const path = node.path_slice();
        for (path, 0..) |name, k| {
            const found = lookup(scope, name).?;
            if (k == path.len - 1) return found;
            scope = .{ .meta = found.meta }; // only Meta is a nested record here
        }
        unreachable;
    }

    const Error = std.mem.Allocator.Error;

    fn walk(
        o: *Oracle,
        tree: *const parse.Tree,
        from: u16,
        to: u16,
        scopes: []const Scope,
    ) Error!void {
        var i = from;
        while (i < to) : (i = tree.nodes[i].end) {
            const node = &tree.nodes[i];
            switch (node.kind) {
                .text => try o.out.appendSlice(o.arena, node.text),
                .value => try o.value(node, resolve(scopes, node)),
                .section => try o.section(tree, i, scopes),
                .inverted, .conditional => {
                    const enter = switch (resolve(scopes, node)) {
                        .flag => |f| if (node.kind == .conditional) f else !f,
                        .items => |l| l.len == 0,
                        .tags => |l| l.len == 0,
                        else => unreachable,
                    };
                    if (enter) try o.walk(tree, i + 1, node.end, scopes);
                },
                .partial => try o.partial(node, scopes),
            }
        }
    }

    fn section(o: *Oracle, tree: *const parse.Tree, i: u16, scopes: []const Scope) Error!void {
        const node = &tree.nodes[i];
        const inner = try o.arena.alloc(Scope, scopes.len + 1);
        @memcpy(inner[0..scopes.len], scopes);
        switch (resolve(scopes, node)) {
            .items => |list| for (list) |*item| {
                inner[scopes.len] = .{ .item = item };
                try o.walk(tree, i + 1, node.end, inner);
            },
            .tags => |list| for (list) |*t| {
                inner[scopes.len] = .{ .tag = t };
                try o.walk(tree, i + 1, node.end, inner);
            },
            .meta => |m| {
                inner[scopes.len] = .{ .meta = m };
                try o.walk(tree, i + 1, node.end, inner);
            },
            .flag => |f| if (f) {
                inner[scopes.len] = .flag;
                try o.walk(tree, i + 1, node.end, inner);
            },
            else => unreachable,
        }
    }

    fn partial(o: *Oracle, node: *const parse.Node, scopes: []const Scope) Error!void {
        const source = for (o.sources) |s| {
            if (std.mem.eql(u8, s.name, node.text)) break s;
        } else unreachable;
        if (!node.called()) return o.walk(source.tree, 0, source.tree.len, scopes);
        // Called: its own scopes, the field's record its only one.
        const own = [_]Scope{.{ .meta = resolve(scopes, node).meta }};
        try o.walk(source.tree, 0, source.tree.len, &own);
    }

    fn value(o: *Oracle, node: *const parse.Node, v: Value) !void {
        const pipes = node.pipe_slice();
        if (pipes.len > 0 and pipes[pipes.len - 1].formatter == .plural) {
            const n: i128 = switch (v) {
                .number => |n| n,
                .items => |l| @intCast(l.len),
                .tags => |l| @intCast(l.len),
                else => unreachable,
            };
            try o.out.print(o.arena, "{d} ", .{n});
            const noun = pipes[pipes.len - 1].args[if (n == 1) 0 else 1];
            return o.text(noun, if (node.escape) .escaped else .raw);
        }
        switch (v) {
            .number => |n| try o.out.print(o.arena, "{d}", .{n}),
            .items => |l| try o.out.print(o.arena, "{d}", .{l.len}), // `| len`
            .tags => |l| try o.out.print(o.arena, "{d}", .{l.len}),
            .str => |s| {
                const how: How = if (pipes.len == 0)
                    (if (node.escape) .escaped else .raw)
                else switch (pipes[0].formatter) {
                    .upper => if (node.escape) .upper else .upper_raw,
                    .lower => if (node.escape) .lower else .lower_raw,
                    .url => .url,
                    else => unreachable,
                };
                try o.text(s, how);
            },
            else => unreachable,
        }
    }

    const How = enum { escaped, raw, upper, lower, upper_raw, lower_raw, url };

    fn text(o: *Oracle, s: []const u8, how: How) !void {
        for (s) |c| {
            const cased = switch (how) {
                .upper, .upper_raw => std.ascii.toUpper(c),
                .lower, .lower_raw => std.ascii.toLower(c),
                else => c,
            };
            const escaped = how == .escaped or how == .upper or how == .lower;
            if (how == .url) {
                const mark = std.mem.indexOfScalar(u8, "-._~", c) != null;
                if (std.ascii.isAlphanumeric(c) or mark) {
                    try o.out.append(o.arena, c);
                } else try o.out.print(o.arena, "%{X:0>2}", .{c});
            } else if (escaped and std.mem.indexOfScalar(u8, "&<>\"'", c) != null) {
                try o.out.appendSlice(o.arena, switch (c) {
                    '&' => "&amp;",
                    '<' => "&lt;",
                    '>' => "&gt;",
                    '"' => "&quot;",
                    else => "&#39;",
                });
            } else try o.out.append(o.arena, cased);
        }
    }
};

// ---- the templates -------------------------------------------------------------

const Source = struct { name: []const u8, root: u32, tree: *const parse.Tree };

/// What a scope of the generator holds, to pick reads that type-check.
const Kind = enum { ctx, item, tag, meta, flag };

const Generator = struct {
    random: *Prng,
    out: std.ArrayList(u8) = .empty,
    arena: std.mem.Allocator,
    budget: u32 = 40,

    fn template(g: *Generator) ![]const u8 {
        var kinds: [8]Kind = @splat(.ctx);
        try g.body(&kinds, 1);
        return g.out.items;
    }

    fn body(g: *Generator, kinds: *[8]Kind, len: usize) std.mem.Allocator.Error!void {
        const parts = 1 + g.random.int_less_than(u32, 5);
        for (0..parts) |_| {
            if (g.budget == 0) return;
            g.budget -= 1;
            switch (g.random.int_less_than(u32, 4)) {
                0 => try g.text(),
                1, 2 => try g.read(kinds, len),
                else => if (len < kinds.len) try g.section(kinds, len) else try g.text(),
            }
        }
    }

    fn text(g: *Generator) !void {
        const texts = [_][]const u8{ "<p>", "x & y", "\n", "  ", "é", "\n\t", "</p>\n" };
        try g.out.appendSlice(g.arena, texts[g.random.int_less_than(usize, texts.len)]);
    }

    /// `../` enough to reach a scope of a kind that has fields.
    fn up_to(g: *Generator, kinds: []const Kind, len: usize) ?usize {
        var tries: u32 = 0;
        while (tries < 8) : (tries += 1) {
            const up = g.random.int_less_than(usize, len);
            if (kinds[len - 1 - up] != .flag) return up;
        }
        return null;
    }

    fn prefix(g: *Generator, up: usize) !void {
        for (0..up) |_| try g.out.appendSlice(g.arena, "../");
    }

    fn read(g: *Generator, kinds: *[8]Kind, len: usize) !void {
        const up = g.up_to(kinds, len) orelse return;
        const open = if (g.random.boolean()) "{{ " else "{{{ ";
        const close = if (open.len == 3) " }}" else " }}}";
        try g.out.appendSlice(g.arena, open);
        try g.prefix(up);
        const strs = [_][]const u8{ "", " | upper", " | lower", " | url" };
        const pipe = strs[g.random.int_less_than(usize, strs.len)];
        const plural = " | plural \"dish\" \"<dishes>\"";
        const choice = g.random.int_less_than(u32, 3);
        try g.out.appendSlice(g.arena, switch (kinds[len - 1 - up]) {
            .ctx => switch (choice) {
                0 => try std.fmt.allocPrint(g.arena, "title{s}", .{pipe}),
                1 => if (g.random.boolean()) "delta" else "count" ++ plural,
                else => if (g.random.boolean()) "items | len" else "meta.label",
            },
            .item => switch (choice) {
                0 => try std.fmt.allocPrint(g.arena, "name{s}", .{pipe}),
                1 => "price",
                else => "tags | len" ++ plural,
            },
            .tag => "label",
            .meta => if (choice == 0) "n" else "label",
            .flag => unreachable,
        });
        try g.out.appendSlice(g.arena, close);
    }

    fn section(g: *Generator, kinds: *[8]Kind, len: usize) !void {
        const up = g.up_to(kinds, len) orelse return;
        const at = kinds[len - 1 - up];
        const Choice = struct { tag: []const u8, name: []const u8, opens: ?Kind };
        const choices: []const Choice = switch (at) {
            .ctx => &.{
                .{ .tag = "#", .name = "items", .opens = .item },
                .{ .tag = "^", .name = "items", .opens = null },
                .{ .tag = "#", .name = "open", .opens = .flag },
                .{ .tag = "^", .name = "open", .opens = null },
                .{ .tag = "?", .name = "open", .opens = null },
                .{ .tag = "#", .name = "meta", .opens = .meta },
            },
            .item => &.{
                .{ .tag = "#", .name = "tags", .opens = .tag },
                .{ .tag = "?", .name = "hot", .opens = null },
                .{ .tag = "^", .name = "tags", .opens = null },
            },
            // Badge inlined where its fields are this scope's.
            .meta => return if (up == 0 and g.random.boolean())
                g.out.appendSlice(g.arena, "{{> Badge}}")
            else
                g.read(kinds, len),
            .tag => return g.read(kinds, len),
            .flag => unreachable,
        };
        var ups: std.ArrayList(u8) = .empty;
        for (0..up) |_| try ups.appendSlice(g.arena, "../");
        if (at == .ctx and g.random.int_less_than(u32, 4) == 0) {
            // Badge called, over `meta`.
            return g.out.print(g.arena, "{{{{> Badge {s}meta}}}}", .{ups.items});
        }
        const c = choices[g.random.int_less_than(usize, choices.len)];
        const path = try std.fmt.allocPrint(g.arena, "{s}{s}", .{ ups.items, c.name });
        try g.out.print(g.arena, "{{{{{s}{s}}}}}", .{ c.tag, path });
        var inner = kinds.*;
        var inner_len = len;
        if (c.opens) |k| {
            inner[len] = k;
            inner_len += 1;
        }
        try g.body(&inner, inner_len);
        try g.out.print(g.arena, "{{{{/{s}}}}}", .{path});
    }
};

// ---- the test --------------------------------------------------------------------

/// Roc's allocations, from the arena `env` points at (the page is read,
/// never freed: the arena goes with the seed).
fn host_alloc(host: *abi.RocHost, size: usize, alignment: usize) callconv(.c) *anyopaque {
    assert(alignment <= 16);
    const arena: *const std.mem.Allocator = @ptrCast(@alignCast(host.env));
    const memory = arena.alignedAlloc(u8, .@"16", size) catch @panic("out of memory");
    return memory.ptr;
}

fn host_dealloc(_: *abi.RocHost, _: *anyopaque, _: usize) callconv(.c) void {}

fn host_realloc(_: *abi.RocHost, _: *anyopaque, _: usize, _: usize) callconv(.c) *anyopaque {
    @panic("not used");
}

fn host_say(_: *abi.RocHost, _: [*]const u8, _: usize) callconv(.c) void {}

test "templates: compiled and run by the VM, as a plain walk of the tree says" {
    var no_arena: u8 = 0;
    var host: abi.RocHost = .{
        .env = &no_arena, // each seed's arena, below
        .roc_alloc = host_alloc,
        .roc_dealloc = host_dealloc,
        .roc_realloc = host_realloc,
        .roc_dbg = host_say,
        .roc_expect_failed = host_say,
        .roc_crashed = host_say,
    };
    const seeds = 3000;
    var checked: u32 = 0;
    for (0..seeds) |seed| {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        host.env = @ptrCast(@constCast(&arena));
        checked += try check_seed(arena, seed, &host);
    }
    try testing.expectEqual(4 * seeds, checked);
}

fn check_seed(arena: std.mem.Allocator, seed: u64, host: *abi.RocHost) !u32 {
    var prng: Prng = .init(seed);
    const random = &prng;
    var generator: Generator = .{ .random = random, .arena = arena };
    const page = try generator.template();
    const sources = [_]Source{
        .{
            .name = "Badge",
            .root = T.meta,
            .tree = try parsed(arena, "<b>{{ label }}={{ n }}</b>"),
        },
        .{ .name = "Page", .root = T.ctx, .tree = try parsed(arena, page) },
    };
    var compiled: [sources.len]bytecode.Template = undefined;
    for (sources, &compiled) |s, *c| c.* = .{ .name = s.name, .tree = s.tree, .root = s.root };
    var chunks: [sources.len]bytecode.Chunk = undefined;
    for (&chunks, 0..) |*chunk, index| {
        var diagnostic: bytecode.Diagnostic = .{};
        chunk.* = bytecode.compile(arena, &layouts, &compiled, index, &diagnostic) catch |err| {
            std.debug.print("seed {d}: {t} {s} `{s}`\n{s}\n", .{
                seed, err, diagnostic.message, diagnostic.subject, page,
            });
            return err;
        };
    }
    const program = try bytecode.assemble(arena, &chunks);
    const text = try arena.alloc(u8, program.text.len + templates.slack);
    @memcpy(text[0..program.text.len], program.text);
    const data: templates.Data = .{
        .code = program.code,
        .text = text[0..program.text.len],
        .layouts = 0,
    };
    var runs: u32 = 0;
    for (0..4) |_| {
        const ctx = try random_ctx(random, arena);
        const got = templates.render_from(data, 1, @ptrCast(ctx), host);
        var oracle: Oracle = .{ .arena = arena, .sources = &sources };
        const scopes = [_]Scope{.{ .ctx = ctx }};
        try oracle.walk(sources[1].tree, 0, sources[1].tree.len, &scopes);
        testing.expectEqualStrings(oracle.out.items, got.items()) catch |err| {
            std.debug.print("seed {d}, the template:\n{s}\n", .{ seed, page });
            return err;
        };
        runs += 1;
    }
    return runs;
}

fn parsed(arena: std.mem.Allocator, source: []const u8) !*const parse.Tree {
    const tree = try arena.create(parse.Tree);
    var diagnostic: parse.Diagnostic = .{};
    parse.parse(source, tree, &diagnostic) catch |err| {
        const d = diagnostic;
        std.debug.print("{s} `{s}` in:\n{s}\n", .{ d.message, d.subject, source });
        return err;
    };
    return tree;
}
