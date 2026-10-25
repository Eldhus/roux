//! The steps of building a roux app, shared by `roux build` (all of them)
//! and `roux dev` (only those an edit needs): the queries' modules
//! (roux-db), the templates generated (their modules and the program,
//! `templates.bin`), roc building the executable while glue lays out the
//! contracts, then the program attached to roc's executable.

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
    /// The build directory, `.roux/main` from the app's directory, here from
    /// the working directory.
    out_path: []const u8,
    /// `.roux/main/app`, roc's executable, from the app's directory.
    executable: []const u8,

    pub fn of(arena: Allocator, app: App) Allocator.Error!Paths {
        const out = try std.fmt.allocPrint(arena, ".roux/{s}", .{app.name});
        return .{
            .out_path = try std.fs.path.join(arena, &.{ app.dir, out }),
            .executable = try std.fmt.allocPrint(arena, "{s}/app", .{out}),
        };
    }
};

/// Every step, timed on one line: `roux build`. roc builds the app while
/// glue lays out the contracts (neither needs the other).
pub fn build(arena: Allocator, io: Io, app: App, mode: Mode, stderr: *Io.Writer) !void {
    const paths: Paths = try .of(arena, app);
    const start = Io.Timestamp.now(io, .awake);
    if (has_queries(io, app)) try query_types(arena, io, app, null);
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
    try attach(arena, io, paths, app, stderr);
    const attached_at = Io.Timestamp.now(io, .awake);
    const line = "roux: {d} templates ({d} ms{s}), roc and glue {d} ms, attach {d} ms: ";
    try stderr.print(line, .{
        generated.templates,
        milliseconds(start, begun_at),
        if (generated.modules_changed) ", modules changed" else "",
        milliseconds(begun_at, compiled_at),
        milliseconds(compiled_at, attached_at),
    });
    try stderr.print("{s}\n", .{app.output});
}

/// Whether the app has queries for roux-db: a `db/schema.sql` (`roux dev`
/// asks the same).
pub fn has_queries(io: Io, app: App) bool {
    var dir = Io.Dir.cwd().openDir(io, app.dir, .{}) catch return false;
    defer dir.close(io);
    dir.access(io, "db/schema.sql", .{}) catch return false;
    return true;
}

/// `roux-db gen db` in the app's directory: the queries' typed modules.
/// roux-db is found beside this roux (both are `zig build tools`').
/// `log`: where roux-db's messages go (`roux dev` shows them in the page
/// too); null for the terminal.
pub fn query_types(arena: Allocator, io: Io, app: App, log: ?Io.File) !void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const self_len = try Io.Dir.readLinkAbsolute(io, "/proc/self/exe", &buffer);
    const bin = std.fs.path.dirname(buffer[0..self_len]) orelse ".";
    const roux_db = try std.fs.path.join(arena, &.{ bin, "roux-db" });
    const to: std.process.SpawnOptions.StdIo = if (log) |file| .{ .file = file } else .inherit;
    var child = try spawn_to(io, &.{ roux_db, "gen", "db" }, app.dir, to);
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
        .app = try std.fs.path.join(arena, &.{ app.dir, rocstache.generate.templates_dir }),
        .build = paths.out_path,
        .roc = app.roc,
        .changed = changed,
    }, cache, stderr);
}

/// roc started on the app's executable: roc links it, as any platform's.
/// `log`: where roc's messages go (`roux dev` shows them in the page too);
/// null for the terminal.
pub fn start_roc(io: Io, paths: Paths, app: App, mode: Mode, log: ?Io.File) !std.process.Child {
    var buffer: [std.fs.max_path_bytes + 16]u8 = undefined;
    const output = try std.fmt.bufPrint(&buffer, "--output={s}", .{paths.executable});
    const argv = &.{ app.roc, "build", mode.roc_opt(), app.file, output };
    const to: std.process.SpawnOptions.StdIo = if (log) |file| .{ .file = file } else .inherit;
    return spawn_to(io, argv, app.dir, to);
}

/// roc's executable with the templates' program attached after it, then
/// the trailer the host looks for (host/templates.zig's `load_attached`):
/// the program's length and a magic. Written beside the output and renamed
/// over it, so a running binary is not overwritten. A call that fails is
/// named on `stderr`, with its file and errno.
pub fn attach(arena: Allocator, io: Io, paths: Paths, app: App, stderr: *Io.Writer) !void {
    const cwd = Io.Dir.cwd();
    const built = try std.fs.path.joinZ(arena, &.{ app.dir, paths.executable });
    const program_path = try std.fs.path.join(arena, &.{
        paths.out_path,
        rocstache.generate.program_name,
    });
    const program = try cwd.readFileAlloc(io, program_path, arena, .limited(1 << 30));
    const trailer = rocstache.program.trailer(program.len);
    const attached = try std.fmt.allocPrintSentinel(arena, "{s}.new", .{app.output}, 0);
    var failure: Failure = .{};
    write_attached(built, attached, &.{ program, &trailer }, &failure) catch |err| {
        failure.say(stderr);
        return err;
    };
    cwd.rename(attached, cwd, app.output, io) catch |err| {
        _ = std.os.linux.unlink(attached);
        return err;
    };
}

/// The call that failed in an attach, its file and why: roux's one line.
const Failure = struct {
    call: []const u8 = "",
    path: []const u8 = "",
    why: []const u8 = "",

    fn set(
        failure: *Failure,
        call: []const u8,
        path: []const u8,
        why: []const u8,
    ) error{AttachFailed} {
        assert(failure.call.len == 0);
        assert(call.len > 0);
        failure.* = .{ .call = call, .path = path, .why = why };
        return error.AttachFailed;
    }

    fn say(failure: *const Failure, stderr: *Io.Writer) void {
        assert(failure.call.len > 0);
        const line = "roux: the templates not attached: {s} {s}: {s}\n";
        stderr.print(line, .{ failure.call, failure.path, failure.why }) catch {};
    }
};

/// `attached` made: `built` (roc's executable), then `parts`. Removed again
/// if any call fails.
fn write_attached(
    built: [:0]const u8,
    attached: [:0]const u8,
    parts: []const []const u8,
    failure: *Failure,
) error{AttachFailed}!void {
    const copies_max = 16; // 16 GiB: no executable is
    const linux = std.os.linux;
    const source = linux.open(built, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(source) != .SUCCESS) {
        return failure.set("open", built, @tagName(linux.errno(source)));
    }
    defer _ = linux.close(@intCast(source));
    const how: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const opened = linux.open(attached, how, 0o755);
    if (linux.errno(opened) != .SUCCESS) {
        return failure.set("open", attached, @tagName(linux.errno(opened)));
    }
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    errdefer _ = linux.unlink(attached);
    // roc's executable, copied in the kernel, a gigabyte at most a call; to
    // another filesystem (an output in tmpfs) the kernel refuses with EXDEV,
    // so through a buffer.
    for (0..copies_max) |_| {
        const copied = linux.copy_file_range(@intCast(source), null, fd, null, 1 << 30, 0);
        switch (linux.errno(copied)) {
            .SUCCESS => if (copied == 0) break,
            .XDEV => break try copy_buffered(@intCast(source), fd, built, attached, failure),
            else => |errno| return failure.set("copy_file_range", attached, @tagName(errno)),
        }
    } else return failure.set("copy_file_range", attached, "past 16 GiB");
    for (parts) |part| try write_all(fd, part, attached, failure);
}

/// The rest of `source` written to `fd`, 64 KiB a read.
fn copy_buffered(
    source: i32,
    fd: i32,
    built: []const u8,
    attached: []const u8,
    failure: *Failure,
) error{AttachFailed}!void {
    const reads_max = 1 << 18; // 16 GiB: no executable is
    const linux = std.os.linux;
    var buffer: [64 * 1024]u8 = undefined;
    for (0..reads_max) |_| {
        const read = linux.read(source, &buffer, buffer.len);
        if (linux.errno(read) != .SUCCESS) {
            return failure.set("read", built, @tagName(linux.errno(read)));
        }
        if (read == 0) return;
        try write_all(fd, buffer[0..read], attached, failure);
    }
    return failure.set("read", built, "past 16 GiB");
}

fn write_all(
    fd: i32,
    bytes: []const u8,
    attached: []const u8,
    failure: *Failure,
) error{AttachFailed}!void {
    const linux = std.os.linux;
    var done: usize = 0;
    while (done < bytes.len) {
        const wrote = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (linux.errno(wrote) != .SUCCESS) {
            return failure.set("write", attached, @tagName(linux.errno(wrote)));
        }
        if (wrote == 0) return failure.set("write", attached, "nothing written");
        done += wrote;
    }
}

pub fn wait_roc(io: Io, roc: *std.process.Child) !void {
    if (!(try roc.wait(io)).success()) return error.ChildFailed;
}

/// A tool started, its output (stdout and stderr) to `to`; one that cannot
/// be is named, with why, as a tool that ran and failed would have said
/// (rare: a plain unbuffered line).
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

test "attach: a failed call is named, with its file and errno" {
    var failure: Failure = .{};
    const parts: []const []const u8 = &.{"program"};
    const missing = "/nonexistent/roux-attach/app";
    const opened = write_attached(missing, "/nonexistent/roux-attach/app.new", parts, &failure);
    try std.testing.expectError(error.AttachFailed, opened);
    var buffer: [128]u8 = undefined;
    var stderr: Io.Writer = .fixed(&buffer);
    failure.say(&stderr);
    try std.testing.expectEqualStrings(
        "roux: the templates not attached: open /nonexistent/roux-attach/app: NOENT\n",
        stderr.buffered(),
    );
    // Roc's executable read, the attached file not made: its directory is
    // missing.
    failure = .{};
    const attached = "/nonexistent/roux-attach/app.new";
    const made = write_attached("/proc/self/exe", attached, parts, &failure);
    try std.testing.expectError(error.AttachFailed, made);
    try std.testing.expectEqualStrings("open", failure.call);
    try std.testing.expectEqualStrings(attached, failure.path);
    try std.testing.expectEqualStrings("NOENT", failure.why);
}
