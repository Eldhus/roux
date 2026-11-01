//! An inferred page's holes of Roc, typed by Roc. A field only a hole of
//! Roc reads has no type a tag gives: in `{{ Fmt.kr(item.price) }}`,
//! `price` is what `Fmt.kr` takes. So each such hole is asked of Roc as a
//! function annotated with the record of what it reads, closed, its leaves
//! left to Roc: `p0 : { item : { price : _ } } -> Str`. A throwaway
//! platform provides every such function, and glue lays out each one's
//! argument, as roux's contracts are laid out: the leaves come back
//! concrete (`price` a `U32`), or glue names the hole whose type is generic
//! (`item.price.to_str()`, any number), whose page then declares its `Ctx`.
//!
//! The probe sits beside the templates, where `import Fmt` resolves, and is
//! removed after. Being its own platform, it cannot import the app's
//! platform's modules: a hole that uses `pf.Url` is typed only by a
//! declared `Ctx`. Roc's answer is kept by the probe's text, so an edit
//! that keeps the holes asks nothing.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");
const hole = @import("hole.zig");
const contract_ = @import("contract.zig");
const layout = @import("layout.zig");
const cache_ = @import("cache.zig");
const generate = @import("generate.zig");
const Kept = cache_.Kept;
const Contract = contract_.Contract;
const Error = generate.Error;

/// A pending hole of a page, asked of Roc as `p<its index>`.
const Asked = struct { page: usize, pending: contract_.Pending };

const platform = "RouxGlue";
const answer_bytes_max = 16 << 20;

/// Types the pending holes of every page no other template includes (a
/// partial's are typed by its includer), and makes those pages' contracts
/// again with Roc's answers.
pub fn answer(
    gpa: Allocator,
    io: Io,
    options: generate.Options,
    cache: *cache_.Cache,
    kept: []const *Kept,
    templates: []contract_.Template,
    errors: *Io.Writer,
) Error!void {
    var asked: std.ArrayList(Asked) = .empty;
    for (kept, 0..) |k, page| {
        if (included(templates, k.name)) continue;
        for (k.contract.?.pending_slice()) |p| {
            try asked.append(gpa, .{ .page = page, .pending = p });
        }
    }
    if (asked.items.len == 0) return;
    const text = try probe_text(gpa, templates, asked.items);
    const key = std.hash.Wyhash.hash(0, text);
    if (cache.probe_key != key) {
        const said = try ask(gpa, io, options, text, asked.items, templates, errors);
        cache.gpa.free(cache.probe_answer);
        cache.probe_answer = try cache.gpa.dupe(u8, said);
        cache.probe_key = key;
    }
    const types = try gpa.create(Contract);
    types.* = .{};
    const roots = try gpa.alloc(?u16, asked.items.len);
    @memset(roots, null);
    read_answers(gpa, cache.probe_answer, types, roots) catch |err| {
        cache.probe_key = 0;
        try errors.print("roux: glue's layouts of the holes' types could not be read ({t})\n", .{
            err,
        });
        return error.Invalid;
    };
    for (asked.items, roots) |a, root| {
        if (root == null) return refuse(errors, templates, a, generic_message);
    }
    // The answer's names are slices of its text, which the next probe
    // replaces: the contracts made from it hold the cache's own copies.
    const names = cache.probe_names.allocator();
    for (types.fields[0..types.fields_len]) |*f| f.name = try names.dupe(u8, f.name);
    for (types.types[0..types.types_len]) |*t| t.name = try names.dupe(u8, t.name);
    for (kept, 0..) |_, page| {
        try answer_page(gpa, cache, kept, templates, asked.items, roots, page, types, errors);
    }
}

const generic_message = "reads a value whose type Roc cannot tell from the hole " ++
    "(it is generic, like a number's `.to_str()`): declare `{{% Ctx : ... %}}`";

/// Page `page`'s contract, made again with its answers, if it was asked.
fn answer_page(
    gpa: Allocator,
    cache: *cache_.Cache,
    kept: []const *Kept,
    templates: []contract_.Template,
    asked: []const Asked,
    roots: []const ?u16,
    page: usize,
    types: *const Contract,
    errors: *Io.Writer,
) Error!void {
    var mine: std.ArrayList(?u16) = .empty;
    for (asked, roots) |a, root| if (a.page == page) try mine.append(gpa, root);
    if (mine.items.len == 0) return;
    const answers: contract_.Answers = .{ .types = types, .roots = mine.items };
    const ordered = try gpa.dupe(contract_.Template, templates);
    std.mem.swap(contract_.Template, &ordered[0], &ordered[page]);
    const contract = try cache_.create_unfilled(cache.gpa, Contract);
    errdefer cache_.destroy_unfilled(cache.gpa, contract);
    var diagnostic: contract_.Diagnostic = .{};
    contract_.of_answered(contract, ordered, &answers, &diagnostic) catch {
        const source = for (templates) |t| {
            if (std.mem.eql(u8, t.name, diagnostic.template)) break t.source;
        } else ordered[0].source;
        try generate.report(errors, source, diagnostic);
        return error.Invalid;
    };
    assert(contract.pending_len == 0);
    if (kept[page].contract) |old| try cache.retire(.{ .contract = old });
    kept[page].contract = contract;
    templates[page].contract = contract;
}

/// Whether another template includes `name`: a partial, typed where it is.
fn included(templates: []const contract_.Template, name: []const u8) bool {
    for (templates) |t| {
        for (t.tree.slice()) |node| {
            if (node.kind == .partial and std.mem.eql(u8, node.text, name)) return true;
        }
    }
    return false;
}

fn template_of(templates: []const contract_.Template, name: []const u8) contract_.Template {
    for (templates) |t| if (std.mem.eql(u8, t.name, name)) return t;
    unreachable; // the walk met the hole in it
}

/// The probe's source: a platform providing each hole as a function, under
/// every template's imports but the platform's (`pf.`), which it has not.
fn probe_text(
    gpa: Allocator,
    templates: []const contract_.Template,
    asked: []const Asked,
) Error![]const u8 {
    assert(asked.len > 0);
    var out: Io.Writer.Allocating = .init(gpa);
    const writer = &out.writer;
    try writer.writeAll("platform \"probe\"\n\trequires {} { main! : () => {} }\n" ++
        "\texposes []\n\tpackages {}\n\tprovides {");
    for (0..asked.len) |k| try writer.print(" \"probe_{d}\": p{d},", .{ k, k });
    try writer.writeAll(" }\n\ttargets: { inputs_dir: \"targets/\", " ++
        "x64musl: { inputs: [app] } }\n\n");
    var imports: std.ArrayList([]const u8) = .empty;
    for (templates) |t| for (t.contract.?.import_slice()) |name| {
        if (std.mem.startsWith(u8, name, "pf.")) continue;
        for (imports.items) |seen| {
            if (std.mem.eql(u8, seen, name)) break;
        } else try imports.append(gpa, name);
    };
    for (imports.items) |name| try writer.print("import {s}\n", .{name});
    for (asked, 0..) |a, k| {
        const t = template_of(templates, a.pending.template);
        try write_probe(gpa, writer, t.tree.nodes[a.pending.node].expression, k);
    }
    assert(out.written().len > 0);
    return out.written();
}

/// `p3 : { item : { price : _ } } -> Str`, then `p3 = |{ item }| (…)`.
fn write_probe(gpa: Allocator, writer: *Io.Writer, expression: []const u8, k: usize) Error!void {
    var diagnostic: parse.Diagnostic = .{};
    const parsed = hole.of(expression, &diagnostic) catch unreachable; // parse.zig checked it
    const shape = try gpa.create(Contract);
    shape.* = .{};
    shape.root = try contract_.new_type(shape, .record, 0);
    // Shorter paths first: a name read whole covers its fields' reads.
    var length: u8 = 1;
    while (length <= parse.path_max) : (length += 1) {
        for (parsed.read_slice()) |*read| {
            if (read.path_len == length) try add_path(shape, read.path_slice());
        }
    }
    try writer.print("\np{d} : ", .{k});
    try write_shape(shape, shape.root, writer);
    try writer.print(" -> Str\np{d} = |{{", .{k});
    var fields = shape.fields_of(shape.root);
    var count: usize = 0;
    while (fields.next()) |f| : (count += 1) {
        try writer.print("{s} {s}", .{ if (count == 0) "" else ",", f.name });
    }
    try writer.print("{s}}}| ({s})\n", .{ if (count == 0) "" else " ", expression });
}

/// A read's path into the probe's record: records down to an unknown leaf,
/// unless a shorter read already reads it whole.
fn add_path(shape: *Contract, path: []const []const u8) Error!void {
    var at = shape.root;
    for (path, 1..) |segment, length| {
        if (shape.get(at).kind != .record) return; // read whole already
        at = shape.field(at, segment) orelse blk: {
            const kind: contract_.Kind = if (length == path.len) .unknown else .record;
            const child = try contract_.new_type(shape, kind, 0);
            try contract_.new_field(shape, at, segment, child);
            break :blk child;
        };
    }
}

fn write_shape(shape: *const Contract, index: u16, writer: *Io.Writer) Io.Writer.Error!void {
    const type_ = shape.get(index);
    if (type_.kind != .record) return writer.writeAll("_");
    var fields = shape.fields_of(index);
    var count: usize = 0;
    while (fields.next()) |f| : (count += 1) {
        try writer.print("{s}{s} : ", .{ if (count == 0) "{ " else ", ", f.name });
        try write_shape(shape, f.type, writer);
    }
    try writer.writeAll(if (count == 0) "{}" else " }");
}

/// Writes the probe beside the templates, has glue lay it out, removes it:
/// glue's layouts, or the hole it refused, reported.
fn ask(
    gpa: Allocator,
    io: Io,
    options: generate.Options,
    text: []const u8,
    asked: []const Asked,
    templates: []const contract_.Template,
    errors: *Io.Writer,
) Error![]const u8 {
    const cwd = Io.Dir.cwd();
    var app = try cwd.openDir(io, options.app, .{});
    defer app.close(io);
    const file = platform ++ ".roc";
    try app.writeFile(io, .{ .sub_path = file, .data = text });
    defer app.deleteFile(io, file) catch {};
    const dir = try std.fmt.allocPrint(gpa, "{s}/probe", .{options.build});
    const out = try std.fmt.allocPrint(gpa, "{s}/out", .{dir});
    try cwd.createDirPath(io, out);
    const spec = try std.fmt.allocPrint(gpa, "{s}/Layout.roc", .{dir});
    try cwd.writeFile(io, .{ .sub_path = spec, .data = layout.spec });
    const spec_abs = cwd.realPathFileAlloc(io, spec, gpa) catch
        return refuse_tool(errors, "the probe's glue spec has no path", spec);
    const out_abs = cwd.realPathFileAlloc(io, out, gpa) catch
        return refuse_tool(errors, "the probe's glue output has no path", out);
    const app_dir = std.fs.path.dirname(options.app) orelse ".";
    const ran = std.process.run(gpa, io, .{
        .argv = &.{ options.roc, "glue", spec_abs, out_abs, generate.templates_dir ++ "/" ++ file },
        .cwd = .{ .path = app_dir },
        .stdout_limit = .limited(answer_bytes_max),
        .stderr_limit = .limited(answer_bytes_max),
    }) catch return refuse_tool(errors, "roc glue could not be run", "");
    if (!ran.term.success()) return refused(gpa, errors, templates, asked, ran.stderr);
    const zon = try std.fmt.allocPrint(gpa, "{s}/layouts.zon", .{out});
    return cwd.readFileAlloc(io, zon, gpa, .limited(answer_bytes_max));
}

/// Glue refused the probe. A generic hole it names in its own words, which
/// roux matches (the probe's names are roux's); anything else is Roc's
/// report on the probe, shown whole, which quotes the hole.
fn refused(
    gpa: Allocator,
    errors: *Io.Writer,
    templates: []const contract_.Template,
    asked: []const Asked,
    said: []const u8,
) Error {
    if (std.mem.indexOf(u8, said, "unresolved type variable") != null) {
        for (asked, 0..) |a, k| {
            const named = try std.fmt.allocPrint(gpa, "signature of `p{d}`", .{k});
            if (std.mem.indexOf(u8, said, named) != null) {
                return refuse(errors, templates, a, generic_message);
            }
        }
    }
    try errors.print("roux: Roc refused a hole of Roc, typing a page without `Ctx` " ++
        "(as {s}.roc, below):\n{s}", .{ platform, said });
    if (imports_platform(templates)) {
        try errors.writeAll("roux: a hole that uses a platform module (`pf.Url`) is typed " ++
            "only by a declared `{{% Ctx : ... %}}`\n");
    }
    return error.Invalid;
}

fn imports_platform(templates: []const contract_.Template) bool {
    for (templates) |t| for (t.contract.?.import_slice()) |name| {
        if (std.mem.startsWith(u8, name, "pf.")) return true;
    };
    return false;
}

fn refuse(
    errors: *Io.Writer,
    templates: []const contract_.Template,
    a: Asked,
    message: []const u8,
) Error {
    const t = template_of(templates, a.pending.template);
    try generate.report(errors, t.source, .{
        .template = t.name,
        .offset = t.tree.nodes[a.pending.node].offset,
        .message = message,
        .subject = "",
    });
    return error.Invalid;
}

fn refuse_tool(errors: *Io.Writer, message: []const u8, said: []const u8) Error {
    try errors.print("roux: {s}\n{s}", .{ message, said });
    return error.Invalid;
}

/// Each probe's argument type, from glue's layouts, into `types`.
fn read_answers(gpa: Allocator, text: []const u8, types: *Contract, roots: []?u16) !void {
    const source = try gpa.dupeSentinel(u8, text, 0);
    const layouts = try layout.parse(gpa, source);
    for (layouts.contracts) |c| {
        if (!std.mem.startsWith(u8, c.name, "p")) continue;
        const k = std.fmt.parseInt(usize, c.name[1..], 10) catch continue;
        if (k >= roots.len) return error.Invalid;
        roots[k] = try type_of_layout(types, &layouts, c.type, 0);
    }
}

/// A layout's type as a contract's: glue lays out only concrete types.
fn type_of_layout(types: *Contract, layouts: *const layout.Layouts, index: u32, depth: u8) !u16 {
    if (depth == 32) return error.Invalid;
    const type_ = layouts.get(index);
    const int_name: ?[]const u8 = switch (type_.kind) {
        .u8 => "U8",
        .u16 => "U16",
        .u32 => "U32",
        .u64 => "U64",
        .i8 => "I8",
        .i16 => "I16",
        .i32 => "I32",
        .i64 => "I64",
        else => null,
    };
    if (int_name) |name| {
        const at = try contract_.new_type(types, .int, 0);
        types.types[at].name = name;
        return at;
    }
    switch (type_.kind) {
        .str => return contract_.new_type(types, .str, 0),
        .bool => return contract_.new_type(types, .bool, 0),
        .list => {
            const at = try contract_.new_type(types, .list, 0);
            const element = try type_of_layout(types, layouts, type_.element, depth + 1);
            types.types[at].element = element;
            return at;
        },
        .record => {
            const at = try contract_.new_type(types, .record, 0);
            for (type_.fields) |f| {
                const child = try type_of_layout(types, layouts, f.type, depth + 1);
                try contract_.new_field(types, at, f.name, child);
            }
            return at;
        },
        // A float, a `Dec`, a tag union: a layout does not name it.
        else => return error.Invalid,
    }
}

const testing = std.testing;

test "probe: each hole a function of the record it reads, closed, its leaves Roc's" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const page = "{{% import Fmt\nimport pf.Url %}}{{#items |item|}}" ++
        "{{ Fmt.kr(item.price) }}{{ Fmt.both(item.name, item) }}{{ \"${title}\" }}{{/items}}";
    var tree: parse.Tree = .{};
    var d: parse.Diagnostic = .{};
    try parse.parse(page, &tree, &d);
    const contract = try arena.create(Contract);
    var diagnostic: contract_.Diagnostic = .{};
    const templates = [_]contract_.Template{.{ .name = "Page", .source = page, .tree = &tree }};
    try contract_.of(contract, &templates, &diagnostic);
    try testing.expectEqual(@as(u16, 3), contract.pending_len);
    var with_contract = templates;
    with_contract[0].contract = contract;
    var asked: [3]Asked = undefined;
    for (contract.pending_slice(), &asked) |p, *a| a.* = .{ .page = 0, .pending = p };
    const text = try probe_text(arena, &with_contract, &asked);
    // The platform's own modules are not the probe's to import.
    try testing.expect(std.mem.indexOf(u8, text, "import Fmt\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "pf.Url") == null);
    const expected = [_][]const u8{
        "p0 : { item : { price : _ } } -> Str\np0 = |{ item }| (Fmt.kr(item.price))\n",
        // `item` read whole covers `item.name`.
        "p1 : { item : _ } -> Str\np1 = |{ item }| (Fmt.both(item.name, item))\n",
        "p2 : { title : _ } -> Str\np2 = |{ title }| (\"${title}\")\n",
    };
    for (expected) |definition| {
        errdefer std.debug.print("probe:\n{s}\n", .{text});
        try testing.expect(std.mem.indexOf(u8, text, definition) != null);
    }
}
