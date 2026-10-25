## Plans the migration of an existing database to what `schema.sql` makes,
## from what SQLite says of both: `sqlite_schema`, `pragma_table_xinfo`
## and which key is AUTOINCREMENT (host/database.zig's listings), never SQL
## read as text. Pure: the host runs the plan in one transaction, then
## compares the database's `sqlite_schema` with the pristine one row by
## row, and rolls it all back on any failure. So each CREATE runs exactly
## as schema.sql wrote it.
##
## - A table schema.sql makes and the database lacks is created.
## - A table whose CREATE changed by a byte is rebuilt, SQLite's way:
##   renamed aside, made anew, its rows copied by the columns both have
##   (its AUTOINCREMENT going on from where it was), the old one dropped.
##   Whether the rows fit the new table (a NOT NULL column without a
##   DEFAULT, a narrower type, a CHECK) is SQLite's to say as it copies
##   them.
## - What would lose rows, a table or a column schema.sql no longer makes,
##   is refused unless dropped on purpose (`Drop`); the host copies the
##   database before such a plan (`loses`).
## - Indexes, views and triggers hold no rows: one that changed is dropped
##   and made again, one gone is dropped. What goes with a table or view
##   that is dropped (its indexes, its triggers) is made again after it.
## - Names are SQLite's: ASCII letters in any case are the same name.
Migrate := [].{

	## A row of `sqlite_schema`: `kind` is table, index, view or trigger.
	Object : { kind : Str, name : Str, table : Str, sql : Str }

	## A column of a table; `hidden` 2 and 3 are generated, never copied.
	## `autoincrement`: the key of a table with AUTOINCREMENT.
	TableColumn : { table : Str, name : Str, hidden : I64, autoincrement : Bool }

	## A database's schema, in the order SQLite made it.
	Schema : { objects : List(Object), columns : List(TableColumn) }

	## A table, or a table's column, schema.sql no longer makes, and whose
	## rows may go.
	Drop : [Table(Str), Column(Str, Str)]

	## A statement of the plan, and why it runs.
	Step : { sql : Str, why : Str }

	## Prefixes the name of a table set aside while it is rebuilt.
	aside_prefix : Str
	aside_prefix = "roux_old_"

	## The steps that bring `live` to `pristine`, or why there are none:
	## each refusal a sentence. A new database (nothing in it) needs none:
	## the host makes it from schema.sql.
	plan : Schema, Schema, List(Drop) -> Try(List(Step), List(Str))
	plan = |live, pristine, drops| {
		if live.objects.is_empty() {
			return Ok([])
		}
		refusals = refuse(live, pristine, drops)
		if (refusals.is_empty()) Ok(planned(live, pristine)) else Err(refusals)
	}

	## Whether the plan loses rows or values (dropped on purpose: `plan`
	## refuses any other loss).
	loses : Schema, Schema -> Bool
	loses = |live, pristine| {
		lost = |table| !lost_columns(live, pristine, table.name).is_empty()
		!live.objects.is_empty()
			and (!gone_tables(live, pristine).is_empty() or rebuilt_tables(live, pristine).any(lost))
	}

	refuse : Schema, Schema, List(Drop) -> List(Str)
	refuse = |live, pristine, drops| {
		tables = gone_tables(live, pristine)
			.keep_if(|table| !drops.any(|drop| drops_table(drop, table.name)))
			.map(|table| lost("table `${table.name}`", "rows", "table ${quote_word(table.name)}"))
		columns = rebuilt_tables(live, pristine).join_map(
			|table| {
				dropped = |column| drops.any(|drop| drops_column(drop, table.name, column.name))
				lost_columns(live, pristine, table.name)
					.drop_if(dropped)
					.map(
						|column| {
							what = "column `${table.name}.${column.name}`"
							lost(what, "values", "column ${quote_word(table.name)} ${quote_word(column.name)}")
						},
					)
			},
		)
		kept = drops.keep_if(|drop| still_made(pristine, drop)).map(
			|drop|
				match drop {
					Table(table) =>
						"`-- @drop table ${table}`, but schema.sql makes table `${table}`"
					Column(table, column) =>
						"`-- @drop column ${table} ${column}`, but schema.sql makes `${table}.${column}`"
				},
		)
		aside = pristine.objects.concat(live.objects)
			.keep_if(|object| folded(object.name).starts_with(aside_prefix))
			.map(|object| "`${object.name}`: names starting `${aside_prefix}` are roux's, for rebuilding")
		tables.concat(columns).concat(kept).concat(aside)
	}

	## Why a table or column would be lost, and the line that loses it.
	lost : Str, Str, Str -> Str
	lost = |what, held, drop|
		Str.join_with(
			[
				"${what} is in the database, not in schema.sql: its ${held} would go.",
				" Keep it, or drop it on purpose: `-- @drop ${drop}` in schema.sql.",
				" (A rename is a drop and a new one: the ${held} do not follow.)",
			],
			"",
		)

	planned : Schema, Schema -> List(Step)
	planned = |live, pristine| {
		rebuilt = rebuilt_tables(live, pristine)
		replaced = rebuilt.concat(gone_tables(live, pristine))
		# What holds no rows and changed goes first. What goes with a table
		# or view is not dropped again: a table's indexes, a view's triggers.
		changed = live.objects.keep_if(|object| object.kind != "table" and !identical(pristine, object))
		remade_views = changed.keep_if(|object| object.kind == "view")
		goes_with = |object|
			(object.kind == "index" and has_named(replaced, object.table))
			or (object.kind == "trigger" and has_named(remade_views, object.table))
		unmade = changed.drop_if(goes_with).map(|object| unmake(pristine, object))
		dropped = gone_tables(live, pristine).map(
			|table| { sql: "DROP TABLE ${quote(table.name)}", why: "table `${table.name}`: dropped on purpose" },
		)
		remade = rebuilt.join_map(|table| rebuild(live, pristine, table))
		created = pristine.objects
			.keep_if(|object| object.kind == "table" and !has_table(live, object.name))
			.map(|table| { sql: table.sql, why: "table `${table.name}`: new in schema.sql" })
		# In schema.sql's order: what each refers to is made by then. A view
		# of a rebuilt table needs nothing: the rename aside left it as it was.
		made_again = |object|
			!identical(live, object)
			or (object.kind != "view" and has_named(rebuilt, object.table))
			or (object.kind == "trigger" and has_named(remade_views, object.table))
		derived = pristine.objects
			.keep_if(|object| object.kind != "table" and made_again(object))
			.map(|object| { sql: object.sql, why: "${object.kind} `${object.name}`: as schema.sql makes it" })
		unmade.concat(dropped).concat(remade).concat(created).concat(derived)
	}

	## An index, view or trigger of the database dropped: changed, or gone.
	unmake : Schema, Object -> Step
	unmake = |pristine, object| {
		what = if (has_named(pristine.objects, object.name)) "changed in schema.sql" else "not in schema.sql"
		{
			sql: "DROP ${keyword(object.kind)} ${quote(object.name)}",
			why: "${object.kind} `${object.name}`: ${what}",
		}
	}

	## SQLite's twelve steps, as the host frames them (foreign keys off,
	## the rename aside not rewriting what refers to the table).
	rebuild : Schema, Schema, Object -> List(Step)
	rebuild = |live, pristine, table| {
		old = match find(live.objects, "table", table.name) {
			Ok(found) => found.name
			Err(NotFound) => crash "Migrate.rebuild: a rebuilt table is in the database"
		}
		aside = "${aside_prefix}${old}"
		why = |what| "table `${table.name}`: ${what}"
		pairs = data_columns(live, old).keep_oks(
			|column|
				find_column(data_columns(pristine, table.name), column.name)
					.map_ok(|new| { new: new.name, old: column.name }),
		)
		copied = if (pairs.is_empty()) [] else {
			into = Str.join_with(pairs.map(|pair| quote(pair.new)), ", ")
			from = Str.join_with(pairs.map(|pair| quote(pair.old)), ", ")
			names = Str.join_with(pairs.map(|pair| pair.new), ", ")
			insert = "INSERT INTO ${quote(table.name)} (${into}) SELECT ${from} FROM ${quote(aside)}"
			[{ sql: insert, why: why("its rows, by ${names}") }]
		}
		# The largest key ever handed out, which the copied rows may no
		# longer hold: the rename moved its row of `sqlite_sequence` aside.
		counted = if (autoincremented(live, old) and autoincremented(pristine, table.name)) {
			sequence = Str.join_with(
				[
					"INSERT INTO sqlite_sequence (name, seq) SELECT ${literal(table.name)}, seq",
					" FROM sqlite_sequence WHERE name = ${literal(aside)}",
				],
				"",
			)
			[{ sql: sequence, why: why("AUTOINCREMENT goes on from where it was") }]
		} else []
		[
			{
				sql: "ALTER TABLE ${quote(old)} RENAME TO ${quote(aside)}",
				why: why("aside, to make it anew"),
			},
			{ sql: table.sql, why: why("as schema.sql makes it") },
		]
			.concat(counted)
			.concat(copied)
			.concat([{ sql: "DROP TABLE ${quote(aside)}", why: why("the old one") }])
	}

	## Tables in the database that schema.sql no longer makes.
	gone_tables : Schema, Schema -> List(Object)
	gone_tables = |live, pristine|
		live.objects.keep_if(|object| object.kind == "table" and !has_table(pristine, object.name))

	## Tables of schema.sql the database holds otherwise (a byte differs).
	rebuilt_tables : Schema, Schema -> List(Object)
	rebuilt_tables = |live, pristine|
		pristine.objects.keep_if(
			|object|
				object.kind == "table"
					and (
						match find(live.objects, "table", object.name) {
							Ok(old) => old.sql != object.sql
							Err(NotFound) => Bool.False
						}
					),
		)

	## Columns of the database's `table` that schema.sql's no longer has.
	lost_columns : Schema, Schema, Str -> List(TableColumn)
	lost_columns = |live, pristine, table| {
		kept = data_columns(pristine, table)
		data_columns(live, table).keep_if(|column| find_column(kept, column.name).is_err())
	}

	## The columns that hold values: not generated.
	data_columns : Schema, Str -> List(TableColumn)
	data_columns = |schema, table|
		schema.columns.keep_if(|column| same_name(column.table, table) and column.hidden == 0)

	autoincremented : Schema, Str -> Bool
	autoincremented = |schema, table|
		schema.columns.any(|column| same_name(column.table, table) and column.autoincrement)

	find_column : List(TableColumn), Str -> Try(TableColumn, [NotFound])
	find_column = |columns, name| columns.find_first(|column| same_name(column.name, name))

	find : List(Object), Str, Str -> Try(Object, [NotFound])
	find = |objects, kind, name|
		objects.find_first(|object| object.kind == kind and same_name(object.name, name))

	has_table : Schema, Str -> Bool
	has_table = |schema, name| find(schema.objects, "table", name).is_ok()

	## Of any kind: a view that became a table of its name was changed.
	has_named : List(Object), Str -> Bool
	has_named = |objects, name| objects.any(|object| same_name(object.name, name))

	## The same object, to the byte: nothing to do.
	identical : Schema, Object -> Bool
	identical = |schema, object|
		match find(schema.objects, object.kind, object.name) {
			Ok(other) => other.sql == object.sql and other.name == object.name
			Err(NotFound) => Bool.False
		}

	drops_table : Drop, Str -> Bool
	drops_table = |drop, table|
		match drop {
			Table(name) => same_name(name, table)
			Column(_, _) => Bool.False
		}

	drops_column : Drop, Str, Str -> Bool
	drops_column = |drop, table, column|
		match drop {
			Table(_) => Bool.False
			Column(name, field) => same_name(name, table) and same_name(field, column)
		}

	still_made : Schema, Drop -> Bool
	still_made = |pristine, drop|
		match drop {
			Table(table) => has_table(pristine, table)
			Column(table, column) => find_column(data_columns(pristine, table), column).is_ok()
		}

	## What drops an index, view or trigger: tables are never unmade.
	keyword : Str -> Str
	keyword = |kind|
		match kind {
			"index" => "INDEX"
			"view" => "VIEW"
			"trigger" => "TRIGGER"
			_ => crash "Migrate.keyword: an index, view or trigger"
		}

	## An identifier as SQL writes one: in double quotes, its own doubled.
	quote : Str -> Str
	quote = |name| "\"${name.replace_each("\"", "\"\"")}\""

	## A name as a `-- @drop` line writes it: bare when it is a plain word
	## (letters, digits, `_`, not starting with a digit), quoted otherwise.
	quote_word : Str -> Str
	quote_word = |name| {
		bytes = name.to_utf8()
		letter = |byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or byte == '_'
		word_byte = |byte| letter(byte) or (byte >= '0' and byte <= '9')
		word = match bytes.first() {
			Ok(first) => letter(first) and bytes.all(word_byte)
			Err(ListWasEmpty) => Bool.False
		}
		if (word) name else quote(name)
	}

	## A string as SQL writes one: in single quotes, its own doubled.
	literal : Str -> Str
	literal = |text| "'${text.replace_each("'", "''")}'"

	same_name : Str, Str -> Bool
	same_name = |a, b| folded(a) == folded(b)

	## ASCII letters lowered, as SQLite compares names.
	folded : Str -> Str
	folded = |name| {
		lowered = |byte| if (byte >= 'A' and byte <= 'Z') byte + 32 else byte
		Str.from_utf8_lossy(name.to_utf8().map(lowered))
	}
}

expect Migrate.quote("dish") == "\"dish\""
expect Migrate.quote("say \"hi\"") == "\"say \"\"hi\"\"\""
expect Migrate.literal("it's") == "'it''s'"
expect Migrate.quote_word("dish_2") == "dish_2"
expect Migrate.quote_word("dish of the day") == "\"dish of the day\""
expect Migrate.quote_word("2dish") == "\"2dish\""
expect Migrate.same_name("Dish", "dISH")
expect !Migrate.same_name("dish", "dishes")
expect Migrate.plan({ objects: [], columns: [] }, { objects: [], columns: [] }, []) == Ok([])
