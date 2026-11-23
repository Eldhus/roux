//! A template's markup checked as the pages that render it, for the
//! language server (lsp.zig). A layout split across partials (`Top` opens
//! `<body>`, `Bottom` closes it) is whole only in a page: checked alone,
//! each half is wrong.
//!
//! A page is a template beside the checked one that no template includes.
//! It is checked with every partial in place, recursively, its tags blanked
//! (markup.zig), and what SuperHTML finds is put back in the template it
//! lies in. Checking a page: its own problems are its own, and one in a
//! partial is said on the page's tag that reaches it, as `roux build` says
//! a partial's mistake. Checking a template pages reach: it is checked in
//! each of them, and a problem found in only some names those. A template
//! that does not parse, or that no page reaches, is checked as a page.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");
const generate = @import("generate.zig");
const analysis = @import("analysis.zig");
const cache = @import("cache.zig");
const markup = @import("markup.zig");

const Problem = markup.Problem;

/// A page's markup, its partials in place, at most this long.
const page_bytes_max = parse.source_bytes_max;

const Template = struct {
    name: []const u8,
    source: []const u8,
    /// Null when it does not parse: its partials are not followed.
    tree: ?*const parse.Tree,
};

/// The markup's problems in the template `options.path`.
pub fn check(arena: Allocator, io: Io, options: analysis.Options) Allocator.Error![]const Problem {
    const templates = try gather(arena, io, options);
    assert(templates.len >= 1);
    if (templates[0].tree == null) return markup.check(arena, options.source);
    var pages: std.ArrayList(u16) = .empty;
    for (templates[1..], 1..) |t, index| {
        if (t.tree == null or included(templates, @intCast(index))) continue;
        if (reaches(templates, @intCast(index), 0)) try pages.append(arena, @intCast(index));
    }
    if (pages.items.len == 0) return as_page(arena, templates);
    return in_pages(arena, templates, pages.items);
}

/// The checked template first, then the others beside it: the editor's
/// buffers there (what is typed, saved or not), then the directory's
/// files, each once.
fn gather(arena: Allocator, io: Io, options: analysis.Options) Allocator.Error![]const Template {
    const directory = std.fs.path.dirname(options.path) orelse ".";
    var names: std.ArrayList([]const u8) = .empty;
    try names.append(arena, std.fs.path.stem(options.path));
    for (options.buffers) |buffer| {
        const beside = std.mem.eql(u8, std.fs.path.dirname(buffer.path) orelse ".", directory);
        if (!beside or !std.mem.endsWith(u8, buffer.path, ".rocstache")) continue;
        try add_name(arena, &names, std.fs.path.stem(buffer.path));
    }
    if (Io.Dir.cwd().openDir(io, directory, .{ .iterate = true })) |opened| {
        var dir = opened;
        defer dir.close(io);
        var iterator = dir.iterate();
        for (0..generate.templates_max) |_| {
            const entry = (iterator.next(io) catch break) orelse break;
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".rocstache")) continue;
            try add_name(arena, &names, try arena.dupe(u8, std.fs.path.stem(entry.name)));
        }
    } else |_| {} // no directory: the buffers only
    var templates: std.ArrayList(Template) = .empty;
    try templates.ensureTotalCapacityPrecise(arena, names.items.len);
    templates.appendAssumeCapacity(.{
        .name = names.items[0],
        .source = options.source,
        .tree = try parsed(arena, options.source),
    });
    for (names.items[1..]) |name| {
        const source = switch (try analysis.load(arena, io, options, name)) {
            .source => |source| source,
            .missing, .unreadable => continue,
        };
        templates.appendAssumeCapacity(.{
            .name = name,
            .source = source,
            .tree = try parsed(arena, source),
        });
    }
    return templates.items;
}

/// `name`, unless it is not a template's, or already there.
fn add_name(
    arena: Allocator,
    names: *std.ArrayList([]const u8),
    name: []const u8,
) Allocator.Error!void {
    if (!parse.is_type_name(name) or std.mem.eql(u8, name, "Templates")) return;
    for (names.items) |known| if (std.mem.eql(u8, known, name)) return;
    if (names.items.len == generate.templates_max) return;
    try names.append(arena, name);
}

fn parsed(arena: Allocator, source: []const u8) Allocator.Error!?*const parse.Tree {
    const tree = try cache.create_unfilled(arena, parse.Tree);
    var diagnostic: parse.Diagnostic = .{};
    parse.parse(source, tree, &diagnostic) catch return null;
    return tree;
}

/// Whether any other template includes the template `index`.
fn included(templates: []const Template, index: u16) bool {
    for (templates, 0..) |t, other| {
        if (other == index) continue;
        const tree = t.tree orelse continue;
        for (tree.slice()) |node| {
            if (node.kind == .partial and std.mem.eql(u8, node.text, templates[index].name)) {
                return true;
            }
        }
    }
    return false;
}

/// Whether the template `from` includes the template `target`, through
/// any partials.
fn reaches(templates: []const Template, from: u16, target: u16) bool {
    assert(templates.len <= generate.templates_max);
    var seen: [generate.templates_max]bool = @splat(false);
    var queue: [generate.templates_max]u16 = undefined;
    queue[0] = from;
    seen[from] = true;
    var queue_len: u32 = 1;
    var next: u32 = 0;
    while (next < queue_len) : (next += 1) {
        const tree = templates[queue[next]].tree orelse continue;
        for (tree.slice()) |node| {
            if (node.kind != .partial) continue;
            const index = find(templates, node.text) orelse continue;
            if (index == target) return true;
            if (seen[index]) continue;
            seen[index] = true;
            queue[queue_len] = index;
            queue_len += 1;
        }
    }
    return false;
}

fn find(templates: []const Template, name: []const u8) ?u16 {
    for (templates, 0..) |t, index| {
        if (std.mem.eql(u8, t.name, name)) return @intCast(index);
    }
    return null;
}

/// The checked template as a page: its problems, and its partials' on
/// the tags that reach them.
fn as_page(arena: Allocator, templates: []const Template) Allocator.Error![]const Problem {
    const found = try page_problems(arena, templates, 0) orelse
        return markup.check(arena, templates[0].source);
    var problems: std.ArrayList(Problem) = .empty;
    for (found) |placed| {
        const problem = placed.problem;
        const via = placed.segment.via orelse {
            try problems.append(arena, placed.problem);
            continue;
        };
        const partial = templates[placed.segment.template];
        const at: parse.Diagnostic = .{ .offset = placed.problem.offset };
        const on_via: Problem = .{
            .offset = via.offset,
            .length = via.length,
            .message = try arena.print("in {s}.rocstache:{d}:{d}: {s}", .{
                partial.name,
                at.line(partial.source),
                at.column(partial.source),
                problem.message,
            }),
            .warning = problem.warning,
        };
        // A partial put in place twice through one tag says it once.
        for (problems.items) |known| {
            if (same_problem(known, on_via)) break;
        } else try problems.append(arena, on_via);
    }
    return problems.items;
}

/// The checked template's problems in each page that reaches it; one
/// found in only some of them names those.
fn in_pages(
    arena: Allocator,
    templates: []const Template,
    pages: []const u16,
) Allocator.Error![]const Problem {
    const Seen = struct { problem: Problem, pages: std.ArrayList(u16) };
    var seen: std.ArrayList(Seen) = .empty;
    var composed: u32 = 0;
    for (pages) |index| {
        const found = try page_problems(arena, templates, index) orelse continue;
        composed += 1;
        for (found) |placed| {
            if (placed.segment.template != 0) continue;
            const same = for (seen.items) |*known| {
                if (same_problem(known.problem, placed.problem)) break known;
            } else null;
            const entry = same orelse entry: {
                if (seen.items.len == markup.problems_max) continue;
                try seen.append(arena, .{ .problem = placed.problem, .pages = .empty });
                break :entry &seen.items[seen.items.len - 1];
            };
            const last = entry.pages.getLastOrNull();
            if (last == null or last.? != index) try entry.pages.append(arena, index);
        }
    }
    if (composed == 0) return markup.check(arena, templates[0].source);
    const problems = try arena.alloc(Problem, seen.items.len);
    for (seen.items, problems) |entry, *problem| {
        problem.* = entry.problem;
        if (entry.pages.items.len == composed) continue;
        var names: Io.Writer.Allocating = .init(arena);
        for (entry.pages.items, 0..) |index, n| {
            if (n > 0) names.writer.writeAll(", ") catch return error.OutOfMemory;
            names.writer.writeAll(templates[index].name) catch return error.OutOfMemory;
        }
        const message = entry.problem.message;
        problem.message = try arena.print("{s} (in {s})", .{ message, names.written() });
    }
    return problems;
}

fn same_problem(a: Problem, b: Problem) bool {
    return a.offset == b.offset and a.length == b.length and std.mem.eql(u8, a.message, b.message);
}

/// What SuperHTML finds in the page `index`, put back in its templates,
/// over each way it may render (markup.Branches), each problem once; null
/// when the page is longer than a page may be.
fn page_problems(
    arena: Allocator,
    templates: []const Template,
    index: u16,
) Allocator.Error!?[]const Placed {
    const paths = try markup.forks(arena, try trees_in(arena, templates, index));
    assert(paths.len <= markup.forks_max);
    var found: std.ArrayList(Placed) = .empty;
    const renderings = @as(u32, 1) << @intCast(paths.len);
    for (0..renderings) |taken| {
        const branches: markup.Branches = .{ .paths = paths, .taken = @intCast(taken) };
        const page = try compose(arena, templates, index, branches) orelse return null;
        for (try markup.problems_in(arena, page.markup)) |problem| {
            const placed = place(templates, page, problem) orelse continue;
            const known = for (found.items) |other| {
                if (same_placed(other, placed)) break true;
            } else false;
            if (known or found.items.len == markup.problems_max) continue;
            try found.append(arena, placed);
        }
    }
    return found.items;
}

fn same_placed(a: Placed, b: Placed) bool {
    if (a.segment.template != b.segment.template) return false;
    const a_via: ?u32 = if (a.segment.via) |via| via.offset else null;
    const b_via: ?u32 = if (b.segment.via) |via| via.offset else null;
    return a_via == b_via and same_problem(a.problem, b.problem);
}

/// The trees of the template `index` and of every partial it reaches.
fn trees_in(
    arena: Allocator,
    templates: []const Template,
    index: u16,
) Allocator.Error![]const *const parse.Tree {
    var trees: std.ArrayList(*const parse.Tree) = .empty;
    for (templates, 0..) |t, other| {
        const tree = t.tree orelse continue;
        if (other == index or reaches(templates, index, @intCast(other))) {
            try trees.append(arena, tree);
        }
    }
    return trees.items;
}

/// A stretch of a page's markup, from one template.
const Segment = struct {
    /// Where it starts in the page's markup.
    start: u32,
    length: u32,
    template: u16,
    /// Where it starts in the template.
    offset: u32,
    /// The page's partial tag it is reached through; null in the page.
    via: ?Via,

    const Via = struct { offset: u32, length: u32 };
};

const Page = struct {
    /// Blanked, its partials in place.
    markup: []const u8,
    /// Its stretches, in order, end to end.
    segments: []const Segment,
};

/// The template `index` as a page, rendering on `branches`; null when it
/// is longer than a page may be.
fn compose(
    arena: Allocator,
    templates: []const Template,
    index: u16,
    branches: markup.Branches,
) Allocator.Error!?Page {
    var composer: Composer = .{ .arena = arena, .templates = templates, .branches = branches };
    composer.emit(index, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooLong => return null,
    };
    return .{ .markup = composer.markup.items, .segments = composer.segments.items };
}

const Composer = struct {
    arena: Allocator,
    templates: []const Template,
    branches: markup.Branches,
    markup: std.ArrayList(u8) = .empty,
    segments: std.ArrayList(Segment) = .empty,
    /// The templates being emitted, outermost first: a partial already on
    /// it (partials that include each other) is left a blank tag.
    stack: [parse.depth_max]u16 = undefined,
    stack_len: u8 = 0,

    const Error = error{ OutOfMemory, TooLong };

    fn emit(composer: *Composer, index: u16, via: ?Segment.Via) Error!void {
        assert(composer.stack_len < parse.depth_max);
        const t = composer.templates[index];
        const blanked = try composer.arena.alloc(u8, t.source.len);
        markup.blank_taking(t.source, t.tree, composer.branches, blanked);
        composer.stack[composer.stack_len] = index;
        composer.stack_len += 1;
        defer composer.stack_len -= 1;
        var at: u32 = 0;
        if (t.tree) |tree| for (tree.slice()) |node| {
            if (node.kind != .partial) continue;
            assert(node.offset >= at);
            try composer.piece(index, blanked, at, node.offset, via);
            const tag_end = node.offset + node.length;
            const child = find(composer.templates, node.text);
            if (child != null and composer.room(child.?)) {
                const tag: Segment.Via = .{ .offset = node.offset, .length = node.length };
                try composer.emit(child.?, via orelse tag);
            } else try composer.piece(index, blanked, node.offset, tag_end, via);
            at = tag_end;
        };
        try composer.piece(index, blanked, at, @intCast(t.source.len), via);
    }

    /// Whether the template `index` may be put in place here.
    fn room(composer: *const Composer, index: u16) bool {
        if (composer.stack_len == parse.depth_max) return false;
        for (composer.stack[0..composer.stack_len]) |on| if (on == index) return false;
        return true;
    }

    fn piece(
        composer: *Composer,
        index: u16,
        blanked: []const u8,
        from: u32,
        to: u32,
        via: ?Segment.Via,
    ) Error!void {
        assert(from <= to and to <= blanked.len);
        if (from == to) return;
        if (composer.markup.items.len + (to - from) > page_bytes_max) return error.TooLong;
        try composer.segments.append(composer.arena, .{
            .start = @intCast(composer.markup.items.len),
            .length = to - from,
            .template = index,
            .offset = from,
            .via = via,
        });
        try composer.markup.appendSlice(composer.arena, blanked[from..to]);
    }
};

const Placed = struct { segment: Segment, problem: Problem };

/// A problem in a page's markup, in the template it lies in; null when it
/// is on a tag there.
fn place(templates: []const Template, page: Page, problem: Problem) ?Placed {
    if (page.segments.len == 0) return null;
    var segment = page.segments[0];
    for (page.segments) |s| {
        if (s.start > problem.offset) break;
        segment = s;
    }
    assert(segment.start <= problem.offset);
    const into = problem.offset - segment.start;
    const length = @min(problem.length, segment.length -| into);
    const offset = segment.offset + @min(into, segment.length);
    var moved = problem;
    moved.offset = offset;
    moved.length = length;
    const said = markup.about_tags(templates[segment.template].source, moved) orelse return null;
    return .{ .segment = segment, .problem = said };
}

const testing = std.testing;

/// What `check` finds in `templates/<name>`, the others open as buffers.
fn check_with(
    arena: Allocator,
    name: []const u8,
    buffers: []const analysis.Buffer,
) ![]const Problem {
    const path = try arena.print("/nowhere/templates/{s}.rocstache", .{name});
    for (buffers) |buffer| {
        if (!std.mem.eql(u8, buffer.path, path)) continue;
        const source = buffer.text;
        return check(arena, testing.io, .{ .path = path, .source = source, .buffers = buffers });
    }
    unreachable;
}

test "pages: a layout split across partials is whole in its pages" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const buffers = [_]analysis.Buffer{
        .{ .path = "/nowhere/templates/Top.rocstache", .text = "<main>\n<p>{{ title }}" },
        .{ .path = "/nowhere/templates/Bottom.rocstache", .text = "</main>" },
        .{ .path = "/nowhere/templates/Page.rocstache", .text = "{{> Top}}</p>\n{{> Bottom}}" },
        .{ .path = "/nowhere/templates/Other.rocstache", .text = "{{> Top}}\n{{> Bottom}}" },
        .{ .path = "/nowhere/templates/Twice.rocstache", .text = "<b>{{> Row}}{{> Row}}</b>" },
        .{ .path = "/nowhere/templates/Row.rocstache", .text = "<dvi></dvi>" },
        .{ .path = "/nowhere/templates/Rows.rocstache", .text = "<i>{{> Twice}}</i>" },
    };
    // Row in place twice through Rows' one tag: said once there.
    const rows = try check_with(arena, "Rows", &buffers);
    try testing.expectEqual(@as(usize, 1), rows.len);
    const row_message = "in Row.rocstache:1:2: not a valid html element";
    try testing.expectEqualStrings(row_message, rows[0].message);
    // Page closes Top's `<p>`, Other does not: Top's problem names Other.
    const top = try check_with(arena, "Top", &buffers);
    try testing.expectEqual(@as(usize, 1), top.len);
    try testing.expectEqual(@as(u32, 8), top[0].offset); // the element's name
    try testing.expectEqualStrings("missing end tag (in Other)", top[0].message);
    // Bottom is whole in both.
    try testing.expectEqual(@as(usize, 0), (try check_with(arena, "Bottom", &buffers)).len);
    // Page is whole; Other has Top's problem, on its tag that reaches it.
    try testing.expectEqual(@as(usize, 0), (try check_with(arena, "Page", &buffers)).len);
    const other = try check_with(arena, "Other", &buffers);
    try testing.expectEqual(@as(usize, 1), other.len);
    try testing.expectEqual(@as(u32, 0), other[0].offset);
    try testing.expectEqual(@as(u32, "{{> Top}}".len), other[0].length);
    try testing.expectEqualStrings("in Top.rocstache:2:2: missing end tag", other[0].message);
}

test "pages: a template that does not parse, or partials in a loop, still checked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const buffers = [_]analysis.Buffer{
        .{ .path = "/nowhere/templates/Page.rocstache", .text = "<div>{{#x}}" },
        .{ .path = "/nowhere/templates/A.rocstache", .text = "<i>{{> B}}</i>" },
        .{ .path = "/nowhere/templates/B.rocstache", .text = "<b>{{> A}}</b>" },
    };
    // Unparsed (a section never closed): alone, its markup still checked.
    const page = try check_with(arena, "Page", &buffers);
    try testing.expectEqual(@as(usize, 1), page.len);
    try testing.expectEqualStrings("missing end tag", page[0].message);
    // A and B include each other: no page reaches them, each is one.
    try testing.expectEqual(@as(usize, 0), (try check_with(arena, "A", &buffers)).len);
}

test "pages: markup split across a section and its inverse is whole on each branch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const split = "{{?x}}<div class=\"a\">{{/x}}{{^x}}<div class=\"b\">{{/x}}x</div>";
    const buffers = [_]analysis.Buffer{
        .{ .path = "/nowhere/templates/Page.rocstache", .text = split },
        // Through a partial too, and still caught where a branch is wrong.
        .{ .path = "/nowhere/templates/Open.rocstache", .text = "{{?x}}<p>{{/x}}{{^x}}<p>{{/x}}" },
        .{ .path = "/nowhere/templates/Lists.rocstache", .text = "{{> Open}}{{?x}}</p>{{/x}}" },
    };
    try testing.expectEqual(@as(usize, 0), (try check_with(arena, "Page", &buffers)).len);
    // With `x` false, Open's `<p>` is never closed: said once, on the tag.
    const lists = try check_with(arena, "Lists", &buffers);
    try testing.expectEqual(@as(usize, 1), lists.len);
    try testing.expectEqualStrings("in Open.rocstache:1:22: missing end tag", lists[0].message);
}

/// Pieces of templates, markup and tags, right and wrong, for `random_template`.
const pieces = [_][]const u8{
    "<div>",   "</div>",        "<p class=\"a\">", "</p>",       "<dvi>",       "<ul>",
    "</ul>",   "<li>",          "</li>",           "<",          ">",           "\"",
    "=",       "<!--",          "-->",             "<script>",   "</script>",   "text ",
    "\u{e9}",  "\r\n",          "\n",              " ",          "<img src=\"", "<br>",
    "{{ x }}", "{{{ y }}}",     "{{#xs |x|}}",     "{{/xs}}",    "{{?c}}",      "{{^c}}",
    "{{/c}}",  "{{! note }}",   "{{> P}}",         "{{> Page}}", "{{> Gone}}",  "{{",
    "}}",      "class={{ v }}",
};

pub const Prng = @import("fourneau").prng.Prng;

/// A template made at random from `pieces`, for this file's tests and
/// the language server's (lsp.zig).
pub fn random_template(arena: Allocator, prng: *Prng) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    if (prng.int_less_than(u8, 8) == 0) try text.appendSlice(arena, "{{% m %}}\n");
    const count = prng.int_less_than(u32, 40);
    for (0..count) |_| try text.appendSlice(arena, pieces[prng.int_less_than(usize, pieces.len)]);
    return text.items;
}

test "pages: templates made at random: no crash, every problem in its template, none on a tag" {
    const seeds = 300;
    for (0..seeds) |seed| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var prng: Prng = .init(seed);
        const buffers = [_]analysis.Buffer{
            .{ .path = "/nowhere/t/Page.rocstache", .text = try random_template(arena, &prng) },
            .{ .path = "/nowhere/t/P.rocstache", .text = try random_template(arena, &prng) },
        };
        for (buffers) |buffer| {
            const source = buffer.text;
            const options: analysis.Options = .{
                .path = buffer.path,
                .source = source,
                .buffers = &buffers,
            };
            for (try check(arena, testing.io, options)) |problem| {
                const end = problem.offset + problem.length;
                try testing.expect(end <= source.len);
                // A partial's problem is on the tag that reaches it.
                if (std.mem.startsWith(u8, problem.message, "in ")) continue;
                if (!markup.on_tag(source, problem.offset, end)) continue;
                const message = problem.message;
                std.debug.print("seed {d}: `{s}` on a tag in:\n{s}\n", .{ seed, message, source });
                return error.TestUnexpectedResult;
            }
            for (0..source.len + 1) |offset| {
                _ = try markup.complete(arena, source, @intCast(offset));
                _ = try markup.describe(arena, source, @intCast(offset));
            }
        }
    }
}
