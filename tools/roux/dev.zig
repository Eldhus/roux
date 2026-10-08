//! `roux dev APP.roc`: the app built, run, and rebuilt as it is edited
//! (docs/dev-server.md).
//!
//! One loop, one pass at a time, so a build never races a generator. A
//! pass hashes the app's sources by kind and runs only what changed: a
//! query (`*.sql`) runs roux-db; then the templates are generated, which
//! rewrites a `Page.roc` only when its contract changed; Roc sources
//! changed, roc builds (`--opt=dev`); templates changed, Zig compiles the
//! templates object (Debug); either, the link and a restart. Editing
//! markup never starts roc. Content decides, never mtimes: a save that
//! changes nothing, and the generators' own writes, cost nothing more.
//!
//! The app runs with `ROUX_DEV` set to the build's number, so the host
//! answers `/_dev/events` and adds the reload script to HTML (host/dev.zig):
//! a restart drops the browser's stream, it reconnects to the new build
//! and reloads. A failed build leaves the last good one serving.
//!
//! One line per pass on stderr, for people and agents to wait on:
//! `roux dev: build 4 ok (templates) in 412 ms`, or `... failed`.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const pipeline = @import("pipeline.zig");

pub const Options = struct {
    app: pipeline.App,
    /// The port to serve on (`ROUX_PORT`), or the app's own.
    port: ?[]const u8,
    /// A directory of static files, relative to the app's: the host reads
    /// them at startup, so a change restarts the app.
    static: ?[]const u8,
};

const files_max = 4096;
const directories_max = 256;
/// Saves come in bursts (an editor writes, renames, writes again): a pass
/// starts once the app's sources are quiet this long.
const quiet_milliseconds = 30;

/// What the app is built from, a hash of each kind's paths and contents.
const Digests = struct {
    roc: u64 = 0,
    templates: u64 = 0,
    sql: u64 = 0,
    static: u64 = 0,
    /// An app without queries has no `db/` for roux-db.
    sql_files: u32 = 0,
};

const Kind = enum { roc, templates, sql, static, other };

pub fn run(
    gpa: Allocator,
    io: Io,
    options: Options,
    environ: *const std.process.Environ.Map,
) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file.interface;
    defer stderr.flush() catch {};
    var watch: Watch = try .start(gpa, io, options);
    defer watch.deinit(gpa);
    var state: State = .{ .options = options, .environ = environ };
    defer state.stop(io);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    stop_on_signals();
    // Until SIGINT or SIGTERM: roux dev runs as long as it is wanted.
    while (!stopping.load(.monotonic)) {
        _ = arena_state.reset(.retain_capacity);
        state.pass(arena_state.allocator(), io, stderr) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {},
        };
        stderr.flush() catch {};
        // Until a source changes; the app exiting on its own is said, and
        // waits for an edit too.
        while (true) {
            switch (try watch.wait(state.child_fd)) {
                .source, .stopping => break,
                .exited => state.exited(io, stderr),
            }
            stderr.flush() catch {};
        }
    }
}

/// Set by SIGINT or SIGTERM: roux dev stops the app, then itself. (A
/// handler, not a blocked signal and a signalfd: a blocked mask passes to
/// the app across exec, and the app must die by SIGTERM; handlers do not.)
var stopping: std.atomic.Value(bool) = .init(false);

fn on_signal(_: linux.SIG) callconv(.c) void {
    stopping.store(true, .monotonic);
}

fn stop_on_signals() void {
    const action: linux.Sigaction = .{
        .handler = .{ .handler = on_signal },
        .mask = linux.sigemptyset(),
        .flags = 0, // no SA_RESTART: a waiting poll returns at once
    };
    _ = linux.sigaction(.INT, &action, null);
    _ = linux.sigaction(.TERM, &action, null);
}

const State = struct {
    options: Options,
    environ: *const std.process.Environ.Map,
    built: Digests = .{},
    build: u32 = 0,
    child: ?std.process.Child = null,
    /// The child's pidfd, readable when it exits; -1 with no child.
    child_fd: i32 = -1,
    /// The last pass failed: the next that finds nothing to build says so.
    failing: bool = false,

    /// One pass: what changed is built, then the app restarted.
    fn pass(state: *State, arena: Allocator, io: Io, stderr: *Io.Writer) !void {
        const app = state.options.app;
        const start = Io.Timestamp.now(io, .awake);
        const before = try digests(arena, io, state.options);
        if (before.sql_files > 0 and before.sql != state.built.sql) {
            try state.query_types(arena, io, stderr);
        }
        const paths: pipeline.Paths = try .of(arena, app);
        const generated = pipeline.generate(arena, io, paths, app, stderr) catch |err|
            return state.failed(stderr, err);
        // After generation: a contract that changed rewrote its Page.roc.
        const now = try digests(arena, io, state.options);
        const parts: pipeline.Parts = .{
            .roc = now.roc != state.built.roc,
            .templates = now.templates != state.built.templates or generated.contracts_changed,
        };
        const changed = parts.roc or parts.templates or now.static != state.built.static;
        // Nothing changed, and the app runs: nothing to do. (Exited: start
        // it again, it may have been a passing failure.)
        if (!changed and state.child != null) {
            if (state.failing) {
                const again = "roux dev: the sources are build {d}'s again; it serves\n";
                try stderr.print(again, .{state.build});
            }
            state.failing = false;
            return;
        }
        if (parts.roc or parts.templates) {
            pipeline.compile(arena, io, paths, app, .dev, parts) catch |err|
                return state.failed(stderr, err);
            pipeline.link(arena, io, paths, app) catch |err| return state.failed(stderr, err);
        }
        state.built = now;
        state.build += 1;
        state.failing = false;
        try state.restart(arena, io);
        const what = if (parts.roc)
            "roc and templates"
        else if (parts.templates) "templates" else "a restart";
        try stderr.print("roux dev: build {d} ok ({s}) in {d} ms\n", .{
            state.build,
            what,
            pipeline.milliseconds(start, Io.Timestamp.now(io, .awake)),
        });
    }

    /// The app exited on its own (a crash, a refused start): said, and
    /// collected; the next save starts it again.
    fn exited(state: *State, io: Io, stderr: *Io.Writer) void {
        var child = state.child orelse return;
        _ = linux.close(state.child_fd);
        state.child_fd = -1;
        state.child = null;
        const term = child.wait(io) catch return;
        switch (term) {
            .exited => |code| stderr.print("roux dev: build {d} exited, code {d}\n", .{
                state.build,
                code,
            }) catch {},
            .signal => |signal| stderr.print("roux dev: build {d} killed by signal {t}\n", .{
                state.build,
                signal,
            }) catch {},
            .stopped, .unknown => {
                stderr.print("roux dev: build {d} stopped\n", .{state.build}) catch {};
            },
        }
    }

    /// The compilers printed why; the last good build keeps serving.
    fn failed(state: *State, stderr: *Io.Writer, err: anyerror) anyerror {
        state.failing = true;
        stderr.print("roux dev: build {d} failed; build {d} still serving\n", .{
            state.build + 1,
            state.build,
        }) catch {};
        return err;
    }

    /// `roux-db gen db`, from beside this roux.
    fn query_types(state: *State, arena: Allocator, io: Io, stderr: *Io.Writer) !void {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const self_len = try Io.Dir.readLinkAbsolute(io, "/proc/self/exe", &buffer);
        const bin = std.fs.path.dirname(buffer[0..self_len]) orelse ".";
        const roux_db = try std.fs.path.join(arena, &.{ bin, "roux-db" });
        var child = try std.process.spawn(io, .{
            .argv = &.{ roux_db, "gen", "db" },
            .cwd = .{ .path = state.options.app.dir },
            .stdin = .ignore,
        });
        if (!(try child.wait(io)).success()) return state.failed(stderr, error.ChildFailed);
    }

    /// The old build stopped (its database closed), the new one started,
    /// on two shards unless the environment says otherwise (host.zig,
    /// shard_count: eight right after eight did not fit the laptop).
    fn restart(state: *State, arena: Allocator, io: Io) !void {
        state.stop(io);
        var environ = try state.environ.clone(arena);
        try environ.put("ROUX_DEV", try std.fmt.allocPrint(arena, "{d}", .{state.build}));
        if (state.options.port) |port| try environ.put("ROUX_PORT", port);
        if (environ.get("ROUX_SHARDS") == null) try environ.put("ROUX_SHARDS", "2");
        const output = state.options.app.output;
        const binary = try std.fmt.allocPrint(arena, "./{s}", .{std.fs.path.basename(output)});
        const child = try std.process.spawn(io, .{
            .argv = &.{binary},
            .cwd = .{ .path = std.fs.path.dirname(output) orelse "." },
            .environ_map = &environ,
            .stdin = .ignore,
        });
        state.child = child;
        state.child_fd = @intCast(try syscall(linux.pidfd_open(child.id.?, 0)));
    }

    fn stop(state: *State, io: Io) void {
        var child = state.child orelse return;
        _ = linux.close(state.child_fd);
        state.child_fd = -1;
        _ = linux.kill(child.id.?, .TERM);
        _ = child.wait(io) catch {};
        state.child = null;
    }
};

/// Whether a path in the app's directory is under its static files.
fn in_static(options: Options, path: []const u8) bool {
    const static = options.static orelse return false;
    return std.mem.startsWith(u8, path, std.mem.trimEnd(u8, static, "/"));
}

fn kind_of(name: []const u8) Kind {
    if (std.mem.endsWith(u8, name, ".rocstache")) return .templates;
    if (std.mem.endsWith(u8, name, ".roc")) return .roc;
    if (std.mem.endsWith(u8, name, ".sql")) return .sql;
    return .other;
}

/// Each kind's hash over the app's directory (hidden directories and
/// `.roux/` left out), static files only under `options.static`.
fn digests(arena: Allocator, io: Io, options: Options) !Digests {
    var dir = try Io.Dir.cwd().openDir(io, options.app.dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walkSelectively(arena);
    defer walker.deinit();
    var hashes: [4]std.hash.Wyhash = @splat(.init(0));
    var files: u32 = 0;
    var sql_files: u32 = 0;
    while (try walker.next(io)) |entry| {
        if (entry.basename[0] == '.') continue;
        if (entry.kind == .directory) {
            try walker.enter(io, entry);
            continue;
        }
        if (entry.kind != .file) continue;
        const kind: Kind = if (in_static(options, entry.path)) .static else kind_of(entry.basename);
        if (kind == .other) continue;
        files += 1;
        if (files > files_max) return error.TooManyFiles;
        if (kind == .sql) sql_files += 1;
        const content = try entry.dir.readFileAlloc(io, entry.basename, arena, .limited(16 << 20));
        const hash = &hashes[@backingInt(kind)];
        hash.update(entry.path);
        hash.update(content);
    }
    return .{
        .roc = hashes[@backingInt(Kind.roc)].final(),
        .templates = hashes[@backingInt(Kind.templates)].final(),
        .sql = hashes[@backingInt(Kind.sql)].final(),
        .static = hashes[@backingInt(Kind.static)].final(),
        .sql_files = sql_files,
    };
}

/// inotify over the app's directories, as they were when roux dev started.
const Watch = struct {
    fd: i32,
    /// Which watches are the static directory's (by watch descriptor).
    static: std.AutoHashMapUnmanaged(i32, void) = .empty,

    fn start(gpa: Allocator, io: Io, options: Options) !Watch {
        const fd: i32 = @intCast(try syscall(linux.inotify_init1(linux.IN.CLOEXEC)));
        var watch: Watch = .{ .fd = fd };
        errdefer watch.deinit(gpa);
        const mask = linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO | linux.IN.CREATE | linux.IN.DELETE;
        try watch.add(gpa, options.app.dir, mask, false);
        var dir = try Io.Dir.cwd().openDir(io, options.app.dir, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walkSelectively(gpa);
        defer walker.deinit();
        var count: u32 = 1;
        while (try walker.next(io)) |entry| {
            if (entry.kind != .directory or entry.basename[0] == '.') continue;
            count += 1;
            if (count > directories_max) return error.TooManyDirectories;
            const path = try std.fs.path.join(gpa, &.{ options.app.dir, entry.path });
            defer gpa.free(path);
            try watch.add(gpa, path, mask, in_static(options, entry.path));
            try walker.enter(io, entry);
        }
        return watch;
    }

    fn deinit(watch: *Watch, gpa: Allocator) void {
        watch.static.deinit(gpa);
        _ = linux.close(watch.fd);
        watch.* = undefined;
    }

    fn add(watch: *Watch, gpa: Allocator, path: []const u8, mask: u32, static: bool) !void {
        const path_z = try gpa.dupeSentinel(u8, path, 0);
        defer gpa.free(path_z);
        const wd: i32 = @intCast(try syscall(linux.inotify_add_watch(watch.fd, path_z, mask)));
        if (static) try watch.static.put(gpa, wd, {});
    }

    const Woken = enum { source, exited, stopping };

    /// Blocks until a source changes, then until the sources are quiet; or
    /// until the app (`child_fd`, a pidfd; -1 for none) exits, or a signal
    /// asks roux dev to stop.
    fn wait(watch: *Watch, child_fd: i32) !Woken {
        while (!stopping.load(.monotonic)) {
            switch (try watch.read(-1, child_fd)) {
                .source => break,
                .exited => return .exited,
                .quiet => {},
            }
        } else return .stopping;
        while (try watch.read(quiet_milliseconds, -1) != .quiet) {
            if (stopping.load(.monotonic)) return .stopping;
        }
        return .source;
    }

    /// What happened within `timeout` (ms; -1 forever).
    fn read(watch: *Watch, timeout: i32, child_fd: i32) !enum { source, exited, quiet } {
        var fds = [_]linux.pollfd{
            .{ .fd = watch.fd, .events = linux.POLL.IN },
            .{ .fd = child_fd, .events = linux.POLL.IN }, // poll skips a negative fd
        };
        if (try syscall(linux.poll(&fds, fds.len, timeout)) == 0) return .quiet;
        if (fds[1].revents & linux.POLL.IN != 0) return .exited;
        if (fds[0].revents & linux.POLL.IN == 0) return .quiet;
        var buffer: [64 * 1024]u8 align(@alignOf(linux.inotify_event)) = undefined;
        const len = try syscall(linux.read(watch.fd, &buffer, buffer.len));
        var at: usize = 0;
        var source = false;
        while (at < len) {
            const event: *const linux.inotify_event = @ptrCast(@alignCast(&buffer[at]));
            const name_bytes = buffer[at + @sizeOf(linux.inotify_event) ..][0..event.len];
            const name = std.mem.sliceTo(name_bytes, 0);
            if (watch.static.contains(event.wd) or kind_of(name) != .other) source = true;
            at += @sizeOf(linux.inotify_event) + event.len;
        }
        return if (source) .source else .quiet;
    }
};

fn syscall(result: usize) !usize {
    return switch (linux.errno(result)) {
        .SUCCESS => result,
        .INTR => 0,
        else => error.SystemCall,
    };
}
