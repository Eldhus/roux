## rocstache templates as roux runs them (DESIGN.md, Templates): each
## `Page.rocstache` has a generated `Page.roc` whose `render` is pure: it
## walks the template's bytecode over the page's record and returns the
## page as parts, which the host writes out. The bytecode is data, loaded
## once (`load!`), so an edit to a template's markup changes no Roc.
import Host
import Server

Rocstache :: [].{

	Part : Host.TemplatePart

	## A rendered page: what `Page.render` returns; `bytes!` writes it.
	Html : List(Part)

	## Every template's bytecode, from `load!`: give it to each `render`.
	Templates : List(U64)

	## The templates' bytecode, as the build linked it into the app. Call
	## it once, in `init!`, and keep it in the context.
	load! : () => Templates
	load! = || Host.templates_load!({})

	## The page's bytes, HTML-escaped as its parts say: a response's body.
	bytes! : Html => List(U8)
	bytes! = |html| Host.templates_bytes!(html)

	## The page as a Str (a Datastar patch's lines). The bytes are UTF-8:
	## the template's text and the values' Strs, cut only at tags.
	str! : Html => Str
	str! = |html| Str.from_utf8_lossy(Host.templates_bytes!(html))

	## The page as a response: 200, HTML.
	html! : Html => Server.Response
	html! = |parts| {
		status: 200,
		headers: [{ name: "Content-Type", value: "text/html; charset=utf-8" }],
		body: Host.templates_bytes!(parts),
	}
}
