//! An app's templates, generated: every `*.rocstache` in the app's
//! directory gets its contract module beside it (`Page.roc`), and the
//! build directory gets what the templates object compiles from: the
//! renderer's source, a copy of each template, the registry, and the
//! contracts' layout from `roc glue`, run only when a contract changed.
//!
//! A file is written only when its content changes (to a temporary name,
//! then renamed), so a markup edit rewrites nothing the app's Roc sees,
//! and a reader never sees half a file.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");
const contract_ = @import("contract.zig");
const roc = @import("roc.zig");

pub const templates_max = 256;

/// The renderer's source, written into the build directory.
const renderer = [_]struct { name: []const u8, text: []const u8 }{
    .{ .name = "object.zig", .text = @embedFile("object.zig") },
    .{ .name = "part.zig", .text = @embedFile("part.zig") },
    .{ .name = "symbols.zig", .text = @embedFile("symbols.zig") },
    .{ .name = "render.zig", .text = @embedFile("render.zig") },
    .{ .name = "parse.zig", .text = @embedFile("parse.zig") },
    .{ .name = "out.zig", .text = @embedFile("out.zig") },
};

/// An object to compile, and the hash of all that goes into it: the build
/// compiles it only when no object by that hash exists.
pub const Object = struct {
    /// The root file in the build directory: `object.zig`, `part_Page.zig`.
    root: []const u8,
    hash: u64,
};

pub const Options = struct {
    /// The app's directory, holding `main.roc` and its `*.rocstache`.
    app: []const u8,
    /// Where the templates object's sources go (`<app>/.roux/templates`).
    build: []const u8,
    /// The pinned `roc`, for glue.
    roc: []const u8,
    /// roc's `ZigGlue.roc` at the pinned nightly's commit.
    glue_spec: []const u8,
};

pub const Result = struct {
    templates: u32,
    /// Some `Page.roc` changed: the app's Roc must be built again.
    modules_changed: bool,
    contracts_changed: bool,
    /// The dispatcher first, then a part per template.
    objects: []const Object,
};

pub const Error = error{ Invalid, GlueFailed } || Allocator.Error || Io.Dir.ReadFileAllocError ||
    Io.Dir.WriteFileError || Io.Dir.RenameError || Io.Dir.CreateDirPathError ||
    Io.Dir.OpenError || Io.Dir.Iterator.Error || std.process.RunError || Io.Writer.Error;

/// A template as read: its name (the file's stem), source and tree.
const Loaded = struct {
    name: []const u8,
    source: []const u8,
    tree: *parse.Tree,
};

/// Generates everything; a template's mistake is printed to `errors` as
/// `Page.rocstache:12:5: ...` and returns `error.Invalid`.
pub fn generate(gpa: Allocator, io: Io, options: Options, errors: *Io.Writer) Error!Result {
    const cwd = Io.Dir.cwd();
    var app = try cwd.openDir(io, options.app, .{ .iterate = true });
    defer app.close(io);
    const loaded = try load(gpa, io, app, errors);
    const templates = try gpa.alloc(contract_.Template, loaded.len);
    for (loaded, templates) |l, *t| t.* = .{ .name = l.name, .source = l.source, .tree = l.tree };

    const modules = try gpa.alloc(roc.Module, loaded.len);
    var result: Result = .{
        .templates = @intCast(loaded.len),
        .modules_changed = false,
        .contracts_changed = false,
        .objects = &.{},
    };
    for (loaded, modules, 0..) |l, *module, index| {
        module.* = try module_of(gpa, templates, index, errors);
        var text: Io.Writer.Allocating = .init(gpa);
        try roc.write_module(module.*, &text.writer);
        const path = try std.fmt.allocPrint(gpa, "{s}.roc", .{l.name});
        if (try write_if_changed(gpa, io, app, path, text.written())) result.modules_changed = true;
    }

    try cwd.createDirPath(io, options.build);
    var build = try cwd.openDir(io, options.build, .{});
    defer build.close(io);
    try build.createDirPath(io, "glue");
    for (renderer) |file| _ = try write_if_changed(gpa, io, build, file.name, file.text);
    for (loaded) |l| {
        const copy = try std.fmt.allocPrint(gpa, "{s}.rocstache", .{l.name});
        _ = try write_if_changed(gpa, io, build, copy, l.source);
    }
    var registry: Io.Writer.Allocating = .init(gpa);
    try roc.write_registry(modules, &registry.writer);
    _ = try write_if_changed(gpa, io, build, "templates.zig", registry.written());
    result.contracts_changed = try glue(gpa, io, build, options, modules, errors);
    result.objects = try objects(gpa, io, build, loaded, registry.written());
    return result;
}

/// The dispatcher and a part per template, each with the hash of what it
/// compiles from: the renderer, the registry and the glue (the contracts'
/// layout), and for a part its template and every partial it reaches.
fn objects(
    gpa: Allocator,
    io: Io,
    build: Io.Dir,
    loaded: []const Loaded,
    registry: []const u8,
) Error![]const Object {
    var common = std.hash.Wyhash.init(0);
    for (renderer) |file| common.update(file.text);
    common.update(registry);
    const glue_path = "glue/roc_platform_abi.zig";
    common.update(try build.readFileAlloc(io, glue_path, gpa, .limited(16 << 20)));
    const result = try gpa.alloc(Object, loaded.len + 1);
    result[0] = .{ .root = "object.zig", .hash = common.final() };
    for (loaded, result[1..], 0..) |l, *object, index| {
        const root = try std.fmt.allocPrint(gpa, "part_{s}.zig", .{l.name});
        const text = try std.fmt.allocPrint(gpa,
            \\//! Generated by roux build. DO NOT EDIT. `{s}`'s part of the app's
            \\//! templates, compiled alone (part.zig).
            \\pub const index = {d};
            \\pub const panic = @import("symbols.zig").panic;
            \\comptime {{
            \\    _ = @import("part.zig");
            \\}}
            \\
        , .{ l.name, index });
        _ = try write_if_changed(gpa, io, build, root, text);
        var hash = common;
        hash.update(text);
        reach(loaded, l, &hash, 0);
        object.* = .{ .root = root, .hash = hash.final() };
    }
    return result;
}

/// Hashes `template` and the partials it includes, transitively (the
/// contract has checked their depth). A partial included twice is hashed
/// twice: the hash is still the content's.
fn reach(loaded: []const Loaded, template: Loaded, hash: *std.hash.Wyhash, depth: u8) void {
    assert(depth <= contract_.partial_depth_max);
    hash.update(template.name);
    hash.update(template.source);
    for (template.tree.slice()) |node| {
        if (node.kind != .partial) continue;
        for (loaded) |other| {
            if (std.mem.eql(u8, other.name, node.text)) reach(loaded, other, hash, depth + 1);
        }
    }
}

/// Every `*.rocstache` in the app's directory, sorted by name, parsed.
fn load(gpa: Allocator, io: Io, app: Io.Dir, errors: *Io.Writer) Error![]const Loaded {
    var names: std.ArrayList([]const u8) = .empty;
    var iterator = app.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".rocstache")) continue;
        if (names.items.len == templates_max) {
            try errors.print("more than {d} templates\n", .{templates_max});
            return error.Invalid;
        }
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, string_less);
    const loaded = try gpa.alloc(Loaded, names.items.len);
    for (names.items, loaded) |file, *l| {
        const name = file[0 .. file.len - ".rocstache".len];
        if (!parse.is_type_name(name)) {
            try errors.print("{s}: a template's name is a Roc type name, like `Page`\n", .{file});
            return error.Invalid;
        }
        const source = try app.readFileAlloc(io, file, gpa, .limited(parse.source_bytes_max));
        const tree = try gpa.create(parse.Tree);
        var diagnostic: parse.Diagnostic = .{};
        parse.parse(source, tree, &diagnostic) catch {
            try report(errors, source, .{
                .template = name,
                .offset = diagnostic.offset,
                .subject = diagnostic.subject,
                .message = diagnostic.message,
            });
            return error.Invalid;
        };
        l.* = .{ .name = name, .source = source, .tree = tree };
    }
    return loaded;
}

fn string_less(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Template `index`'s contract, checked, as its module.
fn module_of(
    gpa: Allocator,
    templates: []contract_.Template,
    index: usize,
    errors: *Io.Writer,
) Error!roc.Module {
    // contract.of takes the template first, the partials it may include after.
    const ordered = try gpa.dupe(contract_.Template, templates);
    std.mem.swap(contract_.Template, &ordered[0], &ordered[index]);
    const contract = try gpa.create(contract_.Contract);
    var diagnostic: contract_.Diagnostic = .{};
    contract_.of(contract, ordered, &diagnostic) catch {
        const source = for (templates) |t| {
            if (std.mem.eql(u8, t.name, diagnostic.template)) break t.source;
        } else ordered[0].source;
        try report(errors, source, diagnostic);
        if (!std.mem.eql(u8, diagnostic.template, ordered[0].name)) {
            try errors.print("  (included from {s}.rocstache)\n", .{ordered[0].name});
        }
        return error.Invalid;
    };
    var line: Io.Writer.Allocating = .init(gpa);
    try contract_.write_line(contract, contract.root, &line.writer);
    return .{
        .name = ordered[0].name,
        .contract = contract,
        .line = line.written(),
        .id = contract_.id(ordered[0].name, line.written()),
    };
}

/// `Page.rocstache:12:5: `title` message`, as compilers print it, so
/// editors and agents can jump to it.
fn report(
    errors: *Io.Writer,
    source: []const u8,
    problem: contract_.Diagnostic,
) Io.Writer.Error!void {
    const d: parse.Diagnostic = .{ .offset = problem.offset };
    try errors.print("{s}.rocstache:{d}:{d}: ", .{
        problem.template,
        d.line(source),
        d.column(source),
    });
    if (problem.subject.len > 0) try errors.print("`{s}` ", .{problem.subject});
    try errors.print("{s}\n", .{problem.message});
}

/// The throwaway platform, and `roc glue` on it when its contracts changed
/// (or its output is missing). Returns whether they changed.
fn glue(
    gpa: Allocator,
    io: Io,
    build: Io.Dir,
    options: Options,
    modules: []const roc.Module,
    errors: *Io.Writer,
) Error!bool {
    var contracts: Io.Writer.Allocating = .init(gpa);
    try roc.write_contracts(modules, &contracts.writer);
    var platform: Io.Writer.Allocating = .init(gpa);
    try roc.write_platform(modules, &platform.writer);
    const changed = try write_if_changed(gpa, io, build, "glue/Contracts.roc", contracts.written());
    _ = try write_if_changed(gpa, io, build, "glue/main.roc", platform.written());
    const abi = "glue/roc_platform_abi.zig";
    const present = if (build.access(io, abi, .{})) true else |_| false;
    if (!changed and present) return false;

    const output = try std.fmt.allocPrint(gpa, "{s}/glue/out", .{options.build});
    const platform_path = try std.fmt.allocPrint(gpa, "{s}/glue/main.roc", .{options.build});
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ options.roc, "glue", options.glue_spec, output, platform_path },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    if (!result.term.success()) {
        try errors.print("roc glue failed on the contracts:\n{s}{s}", .{
            result.stdout,
            result.stderr,
        });
        // Its Contracts.roc goes, so the next run tries again.
        build.deleteFile(io, "glue/Contracts.roc") catch {};
        return error.GlueFailed;
    }
    const generated_path = "glue/out/roc_platform_abi.zig";
    const generated = try build.readFileAlloc(io, generated_path, gpa, .limited(16 << 20));
    _ = try write_if_changed(gpa, io, build, abi, generated);
    return true;
}

/// Writes `data` unless the file holds exactly that already; says whether
/// it wrote. Through a temporary name and a rename.
pub fn write_if_changed(
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    path: []const u8,
    data: []const u8,
) Error!bool {
    if (dir.readFileAlloc(io, path, gpa, .limited(16 << 20))) |old| {
        if (std.mem.eql(u8, old, data)) return false;
    } else |_| {}
    const temporary = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    try dir.writeFile(io, .{ .sub_path = temporary, .data = data });
    try dir.rename(temporary, dir, path, io);
    return true;
}
