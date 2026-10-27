## How `Sqlite.open!` brings a database to what `schema.sql` makes, from
## what SQLite says of both: `sqlite_schema`, `pragma_table_xinfo` and
## which key is AUTOINCREMENT (host/database.zig's listings), never SQL
## read as text. Pure: the host runs it all in one transaction, then
## compares the database's `sqlite_schema` with the pristine one row by
## row, and rolls it all back on any failure.
##
## First the steps of `ledger.sql` the database has not run, in order
## (`pending`): what schema.sql cannot say, a rename, a drop, rows moved.
## Then the plan (`plan`):
##
## - A table schema.sql makes and the database lacks is created.
## - A table whose CREATE changed by a byte is rebuilt, SQLite's way:
##   renamed aside, made anew, its rows copied by the columns both have
##   (its AUTOINCREMENT going on from where it was), the old one dropped.
##   Whether the rows fit the new table (a NOT NULL column without a
##   DEFAULT, a narrower type, a CHECK) is SQLite's to say as it copies
##   them.
## - What would lose rows, a table or a column schema.sql no longer makes,
##   is refused: a step of the ledger renames or drops it.
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

	## A statement of the plan, and why it runs.
	Step : { sql : Str, why : Str }

	## Prefixes the name of a table set aside while it is rebuilt.
	aside_prefix : Str
	aside_prefix = "roux_old_"

	## The steps of `ledger` a database that ran `ran` has not, or why the
	## two disagree: a step that ran is never changed. `ahead`: the
	## database ran steps this ledger lacks (a newer release's).
	pending : List(Str), List(Str) -> Try({ run : List(Str), ahead : Bool }, Str)
	pending = |ran, ledger| first_differing(ran, ledger, 0)

	## From step `index` on (0 the first): the first step the two have and
	## differ in.
	first_differing : List(Str), List(Str), U64 -> Try({ run : List(Str), ahead : Bool }, Str)
	first_differing = |ran, ledger, index|
		match (ran.get(index), ledger.get(index)) {
			(Ok(did), Ok(says)) =>
				if (did == says) first_differing(ran, ledger, index + 1) else Err(edited(index + 1, did, says))
			_ => Ok({ run: ledger.drop_first(ran.len()), ahead: ran.len() > ledger.len() })
		}

	## Why a database will not run a ledger whose step `number` was edited.
	edited : U64, Str, Str -> Str
	edited = |number, ran, now|
		Str.join_with(
			[
				"ledger.sql's step ${number.to_str()} is not what the database ran.",
				" It ran:\n  ${ran}\nledger.sql says:\n  ${now}\n",
				"A step that ran stays as it is: put it back, and add a step after it. (A database",
				" that ran a draft of the step, a dev one: put back the copy made before it, in",
				" `<database>.before-ledger/`.)",
			],
			"",
		)

	## The steps that bring `live` to `pristine`, or why there are none:
	## each refusal a sentence. A new database (nothing in it) needs none:
	## the host makes it from schema.sql. `ahead`: an older executable
	## over a newer database, which it opens only as it is.
	plan : Schema, Schema, Bool -> Try(List(Step), List(Str))
	plan = |live, pristine, ahead| {
		if live.objects.is_empty() {
			return Ok([])
		}
		refusals = refuse(live, pristine)
		if !refusals.is_empty() {
			return Err(if (ahead) [too_new] else refusals)
		}
		steps = planned(live, pristine)
		if (ahead and !steps.is_empty()) Err([too_new]) else Ok(steps)
	}

	too_new : Str
	too_new = Str.join_with(
		[
			"the database ran steps of a ledger.sql newer than this one, and its schema differs:",
			" an older executable over a newer database opens it only as it is.",
		],
		"",
	)

	refuse : Schema, Schema -> List(Str)
	refuse = |live, pristine| {
		made = new_tables(live, pristine)
		tables = gone_tables(live, pristine).map(
			|table| {
				name = sql_name(table.name)
				new = match made { [only] => sql_name(only.name), _ => "<new name>" }
				lost("table `${table.name}`", "rows", "ALTER TABLE ${name} RENAME TO ${new};", "DROP TABLE ${name};")
			},
		)
		columns = rebuilt_tables(live, pristine).join_map(
			|table| {
				gained = new_columns(live, pristine, table.name)
				lost_columns(live, pristine, table.name).map(
					|column| {
						what = "column `${table.name}.${column.name}`"
						alter = "ALTER TABLE ${sql_name(table.name)}"
						name = sql_name(column.name)
						new = match gained { [only] => sql_name(only.name), _ => "<new name>" }
						lost(what, "values", "${alter} RENAME COLUMN ${name} TO ${new};", "${alter} DROP COLUMN ${name};")
					},
				)
			},
		)
		aside = pristine.objects.concat(live.objects)
			.keep_if(|object| folded(object.name).starts_with("roux_"))
			.map(|object| "`${object.name}`: names starting `roux_` are roux's")
		tables.concat(columns).concat(aside)
	}

	## Why a table or column would be lost, and the steps that rename it or
	## drop it.
	lost : Str, Str, Str, Str -> Str
	lost = |what, held, rename, drop|
		Str.join_with(
			[
				"${what} is in the database, not in schema.sql: its ${held} would go.",
				" Renamed? Add the step to ledger.sql: `${rename}`",
				" Gone on purpose? `${drop}`",
			],
			"",
		)

	planned : Schema, Schema -> List(Step)
	planned = |live, pristine| {
		# Each table made from rows the database has, in schema.sql's order.
		rebuilt = rebuilt_tables(live, pristine)
		# What holds no rows and changed goes first. What goes with a table
		# or view is not dropped again: a table's indexes, a view's triggers.
		changed = live.objects.keep_if(|object| object.kind != "table" and !identical(pristine, object))
		remade_views = changed.keep_if(|object| object.kind == "view")
		goes_with = |object|
			(object.kind == "index" and has_named(rebuilt, object.table))
			or (object.kind == "trigger" and has_named(remade_views, object.table))
		unmade = changed.drop_if(goes_with).map(|object| unmake(pristine, object))
		remade = rebuilt.join_map(|table| rebuild(live, pristine, table))
		created = new_tables(live, pristine).map(
			|table| { sql: table.sql, why: "table `${table.name}`: new in schema.sql" },
		)
		# In schema.sql's order: what each refers to is made by then. A view
		# of a rebuilt table needs nothing: the rename aside left it as it was.
		made_again = |object|
			!identical(live, object)
			or (object.kind != "view" and has_named(rebuilt, object.table))
			or (object.kind == "trigger" and has_named(remade_views, object.table))
		derived = pristine.objects
			.keep_if(|object| object.kind != "table" and made_again(object))
			.map(|object| { sql: object.sql, why: "${object.kind} `${object.name}`: as schema.sql makes it" })
		unmade.concat(remade).concat(created).concat(derived)
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
		# The database's own spelling of the name: `Dish` is `dish` to SQLite.
		old = match find(live.objects, "table", table.name) {
			Ok(found) => found.name
			Err(NotFound) => crash "Migrate.rebuild: a rebuilt table is in the database"
		}
		aside = "${aside_prefix}${old}"
		why = |what| "table `${table.name}`: ${what}"
		# Each column both have, by name, each as each spells it.
		had = data_columns(live, old)
		pairs = data_columns(pristine, table.name).keep_oks(
			|column| find_column(had, column.name).map_ok(|found| { new: column.name, from: found.name }),
		)
		copied = if (pairs.is_empty()) [] else {
			into = Str.join_with(pairs.map(|pair| quote(pair.new)), ", ")
			from = Str.join_with(pairs.map(|pair| quote(pair.from)), ", ")
			insert = "INSERT INTO ${quote(table.name)} (${into}) SELECT ${from} FROM ${quote(aside)}"
			names = Str.join_with(pairs.map(|pair| pair.new), ", ")
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
			{ sql: "ALTER TABLE ${quote(old)} RENAME TO ${quote(aside)}", why: why("aside, to make it anew") },
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

	## Tables schema.sql makes that the database lacks.
	new_tables : Schema, Schema -> List(Object)
	new_tables = |live, pristine| gone_tables(pristine, live)

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

	## Columns of schema.sql's `table` that the database's lacks.
	new_columns : Schema, Schema, Str -> List(TableColumn)
	new_columns = |live, pristine, table| lost_columns(pristine, live, table)

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

	## A name as a person writes it in a step: bare when it is a plain
	## word (letters, digits, `_`, not starting with a digit), quoted
	## otherwise.
	sql_name : Str -> Str
	sql_name = |name| {
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
expect Migrate.sql_name("dish_2") == "dish_2"
expect Migrate.sql_name("dish of the day") == "\"dish of the day\""
expect Migrate.sql_name("2dish") == "\"2dish\""
expect Migrate.same_name("Dish", "dISH")
expect !Migrate.same_name("dish", "dishes")
expect {
	empty = { objects: [], columns: [] }
	Migrate.plan(empty, empty, Bool.False) == Ok([])
}
expect Migrate.pending(["a;", "b;"], ["a;", "b;", "c;"]) == Ok({ run: ["c;"], ahead: Bool.False })
expect Migrate.pending(["a;", "b;", "c;"], ["a;", "b;"]) == Ok({ run: [], ahead: Bool.True })
expect Migrate.pending([], []) == Ok({ run: [], ahead: Bool.False })
expect Migrate.pending(["a;", "x;"], ["a;", "b;"]).is_err()
