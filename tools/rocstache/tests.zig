//! The template compiler's test root (`zig build test`). The compiler and
//! the host's VM together, against an oracle: host/templates_test.zig.

test {
    _ = @import("parse.zig");
    _ = @import("contract.zig");
    _ = @import("declared.zig");
    _ = @import("layout.zig");
    _ = @import("cache.zig");
    _ = @import("bytecode.zig");
    _ = @import("roc.zig");
    _ = @import("program.zig");
    _ = @import("generate.zig");
    _ = @import("analysis.zig");
    _ = @import("assist.zig");
    _ = @import("lsp.zig");
    _ = @import("root.zig");
}
