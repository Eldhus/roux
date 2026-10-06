//! roux's build: the host, for `roc build`, and its checks.
//!
//!   zig build platform     the host as libhost.a, where roc finds it
//!   zig build test         tidy over the host (fourneau's rules)
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
            .imports = &.{.{ .name = "tidy", .module = fourneau.module("tidy") }},
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path(".")); // tidy reads the source tree
    // ...which the build system cannot see: a change to a file the test does
    // not import would otherwise reuse the cached run (as in fourneau).
    run_tests.has_side_effects = true;
    b.step("test", "Run tidy over the host").dependOn(&run_tests.step);

    platform_step(b, fourneau);
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
