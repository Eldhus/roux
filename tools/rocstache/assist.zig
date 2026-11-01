//! What the language server says about a point of a template, read from
//! its analysis (analysis.zig): the contract decides every type, as it
//! does for `roux build`. A hover's text: the type of the path segment
//! under the cursor, what a formatter does, what a partial reads. And
//! completions: the fields in scope, the formatters after `|`, the
//! templates beside this one after `>`.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");
const contract_ = @import("contract.zig");
const analysis = @import("analysis.zig");
const generate = @import("generate.zig");
const cache = @import("cache.zig");

/// Markdown about what is at `offset` of the checked template. Null over
/// text, and when the template has a problem: no contract to read from.
pub fn hover(arena: Allocator, result: analysis.Analysis, offset: u32) Allocator.Error!?[]const u8 {
    const contract = result.contract orelse return null;
    const self = result.templates[0];
    assert(offset <= self.source.len);
    const node = for (self.tree.slice()) |*node| {
        if (node.kind == .text) continue;
        if (node.offset <= offset and offset < node.offset + node.length) break node;
    } else return null;
    const scopes = analysis.scopes_at(contract, self.tree, self.source, node.offset);
    const path = node.path_slice();
    for (path, 0..) |segment, k| {
        if (!within(self.source, segment, offset)) continue;
        const target = analysis.lookup(contract, &scopes, path[0 .. k + 1]) orelse return null;
        return try typed(arena, contract, segment, target);
    }
    for (node.pipe_slice()) |pipe| {
        if (within(self.source, pipe.name, offset)) return formatter_text(pipe.formatter);
    }
    if (node.kind == .partial) return try partial_text(arena, result, node);
    if (node.kind == .fragment) return try fragment_text(arena, result, node);
    // A Roc expression is Roc's to describe.
    if (node.expression.len > 0) return null;
    // Elsewhere in the tag (its braces, `#`, its binder): the whole path's type.
    const target = analysis.lookup(contract, &scopes, path) orelse return null;
    return try typed(arena, contract, node.text, target);
}

/// Whether `offset` is on `piece`, a slice of `source`, or just after it.
fn within(source: []const u8, piece: []const u8, offset: u32) bool {
    if (piece.len == 0) return false;
    const start = @intFromPtr(piece.ptr) - @intFromPtr(source.ptr);
    assert(start + piece.len <= source.len);
    return offset >= start and offset <= start + piece.len;
}

/// `label : Type`, as Roc writes it.
fn typed(
    arena: Allocator,
    contract: *const contract_.Contract,
    label: []const u8,
    index: u16,
) Allocator.Error![]const u8 {
    var line: std.Io.Writer.Allocating = .init(arena);
    contract_.write_line(contract, index, &line.writer) catch return error.OutOfMemory;
    return arena.print("```roc\n{s} : {s}\n```", .{ label, line.written() });
}

fn formatter_text(formatter: parse.Formatter) []const u8 {
    return switch (formatter) {
        .len => "`len`: a list's length, a number; `| len | plural \"dish\" \"dishes\"` " ++
            "names it.",
        .plural => "`plural \"one\" \"many\"`: the number, a space, and the noun that fits " ++
            "it: `1 dish`, `3 dishes`.",
        .upper => "`upper`: the Str in upper case.",
        .lower => "`lower`: the Str in lower case.",
        .url => "`url`: the Str percent-encoded, for a URL's path segment or query value.",
    };
}

/// A partial is copied in here and reads the names in scope here.
fn partial_text(
    arena: Allocator,
    result: analysis.Analysis,
    node: *const parse.Node,
) Allocator.Error![]const u8 {
    assert(node.kind == .partial);
    _ = result;
    return arena.print("`{s}.rocstache`, copied in here: its tags read the names in " ++
        "scope here, and were checked against them.", .{node.text});
}

/// A fragment: its module and what it takes when it renders alone.
fn fragment_text(
    arena: Allocator,
    result: analysis.Analysis,
    node: *const parse.Node,
) Allocator.Error!?[]const u8 {
    assert(node.kind == .fragment);
    const page = result.contract.?;
    const k = for (page.fragment_slice(), 0..) |f, index| {
        if (std.mem.eql(u8, f.name, node.text)) break index;
    } else return null; // a partial's own fragment, not this page's
    const contract = try cache.create_unfilled(arena, contract_.Contract);
    contract_.of_fragment(contract, page, @intCast(k)) catch return null;
    var line: std.Io.Writer.Allocating = .init(arena);
    contract_.write_line(contract, contract.root, &line.writer) catch return error.OutOfMemory;
    const name = result.templates[0].name;
    return try arena.print("The fragment `{0s}.{1s}`: rendered here, and alone by " ++
        "`{0s}.{1s}.template`, from what it reads:\n```roc\n{0s}.{1s}.Ctx : {2s}\n```", .{
        name, node.text, line.written(),
    });
}

pub const Item = struct {
    label: []const u8,
    kind: enum { field, formatter, template },
    /// A field's type, a formatter's text, a template's file.
    detail: []const u8,
};

/// What may be typed at `offset` of the template `options` names: the tag
/// around it, read up to `offset`, says what it asks for.
pub fn complete(
    arena: Allocator,
    io: Io,
    options: analysis.Options,
    offset: u32,
) Allocator.Error![]const Item {
    const source = options.source;
    const span = parse.tag_at(source, offset) orelse return &.{};
    const braces: u32 = if (std.mem.startsWith(u8, source[span.start..], "{{{")) 3 else 2;
    if (offset < span.start + braces) return &.{};
    const want = wanted(source[span.start + braces .. offset]) orelse return &.{};
    return switch (want) {
        .field => |field| fields(arena, io, options, span, field),
        .formatter => |prefix| formatters(arena, prefix),
        .template => |prefix| templates(arena, io, options, prefix),
    };
}

const Wanted = union(enum) {
    field: Field,
    /// The formatter's name typed so far.
    formatter: []const u8,
    /// The template's name typed so far.
    template: []const u8,
};

/// A path being typed: through `path`, a field whose name begins with
/// `prefix`; with no path, a name in scope (a binder, or a field of the
/// page's `Ctx`).
const Field = struct {
    path: [parse.path_max][]const u8 = undefined,
    path_len: u8 = 0,
    prefix: []const u8 = "",
};

/// What a tag typed so far (after its braces) asks for, by the tag's
/// grammar (parse.zig's table) read up to the cursor; null where nothing
/// is completed (a comment, a closing tag, a formatter's arguments).
fn wanted(so_far: []const u8) ?Wanted {
    var rest = std.mem.trimStart(u8, so_far, " \t");
    if (rest.len > 0) switch (rest[0]) {
        // A fragment's name is new, written by hand.
        '!', '/', '%', '$' => return null,
        '>' => {
            const inner = std.mem.trimStart(u8, rest[1..], " \t");
            // A partial takes no context: nothing after its name.
            if (std.mem.indexOfAny(u8, inner, " \t") != null) return null;
            return .{ .template = inner };
        },
        '#', '^', '?' => {
            rest = std.mem.trimStart(u8, rest[1..], " \t");
            // A binder (`|dish|`) is a new name, written by hand.
            if (std.mem.indexOfScalar(u8, rest, '|') != null) return null;
        },
        else => {},
    };
    if (std.mem.lastIndexOfScalar(u8, rest, '|')) |bar| {
        const name = std.mem.trimStart(u8, rest[bar + 1 ..], " \t");
        if (std.mem.indexOfAny(u8, name, " \t\"") != null) return null; // its arguments
        return .{ .formatter = name };
    }
    return field_of(rest);
}

/// `a.b.pre`: a path whose last segment is still being typed.
fn field_of(written: []const u8) ?Wanted {
    var field: Field = .{};
    if (std.mem.indexOfAny(u8, written, " \t") != null) return null; // past the path
    var parts = std.mem.splitScalar(u8, written, '.');
    var part = parts.first();
    while (parts.next()) |next| {
        if (!parse.is_field_name(part) or field.path_len == parse.path_max) return null;
        field.path[field.path_len] = part;
        field.path_len += 1;
        part = next;
    }
    field.prefix = part;
    return .{ .field = field };
}

/// The fields of the record the path reaches, in the scopes at the tag:
/// the template analyzed with the tag being typed blanked out (spaces, so
/// every offset stays), since it does not parse or check yet.
fn fields(
    arena: Allocator,
    io: Io,
    options: analysis.Options,
    span: parse.Span,
    field: Field,
) Allocator.Error![]const Item {
    const blanked = try arena.dupe(u8, options.source);
    // A tag that never closes has no tag after it: blank to the end. An
    // opener retyped would leave its closing tag closing nothing: the whole
    // section goes, which the opener's own path, outside it, never reads.
    const end = parse.section_end(options.source, span) orelse span.end orelse blanked.len;
    @memset(blanked[span.start..end], ' ');
    const result = try analysis.analyze(arena, io, .{
        .path = options.path,
        .source = blanked,
        .buffers = options.buffers,
    });
    const contract = result.contract orelse return &.{};
    const scopes = analysis.scopes_at(contract, result.templates[0].tree, blanked, span.start);
    const path = field.path[0..field.path_len];
    var items: std.ArrayList(Item) = .empty;
    // A bare name: the open sections' binders, then the page's fields.
    if (path.len == 0) {
        for (scopes.binder_slice(), scopes.slice()) |binder, type_| {
            if (binder.len == 0 or !std.mem.startsWith(u8, binder, field.prefix)) continue;
            var line: Io.Writer.Allocating = .init(arena);
            contract_.write_line(contract, type_, &line.writer) catch return error.OutOfMemory;
            try items.append(arena, .{ .label = binder, .kind = .field, .detail = line.written() });
        }
    }
    const record = if (path.len == 0)
        scopes.types[0]
    else
        analysis.lookup(contract, &scopes, path) orelse return items.items;
    if (contract.get(record).kind != .record) return items.items;
    var iterator = contract.fields_of(record);
    while (iterator.next()) |f| {
        if (!std.mem.startsWith(u8, f.name, field.prefix)) continue;
        var line: Io.Writer.Allocating = .init(arena);
        contract_.write_line(contract, f.type, &line.writer) catch return error.OutOfMemory;
        try items.append(arena, .{ .label = f.name, .kind = .field, .detail = line.written() });
    }
    return items.items;
}

fn formatters(arena: Allocator, prefix: []const u8) Allocator.Error![]const Item {
    const all = [_]parse.Formatter{ .len, .plural, .upper, .lower, .url };
    comptime assert(all.len == @typeInfo(parse.Formatter).@"enum".field_names.len);
    var items: std.ArrayList(Item) = .empty;
    for (all) |formatter| {
        const name = @tagName(formatter);
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        const detail = formatter_text(formatter);
        try items.append(arena, .{ .label = name, .kind = .formatter, .detail = detail });
    }
    return items.items;
}

/// The templates beside this one: the editor's open buffers there (a
/// partial not yet saved), then the directory's files.
fn templates(
    arena: Allocator,
    io: Io,
    options: analysis.Options,
    prefix: []const u8,
) Allocator.Error![]const Item {
    const directory = std.fs.path.dirname(options.path) orelse ".";
    var names: std.ArrayList([]const u8) = .empty;
    for (options.buffers) |buffer| {
        const beside = std.mem.eql(u8, std.fs.path.dirname(buffer.path) orelse ".", directory);
        if (!beside or !std.mem.endsWith(u8, buffer.path, ".rocstache")) continue;
        try add_template(arena, &names, options.path, std.fs.path.stem(buffer.path), prefix);
    }
    if (Io.Dir.cwd().openDir(io, directory, .{ .iterate = true })) |opened| {
        var dir = opened;
        defer dir.close(io);
        var iterator = dir.iterate();
        for (0..generate.templates_max) |_| {
            const entry = (iterator.next(io) catch break) orelse break;
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".rocstache")) continue;
            const name = try arena.dupe(u8, std.fs.path.stem(entry.name));
            try add_template(arena, &names, options.path, name, prefix);
        }
    } else |_| {} // no directory: the buffers only
    std.mem.sort([]const u8, names.items, {}, string_less);
    const items = try arena.alloc(Item, names.items.len);
    for (names.items, items) |name, *item| {
        const file = try arena.print("{s}.rocstache", .{name});
        item.* = .{ .label = name, .kind = .template, .detail = file };
    }
    return items;
}

/// `name`, unless it is this template, not a template's name, or there.
fn add_template(
    arena: Allocator,
    names: *std.ArrayList([]const u8),
    self: []const u8,
    name: []const u8,
    prefix: []const u8,
) Allocator.Error!void {
    if (!parse.is_type_name(name) or std.mem.eql(u8, name, "Templates")) return;
    if (std.mem.eql(u8, name, std.fs.path.stem(self))) return;
    if (!std.mem.startsWith(u8, name, prefix)) return;
    for (names.items) |known| if (std.mem.eql(u8, known, name)) return;
    if (names.items.len == generate.templates_max) return;
    try names.append(arena, name);
}

fn string_less(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const testing = std.testing;

/// The labels `complete` offers where `$` is in `page` (taken out).
fn labels(arena: Allocator, page: []const u8, buffers: []const analysis.Buffer) ![]const u8 {
    const cursor = std.mem.indexOfScalar(u8, page, '$').?;
    const source = try std.mem.concat(arena, u8, &.{ page[0..cursor], page[cursor + 1 ..] });
    const items = try complete(arena, testing.io, .{
        .path = "/app/templates/Page.rocstache",
        .source = source,
        .buffers = buffers,
    }, @intCast(cursor));
    var names: std.ArrayList(u8) = .empty;
    for (items, 0..) |item, k| {
        if (k > 0) try names.append(arena, ' ');
        try names.appendSlice(arena, item.label);
    }
    return names.items;
}

test "assist: completion offers the fields in scope, typed or not, closed or not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const declared = "{{% Ctx : { items : List({ name : Str, price : U32 }), " ++
        "title : Str, user : { age : U32, name : Str } } %}}";
    const cases = [_][2][]const u8{
        // Inferred from the other tags; the one typed is not a field.
        .{ "<p>{{ ti$}}</p>{{ title }}{{ body }}", "title" },
        .{ declared ++ "{{ $}}", "items title user" },
        // In a section: its binder, then the page's fields.
        .{ declared ++ "{{#items |item|}}{{ $}}{{/items}}", "item items title user" },
        .{ declared ++ "{{#items |item|}}{{ i$}}{{/items}}", "item items" },
        .{ declared ++ "{{#items |item|}}{{ item.$}}{{/items}}", "name price" },
        .{ declared ++ "{{ user.$}}", "age name" },
        .{ declared ++ "{{#$}}", "items title user" },
        // A binder is a new name, written by hand.
        .{ declared ++ "{{#items |i$}}", "" },
        // An existing section's opener retyped: its closing tag stays below.
        .{ declared ++ "{{#it$ |item|}}{{ item.name }}{{/items}}", "items" },
        .{ declared ++ "{{^ti$}}none{{/title}}", "title" },
        .{ declared ++ "<p>{{ t$", "title" }, // never closed
        .{ declared ++ "{{ title | up$}}", "upper" },
        .{ declared ++ "{{ items | $}}", "len plural upper lower url" },
        .{ declared ++ "{{! $}}", "" },
        .{ declared ++ "{{ user | plural \"$\" }}", "" },
    };
    for (cases) |case| {
        errdefer std.debug.print("case {s}\n", .{case[0]});
        try testing.expectEqualStrings(case[1], try labels(arena, case[0], &.{}));
    }
}

test "assist: completion offers the templates beside this one after `>`" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const buffers = [_]analysis.Buffer{
        .{ .path = "/app/templates/Top.rocstache", .text = "{{ title }}" },
        .{ .path = "/app/templates/Tail.rocstache", .text = "" },
        .{ .path = "/app/templates/Page.rocstache", .text = "" },
        .{ .path = "/elsewhere/Thing.rocstache", .text = "" },
    };
    try testing.expectEqualStrings("Tail Top", try labels(arena, "{{> T$}}", &buffers));
    // A partial takes no context, and a fragment's name is new: nothing.
    const page = "{{> Top fr$}}{{> Top}}";
    try testing.expectEqualStrings("", try labels(arena, page, &buffers));
    try testing.expectEqualStrings("", try labels(arena, "{{$Ro$}}x{{/Row}}", &buffers));
}

test "assist: hover shows the segment's type, a formatter, a partial, a fragment" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const top: analysis.Buffer = .{
        .path = "/app/templates/Top.rocstache",
        .text = "<title>{{ frame.title }}</title>",
    };
    const page = "{{% Ctx : { frame : { title : Str }, n : List(Str), " ++
        "items : List({ id : U64, name : { first : Str } }) } %}}" ++
        "{{> Top}}{{#items |item|}}{{$Row}}{{ item.name.first | upper }}{{/Row}}" ++
        "{{ n | len }}{{/items}}";
    const result = try analysis.analyze(arena, testing.io, .{
        .path = "/app/templates/Page.rocstache",
        .source = page,
        .buffers = &.{top},
    });
    const cases = [_]struct { on: []const u8, expected: []const u8 }{
        .{
            .on = "#items",
            .expected = "```roc\nitems : List({ id : U64, name : { first : Str } })\n```",
        },
        // A binder is its element.
        .{
            .on = "item.name",
            .expected = "```roc\nitem : { id : U64, name : { first : Str } }\n```",
        },
        .{ .on = "name.first", .expected = "```roc\nname : { first : Str }\n```" },
        .{ .on = "first |", .expected = "```roc\nfirst : Str\n```" },
        .{ .on = "upper", .expected = "`upper`: the Str in upper case." },
        .{ .on = "{{ n |", .expected = "```roc\nn : List(Str)\n```" },
        .{
            .on = "Top}}",
            .expected = "`Top.rocstache`, copied in here: its tags read the names in " ++
                "scope here, and were checked against them.",
        },
        .{
            .on = "$Row",
            .expected = "The fragment `Page.Row`: rendered here, and alone by " ++
                "`Page.Row.template`, from what it reads:\n" ++
                "```roc\nPage.Row.Ctx : { name : { first : Str } }\n```",
        },
    };
    for (cases) |case| {
        const offset: u32 = @intCast(std.mem.indexOf(u8, page, case.on).? + 1);
        const text = (try hover(arena, result, offset)).?;
        try testing.expectEqualStrings(case.expected, text);
    }
}

test "assist: no hover over text, nor in a template with a problem" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const options = [_]analysis.Options{
        .{ .path = "/app/templates/Page.rocstache", .source = "<p>{{ a }}</p>", .buffers = &.{} },
        .{ .path = "/app/templates/Page.rocstache", .source = "{{ a }}{{ a.b }}", .buffers = &.{} },
    };
    for (options) |option| {
        const result = try analysis.analyze(arena, testing.io, option);
        try testing.expectEqual(@as(?[]const u8, null), try hover(arena, result, 1));
    }
}
