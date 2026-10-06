//! SQLite's mutexes, counted: SQLite's own (pthread) implementation,
//! wrapped so each thread knows how many it holds. roux's VFS yields the
//! fiber when it waits on the disk, which is safe only when this thread
//! holds no SQLite mutex: another fiber on the thread could try to take
//! the same one, and the thread would deadlock on itself. The VFS asserts
//! `held == 0` wherever it may yield. An interface file: SQLite's
//! `sqlite3_mutex_methods` is a table of C function pointers.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig");

/// SQLite mutexes this thread holds now.
pub threadlocal var held: u32 = 0;

/// SQLite's default methods, which ours call.
var original: c.MutexMethods = undefined;
var counted: c.MutexMethods = undefined;

/// Installs the counting methods, in sqlite.zig's configuration window:
/// SQLite has been initialized once (which fills in its defaults) and shut
/// down (sqlite3_config is refused while initialized).
pub fn install() error{Sqlite}!void {
    if (c.sqlite3_config(c.config_getmutex, &original) != c.ok) return error.Sqlite;
    assert(original.enter != null and original.leave != null);
    counted = original;
    counted.enter = enter;
    counted.try_enter = try_enter;
    counted.leave = leave;
    if (c.sqlite3_config(c.config_mutex, &counted) != c.ok) return error.Sqlite;
}

fn enter(mutex: ?*c.Mutex) callconv(.c) void {
    original.enter.?(mutex);
    held += 1;
}

fn try_enter(mutex: ?*c.Mutex) callconv(.c) c_int {
    const result = original.try_enter.?(mutex);
    if (result == c.ok) held += 1;
    return result;
}

fn leave(mutex: ?*c.Mutex) callconv(.c) void {
    assert(held > 0); // left once per enter
    held -= 1;
    original.leave.?(mutex);
}
