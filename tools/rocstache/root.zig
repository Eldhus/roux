//! rocstache: templates compiled to bytecode that the host's renderer
//! runs over the app's records (DESIGN.md, Templates). The `rocstache`
//! module, which the `roux` tool builds apps with.

pub const generate = @import("generate.zig");
/// The compiler's parts, for the host's test of the compiler and the VM
/// together (host/templates_test.zig).
pub const parse = @import("parse.zig");
pub const bytecode = @import("bytecode.zig");
pub const layout = @import("layout.zig");
