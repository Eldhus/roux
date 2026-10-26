//! `roux dev APP.roc`: the app built, run, and rebuilt as it is edited.
//!
//! One loop, one pass at a time, so a build never races a generator. A
//! pass hashes the app's sources by kind and runs only what changed: a
//! query (`db/*.sql`) runs roux-db; then the templates are generated, which
//! rewrites a `Page.roc` only when its contract changed, and the program
//! (`templates.bin`) when the markup did. Markup alone: the running app
//! is told to reread the program (SIGUSR1), no compiler, no restart. Roc
//! changed (an edit, or a rewritten `Page.roc`): roc builds (`--opt=dev`)
//! while glue lays out any changed contract, then the attach and a restart.
//! Content decides, never mtimes: a save that changes nothing, and the
//! generators' own writes, cost nothing more.
//!
//! The app runs with `ROUX_DEV` set to the build's number, so the host
//! answers `/_dev/events` and adds the reload script to HTML (host/dev.zig):
//! a restart drops the browser's stream, it reconnects to the new build
//! and reloads. It also gets `ROUX_DEV_TEMPLATES`, `ROUX_DEV_ERRORS`,
//! `ROUX_DEV_STATS`, `ROUX_DEV_STATIC` and `ROUX_DEV_LISTENING` (files in
//! the build directory) and `ROUX_DEV_LOAD` (roux-load beside roux, when
//! there). A failed build leaves the last good one serving.
//!
//! A restart holds its requests: roux dev keeps a socket where the app
//! listens, as systemd does in production, and hands it to each build
//! (`ROUX_DEV_LISTEN`, its descriptor); a client connecting while one
//! build stops and the next starts waits in its queue (`State.hold`).
//!
//! The app is built into the build directory (`.roux/main/main`), never
//! beside `main.roc`: a binary there comes only from `roux build`, so a
//! dev build is never shipped by mistake. It runs in the app's directory,
//! as a built one does. Its static files are the directory its `init!`
//! names, which the host writes to `ROUX_DEV_STATIC` as it starts; from
//! then on an edit there restarts the app (the host reads them at startup).
//!
//! One line per pass on stderr, for people and agents to wait on:
//! `roux dev: build 3 ok (templates reread, 2) in 0.8 ms` for markup,
//! `roux dev: build 4 ok (roc) in 1097 ms` for a restart, or `... failed`.

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
};

/// What the last failed pass said, beside the program: the running app
/// reads it on SIGUSR2 (`ROUX_DEV_ERRORS`).
const errors_name = "dev-errors.txt";
/// roc's messages in a pass, read back into the pass's report.
const roc_log_name = "roc.log";
/// roux-db's, likewise.
const roux_db_log_name = "roux-db.log";
/// The last good pass, which the app serves at `/_dev/stats`
/// (`ROUX_DEV_STATS`): what was built, and the microseconds from the save
/// noticed to the app told (a reread) or started again (a restart).
const stats_name = "dev-stats.json";
/// The app's static directory, as its `init!` returned it, written by the
/// host as it starts (`ROUX_DEV_STATIC`; empty: none).
const static_name = "dev-static.txt";
/// Where the app listens, as the host chose it (`ROUX_DEV_LISTENING`:
/// `127.0.0.1:8080`; empty until it has).
const listening_name = "dev-listening.txt";
/// The held socket's queue: the host's own (host.zig, `listen_on`).
const held_backlog = 4096;

/// The exit code of an app asking roux dev to start it again (the host's
/// `/_dev/restart`; host/dev.zig's `restart_code`, the same).
const restart_code = 75;

/// How long the app's directory must be quiet after an edit before a pass:
/// one pass for a save through a temp file, or many files saved at once
/// (2026-10-16: Zed and nvim save in place; a tool that renames a temp file
/// over the file does it 0.2-0.4 ms after making it).
const quiet_ms = 10;
/// At most 1 s of edits gathered into one pass.
const quiet_windows_max = 100;

const files_max = 4096;
const directories_max = 256;

/// What the app is built from, a hash of each kind's paths and contents.
const Digests = struct {
    roc: u64 = 0,
    templates: u64 = 0,
    /// The queries: `db/*.sql` only (what roux-db reads).
    sql: u64 = 0,
    static: u64 = 0,
};

const Kind = enum { roc, templates, sql, static, other };

pub fn run(
    gpa: Allocator,
    io: Io,
    options_given: Options,
    environ: *const std.process.Environ.Map,
) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file.interface;
    defer stderr.flush() catch {};
    // What lasts as long as roux dev: the build's paths.
    var lasting_state: std.heap.ArenaAllocator = .init(gpa);
    defer lasting_state.deinit();
    const lasting = lasting_state.allocator();
    // The binary in the build directory, named as roux build names it.
    var options = options_given;
    const out_path = (try pipeline.Paths.of(lasting, options.app)).out_path;
    options.app.output = try std.fs.path.join(lasting, &.{ out_path, options.app.name });
    try Io.Dir.cwd().createDirPath(io, out_path);
    var watch: Watch = try .start(gpa, io, options, out_path);
    defer watch.deinit(gpa);
    var state: State = .{
        .options = options,
        .static = &watch.static,
        .environ = environ,
        .cache = .init(gpa),
    };
    defer state.cache.deinit();
    defer state.release(io); // after the app has stopped
    defer state.stop(io);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    stop_on_signals();
    // Until SIGINT or SIGTERM: roux dev runs as long as it is wanted.
    while (!stopping.load(.monotonic)) {
        _ = arena_state.reset(.retain_capacity);
        if (watch.static_told) try state.static_said(arena_state.allocator(), io, &watch, stderr);
        if (watch.listening_told) try state.listening_said(arena_state.allocator(), io, &watch);
        const changed = watch.changed;
        watch.changed.reset();
        var names: [16][]const u8 = undefined;
        const pass: Pass = .{
            .markup_only = changed.markup_only(),
            .written = changed.written(&names),
        };
        // What the pass says (roux's lines, the generator's refusals,
        // roc's messages) goes to the terminal, and when it failed, to
        // the page too: the running app shows it over the page.
        const arena = arena_state.allocator();
        var report: Io.Writer.Allocating = .init(arena);
        const failed = if (state.pass(arena, io, &report.writer, pass)) |_|
            false
        else |err| switch (err) {
            error.OutOfMemory => return err,
            else => true,
        };
        stderr.writeAll(report.written()) catch {};
        if (failed) {
            state.tell_page(arena, io, report.written());
        } else if (state.page_told) {
            state.tell_page(arena, io, "");
        }
        stderr.flush() catch {};
        try state.wait(arena, io, &watch, stderr);
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
    _ = linux.sigaction(.USR2, &ignore, null); // the same, for a failure's news
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
    /// The app's static directory, once its host has said (`Watch.static`).
    static: *const ?[]const u8,
    environ: *const std.process.Environ.Map,
    /// What generation keeps between passes (tools/rocstache/cache.zig:
    /// each template's parse, contract and code, the layouts, the outputs'
    /// hashes).
    cache: rocstache.generate.Cache,
    built: Digests = .{},
    build: u32 = 0,
    /// The rereads of the templates' program by the running build.
    rereads: u32 = 0,
    child: ?std.process.Child = null,
    /// The child's pidfd, readable when it exits; -1 with no child.
    child_fd: i32 = -1,
    /// The socket where the app listens, held across its restarts (`hold`).
    held: ?Io.net.Server = null,
    /// The last pass failed: the next that finds nothing to build says so.
    failing: bool = false,
    /// The running app shows a failure over its pages (`tell_page`).
    page_told: bool = false,

    /// Until a source changes; the app exiting on its own is said, and
    /// waits for an edit too, unless it asked to be started again.
    fn wait(state: *State, arena: Allocator, io: Io, watch: *Watch, stderr: *Io.Writer) !void {
        while (true) {
            switch (try watch.wait(state.child_fd)) {
                .source, .stopping => return,
                .exited => if (state.exited(io, stderr)) {
                    const paths: pipeline.Paths = try .of(arena, state.options.app);
                    state.restart(arena, io, paths) catch |err| {
                        stderr.print("roux dev: build {d} would not start again ({t})\n", .{
                            state.build,
                            err,
                        }) catch {};
                    };
                    stderr.print("roux dev: build {d} started again\n", .{state.build}) catch {};
                },
            }
            stderr.flush() catch {};
        }
    }

    /// The app named its static files as it started: watched from now, and
    /// what they are now is what it serves (no restart for them).
    fn static_said(
        state: *State,
        arena: Allocator,
        io: Io,
        watch: *Watch,
        stderr: *Io.Writer,
    ) !void {
        watch.static_told = false;
        if (!watch.learn_static(stderr)) return;
        state.built.static = (try digests(arena, io, state.options.app.dir, watch.static)).static;
    }

    /// `stats_name` for the pass that just succeeded; a failure to write it
    /// costs only the stats.
    fn write_stats(state: *State, arena: Allocator, io: Io, what: []const u8, micros: i64) void {
        const paths = pipeline.Paths.of(arena, state.options.app) catch return;
        var dir = Io.Dir.cwd().openDir(io, paths.out_path, .{}) catch return;
        defer dir.close(io);
        const text = std.fmt.allocPrint(
            arena,
            "{{\"build\":{d},\"reread\":{d},\"built\":\"{s}\",\"micros\":{d}}}\n",
            .{ state.build, state.rereads, what, micros },
        ) catch return;
        dir.writeFile(io, .{ .sub_path = stats_name, .data = text }) catch {};
    }

    /// The running app told what the last pass said (`errors_name`, then
    /// SIGUSR2: host/dev.zig), shown over its pages; "" takes it away.
    fn tell_page(state: *State, arena: Allocator, io: Io, text: []const u8) void {
        const child = state.child orelse return;
        const paths = pipeline.Paths.of(arena, state.options.app) catch return;
        var dir = Io.Dir.cwd().openDir(io, paths.out_path, .{}) catch return;
        defer dir.close(io);
        dir.writeFile(io, .{ .sub_path = errors_name, .data = text }) catch return;
        _ = linux.kill(child.id.?, .USR2);
        state.page_told = text.len > 0;
    }

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
            try digests(arena, io, app.dir, state.static.*);
        const paths: pipeline.Paths = try .of(arena, app);
        // roux-db runs when roux build would: the app has `db/schema.sql`.
        if (before.sql != state.built.sql and pipeline.has_queries(io, app)) {
            queries(arena, io, paths, app, stderr) catch |err| return state.failed(stderr, err);
        }
        const built = state.generate_and_roc(arena, io, paths, before, p, stderr) catch |err|
            return state.failed(stderr, err);
        const now = built.now;
        const roc = now.roc != state.built.roc;
        const static = now.static != state.built.static;
        const templates = built.program_changed;
        // Only markup changed, and the app runs: it rereads the program
        // (`templates.bin`), no attach and no restart, its state kept.
        if (!roc and !static and state.child != null) {
            state.built = now;
            if (templates) return state.reread(arena, io, stderr, start);
            // Nothing changed at all. (Exited: start it again, below; it
            // may have been a passing failure.)
            if (state.failing) {
                const again = "roux dev: the sources are build {d}'s again; it serves\n";
                try stderr.print(again, .{state.build});
            }
            state.failing = false;
            return;
        }
        // The app reads its program from `templates.bin` in development, so
        // only Roc (or no binary yet) needs the program attached again.
        if (roc or state.build == 0) {
            pipeline.attach(arena, io, paths, app, stderr) catch |err| {
                return state.failed(stderr, err);
            };
        }
        state.built = now;
        state.build += 1;
        state.rereads = 0;
        state.failing = false;
        const took = start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
        const micros = @divTrunc(took, std.time.ns_per_us);
        state.write_stats(arena, io, built_what(roc, templates), @intCast(micros));
        try state.restart(arena, io, paths);
        try stderr.print("roux dev: build {d} ok ({s}) in {d} ms\n", .{
            state.build,
            built_what(roc, templates),
            pipeline.milliseconds(start, Io.Timestamp.now(io, .awake)),
        });
    }

    /// The templates generated and, when Roc changed (an edit, or a
    /// contract that rewrote its Page.roc), roc built while glue lays the
    /// contracts out: what the sources are now, and whether the program
    /// changed.
    fn generate_and_roc(
        state: *State,
        arena: Allocator,
        io: Io,
        paths: pipeline.Paths,
        before: Digests,
        p: Pass,
        stderr: *Io.Writer,
    ) !struct { now: Digests, program_changed: bool } {
        const app = state.options.app;
        var generation =
            try pipeline.begin(arena, io, paths, app, &state.cache, p.written, stderr);
        const now = if (generation.modules_changed)
            digests(arena, io, app.dir, state.static.*) catch |err| {
                rocstache.generate.abandon(io, &generation);
                return err;
            }
        else
            before;
        const building = now.roc != state.built.roc;
        // roc's messages to a file, read into the report once it is done.
        var out = Io.Dir.cwd().openDir(io, paths.out_path, .{}) catch |err| {
            rocstache.generate.abandon(io, &generation);
            return err;
        };
        defer out.close(io);
        const log: ?Io.File = if (building)
            out.createFile(io, roc_log_name, .{ .truncate = true }) catch |err| {
                rocstache.generate.abandon(io, &generation);
                return err;
            }
        else
            null;
        defer if (log) |file| file.close(io);
        var roc: ?std.process.Child = if (building)
            pipeline.start_roc(io, paths, app, .dev, log) catch |err| {
                rocstache.generate.abandon(io, &generation);
                return err;
            }
        else
            null;
        const generated = rocstache.generate.finish(arena, io, &generation, stderr) catch |err| {
            if (roc) |*child| child.kill(io);
            return err;
        };
        if (roc) |*child| {
            const waited = pipeline.wait_roc(io, child);
            const said = out.readFileAlloc(io, roc_log_name, arena, .limited(1 << 20)) catch "";
            stderr.writeAll(said) catch {};
            try waited;
        }
        return .{ .now = now, .program_changed = generated.program_changed };
    }

    /// The running app told to reread the templates' program (SIGUSR1;
    /// host/templates.zig): it swaps it in at its next render and tells
    /// the browser, whose page reloads.
    fn reread(
        state: *State,
        arena: Allocator,
        io: Io,
        stderr: *Io.Writer,
        start: Io.Timestamp,
    ) !void {
        const nanoseconds = start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
        state.rereads += 1;
        state.failing = false;
        // Before the signal: the page reloads at once and asks for them.
        const micros = @divTrunc(nanoseconds, std.time.ns_per_us);
        state.write_stats(arena, io, "templates", @intCast(micros));
        // A failure shown is taken away first: the reloaded page's stream
        // reads the errors file as it connects.
        if (state.page_told) state.tell_page(arena, io, "");
        _ = linux.kill(state.child.?.id.?, .USR1);
        const tenths: u64 = @intCast(@divTrunc(nanoseconds, 100 * std.time.ns_per_us));
        try stderr.print("roux dev: build {d} ok (templates reread, {d}) in {d}.{d} ms\n", .{
            state.build,
            state.rereads,
            tenths / 10,
            tenths % 10,
        });
    }

    /// The app exited on its own (a crash, a refused start): said, and
    /// collected; the next save starts it again.
    /// Says whether the app asked to be started again (`restart_code`: its
    /// `/_dev/restart`, from the page of an `init!` that failed).
    fn exited(state: *State, io: Io, stderr: *Io.Writer) bool {
        var child = state.child orelse return false;
        _ = linux.close(state.child_fd);
        state.child_fd = -1;
        state.child = null;
        const term = child.wait(io) catch return false;
        // Asked to start again, its socket stays held for the next; down
        // until an edit, its clients are refused rather than kept waiting.
        if (term != .exited or term.exited != restart_code) state.release(io);
        switch (term) {
            .exited => |code| {
                if (code == restart_code) return true;
                stderr.print("roux dev: build {d} exited, code {d}\n", .{
                    state.build,
                    code,
                }) catch {};
            },
            .signal => |signal| stderr.print("roux dev: build {d} killed by signal {t}\n", .{
                state.build,
                signal,
            }) catch {},
            .stopped, .unknown => {
                stderr.print("roux dev: build {d} stopped\n", .{state.build}) catch {};
            },
        }
        return false;
    }

    /// The last good build keeps serving. A compiler's failure was printed
    /// by it (`Invalid`, `ChildFailed`); any other is named here (a tool
    /// that would not start, a file that could not be written).
    fn failed(state: *State, stderr: *Io.Writer, err: anyerror) anyerror {
        state.failing = true;
        stderr.print("roux dev: build {d} failed", .{state.build + 1}) catch {};
        switch (err) {
            error.Invalid, error.ChildFailed, error.AttachFailed => {},
            else => stderr.print(" ({t})", .{err}) catch {},
        }
        stderr.print("; build {d} still serving\n", .{state.build}) catch {};
        return err;
    }

    /// The old build stopped (its database closed), the new one started,
    /// on two shards unless `ROUX_SHARDS` says otherwise (host.zig,
    /// shard_count: development needs no more, and two rings fit the locked
    /// memory while the old process's are still being freed).
    fn restart(state: *State, arena: Allocator, io: Io, paths: pipeline.Paths) !void {
        state.hold(io, try std.fs.path.join(arena, &.{ paths.out_path, listening_name }));
        state.stop(io);
        var environ = try state.environ.clone(arena);
        try environ.put("ROUX_DEV", try std.fmt.allocPrint(arena, "{d}", .{state.build}));
        const program = try std.fs.path.join(arena, &.{
            try Io.Dir.cwd().realPathFileAlloc(io, paths.out_path, arena),
            rocstache.generate.program_name,
        });
        try environ.put("ROUX_DEV_TEMPLATES", program);
        const out = std.fs.path.dirname(program).?;
        const errors = try std.fs.path.join(arena, &.{ out, errors_name });
        try environ.put("ROUX_DEV_ERRORS", errors);
        try environ.put("ROUX_DEV_STATS", try std.fs.path.join(arena, &.{ out, stats_name }));
        try environ.put("ROUX_DEV_STATIC", try std.fs.path.join(arena, &.{ out, static_name }));
        // roux-load, beside this roux: the page's race from outside the browser.
        var self_buffer: [std.fs.max_path_bytes]u8 = undefined;
        if (Io.Dir.readLinkAbsolute(io, "/proc/self/exe", &self_buffer)) |self_len| {
            const bin = std.fs.path.dirname(self_buffer[0..self_len]) orelse ".";
            const loader = try std.fs.path.join(arena, &.{ bin, "roux-load" });
            if (Io.Dir.cwd().access(io, loader, .{})) |_| {
                try environ.put("ROUX_DEV_LOAD", loader);
            } else |_| {}
        } else |_| {}
        // A new build shows no failure: the file it reads one from emptied,
        // or a failure fixed by this build is shown over its pages again.
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = errors, .data = "" });
        state.page_told = false;
        // Where it listens is said by this build, not an earlier one.
        const listening = try std.fs.path.join(arena, &.{ out, listening_name });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = listening, .data = "" });
        try environ.put("ROUX_DEV_LISTENING", listening);
        _ = environ.swapRemove("ROUX_DEV_LISTEN");
        var held: [1]Io.File = undefined;
        if (state.held) |server| {
            held[0] = .{ .handle = server.socket.handle, .flags = .{ .nonblocking = false } };
            const fd = try std.fmt.allocPrint(arena, "{d}", .{server.socket.handle});
            try environ.put("ROUX_DEV_LISTEN", fd);
        }
        if (state.options.port) |port| try environ.put("ROUX_PORT", port);
        if (environ.get("ROUX_SHARDS") == null) try environ.put("ROUX_SHARDS", "2");
        // From the build directory, in the app's: where a built app runs.
        const binary = try std.fs.path.join(arena, &.{ out, state.options.app.name });
        const child = try std.process.spawn(io, .{
            .argv = &.{binary},
            .cwd = .{ .path = state.options.app.dir },
            .environ_map = &environ,
            .stdin = .ignore,
            .inherit_files = if (state.held != null) &held else &.{},
        });
        state.child = child;
        state.child_fd = @intCast(try syscall(linux.pidfd_open(child.id.?, 0)));
    }

    /// Before the running build stops, its socket held here too, so a
    /// client connecting while the next one starts waits in the queue
    /// rather than being refused. The address is the one the build said
    /// (`listening_path`), bound beside its own (SO_REUSEPORT, which the
    /// host sets as Zig's `reuse_address` does); once held, the next builds
    /// listen on this one (host.zig, `dev_listener`). Held until the address
    /// moves or a build exits on its own. Without one (no build running,
    /// nothing said yet, a bind refused) a restart refuses for its while.
    fn hold(state: *State, io: Io, listening_path: []const u8) void {
        if (state.child == null) return; // a build that asked to start again keeps its own
        const address = listening_address(io, listening_path) orelse return;
        if (state.held) |held| {
            if (held.socket.address.eql(&address)) return;
            state.release(io);
        }
        assert(state.held == null);
        state.held = address.listen(io, .{
            .reuse_address = true,
            .kernel_backlog = held_backlog,
        }) catch null;
    }

    /// The build said where it listens: a socket held at another address
    /// (its port changed) is let go now, so clients there are refused rather
    /// than kept waiting; the next restart holds the new one.
    fn listening_said(state: *State, arena: Allocator, io: Io, watch: *Watch) !void {
        watch.listening_told = false;
        const held = state.held orelse return;
        const path = try std.fs.path.join(arena, &.{ watch.out_path, listening_name });
        const address = listening_address(io, path) orelse return;
        if (!held.socket.address.eql(&address)) state.release(io);
    }

    fn release(state: *State, io: Io) void {
        var held = state.held orelse return;
        held.deinit(io);
        state.held = null;
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

/// Where the build said it listens (`listening_name`); null until it has
/// (still in `init!`: roux dev empties the file before each start).
fn listening_address(io: Io, path: []const u8) ?Io.net.IpAddress {
    var buffer: [96]u8 = undefined;
    return address_said(Io.Dir.cwd().readFile(io, path, &buffer) catch return null);
}

/// The address as the host writes it (`{f}`, host.zig's `dev_listen_start`).
fn address_said(said: []const u8) ?Io.net.IpAddress {
    const text = std.mem.trimEnd(u8, said, "\n");
    if (text.len == 0) return null;
    return Io.net.IpAddress.parseLiteral(text) catch null;
}

test address_said {
    var buffer: [96]u8 = undefined;
    for ([_][]const u8{ "127.0.0.1", "0.0.0.0", "::1", "fd7a:115c:a1e0::1" }) |host| {
        const address = try Io.net.IpAddress.parse(host, 8080);
        const said = try std.fmt.bufPrint(&buffer, "{f}", .{address});
        try std.testing.expect(address_said(said).?.eql(&address));
    }
    try std.testing.expect(address_said("") == null); // not yet said
    try std.testing.expect(address_said("localhost:8080") == null);
}

/// roux-db on the app's queries, its messages into the pass's report (and
/// so over the page when it refuses one), as roc's are.
fn queries(
    arena: Allocator,
    io: Io,
    paths: pipeline.Paths,
    app: pipeline.App,
    report: *Io.Writer,
) !void {
    try Io.Dir.cwd().createDirPath(io, paths.out_path);
    var out = try Io.Dir.cwd().openDir(io, paths.out_path, .{});
    defer out.close(io);
    const log = try out.createFile(io, roux_db_log_name, .{ .truncate = true });
    defer log.close(io);
    const ran = pipeline.query_types(arena, io, app, log);
    const said = out.readFileAlloc(io, roux_db_log_name, arena, .limited(1 << 20)) catch "";
    report.writeAll(said) catch {};
    return ran;
}

/// What a pass built, for its line.
fn built_what(roc: bool, templates: bool) []const u8 {
    if (roc and templates) return "roc, templates";
    if (roc) return "roc";
    if (templates) return "templates";
    return "static";
}

/// Whether a path in the app's directory is under its static files (the
/// directory itself included; `static` normalized by `Watch.learn_static`).
fn in_static(static_or_null: ?[]const u8, path: []const u8) bool {
    const static = static_or_null orelse return false;
    if (!std.mem.startsWith(u8, path, static)) return false;
    return path.len == static.len or path[static.len] == '/';
}

test in_static {
    try std.testing.expect(in_static("static", "static"));
    try std.testing.expect(in_static("static", "static/css/a.css"));
    try std.testing.expect(!in_static("static", "static2/a.css"));
    try std.testing.expect(!in_static("static", "templates"));
    try std.testing.expect(!in_static(null, "static"));
}

/// A static directory as `init!` named it, relative to the app's, as the
/// watches name theirs (`static`, from `./static/`); "" for none; null for
/// one not strictly inside the app's directory (absolute, `..`, the app's own).
fn normalized(said: []const u8) ?[]const u8 {
    if (said.len == 0) return "";
    if (said[0] == '/') return null;
    var path = std.mem.trimEnd(u8, said, "/");
    while (std.mem.startsWith(u8, path, "./")) path = path[2..];
    if (path.len == 0 or std.mem.eql(u8, path, ".")) return null;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return null;
        if (part.len == 0) return null;
    }
    return path;
}

test normalized {
    try std.testing.expectEqualStrings("static", normalized("static").?);
    try std.testing.expectEqualStrings("static", normalized("./static/").?);
    try std.testing.expectEqualStrings("a/b", normalized("a/b").?);
    try std.testing.expectEqualStrings("", normalized("").?);
    try std.testing.expect(normalized("/srv/static") == null);
    try std.testing.expect(normalized("../shared") == null);
    try std.testing.expect(normalized("a/../b") == null);
    try std.testing.expect(normalized(".") == null);
}

fn kind_of(name: []const u8) Kind {
    if (std.mem.endsWith(u8, name, ".rocstache")) return .templates;
    if (std.mem.endsWith(u8, name, ".roc")) return .roc;
    if (std.mem.endsWith(u8, name, ".sql")) return .sql;
    return .other;
}

/// Each kind's hash over the app's directory (hidden directories and
/// `.roux/` left out), static files only under `static`.
fn digests(arena: Allocator, io: Io, app_dir: []const u8, static: ?[]const u8) !Digests {
    var dir = try Io.Dir.cwd().openDir(io, app_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walkSelectively(arena);
    defer walker.deinit();
    var hashes: [4]std.hash.Wyhash = @splat(.init(0));
    var files: u32 = 0;
    while (try walker.next(io)) |entry| {
        if (entry.basename[0] == '.') continue;
        if (entry.kind == .directory) {
            try walker.enter(io, entry);
            continue;
        }
        if (entry.kind != .file) continue;
        const kind: Kind = if (in_static(static, entry.path)) .static else kind_of(entry.basename);
        if (kind == .other) continue;
        // A `.sql` elsewhere (another app's, beside this one) is no query
        // of this app's.
        if (kind == .sql and !std.mem.startsWith(u8, entry.path, "db/")) continue;
        files += 1;
        if (files > files_max) return error.TooManyFiles;
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
    };
}

/// inotify over the app's directories (hidden ones left out), those made
/// while roux dev runs too.
const Watch = struct {
    fd: i32,
    gpa: Allocator,
    io: Io,
    options: Options,
    /// The build directory, from the working directory.
    out_path: []const u8,
    /// Its watch: only `static_name` written there counts.
    out_wd: i32 = -1,
    /// Each watch's directory, from the app's (`""` for the app's own).
    paths: std.AutoHashMapUnmanaged(i32, []const u8) = .empty,
    /// The app's static directory, from the app's (owned); null: none, or
    /// not said yet.
    static: ?[]const u8 = null,
    /// Which watches are the static directory's (by watch descriptor).
    static_wds: std.AutoHashMapUnmanaged(i32, void) = .empty,
    /// The host wrote `static_name` since the last pass.
    static_told: bool = false,
    /// The host wrote `listening_name` since the last pass.
    listening_told: bool = false,
    /// What the events named since the last pass.
    changed: Changed = .{},
    /// Where events are read (a field: a safe build fills a local
    /// `undefined` buffer on every read).
    buffer: [64 * 1024]u8 align(@alignOf(linux.inotify_event)) = undefined,

    const Changed = struct {
        templates: bool = false,
        /// Roc, SQL, static files, or events lost (the queue overflowed).
        other: bool = false,
        /// A template created or deleted, one outside `templates/`, or more
        /// than `names` holds: generation lists the directory and reads
        /// every template.
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

    fn start(gpa: Allocator, io: Io, options: Options, out_path: []const u8) !Watch {
        const fd: i32 = @intCast(try syscall(linux.inotify_init1(linux.IN.CLOEXEC)));
        var watch: Watch = .{
            .fd = fd,
            .gpa = gpa,
            .io = io,
            .options = options,
            .out_path = out_path,
        };
        errdefer watch.deinit(gpa);
        _ = try watch.add_tree("");
        const out = try std.posix.toPosixPath(out_path);
        const mask = linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO;
        watch.out_wd = @intCast(try syscall(linux.inotify_add_watch(fd, &out, mask)));
        return watch;
    }

    fn deinit(watch: *Watch, gpa: Allocator) void {
        var paths = watch.paths.valueIterator();
        while (paths.next()) |path| gpa.free(path.*);
        watch.paths.deinit(gpa);
        watch.static_wds.deinit(gpa);
        if (watch.static) |static| gpa.free(static);
        _ = linux.close(watch.fd);
        watch.* = undefined;
    }

    /// The static directory the host wrote (`static_name`) taken as the
    /// app's: whether it changed. One outside the app's directory is said
    /// and not watched (its edits wait for a restart, as without roux dev).
    fn learn_static(watch: *Watch, stderr: *Io.Writer) bool {
        const gpa = watch.gpa;
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        var dir = Io.Dir.cwd().openDir(watch.io, watch.out_path, .{}) catch return false;
        defer dir.close(watch.io);
        const said = dir.readFile(watch.io, static_name, &buffer) catch return false;
        const static = normalized(said) orelse {
            stderr.print("roux dev: static files in {s} are outside the app's directory; " ++
                "not watched\n", .{said}) catch {};
            return watch.set_static(null);
        };
        return watch.set_static(if (static.len == 0) null else gpa.dupe(u8, static) catch null);
    }

    /// `static` (owned) as the app's static directory, and its watches
    /// marked: whether it changed.
    fn set_static(watch: *Watch, static: ?[]const u8) bool {
        const gpa = watch.gpa;
        const old = watch.static;
        const same = if (old) |o|
            (if (static) |s| std.mem.eql(u8, o, s) else false)
        else
            static == null;
        if (same) {
            if (static) |s| gpa.free(s);
            return false;
        }
        if (old) |o| gpa.free(o);
        watch.static = static;
        watch.static_wds.clearRetainingCapacity();
        var entries = watch.paths.iterator();
        while (entries.next()) |entry| {
            if (in_static(static, entry.value_ptr.*)) {
                watch.static_wds.put(gpa, entry.key_ptr.*, {}) catch {};
            }
        }
        return true;
    }

    /// `relative` (from the app's directory) watched, and each directory
    /// under it that is not hidden; its own watch descriptor.
    fn add_tree(watch: *Watch, relative: []const u8) !i32 {
        const gpa = watch.gpa;
        const io = watch.io;
        const top = try watch.add(relative);
        const path = try std.fs.path.join(gpa, &.{ watch.options.app.dir, relative });
        defer gpa.free(path);
        var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walkSelectively(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .directory or entry.basename[0] == '.') continue;
            const below = try std.fs.path.join(gpa, &.{ relative, entry.path });
            defer gpa.free(below);
            _ = try watch.add(below);
            try walker.enter(io, entry);
        }
        return top;
    }

    fn add(watch: *Watch, relative: []const u8) !i32 {
        const gpa = watch.gpa;
        if (watch.paths.count() == directories_max) return error.TooManyDirectories;
        const path = try std.fs.path.joinZ(gpa, &.{ watch.options.app.dir, relative });
        defer gpa.free(path);
        const mask = linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO | linux.IN.CREATE | linux.IN.DELETE;
        const wd: i32 = @intCast(try syscall(linux.inotify_add_watch(watch.fd, path, mask)));
        const entry = try watch.paths.getOrPut(gpa, wd);
        if (entry.found_existing) gpa.free(entry.value_ptr.*);
        entry.value_ptr.* = try gpa.dupe(u8, relative);
        if (in_static(watch.static, relative)) try watch.static_wds.put(gpa, wd, {});
        return wd;
    }

    /// Whether `wd` watches the app's `templates/`, where an edit names
    /// its template (elsewhere a `.rocstache` is no template of the app's).
    fn is_templates(watch: *const Watch, wd: i32) bool {
        const path = watch.paths.get(wd) orelse return false;
        return std.mem.eql(u8, path, rocstache.generate.templates_dir);
    }

    /// A directory made (or moved in) under a watched one: it and what it
    /// holds are watched now, and what it holds may be sources.
    fn appeared(watch: *Watch, wd: i32, name: []const u8) void {
        const parent = watch.paths.get(wd) orelse return;
        const relative = std.fs.path.join(watch.gpa, &.{ parent, name }) catch return;
        defer watch.gpa.free(relative);
        _ = watch.add_tree(relative) catch {};
        watch.changed.other = true;
        watch.changed.listing = true;
    }

    const Woken = enum { source, exited, stopping };

    /// Blocks until a source changes, then drains the events already
    /// queued; or until the app (`child_fd`, a pidfd; -1 for none) exits,
    /// or a signal asks roux dev to stop.
    fn wait(watch: *Watch, child_fd: i32) !Woken {
        while (!stopping.load(.monotonic)) {
            switch (try watch.read(-1, child_fd)) {
                .source => break,
                .exited => return .exited,
                .quiet, .timeout => {},
            }
        } else return .stopping;
        // Then until the directory is quiet `quiet_ms`, every kind of edit
        // alike: a save through a temp file and a rename (0.2-0.4 ms
        // apart), several files saved at once, a
        // checkout, each one pass. Bounded: a directory that never goes
        // quiet still gets its pass.
        for (0..quiet_windows_max) |_| {
            if (try watch.read(quiet_ms, -1) == .timeout) break;
            if (stopping.load(.monotonic)) return .stopping;
        }
        return .source;
    }

    /// What happened within `timeout` (ms; -1 forever): a source changed,
    /// the app exited, only other events (`quiet`), or none (`timeout`).
    fn read(
        watch: *Watch,
        timeout: i32,
        child_fd: i32,
    ) !enum { source, exited, quiet, timeout } {
        var fds = [_]linux.pollfd{
            .{ .fd = watch.fd, .events = linux.POLL.IN },
            .{ .fd = child_fd, .events = linux.POLL.IN }, // poll skips a negative fd
        };
        if (try syscall(linux.poll(&fds, fds.len, timeout)) == 0) return .timeout;
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
            const made = linux.IN.CREATE | linux.IN.MOVED_TO;
            if (event.mask & linux.IN.Q_OVERFLOW != 0) {
                watch.changed.other = true;
                watch.changed.listing = true;
                watch.static_told = true;
                watch.listening_told = true;
                source = true;
            } else if (event.wd == watch.out_wd) {
                // The build's own files: only the host's word counts.
                if (std.mem.eql(u8, name, static_name)) {
                    watch.static_told = true;
                    source = true;
                } else if (std.mem.eql(u8, name, listening_name)) {
                    watch.listening_told = true;
                    source = true;
                }
            } else if (event.mask & linux.IN.ISDIR != 0) {
                if (event.mask & made != 0 and name.len > 0 and name[0] != '.') {
                    watch.appeared(event.wd, name);
                    source = true;
                }
            } else if (watch.static_wds.contains(event.wd)) {
                watch.changed.other = true;
                source = true;
            } else switch (kind_of(name)) {
                .templates => {
                    watch.changed.templates = true;
                    const listed = event.mask & (linux.IN.CREATE | linux.IN.DELETE) != 0;
                    if (listed or !watch.is_templates(event.wd)) {
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
