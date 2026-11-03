//! The host's renderer for rocstache templates: one
//! VM for every template of every app. roux build compiles the app's
//! templates to bytecode (tools/rocstache/bytecode.zig), each read a byte
//! offset where Roc's compiler laid the contract's record out (`roc glue`
//! told it), and attaches the bytecode and the static text after the
//! executable roc linked. A template's value (`Menu.template(ctx)`, a tag
//! of the app's `Templates.Template`) is boxed as it is sent and given to
//! `hosted_template_render`; the VM finds the template by the tag and
//! walks its bytecode reading the record in place: no copy of it, no Roc
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
    list,
    record,
    cond,
    unless,
    empty,
    call,
    hole,
    _,
};
const Int = enum(u8) { u8, u16, u32, u64, i8, i16, i32, i64, _ };
/// The most a hole's union holds (bytecode.zig's `hole_bytes_max`).
const hole_bytes_max = 512;

/// The program roux build attached to the executable, read at start-up
/// (`load_attached`): roc links the app as any platform's, and roux adds
/// the templates' program to it as the section `section_name`
/// (tools/rocstache/program.zig's `attachment`). Words: the code's length
/// in words, the text's in bytes, the layouts' identity, the code, then
/// the text, with `slack` bytes after it.
var attached: Data = undefined;
/// Whether the executable has no program: an app without templates, or one
/// whose section a tool removed (`render` says which it was).
var none_attached = false;

pub const section_name = ".roux.templates";

/// An app with no templates: no tag, no code, no text.
const empty_words = [_]u64{ 2, 0, 0, 0, 0 } ++ @as([slack / 8]u64, @splat(0));

/// Reads the program from the executable's section; none is an app without
/// templates. Called once, before `init!`. A program that is malformed
/// stops the app: it was built wrong.
pub fn load_attached() void {
    attached = data_at(&empty_words);
    const words = read_attached("/proc/self/exe") catch |err| switch (err) {
        error.NoneAttached => {
            none_attached = true;
            return;
        },
        error.Unreadable => @panic("the executable could not be read for its templates"),
        error.Malformed => @panic("the templates attached to the executable are malformed"),
        error.OutOfMemory => @panic("out of memory reading the templates"),
    };
    attached = data_at(words.ptr);
}

const AttachedError = error{ NoneAttached, Unreadable, Malformed, OutOfMemory };

/// The program in the section `section_name` of the ELF at `path` (public
/// for templates_test.zig).
pub fn read_attached(path: [*:0]const u8) AttachedError![]u64 {
    const linux = std.os.linux;
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return error.Unreadable;
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    var stat: linux.Statx = undefined;
    const flags: u32 = linux.AT.EMPTY_PATH;
    if (linux.errno(linux.statx(fd, "", flags, .{ .SIZE = true }, &stat)) != .SUCCESS) {
        return error.Unreadable;
    }
    const section = try section_named(fd, stat.size, section_name);
    const length = section.size;
    if (length < 24 + slack or length % 8 != 0) return error.Malformed;
    const words = try std.heap.page_allocator.alloc(u64, @intCast(length / 8));
    errdefer std.heap.page_allocator.free(words);
    try pread_all(fd, std.mem.sliceAsBytes(words), section.offset);
    if (!well_formed(words, length)) return error.Malformed;
    return words;
}

const Section = struct { offset: u64, size: u64 };

/// The section `name` of the ELF in `fd` (`size` bytes), through its
/// section headers: a little-endian ELF64 (ELF's own layout, fixed: the
/// header's fields at their offsets, 64 bytes a section header).
fn section_named(fd: i32, size: u64, name: []const u8) AttachedError!Section {
    const header_size = 64;
    const entry_size = 64;
    const names_size_max = 1 << 20;
    var header: [header_size]u8 = undefined;
    if (size < header_size) return error.Malformed;
    try pread_all(fd, &header, 0);
    if (!std.mem.eql(u8, header[0..4], std.elf.MAGIC)) return error.Malformed;
    if (header[4] != std.elf.ELFCLASS64 or header[5] != std.elf.ELFDATA2LSB) return error.Malformed;
    if (field(u16, &header, 58) != entry_size) return error.Malformed;
    const count = field(u16, &header, 60);
    const names_index = field(u16, &header, 62);
    if (count == 0 or count >= std.elf.SHN_LORESERVE or names_index >= count) {
        return error.Malformed;
    }
    const table_offset = field(u64, &header, 40);
    const table_size = @as(u64, count) * entry_size;
    if (table_offset > size or table_size > size - table_offset) return error.Malformed;
    const allocator = std.heap.page_allocator;
    const table = try allocator.alloc(u8, @intCast(table_size));
    defer allocator.free(table);
    try pread_all(fd, table, table_offset);
    const names_entry = table[@as(usize, names_index) * entry_size ..][0..entry_size];
    const names_at = Section{
        .offset = field(u64, names_entry, 24),
        .size = field(u64, names_entry, 32),
    };
    if (names_at.size > names_size_max) return error.Malformed;
    if (names_at.offset > size or names_at.size > size - names_at.offset) return error.Malformed;
    const names = try allocator.alloc(u8, @intCast(names_at.size));
    defer allocator.free(names);
    try pread_all(fd, names, names_at.offset);
    for (0..count) |index| {
        const entry = table[index * entry_size ..][0..entry_size];
        const name_offset = field(u32, entry, 0);
        if (name_offset >= names.len) continue;
        const end = std.mem.indexOfScalarPos(u8, names, name_offset, 0) orelse continue;
        if (!std.mem.eql(u8, names[name_offset..end], name)) continue;
        const found = Section{ .offset = field(u64, entry, 24), .size = field(u64, entry, 32) };
        if (found.offset > size or found.size > size - found.offset) return error.Malformed;
        return found;
    }
    return error.NoneAttached;
}

fn field(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

/// Whether `length` bytes of `words` hold one program, padded to whole
/// words by up to 7 bytes (tools/rocstache/program.zig).
fn well_formed(words: []const u64, length: usize) bool {
    if (length < 24 + slack or words.len < 3) return false;
    const code_len = words[0];
    const text_len = words[1];
    if (code_len < 2 or code_len > words.len) return false;
    const used = 24 + code_len * 8 + text_len + slack;
    return used <= length and length - used < 8;
}

fn pread_all(fd: i32, buffer: []u8, offset: u64) error{Unreadable}!void {
    const linux = std.os.linux;
    var done: usize = 0;
    while (done < buffer.len) {
        const got = linux.pread(fd, buffer[done..].ptr, buffer.len - done, @intCast(offset + done));
        if (linux.errno(got) != .SUCCESS or got == 0) return error.Unreadable;
        done += got;
    }
}

/// A program: the attached one, one reread, or one a test assembled
/// (templates_test.zig).
pub const Data = struct {
    code: []const u64,
    text: []const u8,
    /// The identity of the layouts the code reads records by
    /// (tools/rocstache/program.zig).
    layouts: u64,
};

/// The program in `words`, laid out as tools/rocstache/program.zig writes it.
fn data_at(words: [*]const u64) Data {
    const code_len: usize = @intCast(words[0]);
    const text_len: usize = @intCast(words[1]);
    const text: [*]const u8 = @ptrCast(words + 3 + code_len);
    return .{
        .code = words[3..][0..code_len],
        .text = text[0..text_len],
        .layouts = words[2],
    };
}

/// Bytes after the text, and after the written page, that block copies
/// may run into.
pub const slack = 32;

/// How a `Str` part's value is written: the top byte of its run
/// (tools/rocstache/bytecode.zig's Mode).
const Mode = enum(u8) { escaped, raw, _ };
const mode_shift = 56;

/// A shard's buffer: a page larger than this is written to the heap.
const scratch_bytes = 256 * 1024;
threadlocal var scratch: ?[]u8 = null;

/// The box a hole's tag is built in, one per thread: Roc returns before the
/// next hole (its `hole` never renders). Not on the stack, where a safe
/// build would fill all of it at every hole.
threadlocal var hole_box: [16 + hole_bytes_max]u8 align(16) = undefined;

/// Scopes open at once in one template: sections nested in the template
/// and in the partials it includes (the compiler's bound).
const scopes_max = 16 * 9 + 1;

/// The app's `Templates.Template` at `template` (a box's payload), made
/// for `layouts`, rendered in one Roc list: which template by the union's
/// discriminant, from its tag's payload, as glue laid the union out (the
/// program's header: bytecode.zig's `Union`). The value is only read.
pub fn render(layouts: u64, template: abi.RocBox, roc_host: *abi.RocHost) Bytes {
    // Only an app with templates renders: its program was removed after
    // roux build (LLVM's `strip --strip-all` drops sections not loaded), or
    // the binary was not made by roux build.
    if (reload_path == null and none_attached) @panic("the executable has no section " ++
        section_name ++ ", the templates' program: a tool removed it after roux build " ++
        "(llvm-strip, llvm-objcopy --strip-all), or roux build did not make this binary");
    if (reload_path == null) return render_union(attached, layouts, template, roc_host);
    const program = acquire();
    defer release();
    return render_union(program.data, layouts, template, roc_host);
}

pub fn render_union(data: Data, layouts: u64, template: abi.RocBox, roc_host: *abi.RocHost) Bytes {
    // A value made for other layouts would be read at another program's
    // offsets: memory the host must never send. roux build writes the
    // app's Templates.roc and this program from one generation, and a
    // reread program keeps the attached layouts, so this is a broken build.
    if (layouts != data.layouts) @panic("a template's value made for other layouts than the " ++
        "templates' program: Templates.roc and the program are from different builds");
    const code = data.code;
    const count: usize = @intCast(code[0]);
    assert(count > 0);
    const union_word = code[1 + 2 * count];
    const offset: usize = @intCast(union_word & 0xffff_ffff);
    const size: usize = @intCast(union_word >> 32);
    const base = @intFromPtr(template);
    const discriminant: u64 = switch (size) {
        0 => 0,
        1 => @as(*const u8, @ptrFromInt(base + offset)).*,
        2 => @as(*const u16, @ptrFromInt(base + offset)).*,
        4 => @as(*const u32, @ptrFromInt(base + offset)).*,
        8 => @as(*const u64, @ptrFromInt(base + offset)).*,
        else => unreachable,
    };
    const tags = code[2 + 2 * count ..][0..count];
    // Roc numbers tags by name, as templates are: the template is usually
    // the discriminant's own index; else found.
    const index: usize = blk: {
        if (discriminant < count and tags[@intCast(discriminant)] >> 32 == discriminant) {
            break :blk @intCast(discriminant);
        }
        for (tags, 0..) |tag, i| if (tag >> 32 == discriminant) break :blk i;
        // A union narrower than glue's (a value built by hand, not by the
        // generated constructor): never read past it.
        @panic("a template's tag the templates' program does not have");
    };
    const payload: usize = @intCast(tags[index] & 0xffff_ffff);
    return render_from(data, index, @ptrFromInt(base + payload), roc_host);
}

pub fn render_from(data: Data, index: u64, context: abi.RocBox, roc_host: *abi.RocHost) Bytes {
    const buffer = scratch orelse blk: {
        const fresh = std.heap.page_allocator.alloc(u8, scratch_bytes) catch
            @panic("out of memory");
        scratch = fresh;
        break :blk fresh;
    };
    var vm: Vm = .{
        .sink = .{ .buffer = buffer, .text = data.text },
        .code = data.code,
        .roc_host = roc_host,
    };
    defer vm.sink.deinit();
    vm.template(index, @intFromPtr(context));
    const sink = &vm.sink;
    const result: Bytes = .allocate(sink.len, roc_host);
    if (sink.len > 0) @memcpy(@constCast(result.allocationItems()), sink.buffer[0..sink.len]);
    return result;
}

// ---- development: the program reread, no restart --------------------------------

// In development the app is also given the program's file
// (`templates.bin`, the one roux build attaches); on a markup edit `roux
// dev` only rewrites it and sends the app SIGUSR1: no attach, no restart,
// the app's state kept. The
// signal bumps `requested`; the next render rereads the file and swaps
// the program in. A render on another shard may still run the old one:
// each thread publishes the program it renders from (a hazard), and the
// swap frees the old program only once no hazard holds it. Renders never
// yield, so that wait is a render's length. In production `reload_path`
// is null and a render pays one comparison.

/// The file roux dev rewrites (`ROUX_DEV_TEMPLATES`); null in production.
var reload_path: ?[:0]const u8 = null;
/// Bumped by SIGUSR1: a new program is in the file. The events streams
/// wait on it too (host.zig), to tell the browser.
pub var requested: std.atomic.Value(u32) = .init(0);
/// The `requested` count the current program answers.
pub var loaded: std.atomic.Value(u32) = .init(0);
var current: std.atomic.Value(?*const Program) = .init(null);
/// Held while a program is read and swapped in (microseconds, development
/// only): a spin.
var swapping: std.atomic.Value(bool) = .init(false);
/// The number of templates the app's Roc was built for: a program with
/// another count needs the restart roux dev gives it.
var templates_count: u64 = 0;

const Program = struct {
    /// Its words, read from the file (empty for the attached program).
    words: []u64,
    data: Data,
};

var attached_program: Program = undefined;

const threads_max = 256;
var hazards: [threads_max]std.atomic.Value(?*const Program) = @splat(.init(null));
var hazards_used: std.atomic.Value(u32) = .init(0);
threadlocal var hazard: ?*std.atomic.Value(?*const Program) = null;

/// Development: renders take their program from `path`, read now. Called
/// once, before the shards start.
pub fn reload_from(path: [:0]const u8) void {
    assert(reload_path == null);
    assert(attached.code.len > 0);
    templates_count = attached.code[0];
    attached_program = .{ .words = &.{}, .data = attached };
    current.store(&attached_program, .seq_cst);
    reload_path = path;
    swap_in(0);
}

/// The SIGUSR1 handler's work: async-signal-safe (an atomic and a futex
/// wake: the events streams' fibers wait on `requested`).
pub fn request_reload() void {
    _ = requested.fetchAdd(1, .release);
    _ = std.os.linux.futex_3arg(
        &requested.raw,
        .{ .cmd = .WAKE, .private = true },
        std.math.maxInt(i32),
    );
}

/// The program this thread renders from, held until `release`.
fn acquire() *const Program {
    const want = requested.load(.acquire);
    if (want != loaded.load(.acquire)) swap_in(want);
    const slot = hazard orelse register();
    while (true) {
        const program = current.load(.seq_cst).?;
        slot.store(program, .seq_cst);
        // Swapped meanwhile: the swap may not have seen this hazard.
        if (current.load(.seq_cst) == program) return program;
    }
}

fn release() void {
    hazard.?.store(null, .release);
}

fn register() *std.atomic.Value(?*const Program) {
    const index = hazards_used.fetchAdd(1, .monotonic);
    if (index >= threads_max) @panic("more threads render than templates.zig allows");
    hazard = &hazards[index];
    return hazard.?;
}

/// Reads the file and swaps it in, unless another thread did already;
/// the old program is freed once no render holds it. A file that cannot
/// be read, or holds another number of templates, is said and skipped:
/// the old program keeps serving.
fn swap_in(want: u32) void {
    while (swapping.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
    defer swapping.store(false, .release);
    // Another thread swapped in this request, or a later one, while this
    // one waited: nothing to do (counters wrap, so compared as a distance).
    const ahead: i32 = @bitCast(loaded.load(.acquire) -% want);
    if (want != 0 and ahead >= 0) return;
    defer loaded.store(want, .release);
    const fresh = read_program(reload_path.?) catch |err| {
        log_reload_failure(err);
        return;
    };
    const old = current.swap(fresh, .seq_cst).?;
    const used = @min(hazards_used.load(.acquire), threads_max);
    for (hazards[0..used]) |*slot| {
        while (slot.load(.seq_cst) == old) std.atomic.spinLoopHint();
    }
    if (old.words.len > 0) {
        std.heap.page_allocator.free(old.words);
        std.heap.page_allocator.destroy(old);
    }
}

const ReadError = error{ Unreadable, Malformed, ContractsChanged, TemplatesChanged, OutOfMemory };

fn read_program(path: [:0]const u8) ReadError!*const Program {
    const linux = std.os.linux;
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return error.Unreadable;
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    var stat: linux.Statx = undefined;
    const flags: u32 = linux.AT.EMPTY_PATH;
    if (linux.errno(linux.statx(fd, "", flags, .{ .SIZE = true }, &stat)) != .SUCCESS) {
        return error.Unreadable;
    }
    const size: usize = @intCast(stat.size);
    if (size < 16 + slack) return error.Malformed;
    const words = try std.heap.page_allocator.alloc(u64, (size + 7) / 8);
    errdefer std.heap.page_allocator.free(words);
    const bytes = std.mem.sliceAsBytes(words);
    var done: usize = 0;
    while (done < size) {
        const got = linux.read(fd, bytes[done..].ptr, size - done);
        if (linux.errno(got) != .SUCCESS or got == 0) return error.Unreadable;
        done += got;
    }
    if (!well_formed(words, size)) return error.Malformed;
    const data = data_at(words.ptr);
    // Made for other layouts (a contract changed, roc not rebuilt yet): its
    // offsets are not this app's records'. Never read by them.
    if (data.layouts != attached_program.data.layouts) return error.ContractsChanged;
    if (data.code[0] != templates_count) return error.TemplatesChanged;
    const program = try std.heap.page_allocator.create(Program);
    program.* = .{ .words = words, .data = data };
    return program;
}

fn log_reload_failure(err: ReadError) void {
    const message = switch (err) {
        error.Unreadable => "roux: the templates' program could not be read; the old one serves\n",
        error.Malformed => "roux: the templates' program is malformed; the old one serves\n",
        error.TemplatesChanged => "roux: templates were added or removed: the old program " ++
            "serves until the restart\n",
        error.ContractsChanged => "roux: the templates' contracts changed: the old program " ++
            "serves until the restart\n",
        error.OutOfMemory => "roux: out of memory rereading the templates; the old one serves\n",
    };
    _ = std.os.linux.write(2, message.ptr, message.len);
}

const Vm = struct {
    sink: Sink,
    code: []const u64,
    /// What releases a Str a hole's Roc allocated.
    roc_host: *abi.RocHost,

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
                    const mode: Mode = @fromBackingInt(@intCast(ref >> mode_shift));
                    // A small Str (most fields) is written inline from its
                    // own 24 bytes, as a hole's is; a big one out of line.
                    if (string.isSmallStr()) {
                        assert(mode == .escaped or mode == .raw);
                        sink.small(string.*, mode == .raw);
                    } else {
                        sink.string(string.asSlice(), mode);
                    }
                    pc += 2;
                },
                .int => {
                    sink.run(code[pc + 1]);
                    sink.number(read_int(at, @fromBackingInt(@intCast(rest))));
                    pc += 2;
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
                .list, .record => pc = vm.section(op, at, rest, pc, scopes, len),
                .call => {
                    vm.template(rest, at);
                    pc += 1;
                },
                .hole => pc = vm.hole(pc, rest, scopes, len),
                .text, _ => unreachable,
            }
        }
    }

    /// A hole of Roc: its tag of the app's `Holes.Hole` built in a box whose
    /// count is Roc's static data (0: never freed, a retain or release of it
    /// a branch), each leaf's value copied in from its scope, not retained:
    /// Roc retains what it takes from a box it does not own. Then the Str
    /// Roc makes of it, written as the run's mode says, and released when
    /// Roc allocated it. Returns the code after it.
    fn hole(vm: *Vm, pc: usize, leaves: usize, scopes: *const [scopes_max]usize, len: usize) usize {
        const code = vm.code;
        assert(pc + 3 + leaves <= code.len);
        const ref = code[pc + 1];
        const meta = code[pc + 2];
        const discriminant: u64 = meta & 0xffff;
        const discriminant_offset: usize = @intCast((meta >> 16) & 0xffff);
        const discriminant_size: usize = @intCast((meta >> 32) & 0xff);
        const size: usize = @intCast((meta >> 40) & 0xffff);
        assert(size <= hole_bytes_max);
        assert(discriminant_offset + discriminant_size <= size or discriminant_size == 0);
        const boxed = &hole_box;
        std.mem.writeInt(u64, boxed[8..16], 0, .little);
        // Not cleared: each field of the tag's payload is a leaf, and the
        // discriminant is written, so every byte Roc reads as a value is
        // this hole's; padding is never read as one.
        const payload = boxed[16..][0..size];
        for (code[pc + 3 ..][0..leaves]) |leaf| {
            const up: usize = @intCast(leaf & 15);
            assert(up < len);
            const from = scopes[len - 1 - up] + @as(usize, @intCast((leaf >> 4) & 0xffffff));
            const bytes: usize = @intCast((leaf >> 28) & 0xffff);
            const into: usize = @intCast((leaf >> 44) & 0xffff);
            assert(into + bytes <= size);
            copy_value(payload[into..][0..bytes], @ptrFromInt(from));
        }
        const tag = payload[discriminant_offset..];
        switch (discriminant_size) {
            0 => {},
            1 => tag[0] = @intCast(discriminant),
            2 => std.mem.writeInt(u16, tag[0..2], @intCast(discriminant), .little),
            4 => std.mem.writeInt(u32, tag[0..4], @intCast(discriminant), .little),
            8 => std.mem.writeInt(u64, tag[0..8], discriminant, .little),
            else => unreachable,
        }
        vm.sink.run(ref);
        const string = abi.roc_hole_for_host(@ptrCast(payload.ptr));
        const mode: Mode = @fromBackingInt(@intCast(ref >> mode_shift));
        assert(mode == .escaped or mode == .raw);
        if (string.isSmallStr()) {
            vm.sink.small(string, mode == .raw);
        } else {
            vm.sink.string(string.asSlice(), mode);
            string.decref(vm.roc_host);
        }
        return pc + 3 + leaves;
    }

    /// A value's bytes: a scalar's, a Str's or a List's sizes as fixed
    /// moves, anything else (a record read whole) by `memcpy`.
    inline fn copy_value(into: []u8, from: [*]const u8) void {
        inline for (.{ 1, 2, 4, 8, 16, 24 }) |size| {
            if (into.len == size) {
                into[0..size].* = from[0..size].*;
                return;
            }
        }
        @memcpy(into, from[0..into.len]);
    }

    /// A section opening a scope: each of a list's elements, or a record.
    /// Returns the code after it.
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
        assert(op == .record);
        const body = pc + 1;
        scopes[len] = at;
        vm.run(body, body + body_len, scopes, len + 1);
        return body + body_len;
    }
};

fn read_bool(at: usize) bool {
    return @as(*const u8, @ptrFromInt(at)).* != 0;
}

const Number = struct { negative: bool, magnitude: u64 };

/// The integer at `at`.
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
            // Inline here whatever else calls it: the fields' path is the hot one.
            .escaped => @call(.always_inline, Sink.escape, .{ sink, bytes }),
            .raw => sink.raw(bytes),
            _ => unreachable,
        }
    }

    /// As Roc's `to_str` prints it: a `-` if negative, then the digits.
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
    /// A small Str (its bytes within its own 24), written from those: whole
    /// when raw, or when its first 16 hold it all with nothing to escape;
    /// else escaped. A small Str owns no allocation: nothing to release.
    inline fn small(sink: *Sink, value: abi.RocStr, raw_: bool) void {
        const bytes: [24]u8 = std.mem.asBytes(&value).*;
        const length: usize = bytes[23] & 0x7f;
        assert(length <= 23);
        if (raw_) {
            sink.reserve(24);
            sink.buffer[sink.len..][0..24].* = bytes;
            sink.len += length;
            return;
        }
        if (length <= 16) {
            const chunk = bytes[0..16].*;
            if (specials(chunk) & live(length) == 0) {
                sink.reserve(16);
                sink.buffer[sink.len..][0..16].* = chunk;
                sink.len += length;
                return;
            }
        }
        // Rare: out of line, so `escape` stays inline where `string` calls it.
        @call(.never_inline, Sink.escape, .{ sink, bytes[0..length] });
    }

    inline fn copy_short(sink: *Sink, bytes_: []const u8) void {
        for (bytes_, sink.buffer[sink.len..][0..bytes_.len]) |b, *d| d.* = b;
        sink.len += bytes_.len;
    }

    inline fn raw_unreserved(sink: *Sink, bytes_: []const u8) void {
        @memcpy(sink.buffer[sink.len..][0..bytes_.len], bytes_);
        sink.len += bytes_.len;
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
