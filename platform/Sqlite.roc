import Host
import Server

## The app's one SQLite database, queried through the typed modules
## `roux-db gen db` writes from `db/schema.sql` and `db/*.sql`
## (`db/Module.roc`, and `db/Database.roc`, every statement numbered):
##
## ```roc
## init! = || {
##     db = Sqlite.open!(Database.at("dishes.db"))?
##     Ok({ config: { port: 8080, static_dir: "" }, context: { db } })
## }
##
## respond! = |request, { db }| {
##     dish = Dishes.by_id!(Sqlite.read(db, request), { id: 3 })?
##     tx = Sqlite.write!(db, request)?
##     Dishes.rename!(tx, { id: 3, name: "Soup" })?
##     Sqlite.commit!(tx)?
##     ...
## }
## ```
##
## No SQL is read at run time: every statement was prepared at startup,
## and a call names it by number. A read runs on its request's shard. A
## write runs on the one writer, one request at a time: `write!` waits a
## bounded time (`WriterBusy`, answered 503), is refused to a GET or a
## HEAD (`WriteRefused`), and a transaction not committed when `respond!`
## returns is rolled back: an error answer stays as it is (a constraint
## the handler made a 400), a success becomes a 500, since what it did was
## undone. `ROUX_DATABASE` overrides the
## path. No migrations yet: an existing database must hold exactly the
## schema `schema.sql` makes, or `open!` fails.
Sqlite := [].{
	## What `Database.at(path)` gives `open!`.
	Database : { path : Str, schema : Str, statements : List(Statement) }

	Statement : Host.SqliteStatement

	## A parameter, or a cell of a row.
	Value : Host.SqliteValue

	## A column or parameter that may be NULL.
	Nullable(a) : [Null, NotNull(a)]

	Err : [
		## The writer stayed busy past the wait, or too many waited: 503.
		WriterBusy(Str),
		## Every reader of the request's shard stayed busy past the wait:
		## 503 (statements waiting on the disk).
		ReadersBusy(Str),
		## Past the statement's time.
		TimedOut(Str),
		## More rows (or bytes) than the query's bound.
		TooManyRows(Str),
		## A value the column's type does not hold: a NULL from an outer
		## join typed never NULL, a Bool that is 2, text not UTF-8.
		InvalidValue(Str),
		## A UNIQUE, NOT NULL, CHECK or FOREIGN KEY constraint, as SQLite
		## says it.
		Constraint(Str),
		## A write for a GET or HEAD, a second `write!`, a write without one.
		WriteRefused(Str),
		Failed(Str),
		## Generated code and the host disagree: regenerate with roux-db.
		Misuse(Str),
	]

	## The opened database, for the app's context.
	Db :: { opened : Bool }

	## Reads for one request.
	Read :: { request : U64, writer : Bool }

	## One request's transaction on the writer.
	Write :: { request : U64 }

	## Opens the database, once, in `init!`.
	open! : Database => Try(Db, [DbErr(Err)])
	open! = |database|
		match Host.sqlite_open!(database.path, database.schema, database.statements) {
			Ok({}) => Ok(Db.{ opened: Bool.True })
			Err(message) => Err(DbErr(Failed(message)))
		}

	read : Db, Server.Request -> Read
	read = |_db, request| Read.{ request: request.body, writer: Bool.False }

	## Takes the writer and begins the request's transaction.
	write! : Db, Server.Request => Try(Write, [DbErr(Err)])
	write! = |_db, request|
		match Host.sqlite_write_begin!(request.body) {
			Ok({}) => Ok(Write.{ request: request.body })
			Err(err) => Err(DbErr(from_host(err)))
		}

	## Commits, and gives the writer back.
	commit! : Write => Try({}, [DbErr(Err)])
	commit! = |Write.{ request }|
		match Host.sqlite_commit!(request) {
			Ok({}) => Ok({})
			Err(err) => Err(DbErr(from_host(err)))
		}

	## Reads inside the transaction: they see its writes.
	reading : Write -> Read
	reading = |Write.{ request }| Read.{ request, writer: Bool.True }

	## For generated code: statement `index` of `Database.roc`.
	run_read! : Read, U32, List(Value) => Try(List(List(Value)), [DbErr(Err)])
	run_read! = |Read.{ request, writer }, index, params|
		match Host.sqlite_run!(request, index, writer, params) {
			Ok(rows) => Ok(rows)
			Err(err) => Err(DbErr(from_host(err)))
		}

	run_write! : Write, U32, List(Value) => Try(List(List(Value)), [DbErr(Err)])
	run_write! = |Write.{ request }, index, params|
		match Host.sqlite_run!(request, index, Bool.True, params) {
			Ok(rows) => Ok(rows)
			Err(err) => Err(DbErr(from_host(err)))
		}

	## The host's code (host/database.zig, `Failure`) as a tag.
	from_host : Host.SqliteErr -> Err
	from_host = |{ code, message }|
		match code {
			1 => WriterBusy(message)
			2 => TimedOut(message)
			3 => TooManyRows(message)
			4 => InvalidValue(message)
			5 => Constraint(message)
			6 => WriteRefused(message)
			8 => Misuse(message)
			9 => ReadersBusy(message)
			_ => Failed(message)
		}

	## Parameters, as generated code makes them.
	Param := [].{
		i64 : I64 -> Value
		i64 = |n| Integer(n)

		f64 : F64 -> Value
		f64 = |x| Real(x)

		str : Str -> Value
		str = |s| Text(s)

		bytes : List(U8) -> Value
		bytes = |b| Blob(b)

		bool : Bool -> Value
		bool = |b| Integer(if b 1 else 0)

		nullable_i64 : Nullable(I64) -> Value
		nullable_i64 = |value|
			match value {
				Null => Null
				NotNull(n) => Integer(n)
			}

		nullable_f64 : Nullable(F64) -> Value
		nullable_f64 = |value|
			match value {
				Null => Null
				NotNull(x) => Real(x)
			}

		nullable_str : Nullable(Str) -> Value
		nullable_str = |value|
			match value {
				Null => Null
				NotNull(s) => Text(s)
			}

		nullable_bytes : Nullable(List(U8)) -> Value
		nullable_bytes = |value|
			match value {
				Null => Null
				NotNull(b) => Blob(b)
			}

		nullable_bool : Nullable(Bool) -> Value
		nullable_bool = |value|
			match value {
				Null => Null
				NotNull(b) => Integer(if b 1 else 0)
			}
	}

	## Cells, as generated code reads them. The host checked every cell
	## against its column's type, so another kind is a bug: a crash.
	Cell := [].{
		i64 : Value -> I64
		i64 = |cell|
			match cell {
				Integer(n) => n
				_ => crash "Sqlite.Cell.i64: the host checks cells"
			}

		f64 : Value -> F64
		f64 = |cell|
			match cell {
				Real(x) => x
				_ => crash "Sqlite.Cell.f64: the host checks cells"
			}

		str : Value -> Str
		str = |cell|
			match cell {
				Text(s) => s
				_ => crash "Sqlite.Cell.str: the host checks cells"
			}

		bytes : Value -> List(U8)
		bytes = |cell|
			match cell {
				Blob(b) => b
				_ => crash "Sqlite.Cell.bytes: the host checks cells"
			}

		bool : Value -> Bool
		bool = |cell|
			match cell {
				Integer(n) => n == 1
				_ => crash "Sqlite.Cell.bool: the host checks cells"
			}

		nullable_i64 : Value -> Nullable(I64)
		nullable_i64 = |cell|
			match cell {
				Null => Null
				_ => NotNull(Cell.i64(cell))
			}

		nullable_f64 : Value -> Nullable(F64)
		nullable_f64 = |cell|
			match cell {
				Null => Null
				_ => NotNull(Cell.f64(cell))
			}

		nullable_str : Value -> Nullable(Str)
		nullable_str = |cell|
			match cell {
				Null => Null
				_ => NotNull(Cell.str(cell))
			}

		nullable_bytes : Value -> Nullable(List(U8))
		nullable_bytes = |cell|
			match cell {
				Null => Null
				_ => NotNull(Cell.bytes(cell))
			}

		nullable_bool : Value -> Nullable(Bool)
		nullable_bool = |cell|
			match cell {
				Null => Null
				_ => NotNull(Cell.bool(cell))
			}
	}
}

expect Sqlite.from_host({ code: 1, message: "busy" }) == WriterBusy("busy")
expect Sqlite.from_host({ code: 99, message: "?" }) == Failed("?")
expect Sqlite.Param.bool(Bool.True) == Integer(1)
expect Sqlite.Param.nullable_str(Null) == Null
expect Sqlite.Cell.nullable_i64(Integer(7)) == NotNull(7)
expect Sqlite.Cell.nullable_str(Null) == Null
