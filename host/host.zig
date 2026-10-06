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
/// `handle` is the address of the request, valid for this call: Roc holds
/// it only while `respond!` runs.
export fn hosted_request_body_read_all(handle: u64, limit_bytes: u64) callconv(.c) BodyResult {
    const request: *Server.Request = @ptrFromInt(handle);
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
                };
            }
        }
        const roc_request = request_to_roc(request);
        abi.increfBox(@ptrCast(app.context), 1); // Roc consumes its arguments
        const roc = abi.roc_respond_for_host(roc_request, app.context);
        // The response's headers, as fourneau wants them, in this
        // connection's scratch memory; their bytes stay Roc's until release.
        const table: [*]Header = @ptrCast(@alignCast(request.scratch.ptr));
        const capacity = @min(response_headers_max, request.scratch.len / @sizeOf(Header));
        const roc_headers = roc.headers.items();
        const count = @min(roc_headers.len, capacity);
        for (roc_headers[0..count], table[0..count]) |roc_header, *header| {
            header.* = .{ .name = roc_header.name.asSlice(), .value = roc_header.value.asSlice() };
        }
        return .{
            .status = roc.status,
            .headers = table[0..count],
            .body = roc.body.items(),
            .roc = roc,
        };
    }

    pub fn release(app: *App, response: *Response) void {
        _ = app;
        if (response.roc) |roc| roc.decref(host());
        response.* = undefined;
        assert(requests_in_flight > 0);
        requests_in_flight -= 1;
        // Every request on this shard is done, so everything Roc allocated
        // for them is freed: otherwise Roc (or this host) leaked.
        if (requests_in_flight == 0) assert(roc_allocations_live == roc_allocations_idle);
    }

    fn request_to_roc(request: *Server.Request) RequestFromHost {
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
            .body = @intFromPtr(request),
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

    const init = abi.roc_init_for_host();
    if (init.tag == .Err) {
        const code = init.payload_err();
        std.process.exit(@intCast(@max(0, @min(code, 255))));
    }
    const started = init.payload_ok();
    const port = if (started.port == 0) port_default else started.port;
    const startup_io = std.Io.Threaded.global_single_threaded.io();
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
    roc_allocations_idle = roc_allocations_live;

    const gpa = std.heap.page_allocator;
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
    const address = try std.Io.net.IpAddress.parse(listen_address(), listen.port);
    const listener = try address.listen(io, .{ .reuse_address = true, .kernel_backlog = 4096 });
    var server = try Server.init(gpa, io, app, listener, .{
        .connections_max = @max(1, connections_max / listen.shards),
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
