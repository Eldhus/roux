## rocstache templates as roux runs them (DESIGN.md, Templates): each
## `Menu.rocstache` has a generated `Menu.roc` holding its contract (`Ctx`)
## and `template`, which makes the template's value, purely: data the
## host's renderer reads when the value is sent (a response) or asked for
## its bytes. One VM, in the host, runs every template's bytecode over the
## record, read where Roc's compiler laid it out. An edit to a template's
## markup changes no Roc.
import Host
import Server
import Sse

Rocstache :: [].{

	## A template's value, as its generated `X.template` makes it: the
	## layouts it was made for, and the app's templates' union
	## (`Templates.Template`, generated). Only the generated constructor
	## builds one: a bare tag (`Menu(ctx)`) is not a `Template`, so it is a
	## type error wherever a template is sent.
	Template(t) : { layouts : U64, template : t }

	## A template as a response: 200, HTML, rendered as it is sent.
	html : Template(t) -> Server.Response(t)
	html = |made| {
		status: 200,
		headers: [{ name: "Content-Type", value: "text/html; charset=utf-8" }],
		body: Html(made),
	}

	## The template rendered now: UTF-8 bytes, the template's text and the
	## values, HTML-escaped as its tags say.
	bytes! : Template(t) => List(U8)
	bytes! = |made| Host.template_render!(made.layouts, Box.box(made.template)).bytes

	## The template rendered now, as a Str.
	str! : Template(t) => Str
	str! = |made| Str.from_utf8_lossy(bytes!(made))

	## The template rendered now as a Datastar patch: each line an
	## `elements` line; Datastar replaces the element by its id.
	patch! : Template(t) => Sse.Event
	patch! = |made| {
		lines = str!(made).split_on("\n").map(|line| "elements ${line}")
		match Sse.Event.named("datastar-patch-elements", Str.join_with(lines, "\n")) {
			Ok(event) => event
			Err(InvalidEventName) => crash "a constant event name has no line break"
		}
	}
}
