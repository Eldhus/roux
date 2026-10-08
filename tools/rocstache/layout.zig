//! Where Roc's compiler lays out each template's contract: what the host's
//! renderer reads the record by (DESIGN.md, Templates). Nothing guesses an
//! offset: roux build writes a throwaway platform with one hosted function
//! per contract, taking it concretely, and runs `roc glue` on it with its
//! own spec (`Layout.roc`), which writes the compiler's layout facts as ZON
//! (`layouts.zon`): every type's kind and size, and each record's fields'
//! offsets. Glue runs only when a contract changed (~0.3 s).

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = Io.Writer;
const contract_ = @import("contract.zig");

/// The glue spec, written beside the throwaway platform.
pub const spec = @embedFile("Layout.roc");

pub const Kind = enum { other, record, list, str, bool, u8, u16, u32, u64, i8, i16, i32, i64 };

pub const Field = struct { name: []const u8, offset: u32, type: u32 };

pub const Type = struct {
    kind: Kind,
    size: u32,
    /// list: the element's type.
    element: u32,
    /// record: its fields, padding left out.
    fields: []const Field,
};

/// A hosted function of the throwaway platform: `Contracts.t3!`, and its
/// argument's type.
pub const Hosted = struct { name: []const u8, type: u32 };

pub const Layouts = struct {
    contracts: []const Hosted,
    types: []const Type,

    pub fn get(layouts: *const Layouts, index: u32) *const Type {
        return &layouts.types[index];
    }

    pub fn field(layouts: *const Layouts, record: u32, name: []const u8) ?Field {
        const type_ = layouts.get(record);
        if (type_.kind != .record) return null;
        for (type_.fields) |f| if (std.mem.eql(u8, f.name, name)) return f;
        return null;
    }

    /// Template `index`'s contract's type, or null when it reads nothing
    /// (glue cannot lay out `{}`, and no read needs it).
    pub fn root(layouts: *const Layouts, index: usize) ?u32 {
        var buffer: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&buffer, "Contracts.t{d}!", .{index}) catch unreachable;
        for (layouts.contracts) |c| if (std.mem.eql(u8, c.name, name)) return c.type;
        return null;
    }

    /// Whether every type's fields and elements are within the table.
    pub fn valid(layouts: *const Layouts) bool {
        const len = layouts.types.len;
        for (layouts.contracts) |c| if (c.type >= len) return false;
        for (layouts.types) |t| {
            if (t.kind == .list and t.element >= len) return false;
            for (t.fields) |f| if (f.type >= len or f.offset >= t.size) return false;
        }
        return true;
    }
};

/// `layouts.zon`, as the spec wrote it.
pub fn parse(gpa: Allocator, source: [:0]const u8) error{ OutOfMemory, Invalid }!Layouts {
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const layouts = std.zon.parse.fromSlice(Layouts, .{
        .gpa = gpa,
        .arena = gpa,
        .source = source,
        .diagnostics = &diagnostics,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return error.Invalid,
    };
    if (!layouts.valid()) return error.Invalid;
    return layouts;
}

pub const Contract = struct {
    /// The template's index among the app's, sorted by name.
    index: u32,
    contract: *const contract_.Contract,

    fn empty(c: Contract) bool {
        const root = c.contract.get(c.contract.root);
        return root.kind == .record and root.first == std.math.maxInt(u16);
    }
};

/// `Contracts.roc`: one hosted function per contract that holds anything,
/// taking it concretely (spelled out: glue lays out each alone).
pub fn write_contracts(contracts: []const Contract, writer: *Writer) Writer.Error!void {
    try writer.writeAll("Contracts := [].{\n");
    for (contracts) |c| {
        if (c.empty()) continue;
        try writer.print("\tt{d}! : ", .{c.index});
        try contract_.write_line(c.contract, c.contract.root, writer);
        try writer.writeAll(" => {}\n");
    }
    try writer.writeAll("}\n");
}

/// The throwaway platform's `main.roc`.
pub fn write_platform(contracts: []const Contract, writer: *Writer) Writer.Error!void {
    try writer.writeAll("platform \"contracts\"\n" ++
        "\trequires {} { main! : () => {} }\n" ++
        "\texposes []\n\tpackages {}\n" ++
        "\tprovides { \"contracts_main\": main_for_host! }\n" ++
        "\thosted {\n");
    for (contracts) |c| {
        if (c.empty()) continue;
        try writer.print("\t\t\"contract_t{d}\": Contracts.t{d}!,\n", .{ c.index, c.index });
    }
    try writer.writeAll("\t}\n" ++
        "\ttargets: { inputs_dir: \"targets/\", x64musl: { inputs: [app] } }\n\n" ++
        "import Contracts\n\nmain_for_host! : () => {}\nmain_for_host! = || main!()\n");
}

test "layout: parses what the spec writes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\.{
        \\    .contracts = .{
        \\        .{ .name = "Contracts.t0!", .type = 1 },
        \\    },
        \\    .types = .{
        \\        .{ .kind = .other, .size = 0, .element = 0, .fields = .{  } },
        \\        .{ .kind = .record, .size = 32, .element = 0, .fields = .{
        \\            .{ .name = "items", .offset = 0, .type = 2 },
        \\            .{ .name = "open", .offset = 24, .type = 4 },
        \\        } },
        \\        .{ .kind = .list, .size = 24, .element = 3, .fields = .{  } },
        \\        .{ .kind = .str, .size = 24, .element = 0, .fields = .{  } },
        \\        .{ .kind = .bool, .size = 1, .element = 0, .fields = .{  } },
        \\    },
        \\}
    ;
    const layouts = try parse(arena.allocator(), source);
    try std.testing.expectEqual(@as(?u32, 1), layouts.root(0));
    try std.testing.expectEqual(@as(?u32, null), layouts.root(1));
    try std.testing.expectEqual(@as(u32, 24), layouts.field(1, "open").?.offset);
    try std.testing.expectEqual(Kind.str, layouts.get(layouts.get(2).element).kind);
    try std.testing.expectError(error.Invalid, parse(arena.allocator(),
        \\.{ .contracts = .{ .{ .name = "Contracts.t0!", .type = 7 } }, .types = .{} }
    ));
}
