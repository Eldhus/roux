## The host's effects and the records that cross the boundary. Apps use
## them through Server, Stdout and Stderr, never directly.
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

	stdout_line! : Str => {}
	stderr_line! : Str => {}

	## The whole body, up to `limit_bytes`; read from the connection only
	## now, when the handler asks.
	request_body_read_all! : U64, U64 => Try(List(U8), [BodyTooLarge, BodyInvalid, BodyDisconnected, BodyAfterStream, BodyDuringWrite])

	## A streamed response on the request `body` names: a 200 head with
	## these headers, then a chunk per send, then the end (fourneau's
	## streams). Out of order, or an event too large, is `StreamRefused`.
	response_stream_start! : U64, List(Header) => Try({}, [StreamDisconnected, StreamRefused])
	response_stream_send! : U64, List(U8) => Try({}, [StreamDisconnected, StreamRefused])
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

	## Opens the app's one database, in `init!` (path, schema.sql, the
	## statements, when a commit is durable); `Err` says why not.
	sqlite_open! : Str, Str, List(SqliteStatement), SqliteSynchronous => Try({}, Str)

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

	## One piece of a rendered page (Rocstache.Html): a run of the
	## templates' static text (`offset * 65536 + length` into the text the
	## build linked in; 0 for none), and after it, for all but `Text`, a
	## value. A `Value`'s Str is written as the run's top byte says (escaped,
	## raw, upper- or lowercased and escaped, percent-encoded): the bytecode
	## holds the word ready, so the walker never looks at it.
	TemplatePart : [Text(U64), Value(U64, Str), Signed(U64, I64), Unsigned(U64, U64)]

	## The templates' bytecode, as the build linked it in: once, at startup.
	templates_load! : {} => List(U64)

	## A page's parts written out, HTML-escaped where the parts say.
	templates_bytes! : List(TemplatePart) => List(U8)
}
