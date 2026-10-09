## rocstache templates as roux runs them (DESIGN.md, Templates): each
## `Page.rocstache` has a generated `Page.roc` holding its contract (`Ctx`)
## and `render!`, which calls the host's renderer: one VM, in the host,
## that runs every template's bytecode over the record, read where Roc's
## compiler laid it out. An edit to a template's markup changes no Roc.
import Host
import Server

Rocstache :: [].{

	## A rendered page's bytes: UTF-8, the template's text and the values,
	## HTML-escaped as its tags say.
	Html : List(U8)

	## Renders template `index` from `boxed`, its contract. Trusts its
	## caller: the box must hold exactly the contract the index's template
	## was compiled for, which only its generated module guarantees.
	render! : U64, Box(a) => Html
	render! = |index, boxed| Host.template_render!(index, boxed).bytes

	## The page as a Str (a Datastar patch's lines).
	str : Html -> Str
	str = |html| Str.from_utf8_lossy(html)

	## Rendered bytes as a response: 200, HTML.
	html : Html -> Server.Response(page)
	html = |bytes| {
		status: 200,
		headers: [{ name: "Content-Type", value: "text/html; charset=utf-8" }],
		body: Bytes(bytes),
	}
}
