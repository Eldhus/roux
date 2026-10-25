app [Context, program] { pf: platform "../../platform/main.roc" }

import pf.File
import pf.Server
import pf.Sqlite
import pf.Stderr

## The migration cases' app (runner.zig runs it in each case's directory):
## opens `test.db` with `schema.sql` and the drops roux-db read from it
## (`drops`: `table<tab>menu`, `column<tab>dish<tab>note`, a line each:
## a name may hold a space), so the
## platform migrates it, then exits: 0 when it opened, 1 with the reason
## on stderr. It never serves.

Context : {}

program = { init!, respond! }

init! : () => Try({ config : Server.Config, context : Context }, [Exit(I64)])
init! = || {
	schema = File.read_utf8!("schema.sql", 1_000_000) ? |_| Exit(2)
	listed = File.read_utf8!("drops", 100_000) ? |_| Exit(2)
	drops = listed.split_on("\n").keep_oks(drop_of)
	database = { path: "test.db", schema, statements: [], drops }
	match Sqlite.open!(database, { synchronous: Full }) {
		Ok(_) => Err(Exit(0))
		Err(DbErr(err)) => {
			Stderr.line!(message_of(err))
			Err(Exit(1))
		}
	}
}

drop_of : Str -> Try(Sqlite.Drop, [Blank])
drop_of = |line|
	match line.split_on("\t") {
		["table", table] => Ok(Table(table))
		["column", table, column] => Ok(Column(table, column))
		_ => Err(Blank)
	}

message_of : Sqlite.Err -> Str
message_of = |err|
	match err {
		Failed(message) => message
		Misuse(message) => message
		_ => Str.inspect(err)
	}

respond! : Server.Request, Context => Try(Server.Response(_), [NotFound])
respond! = |_request, _context| Err(NotFound)
