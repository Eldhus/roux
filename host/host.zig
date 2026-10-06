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
const RequestsType = @import("requests.zig").RequestsType;
const sqlite_vfs = @import("sqlite").vfs;
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
/// The app's static files (`static_dir`), served before `respond!`; read
/// once at startup and shared read-only by every shard.
var static_site: ?*const fourneau.site.Site = null;
/// The app's database, opened by `Sqlite.open!` in `init!`; its writer is
/// shared by every shard under its lock, the rest read-only.
var database: ?*database_module.Database = null;
/// Set as the shards start: `init!` is over (`Sqlite.open!` is its).
var serving = false;

const Requests = RequestsType(Server.Request);
/// This shard's requests in Roc, by handle (requests.zig).
threadlocal var shard_requests: ?*Requests = null;
/// This shard's readers of the database, leased a statement at a time.
threadlocal var shard_readers: ?*database_module.ReaderPool = null;
/// A result's rows, kept here until their count is known: a Roc list of
/// refcounted items is allocated at its length (database's largest
/// `rows_max`, allocated as the shard starts).
threadlocal var shard_rows: []RocRow = &.{};

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
    line.decref(host());
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
    const io = shard_io orelse return file_error(.file_unreadable); // not on a shard
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
    };
    database = database_module.open(gpa, description, .{}, &report) catch
        return open_error(report.message());
    var banner: [256]u8 = undefined;
    write_line(1, std.fmt.bufPrint(&banner, "roux: database {s}, {d} statements", .{
        where, descriptions.len,
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
    var sink: RowsToRoc = .{ .rows = shard_rows, .columns = columns };
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
    };

    pub fn handle(app: *App, request: *Server.Request) Response {
        requests_in_flight += 1;
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
        // The response's headers, as fourneau wants them, in this
        // connection's scratch memory; their bytes stay Roc's until release.
        const table: [*]Header = @ptrCast(@alignCast(request.scratch.ptr));
        const capacity = @min(response_headers_max, request.scratch.len / @sizeOf(Header));
        const roc_headers = roc.headers.items();
        const count = @min(roc_headers.len, capacity);
        for (roc_headers[0..count], table[0..count]) |*roc_header, *header| {
            header.* = .{ .name = roc_header.name.asSlice(), .value = roc_header.value.asSlice() };
        }
        return .{
            .status = roc.status,
            .headers = table[0..count],
            .body = roc.body.items(),
            .roc = roc,
            .handle = request_handle,
        };
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
    // thread's Io until the shards start (roux's VFS).
    const startup_io = std.Io.Threaded.global_single_threaded.io();
    sqlite_vfs.thread_io = startup_io;
    const init = abi.roc_init_for_host();
    if (init.tag == .Err) {
        const code = init.payload_err();
        std.process.exit(@intCast(@max(0, @min(code, 255))));
    }
    const started = init.payload_ok();
    // The app names its port; the deployment may say otherwise (ROUX_PORT),
    // as it says the address: a local run of an app that asks for 443.
    const app_port = if (started.port == 0) port_default else started.port;
    const port = port_from(environment("ROUX_PORT")) orelse app_port;
    const shards = shard_count();
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
        site.* = try fourneau.site.Site.load(gpa, startup_io, static_dir, "", tls != null);
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

fn environment(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

fn port_from(text: ?[]const u8) ?u16 {
    return std.fmt.parseInt(u16, text orelse return null, 10) catch null;
}

/// One shard per CPU this process may run on (its affinity mask, so
/// `taskset` decides), at most `shards_max`.
fn shard_count() u32 {
    var set: std.os.linux.cpu_set_t = @splat(0);
    const linux = std.os.linux;
    const result = linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &set);
    if (linux.errno(result) != .SUCCESS) return 1;
    var count: u32 = 0;
    for (set) |word| count += @popCount(word);
    assert(count >= 1); // we are running on one
    return @min(count, shards_max);
}

fn run_shard(app: *App, listen: Listen) void {
    run_shard_or_fail(app, listen) catch |err| {
        var buffer: [128]u8 = undefined;
        write_line(2, std.fmt.bufPrint(&buffer, "roux: shard: {t}", .{err}) catch "roux");
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

    var runtime: Evented = undefined;
    try runtime.init(gpa, .{
        .thread_limit = 0, // this thread only
        // Not the default 8: with hundreds of connections the queues overflowed,
        // costing ~3,000 kernel cycles a request (fourneau's experiment 23).
        .log2_ring_entries = 12,
    });
    defer runtime.deinit();

    const io = runtime.io();
    shard_io = io;
    // SQLite's files on this shard wait through its ring, yielding fibers.
    sqlite_vfs.thread_io = io;
    if (database) |opened| try open_shard_database(gpa, opened);
    const address = try std.Io.net.IpAddress.parse(listen_address(), listen.port);
    const listener = try address.listen(io, .{ .reuse_address = true, .kernel_backlog = 4096 });
    var server = try Server.init(gpa, io, app, listener, .{
        .connections_max = connections_per_shard,
        .tls = listen.tls,
    });
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

/// The shard's readers, and its buffer of rows, sized for the largest
/// `rows_max` of the database's statements.
fn open_shard_database(gpa: std.mem.Allocator, opened: *database_module.Database) !void {
    var report: database_module.Report = .{};
    const readers = try gpa.create(database_module.ReaderPool);
    readers.* = database_module.ReaderPool.open(gpa, opened, &report) catch {
        write_line(2, report.message());
        return error.DatabaseReader;
    };
    shard_readers = readers;
    var rows_max: u32 = 1;
    for (opened.statements) |statement| rows_max = @max(rows_max, statement.rows_max);
    shard_rows = try gpa.alloc(RocRow, rows_max);
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
