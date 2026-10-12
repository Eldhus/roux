//! One template checked as `roux build` checks it, for the language server
//! (lsp.zig): parsed, the partials it reaches found beside it, and its
//! contract decided and checked, a called partial's before its callers'
//! (contract.calls_known, generate.zig's order). Not the bytecode, which
//! needs roc glue's layouts: what only it refuses (a layout glue disagrees
//! with, a read more than 15 scopes up) is left to `roux build`.
//!
//! A partial is read from the editor's buffer when one is open (what is
//! typed, saved or not), else from its file. A mistake in a partial is
//! reported on the tag that reaches it, with the partial's own line.
//! Everything lives in the caller's arena, one a request.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");
const contract_ = @import("contract.zig");
const generate = @import("generate.zig");
const cache = @import("cache.zig");

/// A document open in the editor: its path, and what it holds now.
pub const Buffer = struct { path: []const u8, text: []const u8 };

/// A mistake, in the checked template's source.
pub const Problem = struct {
    offset: u32,
    length: u32,
    message: []const u8,
};

pub const Analysis = struct {
    /// The checked template first, then the partials it reaches.
    templates: []const contract_.Template,
    /// Its contract; null when a problem stopped it.
    contract: ?*const contract_.Contract = null,
    problem: ?Problem = null,
};

pub const Options = struct {
    /// The template's file: its name, and where its partials are.
    path: []const u8,
    /// What it holds now (the editor's buffer).
    source: []const u8,
    /// Every document open in the editor, the template's own included.
    buffers: []const Buffer,
};

/// The template `options.path`, holding `options.source`, checked.
pub fn analyze(arena: Allocator, io: Io, options: Options) Allocator.Error!Analysis {
    const name = std.fs.path.stem(options.path);
    if (name_refused(name)) |message| {
        return .{ .templates = &.{}, .problem = .{ .offset = 0, .length = 0, .message = message } };
    }
    const tree = try cache.create_unfilled(arena, parse.Tree);
    var diagnostic: parse.Diagnostic = .{};
    parse.parse(options.source, tree, &diagnostic) catch {
        return .{ .templates = &.{}, .problem = problem_in(options.source, diagnostic) };
    };
    const templates = try arena.alloc(contract_.Template, generate.templates_max);
    templates[0] = .{ .name = name, .source = options.source, .tree = tree };
    var count: u32 = 1;
    if (try reach(arena, io, options, templates, &count)) |problem| {
        return .{ .templates = templates[0..count], .problem = problem };
    }
    assert(count >= 1);
    assert(count <= generate.templates_max);
    return decide(arena, templates[0..count]);
}

/// The scopes in effect at a point of a checked template, outermost first:
/// the contract's root, then each enclosing section's, by the check's rule
/// (a list's element, a record or a Bool itself; `{{^}}` and `{{?}}` open
/// none). What `../` climbs, and what a path starts from.
pub const Scopes = struct {
    types: [parse.depth_max + 1]u16 = undefined,
    len: u8 = 0,

    pub fn slice(scopes: *const Scopes) []const u16 {
        return scopes.types[0..scopes.len];
    }
};

/// The scopes at `offset` of `source`, whose tree and checked contract
/// these are. A tag's own path starts from the scopes at its `{{`.
pub fn scopes_at(
    contract: *const contract_.Contract,
    tree: *const parse.Tree,
    source: []const u8,
    offset: u32,
) Scopes {
    assert(offset <= source.len);
    var scopes: Scopes = .{};
    scopes.types[0] = contract.root;
    scopes.len = 1;
    const nodes = tree.slice();
    var index: u16 = 0;
    while (index < nodes.len) {
        const node = &nodes[index];
        // At or past the point: neither this node nor any after encloses it.
        if (node.offset + node.length > offset) break;
        const opens = node.kind == .section or node.kind == .inverted or
            node.kind == .conditional;
        const body_end = if (node.end < nodes.len) nodes[node.end].offset else source.len;
        if (!opens or body_end <= offset) {
            index = node.end;
            continue;
        }
        // The point is in this section's body.
        if (node.kind == .section) {
            const target = lookup(contract, scopes.slice(), node.up, node.path_slice()) orelse
                break;
            const type_ = contract.get(target);
            assert(scopes.len <= parse.depth_max);
            scopes.types[scopes.len] = switch (type_.kind) {
                .list => type_.element,
                .record, .bool => target,
                .unknown, .str, .int, .other => break, // the check refuses it
            };
            scopes.len += 1;
        }
        index += 1;
    }
    assert(scopes.len >= 1);
    return scopes;
}

/// The type a path names, `up` scopes out, in a finished contract; null
/// where there is no such field, or a field of what is not a record.
pub fn lookup(
    contract: *const contract_.Contract,
    scopes: []const u16,
    up: u8,
    path: []const []const u8,
) ?u16 {
    assert(scopes.len > 0);
    if (up >= scopes.len) return null;
    var at = scopes[scopes.len - 1 - up];
    for (path) |name| {
        if (contract.get(at).kind != .record) return null;
        at = contract.field(at, name) orelse return null;
    }
    return at;
}

/// What generate.zig refuses in a template's file name.
fn name_refused(name: []const u8) ?[]const u8 {
    if (!parse.is_type_name(name)) return "a template's name is a Roc type name, like `Page`";
    if (std.mem.eql(u8, name, "Templates")) {
        return "`Templates` is the module roux writes for the union";
    }
    return null;
}

/// Loads every partial the templates reach, breadth first, each once. One
/// that does not exist is left to the contract's check, which names it at
/// its tag; one that cannot be read or parsed is the problem.
fn reach(
    arena: Allocator,
    io: Io,
    options: Options,
    templates: []contract_.Template,
    count: *u32,
) Allocator.Error!?Problem {
    var next: u32 = 0;
    while (next < count.*) : (next += 1) {
        assert(count.* <= templates.len);
        for (templates[next].tree.slice()) |node| {
            if (node.kind != .partial or find(templates[0..count.*], node.text) != null) continue;
            const loaded = templates[0..count.*];
            if (count.* == templates.len) {
                const message = "reaches more templates than a build has";
                return on_tag(loaded, node.text, message);
            }
            const source = switch (try load(arena, io, options, node.text)) {
                .missing => continue,
                .source => |source| source,
                .unreadable => |err| {
                    const message = try arena.print("cannot be read ({t})", .{err});
                    return on_tag(loaded, node.text, message);
                },
            };
            const tree = try cache.create_unfilled(arena, parse.Tree);
            var diagnostic: parse.Diagnostic = .{};
            parse.parse(source, tree, &diagnostic) catch {
                const message = try in_partial(arena, node.text, source, .{
                    .offset = diagnostic.offset,
                    .message = diagnostic.message,
                    .subject = diagnostic.subject,
                });
                return on_tag(loaded, node.text, message);
            };
            templates[count.*] = .{ .name = node.text, .source = source, .tree = tree };
            count.* += 1;
        }
    }
    assert(next == count.*);
    return null;
}

const Loaded = union(enum) {
    source: []const u8,
    missing,
    unreadable: Io.Dir.ReadFileAllocError,
};

/// The partial `name`, beside the template: the editor's buffer, else the file.
fn load(arena: Allocator, io: Io, options: Options, name: []const u8) Allocator.Error!Loaded {
    assert(parse.is_type_name(name));
    const dir = std.fs.path.dirname(options.path) orelse ".";
    const path = try std.mem.concat(arena, u8, &.{ dir, "/", name, ".rocstache" });
    for (options.buffers) |buffer| {
        if (std.mem.eql(u8, buffer.path, path)) return .{ .source = buffer.text };
    }
    const limit: Io.Limit = .limited(parse.source_bytes_max);
    const source = Io.Dir.cwd().readFileAlloc(io, path, arena, limit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return .missing,
        else => return .{ .unreadable = err },
    };
    return .{ .source = source };
}

/// The checked template's contract, after those of the partials it
/// reaches that are called (`{{> Top frame}}`), which it takes as types.
fn decide(arena: Allocator, templates: []contract_.Template) Allocator.Error!Analysis {
    var called: [generate.templates_max]bool = @splat(false);
    var remaining: u32 = 0;
    for (templates) |t| for (t.tree.slice()) |node| {
        if (node.kind != .partial or !node.called()) continue;
        const index = find(templates, node.text) orelse continue;
        if (index == 0 or called[index]) continue; // a cycle back: `of` reports it
        called[index] = true;
        remaining += 1;
    };
    for (0..templates.len + 1) |_| {
        if (remaining == 0) break;
        var progressed = false;
        for (templates[1..], 1..) |*t, index| {
            if (!called[index] or t.contract != null) continue;
            if (!contract_.calls_known(templates, t.tree, 0)) continue;
            const contract = try cache.create_unfilled(arena, contract_.Contract);
            const ordered = try arena.dupe(contract_.Template, templates);
            std.mem.swap(contract_.Template, &ordered[0], &ordered[index]);
            var diagnostic: contract_.Diagnostic = .{};
            contract_.of(contract, ordered, &diagnostic) catch {
                return .{ .templates = templates, .problem = try problem_of(
                    arena,
                    templates,
                    diagnostic,
                ) };
            };
            t.contract = contract;
            remaining -= 1;
            progressed = true;
        }
        if (!progressed) break;
    }
    if (remaining > 0) {
        const first = for (templates[1..], 1..) |t, index| {
            if (called[index] and t.contract == null) break t.name;
        } else unreachable;
        const message = "is among partials that call each other: no contract comes first";
        return .{ .templates = templates, .problem = on_tag(templates, first, message) };
    }
    const contract = try cache.create_unfilled(arena, contract_.Contract);
    var diagnostic: contract_.Diagnostic = .{};
    contract_.of(contract, templates, &diagnostic) catch {
        return .{ .templates = templates, .problem = try problem_of(arena, templates, diagnostic) };
    };
    return .{ .templates = templates, .contract = contract };
}

/// The contract's mistake: where it is, when it is in the checked template;
/// else on the tag that reaches the partial it is in.
fn problem_of(
    arena: Allocator,
    templates: []const contract_.Template,
    diagnostic: contract_.Diagnostic,
) Allocator.Error!Problem {
    const self = templates[0];
    if (std.mem.eql(u8, diagnostic.template, self.name)) {
        return problem_in(self.source, .{
            .offset = diagnostic.offset,
            .message = diagnostic.message,
            .subject = diagnostic.subject,
        });
    }
    const index = find(templates, diagnostic.template).?;
    const message = try in_partial(arena, diagnostic.template, templates[index].source, .{
        .offset = diagnostic.offset,
        .message = diagnostic.message,
        .subject = diagnostic.subject,
    });
    return on_tag(templates, diagnostic.template, message);
}

/// The mistake in `source`: its subject underlined, when it is a slice of
/// the source (a path, a name, as written); else the tag's `{{`.
fn problem_in(source: []const u8, diagnostic: parse.Diagnostic) Problem {
    const offset = diagnostic.offset;
    assert(offset <= source.len);
    const start = @intFromPtr(source.ptr);
    const at = @intFromPtr(diagnostic.subject.ptr);
    const inside = diagnostic.subject.len > 0 and at >= start and
        at + diagnostic.subject.len <= start + source.len;
    const message = diagnostic.message;
    if (inside) {
        const subject_offset: u32 = @intCast(at - start);
        const length: u32 = @intCast(diagnostic.subject.len);
        // Says what it is about: the underline shows where.
        return .{ .offset = subject_offset, .length = length, .message = message };
    }
    const length: u32 = @intCast(@min(2, source.len - offset));
    return .{ .offset = offset, .length = length, .message = message };
}

/// `in Top.rocstache:3:5: `x` message`, as `roux build` prints it.
fn in_partial(
    arena: Allocator,
    name: []const u8,
    source: []const u8,
    diagnostic: parse.Diagnostic,
) Allocator.Error![]const u8 {
    const subject = if (diagnostic.subject.len > 0)
        try arena.print("`{s}` ", .{diagnostic.subject})
    else
        "";
    return arena.print("in {s}.rocstache:{d}:{d}: {s}{s}", .{
        name,
        diagnostic.line(source),
        diagnostic.column(source),
        subject,
        diagnostic.message,
    });
}

/// `message` on the checked template's first partial tag through which it
/// reaches the template `name`.
fn on_tag(templates: []const contract_.Template, name: []const u8, message: []const u8) Problem {
    const self = templates[0];
    for (self.tree.slice()) |node| {
        if (node.kind != .partial) continue;
        if (!std.mem.eql(u8, node.text, name) and !reaches(templates, node.text, name)) continue;
        return .{ .offset = node.offset, .length = node.length, .message = message };
    }
    unreachable; // every template but the first was reached from it
}

/// Whether the template `from` includes `name`, through any partials.
fn reaches(templates: []const contract_.Template, from: []const u8, name: []const u8) bool {
    const start = find(templates, from) orelse return false;
    var seen: [generate.templates_max]bool = @splat(false);
    var queue: [generate.templates_max]u32 = undefined;
    queue[0] = start;
    seen[start] = true;
    var queue_len: u32 = 1;
    var next: u32 = 0;
    while (next < queue_len) : (next += 1) {
        assert(queue_len <= templates.len);
        for (templates[queue[next]].tree.slice()) |node| {
            if (node.kind != .partial) continue;
            if (std.mem.eql(u8, node.text, name)) return true;
            const index = find(templates, node.text) orelse continue;
            if (seen[index]) continue;
            seen[index] = true;
            queue[queue_len] = index;
            queue_len += 1;
        }
    }
    return false;
}

fn find(templates: []const contract_.Template, name: []const u8) ?u32 {
    for (templates, 0..) |t, index| {
        if (std.mem.eql(u8, t.name, name)) return @intCast(index);
    }
    return null;
}

const testing = std.testing;

/// The problem `analyze` finds in `Page`, its partials open as buffers.
fn problem_with(arena: Allocator, page: []const u8, partials: []const Buffer) !?Problem {
    var buffers: [8]Buffer = undefined;
    buffers[0] = .{ .path = "/app/templates/Page.rocstache", .text = page };
    @memcpy(buffers[1..][0..partials.len], partials);
    const analysis = try analyze(arena, testing.io, .{
        .path = buffers[0].path,
        .source = page,
        .buffers = buffers[0 .. partials.len + 1],
    });
    assert((analysis.problem == null) == (analysis.contract != null));
    return analysis.problem;
}

test "analysis: a sound template has its contract, its partials from buffers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const top: Buffer = .{
        .path = "/app/templates/Top.rocstache",
        .text = "<title>{{ title }}</title>",
    };
    const page = "{{> Top frame}}{{#items}}{{ name }}{{/items}}";
    try testing.expectEqual(@as(?Problem, null), try problem_with(arena, page, &.{top}));
}

test "analysis: a mistake is underlined where it is, or on the tag reaching it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // In the template: the subject as written.
    const page = "<p>{{ a }}{{ a.b }}</p>";
    const own = (try problem_with(arena, page, &.{})).?;
    try testing.expectEqualStrings("a.b", page[own.offset..][0..own.length]);
    // A parse error with no subject: the tag's braces.
    const open = (try problem_with(arena, "<p>{{ a", &.{})).?;
    try testing.expectEqual(@as(u32, 3), open.offset);
    try testing.expectEqualStrings("a tag that never closes", open.message);
    // In a partial, inlined or called, parsed or checked: the tag, the partial's line.
    const cases = [_]struct { page: []const u8, top: []const u8, message: []const u8 }{
        .{
            .page = "x\n{{> Top}}",
            .top = "\n{{#a}}",
            .message = "in Top.rocstache:2:1: `a` is never closed",
        },
        .{
            .page = "{{ a }}{{> Top}}",
            .top = "{{#a}}{{ b }}{{/a}}",
            .message = "in Top.rocstache:1:1: `a` is a Str elsewhere, and a list here",
        },
        .{
            .page = "{{> Top frame}}",
            .top = "{{ ../x }}",
            .message = "in Top.rocstache:1:1: `../x` climbs above the template's context",
        },
    };
    for (cases) |case| {
        const top: Buffer = .{ .path = "/app/templates/Top.rocstache", .text = case.top };
        const problem = (try problem_with(arena, case.page, &.{top})).?;
        const tag = case.page[problem.offset..][0..problem.length];
        try testing.expect(std.mem.startsWith(u8, tag, "{{> Top"));
        try testing.expectEqualStrings(case.message, problem.message);
    }
}

test "analysis: a partial through another is reported on the first tag" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const middle: Buffer = .{ .path = "/app/templates/Middle.rocstache", .text = "{{> Bottom}}" };
    const bottom: Buffer = .{ .path = "/app/templates/Bottom.rocstache", .text = "{{ X }}" };
    const page = "<p>{{> Middle}}</p>";
    const problem = (try problem_with(arena, page, &.{ middle, bottom })).?;
    try testing.expectEqualStrings("{{> Middle}}", page[problem.offset..][0..problem.length]);
    try testing.expect(std.mem.startsWith(u8, problem.message, "in Bottom.rocstache:1:1:"));
}

test "analysis: a partial is read from its file, a missing one named at its tag" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Top.rocstache", .data = "{{ title }}" });
    const dir = try std.mem.concat(arena, u8, &.{ ".zig-cache/tmp/", &tmp.sub_path });
    const path = try std.mem.concat(arena, u8, &.{ dir, "/Page.rocstache" });
    const page = "{{> Top}}{{> Gone}}";
    const options: Options = .{ .path = path, .source = page, .buffers = &.{} };
    const analysis = try analyze(arena, testing.io, options);
    try testing.expectEqual(@as(usize, 2), analysis.templates.len);
    const problem = analysis.problem.?;
    try testing.expectEqualStrings("Gone", page[problem.offset..][0..problem.length]);
    try testing.expectEqualStrings("is not a template here (no such .rocstache)", problem.message);
}

test "analysis: the scopes at a point follow the sections around it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const page = "{{ t }}{{#xs}}A{{#on}}B{{/on}}{{^ys}}C{{/ys}}{{?f}}D{{/f}}{{/xs}}E";
    const path = "/app/templates/Page.rocstache";
    const options: Options = .{ .path = path, .source = page, .buffers = &.{} };
    const analysis = try analyze(arena, testing.io, options);
    const contract = analysis.contract.?;
    const tree = analysis.templates[0].tree;
    const element = "{ f : Bool, on : Bool, ys : Bool }";
    const cases = [_]struct { at: u8, innermost: []const u8, depth: u8 }{
        .{ .at = 'A', .innermost = element, .depth = 2 },
        .{ .at = 'B', .innermost = "Bool", .depth = 3 },
        .{ .at = 'C', .innermost = element, .depth = 2 },
        .{ .at = 'D', .innermost = element, .depth = 2 },
        .{ .at = 'E', .innermost = "{ t : Str, xs : List(" ++ element ++ ") }", .depth = 1 },
    };
    for (cases) |case| {
        const offset: u32 = @intCast(std.mem.indexOfScalar(u8, page, case.at).?);
        const scopes = scopes_at(contract, tree, page, offset);
        try testing.expectEqual(case.depth, scopes.len);
        var buffer: [128]u8 = undefined;
        var writer: Io.Writer = .fixed(&buffer);
        try contract_.write_line(contract, scopes.slice()[scopes.len - 1], &writer);
        try testing.expectEqualStrings(case.innermost, writer.buffered());
    }
    // A section's own tag is read in the scopes outside it.
    const tag: u32 = @intCast(std.mem.indexOf(u8, page, "{{#on}}").? + 3);
    try testing.expectEqual(@as(u8, 2), scopes_at(contract, tree, page, tag).len);
}

test "analysis: a file name roux build refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "/app/templates/page.rocstache", "/app/Templates.rocstache" }) |path| {
        const options: Options = .{ .path = path, .source = "", .buffers = &.{} };
        const analysis = try analyze(arena, testing.io, options);
        try testing.expect(analysis.problem != null);
    }
}
