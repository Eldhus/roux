//! An app's templates, generated: every `*.rocstache` in the app's
//! directory gets its module beside it (`Page.roc`: the contract and a
//! one-line `render!`, roc.zig), the contracts are laid out by Roc's
//! compiler (`roc glue`, only when one changed: layout.zig), and the build
//! directory gets the object holding every template's bytecode and text
//! (elf.zig), which the link takes as it is: a markup edit runs no
//! compiler.
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
const bytecode = @import("bytecode.zig");
const elf = @import("elf.zig");
const layout = @import("layout.zig");

pub const templates_max = 256;

pub const Options = struct {
    /// The app's directory, holding `main.roc` and its `*.rocstache`.
    app: []const u8,
    /// Where the templates' object goes (`<app>/.roux/main`), and glue's
    /// files (`glue/`).
    build: []const u8,
    /// The pinned `roc`, for glue.
    roc: []const u8,
};

/// The object's name in the build directory.
pub const object_name = "templates.o";

pub const Result = struct {
    templates: u32,
    /// Some `Page.roc` changed: the app's Roc must be built again.
    modules_changed: bool,
    /// The templates' object changed: the app must be linked again.
    object_changed: bool,
};

pub const Error = error{Invalid} || Allocator.Error || Io.Dir.ReadFileAllocError ||
    Io.Dir.WriteFileError || Io.Dir.RenameError || Io.Dir.CreateDirPathError ||
    Io.Dir.OpenError || Io.Dir.Iterator.Error || Io.Writer.Error;

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

    var result: Result = .{
        .templates = @intCast(loaded.len),
        .modules_changed = false,
        .object_changed = false,
    };
    try compute_contracts(gpa, loaded, templates, errors);
    const contracts = try gpa.alloc(layout.Contract, loaded.len);
    for (loaded, templates, contracts, 0..) |l, t, *c, index| {
        c.* = .{ .index = @intCast(index), .contract = t.contract.? };
        var text: Io.Writer.Allocating = .init(gpa);
        const module: roc.Module = .{
            .name = l.name,
            .contract = t.contract.?,
            .index = @intCast(index),
        };
        try roc.write_module(module, &text.writer);
        const path = try std.fmt.allocPrint(gpa, "{s}.roc", .{l.name});
        if (try write_if_changed(gpa, io, app, path, text.written())) result.modules_changed = true;
    }

    try cwd.createDirPath(io, options.build);
    var build = try cwd.openDir(io, options.build, .{});
    defer build.close(io);
    const layouts = try glue(gpa, io, build, options, contracts, errors);
    const compiled = try gpa.alloc(bytecode.Template, loaded.len);
    for (templates, compiled, 0..) |t, *c, index| {
        const root = layouts.root(index) orelse bytecode.nothing;
        c.* = .{ .name = t.name, .tree = t.tree, .root = root };
    }
    var builder: bytecode.Builder = .{ .gpa = gpa };
    var diagnostic: bytecode.Diagnostic = .{};
    bytecode.program(&builder, &layouts, compiled, &diagnostic) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => {
            const source = for (templates) |t| {
                if (std.mem.eql(u8, t.name, diagnostic.template)) break t.source;
            } else unreachable;
            try report(errors, source, .{
                .template = diagnostic.template,
                .offset = diagnostic.offset,
                .message = diagnostic.message,
                .subject = diagnostic.subject,
            });
            return error.Invalid;
        },
    };
    var object: Io.Writer.Allocating = .init(gpa);
    try elf.write(builder.code.items, builder.text.items, &object.writer);
    result.object_changed = try write_if_changed(gpa, io, build, object_name, object.written());
    return result;
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

/// Every template's contract, a called partial's before its callers' (they
/// take its contract as a field's type): passes over the templates, each
/// computing those whose calls are known, until all are, or a pass
/// computes none (partials that call each other).
fn compute_contracts(
    gpa: Allocator,
    loaded: []const Loaded,
    templates: []contract_.Template,
    errors: *Io.Writer,
) Error!void {
    const done = try gpa.alloc(bool, loaded.len);
    @memset(done, false);
    var remaining = loaded.len;
    for (0..loaded.len + 1) |_| {
        if (remaining == 0) return;
        var progressed = false;
        for (loaded, 0..) |l, index| {
            if (done[index] or !calls_known(templates, l.tree, 0)) continue;
            templates[index].contract = try contract_of(gpa, templates, index, errors);
            done[index] = true;
            remaining -= 1;
            progressed = true;
        }
        if (!progressed) break;
    }
    try errors.writeAll("partials call each other, so no contract comes first:");
    for (loaded, done) |l, d| if (!d) try errors.print(" {s}", .{l.name});
    try errors.writeAll("\n");
    return error.Invalid;
}

/// Whether every partial a tree calls (through the partials it inlines,
/// too) has its contract. One that does not exist counts as known: the
/// contract's check reports it.
fn calls_known(templates: []const contract_.Template, tree: *const parse.Tree, depth: u8) bool {
    if (depth > contract_.partial_depth_max) return true; // the check reports the depth
    for (tree.slice()) |node| {
        if (node.kind != .partial) continue;
        const target = for (templates) |t| {
            if (std.mem.eql(u8, t.name, node.text)) break t;
        } else continue;
        if (node.called()) {
            if (target.contract == null) return false;
        } else if (!calls_known(templates, target.tree, depth + 1)) return false;
    }
    return true;
}

/// Template `index`'s contract, checked.
fn contract_of(
    gpa: Allocator,
    templates: []contract_.Template,
    index: usize,
    errors: *Io.Writer,
) Error!*const contract_.Contract {
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
    return contract;
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

/// The contracts' layouts: the throwaway platform written, and `roc glue`
/// run on it with layout.zig's spec when a contract changed (or its
/// output is missing). `--no-cache`: glue's cache runs whichever spec it
/// compiled first (roc-lang/roc#12139).
fn glue(
    gpa: Allocator,
    io: Io,
    build: Io.Dir,
    options: Options,
    contracts: []const layout.Contract,
    errors: *Io.Writer,
) Error!layout.Layouts {
    try build.createDirPath(io, "glue");
    var platform: Io.Writer.Allocating = .init(gpa);
    try layout.write_platform(contracts, &platform.writer);
    var declared: Io.Writer.Allocating = .init(gpa);
    try layout.write_contracts(contracts, &declared.writer);
    // The layouts are the compiler's: a new spec or another roc (a nightly
    // bump; its path names it) lays them out again, as a contract does.
    const spec_changed = try write_if_changed(gpa, io, build, "glue/Layout.roc", layout.spec);
    const roc_changed = try write_if_changed(gpa, io, build, "glue/roc", options.roc);
    _ = try write_if_changed(gpa, io, build, "glue/main.roc", platform.written());
    const contracts_changed =
        try write_if_changed(gpa, io, build, "glue/Contracts.roc", declared.written());
    const changed = spec_changed or roc_changed or contracts_changed;
    const zon = "glue/layouts.zon";
    const present = if (build.access(io, zon, .{})) true else |_| false;
    if (changed or !present) {
        const spec = try std.fmt.allocPrint(gpa, "{s}/glue/Layout.roc", .{options.build});
        const output = try std.fmt.allocPrint(gpa, "{s}/glue/out", .{options.build});
        const main = try std.fmt.allocPrint(gpa, "{s}/glue/main.roc", .{options.build});
        const result = std.process.run(gpa, io, .{
            .argv = &.{ options.roc, "glue", "--no-cache", spec, output, main },
            .stdout_limit = .limited(1 << 20),
            .stderr_limit = .limited(1 << 20),
        }) catch |err| {
            try errors.print("roc glue ({s}) could not run: {t}\n", .{ options.roc, err });
            return error.Invalid;
        };
        if (!result.term.success()) {
            try errors.print("roc glue failed on the contracts:\n{s}{s}", .{
                result.stdout,
                result.stderr,
            });
            // Its Contracts.roc goes, so the next run tries again.
            build.deleteFile(io, "glue/Contracts.roc") catch {};
            return error.Invalid;
        }
        const out = "glue/out/layouts.zon";
        const written = try build.readFileAlloc(io, out, gpa, .limited(16 << 20));
        _ = try write_if_changed(gpa, io, build, zon, written);
    }
    const source = try build.readFileAllocOptions(io, zon, gpa, .limited(16 << 20), .of(u8), 0);
    return layout.parse(gpa, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => {
            try errors.print("{s}/{s}: not the layouts roux's glue spec writes\n", .{
                options.build,
                zon,
            });
            build.deleteFile(io, "glue/Contracts.roc") catch {};
            return error.Invalid;
        },
    };
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
