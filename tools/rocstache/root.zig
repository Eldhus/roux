//! rocstache: templates compiled to bytecode that the host's renderer
//! runs over the app's records (DESIGN.md, Templates). The `rocstache`
//! module, which the `roux` tool builds apps with.

pub const generate = @import("generate.zig");
