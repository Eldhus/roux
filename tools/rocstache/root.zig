//! rocstache: templates whose Roc side is only a contract, compiled to
//! machine code by Zig (DESIGN.md, Templates). The `rocstache` module, which
//! the `roux` tool builds apps with.

pub const generate = @import("generate.zig");
