//! The steps of building a roux app, shared by `roux build` (all of them)
//! and `roux dev` (only those an edit needs): the templates generated (their
//! modules, and their bytecode's object, written directly), then roc, then
//! the link.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
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
};

/// Where a build's files go, relative to the app's directory (where roc
/// runs) and to the working directory.
pub const Paths = struct {
    /// `.roux/main`, from the app's directory.
    out: []const u8,
    /// The same, from the working directory.
    out_path: []const u8,
    /// `.roux/main/app`, roc's executable, from the app's directory.
    archive: []const u8,

    pub fn of(arena: Allocator, app: App) Allocator.Error!Paths {
        const out = try std.fmt.allocPrint(arena, ".roux/{s}", .{app.name});
        return .{
            .out = out,
            .out_path = try std.fs.path.join(arena, &.{ app.dir, out }),
            .archive = try std.fmt.allocPrint(arena, "{s}/app", .{out}),
        };
    }
};

/// Every step, timed on one line: `roux build`. roc builds the app while
/// glue lays out the contracts (neither needs the other).
pub fn build(arena: Allocator, io: Io, app: App, mode: Mode, stderr: *Io.Writer) !void {
    const paths: Paths = try .of(arena, app);
    const start = Io.Timestamp.now(io, .awake);
    if (has_queries(io, app)) try query_types(arena, io, app);
    var cache: rocstache.generate.Cache = .init(arena);
    var generation = try begin(arena, io, paths, app, &cache, null, stderr);
    const begun_at = Io.Timestamp.now(io, .awake);
    var roc = start_roc(io, paths, app, mode, null) catch |err| {
        rocstache.generate.abandon(io, &generation);
        return err;
    };
    const generated = rocstache.generate.finish(arena, io, &generation, stderr) catch |err| {
        roc.kill(io);
        return err;
    };
    try wait_roc(io, &roc);
    const compiled_at = Io.Timestamp.now(io, .awake);
    try attach(arena, io, paths, app);
    const linked_at = Io.Timestamp.now(io, .awake);
    const line = "roux: {d} templates ({d} ms{s}), roc and glue {d} ms, attach {d} ms: ";
    try stderr.print(line, .{
        generated.templates,
        milliseconds(start, begun_at),
        if (generated.modules_changed) ", modules changed" else "",
        milliseconds(begun_at, compiled_at),
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

/// The templates' modules written and glue started (generate.zig's
/// `begin`); `rocstache.generate.finish` writes their program. `changed`:
/// the templates whose files `roux dev` saw written (null: all may have
/// been).
pub fn begin(
    arena: Allocator,
    io: Io,
    paths: Paths,
    app: App,
    cache: *rocstache.generate.Cache,
    changed: ?[]const []const u8,
    stderr: *Io.Writer,
) !rocstache.generate.Generation {
    return rocstache.generate.begin(arena, io, .{
        .app = app.dir,
        .build = paths.out_path,
        .roc = app.roc,
        .cache = cache,
        .changed = changed,
    }, cache, stderr);
}

/// roc started on the app's executable: roc links it, as any platform's.
/// `log`: where roc's messages go (`roux dev` shows them in the page too);
/// null for the terminal.
pub fn start_roc(io: Io, paths: Paths, app: App, mode: Mode, log: ?Io.File) !std.process.Child {
    var buffer: [std.fs.max_path_bytes + 16]u8 = undefined;
    const output = try std.fmt.bufPrint(&buffer, "--output={s}", .{paths.archive});
    const argv = &.{ app.roc, "build", mode.roc_opt(), app.file, output };
    const to: std.process.SpawnOptions.StdIo = if (log) |file| .{ .file = file } else .inherit;
    return spawn_to(io, argv, app.dir, to);
}

/// roc's executable with the templates' program attached after it, then
/// the trailer the host looks for (host/templates.zig's `load_attached`):
/// the program's length and a magic. Written beside the output and renamed
/// over it, so a running binary is not overwritten.
pub fn attach(arena: Allocator, io: Io, paths: Paths, app: App) !void {
    const copies_max = 16; // 16 GiB: no executable is
    const cwd = Io.Dir.cwd();
    const built = try std.fs.path.joinZ(arena, &.{ app.dir, paths.archive });
    const program_path = try std.fs.path.join(arena, &.{
        paths.out_path,
        rocstache.generate.program_name,
    });
    const program = try cwd.readFileAlloc(io, program_path, arena, .limited(1 << 30));
    const trailer = rocstache.program.trailer(program.len);
    const attached = try std.fmt.allocPrintSentinel(arena, "{s}.new", .{app.output}, 0);
    const linux = std.os.linux;
    const source = linux.open(built, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(source) != .SUCCESS) return error.AttachFailed;
    defer _ = linux.close(@intCast(source));
    const how: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const opened = linux.open(attached, how, 0o755);
    if (linux.errno(opened) != .SUCCESS) return error.AttachFailed;
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    // roc's executable, copied in the kernel, a gigabyte at most a call.
    for (0..copies_max) |_| {
        const copied = linux.copy_file_range(@intCast(source), null, fd, null, 1 << 30, 0);
        if (linux.errno(copied) != .SUCCESS) return error.AttachFailed;
        if (copied == 0) break;
    } else return error.AttachFailed;
    for ([_][]const u8{ program, &trailer }) |part| {
        var done: usize = 0;
        while (done < part.len) {
            const wrote = linux.write(fd, part[done..].ptr, part.len - done);
            if (linux.errno(wrote) != .SUCCESS or wrote == 0) return error.AttachFailed;
            done += wrote;
        }
    }
    try cwd.rename(attached, cwd, app.output, io);
}

pub fn wait_roc(io: Io, roc: *std.process.Child) !void {
    if (!(try roc.wait(io)).success()) return error.ChildFailed;
}

/// A tool started; one that cannot be is named, with why, as a tool that
/// ran and failed would have said (rare: a plain unbuffered line).
fn spawn(io: Io, argv: []const []const u8, cwd: []const u8) !std.process.Child {
    return spawn_to(io, argv, cwd, .inherit);
}

/// The same, its output (stdout and stderr) to `to`.
fn spawn_to(
    io: Io,
    argv: []const []const u8,
    cwd: []const u8,
    to: std.process.SpawnOptions.StdIo,
) !std.process.Child {
    const how: std.process.SpawnOptions = .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = to,
        .stderr = to,
    };
    return std.process.spawn(io, how) catch |err| {
        std.debug.print("roux: {s} could not run: {t}\n", .{ argv[0], err });
        return error.ChildFailed;
    };
}

pub fn milliseconds(from: Io.Timestamp, to: Io.Timestamp) i64 {
    return @intCast(@divTrunc(from.durationTo(to).nanoseconds, std.time.ns_per_ms));
}
