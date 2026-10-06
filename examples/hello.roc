app [Context, program] { pf: platform "../platform/main.roc" }

import pf.Server

Context : {}

program = { init!, respond! }

init! : () => Try({ config : Server.Config, context : Context }, [Exit(I64)])
init! = || Ok({ config: { port: 8080, static_dir: "" }, context: {} })

respond! : Server.Request, Context => Try(Server.Response, [NotFound, BadRequest(Str)])
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
