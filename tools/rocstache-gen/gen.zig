//! Orchestrates parse -> infer -> emit for one template plus its partials.

const std = @import("std");
const Allocator = std.mem.Allocator;
pub const mustache = @import("mustache.zig");
pub const formatters = @import("formatters.zig");
pub const pragma = @import("pragma.zig");
pub const infer = @import("infer.zig");
pub const emit = @import("emit.zig");

/// Supplies partial sources by module name (`Header` -> contents of
/// `Header.rocstache`), or null when there is no such file.
pub const Loader = struct {
    ctx: *anyopaque,
    loadFn: *const fn (ctx: *anyopaque, name: []const u8) anyerror!?[]const u8,

    pub fn load(l: Loader, name: []const u8) anyerror!?[]const u8 {
        return l.loadFn(l.ctx, name);
    }
};

pub const Options = struct {
    source_name: []const u8,
    module_name: []const u8,
};

pub const Result = struct {
    roc: []const u8,
    /// Every partial module name reached (transitively), in discovery order.
    partials_used: []const []const u8,
};

const Partial = struct {
    name: []const u8,
    tpl: mustache.Template,
    root: u32,
    done: bool,
};

const Gen = struct {
    arena: Allocator,
    loader: Loader,
    diag: *mustache.Diagnostic,
    /// The shared root context shape (`@name` fields).
    groot: u32 = 0,
    partials: std.ArrayList(Partial) = .empty,

    fn analyzePartial(self: *Gen, inf: *infer.Infer, name: []const u8, offset: u32) anyerror!u32 {
        for (self.partials.items) |p| if (std.mem.eql(u8, p.name, name)) {
            if (!p.done) {
                self.diag.* = .{ .offset = offset, .message = "partials form a cycle" };
                return error.TypeError;
            }
            return p.root;
        };
        const src = (try self.loader.load(name)) orelse {
            self.diag.* = .{ .offset = offset, .message = "partial template file not found (expected <Name>.rocstache next to the template)" };
            return error.TypeError;
        };
        const idx = self.partials.items.len;
        try self.partials.append(self.arena, .{ .name = name, .tpl = undefined, .root = 0, .done = false });
        var local: mustache.Diagnostic = .{};
        const tpl = mustache.parse(self.arena, src, &local) catch |err| {
            self.diag.* = .{ .offset = local.offset, .message = local.message, .file = name };
            return err;
        };
        self.partials.items[idx].tpl = tpl;
        checkBlock(self.arena, &self.partials.items[idx].tpl, name, self.diag) catch |err| {
            self.diag.file = name;
            return err;
        };
        const root = try inf.new(.record);
        self.partials.items[idx].root = root;
        var saved = self.diag.*;
        // A copy: a partial used inside this one appends to `partials`, which
        // may move the list (the template's own slices live in the arena).
        const own = self.partials.items[idx].tpl;
        infer.inferTemplate(inf, &own, root, self.groot, self, partialRoot) catch |err| {
            if (self.diag.file.len == 0) self.diag.file = name;
            return err;
        };
        saved = self.diag.*;
        self.partials.items[idx].done = true;
        return root;
    }

    fn partialRoot(self: *Gen, inf: *infer.Infer, name: []const u8, offset: u32) anyerror!u32 {
        const root = try self.analyzePartial(inf, name, offset);
        return inf.clone(root);
    }
};

/// Everything known about a template after parsing and inference; what the
/// emitter and the language server work from.
pub const Analysis = struct {
    tpl: mustache.Template,
    inf: *infer.Infer,
    /// The template's context shape (`Ctx`).
    root: u32,
    /// The root context (`@name` fields), shared by the template and every
    /// partial it uses; a page passes its context as the root.
    groot: u32,
    /// Whether the template, or a partial it uses, reads `@` fields.
    uses_root: bool,
    /// Every partial reached (transitively), in discovery order, with its
    /// own context shape.
    partials: []const emit.PartialInfo,
    /// What the template's `{{% %}}` block declares.
    pragma: pragma.Pragma,
};

/// Names the generated module defines itself; a block that defines one
/// would shadow or clash with the generated code.
const reserved = [_][]const u8{ "render", "render_in", "render_into", "context", "root", "out", "item" };

/// Checks a template's `{{% %}}` block against the generated code:
///
/// - every bare formatter name must come from the block: exposed by an
///   import, or defined there (a qualified name such as `Str.trim` is roc's
///   to resolve). Reported at the tag, rather than by roc in the generated
///   module;
/// - the block must not define a name the generated code uses;
/// - an imported module must not go by the name of a partial the template
///   includes, or of the template itself (`import ../db/Tags as TagRows`).
fn checkBlock(arena: Allocator, tpl: *const mustache.Template, module_name: []const u8, diag: *mustache.Diagnostic) !void {
    const p = try pragma.parse(arena, tpl.pragma);
    for (p.locals) |name| {
        const clash = for (reserved) |r| {
            if (std.mem.eql(u8, name, r)) break true;
        } else std.mem.startsWith(u8, name, "item") and name.len > 4 and std.ascii.isDigit(name[4]);
        if (clash) {
            diag.* = .{ .offset = tpl.pragma_offset + @as(u32, @intCast(try pragma.definitionOffset(arena, tpl.pragma, name))), .message = try std.fmt.allocPrint(arena, "`{s}` is a name the generated module uses (render, render_in, render_into, context, root, out, item...); call this definition something else", .{name}) };
            return error.TypeError;
        }
    }
    for (p.imports) |imp| {
        var taken: ?[]const u8 = null;
        if (module_name.len != 0 and std.mem.eql(u8, imp.name, module_name)) taken = "this template's own module";
        for (tpl.partials) |partial| if (std.mem.eql(u8, imp.name, partial)) {
            taken = "a partial this template includes";
        };
        if (taken) |what| {
            diag.* = .{ .offset = tpl.pragma_offset, .message = try std.fmt.allocPrint(arena, "`import {s}` goes by `{s}`, which is also {s}; give it another name: `import {s} as {s}Rows`", .{ imp.module, imp.name, what, imp.module, imp.name }) };
            return error.TypeError;
        }
    }
    for (tpl.fmts) |f| {
        if (std.mem.indexOfScalar(u8, f.name, '.') != null or p.defines(f.name)) continue;
        const builtin = (try formatters.parse(arena, formatters.builtin_src)).find(f.name) != null;
        diag.* = .{ .offset = f.offset, .message = if (builtin)
            try std.fmt.allocPrint(arena, "`{s}` is not imported: add `import pf.Rocstache exposing [{s}]` to the `{{{{% %}}}}` block at the top", .{ f.name, f.name })
        else
            try std.fmt.allocPrint(arena, "`{s}` is not defined here: define it in the `{{{{% %}}}}` block at the top, or import it (`import ../Formatters exposing [{s}]`)", .{ f.name, f.name }) };
        return error.TypeError;
    }
}

/// Whether a template reads `@` fields itself or through its partials.
fn usesRoot(tpl: *const mustache.Template, partials: []const emit.PartialInfo) bool {
    for (tpl.exprs) |e| if (mustache.isRootPath(tpl.path(e.path_start, e.path_len))) return true;
    for (tpl.args) |a| if (a.kind == .path and mustache.isRootPath(tpl.path(a.path_start, a.path_len))) return true;
    for (tpl.partials) |name| for (partials) |p| if (std.mem.eql(u8, p.name, name) and p.uses_root) return true;
    return false;
}

pub fn analyze(
    arena: Allocator,
    src: []const u8,
    module_name: []const u8,
    loader: Loader,
    diag: *mustache.Diagnostic,
) anyerror!Analysis {
    const tpl = try mustache.parse(arena, src, diag);
    try checkBlock(arena, &tpl, module_name, diag);
    const inf = try arena.create(infer.Infer);
    inf.* = infer.Infer.init(arena, diag);
    const root = try inf.new(.record);
    const groot = try inf.new(.record);
    var gen = Gen{ .arena = arena, .loader = loader, .diag = diag, .groot = groot };
    try infer.inferTemplate(inf, &tpl, root, groot, &gen, Gen.partialRoot);

    // A partial needs the root when it reads `@` itself or includes a partial
    // that needs it, however deep: iterate to a fixed point (a partial is
    // registered before the partials it includes, so one pass is not enough).
    var infos: std.ArrayList(emit.PartialInfo) = .empty;
    for (gen.partials.items) |p| try infos.append(arena, .{ .name = p.name, .root = p.root });
    var changed = true;
    while (changed) {
        changed = false;
        for (gen.partials.items, 0..) |p, i| {
            if (!infos.items[i].uses_root and usesRoot(&p.tpl, infos.items)) {
                infos.items[i].uses_root = true;
                changed = true;
            }
        }
    }
    return .{ .tpl = tpl, .inf = inf, .root = root, .groot = groot, .uses_root = usesRoot(&tpl, infos.items), .partials = infos.items, .pragma = try pragma.parse(arena, tpl.pragma) };
}

pub fn generate(
    arena: Allocator,
    src: []const u8,
    loader: Loader,
    opts: Options,
    diag: *mustache.Diagnostic,
) anyerror!Result {
    const a = try analyze(arena, src, opts.module_name, loader, diag);
    var names: std.ArrayList([]const u8) = .empty;
    for (a.partials) |p| try names.append(arena, p.name);

    var aw: std.Io.Writer.Allocating = try .initCapacity(arena, src.len * 2 + 512);
    try emit.emit(arena, &aw.writer, a.inf, &a.tpl, a.root, a.groot, a.uses_root, a.partials, .{
        .module_name = opts.module_name,
        .source_name = opts.source_name,
        .pragma = a.pragma,
    });
    return .{ .roc = aw.written(), .partials_used = names.items };
}

// ---------------------------------------------------------------- tests

const TestFiles = struct {
    files: []const struct { []const u8, []const u8 },
    fn load(ctx: *anyopaque, name: []const u8) anyerror!?[]const u8 {
        const self: *TestFiles = @ptrCast(@alignCast(ctx));
        for (self.files) |f| if (std.mem.eql(u8, f[0], name)) return f[1];
        return null;
    }
};

fn genTest(arena: Allocator, src: []const u8, files: *TestFiles) ![]const u8 {
    var diag: mustache.Diagnostic = .{};
    const r = generate(arena, src, .{ .ctx = files, .loadFn = TestFiles.load }, .{
        .source_name = "T.rocstache",
        .module_name = "T",
    }, &diag) catch |err| {
        std.debug.print("gen error: {s} at {d} in {s}\n", .{ diag.message, diag.offset, diag.file });
        return err;
    };
    return r.roc;
}

fn has(out: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, out, needle) != null;
}

test "root paths: partials take the root, pages pass their context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const post_src = "{{%\nstamp = |at, _now| at\n%}}\n<p>{{ body }} {{ at | stamp @now }}</p>";
    var files = TestFiles{ .files = &.{.{ "Post", post_src }} };
    const out = try genTest(arena.allocator(), "{{#posts}}{{> Post}}{{/posts}}", &files);
    try std.testing.expect(has(out, "$out = Post.render_into($out, item, root)"));
    try std.testing.expect(has(out, "render = |context| render_into(Str.with_capacity("));
    try std.testing.expect(has(out, ", context, context)\n"));
    try std.testing.expect(has(out, "render_in = |context, root| render_into("));
    // two hops: Outer -> Mid -> Leaf; only Leaf reads `@`
    var deep = TestFiles{ .files = &.{
        .{ "Leaf", "{{%\nstamp = |at, _now| at\n%}}<i>{{ at | stamp @now }}</i>" },
        .{ "Mid", "{{#items}}{{> Leaf}}{{/items}}" },
    } };
    const outer = try genTest(arena.allocator(), "<h1>{{ title }}</h1>{{> Mid}}", &deep);
    try std.testing.expect(has(outer, "Mid.render_into($out, context, root)"));
    // the partial on its own: the root is a separate argument
    const post = try genTest(arena.allocator(), post_src, &files);
    try std.testing.expect(has(post, "render_into = |out, context, root| {"));
    try std.testing.expect(has(post, "stamp(context.at, root.now).to_str()"));
    try std.testing.expect(has(post, "\nstamp = |at, _now| at\n"));
}

test "end to end codegen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var files = TestFiles{ .files = &.{} };
    const out = try genTest(arena.allocator(),
        \\{{%
        \\import pf.Rocstache exposing [upper]
        \\
        \\money : I64 -> Str
        \\money = |cents| "$${cents.to_str()}"
        \\%}}
        \\<h1>{{title}}</h1>
        \\{{#items}}
        \\  <li>{{ name | upper }} {{{raw}}} {{ price | money }} {{ count }}</li>
        \\{{/items}}
        \\{{^items}}
        \\  <p>none</p>
        \\{{/items}}
        \\{{#admin}}<b>admin</b>{{/admin}}
        \\{{?paid}}<i>{{ title }} paid</i>{{/paid}}
        \\{{#items}}{{?../paid}}{{ ../title }}:{{ name | Str.trim }}{{/paid}}{{/items}}
    , &files);
    const expected =
        \\# Generated by rocstache-gen from T.rocstache. DO NOT EDIT.
        \\import pf.Rocstache
        \\
        \\# ---- {{% %}} block of T.rocstache, from line 2
        \\import pf.Rocstache exposing [upper]
        \\
        \\money : I64 -> Str
        \\money = |cents| "$${cents.to_str()}"
        \\# ----
        \\
        \\## Compiled from `T.rocstache`. `T.render(context)` is the HTML, with every
        \\## `{{ value }}` made text by its `to_str` and HTML-escaped. The context is any
        \\## record with the fields the template reads.
        \\T :: [].{
        \\
        \\    render = |context| render_into(Str.with_capacity(2048), context)
        \\
        \\    ## `render`, appending to `out`: how a template that includes this one renders it.
        \\    render_into = |out, context| {
        \\        var $out = out
        \\        $out = $out.concat("<h1>")
        \\        $out = $out.concat(Rocstache.escape(context.title.to_str())) # T.rocstache:7
        \\        $out = $out.concat("</h1>\n")
        \\        for item in context.items { # T.rocstache:8
        \\            $out = $out.concat("  <li>")
        \\            $out = $out.concat(Rocstache.escape(upper(item.name).to_str())) # T.rocstache:9
        \\            $out = $out.concat(" ")
        \\            $out = $out.concat(item.raw.to_str()) # T.rocstache:9
        \\            $out = $out.concat(" ")
        \\            $out = $out.concat(Rocstache.escape(money(item.price).to_str())) # T.rocstache:9
        \\            $out = $out.concat(" ")
        \\            $out = $out.concat(Rocstache.escape(item.count.to_str())) # T.rocstache:9
        \\            $out = $out.concat("</li>\n")
        \\        }
        \\        if context.items.is_empty() { # T.rocstache:11
        \\            $out = $out.concat("  <p>none</p>\n")
        \\        }
        \\        if context.admin { # T.rocstache:14
        \\            $out = $out.concat("<b>admin</b>")
        \\        }
        \\        $out = $out.concat("\n")
        \\        if context.paid { # T.rocstache:15
        \\            $out = $out.concat("<i>")
        \\            $out = $out.concat(Rocstache.escape(context.title.to_str())) # T.rocstache:15
        \\            $out = $out.concat(" paid</i>")
        \\        }
        \\        $out = $out.concat("\n")
        \\        for item in context.items { # T.rocstache:16
        \\            if context.paid { # T.rocstache:16
        \\                $out = $out.concat(Rocstache.escape(context.title.to_str())) # T.rocstache:16
        \\                $out = $out.concat(":")
        \\                $out = $out.concat(Rocstache.escape(Str.trim(item.name).to_str())) # T.rocstache:16
        \\            }
        \\        }
        \\        $out
        \\    }
        \\}
        \\
    ;
    try std.testing.expectEqualStrings(expected, try untab(arena.allocator(), out));
}

fn untab(gpa: Allocator, s: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, gpa, s, "\t", "    ");
}

test "partials with projection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var files = TestFiles{ .files = &.{
        .{ "Card", "<div>{{name}}{{#tags}}{{.}}{{/tags}}</div>" },
        .{ "Row", "{{name}}" },
        .{ "Footer", "</body>" },
    } };
    const out = try genTest(arena.allocator(), "{{> Card}}{{email}}{{#tags}}{{.}}{{/tags}}{{#rows}}{{> Row}}{{extra}}{{/rows}}{{> Footer}}", &files);
    try std.testing.expect(has(out, "import Card\nimport Row\nimport Footer\n"));
    try std.testing.expect(has(out, "$out = Card.render_into($out, context)"));
    try std.testing.expect(has(out, "$out = Row.render_into($out, item)"));
    // A partial that reads no fields takes `{}`.
    try std.testing.expect(has(out, "$out = Footer.render_into($out, {})"));
}

test "a partial that uses partials: the list of partials grows under it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var files = TestFiles{ .files = &.{
        .{ "Page", "{{name}}{{> P1}}{{> P2}}{{> P3}}{{> P4}}{{> P5}}{{> P6}}{{> P7}}{{> P8}}{{> P9}}{{tail}}" },
        .{ "P1", "{{a}}" },
        .{ "P2", "{{b}}" },
        .{ "P3", "{{c}}" },
        .{ "P4", "{{d}}" },
        .{ "P5", "{{e}}" },
        .{ "P6", "{{f}}" },
        .{ "P7", "{{g}}" },
        .{ "P8", "{{h}}" },
        .{ "P9", "{{i}}" },
    } };
    const out = try genTest(arena.allocator(), "{{> Page}}", &files);
    try std.testing.expect(has(out, "$out = Page.render_into($out, context)"));
}

test "formatters must be in scope; a declared Ctx types render" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files = TestFiles{ .files = &.{} };
    var diag: mustache.Diagnostic = .{};
    try std.testing.expectError(error.TypeError, generate(a, "{{ x | money }}", .{ .ctx = &files, .loadFn = TestFiles.load }, .{ .source_name = "T", .module_name = "T" }, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "`money` is not defined here") != null);
    try std.testing.expectError(error.TypeError, generate(a, "{{ x | plural }}", .{ .ctx = &files, .loadFn = TestFiles.load }, .{ .source_name = "T", .module_name = "T" }, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "import pf.Rocstache exposing [plural]") != null);
    try std.testing.expectError(error.TypeError, generate(a, "{{%\nrender_into = |s| s\n%}}{{ x | render_into }}", .{ .ctx = &files, .loadFn = TestFiles.load }, .{ .source_name = "T", .module_name = "T" }, &diag));
    var with_tags = TestFiles{ .files = &.{.{ "Tags", "x" }} };
    try std.testing.expectError(error.TypeError, generate(a, "{{%\nimport ../db/Tags\n%}}{{> Tags}}", .{ .ctx = &with_tags, .loadFn = TestFiles.load }, .{ .source_name = "T", .module_name = "T" }, &diag));
    _ = try genTest(a, "{{%\nimport ../db/Tags as TagRows\n%}}{{> Tags}}", &with_tags);
    const two = try genTest(a, "{{%\nCtx(a, others) : { x : a, ..others }\n%}}{{ x }}", &files);
    try std.testing.expect(has(two, "render : Ctx(_, _) -> Str") and has(two, "render_into : Str, Ctx(_, _) -> Str"));
    const q = try genTest(a, "{{ n | Num.to_str }}{{ x | I64.to_str }}", &files);
    try std.testing.expect(has(q, "I64.to_str(context.x).to_str()"));
    const typed = try genTest(a, "{{%\nimport ../db/Links\n\nCtx : { links : List(Links.Row) }\n%}}{{#links}}{{ title }}{{/links}}", &files);
    try std.testing.expect(has(typed, "\trender : Ctx -> Str\n\trender = |context|"));
    try std.testing.expect(has(typed, "T :: [].{\n\n\tCtx : { links : List(Links.Row) }\n"));
    try std.testing.expect(!has(typed, "\trender_into :"));
    const open_ctx = try genTest(a, "{{%\nCtx(others) : { links : List({ title : Str }), ..others }\n%}}{{ heading }}{{#links}}{{ title }}{{/links}}", &files);
    try std.testing.expect(has(open_ctx, "\trender : Ctx(_) -> Str\n"));
    try std.testing.expect(has(typed, "import ../db/Links\n"));
}

test "partial errors report the partial file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var files = TestFiles{ .files = &.{ .{ "Bad", "{{#x}}" }, .{ "Fmt", "{{ x | nope }}" } } };
    var diag: mustache.Diagnostic = .{};
    try std.testing.expectError(error.ParseError, generate(arena.allocator(), "{{> Bad}}", .{ .ctx = &files, .loadFn = TestFiles.load }, .{ .source_name = "T", .module_name = "T" }, &diag));
    try std.testing.expectEqualStrings("Bad", diag.file);
    try std.testing.expectError(error.TypeError, generate(arena.allocator(), "{{> Fmt}}", .{ .ctx = &files, .loadFn = TestFiles.load }, .{ .source_name = "T", .module_name = "T" }, &diag));
    try std.testing.expectEqualStrings("Fmt", diag.file);
    var cyc = TestFiles{ .files = &.{ .{ "A", "{{> B}}" }, .{ "B", "{{> A}}" } } };
    try std.testing.expectError(error.TypeError, generate(arena.allocator(), "{{> A}}", .{ .ctx = &cyc, .loadFn = TestFiles.load }, .{ .source_name = "T", .module_name = "T" }, &diag));
}
