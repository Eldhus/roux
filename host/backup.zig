//! `Sqlite.backup!`: the database copied as one moment saw it, into a
//! directory of dated copies, the oldest past `keep` deleted.
//!
//! SQLite's online backup copies from a shard's reader in one read
//! transaction: a snapshot, while the writer goes on committing. The copy
//! is written under a `.partial` name with no journal (a failed copy is
//! deleted, not rolled back), synced, renamed to its dated name, and the
//! directory synced: a copy under its dated name is whole. Names sort as
//! their times (`backup-20261006T235959Z.db`): the oldest come first.
//!
//! Only roux can make the copy: its VFS holds a lock on the database file
//! that keeps other processes out (DESIGN), `sqlite3 .backup` included.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const sqlite = @import("sqlite");
const c = sqlite.c;
const database_module = @import("database.zig");
const Connection = database_module.Connection;
const Report = database_module.Report;

/// Copies kept, at most.
pub const keep_max = 256;
/// Copies (and partial copies) in the directory, at most.
const copies_max = 512;
/// Directory entries looked at, at most.
const entries_max = 4096;
const prefix = "backup-";
const stamp_length = "20261006T235959Z".len;
const suffix = ".db";
const partial_suffix = ".partial";
pub const name_length = prefix.len + stamp_length + suffix.len;
const partial_length = prefix.len + stamp_length + partial_suffix.len;
const path_bytes_max = 1024;
const directory_bytes_max = path_bytes_max - partial_length - 2;
/// The copy's page cache, from SQLite's heap (`database.heap_bytes`).
pub const cache_kib = database_module.backup_cache_kib;

comptime {
    assert(copies_max > keep_max);
    assert(name_length == 26 and partial_length == 31);
}

pub const Options = struct {
    directory: []const u8,
    /// Copies kept, this one included: 1 to `keep_max`.
    keep: u32,
    /// The copy's time, seconds since the epoch (the real clock; a test's).
    now_s: i64,
};

pub const Name = [name_length]u8;

/// One backup at a time, in the whole process.
var running: std.atomic.Value(bool) = .init(false);

/// Copies `source`'s database to `options.directory`; returns the copy's
/// name. `source` is a reader with no statement running.
pub fn backup(
    source: *Connection,
    io: Io,
    options: Options,
    report: *Report,
) error{Failed}!Name {
    assert(source.role == .reader and !source.running);
    if (options.keep == 0 or options.keep > keep_max) {
        return report.fail(.misuse, "backup: keep 1 to {d}, not {d}", .{ keep_max, options.keep });
    }
    if (options.directory.len == 0 or options.directory.len > directory_bytes_max) {
        return report.fail(.misuse, "backup: a directory of 1 to {d} bytes", .{
            directory_bytes_max,
        });
    }
    if (running.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
        return report.fail(.failed, "backup: another is running", .{});
    }
    defer assert(running.swap(false, .release));
    const name = name_at(options.now_s);
    var dir = Io.Dir.cwd().openDir(io, options.directory, .{ .iterate = true }) catch |err|
        return report.fail(.failed, "backup: {s}: {t}", .{ options.directory, err });
    defer dir.close(io);
    try make(source, io, dir, options.directory, &name, report);
    try rotate(io, dir, options.keep, report);
    return name;
}

/// The copy, under its dated name, synced.
fn make(
    source: *Connection,
    io: Io,
    dir: Io.Dir,
    directory: []const u8,
    name: *const Name,
    report: *Report,
) error{Failed}!void {
    if (dir.access(io, name, .{})) |_| {
        return report.fail(.failed, "backup: {s} exists (one a second)", .{name});
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return report.fail(.failed, "backup: {s}: {t}", .{ name, err }),
    }
    const partial = partial_of(name);
    var path_buffer: [path_bytes_max]u8 = undefined;
    const parts = .{ directory, &partial };
    const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/{s}", parts, 0) catch
        unreachable; // directory_bytes_max
    // A partial copy is from a backup that failed or a crash: never whole.
    delete_if_there(io, dir, &partial) catch |err|
        return report.fail(.failed, "backup: {s}: {t}", .{ &partial, err });
    errdefer delete_if_there(io, dir, &partial) catch {};
    try copy(source, path, report);
    const file = dir.openFile(io, &partial, .{}) catch |err|
        return report.fail(.failed, "backup: {s}: {t}", .{ &partial, err });
    defer file.close(io);
    file.sync(io) catch |err| return report.fail(.failed, "backup: sync: {t}", .{err});
    dir.rename(&partial, dir, name, io) catch |err|
        return report.fail(.failed, "backup: rename: {t}", .{err});
    const directory_file: Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    directory_file.sync(io) catch |err|
        return report.fail(.failed, "backup: sync {s}: {t}", .{ directory, err });
}

/// `source`'s pages into a new database at `path`, in one read
/// transaction.
fn copy(source: *Connection, path: [:0]const u8, report: *Report) error{Failed}!void {
    var db: ?*c.Db = null;
    const flags = c.open_readwrite | c.open_create | c.open_nomutex | c.open_exrescode;
    if (c.sqlite3_open_v2(path, &db, flags, null) != c.ok) {
        defer _ = c.sqlite3_close_v2(db);
        return report.fail(.failed, "backup: open {s}: {s}", .{ path, c.sqlite3_errmsg(db) });
    }
    const destination = db.?;
    defer assert(c.sqlite3_close_v2(destination) == c.ok);
    const settings = std.fmt.comptimePrint(
        "PRAGMA journal_mode = OFF; PRAGMA cache_size = -{d}",
        .{cache_kib},
    );
    sqlite.exec(destination, settings) catch
        return report.fail(.failed, "backup: {s}", .{c.sqlite3_errmsg(destination)});
    const handle = c.sqlite3_backup_init(destination, "main", source.db, "main") orelse
        return report.fail(.failed, "backup: {s}", .{c.sqlite3_errmsg(destination)});
    const stepped = c.sqlite3_backup_step(handle, -1);
    const finished = c.sqlite3_backup_finish(handle);
    if (stepped != c.done) {
        return report.fail(.failed, "backup: step: {s}", .{c.sqlite3_errstr(stepped)});
    }
    if (finished != c.ok) {
        return report.fail(.failed, "backup: {s}", .{c.sqlite3_errmsg(destination)});
    }
}

/// Deletes the oldest copies past `keep`, and partial ones.
fn rotate(io: Io, dir: Io.Dir, keep: u32, report: *Report) error{Failed}!void {
    assert(keep >= 1 and keep <= keep_max);
    var copies: [copies_max]Name = undefined;
    var count: u32 = 0;
    var entries = dir.iterate();
    for (0..entries_max + 1) |_| {
        const entry = (entries.next(io) catch |err|
            return report.fail(.failed, "backup: read the directory: {t}", .{err})) orelse break;
        if (entry.kind != .file) continue;
        if (is_partial(entry.name)) {
            dir.deleteFile(io, entry.name) catch |err|
                return report.fail(.failed, "backup: {s}: {t}", .{ entry.name, err });
            continue;
        }
        if (!is_copy(entry.name)) continue;
        if (count == copies_max) {
            return report.fail(.failed, "backup: over {d} copies", .{copies_max});
        }
        @memcpy(&copies[count], entry.name);
        count += 1;
    } else return report.fail(.failed, "backup: over {d} directory entries", .{entries_max});
    assert(count >= 1); // the copy just made
    const sorted = copies[0..count];
    std.mem.sort(Name, sorted, {}, older);
    if (count <= keep) return;
    for (sorted[0 .. count - keep]) |*doomed| {
        dir.deleteFile(io, doomed) catch |err|
            return report.fail(.failed, "backup: {s}: {t}", .{ doomed, err });
    }
}

fn older(_: void, a: Name, b: Name) bool {
    return std.mem.order(u8, &a, &b) == .lt;
}

fn delete_if_there(io: Io, dir: Io.Dir, name: []const u8) Io.Dir.DeleteFileError!void {
    dir.deleteFile(io, name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

/// `backup-YYYYMMDDTHHMMSSZ.db`, UTC.
pub fn name_at(now_s: i64) Name {
    assert(now_s >= 0); // after 1970
    const epoch = std.time.epoch;
    const seconds: epoch.EpochSeconds = .{ .secs = @intCast(now_s) };
    const year_day = seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = seconds.getDaySeconds();
    var name: Name = undefined;
    const format = prefix ++ "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z" ++ suffix;
    const written = std.fmt.bufPrint(&name, format, .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    }) catch unreachable; // a year of four digits
    assert(written.len == name_length);
    return name;
}

fn partial_of(name: *const Name) [partial_length]u8 {
    assert(is_copy(name));
    var partial: [partial_length]u8 = undefined;
    @memcpy(partial[0 .. prefix.len + stamp_length], name[0 .. prefix.len + stamp_length]);
    @memcpy(partial[prefix.len + stamp_length ..], partial_suffix);
    return partial;
}

fn is_copy(name: []const u8) bool {
    return name.len == name_length and is_stamped(name, suffix);
}

fn is_partial(name: []const u8) bool {
    return name.len == partial_length and is_stamped(name, partial_suffix);
}

fn is_stamped(name: []const u8, end: []const u8) bool {
    assert(name.len == prefix.len + stamp_length + end.len);
    if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, end)) return false;
    const stamp = name[prefix.len..][0..stamp_length];
    for (stamp, 0..) |byte, index| {
        const expected: ?u8 = switch (index) {
            8 => 'T',
            15 => 'Z',
            else => null,
        };
        if (expected) |letter| {
            if (byte != letter) return false;
        } else if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

test "backup: names are UTC, sort as their times, and nothing else is one" {
    try std.testing.expectEqualStrings("backup-19700101T000000Z.db", &name_at(0));
    try std.testing.expectEqualStrings("backup-20261006T235959Z.db", &name_at(1_791_331_199));
    try std.testing.expectEqualStrings("backup-20280229T010203Z.db", &name_at(1_835_398_923));
    try std.testing.expect(older({}, name_at(1_791_331_199), name_at(1_791_331_200)));
    try std.testing.expect(is_copy(&name_at(0)));
    try std.testing.expectEqualStrings("backup-19700101T000000Z.partial", &partial_of(&name_at(0)));
    try std.testing.expect(is_partial(&partial_of(&name_at(0))));
    try std.testing.expect(!is_copy("backup-19700101T000000Z.partial"));
    try std.testing.expect(!is_copy("backup-1970010100000000.db"));
    try std.testing.expect(!is_copy("dragrace.db"));
    try std.testing.expect(!is_copy("backup-19700101T00000aZ.db"));
}
