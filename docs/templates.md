# Templates

How a roux app makes its pages: what you write, what the build makes of it, and what happens
when you edit one under `roux dev` and when you ship it.


## Two files per page, one written by you

A page is HTML in `templates/`, beside the app's `main.roc`, with
[Mustache](https://mustache.github.io/mustache.5.html)'s tags. The language is rocstache: Roc
values in mustache tags. Editor support is [rocstache](https://github.com/Eldhus/rocstache).

| file | written by | says |
|---|---|---|
| `templates/Menu.rocstache` | you | the markup, and maybe its contract |
| `templates/Menu.roc` | the build | the contract as a Roc type, `Menu.Ctx`, and `Menu.template` |
| `templates/Templates.roc` | the build | every template of the app, as one tag union |

The app imports a template as it imports any module, and fills it with a record:

```roc
import templates/Menu

respond! = |request, context|
    match request.target {
        "/" => Ok(Rocstache.html(Menu.template({ title: "Today", items: context.dishes })))
        _ => Err(NotFound)
    }
```

`Menu.roc` changes only when the record the template reads changes, so its history in git is
the history of the template's type: commit it. `Templates.roc` holds a hash that depends on the
machine it was built on; the build writes it first, so leave it out of git.


## The tags

```html
{{%
## The menu page.
Ctx : { title : Str, items : List({ name : Str, price : U32, spicy : Bool }) }
%}}
<h1>{{ title }}</h1>
<p>{{ items | len | plural "dish" "dishes" }} on the menu.</p>
<ul>
{{#items}}
  <li>{{ name }}{{?spicy}} (hot){{/spicy}}: {{ price }} kr</li>
{{/items}}
</ul>
{{^items}}<p>The kitchen is closed.</p>{{/items}}
```

| tag | what |
|---|---|
| `{{ a.b }}` | a value, HTML-escaped: `<`, `>`, `&`, `"` and `'` |
| `{{{ a }}}` | a value as it is, for HTML the app made |
| `{{ a \| upper }}` | a value through a formatter |
| `{{#a}}…{{/a}}` | each element of a list; a record's fields; a Bool's body when true |
| `{{^a}}…{{/a}}` | when the list is empty, or the Bool false |
| `{{?a}}…{{/a}}` | when the Bool is true; its body reads the fields around it, as `{{#a}}` would read `a`'s |
| `{{../a}}`, `{{.}}` | a field of the enclosing scope; the element itself |
| `{{> Name}}`, `{{> Name field}}` | another template (Partials, below) |
| `{{! … }}` | a comment |
| `{{% … %}}` | the contract, first in the file |

A line that holds only a section, closing, comment or partial tag (spaces aside) goes with the
tag, as in Mustache: the template above writes one tag a line and leaves no blank lines.

**Formatters** are five: `len` (a list's length), `plural "one" "many"` (a count and its noun),
`upper` and `lower` (ASCII letters only) and `url` (percent-encoded for a path segment or a query
value). They chain only as `len | plural`. Anything else, a date, a price with decimals, a
string cut short, is computed in Roc into a field: the template prints it.

**What prints:** `Str`, and integers up to 64 bits. A record may carry an `F64` or a `Dec` for a
template it passes on, but no tag prints one.


## The contract

A template's **contract** is the record it reads. Declare it in the `{{% %}}` block, as above, in
Roc's own syntax; the `##` lines above `Ctx` become the type's documentation. Or leave the block
out, and the build infers it from the tags:

```html
<h1>{{ title }}</h1>
{{#items}}<li><a href="/dishes/{{ slug | url }}">{{ name }}</a>{{?spicy}} (hot){{/spicy}}</li>{{/items}}
{{#open}}<p>Open now.</p>{{/open}}
```

```roc
## What `Page.rocstache` reads, inferred from its tags.
Ctx : {
    items : List({ name : Str, slug : Str, spicy : Bool }),
    open : Bool,
    title : Str,
}
```

A dotted path is a record, a section that reads its element is a list, one that doesn't is a
Bool, a value under `len` is a list, and every other value is a `Str`. Declare the contract once a
template prints a number, or once its type is worth reading at the top of the file.

Either way the template is checked against its contract as the app builds, and a mistake is
roux's message at the template's line, never a Roc error deep in generated code. The app is
checked against the contract by Roc: a field missing or misspelt where the app fills the record is
an ordinary type error in the app.


## Partials

Two ways, for two jobs:

- `{{> Head}}` **inlines** `Head.rocstache` where it stands, in the same scope: Head reads the
  fields of whatever is around it. For a piece of markup shared by pages whose records have the
  same fields.
- `{{> Foot foot}}` **calls** `Foot.rocstache` with the field `foot` as its whole record. Foot
  has its own contract, and `foot` must be exactly that type. For a part with its own data, the
  same on every page: a footer, a navigation, a card.

```html
{{%
Ctx : { title : Str, items : List({ name : Str }), foot : { year : Str, who : Str } }
%}}
{{> Head}}
{{#items}}<li>{{ name }}</li>{{/items}}
{{> Foot foot}}
```

A contract spells its types out: `foot : Foot.Ctx` is refused, because the contract is laid out
on its own, before any Roc module is read.


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

A value can only come from its template's `template` function: a bare tag, `Menu(ctx)`, is a type
error wherever a response wants a template.


## Under roux dev

- **An edit to markup** reaches the browser without a restart: roux dev compiles the templates
  again (well under a millisecond for a small app), the running app rereads them at its next
  page, and the browser reloads. The app keeps its state and its open event streams.
- **An edit that changes a contract** rewrites `Menu.roc`, so Roc builds the app again and it
  restarts, as for an edit to Roc.
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
| a section left open | `items` is never closed |
| `{{/item}}` closing `{{#items}}` | `item` closes a different section than the one open |
| a formatter roux lacks | `capitalize` is not a formatter (len, plural, upper, lower, url): compute it in Roc, into a field |
| an `F64` printed | `price` a template prints a Str or an integer; format it in Roc, into a Str field (it is F64) |
| a section over a `Str` | `title` a section takes a list, a record or a Bool (it is Str) |
| `{{?}}` over a list | `items` `{{?}}` takes a Bool (it is List({ name : Str, price : U32 })) |
| `len` of a `Str` | `title` `len` takes a list |
| `{{& a}}`, Mustache's unescaped tag | `& title` is not a field name (like `title`) |
| a partial that does not exist | `Header` is not a template here (no such .rocstache) |
| a called partial given the wrong record | `Foot` is not the partial's contract (it is { year : Str }) |
| an inlined partial reading a field not in scope | `title` the contract has no such field here (it has: items), then: (included from templates/Page.rocstache) |
| another module's type in a contract | `Foot.Ctx` spell the type out: glue lays out the contract alone |

Mustache's `{{= =}}` (other delimiters) is not rocstache either. A path is at most four fields
deep, sections nest at most 16 deep, and no template may be named `Templates`.


## Shipping

`roux build` compiles every template to bytecode and attaches it to the executable, in an ELF
section of its own, `.roux.templates`: the one file is the whole app. Nothing is read from
`templates/` at run time.

GNU `strip` keeps the section, whatever its options. LLVM's `llvm-strip` and `llvm-objcopy
--strip-all` remove it, and the app then stops at its first page, saying the section is missing
and what likely removed it.
