## What templates compiled by roux call (DESIGN.md, Templates). An app does
## not use this module itself: each `Page.rocstache` has a generated
## `Page.roc` whose `render!` calls it with the template's id.
import Host

Rocstache :: [].{

	## Renders the template `id` names from `boxed`, its contract, in the
	## app's templates object (Zig, compiled from the template). Trusts its
	## caller: the box must hold exactly the contract the id was made for,
	## which only the generated module guarantees.
	compiled_render! : U64, Box(a) => Str
	compiled_render! = |id, boxed| Host.template_render!(id, boxed)
}
