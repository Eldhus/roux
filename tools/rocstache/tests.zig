//! The template compiler's test root (`zig build test`). What the host's
//! renderer does with the bytecode is tested through the examples, whose
//! pages are compared.

test {
    _ = @import("parse.zig");
    _ = @import("contract.zig");
    _ = @import("declared.zig");
    _ = @import("layout.zig");
    _ = @import("cache.zig");
    _ = @import("bytecode.zig");
    _ = @import("roc.zig");
    _ = @import("elf.zig");
    _ = @import("generate.zig");
    _ = @import("root.zig");
}
