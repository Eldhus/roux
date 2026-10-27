//! The templates' program as bytes: what `roux build` attaches after the
//! executable roc linked, and what `roux dev` has a running app reread
//! (`templates.bin`). The host reads it (host/templates.zig). No compiler
//! runs and nothing links, so a markup edit costs only the generation.
//!
//! The program: the code's length in words, the text's in bytes, the
//! layouts' identity (a hash of what glue laid the contracts out from: the
//! host rereads in development only a program made for the layouts it was
//! built with), the code, the text, then `slack` zero bytes (the host
//! copies runs in 32-byte blocks that may run past the text's end), then
//! zeros to a whole word.
//!
//! Attached, it is the executable's section `section_name` (`attachment`):
//! a section, unlike bytes appended past the ELF, survives `strip`, which
//! rewrites the file from its sections. A plain section, not loaded:
//! LLVM's `--strip-all` still removes it, and the host says so.

const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;

pub const slack = 32;

/// The section holding the program (host/templates.zig reads it).
pub const section_name = ".roux.templates";

/// The ELF header's and a section header's size (ELF64).
pub const header_size = 64;
pub const section_header_size = 64;
/// The section names' table the attachment copies: no executable's is near.
pub const names_size_max = 1 << 20;

pub const Program = struct {
    code: []const u64,
    text: []const u8,
    /// The layouts' identity (generate.zig).
    layouts: u64,
};

pub fn write(program: Program, writer: *Writer) Writer.Error!void {
    try int(writer, u64, program.code.len);
    try int(writer, u64, program.text.len);
    try int(writer, u64, program.layouts);
    for (program.code) |w| try int(writer, u64, w);
    try writer.writeAll(program.text);
    try writer.splatByteAll(0, slack + padding(program.text.len));
}

/// Where an executable's section headers are, from its ELF header.
pub const Sections = struct {
    /// The table's offset in the file.
    offset: u64,
    count: u16,
    /// The index of the section holding the names.
    names: u16,
};

/// The section table an ELF header names: a little-endian ELF64 with its
/// section headers counted in the header (not past `SHN_LORESERVE`).
pub fn sections(header: *const [header_size]u8) error{NotElf}!Sections {
    if (!std.mem.eql(u8, header[0..4], std.elf.MAGIC)) return error.NotElf;
    if (header[4] != std.elf.ELFCLASS64) return error.NotElf;
    if (header[5] != std.elf.ELFDATA2LSB) return error.NotElf;
    if (get(u16, header, 58) != section_header_size) return error.NotElf;
    const count = get(u16, header, 60);
    const names = get(u16, header, 62);
    if (count == 0 or count >= std.elf.SHN_LORESERVE) return error.NotElf;
    if (names >= count) return error.NotElf;
    return .{ .offset = get(u64, header, 40), .count = count, .names = names };
}

/// A section's place in the file, from its header in `table`.
pub const Section = struct { name: u32, type: u32, offset: u64, size: u64 };

pub fn section_at(table: []const u8, index: usize) Section {
    assert(table.len % section_header_size == 0);
    assert(index < table.len / section_header_size);
    const entry = table[index * section_header_size ..][0..section_header_size];
    return .{
        .name = get(u32, entry, 0),
        .type = get(u32, entry, 4),
        .offset = get(u64, entry, 24),
        .size = get(u64, entry, 32),
    };
}

/// The name at `offset` in the names' table, or null past its end or with
/// no terminating zero.
pub fn name_at(names: []const u8, offset: u32) ?[]const u8 {
    if (offset >= names.len) return null;
    const end = std.mem.indexOfScalarPos(u8, names, offset, 0) orelse return null;
    return names[offset..end];
}

/// What attaching a program to an executable writes: the executable's
/// bytes stay where they are, `tail` follows them (the program, the names'
/// table again with `section_name` added, the section headers again with
/// the program's added), and `header` replaces its first bytes, naming the
/// new table. The old table and names stay, unreferenced: a few kilobytes.
pub const Attachment = struct {
    header: [header_size]u8,
    tail: []u8,
};

pub const AttachError = error{ NotElf, AlreadyAttached, OutOfMemory };

/// The attachment of `program` to an executable of `file_size` bytes, from
/// its ELF `header`, its section headers (`table`) and its names (`names`,
/// the section `header` says holds them).
pub fn attachment(
    gpa: std.mem.Allocator,
    header: *const [header_size]u8,
    table: []const u8,
    names: []const u8,
    file_size: u64,
    program: []const u8,
) AttachError!Attachment {
    const found = try sections(header);
    if (table.len != @as(usize, found.count) * section_header_size) return error.NotElf;
    if (names.len > names_size_max) return error.NotElf;
    assert(program.len % 8 == 0);
    for (0..found.count) |index| {
        const name = name_at(names, section_at(table, index).name) orelse continue;
        if (std.mem.eql(u8, name, section_name)) return error.AlreadyAttached;
    }
    const names_type = section_at(table, found.names).type;
    if (names_type != std.elf.SHT_STRTAB) return error.NotElf;

    const program_offset = std.mem.alignForward(u64, file_size, 8);
    const names_offset = program_offset + program.len;
    const names_size = names.len + section_name.len + 1;
    const table_offset = std.mem.alignForward(u64, names_offset + names_size, 8);
    const end = table_offset + table.len + section_header_size;
    const tail = try gpa.alloc(u8, @intCast(end - file_size));
    errdefer gpa.free(tail);
    @memset(tail, 0);
    const at = struct {
        fn at(bytes: []u8, from: u64, offset: u64) []u8 {
            return bytes[@intCast(offset - from)..];
        }
    }.at;
    @memcpy(at(tail, file_size, program_offset)[0..program.len], program);
    const names_new = at(tail, file_size, names_offset);
    @memcpy(names_new[0..names.len], names);
    @memcpy(names_new[names.len..][0..section_name.len], section_name);
    const table_new = at(tail, file_size, table_offset);
    @memcpy(table_new[0..table.len], table);
    const names_entry = table_new[@as(usize, found.names) * section_header_size ..];
    put(u64, names_entry, 24, names_offset);
    put(u64, names_entry, 32, names_size);
    const added = table_new[table.len..][0..section_header_size];
    put(u32, added, 0, @intCast(names.len));
    put(u32, added, 4, std.elf.SHT_PROGBITS);
    put(u64, added, 24, program_offset);
    put(u64, added, 32, program.len);
    put(u64, added, 48, 8);

    var header_new = header.*;
    put(u64, &header_new, 40, table_offset);
    put(u16, &header_new, 60, found.count + 1);
    return .{ .header = header_new, .tail = tail };
}

fn get(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

fn put(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}

/// Zeros after the text and the slack, to a whole word.
fn padding(text_len: usize) usize {
    return (8 - (text_len + slack) % 8) % 8;
}

fn int(writer: *Writer, comptime T: type, value: anytype) Writer.Error!void {
    try writer.writeInt(T, @intCast(value), .little);
}

test "program: whole words" {
    var buffer: [256]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    const code = [_]u64{ 2, 0 };
    try write(.{ .code = &code, .text = "abc", .layouts = 7 }, &writer);
    const written = writer.buffered();
    try std.testing.expectEqual(@as(usize, 0), written.len % 8);
    try std.testing.expectEqual(@as(usize, 24 + 16 + 3 + slack + 5), written.len);
}

/// A smallest ELF for the tests: its header, `text` (a section), the
/// names, then three section headers (none, `.text`, `.shstrtab`); `size`
/// bytes long.
pub fn test_elf(gpa: std.mem.Allocator, text: []const u8, size_extra: usize) ![]u8 {
    const names = "\x00.text\x00.shstrtab\x00";
    const text_offset = header_size;
    const names_offset = text_offset + text.len;
    const table_offset = std.mem.alignForward(usize, names_offset + names.len, 8);
    const size = table_offset + 3 * section_header_size + size_extra;
    const bytes = try gpa.alloc(u8, size);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], std.elf.MAGIC);
    bytes[4] = std.elf.ELFCLASS64;
    bytes[5] = std.elf.ELFDATA2LSB;
    put(u64, bytes, 40, table_offset);
    put(u16, bytes, 58, section_header_size);
    put(u16, bytes, 60, 3);
    put(u16, bytes, 62, 2);
    @memcpy(bytes[text_offset..][0..text.len], text);
    @memcpy(bytes[names_offset..][0..names.len], names);
    const table = bytes[table_offset..];
    put(u32, table, 64 + 0, 1);
    put(u32, table, 64 + 4, std.elf.SHT_PROGBITS);
    put(u64, table, 64 + 24, text_offset);
    put(u64, table, 64 + 32, text.len);
    put(u32, table, 128 + 0, 7);
    put(u32, table, 128 + 4, std.elf.SHT_STRTAB);
    put(u64, table, 128 + 24, names_offset);
    put(u64, table, 128 + 32, names.len);
    return bytes;
}

/// `elf` with `program` attached, as roux build writes it.
pub fn test_attached(gpa: std.mem.Allocator, elf: []const u8, program: []const u8) ![]u8 {
    const found = try sections(elf[0..header_size]);
    const table_offset: usize = @intCast(found.offset);
    const table = elf[table_offset..][0 .. @as(usize, found.count) * section_header_size];
    const names_section = section_at(table, found.names);
    const names_offset: usize = @intCast(names_section.offset);
    const names = elf[names_offset..][0..@intCast(names_section.size)];
    const made = try attachment(gpa, elf[0..header_size], table, names, elf.len, program);
    defer gpa.free(made.tail);
    const out = try std.mem.concat(gpa, u8, &.{ elf, made.tail });
    out[0..header_size].* = made.header;
    return out;
}

/// The bytes of the section named `name` in `elf`, or null.
pub fn test_section(elf: []const u8, name: []const u8) !?[]const u8 {
    const found = try sections(elf[0..header_size]);
    const table_offset: usize = @intCast(found.offset);
    const table = elf[table_offset..][0 .. @as(usize, found.count) * section_header_size];
    const names_section = section_at(table, found.names);
    const names_offset: usize = @intCast(names_section.offset);
    const names = elf[names_offset..][0..@intCast(names_section.size)];
    for (0..found.count) |index| {
        const section = section_at(table, index);
        const named = name_at(names, section.name) orelse continue;
        if (!std.mem.eql(u8, named, name)) continue;
        const offset: usize = @intCast(section.offset);
        return elf[offset..][0..@intCast(section.size)];
    }
    return null;
}

test "attachment: the program a section, the executable's own sections kept" {
    const gpa = std.testing.allocator;
    const program = "program!" ++ "program!" ++ "program!" ++ "program!" ++ "program!";
    // An executable of any length: the program still starts on a word.
    for ([_]usize{ 0, 1, 7 }) |extra| {
        const elf = try test_elf(gpa, "code", extra);
        defer gpa.free(elf);
        const attached = try test_attached(gpa, elf, program);
        defer gpa.free(attached);
        try std.testing.expectEqualSlices(u8, elf[header_size..], attached[header_size..elf.len]);
        const got = (try test_section(attached, section_name)).?;
        try std.testing.expectEqualStrings(program, got);
        try std.testing.expectEqual(@as(usize, 0), (@intFromPtr(got.ptr) -
            @intFromPtr(attached.ptr)) % 8);
        try std.testing.expectEqualStrings("code", (try test_section(attached, ".text")).?);
        try std.testing.expectEqual(null, try test_section(elf, section_name));
        // Attached twice is refused: one program to an executable.
        try std.testing.expectError(error.AlreadyAttached, test_attached(gpa, attached, program));
    }
}

test "attachment: not an ELF64 little-endian executable is refused" {
    const gpa = std.testing.allocator;
    const elf = try test_elf(gpa, "code", 0);
    defer gpa.free(elf);
    var header: [header_size]u8 = elf[0..header_size].*;
    try std.testing.expect((try sections(&header)).count == 3);
    header[0] = 'X';
    try std.testing.expectError(error.NotElf, sections(&header));
    header = elf[0..header_size].*;
    header[4] = std.elf.ELFCLASS32;
    try std.testing.expectError(error.NotElf, sections(&header));
    header = elf[0..header_size].*;
    put(u16, &header, 60, 0); // extended numbering: the count elsewhere
    try std.testing.expectError(error.NotElf, sections(&header));
    header = elf[0..header_size].*;
    put(u16, &header, 62, 3); // the names past the table
    try std.testing.expectError(error.NotElf, sections(&header));
    try std.testing.expectEqual(null, name_at("\x00abc", 1)); // no terminating zero
    try std.testing.expectEqual(null, name_at("\x00abc\x00", 6));
    try std.testing.expectEqualStrings("abc", name_at("\x00abc\x00", 1).?);
}
