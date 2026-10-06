app [Context, program] { pf: platform "../../platform/main.roc" }

import pf.Server
import Page

## A page rendered from a template per request: `Page.rocstache`, compiled
## to `Page.roc` by rocstache-gen (`zig build examples` regenerates it).
## The menu is the app's context, made once by `init!`.
Context : { title : Str, items : List({ name : Str, price : U32 }) }

program = { init!, respond! }

init! : () => Try({ config : Server.Config, context : Context }, [Exit(I64)])
init! = || Ok({
	config: { port: 8080, static_dir: "" },
	context: {
		title: "Eldhús <menu>",
		items: [
			{ name: "Roux", price: 120 },
			{ name: "Sauce \"espagnole\"", price: 340 },
			{ name: "Fish & chips", price: 290 },
		],
	},
})

respond! : Server.Request, Context => Try(Server.Response, [NotFound])
respond! = |request, context|
	match request.target {
		"/" => Ok(Server.html(Page.render(context)))
		_ => Err(NotFound)
	}
