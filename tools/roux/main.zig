//! roux: builds a roux app, and serves it as it is edited.
//!
//!   roux build [--dev] [--output=PATH] [--roc=PATH] APP.roc
//!   roux dev [--port=N] [--static=DIR] [--roc=PATH] APP.roc
//!
//! `build` generates the app's templates (each `Page.rocstache` beside
//! `APP.roc` gets its `Page.roc` contract; their bytecode goes in
//! `.roux/APP/templates.bin`), roc linking the app's executable while glue
//! lays the contracts out; then attaches the bytecode after it, into `APP`
//! beside `APP.roc`, as `roc build` names it, or into `--output`.
//! `--dev` is roc's `--opt=dev`; without it, `--opt=speed`. The templates'
//! bytecode is the same either way (DESIGN.md, Templates).
//!
//! `dev` builds fast, runs the app, and rebuilds only what each edit needs,
//! the browser reloading itself (dev.zig). `--static` names the app's
//! static files' directory, whose changes restart it.
//!
//! The toolchain is the pinned one, named at roux's build (build.zig): the
//! Zig that built this roux, and the roc nightly roux's `.roc-version`
//! names where it is installed, unless `--roc` names it elsewhere (the
//! dragrace installs its own, the same pin).

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const options = @import("roux_options");
const pipeline = @import("pipeline.zig");
const dev = @import("dev.zig");

const usage =
    \\usage: roux build [--dev] [--output=PATH] [--roc=PATH] APP.roc
    \\       roux dev [--port=N] [--static=DIR] [--roc=PATH] APP.roc
    \\
;

const Flags = struct {
    dev: bool = false,
    output: ?[]const u8 = null,
    roc: []const u8 = options.roc,
    port: ?[]const u8 = null,
    static: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var stderr_buffer: [4096]u8 = undefined;
    // Streaming: stderr redirected to a file (a log) is appended to, never
    // written at offset 0 over what the children wrote.
    var stderr_file: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file.interface;
    defer stderr.flush() catch {};
    if (args.len < 3) return usage_exit(stderr);
    const command = args[1];
    const building = std.mem.eql(u8, command, "build");
    if (!building and !std.mem.eql(u8, command, "dev")) return usage_exit(stderr);
    const flags = parse(args[2 .. args.len - 1], building) orelse return usage_exit(stderr);
    const file = args[args.len - 1];
    if (!std.mem.endsWith(u8, file, ".roc")) return usage_exit(stderr);
    const app: pipeline.App = try .of(arena, file, flags.output, flags.roc);
    const result = if (building)
        pipeline.build(arena, io, app, if (flags.dev) .dev else .release, stderr)
    else
        dev.run(init.gpa, io, .{
            .app = app,
            .port = flags.port,
            .static = flags.static,
        }, init.environ_map);
    result catch |err| switch (err) {
        error.Invalid, error.GlueFailed, error.ChildFailed => {
            stderr.flush() catch {};
            std.process.exit(1);
        },
        else => return err,
    };
}

/// The flags before `APP.roc`; null for one that is not the command's.
fn parse(arguments: []const []const u8, building: bool) ?Flags {
    var flags: Flags = .{};
    for (arguments) |flag| {
        if (std.mem.startsWith(u8, flag, "--roc=")) {
            flags.roc = flag["--roc=".len..];
        } else if (building and std.mem.eql(u8, flag, "--dev")) {
            flags.dev = true;
        } else if (building and std.mem.startsWith(u8, flag, "--output=")) {
            flags.output = flag["--output=".len..];
        } else if (!building and std.mem.startsWith(u8, flag, "--port=")) {
            flags.port = flag["--port=".len..];
        } else if (!building and std.mem.startsWith(u8, flag, "--static=")) {
            flags.static = flag["--static=".len..];
        } else return null;
    }
    return flags;
}

fn usage_exit(stderr: *Io.Writer) !void {
    try stderr.writeAll(usage);
    try stderr.flush();
    std.process.exit(2);
}
