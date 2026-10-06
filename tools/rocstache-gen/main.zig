//! rocstache-gen: compile a Mustache template (*.rocstache) into a statically typed Roc module.
//!
//!   rocstache-gen [-o OUT.roc] [-d DEPFILE] [-m Module] [-u] INPUT.rocstache
//!   rocstache-gen lsp        language server over stdio (see lsp.zig)

const std = @import("std");
const lib = @import("rocstache_gen");
const Io = std.Io;
const lsp = @import("lsp.zig");

const usage =
    \\usage: rocstache-gen [options] INPUT.rocstache
    \\
    \\  -o OUT.roc        write the generated module here (default: stdout)
    \\  -m NAME           module/type name (default: OUT's basename without .roc)
    \\  -d DEPFILE        write a Makefile dependency file listing the partials
    \\                    this output depends on
    \\  -u                update only: leave OUT and DEPFILE untouched (same
    \\                    mtime) when their contents would not change
    \\
    \\  rocstache-gen lsp   run the language server (stdio)
    \\
;

const FileLoader = struct {
    io: Io,
    arena: std.mem.Allocator,
    dir: []const u8,
    paths: std.ArrayList([]const u8) = .empty,

    fn load(ctx: *anyopaque, name: []const u8) anyerror!?[]const u8 {
        const self: *FileLoader = @ptrCast(@alignCast(ctx));
        const path = try std.fs.path.join(self.arena, &.{ self.dir, try std.fmt.allocPrint(self.arena, "{s}.rocstache", .{name}) });
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, path, self.arena, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        try self.paths.append(self.arena, path);
        return bytes;
    }
};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "lsp")) {
        return lsp.run(init.gpa, io);
    }
    if (args.len < 2) fatal("{s}", .{usage});

    var input: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var module_name: ?[]const u8 = null;
    var dep_path: ?[]const u8 = null;
    var update_only = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const takes_value = a.len == 2 and a[0] == '-' and std.mem.indexOfScalar(u8, "omd", a[1]) != null;
        if (takes_value) {
            i += 1;
            if (i >= args.len) fatal("missing value for {s}\n{s}", .{ a, usage });
            switch (a[1]) {
                'o' => out_path = args[i],
                'm' => module_name = args[i],
                'd' => dep_path = args[i],
                else => unreachable,
            }
        } else if (std.mem.eql(u8, a, "-u")) {
            update_only = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            fatal("{s}", .{usage});
        } else if (a.len > 0 and a[0] == '-') {
            fatal("unknown option {s}\n{s}", .{ a, usage });
        } else if (input == null) {
            input = a;
        } else fatal("only one input template is allowed\n{s}", .{usage});
    }
    const in_path = input orelse fatal("{s}", .{usage});
    if (!try genTemplate(io, arena, .{
        .in_path = in_path,
        .out_path = out_path,
        .module_name = module_name,
        .dep_path = dep_path,
        .update_only = update_only,
    })) std.process.exit(1);
}

pub const Job = struct {
    in_path: []const u8,
    out_path: ?[]const u8 = null,
    module_name: ?[]const u8 = null,
    dep_path: ?[]const u8 = null,
    update_only: bool = false,
};

/// Generates one template's module (and depfile). A template error is
/// printed as `file:line:col: error: message` and returns false.
pub fn genTemplate(io: Io, arena: std.mem.Allocator, job: Job) !bool {
    const in_path = job.in_path;
    const out_path = job.out_path;
    const module_name = job.module_name;
    const dep_path = job.dep_path;
    const update_only = job.update_only;

    const module = module_name orelse blk: {
        const base = std.fs.path.basename(out_path orelse fatal("-m NAME is required when writing to stdout\n", .{}));
        if (!std.mem.endsWith(u8, base, ".roc")) fatal("output file must end in .roc\n", .{});
        break :blk base[0 .. base.len - 4];
    };
    if (!lib.mustache.isTypeName(module)) fatal("module name `{s}` must be a capitalized Roc type name (e.g. Index)\n", .{module});

    const src = Io.Dir.cwd().readFileAlloc(io, in_path, arena, .unlimited) catch |err| fatal("cannot read {s}: {s}\n", .{ in_path, @errorName(err) });

    var loader = FileLoader{ .io = io, .arena = arena, .dir = std.fs.path.dirname(in_path) orelse "." };
    var diag: lib.mustache.Diagnostic = .{};
    const result = lib.gen.generate(arena, src, .{ .ctx = &loader, .loadFn = FileLoader.load }, .{
        .source_name = std.fs.path.basename(in_path),
        .module_name = module,
    }, &diag) catch |err| switch (err) {
        error.ParseError, error.TypeError => {
            const file = if (diag.file.len != 0) blk: {
                for (loader.paths.items) |p| if (std.mem.endsWith(u8, p, try std.fmt.allocPrint(arena, "{s}.rocstache", .{diag.file}))) break :blk p;
                break :blk diag.file;
            } else in_path;
            const file_src = if (diag.file.len != 0) (try FileLoader.load(@ptrCast(&loader), diag.file)) orelse src else src;
            const lc = diag.lineCol(file_src);
            std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ file, lc.line, lc.col, diag.message });
            return false;
        },
        else => return err,
    };

    if (out_path) |op| {
        try writeOutput(io, arena, op, result.roc, update_only);
    } else {
        var buf: [4096]u8 = undefined;
        var fw: Io.File.Writer = .init(.stdout(), io, &buf);
        try fw.interface.writeAll(result.roc);
        try fw.interface.flush();
    }

    if (dep_path) |dp| {
        // Make-style: `out: prerequisites`, then an empty rule per
        // prerequisite (like gcc -MP) so a deleted partial does not stop Make
        // with "No rule to make target".
        var aw: Io.Writer.Allocating = .init(arena);
        try aw.writer.print("{s}: {s}", .{ out_path orelse "-", in_path });
        for (loader.paths.items) |p| try aw.writer.print(" {s}", .{p});
        try aw.writer.writeAll("\n");
        for (loader.paths.items) |p| try aw.writer.print("{s}:\n", .{p});
        try writeOutput(io, arena, dp, aw.written(), update_only);
    }
    return true;
}

/// Writes `data` to `path` atomically (temp file in the same directory, then
/// rename), so a `roc build --watch` reading the module never sees a
/// truncated file. With `update_only`, an unchanged file is left alone so its
/// mtime does not move.
fn writeOutput(io: Io, arena: std.mem.Allocator, path: []const u8, data: []const u8, update_only: bool) !void {
    if (update_only) {
        if (Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited)) |existing| {
            if (std.mem.eql(u8, existing, data)) return;
        } else |_| {}
    }
    if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    const tmp = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = data });
    Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), path, io) catch |err| {
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return err;
    };
}

test {
    _ = lsp;
}
