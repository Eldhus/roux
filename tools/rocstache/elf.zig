//! The templates' data as an object file, written directly: an x86-64 ELF
//! relocatable with one read-only section and one symbol,
//! `rocstache_data`, which the host reads (host/templates.zig). No
//! compiler runs, so a markup edit costs only the link.
//!
//! The section: the code's length in words, the text's in bytes, the
//! layouts' identity (a hash of what glue laid the contracts out from: the
//! host rereads in development only a program made for the layouts it was
//! built with), the code, the text, then `slack` zero bytes (the host
//! copies runs in 32-byte blocks that may run past the text's end).

const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;

pub const slack = 32;

pub const Program = struct {
    code: []const u64,
    text: []const u8,
    /// The layouts' identity (generate.zig).
    layouts: u64,
};

const header_bytes = 64;
const section_header_bytes = 64;
const symbol_bytes = 24;
const strtab = "\x00rocstache_data\x00";
const shstrtab = "\x00.rodata\x00.symtab\x00.strtab\x00.shstrtab\x00.note.GNU-stack\x00";
const sections = 6; // null, .rodata, .symtab, .strtab, .shstrtab, .note.GNU-stack

/// The section's bytes alone: what `roux dev` hands a running app to
/// reread (`templates.bin`; host/templates.zig).
pub fn write_program(program: Program, writer: *Writer) Writer.Error!void {
    try int(writer, u64, program.code.len);
    try int(writer, u64, program.text.len);
    try int(writer, u64, program.layouts);
    for (program.code) |w| try int(writer, u64, w);
    try writer.writeAll(program.text);
    try writer.splatByteAll(0, slack);
}

pub fn write(program: Program, writer: *Writer) Writer.Error!void {
    const data_bytes = 24 + program.code.len * 8 + program.text.len + slack;
    const data_at = header_bytes;
    const symtab_at = std.mem.alignForward(usize, data_at + data_bytes, 8);
    const strtab_at = symtab_at + 2 * symbol_bytes;
    const shstrtab_at = strtab_at + strtab.len;
    const sections_at = std.mem.alignForward(usize, shstrtab_at + shstrtab.len, 8);

    // The file header.
    try writer.writeAll("\x7fELF\x02\x01\x01"); // 64-bit, little-endian, version 1
    try writer.splatByteAll(0, 9); // SysV, padding
    try int(writer, u16, 1); // ET_REL
    try int(writer, u16, 62); // EM_X86_64
    try int(writer, u32, 1);
    try int(writer, u64, 0); // entry
    try int(writer, u64, 0); // program headers: none
    try int(writer, u64, sections_at);
    try int(writer, u32, 0); // flags
    try int(writer, u16, header_bytes);
    try int(writer, u16, 0);
    try int(writer, u16, 0);
    try int(writer, u16, section_header_bytes);
    try int(writer, u16, sections);
    try int(writer, u16, 4); // .shstrtab

    // .rodata.
    try write_program(program, writer);
    try writer.splatByteAll(0, symtab_at - (data_at + data_bytes));

    // .symtab: the null symbol, then rocstache_data (global, an object).
    try writer.splatByteAll(0, symbol_bytes);
    try int(writer, u32, 1); // its name in .strtab
    try int(writer, u8, (1 << 4) | 1); // STB_GLOBAL, STT_OBJECT
    try int(writer, u8, 0);
    try int(writer, u16, 1); // .rodata
    try int(writer, u64, 0);
    try int(writer, u64, data_bytes);

    try writer.writeAll(strtab);
    try writer.writeAll(shstrtab);
    try writer.splatByteAll(0, sections_at - (shstrtab_at + shstrtab.len));

    // The section headers: name, type, flags, address, offset, size, link,
    // info, alignment, entry size.
    try writer.splatByteAll(0, section_header_bytes);
    try section(writer, 1, 1, 2, data_at, data_bytes, 0, 0, 8, 0); // PROGBITS, ALLOC
    try section(writer, 9, 2, 0, symtab_at, 2 * symbol_bytes, 3, 1, 8, symbol_bytes); // SYMTAB
    try section(writer, 17, 3, 0, strtab_at, strtab.len, 0, 0, 1, 0); // STRTAB
    try section(writer, 25, 3, 0, shstrtab_at, shstrtab.len, 0, 0, 1, 0);
    try section(writer, 35, 1, 0, sections_at, 0, 0, 0, 1, 0); // no executable stack
}

fn section(
    writer: *Writer,
    name: u32,
    type_: u32,
    flags: u64,
    offset: usize,
    size: usize,
    link: u32,
    info: u32,
    alignment: u64,
    entry: u64,
) Writer.Error!void {
    try int(writer, u32, name);
    try int(writer, u32, type_);
    try int(writer, u64, flags);
    try int(writer, u64, 0);
    try int(writer, u64, offset);
    try int(writer, u64, size);
    try int(writer, u32, link);
    try int(writer, u32, info);
    try int(writer, u64, alignment);
    try int(writer, u64, entry);
}

fn int(writer: *Writer, comptime T: type, value: anytype) Writer.Error!void {
    try writer.writeInt(T, @intCast(value), .little);
}

test "elf: the names the section headers point at" {
    try std.testing.expectEqualStrings(".rodata", std.mem.sliceTo(shstrtab[1..], 0));
    try std.testing.expectEqualStrings(".symtab", std.mem.sliceTo(shstrtab[9..], 0));
    try std.testing.expectEqualStrings(".strtab", std.mem.sliceTo(shstrtab[17..], 0));
    try std.testing.expectEqualStrings(".shstrtab", std.mem.sliceTo(shstrtab[25..], 0));
    try std.testing.expectEqualStrings(".note.GNU-stack", std.mem.sliceTo(shstrtab[35..], 0));
    try std.testing.expectEqualStrings("rocstache_data", std.mem.sliceTo(strtab[1..], 0));
}
