//! SQLite's mutexes, roux's own. SQLite is built with `SQLITE_OS_OTHER`
//! (no OS code of its own), so its default mutexes do nothing; these are
//! what make it safe across shards.
//!
//! A mutex is a futex lock owned by its thread, recursive where SQLite
//! asks. It blocks the thread, not the fiber: SQLite holds one for a few
//! instructions, never across a wait. That is checked: each thread counts
//! the SQLite mutexes it holds (`held`), and roux's VFS asserts the count
//! is zero wherever it may yield, since another fiber of the thread taking
//! the same mutex would block the thread on itself.
//!
//! An interface file: SQLite's `sqlite3_mutex_methods` is a table of C
//! function pointers over its opaque mutex.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const c = @import("c.zig");

/// SQLite mutexes this thread holds now.
pub threadlocal var held: u32 = 0;
/// Its address names this thread: a mutex's owner.
threadlocal var thread_marker: u8 = 0;

const kind_fast = 0;
const kind_recursive = 1;
/// SQLITE_MUTEX_STATIC_MAIN (2) to SQLITE_MUTEX_STATIC_VFS3 (13).
const statics = 12;
/// Mutexes SQLite allocates (not static): few in multi-thread mode.
const dynamic_max = 64;

const Mutex = struct {
    /// 0 free, 1 held, 2 held with a thread waiting.
    state: std.atomic.Value(u32) = .init(0),
    /// The holding thread's marker address; 0 for none.
    owner: std.atomic.Value(usize) = .init(0),
    /// How deep the owner holds it (recursive mutexes only past 1).
    depth: u32 = 0,
    recursive: bool = false,
    in_use: bool = false,
};

var static_mutexes: [statics]Mutex = @splat(.{ .recursive = false });
var dynamic_mutexes: [dynamic_max]Mutex = @splat(.{});
var dynamic_guard: std.atomic.Value(u32) = .init(0);

const methods: c.MutexMethods = .{
    .init = init,
    .end = end,
    .alloc = alloc,
    .free = free,
    .enter = enter,
    .try_enter = try_enter,
    .leave = leave,
    .held = is_held,
    .not_held = is_not_held,
};

/// Installs roux's mutexes, in sqlite.zig's configuration window (before
/// SQLite initializes).
pub fn install() error{Sqlite}!void {
    if (c.sqlite3_config(c.config_mutex, &methods) != c.ok) return error.Sqlite;
}

fn me() usize {
    return @intFromPtr(&thread_marker);
}

fn of(mutex: ?*c.Mutex) *Mutex {
    return @ptrCast(@alignCast(mutex.?));
}

fn init() callconv(.c) c_int {
    return c.ok;
}

fn end() callconv(.c) c_int {
    return c.ok;
}

fn alloc(kind: c_int) callconv(.c) ?*c.Mutex {
    if (kind >= 2) {
        const index: usize = @intCast(kind - 2);
        assert(index < statics); // SQLite's static kinds
        return @ptrCast(&static_mutexes[index]);
    }
    assert(kind == kind_fast or kind == kind_recursive);
    take_guard();
    defer give_guard();
    for (&dynamic_mutexes) |*mutex| {
        if (mutex.in_use) continue;
        mutex.* = .{ .recursive = kind == kind_recursive, .in_use = true };
        return @ptrCast(mutex);
    }
    return null; // SQLite answers SQLITE_NOMEM
}

fn free(mutex: ?*c.Mutex) callconv(.c) void {
    const found = of(mutex);
    assert(found.owner.load(.monotonic) == 0); // freed unheld
    take_guard();
    defer give_guard();
    assert(found.in_use); // a dynamic one: SQLite frees no static mutex
    found.in_use = false;
}

fn take_guard() void {
    for (0..1 << 24) |_| {
        if (dynamic_guard.cmpxchgWeak(0, 1, .acquire, .monotonic) == null) return;
        std.atomic.spinLoopHint();
    } else unreachable;
}

fn give_guard() void {
    assert(dynamic_guard.swap(0, .release) == 1);
}

fn enter(mutex: ?*c.Mutex) callconv(.c) void {
    const found = of(mutex);
    if (found.owner.load(.monotonic) == me()) {
        assert(found.recursive); // a fast mutex entered twice would deadlock
        found.depth += 1;
        held += 1;
        return;
    }
    lock(found);
    found.owner.store(me(), .monotonic);
    assert(found.depth == 0);
    found.depth = 1;
    held += 1;
}

/// The futex lock (Drepper's "Futexes are tricky", mutex 2): free 0, held
/// 1, held and contended 2; a contended release wakes one sleeper.
fn lock(mutex: *Mutex) void {
    if (mutex.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) return;
    // Each pass takes it, or sleeps until a release.
    for (0..1 << 32) |_| {
        if (mutex.state.swap(2, .acquire) == 0) return;
        _ = linux.futex_4arg(&mutex.state.raw, .{ .cmd = .WAIT, .private = true }, 2, null);
    } else unreachable;
}

fn try_enter(mutex: ?*c.Mutex) callconv(.c) c_int {
    const found = of(mutex);
    if (found.owner.load(.monotonic) == me()) {
        assert(found.recursive);
        found.depth += 1;
        held += 1;
        return c.ok;
    }
    if (found.state.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) return c.busy;
    found.owner.store(me(), .monotonic);
    found.depth = 1;
    held += 1;
    return c.ok;
}

fn leave(mutex: ?*c.Mutex) callconv(.c) void {
    const found = of(mutex);
    assert(found.owner.load(.monotonic) == me()); // left by its owner
    assert(found.depth > 0 and held > 0);
    held -= 1;
    found.depth -= 1;
    if (found.depth > 0) return;
    found.owner.store(0, .monotonic);
    if (found.state.swap(0, .release) == 2) {
        _ = linux.futex_3arg(&found.state.raw, .{ .cmd = .WAKE, .private = true }, 1);
    }
}

fn is_held(mutex: ?*c.Mutex) callconv(.c) c_int {
    return @intFromBool(of(mutex).owner.load(.monotonic) == me());
}

fn is_not_held(mutex: ?*c.Mutex) callconv(.c) c_int {
    return @intFromBool(of(mutex).owner.load(.monotonic) != me());
}

test "mutex: recursive within a thread, refused to another" {
    const mutex = alloc(kind_recursive).?;
    defer free(mutex);
    enter(mutex);
    enter(mutex);
    try std.testing.expectEqual(2, held);
    try std.testing.expectEqual(1, is_held(mutex));
    const Other = struct {
        fn try_it(m: ?*c.Mutex, result: *c_int) void {
            result.* = try_enter(m);
        }
    };
    var result: c_int = -1;
    const thread = try std.Thread.spawn(.{}, Other.try_it, .{ mutex, &result });
    thread.join();
    try std.testing.expectEqual(c.busy, result);
    leave(mutex);
    leave(mutex);
    try std.testing.expectEqual(0, held);
    const again = try std.Thread.spawn(.{}, Other.try_it, .{ mutex, &result });
    again.join();
    try std.testing.expectEqual(c.ok, result);
    // That thread holds it now; it never leaves: a fresh one is freed.
    of(mutex).* = .{ .recursive = true, .in_use = true };
}

test "mutex: a lock waited for is given to the waiter" {
    const mutex = alloc(kind_fast).?;
    defer free(mutex);
    enter(mutex);
    const Waiter = struct {
        fn wait(m: ?*c.Mutex, done: *std.atomic.Value(bool)) void {
            enter(m);
            done.store(true, .release);
            leave(m);
        }
    };
    var done: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, Waiter.wait, .{ mutex, &done });
    // Whether the waiter has gone to sleep or not, it gets the lock.
    leave(mutex);
    thread.join();
    try std.testing.expect(done.load(.acquire));
    try std.testing.expectEqual(0, of(mutex).state.load(.monotonic));
}
