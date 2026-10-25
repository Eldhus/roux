//! roux's test root (`zig build test`): every file's own tests.

test {
    _ = @import("dev.zig");
    _ = @import("main.zig");
    _ = @import("pipeline.zig");
}
