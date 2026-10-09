//! `roux dev APP.roc`: the app built, run, and rebuilt as it is edited
//! (docs/dev-server.md).
//!
//! One loop, one pass at a time, so a build never races a generator. A
//! pass hashes the app's sources by kind and runs only what changed: a
//! query (`*.sql`) runs roux-db; then the templates are generated, which
//! rewrites a `Page.roc` only when its contract changed, and the templates'
//! bytecode object when the markup did; Roc sources changed, roc builds
//! (`--opt=dev`); either, the link and a restart. Editing markup never
//! starts roc, nor any compiler. Content decides, never mtimes: a save that
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
const rocstache = @import("rocstache");

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
const quiet_milliseconds = 0;

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
    var state: State = .{ .options = options, .environ = environ, .cache = .init(gpa) };
    defer state.cache.deinit();
    defer state.stop(io);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    stop_on_signals();
    // Until SIGINT or SIGTERM: roux dev runs as long as it is wanted.
    while (!stopping.load(.monotonic)) {
        _ = arena_state.reset(.retain_capacity);
        const changed = watch.changed;
        watch.changed.reset();
        var names: [16][]const u8 = undefined;
        const pass: Pass = .{
            .markup_only = changed.markup_only(),
            .written = changed.written(&names),
        };
        state.pass(arena_state.allocator(), io, stderr, pass) catch |err| switch (err) {
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
    // The app is told to reread its templates by SIGUSR1, which kills a
    // process with no handler for it: one just started, before the host's
    // `start_dev`. An ignored signal stays ignored across exec (a handled
    // one does not), so the app is born ignoring it until its handler goes
    // in; an edit in that window is not lost, as the host reads the
    // program file when it starts.
    const ignore: linux.Sigaction = .{
        .handler = .{ .handler = linux.SIG.IGN },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(.USR1, &ignore, null);
}

/// What inotify said since the last pass.
const Pass = struct {
    /// Only templates changed, so no other source did and hashing them is
    /// skipped.
    markup_only: bool,
    /// The templates whose files were written, by name; null: all may have.
    written: ?[]const []const u8,
};

const State = struct {
    options: Options,
    environ: *const std.process.Environ.Map,
    /// What generation keeps between passes (the parsed layouts).
    cache: rocstache.generate.Cache,
    built: Digests = .{},
    build: u32 = 0,
    /// The rereads of the templates' program by the running build.
    rereads: u32 = 0,
    child: ?std.process.Child = null,
    /// The child's pidfd, readable when it exits; -1 with no child.
    child_fd: i32 = -1,
    /// The last pass failed: the next that finds nothing to build says so.
    failing: bool = false,

    /// One pass: what changed is built, then the app restarted, or told to
    /// reread its templates.
    fn pass(state: *State, arena: Allocator, io: Io, stderr: *Io.Writer, p: Pass) !void {
        const app = state.options.app;
        const start = Io.Timestamp.now(io, .awake);
        // After a failure the sources may hold Roc the app was not built
        // from (a contract that changed, roc that failed): hash them all.
        const before = if (p.markup_only and state.child != null and !state.failing)
            state.built
        else
            try digests(arena, io, state.options);
        if (before.sql_files > 0 and before.sql != state.built.sql) {
            pipeline.query_types(arena, io, app) catch |err| return state.failed(stderr, err);
        }
        const paths: pipeline.Paths = try .of(arena, app);
        const generated = pipeline.generate(arena, io, paths, app, .{
            .cache = &state.cache,
            .changed = p.written,
        }, stderr) catch |err| return state.failed(stderr, err);
        // A contract that changed rewrote its Page.roc: hash the Roc again.
        const now = if (generated.modules_changed)
            try digests(arena, io, state.options)
        else
            before;
        const roc = now.roc != state.built.roc;
        const static = now.static != state.built.static;
        const templates = generated.program_changed;
        // Only markup changed, and the app runs: it rereads the program
        // (`templates.bin`), no link and no restart, its state kept.
        if (!roc and !static and state.child != null) {
            state.built = now;
            if (templates) return state.reread(io, stderr, start);
            // Nothing changed at all. (Exited: start it again, below; it
            // may have been a passing failure.)
            if (state.failing) {
                const again = "roux dev: the sources are build {d}'s again; it serves\n";
                try stderr.print(again, .{state.build});
            }
            state.failing = false;
            return;
        }
        if (roc) {
            pipeline.compile(io, paths, app, .dev) catch |err| return state.failed(stderr, err);
        }
        // The app reads its program from `templates.bin` in development, so
        // only Roc (or no binary yet) needs the link.
        if (roc or state.build == 0) {
            pipeline.link(arena, io, paths, app) catch |err| return state.failed(stderr, err);
        }
        state.built = now;
        state.build += 1;
        state.rereads = 0;
        state.failing = false;
        try state.restart(arena, io, paths);
        try stderr.print("roux dev: build {d} ok ({s}) in {d} ms\n", .{
            state.build,
            built_what(roc, templates),
            pipeline.milliseconds(start, Io.Timestamp.now(io, .awake)),
        });
    }

    /// The running app told to reread the templates' program (SIGUSR1;
    /// host/templates.zig): it swaps it in at its next render and tells
    /// the browser, whose page reloads.
    fn reread(state: *State, io: Io, stderr: *Io.Writer, start: Io.Timestamp) !void {
        _ = linux.kill(state.child.?.id.?, .USR1);
        state.rereads += 1;
        state.failing = false;
        const tenths: u64 = @intCast(@divTrunc(start.durationTo(Io.Timestamp.now(io, .awake))
            .nanoseconds, 100 * std.time.ns_per_us));
        try stderr.print("roux dev: build {d} ok (templates reread, {d}) in {d}.{d} ms\n", .{
            state.build,
            state.rereads,
            tenths / 10,
            tenths % 10,
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

    /// The old build stopped (its database closed), the new one started,
    /// on two shards unless the environment says otherwise (host.zig,
    /// shard_count: eight right after eight did not fit the laptop).
    fn restart(state: *State, arena: Allocator, io: Io, paths: pipeline.Paths) !void {
        state.stop(io);
        var environ = try state.environ.clone(arena);
        try environ.put("ROUX_DEV", try std.fmt.allocPrint(arena, "{d}", .{state.build}));
        const program = try std.fs.path.join(arena, &.{
            try Io.Dir.cwd().realPathFileAlloc(io, paths.out_path, arena),
            rocstache.generate.program_name,
        });
        try environ.put("ROUX_DEV_TEMPLATES", program);
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

/// What a pass built, for its line.
fn built_what(roc: bool, templates: bool) []const u8 {
    if (roc and templates) return "roc, templates";
    if (roc) return "roc";
    if (templates) return "templates";
    return "static";
}

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
    /// What the events named since the last pass.
    changed: Changed = .{},
    /// The app's directory's watch: templates are its files.
    root: i32 = -1,
    /// Where events are read (a field: a safe build fills a local
    /// `undefined` buffer on every read).
    buffer: [64 * 1024]u8 align(@alignOf(linux.inotify_event)) = undefined,

    const Changed = struct {
        templates: bool = false,
        /// Roc, SQL, static files, or events lost (the queue overflowed).
        other: bool = false,
        /// A template created or deleted, one outside the app's own
        /// directory, or more than `names` holds: generation lists the
        /// directory and reads every template.
        listing: bool = false,
        /// The templates whose files were written, by name: offsets into
        /// `bytes` (not slices, so the struct can be copied).
        names: [16][2]u16 = undefined,
        names_len: u8 = 0,
        bytes: [2048]u8 = undefined,
        bytes_len: u16 = 0,

        fn markup_only(changed: Changed) bool {
            return changed.templates and !changed.other;
        }

        fn reset(changed: *Changed) void {
            changed.templates = false;
            changed.other = false;
            changed.listing = false;
            changed.names_len = 0;
            changed.bytes_len = 0;
        }

        /// A template's file written: `name` is its stem.
        fn note(changed: *Changed, name: []const u8) void {
            for (changed.names[0..changed.names_len]) |n| {
                if (std.mem.eql(u8, changed.bytes[n[0]..][0..n[1]], name)) return;
            }
            const full = changed.names_len == changed.names.len or
                changed.bytes_len + name.len > changed.bytes.len;
            if (full) {
                changed.listing = true;
                return;
            }
            @memcpy(changed.bytes[changed.bytes_len..][0..name.len], name);
            changed.names[changed.names_len] = .{ changed.bytes_len, @intCast(name.len) };
            changed.names_len += 1;
            changed.bytes_len += @intCast(name.len);
        }

        /// The templates written, for generation; null for all.
        fn written(changed: *const Changed, out: *[16][]const u8) ?[]const []const u8 {
            if (changed.listing) return null;
            for (changed.names[0..changed.names_len], out[0..changed.names_len]) |n, *o| {
                o.* = changed.bytes[n[0]..][0..n[1]];
            }
            return out[0..changed.names_len];
        }
    };

    fn start(gpa: Allocator, io: Io, options: Options) !Watch {
        const fd: i32 = @intCast(try syscall(linux.inotify_init1(linux.IN.CLOEXEC)));
        var watch: Watch = .{ .fd = fd };
        errdefer watch.deinit(gpa);
        const mask = linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO | linux.IN.CREATE | linux.IN.DELETE;
        watch.root = try watch.add(gpa, options.app.dir, mask, false);
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
            _ = try watch.add(gpa, path, mask, in_static(options, entry.path));
            try walker.enter(io, entry);
        }
        return watch;
    }

    fn deinit(watch: *Watch, gpa: Allocator) void {
        watch.static.deinit(gpa);
        _ = linux.close(watch.fd);
        watch.* = undefined;
    }

    fn add(watch: *Watch, gpa: Allocator, path: []const u8, mask: u32, static: bool) !i32 {
        const path_z = try gpa.dupeSentinel(u8, path, 0);
        defer gpa.free(path_z);
        const wd: i32 = @intCast(try syscall(linux.inotify_add_watch(watch.fd, path_z, mask)));
        if (static) try watch.static.put(gpa, wd, {});
        return wd;
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
        const buffer = &watch.buffer;
        const len = try syscall(linux.read(watch.fd, buffer, buffer.len));
        var at: usize = 0;
        var source = false;
        while (at < len) {
            const event: *const linux.inotify_event = @ptrCast(@alignCast(&buffer[at]));
            const name_bytes = buffer[at + @sizeOf(linux.inotify_event) ..][0..event.len];
            const name = std.mem.sliceTo(name_bytes, 0);
            if (event.mask & linux.IN.Q_OVERFLOW != 0) {
                watch.changed.other = true;
                watch.changed.listing = true;
                source = true;
            } else if (watch.static.contains(event.wd)) {
                watch.changed.other = true;
                source = true;
            } else switch (kind_of(name)) {
                .templates => {
                    watch.changed.templates = true;
                    const appeared = event.mask & (linux.IN.CREATE | linux.IN.DELETE) != 0;
                    if (appeared or event.wd != watch.root) {
                        watch.changed.listing = true;
                    } else {
                        watch.changed.note(name[0 .. name.len - ".rocstache".len]);
                    }
                    source = true;
                },
                .roc, .sql, .static => {
                    watch.changed.other = true;
                    source = true;
                },
                .other => {},
            }
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
