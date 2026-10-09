# todo

## WIP

1. **Cook: a roux app deployed on the internet with nothing in front.**
   (owner, 2026-10-04) No dependencies, we own everything; one binary;
   TigerStyle; no compatibility with the old Roc API: the best platform we
   can build (owner, 2026-10-05).
   - Where it stands (2026-10-06): M4 first light (2026-10-05): a Roc hello
     app on fourneau, one static executable, handlers on fibers, the body
     effect, Roc leak counting per shard. Split into its own repository
     on 2026-10-06, building against `../fourneau` as a Zig package
     (DIARY). Next: the examples' spec as a Zig step (M4), then crt1/libc
     from Zig's musl. SQLite (M5) done 2026-10-06 (Plan, M5). HTTPS
     (2026-10-06): the host serves TLS 1.3 with a certificate from files
     or from ACME at startup, and redirects plain HTTP, all from its
     environment; the templates example ran so against Pebble. M10's app
     is live: the dragrace site, https://fourneau.y2kbugger.com/, a roux app with
     nothing in front, its own certificate, its races in roux's SQLite
     (2026-10-06; its database 2026-10-07; moved to lon1 the same day).

2. **Templates: rocstache in roux, no database yet.** (owner,
   2026-10-06) The template compiler (`rocstache-gen`, in the old fork)
   moved into roux's `tools/`, on Zig 0.17 and in TigerStyle; an example
   app rendering templates; the dragrace's templates workload runs it.
   - Where it stands (2026-10-06): rocstache-gen is in `tools/` (it
     built and passed its tests on Zig 0.17 unchanged), `Rocstache.roc`
     in the platform (its 19 expects pass on roux's nightly; `url` now
     encodes without the old fork's Url module), and
     `examples/templates` renders a page from `Page.rocstache`, escaped,
     at ~125k requests/s on this laptop. The dragrace's templates
     workload runs it (2026-10-06). Next: tidy over `tools/` (TigerStyle:
     the old code has no assertions and recursion), and the Zed README
     pointed here. Superseded by item 3, which replaces this compiler.

3. **Templates compiled by Zig, the Roc side only a contract.** (owner,
   2026-10-07) rocstache-gen writes a template's Roc type and a typed
   `render!` only; Zig compiles the template at comptime, so the `.roc`
   changes only when the contract does. Replace the current
   implementation, no side by side, streamlined; one compiled renderer
   in development and production, no interpreter. Goals: throughput
   under contention, and a save-to-screen loop as short as it can be.
   Every dev-server thought goes in [docs/dev-server.md](docs/dev-server.md)
   (on main).
   - Where it stands (2026-10-07): prototyped in a scratch copy (Menu:
     29,700 instructions in Roc, 4,280 in Zig; 188k against 112k req/s);
     roc's `output: Archive` linked by `zig ld.lld` in 40 ms, so a
     markup edit needs no roc. Built on the branch `templates`, then
     superseded by `templates-vm` (owner, 2026-10-08); the branch and its
     worktree deleted 2026-10-08, its head kept as the tag
     `archive/templates-comptime`, written up in
     docs/templates-comptime.md.

4. **Templates as bytecode, rendered by one VM in the host: the
   experiment against item 3.** (owner, 2026-10-08: "couldn't you
   optimize bytecode and render() to be FAR better than the roc code-gen
   style ... do the templates-vm on yet another worktree"; then "This
   Walker shit all seems like a bad idea ... a single renderer that
   compiles once"; "Remove walkers and use a constant VM in host")
   - Where it stands (2026-10-08, branch `templates-vm`, worktree
     `../roux-templates-vm`, on top of `templates`): the generated Roc
     walkers are gone (they were `16f3bdf`). One VM in the host runs every
     template, reading the boxed record at offsets `roc glue` gives
     (DESIGN.md, Templates). A pure Roc renderer that is not generated
     per template cannot exist (no reflection), so there was no pure
     variant to race. The examples and every page of the dragrace site (a
     scratch copy, ported) byte for byte the `templates` branch's. Menu:
     15,595 instructions a request (comptime 15,085, walkers 17,184);
     on dedicated cores (`dragrace adhoc race`, three rounds each)
     131k requests a second against 136k (comptime, -3.1%) and 127k
     (walkers, -6.3%). The site: 410 generated lines (was ~15,000), release build
     39 s (78; comptime 50), a Roc edit 1.1-1.2 s (2.0; comptime 1.3).
     The owner chose this branch (2026-10-08: "focus on the host VM,
     obviously"); the comptime one is written up in
     docs/templates-comptime.md. **The reread is built**: a markup edit
     rewrites the program file and signals the running app, which swaps
     the program in (hazard pointers), keeping its state and SSE streams:
     1.39 ms median save to page (88-111 with link and restart), each
     template's parse, contract and code kept between edits,
     production unchanged but a comparison a render (docs/dev-server.md).
     Merged into main 2026-10-09 with the Templates union (item 5), and
     fourneau-dragrace's competitor and site with it.
   - Decided (owner, 2026-10-08): a markup edit reloads the whole page
     (`location.reload()`); no morphing the page in place ("i dont wannt
     messs with morhphdin"). Scroll and focus are lost, as with any reload.
5. **The templates' night: fixes, then nothing sacred.** (owner,
   2026-10-09: "fix 1,2 ... 4 ok do experiments and if success if
   verified commit and take it"; "take one more high level design pass,
   treating NOTHING as sacred. can we do better with ergonomics or api??
   non effectful renderer even if tons more work? ... you have ALL
   night"). The index in `Page.roc` stays (owner: "3 sound dumbs ... do
   not do that"); no release-strip decision now. Serial: the fixes in
   Todo first, then experiments, each measured, written down, committed.
   First experiment: a pure `render` (hosted functions must be
   effectful, so `Page.render(ctx)` would return a value holding the
   effect, run by the platform when it sends; the host might then render
   straight into the response, no copy into a Roc list).
   - Where it stands (2026-10-09): the fixes done and committed (DIARY,
     2026-10-09). Design experiments, each on its own branch and
     worktree, each written up in that branch's DIARY; `page-union` merged
     (owner, 2026-10-09: "The union one is the one we will be merging
     in"), the others not:
     - `pure-render` (`../roux-pure-render`): `Page.render : Ctx ->
       Html`, pure, rendered as the response is sent; bodies `Bytes`,
       `Text`, `Html`. Works, every example and the site byte for byte;
       costs +1.4% instructions (Menu) to +10% (`/about`: Roc folds a
       constant context no more once a closure holds it).
     - `fixed-format` (`../roux-fixed`): `{{ x | fixed "1" }}`, an F64
       printed by the VM as Roc rounds; the site's chart dots -1.1% of
       the race page, byte for byte. Come back to it (owner, 2026-10-09):
       which other formatters belong in the host? (The site's `Format`:
       thousands grouping, `compact` 59.1k, latency; dates.)
     - `sse-frame` (`../roux-sse`): `Sse.Event.lines!` frames an event
       in the host, `Rocstache.patch!` makes a page a Datastar patch; the
       site's patch route -9.5%, byte for byte. Come back to it if roux
       decides to specialize on Datastar (owner, 2026-10-09).
     - `page-union`, merged: templates as data. roux writes the app's
       `Templates.roc` (the union of the contracts, and the layouts'
       identity) and each `X.template`; the host renders the value as a
       response is sent (DESIGN.md, Templates; DIARY 2026-10-09). A
       handler that only fills a template is pure and `roc test`
       compares its response. Free on Menu; `/about` +10% as written
       (Roc stops folding the context at compile time inside a tag),
       +2.5% with the response a top-level constant. Questions for the
       Roc team in the artifact "roux Template Shapes".
     - Found on the way, in the site (fourneau-dragrace `f379a25`, on
       main): log10 by bisection on `F64.pow` was a third of the race
       page; by its series now, -33%.


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

Done 2026-10-06 (owner: "do everything to implement SQLite in roux"):
the seven steps, and SQLite built with no OS code of its own; what is
left is in Todo. Migrations: not yet, by the owner's choice.

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
  - Last done: 2026-10-08 on this branch only (nightly-2026-10-06-c34079d,
    with fourneau-dragrace's `templates-vm` pin). `main`, fourneau-dragrace
    `main` and the skill's vendored Roc docs (which follow `main`'s pin)
    stay on 130536d until the branch merges: the nightly races `main`
    (owner, 2026-10-08: tonight's race runs untouched). The gotchas' and
    the known issues' re-check goes with that.
- **Roc glue**, with each nightly: regenerate `host/roc_platform_abi.zig`
  with `roc glue --no-cache` (roc-lang/roc#12139) and the matching
  `ZigGlue.roc` from the roc repository at the nightly's commit; build and
  run the examples. roux build lays the contracts out again by itself
  when `roc` changes. Compare Roc's keywords (src/parse/tokenize.zig,
  `keywords`, at the nightly's commit) with tools/rocstache/parse.zig's.
  - Last done: 2026-10-08 (c34079d: the spec unchanged, the glue
    identical once `zig fmt` has run over it, as tidy wants).
- **Vendored sources**, monthly and when a security release appears:
  `vendor/sqlite/` (sqlite.org/changes.html) once vendored.
  - Last done: never (not vendored yet).

## Todo

From the adversarial pass over the templates' dev and prod flow
(2026-10-09, owner: "take a serious adversarial pass ... be crazy cracked
and check everything"). Checked and holding: a 300 KB page (runs split
past 64 KiB, the heap growth past the shard's 256 KiB) byte for byte the
same over three requests and between `--dev` and release builds; cycles,
missing partials, nesting past 16, unclosed sections, bad names all
refused naming the template's line; the hazard-pointer swap. What it
found is done (DIARY, 2026-10-09: Roc's keywords refused; the app born
ignoring SIGUSR1; one key for the layouts; roc while glue runs, -21% a
contract change; failures named; the reread counter; the reload script
by `Sec-Fetch-Dest`; new directories watched; stale docs; the compiler
and the VM tested together), but:

- [ ] A `.rocstache` in a subdirectory of the app is no template
  (generation lists the app's directory only) and nothing says so, in
  `roux build` or `roux dev`. Refuse it, naming the file, or say it on
  the line. (2026-10-09)
- Not worth doing, measured: the render is not where a request goes. The
  host VM is 510 instructions a request behind comptime (15,595 against
  15,085) on a page whose request is all HTTP and Roc around it; the
  page's copy from the shard's buffer into Roc's list is one memcpy of
  the page (its share not measured). Release builds are roc's `--opt=speed` (glue 0 ms when warm);
  a markup edit is 1.39 ms. Superinstructions or writing straight into
  Roc's list would win under 1% for real complexity.

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
- [ ] Migrations (owner, 2026-10-06: "require a lot more thought"). Today a
  schema change needs a new database (`open!` refuses a schema that is
  not `schema.sql`'s). (2026-10-06)
- [ ] Live demos on the dragrace site (roux's examples, running). The
  database workload is done (conduit, 2026-10-07) and the site keeps its
  races in roux's SQLite. (2026-10-06)
- [ ] A simulated disk in fourneau's `sim_io` (torn writes, lost
  unsynced writes, fsync errors), so SQLite runs under the deterministic
  simulator through roux's VFS: crash, reopen, `integrity_check`, every
  committed transaction there. (2026-10-06)
- [ ] Group commit: FULL's promise (durable when answered) at a part of
  NORMAL's rate (295 against 9,285 writes/s, DIARY). `synchronous` is
  now the app's to choose in `Sqlite.open!`. (2026-10-06)
- [ ] A test of concurrent statements on one shard (fibers interleaving
  through the VFS's waits): the per-shard row buffer bug (DIARY,
  2026-10-07) was caught by the dragrace, not here. Also: roux-db should
  refuse a query whose row type shadows a builtin (`list` makes `List`).
  (2026-10-07)
- [ ] Several databases per app (owner, 2026-10-06), e.g. a durable
  queue beside the main data, with far more writes and different
  durability. Today: one (`open!` once, one `Database.roc`; the VFS takes
  four). A small plan:
  1. `Sqlite.open!` returns a handle per database; each has its own
     `db/` directory, `Database.roc` and generated modules, typed to it.
  2. Per database: its writer and write lock (a queue's writes never wait
     behind the main data's), reader pool per shard, heap share, and its
     own settings: a queue may take `synchronous=NORMAL` (9,285 writes/s
     against 295 here, DIARY) or group commit, while the main data stays
     FULL.
  3. A request holding two writers takes them in one fixed order (or is
     refused), so two requests cannot wait on each other.
  4. No atomic commit across two databases (SQLite: atomic per WAL
     file only): what must commit together stays in one database.
  (2026-10-06)
- [ ] Replication, Litestream or our own (owner, 2026-10-06). Why
  Litestream cannot just work (v0.5.17 checked, its db.go): it is another
  process that opens the database with its own SQLite connection,
  creates `_litestream_seq` and `_litestream_lock` in it, holds a read
  transaction so no one else checkpoints, takes the write lock to
  checkpoint itself, and reads the `-wal` file directly. roux's VFS keeps
  the WAL index in its own memory and an exclusive lock on the file, so
  another process can neither lock nor see; and `open!` refuses a schema
  with tables `schema.sql` lacks. Options: (1) the VFS speaks SQLite's
  cross-process protocol (a mapped `-shm` file, fcntl byte-range locks)
  and the schema check allows `_litestream_*`: Litestream as it is, at
  system calls per read transaction; (2) replicate in-process: the VFS
  sees every WAL frame and commit, so roux ships them (LTX-like) to S3
  itself, restore tool and all: we own it, a big job; (3) backups only,
  from the app (`VACUUM INTO`). (2026-10-06)
- [ ] Group commit: one fsync for many requests' transactions
  (savepoints in one transaction), if writes need more than the disk's
  ~300 commits a second. (2026-10-06)
- [ ] A data-only sync for the VFS (`fdatasync`): Evented's `fileSync` is
  a full fsync; io_uring's FSYNC takes `IORING_FSYNC_DATASYNC`. A change
  to fourneau's port (its `// fourneau:` patches), measured on writes
  first. (2026-10-06)
- [ ] SQLite's heap under eight shards: memsys5 has one mutex for every
  allocation. Measure contention on a race droplet (the laptop cannot
  load eight shards cleanly with the loader beside them), and the 4 MiB
  per connection `heap_bytes` assumes, by SQLite's high-water mark.
  (2026-10-06)
- [ ] The writer's lock is not FIFO: a waiter woken may lose to one
  arriving. Measure the spread of write waits under contention before
  doing anything (host/database.zig, WriterLock). (2026-10-06)
- [ ] A restart of an eight-shard roux right after it stopped failed
  half the time on the laptop (`roux: shard: SystemResources`, io_uring
  ENOMEM): the kernel frees a dead process's rings a moment after it
  exits, and two sets of eight 4096-entry rings did not fit the 8 MiB of
  locked memory (`ulimit -l`); four shards or fewer never failed (DIARY,
  2026-10-07). `roux dev` runs two (`ROUX_SHARDS`). Production restarts
  too: does the dragrace site's systemd restart hit it on the droplet?
  Measure the rings' locked memory; then a smaller ring, a retry at
  startup, or a higher `LimitMEMLOCK` in the unit. (2026-10-07)
- [ ] The templates' language server, for Zed: rocstache-gen had one
  (`rocstache-gen lsp`: diagnostics, hovers, completions) and went with
  it. Port it onto tools/rocstache (its diagnostics are roux build's),
  as `roux lsp`, and point the Zed extension (`../rocstache/zed`) at
  it. (2026-10-07)
- [ ] Recursion in tools/rocstache: the contract's walks and the
  comptime renderer recurse over the template tree (bounded: sections
  16 deep, partials 8). TigerStyle wants loops with explicit stacks; the
  comptime renderer cannot have one (each level's scope has another
  type). (2026-10-07)

## Tickler

### 2026-10-09

- roc-lang/roc#12120 (`x ? mapper` whose argument type does not fit
  segfaults `roc check`; filed 2026-10-06, owner: "Feldman is really on
  top of these"). Closed 2026-10-08 ("no longer reproduces"); checked
  2026-10-08: fixed on upstream main b8bc57a (both `? narrow` and
  `? |e| narrow(e)` report the mismatch), still segfaults on
  nightly-2026-10-06-c34079d, the newest. Waiting on a nightly. Then: try ~/devel/rocbugs/try-mapper-mismatch
  on the nightly that has it, take that nightly at the weekly Latest Roc
  chore, strike the gotcha in the roc skill and the row in
  compiler-bugs.md, update rocbugs' STATUS. roux has no workaround to
  undo (examples/sqlite's mapper is correct as written); if the fix also
  reports `{ id }` or record patterns better, nothing here depends on it.
  Not fixed: a comment on the issue only if something new was learned.
