//! The requests a shard has in Roc, by handle. Roc names a request to the
//! host's effects (its body, its stream, its database calls) by the U64 in
//! `Server.Request.body`; an app can build that record itself, so the
//! handle is a slot and a generation, checked, never a pointer the host
//! would follow. A handle that is not a live request of this shard finds
//! nothing, and the effect refuses.
//!
//! One table per shard (requests of one shard run on its thread only):
//! fixed at the shard's start, a slot per handler the server may run at
//! once (`Config.handlers_max`: a connection's, or an HTTP/2 stream's).

const std = @import("std");
const assert = std.debug.assert;

pub fn RequestsType(comptime Request: type) type {
    return struct {
        entries: []Entry,
        /// Free slots, as a stack.
        free: []u32,
        free_count: u32,

        const Requests = @This();

        pub const Entry = struct {
            request: ?*Request = null,
            /// Bumped as the slot is reused, so an old handle finds nothing.
            generation: u32 = 0,
            /// The request holds the database's writer.
            holds_writer: bool = false,
        };

        pub fn init(gpa: std.mem.Allocator, slots: u32) !Requests {
            assert(slots >= 1);
            const entries = try gpa.alloc(Entry, slots);
            @memset(entries, .{});
            const free = try gpa.alloc(u32, slots);
            // Slot 0 is popped first.
            for (free, 0..) |*slot, i| slot.* = slots - 1 - @as(u32, @intCast(i));
            return .{ .entries = entries, .free = free, .free_count = slots };
        }

        /// A handle for `request`, until `end`. Every handler the server
        /// runs has a slot of its own: the table is never full.
        pub fn begin(requests: *Requests, request: *Request) u64 {
            assert(requests.free_count > 0);
            requests.free_count -= 1;
            const slot = requests.free[requests.free_count];
            const entry = &requests.entries[slot];
            assert(entry.request == null);
            assert(!entry.holds_writer);
            // Generation 0 is never handed out: handle 0 finds nothing.
            entry.generation +%= 1;
            if (entry.generation == 0) entry.generation = 1;
            entry.request = request;
            const handle = (@as(u64, entry.generation) << 32) | slot;
            assert(requests.find(handle).? == entry);
            return handle;
        }

        /// The live request `handle` names, or null: a handle from Roc is
        /// input, never trusted.
        pub fn find(requests: *Requests, handle: u64) ?*Entry {
            const slot: u64 = handle & 0xffff_ffff;
            const generation: u32 = @intCast(handle >> 32);
            if (slot >= requests.entries.len or generation == 0) return null;
            const entry = &requests.entries[@intCast(slot)];
            if (entry.generation != generation or entry.request == null) return null;
            return entry;
        }

        pub fn end(requests: *Requests, handle: u64) void {
            const entry = requests.find(handle).?; // ours, from `begin`
            assert(!entry.holds_writer); // given back before the request ends
            entry.request = null;
            const slot: u32 = @intCast(handle & 0xffff_ffff);
            assert(requests.free_count < requests.free.len);
            requests.free[requests.free_count] = slot;
            requests.free_count += 1;
        }
    };
}

test "requests: a handle finds its request until it ends, then nothing" {
    const Requests = RequestsType(u8);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var requests: Requests = try .init(arena_state.allocator(), 2);
    var first: u8 = 1;
    var second: u8 = 2;
    const a = requests.begin(&first);
    const b = requests.begin(&second);
    try std.testing.expectEqual(&first, requests.find(a).?.request.?);
    try std.testing.expectEqual(&second, requests.find(b).?.request.?);
    requests.end(a);
    try std.testing.expectEqual(null, requests.find(a));
    // The slot reused: the old handle still finds nothing.
    const c = requests.begin(&first);
    try std.testing.expect(c != a);
    try std.testing.expectEqual(null, requests.find(a));
    try std.testing.expectEqual(&first, requests.find(c).?.request.?);
}

test "requests: handles an app could make find nothing" {
    const Requests = RequestsType(u8);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var requests: Requests = try .init(arena_state.allocator(), 4);
    var request: u8 = 0;
    const live = requests.begin(&request);
    const made_up = [_]u64{
        0,
        1,
        live & 0xffff_ffff, // the slot, generation 0
        live + (1 << 32), // the next generation
        (live & ~@as(u64, 0xffff_ffff)) | 3, // a free slot
        (1 << 32) | 4, // past the table
        std.math.maxInt(u64),
        @intFromPtr(&request), // a pointer, as handles once were
    };
    for (made_up) |handle| try std.testing.expectEqual(null, requests.find(handle));
}
