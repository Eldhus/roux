//! roux-db-floor: examples/sqlite's three database workloads with no Roc,
//! so a roux request's cost splits into the database's and the Roc
//! boundary's (experiment 21).
//!
//!   roux-db-floor DATABASE [PORT]
//!
//! fourneau, one shard per CPU, and the host's own database.zig: the same
//! statements as examples/sqlite (by_id, with_stars, Reviews.add), a reader
//! per shard, the one writer; the answers formatted here, in Zig.
//!
//!   GET /dishes/ID                one dish
//!   GET /                         every dish with its stars (a LEFT JOIN)
//!   POST /reviews?dish_id=D&stars=S   a write, committed

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const fourneau = @import("fourneau");
const Evented = @import("zig_io_evented");
const database_module = @import("database.zig");
const sqlite = @import("sqlite");
const types = sqlite.types;

const Header = fourneau.http1_response.Header;

const by_id = 0;
const with_stars = 1;
const add_review = 2;

fn code(scalar: types.Scalar, nullable: bool) u8 {
    return (types.Type{ .scalar = scalar, .nullable = nullable }).code();
}

/// As examples/sqlite/db/Database.roc describes them.
const statements = [_]database_module.StatementDescription{
    .{
        .name = "Dishes.by_id",
        .sql = "SELECT id, name, price_kr, note FROM dish WHERE id = :id;",
        .writes = false,
        .rows_max = 1,
        .params = &.{code(.i64, false)},
        .columns = &.{ code(.i64, false), code(.str, false), code(.i64, false), code(.str, true) },
    },
    .{
        .name = "Dishes.with_stars",
        .sql = "SELECT d.name, avg(r.stars) AS average, max(r.stars) AS best_stars\n" ++
            "FROM dish d LEFT JOIN review r ON r.dish_id = d.id\n" ++
            "GROUP BY d.id ORDER BY d.name;",
        .writes = false,
        .rows_max = 200,
        .params = &.{},
        .columns = &.{ code(.str, false), code(.f64, true), code(.i64, true) },
    },
    .{
        .name = "Reviews.add",
        .sql = "INSERT INTO review (dish_id, stars) VALUES (:dish_id, :stars);",
        .writes = true,
        .rows_max = 0,
        .params = &.{ code(.i64, false), code(.i64, false) },
        .columns = &.{},
    },
};

var database: *database_module.Database = undefined;
threadlocal var shard_readers: database_module.ReaderPool = undefined;
threadlocal var shard_io: Io = undefined;

const text_plain: []const Header = &.{
    .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
};

const App = struct {
    pub const Response = struct {
        status: u16,
        headers: []const Header,
        body: []const u8,
    };

    pub fn handle(app: *App, request: *Server.Request) Response {
        _ = app;
        const head = request.head;
        const path = head.path_and_query;
        var report: database_module.Report = .{};
        const body = route(head.method, path, request.scratch, &report) catch |err| {
            const status: u16 = switch (err) {
                error.NotFound => 404,
                error.BadRequest => 400,
                error.Failed => 500,
                error.NoSpaceLeft => 500,
            };
            return .{ .status = status, .headers = text_plain, .body = "" };
        };
        return .{ .status = 200, .headers = text_plain, .body = body };
    }

    pub fn release(app: *App, response: *Response) void {
        _ = app;
        response.* = undefined;
    }
};

const Server = fourneau.server.ServerType(App, .{ .send_then_receive = Evented.sendThenReceive });

const RouteError = error{ NotFound, BadRequest, Failed, NoSpaceLeft };

fn route(
    method: fourneau.http1_head.Method,
    path: []const u8,
    scratch: []u8,
    report: *database_module.Report,
) RouteError![]const u8 {
    if (method == .get and std.mem.eql(u8, path, "/")) return menu(scratch, report);
    if (method == .get and std.mem.startsWith(u8, path, "/dishes/")) {
        const id = std.fmt.parseInt(i64, path["/dishes/".len..], 10) catch return error.BadRequest;
        return dish(id, scratch, report);
    }
    if (method == .post and std.mem.startsWith(u8, path, "/reviews?")) {
        const dish_id = try query_i64(path, "dish_id");
        const stars = try query_i64(path, "stars");
        try database_module.begin_write(database, shard_io, report);
        const params = [_]database_module.Value{ .{ .integer = dish_id }, .{ .integer = stars } };
        var none: Discard = .{};
        database_module.run(
            database,
            database.writer,
            add_review,
            &params,
            shard_io,
            &none,
            report,
        ) catch {
            database_module.rollback_write(database, shard_io);
            return error.Failed;
        };
        try database_module.commit_write(database, shard_io, report);
        return "reviewed\n";
    }
    return error.NotFound;
}

fn query_i64(path: []const u8, key: []const u8) RouteError!i64 {
    const mark = std.mem.indexOfScalar(u8, path, '?') orelse return error.BadRequest;
    const query = path[mark + 1 ..];
    var pairs = std.mem.splitScalar(u8, query, '&');
    for (0..16) |_| {
        const pair = pairs.next() orelse break;
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..equals], key)) continue;
        return std.fmt.parseInt(i64, pair[equals + 1 ..], 10) catch error.BadRequest;
    }
    return error.BadRequest;
}

/// One dish: `name: price kr (note)`, as examples/sqlite answers.
fn dish(id: i64, scratch: []u8, report: *database_module.Report) RouteError![]const u8 {
    var rows: Cells = .{};
    const params = [_]database_module.Value{.{ .integer = id }};
    const reader = try shard_readers.lease(shard_io, database.limits, report);
    defer shard_readers.release(shard_io, reader);
    try database_module.run(database, reader, by_id, &params, shard_io, &rows, report);
    if (rows.rows == 0) return error.NotFound;
    var w = Io.Writer.fixed(scratch);
    const name = rows.cells[1].text;
    w.print("{s}: {d} kr", .{ name, rows.cells[2].integer }) catch return error.NoSpaceLeft;
    switch (rows.cells[3]) {
        .text => |note| w.print(" ({s})", .{note}) catch return error.NoSpaceLeft,
        else => {},
    }
    w.writeAll("\n") catch return error.NoSpaceLeft;
    return w.buffered();
}

/// Every dish with its stars, a line each, written as the rows come.
fn menu(scratch: []u8, report: *database_module.Report) RouteError![]const u8 {
    var lines: MenuLines = .{ .writer = Io.Writer.fixed(scratch) };
    const reader = try shard_readers.lease(shard_io, database.limits, report);
    defer shard_readers.release(shard_io, reader);
    try database_module.run(database, reader, with_stars, &.{}, shard_io, &lines, report);
    if (lines.full) return error.NoSpaceLeft;
    return lines.writer.buffered();
}

/// The cells of at most one row (by_id): its text points into SQLite's
/// row, read before the statement is reset.
const Cells = struct {
    cells: [4]database_module.Value = undefined,
    count: u32 = 0,
    rows: u32 = 0,
    text: [256]u8 = undefined,
    text_used: u32 = 0,

    pub fn row(cells: *Cells) error{}!void {
        cells.rows += 1;
    }

    pub fn cell(cells: *Cells, value: database_module.Value) error{}!void {
        assert(cells.count < cells.cells.len);
        // Text is copied: SQLite's bytes go when the statement is reset.
        cells.cells[cells.count] = switch (value) {
            .text => |text| text: {
                const length: u32 = @intCast(@min(text.len, cells.text.len - cells.text_used));
                const copy = cells.text[cells.text_used..][0..length];
                @memcpy(copy, text[0..length]);
                cells.text_used += length;
                break :text .{ .text = copy };
            },
            else => value,
        };
        cells.count += 1;
    }
};

const MenuLines = struct {
    writer: Io.Writer,
    column: u32 = 0,
    full: bool = false,

    pub fn row(lines: *MenuLines) error{}!void {
        lines.column = 0;
    }

    pub fn cell(lines: *MenuLines, value: database_module.Value) error{}!void {
        defer lines.column += 1;
        const w = &lines.writer;
        const written = switch (lines.column) {
            0 => w.print("{s}: ", .{value.text}),
            1 => switch (value) {
                .real => |mean| w.print("{d} stars", .{mean}),
                else => w.writeAll("no reviews"),
            },
            2 => switch (value) {
                .integer => |best| w.print(", best {d}\n", .{best}),
                else => w.writeAll("\n"),
            },
            else => unreachable, // three columns
        };
        written catch {
            lines.full = true;
        };
    }
};

const Discard = struct {
    pub fn row(_: *Discard) error{}!void {}
    pub fn cell(_: *Discard, _: database_module.Value) error{}!void {}
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: roux-db-floor DATABASE [PORT]\n", .{});
        std.process.exit(2);
    }
    const port: u16 = if (args.len > 2) try std.fmt.parseInt(u16, args[2], 10) else 8095;
    sqlite.vfs.thread_io = init.io;
    var report: database_module.Report = .{};
    const description: database_module.Description = .{
        .path = args[1],
        .schema = @embedFile("floor_schema.sql"),
        .statements = &statements,
    };
    database = database_module.open(std.heap.page_allocator, description, .{}, &report) catch {
        std.debug.print("roux-db-floor: {s}\n", .{report.message()});
        std.process.exit(1);
    };
    const shards = shard_count();
    const shards_max = 64;
    var threads: [shards_max]std.Thread = undefined;
    for (threads[1..shards]) |*thread| {
        thread.* = try std.Thread.spawn(.{}, run_shard, .{ port, shards });
    }
    std.debug.print("roux-db-floor on http://127.0.0.1:{d} ({d} shards)\n", .{ port, shards });
    run_shard(port, shards);
}

fn shard_count() u32 {
    const linux = std.os.linux;
    var set: linux.cpu_set_t = @splat(0);
    const result = linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &set);
    if (linux.errno(result) != .SUCCESS) return 1;
    var count: u32 = 0;
    for (set) |word| count += @popCount(word);
    return @max(1, @min(count, 64));
}

fn run_shard(port: u16, shards: u32) void {
    run_shard_or_fail(port, shards) catch |err| std.debug.panic("shard: {t}", .{err});
}

fn run_shard_or_fail(port: u16, shards: u32) !void {
    const gpa = std.heap.page_allocator;
    var runtime: Evented = undefined;
    try runtime.init(gpa, .{ .thread_limit = 0, .log2_ring_entries = 12 });
    defer runtime.deinit();
    const io = runtime.io();
    shard_io = io;
    sqlite.vfs.thread_io = io;
    var report: database_module.Report = .{};
    shard_readers = database_module.ReaderPool.open(gpa, database, &report) catch {
        std.debug.print("roux-db-floor: {s}\n", .{report.message()});
        return error.Reader;
    };
    const address = try Io.net.IpAddress.parse("127.0.0.1", port);
    const listener = try address.listen(io, .{ .reuse_address = true, .kernel_backlog = 4096 });
    var app: App = .{};
    const connections_max = @max(1, 1024 / shards);
    var server = try Server.init(gpa, io, &app, listener, .{ .connections_max = connections_max });
    try server.run();
}
