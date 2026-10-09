//! An app's templates, generated: every `*.rocstache` in the app's
//! directory gets its module beside it (`Page.roc`: the contract and a
//! one-line `render!`, roc.zig), the contracts are laid out by Roc's
//! compiler (`roc glue`, only when one changed: layout.zig), and the build
//! directory gets the program, every template's bytecode and text, as an
//! object the link takes (elf.zig) and alone (`templates.bin`, which `roux
//! dev` has a running app reread): a markup edit runs no compiler.
//!
//! Each template is parsed, given its contract and compiled on its own, so
//! a long-lived caller keeps them (cache.zig) and an edit redoes only what
//! it touched: the edited template, and those whose contract or code is
//! made from it. The program is assembled from the templates' chunks.
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
const cache_ = @import("cache.zig");
const Kept = cache_.Kept;

pub const templates_max = 256;

pub const Options = struct {
    /// The app's directory, holding `main.roc` and its `*.rocstache`.
    app: []const u8,
    /// Where the templates' object goes (`<app>/.roux/main`), and glue's
    /// files (`glue/`).
    build: []const u8,
    /// The pinned `roc`, for glue.
    roc: []const u8,
    /// What a long-lived caller (`roux dev`) keeps between generations
    /// (cache.zig); null for one generation alone.
    cache: ?*Cache = null,
    /// Whether to write the object only when the layouts change: `roux
    /// dev`, whose app reads `templates.bin` and links the object only for
    /// a Roc change. Its layouts' identity must stay the linked one's.
    object_on_layouts_only: bool = false,
    /// The templates whose files changed since the last generation, by
    /// name (inotify told `roux dev`); the others' kept sources are theirs.
    /// Null: read every one, and list the directory.
    changed: ?[]const []const u8 = null,
};

pub const Cache = cache_.Cache;

/// The object's name in the build directory.
pub const object_name = "templates.o";
/// The same program alone, which `roux dev` has a running app reread.
pub const program_name = "templates.bin";

pub const Result = struct {
    templates: u32,
    /// Some `Page.roc` changed: the app's Roc must be built again.
    modules_changed: bool,
    /// The program changed: a running app must reread it (or be linked).
    program_changed: bool,
};

pub const Error = error{Invalid} || Allocator.Error || Io.Dir.ReadFileAllocError ||
    Io.Dir.WriteFileError || Io.Dir.RenameError || Io.Dir.CreateDirPathError ||
    Io.Dir.OpenError || Io.Dir.Iterator.Error || Io.Writer.Error;

/// Generates everything; a template's mistake is printed to `errors` as
/// `Page.rocstache:12:5: ...` and returns `error.Invalid`. `gpa` is used
/// as an arena: what is kept goes in the cache's own allocator.
pub fn generate(gpa: Allocator, io: Io, options: Options, errors: *Io.Writer) Error!Result {
    var alone: Cache = .init(gpa);
    const cache = options.cache orelse &alone;
    const result = generate_with(gpa, io, options, cache, errors) catch |err| {
        cache.forget();
        return err;
    };
    try cache.settle();
    return result;
}

fn generate_with(
    gpa: Allocator,
    io: Io,
    options: Options,
    cache: *Cache,
    errors: *Io.Writer,
) Error!Result {
    const cwd = Io.Dir.cwd();
    var app = try cwd.openDir(io, options.app, .{ .iterate = true });
    defer app.close(io);
    const names = try names_of(gpa, io, app, options, cache, errors);
    // Every name kept first: the map may move as it grows, then never.
    for (names) |name| _ = try cache.kept(name);
    const kept = try gpa.alloc(*Kept, names.len);
    const templates = try gpa.alloc(contract_.Template, names.len);
    for (names, kept, templates) |name, *k, *t| {
        k.* = cache.templates.getPtr(name).?;
        if (unchanged(options, k.*)) {
            k.*.seen = true;
        } else {
            try load(gpa, io, app, cache, k.*, errors);
        }
        t.* = .{ .name = k.*.name, .source = k.*.source, .tree = k.*.tree.? };
    }
    var result: Result = .{
        .templates = @intCast(names.len),
        .modules_changed = false,
        .program_changed = false,
    };
    try compute_contracts(gpa, cache, kept, templates, errors);
    const contracts = try gpa.alloc(layout.Contract, names.len);
    for (kept, contracts, 0..) |k, *c, index| {
        c.* = .{ .index = @intCast(index), .contract = k.contract.? };
        const changed = try write_module(gpa, io, app, cache, k, @intCast(index));
        if (changed) result.modules_changed = true;
    }
    try cwd.createDirPath(io, options.build);
    var build = try cwd.openDir(io, options.build, .{});
    defer build.close(io);
    const laid = try glue(gpa, io, build, options, cache, kept, contracts, errors);
    const chunks = try compile(gpa, cache, kept, templates, &laid, errors);
    const program = try bytecode.assemble(gpa, chunks);
    result.program_changed = try write_program(gpa, io, build, options, cache, .{
        .code = program.code,
        .text = program.text,
        .layouts = laid.id,
    });
    return result;
}

/// The program as the file roux dev has a running app reread, and as the
/// object the link takes (with `object_on_layouts_only`, only when the
/// layouts changed); says whether the program changed.
fn write_program(
    gpa: Allocator,
    io: Io,
    build: Io.Dir,
    options: Options,
    cache: *Cache,
    made: elf.Program,
) Error!bool {
    var program: Io.Writer.Allocating = .init(gpa);
    try elf.write_program(made, &program.writer);
    const bytes = program.written();
    const changed = try write_output(cache, gpa, io, build, "build", program_name, bytes);
    if (!options.object_on_layouts_only or cache.object_layouts != made.layouts) {
        var object: Io.Writer.Allocating = .init(gpa);
        try elf.write(made, &object.writer);
        _ = try write_output(cache, gpa, io, build, "build", object_name, object.written());
        cache.object_layouts = made.layouts;
    }
    return changed;
}

/// The templates' names: the kept listing, when the caller says which
/// files changed and each of them is in it (an edit, not a new template);
/// else the directory listed again, and kept.
fn names_of(
    gpa: Allocator,
    io: Io,
    app: Io.Dir,
    options: Options,
    cache: *Cache,
    errors: *Io.Writer,
) Error![]const []const u8 {
    if (options.changed) |changed| {
        if (cache.names.items.len > 0) {
            const all_known = for (changed) |name| {
                if (!contains(cache.names.items, name)) break false;
            } else true;
            if (all_known) return cache.names.items;
        }
    }
    const names = try template_names(gpa, io, app, errors);
    try cache.keep_names(names);
    return names;
}

/// Whether a kept template's file is known not to have changed.
fn unchanged(options: Options, k: *const Kept) bool {
    const changed = options.changed orelse return false;
    return k.tree != null and !contains(changed, k.name);
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Every `*.rocstache` in the app's directory, by name, sorted.
fn template_names(
    gpa: Allocator,
    io: Io,
    app: Io.Dir,
    errors: *Io.Writer,
) Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var iterator = app.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".rocstache")) continue;
        if (names.items.len == templates_max) {
            try errors.print("more than {d} templates\n", .{templates_max});
            return error.Invalid;
        }
        const name = entry.name[0 .. entry.name.len - ".rocstache".len];
        if (!parse.is_type_name(name)) {
            try errors.print("{s}: a template's name is a Roc type name, like `Page`\n", .{
                entry.name,
            });
            return error.Invalid;
        }
        try names.append(gpa, try gpa.dupe(u8, name));
    }
    std.mem.sort([]const u8, names.items, {}, string_less);
    return names.items;
}

fn string_less(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// A template's source read, and parsed unless it is the one kept.
fn load(
    gpa: Allocator,
    io: Io,
    app: Io.Dir,
    cache: *Cache,
    k: *Kept,
    errors: *Io.Writer,
) Error!void {
    const file = try std.fmt.allocPrint(gpa, "{s}.rocstache", .{k.name});
    const source = try app.readFileAlloc(io, file, gpa, .limited(parse.source_bytes_max));
    const hash = std.hash.Wyhash.hash(0, source);
    k.seen = true;
    if (k.tree != null and k.source_hash == hash) return;
    const owned = try cache.gpa.dupe(u8, source);
    errdefer cache.gpa.free(owned);
    const tree = try cache_.create_unfilled(cache.gpa, parse.Tree);
    errdefer cache_.destroy_unfilled(cache.gpa, tree);
    var diagnostic: parse.Diagnostic = .{};
    parse.parse(owned, tree, &diagnostic) catch {
        try report(errors, owned, .{
            .template = k.name,
            .offset = diagnostic.offset,
            .subject = diagnostic.subject,
            .message = diagnostic.message,
        });
        return error.Invalid;
    };
    if (k.source.len > 0) try cache.retire(.{ .source = k.source });
    if (k.tree) |old| try cache.retire(.{ .tree = old });
    k.source = owned;
    k.source_hash = hash;
    k.tree = tree;
}

/// Every template's contract, a called partial's before its callers' (they
/// take its contract as a field's type): passes over the templates, each
/// computing those whose calls are known, until all are, or a pass
/// computes none (partials that call each other). One whose key is the
/// kept one's is kept.
fn compute_contracts(
    gpa: Allocator,
    cache: *Cache,
    kept: []const *Kept,
    templates: []contract_.Template,
    errors: *Io.Writer,
) Error!void {
    const done = try gpa.alloc(bool, kept.len);
    @memset(done, false);
    var remaining = kept.len;
    for (0..kept.len + 1) |_| {
        if (remaining == 0) return;
        var progressed = false;
        for (kept, 0..) |k, index| {
            if (done[index] or !calls_known(templates, k.tree.?, 0)) continue;
            const key = contract_key(kept, templates, index);
            if (k.contract == null or k.contract_key != key) {
                const fresh = try contract_of(gpa, cache, templates, index, errors);
                if (k.contract) |old| try cache.retire(.{ .contract = old });
                k.contract = fresh;
                k.contract_key = key;
            }
            templates[index].contract = k.contract;
            done[index] = true;
            remaining -= 1;
            progressed = true;
        }
        if (!progressed) break;
    }
    try errors.writeAll("partials call each other, so no contract comes first:");
    for (kept, done) |k, d| if (!d) try errors.print(" {s}", .{k.name});
    try errors.writeAll("\n");
    return error.Invalid;
}

/// What a template's contract is made from: its source, the sources of the
/// partials it inlines (through theirs), the contracts of those it calls.
fn contract_key(kept: []const *Kept, templates: []const contract_.Template, index: usize) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(kept[index].name);
    reach(kept, templates, index, 0, &hasher, .contract);
    return hasher.final();
}

/// What a template's code is made from: its source and the sources of the
/// partials it inlines; a call is an index, which the layouts' identity
/// covers (it hashes the templates' names), with the layouts themselves.
fn chunk_key(
    kept: []const *Kept,
    templates: []const contract_.Template,
    index: usize,
    layouts: u64,
) u64 {
    var hasher = std.hash.Wyhash.init(layouts);
    hasher.update(std.mem.asBytes(&index));
    reach(kept, templates, index, 0, &hasher, .code);
    return hasher.final();
}

/// Hashes a template's source hash, then each partial it names: inlined,
/// its source and its partials (bounded as the contract bounds them);
/// called, its contract's key (for a contract) or its name (for code); one
/// that does not exist, its name (the contract's check reports it).
fn reach(
    kept: []const *Kept,
    templates: []const contract_.Template,
    index: usize,
    depth: u8,
    hasher: *std.hash.Wyhash,
    comptime what: enum { contract, code },
) void {
    hasher.update(std.mem.asBytes(&kept[index].source_hash));
    if (depth > contract_.partial_depth_max) return;
    for (kept[index].tree.?.slice()) |node| {
        if (node.kind != .partial) continue;
        hasher.update(node.text);
        hasher.update(if (node.called()) "c" else "i");
        const target = for (templates, 0..) |t, k| {
            if (std.mem.eql(u8, t.name, node.text)) break k;
        } else continue;
        if (!node.called()) {
            reach(kept, templates, target, depth + 1, hasher, what);
        } else if (what == .contract) {
            hasher.update(std.mem.asBytes(&kept[target].contract_key));
        }
    }
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

/// Template `index`'s contract, checked, in the cache's memory.
fn contract_of(
    gpa: Allocator,
    cache: *Cache,
    templates: []contract_.Template,
    index: usize,
    errors: *Io.Writer,
) Error!*contract_.Contract {
    // contract.of takes the template first, the partials it may include after.
    const ordered = try gpa.dupe(contract_.Template, templates);
    std.mem.swap(contract_.Template, &ordered[0], &ordered[index]);
    const contract = try cache_.create_unfilled(cache.gpa, contract_.Contract);
    errdefer cache_.destroy_unfilled(cache.gpa, contract);
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

/// A template's `Page.roc`, unless its contract and place are what they
/// were when it was last written; says whether the file changed.
fn write_module(
    gpa: Allocator,
    io: Io,
    app: Io.Dir,
    cache: *Cache,
    k: *Kept,
    index: u32,
) Error!bool {
    var hasher = std.hash.Wyhash.init(k.contract_key);
    hasher.update(std.mem.asBytes(&index));
    const key = hasher.final();
    if (k.module_key == key) return false;
    var text: Io.Writer.Allocating = .init(gpa);
    const module: roc.Module = .{ .name = k.name, .contract = k.contract.?, .index = index };
    try roc.write_module(module, &text.writer);
    const path = try std.fmt.allocPrint(gpa, "{s}.roc", .{k.name});
    const changed = try write_output(cache, gpa, io, app, "app", path, text.written());
    k.module_key = key;
    return changed;
}

/// Every template's chunk, compiled unless its key is the kept one's.
fn compile(
    gpa: Allocator,
    cache: *Cache,
    kept: []const *Kept,
    templates: []const contract_.Template,
    laid: *const Laid,
    errors: *Io.Writer,
) Error![]const bytecode.Chunk {
    const compiled = try gpa.alloc(bytecode.Template, kept.len);
    for (templates, compiled, 0..) |t, *c, index| {
        const root = laid.layouts.root(index) orelse bytecode.nothing;
        c.* = .{ .name = t.name, .tree = t.tree, .root = root };
    }
    const chunks = try gpa.alloc(bytecode.Chunk, kept.len);
    for (kept, chunks, 0..) |k, *chunk, index| {
        const key = chunk_key(kept, templates, index, laid.id);
        if (k.chunk == null or k.chunk_key != key) {
            const fresh = try compile_one(cache, laid, templates, compiled, index, errors);
            if (k.chunk) |old| try cache.retire(.{ .chunk = old });
            k.chunk = fresh;
            k.chunk_key = key;
        }
        chunk.* = k.chunk.?;
    }
    return chunks;
}

/// Template `index` compiled, in the cache's memory; its mistake reported.
fn compile_one(
    cache: *Cache,
    laid: *const Laid,
    templates: []const contract_.Template,
    compiled: []const bytecode.Template,
    index: usize,
    errors: *Io.Writer,
) Error!bytecode.Chunk {
    var diagnostic: bytecode.Diagnostic = .{};
    return bytecode.compile(cache.gpa, &laid.layouts, compiled, index, &diagnostic) catch |err|
        switch (err) {
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
    cache: *Cache,
    kept: []const *Kept,
    contracts: []const layout.Contract,
    errors: *Io.Writer,
) Error!Laid {
    // Every contract's key the same as last time: so are the layouts.
    var inputs = std.hash.Wyhash.init(0);
    inputs.update(options.roc);
    for (kept) |k| {
        inputs.update(k.name);
        inputs.update(std.mem.asBytes(&k.contract_key));
    }
    const laid_key = inputs.final();
    if (cache.layouts) |layouts| {
        if (cache.laid_key == laid_key) return .{ .layouts = layouts, .id = cache.laid_id };
    }
    const laid = try lay_out(gpa, io, build, options, cache, kept, contracts, errors);
    cache.laid_key = laid_key;
    cache.laid_id = laid.id;
    return laid;
}

fn lay_out(
    gpa: Allocator,
    io: Io,
    build: Io.Dir,
    options: Options,
    cache: *Cache,
    kept: []const *Kept,
    contracts: []const layout.Contract,
    errors: *Io.Writer,
) Error!Laid {
    try build.createDirPath(io, "glue");
    var platform: Io.Writer.Allocating = .init(gpa);
    try layout.write_platform(contracts, &platform.writer);
    var declared: Io.Writer.Allocating = .init(gpa);
    try layout.write_contracts(contracts, &declared.writer);
    var identity = std.hash.Wyhash.init(0);
    identity.update(layout.spec);
    identity.update(options.roc);
    identity.update(declared.written());
    for (kept) |k| identity.update(k.name);
    const id = identity.final();
    // The layouts are the compiler's: a new spec or another roc (a nightly
    // bump; its path names it) lays them out again, as a contract does.
    const c = cache;
    const spec_changed =
        try write_output(c, gpa, io, build, "build", "glue/Layout.roc", layout.spec);
    const roc_changed = try write_output(c, gpa, io, build, "build", "glue/roc", options.roc);
    _ = try write_output(c, gpa, io, build, "build", "glue/main.roc", platform.written());
    const contracts_changed =
        try write_output(c, gpa, io, build, "build", "glue/Contracts.roc", declared.written());
    const changed = spec_changed or roc_changed or contracts_changed;
    const zon = "glue/layouts.zon";
    if (!changed) {
        if (cache.layouts) |layouts| return .{ .layouts = layouts, .id = id };
    }
    const present = if (build.access(io, zon, .{})) true else |_| false;
    if (changed or !present) try run_glue(gpa, io, build, options, cache, errors);
    // Parsed into the cache's memory, to keep.
    cache.layouts = null;
    _ = cache.arena.reset(.retain_capacity);
    const memory = cache.arena.allocator();
    const source = try build.readFileAllocOptions(io, zon, memory, .limited(16 << 20), .of(u8), 0);
    const layouts = layout.parse(memory, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => {
            try errors.print("{s}/{s}: not the layouts roux's glue spec writes\n", .{
                options.build,
                zon,
            });
            glue_again(io, build, cache);
            return error.Invalid;
        },
    };
    cache.layouts = layouts;
    return .{ .layouts = layouts, .id = id };
}

/// The contracts' layouts, and their identity: a hash of what glue lays
/// them out from (the spec, the roc, the contracts) and of the templates'
/// names, which the program carries so the host rereads only a program
/// its Roc was built for.
const Laid = struct { layouts: layout.Layouts, id: u64 };

/// After glue failed: its Contracts.roc goes (from the cache too), so the
/// next generation runs glue again rather than read old layouts.
fn glue_again(io: Io, build: Io.Dir, cache: *Cache) void {
    build.deleteFile(io, "glue/Contracts.roc") catch {};
    cache.layouts = null;
    if (cache.written.fetchRemove("build/glue/Contracts.roc")) |entry| cache.gpa.free(entry.key);
}

/// `roc glue` with roux's spec on the throwaway platform: `layouts.zon`.
fn run_glue(
    gpa: Allocator,
    io: Io,
    build: Io.Dir,
    options: Options,
    cache: *Cache,
    errors: *Io.Writer,
) Error!void {
    const spec = try std.fmt.allocPrint(gpa, "{s}/glue/Layout.roc", .{options.build});
    const output = try std.fmt.allocPrint(gpa, "{s}/glue/out", .{options.build});
    const main = try std.fmt.allocPrint(gpa, "{s}/glue/main.roc", .{options.build});
    const result = std.process.run(gpa, io, .{
        .argv = &.{ options.roc, "glue", "--no-cache", spec, output, main },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |err| {
        try errors.print("roc glue ({s}) could not run: {t}\n", .{ options.roc, err });
        glue_again(io, build, cache);
        return error.Invalid;
    };
    if (!result.term.success()) {
        try errors.print("roc glue failed on the contracts:\n{s}{s}", .{
            result.stdout,
            result.stderr,
        });
        glue_again(io, build, cache);
        return error.Invalid;
    }
    const out = "glue/out/layouts.zon";
    const written = try build.readFileAlloc(io, out, gpa, .limited(16 << 20));
    _ = try write_if_changed(gpa, io, build, "glue/layouts.zon", written);
}

/// `write_if_changed`, remembering what it wrote in `cache` (keyed by the
/// directory's role and the path): an output the same as last time costs a
/// hash.
fn write_output(
    cache: *Cache,
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    role: []const u8,
    path: []const u8,
    data: []const u8,
) Error!bool {
    const hash = std.hash.Wyhash.hash(0, data);
    const key = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ role, path });
    const known = cache.written.get(key);
    if (known) |old| if (old == hash) return false;
    // Known and different: written without reading the old back.
    const changed = if (known != null) blk: {
        try write_replacing(gpa, io, dir, path, data);
        break :blk true;
    } else try write_if_changed(gpa, io, dir, path, data);
    const entry = try cache.written.getOrPut(cache.gpa, key);
    if (!entry.found_existing) entry.key_ptr.* = try cache.gpa.dupe(u8, key);
    entry.value_ptr.* = hash;
    return changed;
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
    try write_replacing(gpa, io, dir, path, data);
    return true;
}

/// Writes `data` to a temporary name, then renames it over `path`.
fn write_replacing(
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    path: []const u8,
    data: []const u8,
) Error!void {
    const temporary = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    try dir.writeFile(io, .{ .sub_path = temporary, .data = data });
    try dir.rename(temporary, dir, path, io);
}
