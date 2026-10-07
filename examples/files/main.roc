app [Context, program] { pf: platform "../../platform/main.roc" }

import pf.Server
import pf.File
import pf.Rocstache

## Static files and file reads: `public/` is served by the host before
## `respond!` (style.css, with gzip and ETags); `/notes` reads notes.txt
## from disk on every request, so a change shows without a restart;
## `/first-line` answers notes.txt's first line as `init!` read it once, at
## start (as a secret or a setting is read).
Context : { first_line : Str }

program = { init!, respond! }

init! : () => Try({ config : Server.Config, context : Context }, [Exit(I64), FileErr(File.FileErr)])
init! = || {
	notes = File.read_utf8!("notes.txt", 64 * 1024)?
	first_line =
		match notes.split_first("\n") {
			Ok({ before, .. }) => before
			Err(_) => notes
		}
	Ok({ config: { port: 8080, static_dir: "public" }, context: { first_line } })
}

respond! : Server.Request, Context => Try(Server.Response, [NotFound, FileErr(File.FileErr)])
respond! = |request, { first_line }|
	match request.target {
		"/first-line" => Ok(Server.text("${first_line}\n"))
		"/notes" => {
			notes = File.read_utf8!("notes.txt", 64 * 1024)?
			page = "<link rel=\"stylesheet\" href=\"/style.css\"><h1>Notes</h1><p>${Rocstache.escape(notes)}</p>"
			Ok(Server.html(page))
		}
		"/missing" => {
			_ = File.read_utf8!("no-such-file.txt", 1024)?
			Ok(Server.text("unreachable"))
		}
		"/too-large" => {
			_ = File.read_utf8!("notes.txt", 10)?
			Ok(Server.text("unreachable"))
		}
		_ => Err(NotFound)
	}
