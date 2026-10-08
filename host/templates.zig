//! The host's renderer for rocstache templates (DESIGN.md, Templates): one
//! VM for every template of every app. roux build compiles the app's
//! templates to bytecode (tools/rocstache/bytecode.zig), each read a byte
//! offset where Roc's compiler laid the contract's record out (`roc glue`
//! told it), and links the bytecode and the static text in. A page's
//! `render!` boxes its record and calls `hosted_template_render`; the VM
//! walks the bytecode reading the record in place: no copy of it, no Roc
//! value made per part.
//!
//! The writing is the hot path: one pass into a buffer of the shard's (no
//! measuring pass), static runs and short strings copied as whole 16- or
//! 32-byte blocks (the source and the buffer have room past their ends),
//! a string of at most 16 bytes looked at once, through one load that
//! cannot cross a page. Then one allocation of the page's exact size.

const std = @import("std");
const assert = std.debug.assert;
const abi = @import("roc_platform_abi.zig");

pub const Bytes = abi.RocListWith(u8, false);
/// A list as Roc lays it out, whatever its elements (only their address
/// and count are read).
const List = abi.RocListWith(u8, false);

/// The bytecode's ops and integer types (tools/rocstache/bytecode.zig).
const Op = enum(u4) {
    text,
    str,
    int,
    len,
    plural,
    list,
    record,
    when,
    cond,
    unless,
    empty,
    call,
    _,
};
const Int = enum(u8) { u8, u16, u32, u64, i8, i16, i32, i64, list, _ };

/// What the app's build linked in: roux build writes the object itself
/// (tools/rocstache/elf.zig), so a markup edit compiles nothing. Words:
/// the code's length in words, the text's in bytes, the code, then the
/// text, with `slack` bytes after it.
extern const rocstache_data: u64;

const Data = struct { code: []const u64, text: []const u8 };

fn data_linked() Data {
    const words: [*]const u64 = @ptrCast(&rocstache_data);
    const code_len: usize = @intCast(words[0]);
    const text_len: usize = @intCast(words[1]);
    const text: [*]const u8 = @ptrCast(words + 2 + code_len);
    return .{ .code = words[2..][0..code_len], .text = text[0..text_len] };
}

/// Bytes after the text, and after the written page, that block copies
/// may run into.
pub const slack = 32;

/// How a `Str` part's value is written: the top byte of its run
/// (tools/rocstache/bytecode.zig's Mode).
const Mode = enum(u8) { escaped, raw, upper, lower, url, upper_raw, lower_raw, _ };
const mode_shift = 56;

/// A shard's buffer: a page larger than this is written to the heap.
const scratch_bytes = 256 * 1024;
threadlocal var scratch: ?[]u8 = null;

/// Scopes open at once in one template: sections nested in the template
/// and in the partials it includes (the compiler's bound).
const scopes_max = 16 * 9 + 1;

/// Template `index` rendered from the record at `context`, in one Roc
/// list. The record is only read.
pub fn render(index: u64, context: abi.RocBox, roc_host: *abi.RocHost) Bytes {
    const data = data_linked();
    const buffer = scratch orelse blk: {
        const fresh = std.heap.page_allocator.alloc(u8, scratch_bytes) catch
            @panic("out of memory");
        scratch = fresh;
        break :blk fresh;
    };
    var vm: Vm = .{ .sink = .{ .buffer = buffer, .text = data.text }, .code = data.code };
    defer vm.sink.deinit();
    vm.template(index, @intFromPtr(context));
    const sink = &vm.sink;
    const result: Bytes = .allocate(sink.len, roc_host);
    if (sink.len > 0) @memcpy(@constCast(result.allocationItems()), sink.buffer[0..sink.len]);
    return result;
}

const Vm = struct {
    sink: Sink,
    code: []const u64,

    /// A template over the record at `base`: from its own scope, as a
    /// call starts a called partial.
    fn template(vm: *Vm, index: u64, base: usize) void {
        assert(index < vm.code[0]);
        const i: usize = @intCast(index);
        var scopes: [scopes_max]usize = undefined;
        scopes[0] = base;
        vm.run(@intCast(vm.code[1 + 2 * i]), @intCast(vm.code[2 + 2 * i]), &scopes, 1);
    }

    /// The code in `[from, to)`, its scopes `scopes[0..len]`.
    fn run(vm: *Vm, from: usize, to: usize, scopes: *[scopes_max]usize, len: usize) void {
        assert(to <= vm.code.len and len <= scopes_max);
        const code = vm.code;
        const sink = &vm.sink;
        var pc = from;
        while (pc < to) {
            const w = code[pc];
            const op: Op = @fromBackingInt(@intCast(@as(u4, @truncate(w))));
            if (op == .text) {
                sink.run(w >> 8);
                pc += 1;
                continue;
            }
            const up: usize = @intCast((w >> 4) & 15);
            assert(up < len);
            const at = scopes[len - 1 - up] + @as(usize, @intCast((w >> 8) & 0xffffff));
            const rest: usize = @intCast(w >> 32);
            switch (op) {
                .str => {
                    const ref = code[pc + 1];
                    sink.run(ref);
                    const string: *const abi.RocStr = @ptrFromInt(at);
                    sink.string(string.asSlice(), @fromBackingInt(@intCast(ref >> mode_shift)));
                    pc += 2;
                },
                .int, .len => {
                    const int: Int = if (op == .len) .list else @fromBackingInt(@intCast(rest));
                    sink.run(code[pc + 1]);
                    sink.number(read_int(at, int));
                    pc += 2;
                },
                .plural => {
                    const n = read_int(at, @fromBackingInt(@intCast(rest)));
                    sink.run(code[pc + 1]);
                    sink.number(n);
                    const one = !n.negative and n.magnitude == 1;
                    sink.run(if (one) code[pc + 2] else code[pc + 3]);
                    pc += 4;
                },
                // A body in the same scope: run inline, or skipped.
                .cond, .unless, .empty => {
                    const enter = switch (op) {
                        .cond => read_bool(at),
                        .unless => !read_bool(at),
                        .empty => @as(*const List, @ptrFromInt(at)).length == 0,
                        else => unreachable,
                    };
                    pc += if (enter) 1 else 1 + rest;
                },
                .list, .record, .when => pc = vm.section(op, at, rest, pc, scopes, len),
                .call => {
                    vm.template(rest, at);
                    pc += 1;
                },
                .text, _ => unreachable,
            }
        }
    }

    /// A section opening a scope: each of a list's elements, a record, a
    /// Bool when true. Returns the code after it.
    fn section(
        vm: *Vm,
        op: Op,
        at: usize,
        body_len: usize,
        pc: usize,
        scopes: *[scopes_max]usize,
        len: usize,
    ) usize {
        assert(len < scopes_max);
        if (op == .list) {
            const list: *const List = @ptrFromInt(at);
            const stride: usize = @intCast(vm.code[pc + 1]);
            const body = pc + 2;
            if (list.length > 0) {
                var element = @intFromPtr(list.elements_ptr.?);
                for (0..list.length) |_| {
                    scopes[len] = element;
                    vm.run(body, body + body_len, scopes, len + 1);
                    element += stride;
                }
            }
            return body + body_len;
        }
        const body = pc + 1;
        if (op == .record or read_bool(at)) {
            scopes[len] = at;
            vm.run(body, body + body_len, scopes, len + 1);
        }
        return body + body_len;
    }
};

fn read_bool(at: usize) bool {
    return @as(*const u8, @ptrFromInt(at)).* != 0;
}

const Number = struct { negative: bool, magnitude: u64 };

/// The integer at `at`, or a list's length.
inline fn read_int(at: usize, int: Int) Number {
    return switch (int) {
        .u8 => unsigned(@as(*const u8, @ptrFromInt(at)).*),
        .u16 => unsigned(@as(*const u16, @ptrFromInt(at)).*),
        .u32 => unsigned(@as(*const u32, @ptrFromInt(at)).*),
        .u64 => unsigned(@as(*const u64, @ptrFromInt(at)).*),
        .i8 => signed(@as(*const i8, @ptrFromInt(at)).*),
        .i16 => signed(@as(*const i16, @ptrFromInt(at)).*),
        .i32 => signed(@as(*const i32, @ptrFromInt(at)).*),
        .i64 => signed(@as(*const i64, @ptrFromInt(at)).*),
        .list => unsigned(@as(*const List, @ptrFromInt(at)).length),
        _ => unreachable,
    };
}

fn unsigned(value: u64) Number {
    return .{ .negative = false, .magnitude = value };
}

fn signed(value: i64) Number {
    return .{ .negative = value < 0, .magnitude = @abs(value) };
}

const Sink = struct {
    buffer: []u8,
    len: usize = 0,
    text: []const u8,
    /// A heap buffer, when the page outgrew the shard's.
    grown: bool = false,

    fn deinit(sink: *Sink) void {
        if (sink.grown) std.heap.smp_allocator.free(sink.buffer);
        sink.* = undefined;
    }

    /// Room for `count` bytes and the slack after them.
    inline fn reserve(sink: *Sink, count: usize) void {
        if (sink.len + count + slack <= sink.buffer.len) return;
        sink.grow(count);
    }

    fn grow(sink: *Sink, count: usize) void {
        @branchHint(.cold);
        const size = @max(sink.buffer.len * 2, sink.len + count + slack);
        const bigger = std.heap.smp_allocator.alloc(u8, size) catch @panic("out of memory");
        @memcpy(bigger[0..sink.len], sink.buffer[0..sink.len]);
        if (sink.grown) std.heap.smp_allocator.free(sink.buffer);
        sink.buffer = bigger;
        sink.grown = true;
    }

    /// A Str, written as its mode says.
    fn string(sink: *Sink, bytes: []const u8, mode: Mode) void {
        switch (mode) {
            .escaped => sink.escape(bytes),
            .raw => sink.raw(bytes),
            .upper => sink.cased(bytes, .upper, true),
            .lower => sink.cased(bytes, .lower, true),
            .upper_raw => sink.cased(bytes, .upper, false),
            .lower_raw => sink.cased(bytes, .lower, false),
            .url => sink.percent(bytes),
            _ => unreachable,
        }
    }

    inline fn number(sink: *Sink, n: Number) void {
        sink.reserve(21);
        if (n.negative) {
            sink.buffer[sink.len] = '-';
            sink.len += 1;
        }
        sink.digits(n.magnitude);
    }

    /// A static run: copied as 32-byte blocks (the text has slack after it).
    inline fn run(sink: *Sink, ref: u64) void {
        const length: usize = @intCast(ref % 65536);
        if (length == 0) return;
        const offset: usize = @intCast((ref % (1 << mode_shift)) / 65536);
        assert(offset + length <= sink.text.len);
        sink.reserve(length);
        var done: usize = 0;
        while (done < length) : (done += 32) {
            sink.buffer[sink.len + done ..][0..32].* = sink.text[offset + done ..].ptr[0..32].*;
        }
        sink.len += length;
    }

    fn raw(sink: *Sink, value: []const u8) void {
        sink.reserve(value.len);
        @memcpy(sink.buffer[sink.len..][0..value.len], value);
        sink.len += value.len;
    }

    /// HTML-escaped. At most 16 bytes: one look, and when clean one
    /// 16-byte copy. Longer: 16 bytes at a time.
    fn escape(sink: *Sink, value: []const u8) void {
        sink.reserve(value.len * 6);
        if (value.len <= 16) {
            const chunk = load16(value);
            var mask = specials(chunk) & live(value.len);
            if (mask == 0) {
                sink.buffer[sink.len..][0..16].* = chunk;
                sink.len += value.len;
                return;
            }
            var start: usize = 0;
            while (mask != 0) : (mask &= mask - 1) {
                const at = @ctz(mask);
                sink.copy_short(value[start..at]);
                sink.buffer[sink.len..][0..8].* = entity8[value[at]];
                sink.len += entity_len[value[at]];
                start = at + 1;
            }
            sink.copy_short(value[start..]);
            return;
        }
        var start: usize = 0;
        var i: usize = 0;
        while (i + 16 <= value.len) {
            const mask = specials(value[i..][0..16].*);
            if (mask == 0) {
                i += 16;
                continue;
            }
            const at = i + @ctz(mask);
            sink.raw_unreserved(value[start..at]);
            sink.buffer[sink.len..][0..8].* = entity8[value[at]];
            sink.len += entity_len[value[at]];
            i = at + 1;
            start = i;
        }
        while (i < value.len) : (i += 1) {
            if (entity_len[value[i]] == 0) continue;
            sink.raw_unreserved(value[start..i]);
            sink.buffer[sink.len..][0..8].* = entity8[value[i]];
            sink.len += entity_len[value[i]];
            start = i + 1;
        }
        sink.raw_unreserved(value[start..]);
    }

    /// Fewer than 16 bytes, room reserved: byte by byte (short runs only).
    inline fn copy_short(sink: *Sink, bytes_: []const u8) void {
        for (bytes_, sink.buffer[sink.len..][0..bytes_.len]) |b, *d| d.* = b;
        sink.len += bytes_.len;
    }

    inline fn raw_unreserved(sink: *Sink, bytes_: []const u8) void {
        @memcpy(sink.buffer[sink.len..][0..bytes_.len], bytes_);
        sink.len += bytes_.len;
    }

    /// Letters changed to `case`, escaped when `escaped` (the entities are
    /// never changed).
    fn cased(
        sink: *Sink,
        value: []const u8,
        comptime case: enum { upper, lower },
        comptime escaped: bool,
    ) void {
        sink.reserve(value.len * 6);
        for (value) |b| {
            if (escaped and entity_len[b] != 0) {
                sink.buffer[sink.len..][0..8].* = entity8[b];
                sink.len += entity_len[b];
            } else {
                sink.buffer[sink.len] = switch (case) {
                    .upper => std.ascii.toUpper(b),
                    .lower => std.ascii.toLower(b),
                };
                sink.len += 1;
            }
        }
    }

    /// Every byte but `A-Z a-z 0-9 - . _ ~` as `%XX` (RFC 3986).
    fn percent(sink: *Sink, value: []const u8) void {
        sink.reserve(value.len * 3);
        const hex = "0123456789ABCDEF";
        for (value) |b| {
            if (std.ascii.isAlphanumeric(b) or b == '-' or b == '.' or b == '_' or b == '~') {
                sink.buffer[sink.len] = b;
                sink.len += 1;
            } else {
                sink.buffer[sink.len..][0..3].* = .{ '%', hex[b >> 4], hex[b & 15] };
                sink.len += 3;
            }
        }
    }

    /// Two digits at a time from a table, straight into place.
    fn digits(sink: *Sink, value: u64) void {
        var count: usize = 1;
        var v = value;
        while (v >= 10) : (v /= 10) count += 1;
        var end = sink.len + count;
        sink.len = end;
        v = value;
        while (v >= 100) : (v /= 100) {
            end -= 2;
            sink.buffer[end..][0..2].* = pairs[(v % 100) * 2 ..][0..2].*;
        }
        if (v >= 10) {
            sink.buffer[end - 2 ..][0..2].* = pairs[v * 2 ..][0..2].*;
        } else {
            sink.buffer[end - 1] = '0' + @as(u8, @intCast(v));
        }
    }
};

const V = @Vector(16, u8);

/// Up to 16 bytes as one vector: a single load when it cannot cross a page
/// (the bytes past the end are never used), else a copy.
inline fn load16(value: []const u8) [16]u8 {
    assert(value.len <= 16);
    if ((@intFromPtr(value.ptr) & 4095) <= 4096 - 16) return value.ptr[0..16].*;
    var copy: [16]u8 = @splat(0);
    @memcpy(copy[0..value.len], value);
    return copy;
}

inline fn specials(chunk: [16]u8) u16 {
    const v: V = chunk;
    const hits = (v == @as(V, @splat('&'))) | (v == @as(V, @splat('<'))) |
        (v == @as(V, @splat('>'))) | (v == @as(V, @splat('"'))) | (v == @as(V, @splat('\'')));
    return @bitCast(hits);
}

inline fn live(len: usize) u16 {
    return if (len >= 16) 0xffff else (@as(u16, 1) << @intCast(len)) - 1;
}

const entity8 = blk: {
    var table: [256][8]u8 = @splat(@splat(0));
    for ([_][2][]const u8{
        .{ "&", "&amp;" },   .{ "<", "&lt;" },  .{ ">", "&gt;" },
        .{ "\"", "&quot;" }, .{ "'", "&#39;" },
    }) |pair| @memcpy(table[pair[0][0]][0..pair[1].len], pair[1]);
    break :blk table;
};

const entity_len = blk: {
    var table: [256]u8 = @splat(0);
    for ("&<>\"'", [_]u8{ 5, 4, 4, 6, 5 }) |c, n| table[c] = n;
    break :blk table;
};

const pairs = blk: {
    var table: [200]u8 = undefined;
    for (0..100) |i| {
        table[i * 2] = '0' + i / 10;
        table[i * 2 + 1] = '0' + i % 10;
    }
    break :blk table;
};

test "templates: escaping, short and long, every byte at every position" {
    const text: [64]u8 = @splat('x');
    var page: [64 * 6 + slack]u8 = undefined;
    for (0..256) |byte| {
        for ([_]usize{ 5, 16, 40 }) |len| {
            for (0..len) |at| {
                var value: [40]u8 = @splat('x');
                value[at] = @intCast(byte);
                var sink: Sink = .{ .buffer = &page, .text = &text };
                sink.escape(value[0..len]);
                const e = entity8[byte][0..entity_len[byte]];
                const expected_len = len + (if (e.len > 0) e.len - 1 else 0);
                try std.testing.expectEqual(expected_len, sink.len);
                if (e.len > 0) try std.testing.expectEqualStrings(e, page[at..][0..e.len]);
            }
        }
    }
}

test "templates: digits" {
    var page: [64]u8 = undefined;
    for ([_]u64{ 0, 7, 10, 99, 100, 120, 18446744073709551615 }) |n| {
        var sink: Sink = .{ .buffer = &page, .text = "" };
        sink.digits(n);
        var expected: [24]u8 = undefined;
        const printed = try std.fmt.bufPrint(&expected, "{d}", .{n});
        try std.testing.expectEqualStrings(printed, page[0..sink.len]);
    }
}
