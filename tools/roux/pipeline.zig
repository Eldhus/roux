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

/// Which compilers a build runs: both for `roux build`; for `roux dev`,
/// only what an edit changed (markup alone needs no roc).
pub const Parts = struct {
    roc: bool,
    templates: bool,
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
    const generated = try generate(arena, io, paths, app, stderr);
    const generated_at = Io.Timestamp.now(io, .awake);
    try compile(arena, io, paths, app, mode, .{ .roc = true, .templates = true });
    const compiled_at = Io.Timestamp.now(io, .awake);
    try link(arena, io, paths, app);
    const linked_at = Io.Timestamp.now(io, .awake);
    try stderr.print("roux: {d} templates ({d} ms{s}), roc and templates {d} ms, link {d} ms: ", .{
        generated.templates,
        milliseconds(start, generated_at),
        if (generated.contracts_changed) ", contracts changed" else "",
        milliseconds(generated_at, compiled_at),
        milliseconds(compiled_at, linked_at),
    });
    try stderr.print("{s}\n", .{app.output});
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

/// roc and Zig at once: neither needs the other's output.
pub fn compile(arena: Allocator, io: Io, paths: Paths, app: App, mode: Mode, parts: Parts) !void {
    assert(parts.roc or parts.templates);
    const output = try std.fmt.allocPrint(arena, "--output={s}", .{paths.archive});
    var roc: ?std.process.Child = if (parts.roc)
        try spawn(io, &.{ app.roc, "build", mode.roc_opt(), app.file, output }, app.dir)
    else
        null;
    var zig: ?std.process.Child = if (parts.templates) try spawn(io, &.{
        options.zig,
        "build-obj",
        "object.zig",
        mode.zig_opt(),
        "-target",
        "x86_64-linux-musl",
        "-fno-compiler-rt",
        "-femit-bin=../templates.o",
    }, paths.templates) else null;
    const roc_ok = if (roc) |*child| (try child.wait(io)).success() else true;
    const zig_ok = if (zig) |*child| (try child.wait(io)).success() else true;
    if (!roc_ok or !zig_ok) return error.ChildFailed;
}

/// roc's archive and the templates object, into the output: a new file
/// renamed over the old, so a running binary is not overwritten.
pub fn link(arena: Allocator, io: Io, paths: Paths, app: App) !void {
    const linked = try std.fmt.allocPrint(arena, "{s}.new", .{app.output});
    const archive = try std.fs.path.join(arena, &.{ app.dir, paths.archive });
    const object = try std.fs.path.join(arena, &.{ paths.out_path, "templates.o" });
    const argv = [_][]const u8{ options.zig, "ld.lld", "-static", "-o", linked, archive, object };
    var linker = try spawn(io, &argv, ".");
    if (!(try linker.wait(io)).success()) return error.ChildFailed;
    try Io.Dir.cwd().rename(linked, Io.Dir.cwd(), app.output, io);
}

fn spawn(io: Io, argv: []const []const u8, cwd: []const u8) !std.process.Child {
    return std.process.spawn(io, .{ .argv = argv, .cwd = .{ .path = cwd }, .stdin = .ignore });
}

pub fn milliseconds(from: Io.Timestamp, to: Io.Timestamp) i64 {
    return @intCast(@divTrunc(from.durationTo(to).nanoseconds, std.time.ns_per_ms));
}
