const vm = @import("vm.zig");

pub const Parser = @import("Parser.zig");
pub const VM = vm.VM;

test {
    _ = Parser;
    _ = vm;
    _ = @import("example.zig");
}
