app [Context, program] { pf: platform "../../platform/main.roc" }

import pf.File
import pf.Server
import pf.Sqlite
import pf.Stdout
import pf.Stderr

## The migration cases' app (runner.zig runs it in each case's directory):
## opens `test.db` with `schema.sql` and what roux-db read from it, a line
## each, fields between tabs (a name may hold a space):
##
## - `releases`: schema.sql's `@release`, then its `@oldest` (0 for none);
## - `drops`: `7<tab>table<tab>menu`, `7<tab>column<tab>dish<tab>note`;
## - `froms`: `7<tab>column<tab>dish<tab>name<tab>title`,
##   `7<tab>table<tab>meal<tab>menu`.
##
## so the platform migrates it, then exits: 0 when it opened (saying the
## release it came from, as an `init!` task would ask, when schema.sql has
## one), 1 with the reason on stderr. It never serves.

Context : {}

program = { init!, respond! }

init! : () => Try({ config : Server.Config, context : Context }, [Exit(I64)])
init! = || {
	schema = File.read_utf8!("schema.sql", 1_000_000) ? |_| Exit(2)
	releases = File.read_utf8!("releases", 1_000) ? |_| Exit(2)
	(release, oldest) = match releases.split_on("\t").keep_oks(U64.from_str) {
		[r, o] => (r, o)
		_ => return Err(Exit(2))
	}
	listed = File.read_utf8!("drops", 100_000) ? |_| Exit(2)
	drops = listed.split_on("\n").keep_oks(drop_of)
	filled = File.read_utf8!("froms", 100_000) ? |_| Exit(2)
	froms = filled.split_on("\n").keep_oks(from_of)
	database = { path: "test.db", schema, statements: [], release, oldest, drops, froms }
	match Sqlite.open!(database, { synchronous: Full }) {
		Ok(db) => {
			if release > 0 {
				Stdout.line!("migrated from release ${Sqlite.migrated_from(db).to_str()}")
			}
			Err(Exit(0))
		}
		Err(DbErr(err)) => {
			Stderr.line!(message_of(err))
			Err(Exit(1))
		}
	}
}

drop_of : Str -> Try(Sqlite.Line(Sqlite.Drop), [Blank])
drop_of = |line|
	match line.split_on("\t") {
		[number, "table", table] => released(number, Table(table))
		[number, "column", table, column] => released(number, Column(table, column))
		_ => Err(Blank)
	}

from_of : Str -> Try(Sqlite.Line(Sqlite.From), [Blank])
from_of = |line|
	match line.split_on("\t") {
		[number, "column", table, column, expression] => released(number, Column(table, column, expression))
		[number, "table", table, old] => released(number, Table(table, old))
		_ => Err(Blank)
	}

released : Str, a -> Try(Sqlite.Line(a), [Blank])
released = |number, line|
	match U64.from_str(number) {
		Ok(release) => Ok({ release, line })
		Err(_) => Err(Blank)
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
