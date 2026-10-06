//! pad_archive PATH: make an ar archive end on an even byte. Zig 0.17's
//! archiver can leave it odd after an odd-sized member, and lld then
//! refuses it (Zig issue 30572; roc's build carries the same fix). A
//! program, since Zig 0.17's build system runs no custom step code.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const path = args.next() orelse return error.Usage;
    const io = init.io;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);

    const size = (try file.stat(io)).size;
    if (size % 2 == 1) try file.writePositionalAll(io, "\n", size);
}
