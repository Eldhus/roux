app [Context, program] { pf: platform "../../platform/main.roc" }

import pf.File
import pf.Server
import pf.Sqlite
import pf.Stderr

## The migration cases' app (runner.zig runs it in each case's directory):
## opens `test.db` with `schema.sql` and the ledger's steps as roux-db split
## them (`ledger`, a NUL between two steps), so the platform migrates it,
## then exits: 0 when it opened, 1 with the reason on stderr. It never
## serves.

Context : {}

program = { init!, respond! }

init! : () => Try({ config : Server.Config, context : Context }, [Exit(I64)])
init! = || {
	schema = File.read_utf8!("schema.sql", 1_000_000) ? |_| Exit(2)
	steps = File.read_utf8!("ledger", 1_000_000) ? |_| Exit(2)
	ledger = steps.split_on("\u(0)").keep_if(|step| !step.is_empty())
	database = { path: "test.db", schema, ledger, statements: [] }
	match Sqlite.open!(database, { synchronous: Full }) {
		Ok(_) => Err(Exit(0))
		Err(DbErr(err)) => {
			Stderr.line!(message_of(err))
			Err(Exit(1))
		}
	}
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
