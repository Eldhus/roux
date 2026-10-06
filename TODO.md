# todo

## WIP

1. **Cook: a roux app deployed on the internet with nothing in front.**
   (owner, 2026-10-04) No dependencies, we own everything; one binary;
   TigerStyle; no compatibility with the old Roc API: the best platform we
   can build (owner, 2026-10-05). SQLite waited for fourneau's base
   until the owner started it (2026-10-06; WIP 4).
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
   - Where it stands (2026-10-06): done: `Server.Config.static_dir`, served
     by the host before `respond!` (fourneau's site.zig), and
     `File.read_utf8!` (bounded, through the shard's `Io`);
     `examples/files` shows both, a file edited while the app runs shows
     on the next request. The glue regenerated with `roc glue` and
     ZigGlue.roc at the nightly's commit (unchanged platform first: byte
     for byte the committed file). Remove once the site runs on roux.

4. **SQLite in roux, designed from scratch: M5.** (owner, 2026-10-06)
   "Super tiger style": typed queries generated sqlc-style, as rocstache
   compiles templates; no migrations yet (they need more thought);
   measured at every step. Do not touch fourneau-dragrace (the owner is
   working on its site). The design and its steps: Plan, M5. The open
   decisions were taken as recommended (only generated SQL; one writer,
   refused to GET and HEAD; `synchronous=FULL`; the process owns the
   database file once our VFS lands; an exact schema match or no start;
   `roux-db`, `db/schema.sql`, `db/Module.sql` to `db/Module.roc`); the
   owner may overturn any.
   - Where it stands (2026-10-06): steps 1 to 6 done. SQLite 3.53.4
     vendored with one patch of ours; `tools/roux-db`; `host/database.zig`
     and `platform/Sqlite.roc`; `examples/sqlite`; roux's VFS over the
     shard's `std.Io` (SQLite's waits yield the fiber), readers pooled
     per shard. Measured (DIARY): point reads +16% over SQLite's own VFS;
     a shard's reads beside 100 commits a second at p99 0.3 ms where they
     were 3.8-6.8 ms. Next: step 7, static memory (memsys5, a fixed page
     cache); then `SQLITE_OS_OTHER` (no unix VFS compiled in).

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

Designed from scratch (2026-10-06), not ported: the old fork typed
expressions by reading SQL tokens, which the no-hacks rule forbids. The
shape:

- **One database per app**, opened by the host at startup
  (`Server.Config`; `ROUX_DATABASE` overrides the path).
- **Only generated SQL.** `roux-db gen` compiles `db/*.sql` to
  `db/*.roc` plus `Db.roc` (the schema and a numbered statement table);
  the host prepares every statement on every connection at startup and a
  call passes an index. No runtime SQL strings, no statement cache.
- **Types from SQLite, never from reading SQL**: `STRICT` tables only
  (`PRAGMA table_list`); result columns from SQLite's column metadata;
  `-- @param name : Type` on every parameter and `-- @column` on
  expression columns (SQLite cannot say); statements split by
  `sqlite3_prepare_v2`'s tail; statement kinds by the authorizer.
- **Read and write split by type**: `sqlite3_stmt_readonly` decides
  whether a generated function takes `Sqlite.Read` or `Sqlite.Write`.
- **Connections fixed at startup**: readers per shard (a reader is leased
  for one query; with a blocking VFS one per shard suffices), one writer
  for the process behind a FIFO futex lock with a bounded queue and wait
  (`WriterBusy`, 503); SQLite never sees two writers. A lease returns
  only with no transaction and no busy statement (asserted); a write
  still open when `respond!` returns is rolled back and answered 500.
- **No migrations**: a fresh database gets `schema.sql`; an existing
  one's `sqlite_schema` must equal what `schema.sql` makes, or the host
  refuses to start.
- **A limit on everything**: `:many(rows_max)`, result bytes, statement
  time (progress handler), every `sqlite3_limit`, PRAGMAs set and read
  back on every connection.

Steps, serial, each measured, written down and committed:

1. Vendor the newest SQLite amalgamation, pristine and pinned; built for
   the host (musl, PIC) and the tools with our options. Floors: SQLite
   alone (a point query, ns and instructions), the per-request
   alternatives (open+prepare+step, prepare+step, step), fsync physics.
2. `tools/roux-db`: the generator, TigerStyle and tidy from the first
   commit; a named test per refusal; golden outputs.
3. A SQLite patch, `sqlite3_column_nullable` (from the resolver's
   `EP_CanBeNull`), so outer joins type as nullable.
4. The host and `platform/Sqlite.roc`, `examples/sqlite`; the request
   handle made unforgeable first. Measured against a fourneau+SQLite
   floor (experiment 21).
5. The stall: a shard's plaintext p99 while writes commit, unix VFS.
6. Our VFS over the shard's `std.Io` (fibers yield on the disk; clock,
   randomness, sleep through `Io`), our mutexes; then `SQLITE_OS_OTHER`.
7. Static memory: memsys5 and a fixed page cache.

**Proves it:** `examples/sqlite` passes over a real listener, under load,
with the leak count and `integrity_check` holding; the numbers in the
diary. Later: a simulated disk in fourneau's `sim_io` puts SQLite under
deterministic simulation; group commit (savepoints in one transaction)
if the fsync floor calls for it.

### M6. Everything an app needs

Server-sent events (done 2026-10-06: `Sse`, `examples/sse`); multipart
uploads (streamed, through effects); `/_dev`; graceful shutdown
(fourneau serves the static files and compression). **Proves it:**
every example passes; the load test runs.

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
  - Last done: 2026-10-06 (new hosted function and config field; the
    spec from roc-lang/roc 130536d, src/glue/src/ZigGlue.roc).
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
- [ ] The host's 64-slot parameter array for a statement is `undefined`,
  which a safe build fills with 0xaa on every call: 2.3% of a point
  read's instructions (experiment 21). Size it to the call, or fill
  only what is used. (2026-10-06)
- [ ] A data-only sync for the VFS (`fdatasync`): Evented's `fileSync` is
  a full fsync; io_uring's FSYNC takes `IORING_FSYNC_DATASYNC`. A change
  to fourneau's port (its `// fourneau:` patches), measured on writes
  first. (2026-10-06)
- [ ] The writer's lock is not FIFO: a waiter woken may lose to one
  arriving. Measure the spread of write waits under contention before
  doing anything (host/database.zig, WriterLock). (2026-10-06)
- [ ] File the Roc segfault (`x ? mapper` with an argument type that does
  not fit): ~/devel/rocbugs/try-mapper-mismatch; the owner's call.
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
