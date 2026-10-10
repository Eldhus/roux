//! The roux host: fourneau running a Roc application.
//!
//! `roc build` links this library (libhost.a) with the compiled app and
//! musl into one static executable; musl's crt1.o calls our `main`.
//!
//! Each request runs on its connection's fiber: the host builds the
//! request record, calls the app's `respond!` (`roc_respond_for_host`),
//! and sends what it returns. A Roc effect that waits (reading the body)
//! is plain blocking-style code over `std.Io`, so it yields the fiber, not
//! a thread.
//!
//! The host runs one shard per CPU it may use: a thread with its own
//! single-threaded `Evented`, listener (SO_REUSEPORT) and connection slots,
//! sharing nothing but the app's context (fourneau's experiment 1). So every Roc
//! allocation of a request is made and freed on its shard's thread, and the
//! host counts them per thread: a shard with no request in flight holds no
//! more Roc allocations than when it started, or Roc leaked (experiment 13).
//!
//! Ownership, as the generated glue states it: Roc consumes the arguments
//! of the functions it provides (so the shared context is retained once per
//! call), returns results the host owns (released after the response is
//! sent), and hands hosted functions arguments they must release.

const std = @import("std");
const assert = std.debug.assert;
const abi = @import("roc_platform_abi.zig");
const database_module = @import("database.zig");
const backup_module = @import("backup.zig");
const RequestsType = @import("requests.zig").RequestsType;
const dev = @import("dev.zig");
const templates = @import("templates.zig");
const sqlite = @import("sqlite");
const sqlite_vfs = sqlite.vfs;
const fourneau = @import("fourneau");
const Evented = @import("zig_io_evented");
const build_options = @import("build_options");

const Header = fourneau.http1_response.Header;

/// The records crossing the boundary, taken from the provided functions'
/// signatures, so a change to the platform's types needs no edit here.
const RequestFromHost = @typeInfo(@TypeOf(abi.roc_respond_for_host)).@"fn".param_types[0].?;
const ResponseToHost = @typeInfo(@TypeOf(abi.roc_respond_for_host)).@"fn".return_type.?;
const RocHeaders = @FieldType(RequestFromHost, "headers");
const RocHeader = @typeInfo(@typeInfo(@TypeOf(RocHeaders.items)).@"fn".return_type.?).pointer.child;

/// Requests carry at most this many headers into Roc; the server's own
/// limit (`headers_max`) is lower.
const response_headers_max = 64;
const port_default: u16 = 8080;
const shards_max = 256;
/// Connections across all shards; each shard takes an equal part. The
/// kernel spreads connections over the shards' listeners by hash, not by
/// load, so a shard can refuse while another has room (fourneau's experiment 1,
/// follow-up: balance at accept).
const connections_max = 1024;

// --- memory -------------------------------------------------------------------

/// Roc's heap: the glue's size-prefixed allocator over a thread-safe one,
/// since every shard runs Roc. Checked builds (`-Dhost-heap=checked`) use
/// `SafeAllocator`, which never reuses an address: a double free, a free of
/// memory it did not allocate, or a write after free panics.
var roc_heap_checked: std.heap.SafeAllocator = undefined;
var roc_env: abi.RocEnv = .{ .allocator = undefined, .roc_io = .default() };
var roc_host: abi.RocHost = undefined;
var roc_host_ready = false;

fn host() *abi.RocHost {
    assert(roc_host_ready);
    return &roc_host;
}

/// This thread's Roc allocations, live (allocated and not yet freed). A
/// thread's count is its own: shards share nothing, and the context, made
/// before the shards start, is never freed while they run.
threadlocal var roc_allocations_live: u64 = 0;
/// This thread's requests between `handle` and `release`.
threadlocal var requests_in_flight: u32 = 0;
/// `roc_allocations_live` when this thread's shard started: what it holds
/// with no request in flight.
threadlocal var roc_allocations_idle: u64 = 0;
/// This shard's `Io`, for effects that wait (file reads): a fiber waiting
/// on the disk yields like one waiting on the network.
threadlocal var shard_io: ?std.Io = null;
/// The main thread's Io while `init!` runs, before any shard: what a file
/// read in `init!` (a secret, a setting) waits through.
var init_io: ?std.Io = null;
/// The app's static files (`static_dir`), served before `respond!`; read
/// once at startup and shared read-only by every shard.
var static_site: ?*const fourneau.site.Site = null;
/// The app's database, opened by `Sqlite.open!` in `init!`; its writer is
/// shared by every shard under its lock, the rest read-only.
var database: ?*database_module.Database = null;
/// Set as the shards start: `init!` is over (`Sqlite.open!` is its).
var serving = false;
/// The build `roux dev` is serving (`ROUX_DEV`): development mode
/// (dev.zig). Null in production; read once, before the shards.
var dev_build: ?[]const u8 = null;

const Requests = RequestsType(Server.Request);
/// This shard's requests in Roc, by handle (requests.zig).
threadlocal var shard_requests: ?*Requests = null;
/// This shard's readers of the database, leased a statement at a time.
threadlocal var shard_readers: ?*database_module.ReaderPool = null;
/// A result's rows, kept here until their count is known: a Roc list of
/// refcounted items is allocated at its length. A buffer per connection
/// (the database's largest `rows_max`), never per shard: a statement can
/// yield mid-step (roux's VFS waits through the fiber) and another of the
/// shard's requests run its own on another reader meanwhile; with one
/// buffer a shard, their rows mixed (found 2026-10-07, the conduit race on
/// two shards: a row of the wrong width). A reader is leased to one
/// statement at a time, and the writer is one request's at a time.
threadlocal var shard_reader_rows: [][]RocRow = &.{};
var writer_rows: []RocRow = &.{};

// Roc's compiled code calls the exported functions; the glue (lists and
// strings the host builds) calls the `RocHost` table. Both reach the counted
// functions below, so every allocation is counted once.

export fn roc_alloc(length: usize, alignment: usize) callconv(.c) *anyopaque {
    return host().roc_alloc(host(), length, alignment);
}

export fn roc_dealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    host().roc_dealloc(host(), ptr, alignment);
}

fn counted_alloc(roc: *abi.RocHost, length: usize, alignment: usize) callconv(.c) *anyopaque {
    roc_allocations_live += 1;
    return abi.DefaultAllocators.rocAlloc(roc, length, alignment);
}

fn counted_dealloc(roc: *abi.RocHost, ptr: *anyopaque, alignment: usize) callconv(.c) void {
    assert(roc_allocations_live > 0); // a free with no allocation: not ours
    roc_allocations_live -= 1;
    abi.DefaultAllocators.rocDealloc(roc, ptr, alignment);
}

export fn roc_realloc(
    ptr: *anyopaque,
    new_length: usize,
    alignment: usize,
) callconv(.c) *anyopaque {
    return host().roc_realloc(host(), ptr, new_length, alignment);
}

export fn roc_dbg(bytes: [*]const u8, len: usize) callconv(.c) void {
    write_line(2, bytes[0..len]);
}

export fn roc_expect_failed(bytes: [*]const u8, len: usize) callconv(.c) void {
    write_line(2, bytes[0..len]);
}

export fn roc_crashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    write_line(2, bytes[0..len]);
    std.process.abort();
}

// --- hosted effects -------------------------------------------------------------

export fn hosted_stdout_line(line: abi.RocStr) callconv(.c) void {
    write_line(1, line.asSlice());
    line.decref(host());
}

export fn hosted_stderr_line(line: abi.RocStr) callconv(.c) void {
    write_line(2, line.asSlice());
    // During `init!`, kept: a development app whose `init!` fails shows it.
    if (init_io != null) init_said_add(line.asSlice());
    line.decref(host());
}

/// What `init!` wrote to stderr (the platform's `ERROR init!: …`), at most
/// this much; a development app shows it when `init!` fails.
var init_said: [8 * 1024]u8 = undefined;
var init_said_len: usize = 0;
/// Development: `init!` failed, and this is why. Every request is answered
/// with it, over the page, until roux dev restarts the app.
var init_failure: ?[]const u8 = null;

/// Development: the port this app serves, for roux-load to race it.
var dev_port: u16 = 0;

/// Development: a race of roux-load against this app (`/_dev/race`), run on
/// a thread of its own, a lane at a time; the shards only read it.
const Race = struct {
    running: bool = false,
    count: usize = 0,
    /// The lane roux-load is on now.
    current: usize = 0,
    paths: [dev.race_lanes_max][dev.race_path_bytes_max]u8 = undefined,
    path_lens: [dev.race_lanes_max]usize = @splat(0),
    /// roux-load's JSON for each finished lane ("" before, or if it failed).
    results: [dev.race_lanes_max][256]u8 = undefined,
    result_lens: [dev.race_lanes_max]usize = @splat(0),
};
var race: Race = .{};
/// Held while `race` is read or written: microseconds, development only.
var race_lock: std.atomic.Value(bool) = .init(false);

fn race_hold() void {
    while (race_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn race_let_go() void {
    race_lock.store(false, .release);
}

/// Starts a race of `paths` unless one runs; says whether it started.
fn race_start(paths: []const []const u8) bool {
    race_hold();
    defer race_let_go();
    if (race.running) return false;
    race = .{ .running = true, .count = paths.len };
    for (paths, 0..) |path, i| {
        @memcpy(race.paths[i][0..path.len], path);
        race.path_lens[i] = path.len;
    }
    const thread = std.Thread.spawn(.{}, race_run, .{}) catch {
        race.running = false;
        return false;
    };
    thread.detach();
    return true;
}

/// The race's thread: roux-load (`ROUX_DEV_LOAD`, beside roux) on each lane
/// in turn, on loopback, its JSON kept.
fn race_run() void {
    const loader = std.c.getenv("ROUX_DEV_LOAD");
    // An Io of this thread's own that can spawn (the global one's allocator
    // fails, and spawning allocates).
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var lane: usize = 0;
    while (true) : (lane += 1) {
        race_hold();
        if (lane == race.count) {
            race.running = false;
            race_let_go();
            return;
        }
        race.current = lane;
        var path_buffer: [dev.race_path_bytes_max]u8 = undefined;
        const path = path_buffer[0..race.path_lens[lane]];
        @memcpy(path, race.paths[lane][0..path.len]);
        race_let_go();
        var port_buffer: [8]u8 = undefined;
        const port = std.fmt.bufPrint(&port_buffer, "{d}", .{dev_port}) catch unreachable;
        const seconds = std.fmt.comptimePrint("{d}", .{dev.race_seconds});
        const ran = if (loader) |program| std.process.run(std.heap.page_allocator, io, .{
            .argv = &.{
                std.mem.span(program),
                "--port",
                port,
                "--path",
                path,
                "--connections",
                "64",
                "--threads",
                "2",
                "--seconds",
                seconds,
                "--format",
                "json",
            },
            .stdout_limit = .limited(1024),
            .stderr_limit = .limited(1024),
        }) catch |err| blk: {
            var buffer: [96]u8 = undefined;
            const said = "roux: roux-load could not run";
            write_line(2, std.fmt.bufPrint(&buffer, said ++ ": {t}", .{err}) catch said);
            break :blk null;
        } else null;
        race_hold();
        if (ran) |result| {
            const json = std.mem.trim(u8, result.stdout, " \n");
            if (json.len > 0 and json[0] == '{' and json.len <= race.results[lane].len) {
                @memcpy(race.results[lane][0..json.len], json);
                race.result_lens[lane] = json.len;
            }
            std.heap.page_allocator.free(result.stdout);
            std.heap.page_allocator.free(result.stderr);
        }
        race_let_go();
    }
}

/// The race as JSON, in `gpa`'s memory: running, and each lane's path and
/// roux-load's result (null until it has one).
fn race_json(gpa: std.mem.Allocator) ![]u8 {
    race_hold();
    defer race_let_go();
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("{{\"running\":{},\"current\":{d},\"loader\":{},\"lanes\":[", .{
        race.running,
        race.current,
        std.c.getenv("ROUX_DEV_LOAD") != null,
    });
    for (0..race.count) |i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"path\":\"{s}\",\"result\":", .{race.paths[i][0..race.path_lens[i]]});
        if (race.result_lens[i] > 0) {
            try w.writeAll(race.results[i][0..race.result_lens[i]]);
        } else try w.writeAll("null");
        try w.writeAll("}");
    }
    try w.writeAll("]}");
    return out.toOwnedSlice();
}

fn init_said_add(bytes: []const u8) void {
    const room = init_said.len - init_said_len;
    const take = @min(room, bytes.len + 1);
    if (take == 0) return;
    @memcpy(init_said[init_said_len..][0 .. take - 1], bytes[0 .. take - 1]);
    init_said[init_said_len + take - 1] = '\n';
    init_said_len += take;
}

/// The app's `Templates.Template`, boxed, made for `layouts`: which
/// template by its tag (templates.zig). The box goes back to Roc as it
/// came, which releases it.
export fn hosted_template_render(
    layouts: u64,
    template: abi.RocBox,
) callconv(.c) abi.HostTemplate_renderRetRecord {
    return .{ .bytes = templates.render(layouts, template, host()), .template = template };
}

/// A whole line to a standard stream. Rare (logs), so a plain blocking
/// write: it holds the thread for microseconds.
fn write_line(fd: i32, bytes: []const u8) void {
    var parts = [_]std.posix.iovec_const{
        .{ .base = bytes.ptr, .len = bytes.len },
        .{ .base = "\n", .len = 1 },
    };
    _ = std.os.linux.writev(fd, &parts, parts.len);
}

const FileResult = @typeInfo(@TypeOf(abi.hosted_file_read_utf8)).@"fn".return_type.?;

/// A file read whole through the shard's `Io`, at most `limit_bytes`.
export fn hosted_file_read_utf8(path: abi.RocStr, limit_bytes: u64) callconv(.c) FileResult {
    defer path.decref(host());
    // On a shard, or in `init!` (the main thread, before the shards).
    const io = shard_io orelse init_io orelse return file_error(.file_unreadable);
    const gpa = std.heap.smp_allocator;
    const limit: std.Io.Limit = .limited(@intCast(@min(limit_bytes, file_bytes_max) + 1));
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path.asSlice(), gpa, limit) catch |err|
        return file_error(switch (err) {
            error.FileNotFound => .file_not_found,
            error.StreamTooLong => .file_too_large,
            else => .file_unreadable,
        });
    defer gpa.free(bytes);
    if (bytes.len > limit_bytes) return file_error(.file_too_large);
    if (!std.unicode.utf8ValidateSlice(bytes)) return file_error(.file_unreadable);
    return .{ .tag = .Ok, .payload = .{ .ok = .fromSlice(bytes, host()) } };
}

fn file_error(err: abi.FileNotFoundOrFileTooLargeOrFileUnreadable) FileResult {
    return .{ .tag = .Err, .payload = .{ .err = err } };
}

/// The largest file an app may read whole, whatever limit it asks for.
const file_bytes_max = 64 * 1024 * 1024;

const BodyResult = @typeInfo(@TypeOf(abi.hosted_request_body_read_all)).@"fn".return_type.?;

/// The request body, read now that the handler asks, up to `limit_bytes`.
/// A handle that names no request of this shard is `BodyInvalid`.
export fn hosted_request_body_read_all(handle: u64, limit_bytes: u64) callconv(.c) BodyResult {
    const entry = request_entry(handle) orelse
        return .{ .tag = .Err, .payload = .{ .err = .body_invalid } };
    const request = entry.request.?;
    // fourneau reads no body once a stream has started (its 100 Continue
    // would be a second head): refused here, not left to its assertion.
    if (request.stream_state() != .none) {
        return .{ .tag = .Err, .payload = .{ .err = .body_after_stream } };
    }
    // Reading waits on the client, and every request waiting for the
    // database's writer would wait with it.
    if (entry.holds_writer) {
        return .{ .tag = .Err, .payload = .{ .err = .body_during_write } };
    }
    const result = read_body(request, limit_bytes) catch |err| return .{
        .tag = .Err,
        .payload = .{ .err = switch (err) {
            error.ContentTooLarge => .body_too_large,
            error.BadRequest => .body_invalid,
            error.Disconnected, error.OutOfMemory => .body_disconnected,
        } },
    };
    return .{ .tag = .Ok, .payload = .{ .ok = result } };
}

/// The body as Roc's `List(U8)`: the `ok` payload of the hosted result.
const BodyBytes = @FieldType(@FieldType(BodyResult, "payload"), "ok");

fn read_body(request: *Server.Request, limit_bytes: u64) !BodyBytes {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.heap.smp_allocator);

    // A body is bounded by the limit; each pass reads at least a byte.
    for (0..limit_bytes + 2) |_| {
        if (bytes.items.len > limit_bytes) return error.ContentTooLarge;
        try bytes.ensureUnusedCapacity(std.heap.smp_allocator, 4096);
        const got = try request.read_body(bytes.unusedCapacitySlice());
        if (got == 0) break;
        bytes.items.len += got;
    } else unreachable;
    if (bytes.items.len > limit_bytes) return error.ContentTooLarge;
    return .fromSlice(bytes.items, host());
}

// --- streamed responses (Sse) -----------------------------------------------------

const StreamResult = @typeInfo(@TypeOf(abi.hosted_response_stream_start)).@"fn".return_type.?;
const StreamHeaders = @typeInfo(@TypeOf(abi.hosted_response_stream_start)).@"fn".param_types[1].?;
const StreamBytes = @typeInfo(@TypeOf(abi.hosted_response_stream_send)).@"fn".param_types[1].?;
const StreamError = @FieldType(@FieldType(StreamResult, "payload"), "err");

/// The largest event: the platform's `Sse.event_bytes_max`, checked again
/// here. Each effect checks where the stream is, too: the host never lets
/// what a Roc app does reach one of fourneau's assertions.
const stream_event_bytes_max = 64 * 1024;

/// A 200 head with the app's headers; the stream's chunks follow.
export fn hosted_response_stream_start(
    handle: u64,
    headers: StreamHeaders,
) callconv(.c) StreamResult {
    defer headers.deinit(host());
    const entry = request_entry(handle) orelse return stream_error(.stream_refused);
    const request = entry.request.?;
    if (request.stream_state() != .none) return stream_error(.stream_refused);
    // A stream lasts as long as the client listens: not with the writer.
    if (entry.holds_writer) return stream_error(.stream_refused);
    // As fourneau wants them, in the scratch memory, which nothing uses
    // while `respond!` runs; the head is written before this returns.
    const roc_headers = headers.items();
    const table: [*]Header = @ptrCast(@alignCast(request.scratch.ptr));
    const capacity = @min(response_headers_max, request.scratch.len / @sizeOf(Header));
    if (roc_headers.len > capacity) return stream_error(.stream_refused);
    for (roc_headers, table[0..roc_headers.len]) |*roc_header, *header| {
        header.* = .{ .name = roc_header.name.asSlice(), .value = roc_header.value.asSlice() };
    }
    request.stream_start(200, table[0..roc_headers.len]) catch |err| {
        return stream_error(switch (err) {
            error.Disconnected => .stream_disconnected,
            error.HeadRefused => .stream_refused,
        });
    };
    assert(request.stream_state() == .streaming);
    return stream_ok();
}

/// One event, a chunk; its bytes are copied or sent before this returns.
export fn hosted_response_stream_send(handle: u64, bytes: StreamBytes) callconv(.c) StreamResult {
    defer bytes.decref(host());
    const request = request_from(handle) orelse return stream_error(.stream_refused);
    if (request.stream_state() != .streaming) return stream_error(.stream_refused);
    if (bytes.len() > stream_event_bytes_max) return stream_error(.stream_refused);
    request.stream_send(bytes.items()) catch return stream_error(.stream_disconnected);
    return stream_ok();
}

export fn hosted_response_stream_flush(handle: u64) callconv(.c) StreamResult {
    const request = request_from(handle) orelse return stream_error(.stream_refused);
    if (request.stream_state() != .streaming) return stream_error(.stream_refused);
    request.stream_flush() catch return stream_error(.stream_disconnected);
    return stream_ok();
}

export fn hosted_response_stream_end(handle: u64) callconv(.c) StreamResult {
    const request = request_from(handle) orelse return stream_error(.stream_refused);
    if (request.stream_state() != .streaming) return stream_error(.stream_refused);
    request.stream_end() catch return stream_error(.stream_disconnected);
    assert(request.stream_state() == .ended);
    return stream_ok();
}

fn stream_ok() StreamResult {
    return .{ .tag = .Ok, .payload = .{ .ok = .{} } };
}

fn stream_error(err: StreamError) StreamResult {
    return .{ .tag = .Err, .payload = .{ .err = err } };
}

/// The live request of this shard `handle` names (requests.zig).
fn request_entry(handle: u64) ?*Requests.Entry {
    const requests = shard_requests orelse return null; // not on a shard
    return requests.find(handle);
}

fn request_from(handle: u64) ?*Server.Request {
    const entry = request_entry(handle) orelse return null;
    return entry.request.?;
}

// --- the database (Sqlite) --------------------------------------------------------

const SqliteOpenResult = @typeInfo(@TypeOf(abi.hosted_sqlite_open)).@"fn".return_type.?;
const SqliteStatements = @typeInfo(@TypeOf(abi.hosted_sqlite_open)).@"fn".param_types[2].?;
const SqliteRunResult = @typeInfo(@TypeOf(abi.hosted_sqlite_run)).@"fn".return_type.?;
const SqliteParams = @typeInfo(@TypeOf(abi.hosted_sqlite_run)).@"fn".param_types[3].?;
const SqliteWriteResult = @typeInfo(@TypeOf(abi.hosted_sqlite_write_begin)).@"fn".return_type.?;
const SqliteCommitResult = @typeInfo(@TypeOf(abi.hosted_sqlite_commit)).@"fn".return_type.?;
const SqliteBackupResult = @typeInfo(@TypeOf(abi.hosted_sqlite_backup)).@"fn".return_type.?;
/// `List(List(Value))`, a row a `List(Value)`, a cell a `Value`.
const RocRows = @FieldType(@FieldType(SqliteRunResult, "payload"), "ok");
const RocRow = ListItem(RocRows);
const RocValue = ListItem(RocRow);
const SqliteError = @FieldType(@FieldType(SqliteRunResult, "payload"), "err");
/// Parameters a statement takes, at most (roux-db's bound).
const params_max = 64;

/// The item type of a glue list type.
fn ListItem(comptime List: type) type {
    const pointer = @typeInfo(@FieldType(List, "elements_ptr")).optional.child;
    return @typeInfo(pointer).pointer.child;
}

/// `Sqlite.open!`: the database, in `init!` only, once. Every allocation
/// here is the process's for its life (startup).
export fn hosted_sqlite_open(
    path: abi.RocStr,
    schema: abi.RocStr,
    statements: SqliteStatements,
    synchronous: abi.FullOrNormal,
) callconv(.c) SqliteOpenResult {
    defer path.decref(host());
    defer schema.decref(host());
    defer statements.deinit(host());
    if (serving or database != null) return open_error("Sqlite.open! belongs to init!, once");
    const gpa = std.heap.page_allocator;
    const roc_statements = statements.items();
    const descriptions = gpa.alloc(database_module.StatementDescription, roc_statements.len) catch
        return open_error("out of memory");
    defer gpa.free(descriptions);
    // By pointer: a small string's bytes live inside the record.
    for (roc_statements, descriptions) |*statement, *description| {
        description.* = .{
            .name = statement.name.asSlice(),
            .sql = statement.sql.asSlice(),
            .writes = statement.writes,
            .rows_max = statement.rows_max,
            .params = statement.params.items(),
            .columns = statement.columns.items(),
        };
    }
    // Where the database is is the deployment's to say, as the port.
    const where = environment("ROUX_DATABASE") orelse path.asSlice();
    var report: database_module.Report = .{};
    const description: database_module.Description = .{
        .path = where,
        .schema = schema.asSlice(),
        .statements = descriptions,
        .synchronous = switch (synchronous) {
            .full => .full,
            .normal => .normal,
        },
    };
    database = database_module.open(gpa, description, .{}, &report) catch
        return open_error(report.message());
    writer_rows = gpa.alloc(RocRow, rows_max_of(database.?)) catch
        return open_error("out of memory");
    var banner: [256]u8 = undefined;
    const line = "roux: database {s}, {d} statements, synchronous {t}";
    write_line(1, std.fmt.bufPrint(&banner, line, .{
        where, descriptions.len, description.synchronous,
    }) catch "roux: database");
    return .{ .tag = .Ok, .payload = .{ .ok = .{} } };
}

fn open_error(message: []const u8) SqliteOpenResult {
    return .{ .tag = .Err, .payload = .{ .err = .fromSlice(message, host()) } };
}

/// Runs a statement for a request: on the shard's reader, or (`on_writer`)
/// on the writer the request holds.
export fn hosted_sqlite_run(
    handle: u64,
    index: u32,
    on_writer: bool,
    params: SqliteParams,
) callconv(.c) SqliteRunResult {
    defer params.deinit(host());
    var report: database_module.Report = .{};
    const rows = sqlite_run(handle, index, on_writer, params, &report) catch
        return .{ .tag = .Err, .payload = .{ .err = sqlite_error(&report) } };
    return .{ .tag = .Ok, .payload = .{ .ok = rows } };
}

fn sqlite_run(
    handle: u64,
    index: u32,
    on_writer: bool,
    params: SqliteParams,
    report: *database_module.Report,
) error{Failed}!RocRows {
    const opened = database orelse return no_database(report);
    const entry = request_entry(handle) orelse return report.fail(.misuse, "not a request", .{});
    if (index >= opened.statements.len) return report.fail(.misuse, "no statement {d}", .{index});
    const io = shard_io.?; // a request's effect runs on its shard
    if (on_writer and !entry.holds_writer) {
        return report.fail(.write_refused, "{s} runs inside Sqlite.write!", .{
            opened.statements[index].name,
        });
    }
    const readers = shard_readers.?;
    const connection = if (on_writer)
        opened.writer
    else
        try readers.lease(io, opened.limits, report);
    defer if (!on_writer) readers.release(io, connection);
    const roc_params = params.items();
    if (roc_params.len > params_max) return report.fail(.misuse, "{d} parameters", .{
        roc_params.len,
    });
    var values: [params_max]database_module.Value = undefined;
    for (roc_params, values[0..roc_params.len]) |*param, *value| value.* = value_from_roc(param);
    const columns: u32 = @intCast(opened.statements[index].columns.len);
    var sink: RowsToRoc = .{ .rows = rows_for(opened, connection), .columns = columns };
    database_module.run(
        opened,
        connection,
        index,
        values[0..roc_params.len],
        io,
        &sink,
        report,
    ) catch |err| {
        sink.discard();
        return err;
    };
    return sink.finish();
}

/// A parameter from Roc; its bytes stay Roc's, alive until the run ends.
fn value_from_roc(value: *const RocValue) database_module.Value {
    return switch (value.tag) {
        .Null => .null,
        .Integer => .{ .integer = value.payload.integer },
        .Real => .{ .real = value.payload.real },
        // In place: a small string's bytes live inside the value.
        .Text => .{ .text = value.payload.text.asSlice() },
        .Blob => .{ .blob = value.payload.blob.items() },
    };
}

fn value_to_roc(value: database_module.Value) RocValue {
    return switch (value) {
        .null => .{ .payload = .{ .null = .{} }, .tag = .Null },
        .integer => |n| .{ .payload = .{ .integer = n }, .tag = .Integer },
        .real => |x| .{ .payload = .{ .real = x }, .tag = .Real },
        .text => |text| .{ .payload = .{ .text = .fromSlice(text, host()) }, .tag = .Text },
        .blob => |bytes| .{ .payload = .{ .blob = .fromSlice(bytes, host()) }, .tag = .Blob },
    };
}

/// The sink database.run fills: each row a Roc list of its cells, kept in
/// the shard's buffer until the run ends, then one Roc list of them all.
const RowsToRoc = struct {
    rows: []RocRow,
    columns: u32,
    count: u32 = 0,
    /// The row being filled, and its cells so far.
    open: bool = false,
    filled: u32 = 0,

    pub fn row(sink: *RowsToRoc) error{}!void {
        sink.close();
        // database.run fails past rows_max, before this: the buffer fits.
        assert(sink.count < sink.rows.len);
        assert(sink.columns > 0);
        sink.rows[sink.count] = .allocate(sink.columns, host());
        sink.open = true;
        sink.filled = 0;
    }

    pub fn cell(sink: *RowsToRoc, value: database_module.Value) error{}!void {
        assert(sink.open);
        assert(sink.filled < sink.columns);
        const cells: [*]RocValue = @constCast(sink.rows[sink.count].allocationItems().ptr);
        cells[sink.filled] = value_to_roc(value);
        sink.filled += 1;
    }

    fn close(sink: *RowsToRoc) void {
        if (!sink.open) return;
        assert(sink.filled == sink.columns);
        sink.count += 1;
        sink.open = false;
    }

    fn finish(sink: *RowsToRoc) RocRows {
        sink.close();
        const rows: RocRows = .allocate(sink.count, host());
        if (sink.count == 0) return rows;
        const items: [*]RocRow = @constCast(rows.allocationItems().ptr);
        @memcpy(items[0..sink.count], sink.rows[0..sink.count]);
        return rows;
    }

    /// A run that failed: every row so far released (a row cut short is
    /// filled with NULLs first: a list releases every item it has room for).
    fn discard(sink: *RowsToRoc) void {
        if (sink.open) {
            const cells: [*]RocValue = @constCast(sink.rows[sink.count].allocationItems().ptr);
            for (cells[sink.filled..sink.columns]) |*empty| empty.* = value_to_roc(.null);
            sink.filled = sink.columns;
            sink.close();
        }
        for (sink.rows[0..sink.count]) |row_list| row_list.deinit(host());
        sink.count = 0;
    }
};

fn sqlite_error(report: *const database_module.Report) SqliteError {
    return .{
        .code = @backingInt(report.failure),
        .message = .fromSlice(report.message(), host()),
    };
}

fn no_database(report: *database_module.Report) error{Failed} {
    return report.fail(.misuse, "no database: Sqlite.open! in init!", .{});
}

/// `Sqlite.write!`: the writer for this request, and its transaction.
/// Never for a request that should not change anything.
export fn hosted_sqlite_write_begin(handle: u64) callconv(.c) SqliteWriteResult {
    var report: database_module.Report = .{};
    sqlite_write_begin(handle, &report) catch
        return .{ .tag = .Err, .payload = .{ .err = sqlite_error(&report) } };
    return .{ .tag = .Ok, .payload = .{ .ok = .{} } };
}

fn sqlite_write_begin(handle: u64, report: *database_module.Report) error{Failed}!void {
    const opened = database orelse return no_database(report);
    const entry = request_entry(handle) orelse return report.fail(.misuse, "not a request", .{});
    const head = entry.request.?.head;
    switch (head.method) {
        .get, .head, .options, .trace => return report.fail(.write_refused, "a {s} request does " ++
            "not write", .{head.method_text}),
        .post, .put, .delete, .patch, .other => {},
    }
    if (entry.holds_writer) {
        return report.fail(.write_refused, "this request holds the writer already", .{});
    }
    try database_module.begin_write(opened, shard_io.?, report);
    entry.holds_writer = true;
}

/// `Sqlite.backup!`: the database copied from a reader of the request's
/// shard (host/backup.zig).
export fn hosted_sqlite_backup(
    handle: u64,
    directory: abi.RocStr,
    keep: u32,
) callconv(.c) SqliteBackupResult {
    defer directory.decref(host());
    var report: database_module.Report = .{};
    const name = sqlite_backup(handle, directory.asSlice(), keep, &report) catch
        return .{ .tag = .Err, .payload = .{ .err = sqlite_error(&report) } };
    return .{ .tag = .Ok, .payload = .{ .ok = .fromSlice(&name, host()) } };
}

fn sqlite_backup(
    handle: u64,
    directory: []const u8,
    keep: u32,
    report: *database_module.Report,
) error{Failed}!backup_module.Name {
    const opened = database orelse return no_database(report);
    const entry = request_entry(handle) orelse return report.fail(.misuse, "not a request", .{});
    const head = entry.request.?.head;
    switch (head.method) {
        .get, .head, .options, .trace => return report.fail(.write_refused, "a {s} request " ++
            "makes no backup", .{head.method_text}),
        .post, .put, .delete, .patch, .other => {},
    }
    const io = shard_io.?; // a request's effect runs on its shard
    const readers = shard_readers.?;
    const reader = try readers.lease(io, opened.limits, report);
    defer readers.release(io, reader);
    const now_s = std.Io.Timestamp.now(io, .real).toSeconds();
    return backup_module.backup(reader, io, .{
        .directory = directory,
        .keep = keep,
        .now_s = now_s,
    }, report);
}

/// `Sqlite.commit!`: commits, and gives the writer back (a failed commit
/// rolls back and gives it back too).
export fn hosted_sqlite_commit(handle: u64) callconv(.c) SqliteCommitResult {
    var report: database_module.Report = .{};
    sqlite_commit(handle, &report) catch
        return .{ .tag = .Err, .payload = .{ .err = sqlite_error(&report) } };
    return .{ .tag = .Ok, .payload = .{ .ok = .{} } };
}

fn sqlite_commit(handle: u64, report: *database_module.Report) error{Failed}!void {
    const opened = database orelse return no_database(report);
    const entry = request_entry(handle) orelse return report.fail(.misuse, "not a request", .{});
    if (!entry.holds_writer) {
        return report.fail(.write_refused, "no transaction: Sqlite.write! first", .{});
    }
    entry.holds_writer = false;
    try database_module.commit_write(opened, shard_io.?, report);
}

// --- the application, for fourneau ------------------------------------------------

const App = struct {
    /// The app's immutable context, from `init!`; retained per request.
    context: abi.RocBox,

    pub const Response = struct {
        status: u16,
        headers: []const Header,
        body: []const u8,
        /// Roc's response, released after the send; null for a static file.
        roc: ?ResponseToHost,
        /// The request's handle (requests.zig), ended at release; 0 for a
        /// static file, which never reached Roc.
        handle: u64,
        /// Development only: the body with the reload script, freed at
        /// release (dev.zig).
        dev_body: ?[]u8 = null,
    };

    pub fn handle(app: *App, request: *Server.Request) Response {
        requests_in_flight += 1;
        // Development: the program this page is made under, read before
        // it is rendered (dev.zig).
        const program = if (dev_build != null) templates.requested.load(.acquire) else 0;
        if (dev_build) |build| {
            if (dev.is_events(request.head.path_and_query)) return dev_events(request, build);
            if (dev.is_stats(request.head.path_and_query)) return dev_stats();
            if (dev.is_restart(request.head.path_and_query) and request.head.method == .post) {
                // roux dev starts it again (its database closed by the exit).
                std.process.exit(dev.restart_code);
            }
            if (dev.is_race(request.head.path_and_query)) return dev_race(request);
            if (init_failure) |text| return init_failure_page(text, build, program);
        }
        if (static_site) |site| {
            if (site.respond(request.head, request.scratch)) |file| {
                return .{
                    .status = file.status,
                    .headers = file.headers,
                    .body = file.body,
                    .roc = null,
                    .handle = 0,
                };
            }
        }
        const request_handle = shard_requests.?.begin(request);
        const roc_request = request_to_roc(request, request_handle);
        // Development: the app's time, said in `Server-Timing` (below).
        const started: ?std.Io.Timestamp = if (dev_build != null)
            std.Io.Timestamp.now(shard_io.?, .awake)
        else
            null;
        abi.increfBox(@ptrCast(app.context), 1); // Roc consumes its arguments
        const roc = abi.roc_respond_for_host(roc_request, app.context);
        const kept_writer = give_back_writer(request_handle);
        const streamed = fourneau.server.streamed_status;
        if (request.stream_state() != .none) {
            if (kept_writer) {
                write_line(2, "roux: a stream's respond! returned holding the database's " ++
                    "writer: rolled back");
            }
            // Streamed (`Sse`): whatever `respond!` returned after, the
            // response is on its way; ended or not, fourneau finishes it.
            return status_only(streamed, roc, request_handle);
        }
        if (roc.status == streamed) {
            // `Server.streamed` with no stream: there is nothing to send.
            write_line(2, "roux: respond! returned Server.streamed without a stream: 500");
            return status_only(500, roc, request_handle);
        }
        if (kept_writer and roc.status < 400) {
            // Its writes were rolled back: never answer as if they were not.
            // An error answer (a constraint, a 404) says so already.
            write_line(2, "roux: respond! answered success holding the database's writer, " ++
                "never committed: rolled back, 500");
            return status_only(500, roc, request_handle);
        }
        var response: Response = .{
            .status = roc.status,
            .headers = headers_of(request, roc, started),
            .body = roc.body.items(),
            .roc = roc,
            .handle = request_handle,
        };
        if (dev_build) |build| {
            if (dev.wants_script(fetch_dest(request))) add_reload_script(&response, build, program);
        }
        return response;
    }

    /// The response's headers, as fourneau wants them, in this connection's
    /// scratch memory; their bytes stay Roc's until release. In development
    /// (`started`), `Server-Timing` too: `respond!` and the template's
    /// render, which happens as Roc builds the response, for the browser to
    /// show beside the round trip (PerformanceResourceTiming.serverTiming);
    /// its text goes in the scratch memory after the table.
    fn headers_of(
        request: *Server.Request,
        roc: ResponseToHost,
        started: ?std.Io.Timestamp,
    ) []const Header {
        const table: [*]Header = @ptrCast(@alignCast(request.scratch.ptr));
        const capacity = @min(response_headers_max, request.scratch.len / @sizeOf(Header));
        const roc_headers = roc.headers.items();
        var count = @min(roc_headers.len, capacity);
        for (roc_headers[0..count], table[0..count]) |*roc_header, *header| {
            header.* = .{ .name = roc_header.name.asSlice(), .value = roc_header.value.asSlice() };
        }
        const from = started orelse return table[0..count];
        const micros: u64 = @intCast(@divTrunc(
            from.durationTo(std.Io.Timestamp.now(shard_io.?, .awake)).nanoseconds,
            std.time.ns_per_us,
        ));
        const text_at = (count + 1) * @sizeOf(Header);
        if (count == capacity or text_at >= request.scratch.len) return table[0..count];
        const text = std.fmt.bufPrint(request.scratch[text_at..], "roux;dur={d}.{d:0>3}", .{
            micros / 1000,
            micros % 1000,
        }) catch return table[0..count];
        table[count] = .{ .name = "Server-Timing", .value = text };
        count += 1;
        return table[0..count];
    }

    /// The request's `Sec-Fetch-Dest`: what the browser will do with the
    /// answer.
    fn fetch_dest(request: *const Server.Request) ?[]const u8 {
        for (request.head.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "sec-fetch-dest")) return header.value;
        }
        return null;
    }

    /// In development, an HTML page gets the reload script (dev.zig).
    fn add_reload_script(response: *Response, build: []const u8, program: u32) void {
        for (response.headers) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "content-type")) continue;
            if (!dev.is_html(header.value)) return;
            var buffer: [64]u8 = undefined;
            const made = dev.name(build, program, &buffer);
            // Out of memory: the page goes without the script.
            const body = dev.with_script(std.heap.smp_allocator, response.body, made) catch
                return;
            response.body = body;
            response.dev_body = body;
            return;
        }
    }

    /// Development, `init!` failed: every request answered 500 with why,
    /// a page with the reload script, so it goes when the fixed build runs.
    fn init_failure_page(text: []const u8, build: []const u8, program: u32) Response {
        const headers = comptime [_]Header{
            .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            .{ .name = "Cache-Control", .value = "no-store" },
        };
        const plain: Response = .{
            .status = 500,
            .headers = &headers,
            .body = "init! failed",
            .roc = null,
            .handle = 0,
        };
        var name_buffer: [64]u8 = undefined;
        const made = dev.name(build, program, &name_buffer);
        const page = dev.failure_page(std.heap.smp_allocator, text, made) catch return plain;
        return .{
            .status = 500,
            .headers = &headers,
            .body = page,
            .roc = null,
            .handle = 0,
            .dev_body = page,
        };
    }

    /// `/_dev/race`, in development: `POST ?paths=…` starts roux-load on
    /// those lanes (409 while one runs, 400 for bad paths); `GET` is where
    /// it is, as JSON.
    fn dev_race(request: *Server.Request) Response {
        const headers = comptime [_]Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Cache-Control", .value = "no-store" },
        };
        const answer = struct {
            fn of(status: u16, body: []const u8) Response {
                return .{
                    .status = status,
                    .headers = &headers,
                    .body = body,
                    .roc = null,
                    .handle = 0,
                };
            }
        }.of;
        if (request.head.method == .post) {
            var out: [dev.race_lanes_max][]const u8 = undefined;
            const paths = dev.race_paths(request.head.path_and_query, &out) orelse
                return answer(400, "{\"started\":false,\"why\":\"paths\"}");
            if (!race_start(paths)) return answer(409, "{\"started\":false,\"why\":\"running\"}");
            return answer(202, "{\"started\":true}");
        }
        const json = race_json(std.heap.smp_allocator) catch return answer(500, "{}");
        var response = answer(200, json);
        response.dev_body = json;
        return response;
    }

    /// `/_dev/stats`, in development: roux dev's last good pass, as it
    /// wrote it (`ROUX_DEV_STATS`, JSON: what it built and how long it
    /// took, from noticing the save to the app told); `{}` before one.
    fn dev_stats() Response {
        const headers = comptime [_]Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Cache-Control", .value = "no-store" },
        };
        const none: Response = .{
            .status = 200,
            .headers = &headers,
            .body = "{}",
            .roc = null,
            .handle = 0,
        };
        const memory = std.heap.smp_allocator.alloc(u8, dev.stats_bytes_max) catch return none;
        const text = dev_file_read(dev_stats_path, memory);
        if (text.len == 0) {
            std.heap.smp_allocator.free(memory);
            return none;
        }
        return .{
            .status = 200,
            .headers = &headers,
            .body = text,
            .roc = null,
            .handle = 0,
            .dev_body = memory,
        };
    }

    /// `/_dev/events`, in development: the name serving, then the name
    /// again each time the templates' program is reread, and a comment
    /// every `keepalive_seconds` until the client leaves (a day at most).
    fn dev_events(request: *Server.Request, build: []const u8) Response {
        const over: Response = .{
            .status = fourneau.server.streamed_status,
            .headers = &.{},
            .body = "",
            .roc = null,
            .handle = 0,
        };
        const headers = [_]Header{
            .{ .name = "Content-Type", .value = "text/event-stream" },
            .{ .name = "Cache-Control", .value = "no-store" },
        };
        request.stream_start(200, &headers) catch return over;
        var seen = templates.requested.load(.acquire);
        var name_buffer: [64]u8 = undefined;
        var buffer: [128]u8 = undefined;
        const first = dev.event(dev.name(build, seen, &name_buffer), true, &buffer);
        request.stream_send(first) catch return over;
        // A failed build's report, read per stream (development only):
        // the heap, not the fiber's stack.
        const report_memory = std.heap.page_allocator.alloc(u8, dev.failure_bytes_max) catch
            return over;
        defer std.heap.page_allocator.free(report_memory);
        const event_memory = std.heap.page_allocator.alloc(u8, dev.failure_bytes_max + 4096) catch
            return over;
        defer std.heap.page_allocator.free(event_memory);
        var errors_seen = dev_errors_told.load(.acquire);
        const report = init_failure orelse dev_errors_read(report_memory);
        if (report.len > 0) {
            request.stream_send(dev.failure_event(report, event_memory)) catch return over;
        }
        request.stream_flush() catch return over;
        const io = shard_io.?;
        const keepalive: std.Io.Timeout = .{ .duration = .{
            .raw = .fromSeconds(dev.keepalive_seconds),
            .clock = .awake,
        } };
        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
            .raw = .fromSeconds(std.time.s_per_day),
            .clock = .awake,
        });
        while (true) {
            // Woken by a reread (SIGUSR1's futex wake), or the keepalive.
            io.futexWaitTimeout(u32, &templates.requested.raw, seen, keepalive) catch break;
            const now = templates.requested.load(.acquire);
            const errors_now = dev_errors_told.load(.acquire);
            if (errors_now != errors_seen) {
                errors_seen = errors_now;
                const text = dev_errors_read(report_memory);
                request.stream_send(dev.failure_event(text, event_memory)) catch break;
            }
            if (now != seen) {
                seen = now;
                const next = dev.event(dev.name(build, seen, &name_buffer), false, &buffer);
                request.stream_send(next) catch break;
            } else if (errors_now == errors_seen) {
                if (deadline.compare(.lt, .now(io, .awake))) break;
                request.stream_send(": \n\n") catch break;
            }
            request.stream_flush() catch break;
        }
        if (request.stream_state() == .streaming) request.stream_end() catch {};
        return over;
    }

    /// An answer of a status alone, Roc's response released after it.
    fn status_only(status: u16, roc: ResponseToHost, request_handle: u64) Response {
        return .{
            .status = status,
            .headers = &.{},
            .body = "",
            .roc = roc,
            .handle = request_handle,
        };
    }

    /// A request whose `respond!` returned still holding the database's
    /// writer (no `Sqlite.commit!`: an error returned early, or a commit
    /// forgotten): rolled back, the writer given back.
    fn give_back_writer(request_handle: u64) bool {
        const entry = shard_requests.?.find(request_handle).?;
        if (!entry.holds_writer) return false;
        database_module.rollback_write(database.?, shard_io.?);
        entry.holds_writer = false;
        return true;
    }

    pub fn release(app: *App, response: *Response) void {
        _ = app;
        if (response.dev_body) |body| std.heap.smp_allocator.free(body);
        if (response.roc) |roc| roc.decref(host());
        if (response.handle != 0) shard_requests.?.end(response.handle);
        response.* = undefined;
        assert(requests_in_flight > 0);
        requests_in_flight -= 1;
        // Every request on this shard is done, so everything Roc allocated
        // for them is freed: otherwise Roc (or this host) leaked.
        if (requests_in_flight == 0) assert(roc_allocations_live == roc_allocations_idle);
    }

    fn request_to_roc(request: *Server.Request, request_handle: u64) RequestFromHost {
        const head = request.head;
        const headers: RocHeaders = .allocate(head.headers.len, host());
        const slots: [*]RocHeader = @constCast(headers.allocationItems().ptr);
        for (head.headers, slots[0..head.headers.len]) |header, *slot| {
            slot.* = .{
                .name = .fromSlice(header.name, host()),
                .value = .fromSlice(header.value, host()),
            };
        }
        return .{
            .method = .fromSlice(head.method_text, host()),
            .target = .fromSlice(head.path_and_query, host()),
            .headers = headers,
            .body = request_handle,
        };
    }
};

const Server = fourneau.server.ServerType(App, .{ .send_then_receive = Evented.sendThenReceive });

/// Plain HTTP beside HTTPS: redirects (fourneau's https.zig).
const Redirect = fourneau.https.RedirectType(.{ .send_then_receive = Evented.sendThenReceive });

fn run_redirect(redirect_server: *Redirect.Server) void {
    redirect_server.run() catch |err| {
        var buffer: [128]u8 = undefined;
        write_line(2, std.fmt.bufPrint(&buffer, "roux: redirect: {t}", .{err}) catch "roux");
        std.process.exit(1);
    };
}

// --- the program ---------------------------------------------------------------

export fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    _ = argc;
    _ = argv;
    run() catch |err| {
        var buffer: [128]u8 = undefined;
        write_line(2, std.fmt.bufPrint(&buffer, "roux: {t}", .{err}) catch "roux: error");
        return 1;
    };
    return 0;
}

/// The app's `init!`. A failure ends the process, unless in development:
/// there the app stays up and answers with why (`init_failure`), so the page
/// says it and reloads when roux dev starts the fixed build.
fn init_app() InitResult {
    const init = abi.roc_init_for_host();
    if (init.tag == .Ok) return init.payload_ok();
    if (dev_build == null) {
        const code = init.payload_err();
        std.process.exit(@intCast(@max(0, @min(code, 255))));
    }
    init_failure = if (init_said_len > 0) init_said[0..init_said_len] else "init! failed\n";
    return .{
        .port = 0,
        .static_dir = .empty(),
        .context = undefined, // never read: every request is the failure
    };
}

const InitResult = @TypeOf(abi.roc_init_for_host().payload_ok());

fn run() !void {
    if (build_options.heap_checked) {
        roc_heap_checked = .init(std.heap.page_allocator, .{
            .stack_trace_frames = 8,
            .check_write_after_free = true,
        });
        roc_env.allocator = roc_heap_checked.allocator();
    } else {
        roc_env.allocator = std.heap.smp_allocator;
    }
    roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_alloc = &counted_alloc;
    roc_host.roc_dealloc = &counted_dealloc;
    roc_host_ready = true;

    // `init!` may open the database: SQLite's files wait through this
    // thread's Io until the shards start (roux's VFS), and its memory is a
    // heap made now, sized for every connection the shards will open.
    const startup_io = std.Io.Threaded.global_single_threaded.io();
    sqlite_vfs.thread_io = startup_io;
    init_io = startup_io;
    const shards = shard_count();
    try sqlite_setup(shards);
    templates.load_attached();
    start_dev();
    const started = init_app();
    init_io = null;
    // The app names its port; the deployment may say otherwise (ROUX_PORT),
    // as it says the address: a local run of an app that asks for 443.
    const app_port = if (started.port == 0) port_default else started.port;
    const port = port_from(environment("ROUX_PORT")) orelse app_port;
    dev_port = port; // roux-load races it, in development
    assert(shards >= 1);
    assert(shards <= shards_max);

    // HTTPS is the deployment's to say, as the address is: a certificate,
    // or a CA to obtain one from now, before any shard (https.zig).
    var https_options = https_from_environment();
    try https_options.check();
    const tls = try fourneau.https.context(std.heap.page_allocator, startup_io, https_options);
    const static_dir = started.static_dir.asSlice();
    if (static_dir.len > 0) {
        const site = try std.heap.page_allocator.create(fourneau.site.Site);
        const gpa = std.heap.page_allocator;
        site.* = try fourneau.site.Site.load(gpa, startup_io, static_dir, "");
        static_site = site;
    }

    var app: App = .{ .context = started.context };
    // `init!` is over: the database is open, or there is none.
    serving = true;
    const listen: Listen = .{ .port = port, .shards = shards, .tls = tls, .https = https_options };
    var threads: [shards_max]std.Thread = undefined;
    for (threads[1..shards]) |*thread| {
        thread.* = try std.Thread.spawn(.{}, run_shard, .{ &app, listen });
    }
    var banner: [128]u8 = undefined;
    write_line(1, std.fmt.bufPrint(&banner, "roux on {s}://{s}:{d} ({d} shards)", .{
        if (tls != null) "https" else "http",
        listen_address(),
        port,
        shards,
    }) catch "");
    run_shard(&app, listen);
}

/// What every shard listens with, read-only.
const Listen = struct {
    port: u16,
    shards: u32,
    tls: ?*const fourneau.tls.Context,
    https: fourneau.https.Options,
};

/// The deployment's HTTPS, from `ROUX_TLS_CERT` and `ROUX_TLS_KEY`, or
/// `ROUX_ACME_DIRECTORY`, `_IDENTIFIER`, `_STATE` (and `_PROFILE`,
/// `_HTTP_PORT`, `_CA`), with `ROUX_REDIRECT_PORT` and `ROUX_HTTPS_HOST`
/// for plain HTTP beside it. None set: plain HTTP.
fn https_from_environment() fourneau.https.Options {
    return .{
        .cert = environment("ROUX_TLS_CERT"),
        .key = environment("ROUX_TLS_KEY"),
        .acme_directory = environment("ROUX_ACME_DIRECTORY"),
        .acme_identifier = environment("ROUX_ACME_IDENTIFIER"),
        .acme_state = environment("ROUX_ACME_STATE"),
        .acme_profile = environment("ROUX_ACME_PROFILE"),
        .acme_http_port = port_from(environment("ROUX_ACME_HTTP_PORT")) orelse 80,
        .acme_ca = environment("ROUX_ACME_CA"),
        .redirect_port = port_from(environment("ROUX_REDIRECT_PORT")),
        .https_host = environment("ROUX_HTTPS_HOST"),
    };
}

/// `roux dev` names the build: development mode, decided once, before
/// `init!` (dev.zig). It names the templates' program file too: reread on
/// SIGUSR1, no restart (templates.zig).
fn start_dev() void {
    dev_build = if (environment("ROUX_DEV")) |build| (if (build.len > 0) build else null) else null;
    if (dev_build == null) return;
    const path = std.c.getenv("ROUX_DEV_TEMPLATES") orelse return;
    templates.reload_from(std.mem.span(path));
    const action: std.os.linux.Sigaction = .{
        .handler = .{ .handler = on_reload_signal },
        .mask = std.os.linux.sigemptyset(),
        .flags = std.os.linux.SA.RESTART,
    };
    _ = std.os.linux.sigaction(.USR1, &action, null);
    // A failed build's report: roux dev rewrites the file and sends SIGUSR2;
    // the events streams send it to the pages, which show it.
    if (std.c.getenv("ROUX_DEV_STATS")) |stats| dev_stats_path = std.mem.span(stats);
    const errors = std.c.getenv("ROUX_DEV_ERRORS") orelse return;
    dev_errors_path = std.mem.span(errors);
    var failure = action;
    failure.handler = .{ .handler = on_failure_signal };
    _ = std.os.linux.sigaction(.USR2, &failure, null);
}

fn on_reload_signal(_: std.os.linux.SIG) callconv(.c) void {
    templates.request_reload();
}

/// The file roux dev writes a failed build's report to (empty: none).
var dev_errors_path: ?[:0]const u8 = null;
/// Bumped by SIGUSR2: the report changed.
var dev_errors_told: std.atomic.Value(u32) = .init(0);

/// Async-signal-safe: an atomic, and a wake of the streams' futex (the
/// templates' counter's word, unchanged: the streams look at both).
fn on_failure_signal(_: std.os.linux.SIG) callconv(.c) void {
    _ = dev_errors_told.fetchAdd(1, .release);
    _ = std.os.linux.futex_3arg(
        &templates.requested.raw,
        .{ .cmd = .WAKE, .private = true },
        std.math.maxInt(i32),
    );
}

/// The report as the streams send it: read now, at most the most a page
/// is shown, in `buffer`; "" for none or unreadable.
fn dev_errors_read(buffer: []u8) []const u8 {
    return dev_file_read(dev_errors_path, buffer);
}

/// roux dev's last good pass (`ROUX_DEV_STATS`), for `/_dev/stats`.
var dev_stats_path: ?[:0]const u8 = null;

/// A file roux dev writes, read now into `buffer`; "" for none.
fn dev_file_read(path_or_null: ?[:0]const u8, buffer: []u8) []const u8 {
    const path = path_or_null orelse return "";
    const linux = std.os.linux;
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return "";
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    var done: usize = 0;
    while (done < buffer.len) {
        const got = linux.read(fd, buffer[done..].ptr, buffer.len - done);
        if (linux.errno(got) != .SUCCESS or got == 0) break;
        done += got;
    }
    return buffer[0..done];
}

fn environment(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

fn port_from(text: ?[]const u8) ?u16 {
    return std.fmt.parseInt(u16, text orelse return null, 10) catch null;
}

/// One shard per CPU this process may run on (its affinity mask, so
/// `taskset` decides), at most `shards_max`, and at most `ROUX_SHARDS` when
/// the deployment says (`roux dev` runs two: a restart right after a stop
/// found the old process's io_uring memory not yet freed, and eight shards
/// twice over did not fit the laptop's 8 MiB of locked memory).
fn shard_count() u32 {
    var set: std.os.linux.cpu_set_t = @splat(0);
    const linux = std.os.linux;
    const result = linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &set);
    if (linux.errno(result) != .SUCCESS) return 1;
    var count: u32 = 0;
    for (set) |word| count += @popCount(word);
    assert(count >= 1); // we are running on one
    const wanted = std.fmt.parseInt(u32, environment("ROUX_SHARDS") orelse "", 10) catch count;
    return @max(1, @min(count, wanted, shards_max));
}

/// A shard failed to start: the first says why (the others fail alike).
var shard_failed: std.atomic.Value(bool) = .init(false);

fn run_shard(app: *App, listen: Listen) void {
    run_shard_or_fail(app, listen) catch |err| {
        var buffer: [192]u8 = undefined;
        const line = switch (err) {
            // The common first-run surprise: said once, with the way out.
            error.AddressInUse => std.fmt.bufPrint(&buffer, "roux: port {d} is taken: another " ++
                "server listens there. Stop it, or choose another port: ROUX_PORT=8081", .{
                listen.port,
            }),
            else => std.fmt.bufPrint(&buffer, "roux: shard: {t}", .{err}),
        } catch "roux";
        if (!shard_failed.swap(true, .acq_rel)) write_line(2, line);
        std.process.exit(1);
    };
}

fn run_shard_or_fail(app: *App, listen: Listen) !void {
    assert(listen.shards >= 1);
    assert(requests_in_flight == 0);
    assert(serving);
    const gpa = std.heap.page_allocator;
    const connections_per_shard: u32 = @max(1, connections_max / listen.shards);
    const requests = try gpa.create(Requests);
    requests.* = try .init(gpa, connections_per_shard);
    shard_requests = requests;
    roc_allocations_idle = roc_allocations_live;

    const config: fourneau.server.Config = .{
        .connections_max = connections_per_shard,
        .tls = listen.tls,
    };
    // The shard's fibers, all mapped now: its server's, and the redirect's.
    const fibers_max = config.fibers_max() +
        if (listen.https.redirect_port != null) Redirect.fibers_max else 0;
    var runtime: Evented = undefined;
    try runtime_init(&runtime, gpa, fibers_max);
    defer runtime.deinit();

    const io = runtime.io();
    shard_io = io;
    // SQLite's files on this shard wait through its ring, yielding fibers.
    sqlite_vfs.thread_io = io;
    if (database) |opened| try open_shard_database(gpa, opened);
    const address = try std.Io.net.IpAddress.parse(listen_address(), listen.port);
    const listener = try address.listen(io, .{ .reuse_address = true, .kernel_backlog = 4096 });
    var server = try Server.init(gpa, io, app, listener, config);
    var group: std.Io.Group = .init;
    var redirect: Redirect = undefined;
    var redirect_server: Redirect.Server = undefined;
    if (listen.https.redirect_port) |port| {
        assert(listen.tls != null); // redirecting to HTTPS
        redirect = .{ .host = listen.https.https_host.? };
        redirect_server = try redirect.listen(gpa, io, listen_address(), port);
        try group.concurrent(io, run_redirect, .{&redirect_server});
    }
    try server.run();
}

/// How long a shard waits for its ring's locked memory: 40 tries, 50 ms
/// apart.
const runtime_init_tries = 40;
const runtime_init_wait_ns = 50 * std.time.ns_per_ms;

/// The shard's runtime and its ring. A restart right after a stop (roux
/// dev's) can find the old process's rings not yet freed: the kernel frees
/// them after the process is gone, and until then their memory counts
/// against the user's locked memory (8 MiB on the laptop, shared with every
/// other server the user runs). So `SystemResources` is waited out, for at
/// most two seconds, then reported.
fn runtime_init(runtime: *Evented, gpa: std.mem.Allocator, fibers_max: u32) !void {
    var tries: u32 = 0;
    while (true) {
        tries += 1;
        runtime.init(gpa, .{
            .thread_limit = 0, // this thread only
            // Not the default 8: with hundreds of connections the queues
            // overflowed, costing ~3,000 kernel cycles a request (fourneau's
            // experiment 23).
            .log2_ring_entries = 12,
            .fibers_max = fibers_max,
        }) catch |err| switch (err) {
            error.SystemResources => {
                if (tries == runtime_init_tries) {
                    write_line(2, "roux: no locked memory for the shard's io_uring " ++
                        "(other servers of this user hold it; ulimit -l)");
                    return err;
                }
                const wait: std.os.linux.timespec = .{ .sec = 0, .nsec = runtime_init_wait_ns };
                _ = std.os.linux.nanosleep(&wait, null);
                continue;
            },
            else => return err,
        };
        return;
    }
}

/// SQLite with a heap of its own, allocated now: untouched pages until
/// SQLite uses them, nothing allocated after.
fn sqlite_setup(shards: u32) !void {
    const bytes = database_module.heap_bytes(shards, .{});
    const page: std.mem.Alignment = .fromByteUnits(std.heap.page_size_min);
    const heap = std.heap.page_allocator.rawAlloc(bytes, page, @returnAddress()) orelse
        return error.OutOfMemory;
    try sqlite.initialize_with(.{ .heap = heap[0..bytes] });
}

/// The shard's readers, and a buffer of rows for each, sized for the
/// largest `rows_max` of the database's statements.
fn open_shard_database(gpa: std.mem.Allocator, opened: *database_module.Database) !void {
    var report: database_module.Report = .{};
    const readers = try gpa.create(database_module.ReaderPool);
    readers.* = database_module.ReaderPool.open(gpa, opened, &report) catch {
        write_line(2, report.message());
        return error.DatabaseReader;
    };
    shard_readers = readers;
    shard_reader_rows = try gpa.alloc([]RocRow, readers.readers.len);
    for (shard_reader_rows) |*rows| rows.* = try gpa.alloc(RocRow, rows_max_of(opened));
}

fn rows_max_of(opened: *const database_module.Database) u32 {
    var rows_max: u32 = 1;
    for (opened.statements) |statement| rows_max = @max(rows_max, statement.rows_max);
    return rows_max;
}

/// The connection's own buffer of rows: the writer's, or its reader's.
fn rows_for(
    opened: *const database_module.Database,
    connection: *database_module.Connection,
) []RocRow {
    if (connection == opened.writer) return writer_rows;
    const readers = shard_readers.?;
    for (readers.readers, shard_reader_rows) |reader, rows| {
        if (reader == connection) return rows;
    }
    unreachable; // a connection is the writer or a reader of this shard
}

/// Where to listen: `ROUX_ADDRESS`, else loopback. Where a server
/// listens is the deployment's to say (a race droplet listens on its
/// private address), not the app's; its port is the app's.
fn listen_address() []const u8 {
    const value = std.c.getenv("ROUX_ADDRESS") orelse return "127.0.0.1";
    return std.mem.span(value);
}

/// The musl that `roc build` links predates `statx`, which Zig's standard
/// library calls through libc when libc is linked: the system call itself.
export fn statx(
    dirfd: i32,
    path: [*:0]const u8,
    flags: u32,
    mask: u32,
    buffer: *std.os.linux.Statx,
) callconv(.c) i32 {
    const linux = std.os.linux;
    const result = linux.statx(dirfd, path, flags, @bitCast(mask), buffer);
    return switch (linux.errno(result)) {
        .SUCCESS => 0,
        else => |errno| set_errno(errno),
    };
}

extern fn __errno_location() *i32;

fn set_errno(errno: std.os.linux.E) i32 {
    __errno_location().* = @intCast(@backingInt(errno));
    return -1;
}
