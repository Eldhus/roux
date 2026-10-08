app [Context, program] { pf: platform "../../platform/main.roc" }

import pf.Server
import pf.Rocstache
import Page

## A page rendered from a template per request: `Page.rocstache`, whose
## contract and walkers `roux build` writes to `Page.roc` and whose markup
## it compiles to bytecode linked into the app. The bytecode and the menu
## are the app's context, made once by `init!`.
Context : { code : Rocstache.Templates, menu : Page.Ctx }

program = { init!, respond! }

init! : () => Try({ config : Server.Config, context : Context }, [Exit(I64)])
init! = || Ok({
	config: { port: 8080, static_dir: "" },
	context: {
		code: Rocstache.load!(),
		menu: {
			title: "Eldhús <menu>",
			items: [
				{ name: "Roux", price: 120 },
				{ name: "Sauce \"espagnole\"", price: 340 },
				{ name: "Fish & chips", price: 290 },
			],
		},
	},
})

respond! : Server.Request, Context => Try(Server.Response, [NotFound])
respond! = |request, context|
	match request.target {
		"/" => Ok(Rocstache.html!(Page.render(context.code, context.menu)))
		_ => Err(NotFound)
	}
