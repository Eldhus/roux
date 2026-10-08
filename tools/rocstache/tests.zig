//! The template compiler's test root (`zig build test`). object.zig is not
//! here: it compiles only in an app's build directory, beside the registry
//! roux build writes, and is tested through the examples.

test {
    _ = @import("parse.zig");
    _ = @import("contract.zig");
    _ = @import("declared.zig");
    _ = @import("roc.zig");
    _ = @import("out.zig");
    _ = @import("render.zig");
    _ = @import("generate.zig");
    _ = @import("root.zig");
}
