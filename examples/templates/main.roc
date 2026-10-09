app [Context, program] { pf: platform "../../platform/main.roc" }

import pf.Server
import pf.Rocstache
import Page

## A page from a template: `Page.rocstache`, whose contract `roux build`
## writes to `Page.roc` (with `Page.template`, which makes the template's
## value) and whose markup it compiles to bytecode linked into the app.
## The value is data: the host renders it as the response is sent, so the
## whole response is a pure function, and `roc test` checks it. The menu
## is the app's context, made once by `init!`.
Context : { menu : Page.Ctx }

program = { init!, respond! }

init! : () => Try({ config : Server.Config, context : Context }, [Exit(I64)])
init! = || Ok({
	config: { port: 8080, static_dir: "" },
	context: {
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

respond! : Server.Request, Context => Try(Server.Response(_), [NotFound])
respond! = |request, context| respond(request.target, context)

## Pure: the response for a target, as data.
respond : Str, Context -> Try(Server.Response(_), [NotFound])
respond = |target, context|
	match target {
		"/" => Ok(Rocstache.html(Page.template(context.menu)))
		_ => Err(NotFound)
	}

menu = { title: "Menu", items: [{ name: "Roux", price: 120 }] }

expect respond("/", { menu: menu }) == Ok(Rocstache.html(Page.template(menu)))

expect respond("/nope", { menu: menu }) == Err(NotFound)

expect
	match respond("/", { menu: menu }) {
		Ok({ status: 200, body: Html({ template: Page(page), .. }), .. }) => page.title == "Menu"
		_ => False
	}
