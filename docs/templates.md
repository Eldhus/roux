# Templates

How a roux app makes its pages: what you write, what the build makes of it, and what happens
when you edit one under `roux dev` and when you ship it.


## The files

A page is HTML in `templates/`, beside the app's `main.roc`, with
[Mustache](https://mustache.github.io/mustache.5.html)'s tags. The language is rocstache: Roc
values and Roc expressions in mustache tags. Editor support is
[rocstache](https://github.com/Eldhus/rocstache).

| file | written by | in git | says |
|---|---|---|---|
| `templates/Menu.rocstache` | you | yes | the markup, and maybe its contract |
| `templates/Fmt.roc` | you | yes | your own Roc for the holes: plain functions, tested with `expect` |
| `templates/Menu.roc` | the build | yes | the contract as a Roc type, `Menu.Ctx`, its fragments', and `Menu.template` |
| `templates/Holes.roc` | the build | no | every hole of Roc as a function, and `hole`, which renders one |
| `templates/Templates.roc` | the build | no | every template of the app, as one tag union |

`Menu.roc` changes only when the record the template takes changes, so its history in git is the
history of the template's type. Editing a hole's Roc changes `Holes.roc` alone. Both of the files
not in git are written first by every build; each app's `.gitignore` lists them.

The app imports a template as it imports any module, fills it with a record, and gives the
platform its holes:

```roc
app [Context, program] { pf: platform "…/roux/platform/main.roc" }

import pf.Rocstache
import templates/Menu
import templates/Holes

program = { init!, respond!, hole: Holes.hole }

respond! = |request, context|
    match request.target {
        "/" => Ok(Rocstache.html(Menu.template({ title: "Today", dishes: context.dishes })))
        _ => Err(NotFound)
    }
```


## The tags

```html
{{%
import Fmt
## The menu page.
Ctx : { title : Str, dishes : List({ name : Str, price : U32, spicy : Bool }) }
%}}
<h1>{{ title }}</h1>
<p>{{ Fmt.plural(dishes.len(), "dish", "dishes") }} on the menu.</p>
<ul>
{{#dishes |dish|}}
  <li>{{ dish.name }}{{?dish.spicy}} (hot){{/dish.spicy}}: {{ Fmt.kr(dish.price) }}</li>
{{/dishes}}
</ul>
{{^dishes}}<p>The kitchen is closed.</p>{{/dishes}}
```

| tag | what |
|---|---|
| `{{ dish.name }}` | a path, HTML-escaped (`<`, `>`, `&`, `"` and `'`): read where it is |
| `{{ Fmt.kr(dish.price) }}` | a Roc expression of type `Str`, escaped |
| `{{{ … }}}` | either, as it is, for HTML the app made |
| `{{#dishes \|dish\|}}…{{/dishes}}` | each element of a list, named `dish`; or a record, named |
| `{{?spicy}}…{{/spicy}}` | when the Bool is true |
| `{{^dishes}}…{{/dishes}}` | when the list is empty, or the Bool false |
| `{{> Name}}` | another template, as if its text were written here (Partials) |
| `{{$Row}}…{{/Row}}` | a fragment: rendered here, and alone (Fragments) |
| `{{! … }}` | a comment |
| `{{% … %}}` | the block, first in the file: `import` lines, then the contract |

A line that holds only a section, closing, comment, partial or fragment tag (spaces aside) goes
with the tag, as in Mustache: a template written one tag a line leaves no blank lines.

**Names.** A name is a section's binder (`dish`) or a field of the page's `Ctx` (`title`, `dishes`),
nothing else. A binder is visible inside its section, in nested sections, and in partials included
there; the page's fields are visible everywhere. A binder may not hide another name: not an open
section's binder, and not a field of the page's `Ctx`.

**Paths and expressions.** A tag that is only names and dots is a path: the renderer reads it
straight from the record. Anything else is a Roc expression. Either way a tag prints a `Str`, as
Roc's own interpolation requires: a number needs `.to_str()`, `{{ dish.id.to_str() }}`. A path is
Roc too, the same field read the same way; it is only read without a call. An expression holds literals, interpolation, names, `Module.name`, fields, calls,
method calls, Roc's operators and parentheses; anything bigger (`if`, `match`, a lambda, a record
or list) goes in a function of yours, which the hole calls.


## The contract

A template's **contract** is the record it takes. Declare it in the block, as above, in Roc's own
syntax (the `##` lines above `Ctx` become the type's documentation). Or leave it out, and the
build infers it:

```html
<h1>{{ title }}</h1>
{{#dishes |dish|}}<li>{{ dish.name }}: {{ Fmt.kr(dish.price) }}{{?dish.spicy}} (hot){{/dish.spicy}}</li>{{/dishes}}
{{?open}}<p>Open now.</p>{{/open}}
```

```roc
## What `Page.rocstache` reads, inferred from its tags.
Ctx : {
    dishes : List({ name : Str, price : U32, spicy : Bool }),
    open : Bool,
    title : Str,
}
```

A printed path is a `Str`, a dotted path a record, a section a list of what its body reads of its
binder, a condition a `Bool`. A field only a hole of Roc reads is typed by Roc itself: above,
`price` is a `U32` because that is what `Fmt.kr` takes. The build writes each such hole as a
function of exactly what it reads and lets Roc's type checker fill in the types, through
`roc glue`; the answer is kept until such a hole changes.

Declare the contract when a hole is generic (`{{ dish.price.to_str() }}` works for any number, so
no type is chosen), when a hole uses a module of the platform's (`pf.Url`), or whenever the type
is worth reading at the top of the file.

Either way the template is checked against its contract as the app builds, and a mistake is
roux's message at the template's line. The app is checked against the contract by Roc: a field
missing or misspelt where the app fills the record is an ordinary type error in the app.


## Partials

`{{> Price}}` copies `Price.rocstache` in where it stands: its text reads the names in scope there.
For shared chrome (a header reading the page's `title`) or for a piece that reads a name its
includer always gives it:

```html
{{#dishes |dish|}}<li>{{ dish.name }}: {{> Price}}</li>{{/dishes}}
```

with `Price.rocstache` holding `<b>{{ Fmt.kr(dish.price) }}</b>`. Included where no `dish` is in
scope, it is refused at the include, with the scope there and the line in the partial.


## Fragments

A fragment is a part of a page that also renders alone, for an htmx or Datastar swap, without
moving it to a file of its own:

```html
{{#dishes |dish|}}
  {{$Row}}<li id="dish-{{ dish.id.to_str() }}">{{ dish.name }}: {{> Price}}</li>{{/Row}}
{{/dishes}}
```

```roc
"/row" => Ok(Rocstache.html(Menu.Row.template(dish)))
```

Its contract is what it reads of its scope: here `Menu.Row.Ctx` is `{ id : U64, name : Str,
price : U32 }`, and `Menu.Row.template` takes any record with those fields. Its name is a type
name, and it may not read outside its own scope, since alone it has nothing else. A piece that
renders alone and also stands inside a section is a fragment of that page.


## Rendering

`Menu.template(ctx)` makes a value, not HTML. A response carries it, and the platform renders it
as the response is sent:

| | |
|---|---|
| `Rocstache.html(t)` | a response: 200, `text/html` |
| `Rocstache.bytes!(t)`, `Rocstache.str!(t)` | rendered now, for code that needs the text |
| `Rocstache.patch!(t)` | rendered now, as a [Datastar](https://data-star.dev) patch for a server-sent event: Datastar replaces the element with the same `id` |

So a handler that only picks a template and fills it is a pure function, and `roc test` checks
its response with `==`, or matches into it for the field that matters:

```roc
expect
    match respond("/", context) {
        Ok({ status: 200, body: Html({ template: Menu(page), .. }), .. }) => page.title == "Today"
        _ => False
    }
```

A path is read in place; a hole of Roc is one call into the app's `hole`, given just the values it
reads. A value can only come from its template's `template` function: a bare tag, `Menu(ctx)`, is
a type error wherever a response wants a template.


## Under roux dev

- **An edit to markup** reaches the browser without a restart: roux dev compiles the templates
  again (well under a millisecond for a small app), the running app rereads them at its next
  page, and the browser reloads. The app keeps its state and its open event streams.
- **An edit to a hole's Roc, or to a contract,** rewrites `Holes.roc` or `Menu.roc`, so Roc builds
  the app again and it restarts, as for an edit to Roc.
- **A mistake** is shown over the page in the browser, and in roux dev's terminal; the last good
  build goes on serving until it is fixed:

```text
templates/Menu.rocstache:13:29: `cost` the contract has no such field here (it has: name, price)
roux dev: build 2 failed; build 1 still serving
```


## When it refuses

| you wrote | roux says |
|---|---|
| a field the contract lacks | `cost` the contract has no such field here (it has: name, price) |
| a name nothing binds | `dish` is neither a field of the page's `Ctx` nor a section's name (it has: dishes, title) |
| `{{#dishes}}` | `dishes` a section names its element, as `{{#dishes \|dish\|}}` does (a Bool is `{{?flag}}`) |
| a binder hiding a page's field | `title` is a field of the page's `Ctx`: a section's name hides nothing |
| `{{ ../title }}` | `../` is gone: the names around a section stay in scope, so write the one meant |
| `{{ . }}` | `.` is gone: read the element by the name its section gives it |
| `{{ items \| len }}` | `\| len` is gone: write Roc, `{{ items.len().to_str() }}` (and so on for each formatter) |
| `if` or a lambda in a hole | a hole holds a small expression; put the rest in a function |
| a generic hole, no `Ctx` | reads a value whose type Roc cannot tell from the hole …: declare `{{% Ctx : ... %}}` |
| a section left open | `dishes` is never closed |
| a `U32` printed by a path | `price` a template prints a Str: write Roc, `{{ price.to_str() }}` (it is U32) |
| an `F64` printed by a path | `price` a template prints a Str: format it in Roc, `{{ Fmt.money(price) }}` (it is F64) |
| `{{?}}` over a list | `dishes` `{{?}}` takes a Bool (it is List({ name : Str, price : U32 })) |
| a partial that does not exist | `Header` is not a template here (no such .rocstache) |
| a partial reading a name not in scope | `dish` is neither …, then: (included from templates/Page.rocstache) |
| `{{> Name field}}` | a partial takes no context: it reads the names in scope where it stands |

A type error inside a hole's expression is Roc's, reported in `Holes.roc` with your expression
quoted word for word; the comment above each function names its template. Mustache's `{{= =}}`
and `{{& }}` are not rocstache. A path is at most four fields deep, sections nest at most 16 deep,
and no template may be named `Templates`.


## Shipping

`roux build` compiles every template to bytecode and attaches it to the executable, in an ELF
section of its own, `.roux.templates`: the one file is the whole app. Nothing is read from
`templates/` at run time.

GNU `strip` keeps the section, whatever its options. LLVM's `llvm-strip` and `llvm-objcopy
--strip-all` remove it, and the app then stops at its first page, saying the section is missing
and what likely removed it.
