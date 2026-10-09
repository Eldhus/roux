# Templates compiled by Zig (the `templates` branch)

The first of roux's two template experiments, built 2026-10-07 and
2026-10-08, on the branch `templates` (head `9dd205a`; the dragrace's
port on fourneau-dragrace's branch `templates`, head `2f87bec`). Both
branches and their worktrees were deleted 2026-10-08 (owner: "i want
that crazy mad strategy recorded but deleted"); the heads are kept as
the local tag `archive/templates-comptime` in each repository, and
`templates-vm` is built on them. The owner chose the second, bytecode run by one VM in the
host (`templates-vm`, DESIGN.md, Templates), on 2026-10-08. This page
keeps everything the first one was and measured, so it can be judged
again or brought back without reading its diff.

## The idea

The owner's (2026-10-07): the Roc a template generates is only its
contract, the record type it reads and a typed `render!`; Zig compiles
the template itself, at comptime. The `.roc` file then changes only when
the contract does, and the renderer is native code specialized to one
template: no parser, no tree and no interpreter at run time. Goals:
throughput under contention and the shortest save-to-screen loop. One
implementation for development and production ("I cannot accept two
implementations": a development interpreter was built and dropped).

## How a build worked

1. **`roux build`** (`tools/roux`, with `tools/rocstache`) parsed each
   `Page.rocstache`, decided its contract (declared in `{{% %}}` or
   inferred: the same contract.zig and declared.zig the VM uses), and
   wrote `Page.roc`:

   ```roc
   Page :: [].{
       Ctx : { title : Str, items : List({ name : Str, price : Str }) }
       render! : Ctx => Str
       render! = |ctx| Rocstache.compiled_render!(0x<id>, Box.box(ctx))
   }
   ```

   The id hashed the template's name and its contract's spelled type.
2. In the app's build directory: a copy of each template; `templates.zig`,
   a registry (each template's name, id, `@embedFile` of its source and
   its contract's Zig type); and a throwaway Roc platform with one hosted
   function per contract taking it concretely. **`roc glue`** with roc's
   own `ZigGlue.roc` ran on it when a contract changed (~0.5 s) and
   emitted each `Ctx` as a Zig `extern struct` in the layout Roc's
   compiler chose, with a recursive `decref`.
3. **`zig build-obj`** compiled one object per template (`part.zig`, its
   root naming the template) and a dispatcher (`object.zig`), each only
   when no object existed by the hash of its inputs: the template, the
   partials it inlines, the registry, the glue, the renderer. Up to 16
   compiles at once, beside roc. Debug in development (Zig's own
   backend), ReleaseSafe in production.
4. **`roc build`** emitted the app as an archive (`output: Archive`:
   crt1.o, the host, the app, Roc's builtins, musl).
5. **roux linked** the archive and the objects (`zig ld.lld -static`,
   40-80 ms).

At run time `Page.render!(ctx)` boxed the record and called
`hosted_template_render(id, box)`, which the dispatcher exported: a
switch on the id, the template's `measure` (exact), one Roc allocation of
that size, its `render` (asserted to fill it), the box released with
`decrefBoxWith` and the glue's `decref`, a Roc `Str` returned.

## The renderer (render.zig)

`Compiled(registry, index)` is one hand-written generic. Zig's comptime
runs the template parser (parse.zig, the same parser roux build uses) on
the embedded source, memoized per template (`Parsed(name, source)`),
checks every field read against the glue struct (`@compileError` naming
the template's line, a backstop: roux build checked the same first), and
walks the tree with `inline` loops. Each step of the walk happens in the
compiler and leaves only its node's code:

- static text: a fixed-size copy of a comptime-known string;
- `{{ title }}`: a load at a fixed offset (`ctx.title`) and an escape,
  16 bytes at a time;
- `{{#items}}`: a real loop, its body unrolled the same way, the element
  a typed pointer;
- `{{ price }}` an integer: digits two at a time.

For the race's Menu it was as if written by hand:

```zig
out.write_static("<!doctype html>…<tr><th>Dish</th><th>Price</th></tr>\n");
for (ctx.dishes.items()) |*d| {
    out.write_static("<tr><td>");  escape(d.name.asSlice(), out);
    out.write_static("</td><td>"); write_int(d.price, out);
    out.write_static("</td></tr>\n");
}
out.write_static("</table>…");
```

Two passes over the same tree: `measure` counts the bytes exactly
(every writer in out.zig has an exact measure; a test sweeps every byte
at every position through escape and its measure), `render` writes them
into one buffer of that size. Scopes are a comptime tuple of typed
pointers, so `../` is a comptime index and the scope stack costs
nothing. The recursion over the tree cannot be a loop with an explicit
stack (TigerStyle's preference), since each level's scope is another
type.

Partials: `{{> Top}}` compiled inline, in the includer's scope (its
fields are the includer's). `{{> Top frame}}` (2026-10-08) was called:
Top's contract is its own, the includer's field `frame` is `Top.Ctx`,
Top compiles once in its own object, and the includer calls its
`rocstache_measure_<id>` and `rocstache_render_<id>` through `@extern`
(symbols.zig), the field's glue type `@ptrCast` to Top's (same Roc
record, size and alignment asserted at comptime). An edit to Top then
recompiled one object, not every page including it.

Both kinds of object used a panic handler reporting through the host's
`roc_crashed` (`FullPanic`), not std's: std's stack-trace machinery cost
~290 ms of every Debug compile (an empty object: 327 ms with std's
handler, 43 ms with ours). `std.debug.simple_panic` did not compile on
Zig 0.17.

## What it measured

The prototype (2026-10-07, one render of the race's Menu, 742 bytes,
`perf stat`, minus the n=0 run):

| renderer | instructions | cycles |
|---|---|---|
| the generated Roc of the time (rocstache-gen) | 29,700 | 10,900 |
| that Roc improved by hand | 20,600 | 7,100 |
| Zig comptime, standalone | 3,240 | 1,115 |
| Zig comptime in the host, ReleaseSafe | 5,610 | 1,980 |
| Zig comptime as its own ReleaseFast object | 4,280 | 1,385 |

The race's Menu over HTTP on the laptop (2026-10-07; server on CPUs
0-1, oha on 2-7, 64 connections, five interleaved rounds, medians):

| build | req/s | instructions/req | user ns/req | p99 |
|---|---|---|---|---|
| main (templates as Roc) | 109,004 | 39,030 | 9,030 | 1.03 ms |
| comptime, ReleaseSafe | 164,753 | 14,807 | 3,368 | 0.62 ms |
| comptime, ReleaseFast | 169,307 | 13,881 | 3,020 | 0.58 ms |

Against the bytecode VM (2026-10-08): 15,085 instructions a request
against the host VM's 15,595 (the competitor at that date's commits);
on dedicated cores (`dragrace adhoc race`, three rounds) 135,639
requests a second against 131,374, the VM 3.1% behind. Earlier races
against the VM's first form (Roc walkers): 3.6-6.3% ahead.

The dev loop on the dragrace site (12 templates; save to page served):

| edit | comptime | host VM |
|---|---|---|
| a page's markup | 266-298 ms (one object, ~220 ms of Debug compile) | 88-111 ms |
| a partial in nine pages, inlined | 927-948 ms (nine objects) | ~100 ms |
| the same partial, called | 427-574 ms (one object) | ~100 ms |
| Roc (`main.roc`) | ~1.3 s | 1.2 s |
| the release build | 50 s | 39 s |
| (templates as Roc, main) | 3.0 s any template | |

## Why the VM was chosen

The trade, as measured: comptime was ~3% faster under load and ~3%
fewer instructions; the VM runs no compiler for a markup edit (the
bytecode is written as an ELF object directly), so every markup edit is
the link and a restart, 3-9 times faster than comptime's, flat whatever
the template or partial; its release build is shorter (no Zig objects;
the generated Roc is the contracts only, as comptime's); and the VM
opens the next step, a dev server rereading the bytecode with no
restart (state kept), which machine code compiled per template cannot
do without loading code. The owner: "focus on the host VM, obviously"
(2026-10-08).

What the VM kept from this branch: the parser, contracts (inferred and
declared, with the standalone rule), called partials, `roc glue` on a
throwaway platform for the layout (its own spec now, writing offsets as
data, where comptime used ZigGlue's `extern struct`s), the boxed record
behind a generic hosted function, `output: Archive` and roux's own link,
`roux build` and `roux dev`, and the escape and digit writers.

## Costs it had

- `render!` effectful (hosted functions are), as the VM's.
- A Zig compile per changed template; 13 objects ReleaseSafe in the
  optimized build; Zig's cache hit alone ~145 ms; its `--watch` slower
  than a fresh build (1.2 s and more).
- An empty contract `{}`: glue drops a zero-sized argument, so its module
  boxed a `U8` placeholder. (The VM needs no layout for it.)
- `compiled_render!` trusted the id to match the box's type, as the VM's
  `render!` trusts its index.
- Integers, `Str`, `Bool`, lists and records only; formatters built in
  (`len`, `plural`, `upper`, `lower`, `url`).

## Bringing it back

`git switch templates` in roux (or the worktree `../roux-templates`):
`tools/rocstache/render.zig` (the renderer), `out.zig` (the writers and
measures), `part.zig` and `object.zig` (an object's root, the
dispatcher), `symbols.zig` (the externs), `roc.zig` (modules, the glue
platform, the registry), `generate.zig` (the hashes and when glue runs);
`tools/roux/pipeline.zig` (the parallel object compiles). The branch is
on nightly-2026-10-04-130536d and Zig 0.17.0; its glue would need
`--no-cache` (roc-lang/roc#12139) once a second spec shares the cache.
DIARY on that branch, 2026-10-07 and 2026-10-08, has every step.
