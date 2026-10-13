app [Context, program] { pf: platform "../platform/main.roc" }

import pf.Server

## The smallest app, and its negative space:
## - `/`: `hello`;
## - `/echo`: the body read (at most 1 MB), its method and length
##   answered; a body that cannot be read is 400;
## - anything else 404.

Context : {}

program = { init!, respond! }

init! : () => Try({ config : Server.Config, context : Context }, [Exit(I64)])
init! = || Ok({ config: { port: 8080, static_dir: "" }, context: {} })

respond! : Server.Request, Context => Try(Server.Response(_), [NotFound, BadRequest(Str)])
respond! = |request, _context|
	match request.target {
		"/" => Ok(Server.text("hello\n"))
		"/echo" =>
			match Server.read_body!(request, 1_000_000) {
				Ok(body) => Ok(Server.text("${request.method} /echo body=${List.len(body).to_str()}\n"))
				Err(BodyErr(err)) => Err(BadRequest(Str.inspect(err)))
			}
		_ => Err(NotFound)
	}
