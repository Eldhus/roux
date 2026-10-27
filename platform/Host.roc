## The host's effects and the records that cross the boundary. Apps use
## them through the platform's exposed modules (main.roc), never directly.
Host := [].{
	Header : { name : Str, value : Str }

	RequestFromHost : {
		method : Str,
		target : Str,
		headers : List(Header),
		## Names this request's body to `request_body_read_all!`.
		body : U64,
	}

	ResponseToHost : {
		status : U16,
		headers : List(Header),
		body : List(U8),
	}

	## The file's bytes as text, at most `limit_bytes`.
	file_read_utf8! : Str, U64 => Try(Str, [FileNotFound, FileTooLarge, FileUnreadable])

	## Waits this many milliseconds on the request's fiber.
	sleep_millis! : U64 => {}

	stdout_line! : Str => {}
	stderr_line! : Str => {}

	## The whole body, up to `limit_bytes`; read from the connection only
	## now, when the handler asks.
	request_body_read_all! : U64, U64 => Try(List(U8), [BodyTooLarge, BodyInvalid, BodyDisconnected, BodyAfterStream, BodyDuringWrite])

	## A streamed response on the request `body` names: a 200 head with
	## these headers, then the events, then the end (fourneau's streams).
	## Out of order is `StreamRefused`, and so is a header that could break
	## the head or an event type with a line break. An event is its type
	## (none when "") and its data, of any size: the host frames it through
	## its scratch memory, a chunk a piece (host/sse.zig).
	response_stream_start! : U64, List(Header) => Try({}, [StreamDisconnected, StreamRefused])
	response_stream_event! : U64, Str, Str => Try({}, [StreamDisconnected, StreamRefused])
	response_stream_flush! : U64 => Try({}, [StreamDisconnected, StreamRefused])
	response_stream_end! : U64 => Try({}, [StreamDisconnected, StreamRefused])

	## A statement of `Database.roc` (roux-db): the type codes are
	## sqlite/types.zig's.
	SqliteStatement : {
		name : Str,
		sql : Str,
		writes : Bool,
		rows_max : U32,
		params : List(U8),
		columns : List(U8),
	}

	## A SQLite value: a parameter, or a cell of a row.
	SqliteValue : [Null, Integer(I64), Real(F64), Text(Str), Blob(List(U8))]

	## Why a statement failed: `code` is host/database.zig's `Failure`.
	SqliteErr : { code : U8, message : Str }

	## `Sqlite.open!`, in `init!`, once, in three calls inside one
	## transaction, which the last commits (or, failing, rolls back).
	##
	## First the database at the path (schema.sql's text next): the steps of
	## ledger.sql it ran, in order (`roux_ledger`, a row each, its text),
	## and host/database.zig's listings of it and of what schema.sql makes.
	sqlite_inspect! : Str, Str => Try({ ran : List(List(SqliteValue)), live : SqliteListings, pristine : SqliteListings }, Str)

	## Then the steps of ledger.sql it has not run, each recorded as it
	## runs; with `False`, recorded only (a database schema.sql makes now).
	## The database's listing after.
	sqlite_ledger! : List(Str), Bool => Try(SqliteListings, Str)

	## Last, the database brought to schema.sql by Migrate.roc's steps,
	## checked, committed, and its statements prepared (when a commit is
	## durable, then the waits as host/database.zig's `Waits`: read_wait_ms,
	## write_wait_ms, writers_waiting, 0 for the host's default); `Err` says
	## why not. The waits go as numbers, not a record: Zig 0.17 broke on
	## reading a record an exported function takes by value (an LLVM memcpy,
	## -Osafe).
	sqlite_open! : List(SqliteStatement), SqliteSynchronous, List(SqliteStep), U32, U32, U32 => Try({}, Str)

	## A statement of a migration, and why it runs: `Migrate.Step`, as the
	## host reads it.
	SqliteStep : { sql : Str, why : Str }

	## `objects`: type, name, tbl_name, sql. `columns`: table, name, hidden,
	## autoincrement.
	SqliteListings : { objects : List(List(SqliteValue)), columns : List(List(SqliteValue)) }

	## As host/database.zig's `Synchronous`.
	SqliteSynchronous : [Full, Normal]

	## Runs statement `index` for the request `body` names: on its shard's
	## reader, or (`True`) on the writer the request holds.
	sqlite_run! : U64, U32, Bool, List(SqliteValue) => Try(List(List(SqliteValue)), SqliteErr)

	## Takes the writer for the request, and begins its transaction.
	sqlite_write_begin! : U64 => Try({}, SqliteErr)

	## Commits the request's transaction, and gives the writer back.
	sqlite_commit! : U64 => Try({}, SqliteErr)

	## Copies the database into a directory for the request `body` names,
	## keeping that many copies; gives the copy's name.
	sqlite_backup! : U64, Str, U32 => Try(Str, SqliteErr)

	## The app's `Templates.Template`, boxed, rendered: the host reads which
	## template by its tag and runs its bytecode over the tag's payload,
	## reading the record where Roc's compiler laid its fields out, as glue
	## laid the union out. `layouts` is the identity
	## the value was made for (`Templates.layouts`); the host stops on any
	## other, whose offsets are not this program's. The box comes back
	## untouched for Roc to release: Roc knows its type.
	template_render! : U64, Box(a) => { bytes : List(U8), template : Box(a) }
}
