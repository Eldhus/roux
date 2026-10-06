//! roux's build: the host, for `roc build`, and its checks.
//!
//!   zig build platform     the host as libhost.a, where roc finds it
//!   zig build test         tidy over the host (fourneau's rules)
//!   zig build tools        rocstache-gen, the template compiler (tools-test),
//!                          and roux-db, the typed-query generator
//!   zig build examples     the examples' templates and databases, regenerated
//!   zig build sqlite-floor SQLite alone, timed (sqlite/floor.zig)
//!
//! fourneau (../fourneau) is a dependency: the server, our port of
//! `std.Io.Evented` and the style checker come from there.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const fourneau = b.dependency("fourneau", .{});
    // The host is checked by fourneau's tidy, with the same rules
    // (host/tests.zig names the tree).
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("host/tests.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{
                .{ .name = "tidy", .module = fourneau.module("tidy") },
                .{ .name = "sqlite", .module = sqlite_module(b, .{
                    .target = target,
                    .optimize = .debug,
                    .pic = null,
                }) },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path(".")); // tidy reads the source tree
    // ...which the build system cannot see: a change to a file the test does
    // not import would otherwise reuse the cached run (as in fourneau).
    run_tests.has_side_effects = true;
    const test_step = b.step("test", "Run tidy over the host, and SQLite's tests");
    test_step.dependOn(&run_tests.step);
    // SQLite's build, checked: its options, its behaviour, with SQLite's
    // own assertions on (SQLITE_DEBUG). The test root imports the bindings
    // by path (tidy's rule), so the C code is attached to it directly.
    const sqlite_test_module = b.createModule(.{
        .root_source_file = b.path("sqlite/tests.zig"),
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    add_sqlite_c(b, sqlite_test_module);
    const sqlite_tests = b.addTest(.{ .root_module = sqlite_test_module });
    test_step.dependOn(&b.addRunArtifact(sqlite_tests).step);
    // roux-db's tests: fast, and SQLite's assertions on.
    const roux_db_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/roux-db/tests.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "sqlite", .module = sqlite_module(b, .{
                .target = target,
                .optimize = .debug,
                .pic = null,
            }) }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(roux_db_tests).step);

    platform_step(b, fourneau);
    tools_step(b, target);
    floor_step(b, target);
    db_floor_step(b, fourneau);
}

/// `zig build db-floor`: examples/sqlite's workloads on fourneau and the
/// host's database.zig, no Roc (host/floor.zig): what a database request
/// costs without the Roc boundary (experiment 21). Built as the host is:
/// musl, safe.
fn db_floor_step(b: *std.Build, fourneau_package: *std.Build.Dependency) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl });
    const module = b.createModule(.{
        .root_source_file = b.path("host/floor.zig"),
        .target = target,
        .optimize = .safe,
        .link_libc = true,
        .imports = &.{
            .{ .name = "fourneau", .module = fourneau_package.module("fourneau") },
            .{ .name = "zig_io_evented", .module = fourneau_package.module("zig_io_evented") },
            .{ .name = "sqlite", .module = sqlite_module(b, .{
                .target = target,
                .optimize = .safe,
                .pic = null,
            }) },
        },
    });
    // The example's own schema, byte for byte: both open one database file.
    module.addAnonymousImport("floor_schema.sql", .{
        .root_source_file = b.path("examples/sqlite/db/schema.sql"),
    });
    const floor = b.addExecutable(.{ .name = "roux-db-floor", .root_module = module });
    const install = b.addInstallArtifact(floor, .{});
    b.step("db-floor", "Build roux-db-floor, the database workloads without Roc").dependOn(&install.step);
}

/// `zig build sqlite-floor`: SQLite alone, timed (sqlite/floor.zig), in
/// the host's mode, so its numbers are the floor under a roux request.
fn floor_step(b: *std.Build, target: std.Build.ResolvedTarget) void {
    const optimize = b.option(
        std.builtin.Optimize,
        "floor-optimize",
        "sqlite-floor's mode (default safe, as the host)",
    ) orelse .safe;
    const sanitize = b.option(
        std.zig.SanitizeC,
        "floor-sanitize-c",
        "Undefined-behaviour checks in SQLite's C for the floor (default off)",
    ) orelse .off;
    const module = b.createModule(.{
        .root_source_file = b.path("sqlite/floor.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    add_sqlite_c(b, module);
    module.sanitize_c = sanitize;
    const floor = b.addExecutable(.{ .name = "sqlite-floor", .root_module = module });
    const install = b.addInstallArtifact(floor, .{});
    b.step("sqlite-floor", "Build sqlite-floor, SQLite alone, timed").dependOn(&install.step);
}

/// The `sqlite` module: roux's bindings (sqlite/sqlite.zig) with the
/// vendored amalgamation compiled in.
fn sqlite_module(b: *std.Build, options: struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    /// True for the host, which roc links as a position-independent
    /// executable; null for the target's default.
    pic: ?bool,
}) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("sqlite/sqlite.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .pic = options.pic,
        .link_libc = true,
    });
    add_sqlite_c(b, module);
    return module;
}

/// `vendor/sqlite/sqlite3.c` in `module`, with the options of
/// sqlite/options.zig, and SQLite's own assertions in Debug.
fn add_sqlite_c(b: *std.Build, module: *std.Build.Module) void {
    const debug = module.optimize.? == .debug;
    // Explicit, never the mode's default: undefined behaviour in SQLite
    // traps in the tests; elsewhere the floor measures what checking costs.
    module.sanitize_c = if (debug) .trap else .off;
    module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = if (debug) &sqlite_options.flags_debug else &sqlite_options.flags,
    });
}

const sqlite_options = @import("sqlite/options.zig");

/// The examples' templates, each compiled to the `.roc` beside it.
const example_templates = [_][]const u8{
    "examples/templates/Page.rocstache",
};

/// The examples' database directories, each compiled by roux-db.
const example_databases = [_][]const u8{
    "examples/sqlite/db",
};

/// `zig build tools`: rocstache-gen, the template compiler and its language
/// server (zig-out/bin), and `zig build tools-test`, its tests.
fn tools_step(b: *std.Build, target: std.Build.ResolvedTarget) void {
    const optimize = b.option(std.builtin.Optimize, "tools-optimize", "The tools' mode (default safe)") orelse .safe;
    const library = b.createModule(.{
        .root_source_file = b.path("tools/rocstache-gen/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The built-in formatters' signatures come from the platform module that
    // defines them, so the two cannot drift.
    library.addAnonymousImport("builtin_formatters", .{
        .root_source_file = b.path("platform/Rocstache.roc"),
    });
    const generator = b.addExecutable(.{
        .name = "rocstache-gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/rocstache-gen/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "rocstache_gen", .module = library }},
        }),
    });
    const install = b.addInstallArtifact(generator, .{});
    const tools = b.step("tools", "Build rocstache-gen and roux-db");
    tools.dependOn(&install.step);
    const roux_db = b.addExecutable(.{
        .name = "roux-db",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/roux-db/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sqlite", .module = sqlite_module(b, .{
                .target = target,
                .optimize = optimize,
                .pic = null,
            }) }},
        }),
    });
    tools.dependOn(&b.addInstallArtifact(roux_db, .{}).step);
    // Every example's templates, compiled next to them (the generated .roc
    // is committed, so `roc build` needs nothing else; this keeps it current).
    const examples = b.step("examples", "Regenerate the examples' templates and databases");
    for (example_templates) |template| {
        const run = b.addRunArtifact(generator);
        run.setCwd(b.path(std.fs.path.dirname(template).?));
        run.addArgs(&.{ "-u", "-o" });
        run.addArg(b.fmt("{s}.roc", .{std.fs.path.stem(template)}));
        run.addArg(std.fs.path.basename(template));
        examples.dependOn(&run.step);
    }
    for (example_databases) |directory| {
        const run = b.addRunArtifact(roux_db);
        run.addArgs(&.{ "gen", directory });
        // roux-db reads the directory, which the build cannot see.
        run.has_side_effects = true;
        examples.dependOn(&run.step);
    }
    const tests = b.addTest(.{ .root_module = library });
    b.step("tools-test", "Test rocstache-gen").dependOn(&b.addRunArtifact(tests).step);
}

/// `zig build platform`: the roux host as libhost.a for x86_64 Linux musl,
/// where `roc build` finds it (platform/targets/x64musl).
/// Safe (assertions on) unless -Dhost-optimize says otherwise.
fn platform_step(b: *std.Build, fourneau_package: *std.Build.Dependency) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl });
    const optimize = b.option(
        std.builtin.Optimize,
        "host-optimize",
        "The roux host's build mode (default safe)",
    ) orelse .safe;
    // The Roc heap: smp (fast, production) or checked (std.heap.SafeAllocator:
    // double frees, frees of foreign memory and writes after free panic;
    // slower, for testing the host and the app).
    const host_heap = b.option(
        enum { smp, checked },
        "host-heap",
        "The Roc heap: smp (default) or checked (SafeAllocator)",
    ) orelse .smp;
    const host_options = b.addOptions();
    host_options.addOption(bool, "heap_checked", host_heap == .checked);
    // fourneau's exported modules take the importer's target and mode; roc
    // links the app as a position-independent executable, so they are PIC.
    const evented = fourneau_package.module("zig_io_evented");
    evented.pic = true;
    const fourneau = fourneau_package.module("fourneau");
    fourneau.pic = true;
    const host = b.addLibrary(.{
        .name = "host",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("host/host.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
            // Fibers run on threads; without Zig's start code (musl's crt1.o
            // starts the program), musl's pthreads set up thread-local storage.
            .link_libc = true,
            .imports = &.{
                .{ .name = "fourneau", .module = fourneau },
                .{ .name = "zig_io_evented", .module = evented },
                .{ .name = "build_options", .module = host_options.createModule() },
                .{ .name = "sqlite", .module = sqlite_module(b, .{
                    .target = target,
                    .optimize = optimize,
                    .pic = true,
                }) },
            },
        }),
    });
    // Host code may call compiler_rt routines (__zig_probe_stack, ...) that
    // musl does not provide.
    host.bundle_compiler_rt = true;
    const archive = "platform/targets/x64musl/libhost.a";
    const copy = b.addUpdateSourceFiles();
    copy.addCopyFileToSource(host.getEmittedBin(), archive);
    const pad_archive = b.addExecutable(.{
        .name = "pad_archive",
        .root_module = b.createModule(.{
            .root_source_file = b.path("host/pad_archive.zig"),
            .target = b.graph.host,
        }),
    });
    const pad = b.addRunArtifact(pad_archive);
    pad.addArg(archive);
    pad.step.dependOn(&copy.step);
    b.step("platform", "Build the roux host (libhost.a) for roc build").dependOn(&pad.step);
}
