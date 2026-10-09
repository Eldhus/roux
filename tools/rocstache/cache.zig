//! What a long-lived caller (`roux dev`) keeps between generations, so a
//! markup edit redoes only what it changed (generate.zig):
//!
//! - each template's source and parse tree, while its source is the same;
//! - its contract, while its key is: its source, the sources of the
//!   partials it inlines, the contracts of those it calls;
//! - its module's identity, so an unchanged `Page.roc` is not even written
//!   into memory;
//! - its compiled chunk, while its key is: the sources it compiles from
//!   (its own, the partials it inlines), the layouts, the templates' names
//!   (a call is an index) and its root's type;
//! - the contracts' layouts, parsed, while glue's inputs are unchanged;
//! - the hash of what each output file was last written with, so an
//!   unchanged one is neither read back nor written. roux dev is the only
//!   writer of its build directory and of the generated modules.
//!
//! What a generation replaces is freed after it succeeds; a generation that
//! fails forgets every template (`forget`), and the next one starts afresh.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");
const contract_ = @import("contract.zig");
const bytecode = @import("bytecode.zig");
const layout = @import("layout.zig");

pub const Cache = struct {
    gpa: Allocator,
    /// The layouts' memory, reset when they are parsed again.
    arena: std.heap.ArenaAllocator,
    layouts: ?layout.Layouts = null,
    written: std.StringHashMapUnmanaged(u64) = .empty,
    /// Each template as last generated, by name (the key is its source's
    /// memory's `name`).
    templates: std.StringHashMapUnmanaged(Kept) = .empty,
    /// What this generation replaced: freed when it succeeds.
    retired: std.ArrayList(Retired) = .empty,
    /// The templates' names from the last listing of the app's directory,
    /// for a generation told which files changed (`changed`).
    names: std.ArrayList([]const u8) = .empty,

    pub fn init(gpa: Allocator) Cache {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(cache: *Cache) void {
        cache.forget();
        cache.names.deinit(cache.gpa);
        cache.templates.deinit(cache.gpa);
        cache.retired.deinit(cache.gpa);
        var keys = cache.written.keyIterator();
        while (keys.next()) |key| cache.gpa.free(key.*);
        cache.written.deinit(cache.gpa);
        cache.arena.deinit();
        cache.* = undefined;
    }

    /// The template kept under `name`, made if new (`source` empty: it
    /// matches no file's hash but an empty file's, which then parses).
    pub fn kept(cache: *Cache, name: []const u8) Allocator.Error!*Kept {
        const entry = try cache.templates.getOrPut(cache.gpa, name);
        if (!entry.found_existing) {
            const owned = try cache.gpa.dupe(u8, name);
            entry.key_ptr.* = owned;
            entry.value_ptr.* = .{ .name = owned };
        }
        return entry.value_ptr;
    }

    /// Something a generation replaced, freed once it succeeds.
    pub fn retire(cache: *Cache, retired: Retired) Allocator.Error!void {
        try cache.retired.append(cache.gpa, retired);
    }

    /// After a generation succeeded: what it replaced goes, and every
    /// template not seen in it (`seen` false).
    pub fn settle(cache: *Cache) Allocator.Error!void {
        var gone: std.ArrayList([]const u8) = .empty;
        defer gone.deinit(cache.gpa);
        var it = cache.templates.valueIterator();
        while (it.next()) |k| {
            if (!k.seen) try gone.append(cache.gpa, k.name);
            k.seen = false;
        }
        for (gone.items) |name| {
            const removed = cache.templates.fetchRemove(name).?;
            cache.free_kept(removed.value);
        }
        for (cache.retired.items) |r| cache.free_retired(r);
        cache.retired.clearRetainingCapacity();
    }

    /// After a generation failed: every template forgotten (what was
    /// replaced too), so nothing kept can point at what was freed.
    pub fn forget(cache: *Cache) void {
        for (cache.retired.items) |r| cache.free_retired(r);
        cache.retired.clearRetainingCapacity();
        var it = cache.templates.valueIterator();
        while (it.next()) |k| cache.free_kept(k.*);
        cache.templates.clearRetainingCapacity();
        cache.forget_names();
    }

    fn forget_names(cache: *Cache) void {
        for (cache.names.items) |name| cache.gpa.free(name);
        cache.names.clearRetainingCapacity();
    }

    /// The names of a listing, kept (in sorted order).
    pub fn keep_names(cache: *Cache, names: []const []const u8) Allocator.Error!void {
        cache.forget_names();
        for (names) |name| try cache.names.append(cache.gpa, try cache.gpa.dupe(u8, name));
    }

    fn free_kept(cache: *Cache, k: Kept) void {
        if (k.source.len > 0) cache.gpa.free(k.source);
        if (k.tree) |tree| destroy_unfilled(cache.gpa, tree);
        if (k.contract) |c| destroy_unfilled(cache.gpa, c);
        if (k.chunk) |chunk| free_chunk(cache.gpa, chunk);
        cache.gpa.free(k.name);
    }

    fn free_retired(cache: *Cache, r: Retired) void {
        switch (r) {
            .source => |s| cache.gpa.free(s),
            .tree => |t| destroy_unfilled(cache.gpa, t),
            .contract => |c| destroy_unfilled(cache.gpa, c),
            .chunk => |c| free_chunk(cache.gpa, c),
        }
    }
};

/// A template as last generated.
pub const Kept = struct {
    name: []const u8,
    source: []const u8 = "",
    source_hash: u64 = 0,
    tree: ?*parse.Tree = null,
    contract: ?*contract_.Contract = null,
    contract_key: u64 = 0,
    module_key: u64 = 0,
    chunk: ?bytecode.Chunk = null,
    chunk_key: u64 = 0,
    /// Read in this generation (a template not seen was deleted).
    seen: bool = false,
};

pub const Retired = union(enum) {
    source: []const u8,
    tree: *parse.Tree,
    contract: *contract_.Contract,
    chunk: bytecode.Chunk,
};

fn free_chunk(gpa: Allocator, chunk: bytecode.Chunk) void {
    gpa.free(chunk.code);
    gpa.free(chunk.text);
    gpa.free(chunk.runs);
}

/// A large struct (a tree, a contract: hundreds of KB of bounded arrays)
/// without a safe build's fill of `undefined` (`create`'s): its user resets
/// the header and writes each element before reading it.
pub fn create_unfilled(gpa: Allocator, comptime T: type) Allocator.Error!*T {
    const bytes = gpa.rawAlloc(@sizeOf(T), .of(T), @returnAddress()) orelse
        return error.OutOfMemory;
    return @ptrCast(@alignCast(bytes));
}

/// Frees what `create_unfilled` made, without the fill `destroy` does.
pub fn destroy_unfilled(gpa: Allocator, pointer: anytype) void {
    const T = @typeInfo(@TypeOf(pointer)).pointer.child;
    const bytes: [*]u8 = @ptrCast(@constCast(pointer));
    gpa.rawFree(bytes[0..@sizeOf(T)], .of(T), @returnAddress());
}

test "cache: kept, retired, settled, forgotten" {
    const gpa = std.testing.allocator;
    var cache: Cache = .init(gpa);
    defer cache.deinit();
    const page = try cache.kept("Page");
    page.source = try gpa.dupe(u8, "<p>{{ x }}</p>");
    page.tree = try create_unfilled(gpa, parse.Tree);
    page.seen = true;
    _ = try cache.kept("Gone");
    try cache.retire(.{ .source = try gpa.dupe(u8, "old") });
    try cache.settle();
    try std.testing.expect(cache.templates.get("Page") != null);
    try std.testing.expect(cache.templates.get("Gone") == null);
    try std.testing.expectEqual(@as(usize, 0), cache.retired.items.len);
    cache.forget();
    try std.testing.expectEqual(@as(u32, 0), cache.templates.count());
}
