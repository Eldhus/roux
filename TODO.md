# todo

## WIP

1. **Cook: a roux app deployed on the internet with nothing in front.**
   (owner, 2026-10-04) No dependencies, we own everything; one binary;
   TigerStyle; no compatibility with the old Roc API: the best platform we
   can build (owner, 2026-10-05). Do not integrate SQLite early: the base
   (fourneau) comes first.
   - Where it stands (2026-10-06): M4 first light (2026-10-05): a Roc hello
     app on fourneau, one static executable, handlers on fibers, the body
     effect, Roc leak counting per shard. Split into its own repository
     on 2026-10-06, building against `../fourneau` as a Zig package
     (DIARY). Next: the examples' spec as a Zig step (M4), then crt1/libc
     from Zig's musl. SQLite (M5) waits for fourneau's base. HTTPS
     (2026-10-06): the host serves TLS 1.3 with a certificate from files
     or from ACME at startup, and redirects plain HTTP, all from its
     environment; the templates example ran so against Pebble. Next for
     M10: a roux app on the internet (where: the owner's call).

2. **Templates: rocstache in roux, no database yet.** (owner,
   2026-10-06) The template compiler (`rocstache-gen`, in the old fork)
   moved into roux's `tools/`, on Zig 0.17 and in TigerStyle; an example
   app rendering templates; the dragrace's templates workload runs it.
   - Where it stands (2026-10-06): rocstache-gen is in `tools/` (it
     built and passed its tests on Zig 0.17 unchanged), `Rocstache.roc`
     in the platform (its 19 expects pass on roux's nightly; `url` now
     encodes without the old fork's Url module), and
     `examples/templates` renders a page from `Page.rocstache`, escaped,
     at ~125k requests/s on this laptop. Next: the dragrace's templates
     workload (its TODO); tidy over `tools/` (TigerStyle: the old code
     has no assertions and recursion), and the Zed README pointed here.

3. **What the dragrace site needs to run on roux.** (owner, 2026-10-06:
   the site becomes the roux demo; fourneau-dragrace's TODO, WIP 3)
   - Where it stands (2026-10-06): planned. Static files the app names in
     `init!`, served by the host before `respond!` (fourneau's loader:
     gzip, ETags, ranges); a `File` module with a bounded `read_utf8!`
     effect (new hosted functions: the glue regenerated). Next: both,
     with an example each.

## Plan

The road to a roux app on the internet with nothing in front of it.
Milestones in order, each ending in what proves it; one is planned in
detail only when it is reached. The numbers are shared with fourneau's
(its TODO, Plan): M0-M3, M7-M9 and M11 are the server's; M6 and M10 have
a half in each, and these are the platform's.

### Done

- M0-M3, the server: fourneau's TODO, Plan.

### M4. roux on fourneau: hello

The host in Zig (`host/`): the ABI from `roc glue`, the Roc allocator,
`init!`/`respond!`/`shutdown!` on fibers (an effect that waits yields its
fiber), the body effects, standard output and error, environment, time.
The platform's Roc modules, migrated and pruned.
**Proves it:** the spec passes for every example.

### M5. SQLite and the tools

`vendor/sqlite/`, the hosted SQLite functions, readers and the writer;
`roux` and `roux-db` migrated from the old fork to `tools/` (in Zig);
`rocstache-gen` is there already (2026-10-06). **Proves it:** the SQLite examples pass; an
app builds and runs.

### M6. Everything an app needs

Server-sent events; multipart uploads (streamed, through effects);
`/_dev`; graceful shutdown (fourneau serves the static files and
compression). **Proves it:** every example passes; the load test runs.

### M10. Deploy

A roux app on a public droplet, fourneau's TLS and ACME in front of
nothing. **Proves it:** a roux app on the internet, nothing in front.

### Then: the next version

Read the diary, keep the tests, delete what did not pay, write it again.

## Chores

- **Latest Roc**, weekly: a new nightly (github.com/roc-lang/nightlies)?
  Install it beside the others and follow the eldhus-maintenance skill
  (it moves `.roc-version` and fourneau-dragrace's pin together, refreshes
  the vendored Roc docs, re-checks the gotchas); regenerate the glue (next
  chore), build the platform and the examples, note it in the diary.
  - Last done: 2026-10-04 (nightly-2026-10-04-130536d).
- **Roc glue**, with each nightly: regenerate `host/roc_platform_abi.zig`
  with `roc glue` and the matching `ZigGlue.roc` from the roc repository at
  the nightly's commit; build and run the examples.
  - Last done: 2026-10-04 (first light, with the nightly above).
- **Vendored sources**, monthly and when a security release appears:
  `vendor/sqlite/` (sqlite.org/changes.html) once vendored.
  - Last done: never (not vendored yet).

## Todo

- [ ] The examples' spec (M4): requests and expected responses for each
  example, run over a real listener by a Zig build step. (2026-10-06)
- [ ] Build crt1.o and libc.a for the platform from Zig's own musl in
  `zig build platform`: for now they are copied from roc's test platform
  at the nightly's commit (Zig's cached libc.a lacked symbols the host
  needs), and `platform/targets` is not committed. (2026-10-05)
- [ ] Doubt (experiment 20): what the Roc boundary costs. hello.roc runs
  ~1,800 more instructions per request than fourneau-hello (3,700 against
  1,930 pipelined): response-head writing with per-byte header validation
  23% (fourneau's: its SIMD Todo), copying strings into Roc 10%; not the
  handler (`roc_respond_for_host` is 1.3%). (2026-10-05)
- [ ] Doubt (experiment 6): copying every request into Roc strings.
  Method, target and each header are allocated, copied, then freed: ~12%
  of the pipelined profile. Alternative: Roc strings pointing into the
  receive buffer, marked static (reference count 0, never freed), valid
  for the call. (2026-10-05)
- [ ] Doubt (experiment 8): the body is read through an `ArrayList`, then
  copied into a Roc list: two copies. Alternative: read straight into the
  Roc list, sized from `Content-Length` when there is one. (2026-10-05)
- [ ] ThreadSanitizer for the host: TSan's runtime does not support musl,
  which the host links. A glibc build of the host for testing only?
  (2026-10-06)
- [ ] TigerStyle for `tools/rocstache-gen` (owner: TigerStyle,
  data-oriented). Measured 2026-10-06 with tidy pointed at it: 212
  findings, 202 lines over 100 columns, 6 hidden indirections (the
  partial loader is `*anyopaque` plus a function pointer: make it a
  comptime parameter), 4 functions over 70 lines; and about 3 assertions
  in ~3,700 lines, `usize` throughout, recursion in the parser. Bring it
  to zero, then add the tree to `host/tests.zig` so tidy keeps it there.
  (2026-10-06)

## Tickler
