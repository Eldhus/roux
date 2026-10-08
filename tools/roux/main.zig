//! roux: builds a roux app.
//!
//!   roux build [--dev] [--output=PATH] [--roc=PATH] APP.roc
//!
//! Generates the app's templates (each `Page.rocstache` beside `APP.roc`
//! gets its `Page.roc` contract; the templates object's sources go in
//! `.roux/APP/`), then, at the same time, roc builds the app as an archive
//! and Zig compiles the templates object; then links the two into `APP`
//! beside `APP.roc`, as `roc build` names it, or into `--output`. `--dev`
//! is the fast build: roc `--opt=dev` and the templates Debug; without it,
//! `--opt=speed` and ReleaseSafe. The same source either way (DESIGN.md,
//! Templates).
//!
//! The toolchain is the pinned one, named at roux's build (build.zig): the
//! Zig that built this roux, and the roc nightly roux's `.roc-version`
//! names where it is installed, unless `--roc` names it elsewhere (the
//! dragrace installs its own, the same pin).

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const options = @import("roux_options");
const rocstache = @import("rocstache");

const usage =
    \\usage: roux build [--dev] [--output=PATH] [--roc=PATH] APP.roc
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var stderr_buffer: [4096]u8 = undefined;
    // Streaming: stderr redirected to a file (a log) is appended to, never
    // written at offset 0 over what the children wrote.
    var stderr_file: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file.interface;
    defer stderr.flush() catch {};
    if (args.len < 3 or !std.mem.eql(u8, args[1], "build")) return usage_exit(stderr);
    var mode: Mode = .release;
    var output: ?[]const u8 = null;
    var roc: []const u8 = options.roc;
    for (args[2 .. args.len - 1]) |flag| {
        if (std.mem.eql(u8, flag, "--dev")) {
            mode = .dev;
        } else if (std.mem.startsWith(u8, flag, "--output=")) {
            output = flag["--output=".len..];
        } else if (std.mem.startsWith(u8, flag, "--roc=")) {
            roc = flag["--roc=".len..];
        } else return usage_exit(stderr);
    }
    const file = args[args.len - 1];
    if (!std.mem.endsWith(u8, file, ".roc")) return usage_exit(stderr);
    const dir = std.fs.path.dirname(file) orelse ".";
    const name = std.fs.path.stem(file);
    const app: App = .{
        .dir = dir,
        .file = std.fs.path.basename(file),
        .name = name,
        .output = output orelse try std.fs.path.join(arena, &.{ dir, name }),
        .roc = roc,
    };
    build(arena, io, app, mode, stderr) catch |err| switch (err) {
        error.Invalid, error.GlueFailed, error.ChildFailed => {
            stderr.flush() catch {};
            std.process.exit(1);
        },
        else => return err,
    };
}

fn usage_exit(stderr: *Io.Writer) !void {
    try stderr.writeAll(usage);
    try stderr.flush();
    std.process.exit(2);
}

const App = struct {
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
};

const Mode = enum {
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

/// Where a build's files go, relative to the app's directory (where roc and
/// the linker run) and to the working directory.
const Paths = struct {
    /// `.roux/main`, from the app's directory.
    out: []const u8,
    /// The same, from the working directory.
    out_path: []const u8,
    /// The templates object's sources, from the working directory.
    templates: []const u8,
    /// `.roux/main/app.a`, from the app's directory.
    archive: []const u8,

    fn of(arena: Allocator, app: App) Allocator.Error!Paths {
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

fn build(arena: Allocator, io: Io, app: App, mode: Mode, stderr: *Io.Writer) !void {
    const paths: Paths = try .of(arena, app);
    const start = Io.Timestamp.now(io, .awake);
    const generated = try generate(arena, io, paths, app, stderr);
    const generated_at = Io.Timestamp.now(io, .awake);
    try compile(arena, io, paths, app, mode);
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
fn generate(
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
fn compile(arena: Allocator, io: Io, paths: Paths, app: App, mode: Mode) !void {
    const output = try std.fmt.allocPrint(arena, "--output={s}", .{paths.archive});
    var roc = try spawn(io, &.{ app.roc, "build", mode.roc_opt(), app.file, output }, app.dir);
    var zig = try spawn(io, &.{
        options.zig,
        "build-obj",
        "object.zig",
        mode.zig_opt(),
        "-target",
        "x86_64-linux-musl",
        "-fno-compiler-rt",
        "-femit-bin=../templates.o",
    }, paths.templates);
    const roc_ok = (try roc.wait(io)).success();
    const zig_ok = (try zig.wait(io)).success();
    if (!roc_ok or !zig_ok) return error.ChildFailed;
}

/// roc's archive and the templates object, into the output: a new file
/// renamed over the old, so a running binary is not overwritten.
fn link(arena: Allocator, io: Io, paths: Paths, app: App) !void {
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

fn milliseconds(from: Io.Timestamp, to: Io.Timestamp) i64 {
    return @intCast(@divTrunc(from.durationTo(to).nanoseconds, std.time.ns_per_ms));
}
