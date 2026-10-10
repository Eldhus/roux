//! roux: builds a roux app, and serves it as it is edited.
//!
//!   roux build [--dev] [--output=PATH] [--roc=PATH] APP.roc
//!   roux dev [--port=N] [--static=DIR] [--roc=PATH] APP.roc
//!
//! `build` generates the app's templates (each `templates/Page.rocstache`
//! beside `APP.roc` gets its `templates/Page.roc` contract; their bytecode goes in
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
//! roc is the one tool: the nightly roux's `.roc-version` names, which
//! roux checks before anything. Built here, roux runs it where nightlies
//! are installed side by side; a release (`-Droc=roc`) runs the `roc` on
//! PATH; `--roc` names another (the dragrace installs its own, the same
//! pin). `roux version` says which roux and which roc.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const options = @import("roux_options");
const pipeline = @import("pipeline.zig");
const dev = @import("dev.zig");

const usage =
    \\usage: roux build [--dev] [--output=PATH] [--roc=PATH] APP.roc
    \\       roux dev [--port=N] [--static=DIR] [--roc=PATH] APP.roc
    \\       roux load --port N [--path /] [--connections N] [--threads N] [--seconds N]
    \\                 [--mode requests|events]
    \\       roux version
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
    if (args.len == 2 and std.mem.eql(u8, args[1], "version")) {
        try stderr.print("roux {s}, for roc {s}\n", .{ options.version, options.roc_version });
        return;
    }
    // `roux load …`: roux-load, beside this roux (fourneau's load generator).
    if (args.len >= 2 and std.mem.eql(u8, args[1], "load")) {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const self_len = try Io.Dir.readLinkAbsolute(io, "/proc/self/exe", &buffer);
        const bin = std.fs.path.dirname(buffer[0..self_len]) orelse ".";
        const argv = try arena.alloc([]const u8, args.len - 1);
        argv[0] = try std.fs.path.join(arena, &.{ bin, "roux-load" });
        @memcpy(argv[1..], args[2..]);
        const err = std.process.replace(io, .{ .argv = argv });
        try stderr.print("roux: roux-load could not run: {t}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    }
    if (args.len < 3) return usage_exit(stderr);
    const command = args[1];
    const building = std.mem.eql(u8, command, "build");
    if (!building and !std.mem.eql(u8, command, "dev")) return usage_exit(stderr);
    const flags = parse(args[2 .. args.len - 1], building) orelse return usage_exit(stderr);
    const file = args[args.len - 1];
    if (!std.mem.endsWith(u8, file, ".roc")) return usage_exit(stderr);
    try check_roc(arena, io, flags.roc, stderr);
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

/// The roc roux will run is the nightly roux was made for, or roux says
/// which it needs and stops: another nightly's compiler lays records out
/// and names builtins its own way, and fails late and obscurely.
fn check_roc(arena: std.mem.Allocator, io: Io, roc: []const u8, stderr: *Io.Writer) !void {
    // Roc's installer gives the newest nightly it knows, not this one: the
    // nightly's own page is named too.
    const install =
        "Get it at https://github.com/roc-lang/nightlies/releases/tag/{s}\n" ++
        "(how to install Roc: https://www.roc-lang.org/install), put its `roc` on\n" ++
        "PATH, or name it: --roc=PATH.\n";
    const want = "Roc compiler version " ++ options.roc_version;
    const ran = std.process.run(arena, io, .{
        .argv = &.{ roc, "version" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch {
        try stderr.print(
            "roux {s} needs roc {s}, and `{s}` could not be run.\n" ++ install,
            .{ options.version, options.roc_version, roc, options.roc_version },
        );
        try stderr.flush();
        std.process.exit(1);
    };
    const said = std.mem.trim(u8, ran.stdout, " \n");
    if (std.mem.eql(u8, said, want)) return;
    const found = if (std.mem.startsWith(u8, said, "Roc compiler version "))
        said["Roc compiler version ".len..]
    else
        said;
    try stderr.print(
        "roux {s} needs roc {s}; `{s}` is {s}.\n" ++ install,
        .{ options.version, options.roc_version, roc, found, options.roc_version },
    );
    try stderr.flush();
    std.process.exit(1);
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
