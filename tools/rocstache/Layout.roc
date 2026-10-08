## roux's glue spec (tools/rocstache/layout.zig): every template contract's
## layout as Roc's compiler chose it, for the host's renderer to read the
## records by. `roc glue` runs it on the throwaway platform roux build
## writes, one hosted function per contract, and it writes `layouts.zon`:
## each hosted function's argument type, and every type's kind and size,
## a list's element, a record's fields with their offsets (64-bit).
app [make_glue] { pf: platform glue }

import pf.Types
import pf.File
import pf.GlueInput
import pf.TypeInfo

make_glue : List(Types) -> Try(List(File), Str)
make_glue = |types_list| {
	input = GlueInput.from_types(types_list)
	contracts = input.hosted_functions.map(
		|f| {
			type_id = List.first(f.arg_type_ids) ?? 0
			"        .{ .name = \"${f.name}\", .type = ${type_id.to_str()} },\n"
		},
	)
	types = input.types.map(type_line)
	content = Str.join_with(
		[
			".{\n    .contracts = .{\n",
			Str.join_with(contracts, ""),
			"    },\n    .types = .{\n",
			Str.join_with(types, ""),
			"    },\n}\n",
		],
		"",
	)
	Ok([{ name: "layouts.zon", content }])
}

type_line : TypeInfo -> Str
type_line = |info| {
	fields = match info.layout.details {
		AbiRecord(record) =>
			record.fields
				.keep_if(|f| !f.is_padding)
				.map(
					|f| ".{ .name = \"${f.name}\", .offset = ${f.offset64.to_str()}, .type = ${f.type_id.to_str()} }",
				)
		_ => []
	}
	"        .{ .kind = .${kind(info)}, .size = ${info.layout.size64.to_str()}, .element = ${element(info).to_str()}, .fields = .{ ${Str.join_with(fields, ", ")} } },\n"
}

kind : TypeInfo -> Str
kind = |info|
	match info.repr {
		RocStr => "str"
		RocBool => "bool"
		RocU8 => "u8"
		RocU16 => "u16"
		RocU32 => "u32"
		RocU64 => "u64"
		RocI8 => "i8"
		RocI16 => "i16"
		RocI32 => "i32"
		RocI64 => "i64"
		RocList(_) => "list"
		RocRecord(_) => "record"
		_ => "other"
	}

element : TypeInfo -> U64
element = |info|
	match info.repr {
		RocList(e) => e
		_ => 0
	}
