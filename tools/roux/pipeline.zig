//! The steps of building a roux app, shared by `roux build` (all of them)
//! and `roux dev` (only those an edit needs): the templates generated, then
//! roc and the templates object at once, then the link.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const options = @import("roux_options");
const rocstache = @import("rocstache");

pub const App = struct {
    /// The directory holding the app's `.roc` and its templates.
    dir: []const u8,
    /// `main.roc`.
    file: []const u8,
    /// `main`: the build directory's name.
    name: []const u8,
    /// The binary, from the working directory.
    output: []const u8,
    /// The roc to build with.
    roc: []const u8,

    pub fn of(arena: Allocator, file: []const u8, output: ?[]const u8, roc: []const u8) !App {
        assert(std.mem.endsWith(u8, file, ".roc"));
        const dir = std.fs.path.dirname(file) orelse ".";
        const name = std.fs.path.stem(file);
        return .{
            .dir = dir,
            .file = std.fs.path.basename(file),
            .name = name,
            .output = output orelse try std.fs.path.join(arena, &.{ dir, name }),
            .roc = roc,
        };
    }
};

pub const Mode = enum {
    dev,
    release,

    fn roc_opt(mode: Mode) []const u8 {
        return if (mode == .dev) "--opt=dev" else "--opt=speed";
    }

    fn zig_opt(mode: Mode) []const u8 {
        // Safe, as the host ships: bounds checked, and render's writes
        // asserted to fit what measure counted.
        return if (mode == .dev) "-ODebug" else "-OReleaseSafe";
    }
};

/// Where a build's files go, relative to the app's directory (where roc
/// runs) and to the working directory.
pub const Paths = struct {
    /// `.roux/main`, from the app's directory.
    out: []const u8,
    /// The same, from the working directory.
    out_path: []const u8,
    /// The templates object's sources, from the working directory.
    templates: []const u8,
    /// `.roux/main/app.a`, from the app's directory.
    archive: []const u8,

    pub fn of(arena: Allocator, app: App) Allocator.Error!Paths {
        const out = try std.fmt.allocPrint(arena, ".roux/{s}", .{app.name});
        const out_path = try std.fs.path.join(arena, &.{ app.dir, out });
        return .{
            .out = out,
            .out_path = out_path,
            .templates = try std.fs.path.join(arena, &.{ out_path, "templates" }),
            .archive = try std.fmt.allocPrint(arena, "{s}/app.a", .{out}),
        };
    }
};

/// Every step, timed on one line: `roux build`.
pub fn build(arena: Allocator, io: Io, app: App, mode: Mode, stderr: *Io.Writer) !void {
    const paths: Paths = try .of(arena, app);
    const start = Io.Timestamp.now(io, .awake);
    if (has_queries(io, app)) try query_types(arena, io, app);
    const generated = try generate(arena, io, paths, app, stderr);
    const generated_at = Io.Timestamp.now(io, .awake);
    const compiled = try compile(arena, io, paths, app, mode, true, generated.objects);
    const compiled_at = Io.Timestamp.now(io, .awake);
    try link(arena, io, paths, app, mode, generated.objects);
    const linked_at = Io.Timestamp.now(io, .awake);
    const line = "roux: {d} templates ({d} ms{s}), roc and {d} objects {d} ms, link {d} ms: ";
    try stderr.print(line, .{
        generated.templates,
        milliseconds(start, generated_at),
        if (generated.contracts_changed) ", contracts changed" else "",
        compiled,
        milliseconds(generated_at, compiled_at),
        milliseconds(compiled_at, linked_at),
    });
    try stderr.print("{s}\n", .{app.output});
}

/// Whether the app has a `db/` directory of queries for roux-db.
fn has_queries(io: Io, app: App) bool {
    var dir = Io.Dir.cwd().openDir(io, app.dir, .{}) catch return false;
    defer dir.close(io);
    dir.access(io, "db/schema.sql", .{}) catch return false;
    return true;
}

/// `roux-db gen db` in the app's directory: the queries' typed modules.
/// roux-db is found beside this roux (both are `zig build tools`').
pub fn query_types(arena: Allocator, io: Io, app: App) !void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const self_len = try Io.Dir.readLinkAbsolute(io, "/proc/self/exe", &buffer);
    const bin = std.fs.path.dirname(buffer[0..self_len]) orelse ".";
    const roux_db = try std.fs.path.join(arena, &.{ bin, "roux-db" });
    var child = try spawn(io, &.{ roux_db, "gen", "db" }, app.dir);
    if (!(try child.wait(io)).success()) return error.ChildFailed;
}

/// The templates' contracts and the templates object's sources.
pub fn generate(
    arena: Allocator,
    io: Io,
    paths: Paths,
    app: App,
    stderr: *Io.Writer,
) !rocstache.generate.Result {
    const glue_dir = try std.fs.path.join(arena, &.{ paths.templates, "glue" });
    try Io.Dir.cwd().createDirPath(io, glue_dir);
    var dir = try Io.Dir.cwd().openDir(io, glue_dir, .{});
    defer dir.close(io);
    const spec = @embedFile("zig_glue");
    _ = try rocstache.generate.write_if_changed(arena, io, dir, "ZigGlue.roc", spec);
    return rocstache.generate.generate(arena, io, .{
        .app = app.dir,
        .build = paths.templates,
        .roc = app.roc,
        .glue_spec = try std.fs.path.join(arena, &.{ glue_dir, "ZigGlue.roc" }),
    }, stderr);
}

/// At most this many Zig compiles at once, beside roc, in waves: a partial
/// edit recompiles every page that includes it (9 on the dragrace site).
const compiles_max = 16;

/// An object's file, by the hash of what it is compiled from and the mode:
/// `objects/part_Page-3f2a…-dev.o`, under the build directory.
fn object_name(arena: Allocator, object: Object, mode: Mode) Allocator.Error![]const u8 {
    const stem = object.root[0 .. object.root.len - ".zig".len];
    return std.fmt.allocPrint(arena, "objects/{s}-{x:0>16}-{t}.o", .{ stem, object.hash, mode });
}

pub const Object = rocstache.generate.Object;

/// roc (when `roc`) and Zig at once, neither needing the other's output:
/// Zig compiles only the objects not built before (by their hashes), at
/// most `compiles_max` at a time. Returns how many it compiled.
pub fn compile(
    arena: Allocator,
    io: Io,
    paths: Paths,
    app: App,
    mode: Mode,
    roc: bool,
    objects: []const Object,
) !u32 {
    var out = try Io.Dir.cwd().openDir(io, paths.out_path, .{});
    defer out.close(io);
    try out.createDirPath(io, "objects");
    var missing: std.ArrayList(Object) = .empty;
    for (objects) |object| {
        const name = try object_name(arena, object, mode);
        out.access(io, name, .{}) catch try missing.append(arena, object);
    }
    const output = try std.fmt.allocPrint(arena, "--output={s}", .{paths.archive});
    var roc_child: ?std.process.Child = if (roc)
        try spawn(io, &.{ app.roc, "build", mode.roc_opt(), app.file, output }, app.dir)
    else
        null;
    var zig_ok = true;
    var at: usize = 0;
    while (at < missing.items.len) : (at += compiles_max) {
        const wave = missing.items[at..@min(at + compiles_max, missing.items.len)];
        var children: [compiles_max]std.process.Child = undefined;
        for (wave, children[0..wave.len]) |object, *child| {
            const name = try object_name(arena, object, mode);
            const emit = try std.fmt.allocPrint(arena, "-femit-bin=../{s}", .{name});
            child.* = try spawn(io, &.{
                options.zig,         "build-obj",        object.root, mode.zig_opt(), "-target",
                "x86_64-linux-musl", "-fno-compiler-rt", emit,
            }, paths.templates);
        }
        for (children[0..wave.len]) |*child| {
            if (!(try child.wait(io)).success()) zig_ok = false;
        }
    }
    const roc_ok = if (roc_child) |*child| (try child.wait(io)).success() else true;
    if (!roc_ok or !zig_ok) return error.ChildFailed;
    return @intCast(missing.items.len);
}

/// roc's archive and the objects, into the output: a new file renamed
/// over the old, so a running binary is not overwritten. Objects of
/// earlier builds no longer named are deleted.
pub fn link(
    arena: Allocator,
    io: Io,
    paths: Paths,
    app: App,
    mode: Mode,
    objects: []const Object,
) !void {
    const linked = try std.fmt.allocPrint(arena, "{s}.new", .{app.output});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ options.zig, "ld.lld", "-static", "-o", linked });
    try argv.append(arena, try std.fs.path.join(arena, &.{ app.dir, paths.archive }));
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for (objects) |object| {
        const name = try object_name(arena, object, mode);
        try names.put(arena, std.fs.path.basename(name), {});
        try argv.append(arena, try std.fs.path.join(arena, &.{ paths.out_path, name }));
    }
    var linker = try spawn(io, argv.items, ".");
    if (!(try linker.wait(io)).success()) return error.ChildFailed;
    try Io.Dir.cwd().rename(linked, Io.Dir.cwd(), app.output, io);
    try forget(arena, io, paths, mode, &names);
}

/// Deletes this mode's objects no build names any more (an edit's old
/// part); the other mode's stay, so switching between them is not a
/// rebuild of everything.
fn forget(
    arena: Allocator,
    io: Io,
    paths: Paths,
    mode: Mode,
    kept: *const std.StringHashMapUnmanaged(void),
) !void {
    const dir_path = try std.fs.path.join(arena, &.{ paths.out_path, "objects" });
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    const suffix = try std.fmt.allocPrint(arena, "-{t}.o", .{mode});
    var stale: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();
    var seen: u32 = 0;
    while (try iterator.next(io)) |entry| {
        seen += 1;
        if (seen > 4 * rocstache.generate.templates_max) break; // bounded; the rest next time
        if (!std.mem.endsWith(u8, entry.name, suffix) or kept.contains(entry.name)) continue;
        try stale.append(arena, try arena.dupe(u8, entry.name));
    }
    for (stale.items) |name| dir.deleteFile(io, name) catch {};
}

fn spawn(io: Io, argv: []const []const u8, cwd: []const u8) !std.process.Child {
    return std.process.spawn(io, .{ .argv = argv, .cwd = .{ .path = cwd }, .stdin = .ignore });
}

pub fn milliseconds(from: Io.Timestamp, to: Io.Timestamp) i64 {
    return @intCast(@divTrunc(from.durationTo(to).nanoseconds, std.time.ns_per_ms));
}
