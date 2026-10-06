//! The Roc types a query's parameters and result columns take, and their
//! codes: roux-db writes a statement's codes into `Database.roc`, the host
//! reads them at startup and checks every value against them. One file,
//! so the two cannot disagree.

const std = @import("std");
const assert = std.debug.assert;

pub const Scalar = enum(u8) {
    i64 = 1,
    f64 = 2,
    str = 3,
    bytes = 4,
    /// INTEGER 0 or 1; any other value is refused when read.
    bool = 5,

    /// The SQLite storage class the scalar is stored as.
    pub fn storage(scalar: Scalar) Storage {
        return switch (scalar) {
            .i64, .bool => .integer,
            .f64 => .real,
            .str => .text,
            .bytes => .blob,
        };
    }

    /// As Roc spells it.
    pub fn roc(scalar: Scalar) []const u8 {
        return switch (scalar) {
            .i64 => "I64",
            .f64 => "F64",
            .str => "Str",
            .bytes => "List(U8)",
            .bool => "Bool",
        };
    }
};

/// SQLite's storage classes, as a STRICT table declares them.
pub const Storage = enum { integer, real, text, blob };

pub const Type = struct {
    scalar: Scalar,
    nullable: bool,

    /// The bit in a code that says nullable.
    pub const nullable_bit: u8 = 0x10;

    pub fn code(t: Type) u8 {
        const result = @backingInt(t.scalar) | if (t.nullable) nullable_bit else 0;
        assert(std.meta.eql(from_code(result).?, t));
        return result;
    }

    pub fn from_code(value: u8) ?Type {
        const scalar = std.enums.fromInt(Scalar, value & ~nullable_bit) orelse return null;
        if (value & ~nullable_bit & 0xe0 != 0) return null;
        return .{ .scalar = scalar, .nullable = value & nullable_bit != 0 };
    }

    /// `I64`, `Nullable(Str)`, ...: as an annotation writes it.
    pub fn parse(text: []const u8) ?Type {
        const prefix = "Nullable(";
        if (std.mem.startsWith(u8, text, prefix) and std.mem.endsWith(u8, text, ")")) {
            const inner = text[prefix.len .. text.len - 1];
            const scalar = parse_scalar(inner) orelse return null;
            return .{ .scalar = scalar, .nullable = true };
        }
        const scalar = parse_scalar(text) orelse return null;
        return .{ .scalar = scalar, .nullable = false };
    }

    fn parse_scalar(text: []const u8) ?Scalar {
        inline for (@typeInfo(Scalar).@"enum".field_names) |field_name| {
            const scalar: Scalar = @field(Scalar, field_name);
            if (std.mem.eql(u8, text, scalar.roc())) return scalar;
        }
        return null;
    }
};

/// The storage class of a STRICT table's declared type; null for `ANY`
/// (or anything else), which no Roc type fits.
pub fn storage_from_declared(declared: []const u8) ?Storage {
    const names = [_]struct { []const u8, Storage }{
        .{ "INTEGER", .integer }, .{ "INT", .integer },
        .{ "REAL", .real },       .{ "TEXT", .text },
        .{ "BLOB", .blob },
    };
    for (names) |entry| {
        if (std.ascii.eqlIgnoreCase(declared, entry[0])) return entry[1];
    }
    return null;
}

test "types: every code reads back as its type" {
    inline for (@typeInfo(Scalar).@"enum".field_names) |field_name| {
        for ([_]bool{ false, true }) |nullable| {
            const t: Type = .{ .scalar = @field(Scalar, field_name), .nullable = nullable };
            try std.testing.expectEqual(t, Type.from_code(t.code()).?);
        }
    }
    try std.testing.expectEqual(null, Type.from_code(0));
    try std.testing.expectEqual(null, Type.from_code(6));
    try std.testing.expectEqual(null, Type.from_code(0x41));
}

test "types: annotations parse as Roc spells the types" {
    try std.testing.expectEqual(Type{ .scalar = .i64, .nullable = false }, Type.parse("I64").?);
    const bytes: Type = .{ .scalar = .bytes, .nullable = true };
    try std.testing.expectEqual(bytes, Type.parse("Nullable(List(U8))").?);
    try std.testing.expectEqual(null, Type.parse("i64"));
    try std.testing.expectEqual(null, Type.parse("Nullable(Nullable(I64))"));
    try std.testing.expectEqual(null, Type.parse("U64"));
    try std.testing.expectEqual(null, Type.parse("Nullable(I64"));
}

test "types: a STRICT table's declared types, and ANY refused" {
    try std.testing.expectEqual(Storage.integer, storage_from_declared("INT").?);
    try std.testing.expectEqual(Storage.text, storage_from_declared("text").?);
    try std.testing.expectEqual(null, storage_from_declared("ANY"));
}
