//! roux's VFS: SQLite's files through the calling thread's `std.Io`.
//!
//! On a shard that `Io` is Evented (io_uring): a read, a write, a sync
//! that waits on the disk yields its fiber, and the shard serves its other
//! requests meanwhile. With SQLite's own unix VFS the same wait held the
//! shard's thread: at 100 commits a second its reads' p99 went from 0.3 ms
//! to 3.6-6.7 ms (DIARY, step 5).
//!
//! One process owns the database. Its locks are in memory (`Shared`), not
//! fcntl's; the WAL's index is in heap regions, not a `-shm` file. Another
//! process (the `sqlite3` shell) is refused: the first open takes an open
//! file description lock on the whole file, which conflicts with every
//! lock SQLite's own VFS would take.
//!
//! Yielding inside SQLite is safe only where this thread holds no SQLite
//! mutex (mutex.zig counts them); every call here that may yield asserts
//! so. Randomness and the clock never yield: `getrandom` and the vDSO.
//!
//! An interface file: SQLite's VFS is a table of C function pointers.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Io = std.Io;
const linux = std.os.linux;
const c = @import("c.zig");
const mutex = @import("mutex.zig");

/// The `Io` this thread's SQLite calls wait through: set as a thread
/// starts using SQLite (the host's startup, each shard, a test).
pub threadlocal var thread_io: ?Io = null;

/// This thread's calls into the VFS, by kind: what SQLite asks of the
/// disk, per statement (sqlite-floor prints them).
pub const Calls = struct {
    open: u64 = 0,
    read: u64 = 0,
    write: u64 = 0,
    sync: u64 = 0,
    size: u64 = 0,
    access: u64 = 0,
    lock: u64 = 0,
    shm_lock: u64 = 0,
    shm_map: u64 = 0,
};
pub threadlocal var calls: Calls = .{};

pub const name = "roux";
const path_bytes_max = 512;
/// The WAL index is made of regions this size (SQLite's, asserted).
const shm_region_bytes = 32 * 1024;
/// 2 MiB of index: 64 regions of 4,096 frames each, a WAL of a quarter
/// million pages; past it, a write fails (`SQLITE_IOERR_SHMSIZE`).
const shm_regions_max = 64;
const shm_bytes = shm_regions_max * shm_region_bytes;
const page: std.mem.Alignment = .fromByteUnits(4096);
/// Database files one process opens (each with its WAL).
const databases_max = 4;
const spins_max = 1 << 24;

const Kind = enum(u8) { main, wal, journal };
const kinds = 3;

/// A file SQLite opened: `base` first, as SQLite reads it.
const File = extern struct {
    base: c.File,
    handle: std.posix.fd_t,
    kind: Kind,
    /// The lock this connection holds on the database file (main only).
    lock: u8,
    shm_shared: u8,
    shm_exclusive: u8,
    shm_mapped: bool,
    /// Created by this open: its directory is synced on its first sync.
    sync_directory: bool,
    shared: ?*Shared,
};

/// One database file, as every connection of the process shares it.
const Shared = struct {
    path: [path_bytes_max]u8 = undefined,
    path_length: u32 = 0,
    /// Held open for the process's life, with the lock that keeps other
    /// processes out.
    owner: std.posix.fd_t = -1,
    guard: std.atomic.Value(u32) = .init(0),
    // The database file's locks (SQLite's five levels).
    shared_count: u32 = 0,
    reserved: ?*File = null,
    pending: ?*File = null,
    exclusive: ?*File = null,
    // The WAL index.
    shm: ?[*]u8 = null,
    shm_regions: u32 = 0,
    shm_mappers: u32 = 0,
    shm_shared: [c.shm_locks]u32 = @splat(0),
    shm_exclusive: [c.shm_locks]?*File = @splat(null),
    /// Main-file opens of this database; at 0 the slot is free again.
    files_open: u32 = 0,
    /// Each file's size (database, WAL, journal), by kind. One process
    /// owns the files, so only its own writes and truncates change them:
    /// read once at the first open, kept since, and a size asked for costs
    /// no system call (one a read transaction would make: experiment in
    /// the DIARY, 2026-10-06). Checked against the file's in tests.
    sizes: [kinds]u64 = @splat(0),
    sizes_known: [kinds]bool = @splat(false),

    fn take(shared: *Shared) void {
        for (0..spins_max) |_| {
            if (shared.guard.cmpxchgWeak(0, 1, .acquire, .monotonic) == null) return;
            std.atomic.spinLoopHint();
        } else unreachable; // held only for a few instructions, never across a yield
    }

    fn give(shared: *Shared) void {
        assert(shared.guard.swap(0, .release) == 1);
    }
};

var databases: [databases_max]Shared = @splat(.{});
var databases_guard: std.atomic.Value(u32) = .init(0);
/// The working directory at registration, for relative paths.
var directory: [path_bytes_max]u8 = undefined;
var directory_length: u32 = 0;

var methods: c.IoMethods = .{
    .version = 2,
    .close = close,
    .read = read,
    .write = write,
    .truncate = truncate,
    .sync = sync,
    .file_size = file_size,
    .lock = lock,
    .unlock = unlock,
    .check_reserved_lock = check_reserved_lock,
    .file_control = file_control,
    .sector_size = sector_size,
    .device_characteristics = device_characteristics,
    .shm_map = shm_map,
    .shm_lock = shm_lock,
    .shm_barrier = shm_barrier,
    .shm_unmap = shm_unmap,
};

var vfs: c.Vfs = .{
    .version = 2,
    .file_bytes = @sizeOf(File),
    .path_bytes_max = path_bytes_max,
    .next = null,
    .name = name,
    .app_data = null,
    .open = open,
    .delete = delete,
    .access = access,
    .full_pathname = full_pathname,
    .randomness = randomness,
    .sleep = sleep,
    .current_time = current_time,
    .get_last_error = get_last_error,
    .current_time_int64 = current_time_int64,
};

/// SQLite has no OS code of its own (`SQLITE_OS_OTHER`): as it initializes
/// it asks for one, and gets this VFS, as the default.
pub export fn sqlite3_os_init() callconv(.c) c_int {
    register() catch return c.err_generic;
    return c.ok;
}

pub export fn sqlite3_os_end() callconv(.c) c_int {
    return c.ok;
}

fn register() error{Sqlite}!void {
    // The kernel's length counts the terminating zero.
    const result = linux.getcwd(&directory, directory.len);
    if (linux.errno(result) != .SUCCESS or result < 2) return error.Sqlite;
    directory_length = @intCast(result - 1);
    if (c.sqlite3_vfs_register(&vfs, 1) != c.ok) return error.Sqlite;
}

/// The thread's `Io`, for a call that may yield: no SQLite mutex is held.
fn wait_io() Io {
    assert(mutex.held == 0);
    return thread_io.?; // set by every thread that uses SQLite's files
}

fn file_of(base: *c.File) *File {
    return @fieldParentPtr("base", base);
}

// --- the VFS ----------------------------------------------------------------------

fn open(
    _: *c.Vfs,
    path: ?[*:0]const u8,
    base: *c.File,
    flags: c_int,
    out_flags: ?*c_int,
) callconv(.c) c_int {
    calls.open += 1;
    base.methods = null; // a failed open has none
    const kind: Kind = if (flags & c.open_main_db != 0)
        .main
    else if (flags & c.open_wal != 0)
        .wal
    else if (flags & c.open_main_journal != 0)
        .journal
    else
        return c.cantopen; // temporary files: none, all temporaries are in memory
    const text = std.mem.span(path orelse return c.cantopen);
    if (text.len >= path_bytes_max) return c.cantopen;
    const create = flags & c.open_create != 0;
    const handle = open_handle(text, create, flags & c.open_readonly != 0) catch return c.cantopen;
    const file = file_of(base);
    file.* = .{
        .base = .{ .methods = &methods },
        .handle = handle,
        .kind = kind,
        .lock = c.lock_none,
        .shm_shared = 0,
        .shm_exclusive = 0,
        .shm_mapped = false,
        .sync_directory = create and kind != .main,
        .shared = null,
    };
    file.shared = if (kind == .main) share(text) catch null else lookup(base_path(text, kind));
    const shared = file.shared orelse {
        wait_io_close(handle);
        base.methods = null;
        return c.cantopen; // the database opens first; its WAL and journal after
    };
    know_size(shared, file) catch {
        _ = close(base);
        return c.cantopen;
    };
    if (out_flags) |out| out.* = flags;
    return c.ok;
}

/// The database's path for its WAL's or journal's.
fn base_path(path: []const u8, kind: Kind) []const u8 {
    const suffix = switch (kind) {
        .main => return path,
        .wal => "-wal",
        .journal => "-journal",
    };
    assert(std.mem.endsWith(u8, path, suffix)); // SQLite's names
    return path[0 .. path.len - suffix.len];
}

/// The size of a file the process has not opened since it last changed
/// unseen (never, or deleted): one stat.
fn know_size(shared: *Shared, file: *const File) !void {
    const kind = @backingInt(file.kind);
    shared.take();
    const known = shared.sizes_known[kind];
    shared.give();
    if (known) return;
    const length = try io_file(file).length(wait_io()); // outside the guard: may yield
    shared.take();
    defer shared.give();
    shared.sizes[kind] = length;
    shared.sizes_known[kind] = true;
}

fn lookup(path: []const u8) ?*Shared {
    take_databases();
    defer give_databases();
    for (&databases) |*shared| {
        if (shared.path_length == path.len and std.mem.eql(u8, shared.path[0..path.len], path)) {
            return shared;
        }
    }
    return null;
}

fn open_handle(path: []const u8, create: bool, read_only: bool) !std.posix.fd_t {
    const io = wait_io();
    const Mode = @FieldType(Io.Dir.OpenFileOptions, "mode");
    const mode: Mode = if (read_only) .read_only else .read_write;
    const opened = if (create)
        try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false })
    else
        try Io.Dir.cwd().openFile(io, path, .{ .mode = mode });
    return opened.handle;
}

fn wait_io_close(handle: std.posix.fd_t) void {
    const file: Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
    file.close(wait_io());
}

/// The process's state for the database at `path`: made by its first
/// open, which also takes the lock that keeps other processes out.
fn share(path: []const u8) !*Shared {
    take_databases();
    defer give_databases();
    for (&databases) |*shared| {
        if (shared.path_length == path.len and std.mem.eql(u8, shared.path[0..path.len], path)) {
            shared.files_open += 1;
            return shared;
        }
    }
    for (&databases) |*shared| {
        if (shared.path_length != 0) continue;
        shared.owner = try own(path);
        // The index, untouched until used: zero pages from the kernel.
        const shm = std.heap.page_allocator.rawAlloc(shm_bytes, page, @returnAddress()) orelse
            return error.OutOfMemory;
        shared.shm = shm;
        @memcpy(shared.path[0..path.len], path);
        shared.path_length = @intCast(path.len);
        shared.files_open = 1;
        return shared;
    } else return error.TooManyDatabases;
}

/// The last connection closed the database: its slot, its index and the
/// lock that kept other processes out are given back.
fn unshare(shared: *Shared) void {
    take_databases();
    defer give_databases();
    assert(shared.files_open > 0);
    shared.files_open -= 1;
    if (shared.files_open > 0) return;
    assert(shared.shared_count == 0 and shared.shm_mappers == 0);
    const io = wait_io();
    const owner: Io.File = .{ .handle = shared.owner, .flags = .{ .nonblocking = false } };
    owner.close(io);
    std.heap.page_allocator.rawFree(shared.shm.?[0..shm_bytes], page, @returnAddress());
    shared.* = .{};
}

/// An open file description lock on the whole file, write: no other
/// process takes any lock on it while this process lives.
fn own(path: []const u8) !std.posix.fd_t {
    const io = wait_io();
    const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    const Flock = extern struct { type: i16, whence: i16, start: i64, length: i64, pid: i32 };
    var whole: Flock = .{ .type = 1, .whence = 0, .start = 0, .length = 0, .pid = 0 }; // F_WRLCK
    const ofd_set_lock = 37; // F_OFD_SETLK
    const result = linux.fcntl(file.handle, ofd_set_lock, @intFromPtr(&whole));
    if (linux.errno(result) != .SUCCESS) {
        file.close(io);
        return error.DatabaseInUse;
    }
    return file.handle;
}

fn take_databases() void {
    for (0..spins_max) |_| {
        if (databases_guard.cmpxchgWeak(0, 1, .acquire, .monotonic) == null) return;
        std.atomic.spinLoopHint();
    } else unreachable;
}

fn give_databases() void {
    assert(databases_guard.swap(0, .release) == 1);
}

fn delete(_: *c.Vfs, path: [*:0]const u8, sync_directory: c_int) callconv(.c) c_int {
    const io = wait_io();
    const text = std.mem.span(path);
    Io.Dir.cwd().deleteFile(io, text) catch |err| return switch (err) {
        error.FileNotFound => c.ioerr_delete_noent,
        else => c.ioerr_delete,
    };
    forget_size(text);
    if (sync_directory != 0) sync_parent(text) catch return c.ioerr_delete;
    return c.ok;
}

/// A WAL or journal deleted: its size is unknown until it is opened again.
fn forget_size(path: []const u8) void {
    const kind: Kind = if (std.mem.endsWith(u8, path, "-wal"))
        .wal
    else if (std.mem.endsWith(u8, path, "-journal"))
        .journal
    else
        return; // SQLite deletes no database file
    const shared = lookup(base_path(path, kind)) orelse return;
    shared.take();
    defer shared.give();
    shared.sizes[@backingInt(kind)] = 0;
    shared.sizes_known[@backingInt(kind)] = false;
}

fn sync_parent(path: []const u8) !void {
    const io = wait_io();
    const parent = std.fs.path.dirname(path) orelse ".";
    const directory_file = try Io.Dir.cwd().openFile(io, parent, .{ .mode = .read_only });
    defer directory_file.close(io);
    try directory_file.sync(io);
}

fn access(_: *c.Vfs, path: [*:0]const u8, flags: c_int, out: *c_int) callconv(.c) c_int {
    _ = flags; // exists, or read-write: one process, files it made
    calls.access += 1;
    const io = wait_io();
    const stat = Io.Dir.cwd().statFile(io, std.mem.span(path), .{}) catch |err| switch (err) {
        error.FileNotFound => {
            out.* = 0;
            return c.ok;
        },
        else => return c.ioerr_access,
    };
    // As SQLite's own: an empty file is not there (a WAL left at 0 bytes).
    out.* = @intFromBool(stat.size > 0 or stat.kind != .file);
    return c.ok;
}

fn full_pathname(_: *c.Vfs, path: [*:0]const u8, out_bytes: c_int, out: [*]u8) callconv(.c) c_int {
    const text = std.mem.span(path);
    const capacity: usize = @intCast(out_bytes);
    const absolute = text.len > 0 and text[0] == '/';
    const length = if (absolute) text.len else directory_length + 1 + text.len;
    if (length + 1 > capacity) return c.cantopen;
    if (absolute) {
        @memcpy(out[0..text.len], text);
    } else {
        @memcpy(out[0..directory_length], directory[0..directory_length]);
        out[directory_length] = '/';
        @memcpy(out[directory_length + 1 ..][0..text.len], text);
    }
    out[length] = 0;
    return c.ok;
}

/// Never yields (SQLite may ask with its PRNG mutex held): the system call.
fn randomness(_: *c.Vfs, bytes: c_int, out: [*]u8) callconv(.c) c_int {
    const buffer = out[0..@intCast(bytes)];
    var filled: usize = 0;
    for (0..64) |_| {
        if (filled == buffer.len) break;
        const result = linux.getrandom(buffer[filled..].ptr, buffer.len - filled, 0);
        if (linux.errno(result) == .SUCCESS) filled += result;
    }
    return bytes;
}

fn sleep(_: *c.Vfs, microseconds: c_int) callconv(.c) c_int {
    wait_io().sleep(.fromMicroseconds(microseconds), .awake) catch {};
    return microseconds;
}

/// Milliseconds since the Julian epoch, from the vDSO's clock.
fn now_julian_ms() i64 {
    var spec: linux.timespec = undefined;
    assert(linux.errno(linux.clock_gettime(.REALTIME, &spec)) == .SUCCESS);
    const unix_ms = @as(i64, spec.sec) * 1000 + @divTrunc(@as(i64, spec.nsec), 1_000_000);
    return unix_ms + 210_866_760_000_000; // the Unix epoch, in Julian milliseconds
}

fn current_time(_: *c.Vfs, out: *f64) callconv(.c) c_int {
    out.* = @as(f64, @floatFromInt(now_julian_ms())) / 86_400_000.0;
    return c.ok;
}

fn current_time_int64(_: *c.Vfs, out: *i64) callconv(.c) c_int {
    out.* = now_julian_ms();
    return c.ok;
}

fn get_last_error(_: *c.Vfs, _: c_int, _: ?[*]u8) callconv(.c) c_int {
    return 0;
}

// --- a file -----------------------------------------------------------------------

fn io_file(file: *const File) Io.File {
    return .{ .handle = file.handle, .flags = .{ .nonblocking = false } };
}

fn close(base: *c.File) callconv(.c) c_int {
    const file = file_of(base);
    if (file.kind == .main) _ = unlock(base, c.lock_none);
    assert(!file.shm_mapped); // SQLite unmaps before it closes
    io_file(file).close(wait_io());
    if (file.kind == .main) unshare(file.shared.?);
    base.methods = null;
    return c.ok;
}

fn read(base: *c.File, buffer: ?*anyopaque, amount: c_int, offset: i64) callconv(.c) c_int {
    calls.read += 1;
    const file = file_of(base);
    const bytes: [*]u8 = @ptrCast(buffer.?);
    const wanted = bytes[0..@intCast(amount)];
    const got = io_file(file).readPositionalAll(wait_io(), wanted, @intCast(offset)) catch
        return c.ioerr_read;
    if (got == wanted.len) return c.ok;
    // Past the end: SQLite wants the rest zeroed, and to be told.
    @memset(wanted[got..], 0);
    return c.ioerr_short_read;
}

fn write(base: *c.File, buffer: ?*const anyopaque, amount: c_int, offset: i64) callconv(.c) c_int {
    calls.write += 1;
    const file = file_of(base);
    const bytes: [*]const u8 = @ptrCast(buffer.?);
    io_file(file).writePositionalAll(wait_io(), bytes[0..@intCast(amount)], @intCast(offset)) catch
        return c.ioerr_write;
    const shared = file.shared.?;
    shared.take();
    defer shared.give();
    const kind = @backingInt(file.kind);
    assert(shared.sizes_known[kind]);
    shared.sizes[kind] = @max(shared.sizes[kind], @as(u64, @intCast(offset + amount)));
    return c.ok;
}

fn truncate(base: *c.File, size: i64) callconv(.c) c_int {
    const file = file_of(base);
    io_file(file).setLength(wait_io(), @intCast(size)) catch return c.ioerr_truncate;
    const shared = file.shared.?;
    shared.take();
    defer shared.give();
    shared.sizes[@backingInt(file.kind)] = @intCast(size);
    return c.ok;
}

fn sync(base: *c.File, flags: c_int) callconv(.c) c_int {
    _ = flags; // a full sync always
    calls.sync += 1;
    const file = file_of(base);
    io_file(file).sync(wait_io()) catch return c.ioerr_fsync;
    if (file.sync_directory) {
        // A file this open made is durable when its directory entry is.
        var path_buffer: [path_bytes_max]u8 = undefined;
        const path = path_of(file, &path_buffer) catch return c.ioerr_fsync;
        sync_parent(path) catch return c.ioerr_fsync;
        file.sync_directory = false;
    }
    return c.ok;
}

/// The file's path, from the kernel (a WAL's or journal's: not kept).
fn path_of(file: *const File, buffer: *[path_bytes_max]u8) ![]const u8 {
    var link: [64]u8 = undefined;
    const proc = try std.fmt.bufPrintSentinel(&link, "/proc/self/fd/{d}", .{file.handle}, 0);
    const length = linux.readlink(proc, buffer, buffer.len);
    if (linux.errno(length) != .SUCCESS) return error.Unreadable;
    return buffer[0..length];
}

fn file_size(base: *c.File, size: *i64) callconv(.c) c_int {
    calls.size += 1;
    const file = file_of(base);
    const shared = file.shared.?;
    const kind = @backingInt(file.kind);
    shared.take();
    assert(shared.sizes_known[kind]); // since this file opened
    const known = shared.sizes[kind];
    shared.give();
    if (builtin.is_test) {
        // The cache is the file's: what one process owning it promises.
        const length = io_file(file).length(wait_io()) catch return c.ioerr_fstat;
        assert(length == known);
    }
    size.* = @intCast(known);
    return c.ok;
}

fn file_control(_: *c.File, _: c_int, _: ?*anyopaque) callconv(.c) c_int {
    return c.notfound;
}

fn sector_size(_: *c.File) callconv(.c) c_int {
    return 4096;
}

fn device_characteristics(_: *c.File) callconv(.c) c_int {
    return c.iocap_powersafe_overwrite;
}

// --- the database file's locks, in memory -----------------------------------------

/// SQLite's five levels among this process's connections (os_unix.c's
/// rules without fcntl): SHARED while no one holds PENDING or EXCLUSIVE;
/// one RESERVED; EXCLUSIVE through PENDING, once no other SHARED is left.
fn lock(base: *c.File, level: c_int) callconv(.c) c_int {
    calls.lock += 1;
    const file = file_of(base);
    const shared = file.shared.?;
    assert(level == c.lock_shared or level == c.lock_reserved or level == c.lock_exclusive);
    shared.take();
    defer shared.give();
    if (file.lock >= level) return c.ok;
    switch (level) {
        c.lock_shared => {
            assert(file.lock == c.lock_none);
            if (shared.pending != null or shared.exclusive != null) return c.busy;
            shared.shared_count += 1;
        },
        c.lock_reserved => {
            assert(file.lock == c.lock_shared);
            if (shared.reserved != null) return c.busy;
            shared.reserved = file;
        },
        c.lock_exclusive => {
            assert(file.lock >= c.lock_shared);
            if (shared.pending != null and shared.pending != file) return c.busy;
            shared.pending = file;
            file.lock = c.lock_pending;
            if (shared.shared_count > 1) return c.busy; // others still read
            shared.pending = null;
            shared.exclusive = file;
        },
        else => unreachable,
    }
    file.lock = @intCast(level);
    return c.ok;
}

fn unlock(base: *c.File, level: c_int) callconv(.c) c_int {
    const file = file_of(base);
    const shared = file.shared.?;
    assert(level == c.lock_none or level == c.lock_shared);
    shared.take();
    defer shared.give();
    if (file.lock <= level) return c.ok;
    if (shared.reserved == file) shared.reserved = null;
    if (shared.pending == file) shared.pending = null;
    if (shared.exclusive == file) shared.exclusive = null;
    if (level == c.lock_none) {
        assert(shared.shared_count > 0);
        shared.shared_count -= 1;
    }
    file.lock = @intCast(level);
    return c.ok;
}

fn check_reserved_lock(base: *c.File, out: *c_int) callconv(.c) c_int {
    const shared = file_of(base).shared.?;
    shared.take();
    defer shared.give();
    const held = shared.reserved != null or shared.pending != null or shared.exclusive != null;
    out.* = @intFromBool(held);
    return c.ok;
}

// --- the WAL index, in memory ------------------------------------------------------

fn shm_map(
    base: *c.File,
    region: c_int,
    region_bytes: c_int,
    extend: c_int,
    out: *?*volatile anyopaque,
) callconv(.c) c_int {
    calls.shm_map += 1;
    const file = file_of(base);
    const shared = file.shared.?;
    assert(region_bytes == shm_region_bytes);
    const index: u32 = @intCast(region);
    shared.take();
    defer shared.give();
    if (!file.shm_mapped) {
        file.shm_mapped = true;
        shared.shm_mappers += 1;
    }
    if (index >= shared.shm_regions) {
        if (extend == 0) {
            out.* = null;
            return c.ok;
        }
        if (index >= shm_regions_max) return c.ioerr_shmsize;
        shared.shm_regions = index + 1;
    }
    out.* = @ptrCast(shared.shm.? + index * shm_region_bytes);
    return c.ok;
}

/// SQLite's eight WAL locks among this process's connections: a slot is
/// held shared by many or exclusive by one; a lock never waits (busy).
fn shm_lock(base: *c.File, offset: c_int, count: c_int, flags: c_int) callconv(.c) c_int {
    calls.shm_lock += 1;
    const file = file_of(base);
    const shared = file.shared.?;
    assert(offset >= 0 and count >= 1 and offset + count <= c.shm_locks);
    const first: u3 = @intCast(offset);
    const mask: u8 = @truncate(((@as(u16, 1) << @intCast(count)) - 1) << first);
    shared.take();
    defer shared.give();
    if (flags & c.shm_unlock != 0) {
        for (0..c.shm_locks) |slot| {
            const bit = @as(u8, 1) << @intCast(slot);
            if (mask & bit == 0) continue;
            if (file.shm_exclusive & bit != 0) shared.shm_exclusive[slot] = null;
            if (file.shm_shared & bit != 0) shared.shm_shared[slot] -= 1;
        }
        file.shm_exclusive &= ~mask;
        file.shm_shared &= ~mask;
        return c.ok;
    }
    if (flags & c.shm_shared != 0) {
        assert(count == 1); // SQLite's rule
        if (file.shm_shared & mask != 0) return c.ok;
        const slot: usize = first;
        if (shared.shm_exclusive[slot] != null) return c.busy;
        shared.shm_shared[slot] += 1;
        file.shm_shared |= mask;
        return c.ok;
    }
    assert(flags & c.shm_exclusive != 0);
    for (0..c.shm_locks) |slot| {
        const bit = @as(u8, 1) << @intCast(slot);
        if (mask & bit == 0) continue;
        const others_share = shared.shm_shared[slot] > @intFromBool(file.shm_shared & bit != 0);
        const owner = shared.shm_exclusive[slot];
        const other_owns = owner != null and owner != file;
        if (others_share or other_owns) return c.busy;
    }
    for (0..c.shm_locks) |slot| {
        if (mask & (@as(u8, 1) << @intCast(slot)) != 0) shared.shm_exclusive[slot] = file;
    }
    file.shm_exclusive |= mask;
    return c.ok;
}

fn shm_barrier(base: *c.File) callconv(.c) void {
    // A full fence: a sequentially consistent read-modify-write.
    _ = file_of(base).shared.?.guard.fetchAdd(0, .seq_cst);
}

fn shm_unmap(base: *c.File, delete_index: c_int) callconv(.c) c_int {
    const file = file_of(base);
    const shared = file.shared.?;
    shared.take();
    defer shared.give();
    if (!file.shm_mapped) return c.ok;
    assert(file.shm_shared == 0 and file.shm_exclusive == 0);
    file.shm_mapped = false;
    shared.shm_mappers -= 1;
    if (delete_index != 0 and shared.shm_mappers == 0) {
        // The last connection closed the WAL: the next starts from nothing.
        @memset(shared.shm.?[0 .. shared.shm_regions * shm_region_bytes], 0);
        shared.shm_regions = 0;
    }
    return c.ok;
}

fn test_file(shared: *Shared) File {
    return .{
        .base = .{ .methods = &methods },
        .handle = -1,
        .kind = .main,
        .lock = c.lock_none,
        .shm_shared = 0,
        .shm_exclusive = 0,
        .shm_mapped = false,
        .sync_directory = false,
        .shared = shared,
    };
}

test "vfs: the WAL index's locks, shared and exclusive, between two connections" {
    var shared: Shared = .{};
    var first = test_file(&shared);
    var second = test_file(&shared);
    const exclusive = c.shm_lock | c.shm_exclusive;
    const shared_lock = c.shm_lock | c.shm_shared;
    const unlocking = c.shm_unlock | c.shm_exclusive;
    try std.testing.expectEqual(c.ok, shm_lock(&first.base, 3, 1, exclusive));
    try std.testing.expectEqual(c.busy, shm_lock(&second.base, 3, 1, shared_lock));
    try std.testing.expectEqual(c.ok, shm_lock(&second.base, 2, 1, shared_lock)); // another slot
    try std.testing.expectEqual(c.ok, shm_lock(&first.base, 3, 1, unlocking));
    try std.testing.expectEqual(c.ok, shm_lock(&second.base, 3, 1, shared_lock));
    // A range over a slot another shares: busy, and nothing of it taken.
    try std.testing.expectEqual(c.busy, shm_lock(&first.base, 1, 5, exclusive));
    try std.testing.expectEqual(@as(u8, 0), first.shm_exclusive);
    try std.testing.expectEqual(c.ok, shm_lock(&second.base, 2, 2, c.shm_unlock | c.shm_shared));
    try std.testing.expectEqual(c.ok, shm_lock(&first.base, 1, 5, exclusive));
    try std.testing.expectEqual(@as(u8, 0b0011_1110), first.shm_exclusive);
}

test "vfs: the database file's levels, between two connections" {
    var shared: Shared = .{};
    var first = test_file(&shared);
    var second = test_file(&shared);
    try std.testing.expectEqual(c.ok, lock(&first.base, c.lock_shared));
    try std.testing.expectEqual(c.ok, lock(&second.base, c.lock_shared));
    try std.testing.expectEqual(c.ok, lock(&first.base, c.lock_reserved));
    try std.testing.expectEqual(c.busy, lock(&second.base, c.lock_reserved));
    // EXCLUSIVE waits at PENDING while the other reads; no new reader.
    try std.testing.expectEqual(c.busy, lock(&first.base, c.lock_exclusive));
    try std.testing.expectEqual(@as(u8, c.lock_pending), first.lock);
    var third = test_file(&shared);
    try std.testing.expectEqual(c.busy, lock(&third.base, c.lock_shared));
    try std.testing.expectEqual(c.ok, unlock(&second.base, c.lock_none));
    try std.testing.expectEqual(c.ok, lock(&first.base, c.lock_exclusive));
    var out: c_int = 0;
    try std.testing.expectEqual(c.ok, check_reserved_lock(&second.base, &out));
    try std.testing.expectEqual(1, out);
    try std.testing.expectEqual(c.ok, unlock(&first.base, c.lock_none));
    try std.testing.expectEqual(0, shared.shared_count);
    try std.testing.expectEqual(c.ok, check_reserved_lock(&second.base, &out));
    try std.testing.expectEqual(0, out);
}
