# Diary

What was done, measured and learned, in order. Newest last.

roux began inside one repository with fourneau: everything before
2026-10-06 is in [fourneau's DIARY.md](https://github.com/Eldhus/fourneau/blob/main/DIARY.md),
whose entries on the host, the Roc ABI and first light (2026-10-05) are
this platform's history too.

## 2026-10-06: roux gets its own repository

The owner made the Eldhus organization and asked for one repository per
thing. fourneau (the server, the simulator, the Evented port, the
benchmarks and research) left with its history; roux kept the platform and
its history, and lost the server's files in one commit.

The layout flattened: `roux/platform`, `roux/host` and `roux/examples` are
now `platform/`, `host/` and `examples/`. `build.zig.zon` depends on
`../fourneau` by path, and the host imports fourneau's exported modules
(`fourneau`, `zig_io_evented`, made position-independent for roc's PIE
link). tidy is fourneau's module; `host/tests.zig` names the host's tree,
and since a tree now lists its own interface files, host.zig's exemption
(the Roc ABI) lives here. The Roc-boundary experiments came along with
their numbers (EXPERIMENTS.md).

Checked: `zig build test` (tidy over the host) green; `zig build
platform` builds libhost.a; `roc build examples/hello.roc` links, and the
binary answers `curl http://127.0.0.1:8080/` with `hello`.

## 2026-10-06: the docs harmonized

The owner asked for one official stance per kind of document, kept in the
eldhus skill (`eldhus-way/references/docs.md`), and every repository
brought to it. The first pass here: the README's Build and License
sections; DESIGN's tools marked planned, the compiler named
`rocstache-gen`; PLAN says which milestones are shared; FEATURES links
fourneau's benchmark (the relative link was broken); EXPERIMENTS gained
the status line. Every CLAUDE.md got the same `## Always` lines.

## 2026-10-06: no CLAUDE.md

The owner wants nothing Claude-specific in the repositories. This
repository's CLAUDE.md is gone: what it said about this repository is now
the README's "Working on it", and what every repository shares is in the
one `~/devel/eldhus/CLAUDE.md` (eldhus-skill's `workspace/CLAUDE.md`,
symlinked), which Claude Code loads for any session started below it.

## 2026-10-06: a cleanup pass

Across Eldhus, at the owner's request. Here: the README tells roux's name
only (fourneau's and rocstache's are theirs); DESIGN marks the planned
modules and `vendor/sqlite/` as planned; PLAN gains Done and names
`rocstache-gen`; FEATURES points at the current measurements instead of
quoting the superseded six-core table; TODO loses its preamble and the
Roc chore follows the eldhus-maintenance skill; this diary opens in the
standard way.

## 2026-10-06: the settled experiments

EXPERIMENTS.md keeps only what is open; a settled entry is a one-line
stub, its conclusion in DESIGN.md (the docs stance, owner 2026-10-06).
Here are the settled entries as they stood, verbatim:

13. **No leak checking of the server.** (settled 2026-10-05: the host
    runs shared-nothing shards and counts Roc allocations per thread; when
    a shard has no request in flight it asserts it holds what it held at
    start. On in every build. 3.1M requests, `/echo` with headers and a
    300 KB body: no leak. An injected leak (the response never released)
    crashes on the first request. The first run caught a hole in the
    counting itself: the glue's lists and strings allocate through the
    `RocHost` table, not the exported `roc_alloc`; both now reach one
    counted function.) The simulator's tests use
    `std.testing.allocator`, which checks leaks, but the server allocates
    nothing per request, and the Roc path's allocations (strings, lists,
    the context box) are never counted. Experiment: count roc_alloc and
    roc_dealloc per request in a test host; zero net per request. With
    shared-nothing shards the count is per thread: no contended atomic, so
    it can stay on in production as an assertion (a shard with no request
    in flight holds no Roc allocation beyond the app's context). The
    glue's reference counts are atomic, so the shared context box is
    sound across threads already.

19. **Request arenas for Roc memory.** (settled 2026-10-05: rejected for
    now. A per-shard LIFO pool of bump arenas, freed whole at release.
    On hello.roc: instructions per request equal to SmpAllocator's (whose
    thread-local free lists are already cheap), user cycles -3% in two
    rounds of three, L1 misses up 50%; and the current arena must follow
    fiber switches, a place for subtle bugs. Code in history: the commit
    "experiment: request arenas for Roc memory".
    Retry with an app that allocates heavily.)

## 2026-10-06: PLAN.md and EXPERIMENTS.md fold into TODO.md

The owner: there is no real distinction between experiments, plan and
todo. The milestones are TODO's Plan section, without status (status is
WIP's); each open experiment is a Todo item, "Doubt (experiment N)",
keeping its number (the settled ones are in the entry before this one;
the performance-pass Todo was the same three doubts and is gone). The two
files, as they stood, verbatim:

### PLAN.md

### Plan

The road to a roux app on the internet with nothing in front of it.
Milestones are in order and each ends in something that proves it; one is
planned in detail only when it is reached. The numbers are shared with
fourneau's PLAN.md (the two were one plan until 2026-10-06): M0-M3, M7-M9
and M11 are the server's alone; M6 and M10 have a half in each repository,
and this file describes the platform's. Where the work stands is in
[TODO.md](TODO.md).

#### Done

- M0-M3, the server: fourneau's PLAN.md.

#### M4. roux on fourneau: hello

The host in Zig (`host/`): the ABI from `roc glue`, the Roc allocator,
`init!`/`respond!`/`shutdown!` on fibers (an effect that waits yields its
fiber), the body effects, standard output and error, environment, time.
The platform's Roc modules, migrated and pruned.
- First light 2026-10-05 (fourneau's DIARY): `roc build` of `hello.roc`
  gives one static binary that answers `curl`; Roc handlers on fibers; the
  body effect works; leak counting per shard.
- Left: the examples' spec (requests and expected responses, run by a
  Zig step over a real listener); crt1.o and libc.a built here.

**Proves it:** the spec passes for every example.

#### M5. SQLite and the tools

`vendor/sqlite/`, the hosted SQLite functions, readers and the writer;
`roux`, `roux-db` and `rocstache-gen` (the template compiler), migrated from the
old fork to `tools/` (in Zig). **Proves it:** the SQLite examples pass; an
app builds and runs.

#### M6. Everything an app needs

Server-sent events; multipart uploads (streamed, through effects);
`/_dev`; graceful shutdown (fourneau serves the static files and
compression). **Proves it:** every example passes; the load test runs.

#### M10. Deploy

A roux app on a public droplet, fourneau's TLS and ACME in front of
nothing. **Proves it:** a roux app on the internet, nothing in front.

#### Then: the next version

Read the diary, keep the tests, delete what did not pay, write it again.

### EXPERIMENTS.md

### Experiments

What I do not like about what exists, written down adversarially, each
with the experiment that would settle it. Be in love with nothing:
benchmark, break and replace (owner, 2026-10-05). Results go to DIARY.md;
a settled experiment leaves a one-line stub here, its conclusion in
DESIGN.md (or deleted with the code it judged) and its full text and
numbers in DIARY.md.

Status: **open**, **running**, **settled** (with the date and the verdict),
**moved** (to another repository, with the date). Numbers are never
reused.

These are the Roc boundary's, moved from fourneau's EXPERIMENTS.md when
the repositories split (2026-10-06), with their numbers kept so the
diaries' references still hold. The rest are the server's, in fourneau.

6. **Copying every request into Roc strings.** (open) Method, target and
   each header are allocated and copied, then freed: ~12% of the
   pipelined profile. Alternative: Roc strings pointing into the receive
   buffer, marked static (refcount 0, never freed), valid for the call.
8. **The body read through an `ArrayList`, then copied into a Roc list.**
   (open) Two copies. Alternative: read straight into the Roc list, sized
   from `Content-Length` when there is one.
13. **No leak checking of the server.** (settled 2026-10-05: every shard
    counts its Roc allocations, asserted in every build; DESIGN, The
    host.)
19. **Request arenas for Roc memory.** (settled 2026-10-05: rejected for
    now; DESIGN, The host. Retry with an app that allocates heavily.)
20. **What the Roc boundary costs.** (open) hello.roc runs ~1,800 more
    instructions per request than fourneau-hello (3,700 against 1,930
    pipelined). Measured parts: response-head writing with per-byte
    header validation (23%), copying strings into Roc (fromSlice +
    memcpy, 10%). Not the handler: roc_respond_for_host is 1.3%.

## 2026-10-06: templates

The owner asked for templates in roux (no database yet). The old fork's
`rocstache-gen` (3,725 lines of Zig 0.16: parser, shape inference,
emitter, `{{% %}}` blocks, formatters, the language server) is
`tools/rocstache-gen/`, without its `rocstache dev/build` front end
(`roux`, planned, takes that role). On Zig 0.17 it built and passed its
tests with no change. `Rocstache.roc` (escaping, formatters) is a
platform module; it imported the old fork's `Url` for one formatter,
which now has its own percent-encoder; its 19 expects pass on
nightly-2026-10-04-130536d.

`examples/templates`: a menu rendered from `Page.rocstache` per request.
The page escapes `<menu>`, quotes and `&`; an unknown path is 404; oha
(32 connections, 5 s, 8 shards, laptop) 125,359 requests/s, all good.
`zig build examples` regenerates the committed `.roc`.

Not yet TigerStyle: the compiler has no assertions, `usize` throughout
and recursion; tidy does not look at `tools/` yet (TODO).

## 2026-10-06: HTTPS for roux apps

fourneau's certificate and redirect code moved into its `https.zig`, which
the host now uses: the deployment's environment says HTTPS
(`ROUX_TLS_CERT`/`ROUX_TLS_KEY`, or `ROUX_ACME_*` to obtain a certificate
at startup, and `ROUX_REDIRECT_PORT`). `examples/templates` with Pebble:
the host obtained a certificate for 127.0.0.1 before its shards started,
served the escaped menu over TLS 1.3 on 8 shards (curl verifying through
Pebble's root), and redirected plain HTTP to it. The static musl binary
does ACME with Zig's `std.http.Client`.

## 2026-10-06: static files and file reads

For the dragrace site to run on roux (owner: the site becomes the demo).
`Server.Config` gains `static_dir`: the host loads it at startup with
fourneau's site.zig (moved out of fourneau-static for this) and serves
its files before `respond!`. `File.read_utf8!(path, limit)` reads a whole
file through the shard's `Io`, so a fiber waiting on the disk yields;
not UTF-8 is `FileUnreadable`, past the limit `FileTooLarge`.

Both cross the boundary, so the glue was regenerated: `roc glue
ZigGlue.roc OUT main.roc`, the spec from roc-lang/roc at the nightly's
commit. Regenerated from the unchanged platform first, it matched the
committed file byte for byte; then the new fields and result types
appeared, nothing else. `examples/files`: style.css from `public/`, the
notes read per request (an edit shows at once), a missing file and an
oversized one as 500 with the typed error logged.

## 2026-10-06: server-sent events

For fourneau-dragrace's new SSE workload (a Datastar action) and M6.
`Sse` is effects on the handler's fiber: `start!(request, headers)`,
`send!(stream, event)`, `flush!`, `end!`, which returns
`Server.streamed` for `respond!` to return. Each is a call into
fourneau's new streamed responses (its DIARY). basic-webserver's `Sse`
keeps a state machine (`Sse.unfold!`) that its host advances between
wakes; a roux handler is already on its own fiber, so it simply waits
where it is. `Sse.Event.named` refuses a type with a line break, and
data's lines become `data:` lines (CRLF and CR too). `Url.query_value`
form-decodes a query value (a three-state walk over the bytes; `%` with
no two hex digits after it, or bytes that are not UTF-8, is
`BadEncoding`).

The host trusts the app with none of it: each effect asks fourneau
where the stream is (`Request.stream_state`, new) and refuses what is
out of order (`Refused`); an event over 64 KiB is refused; a body read
after the start is the new `BodyAfterStream` (its 100 Continue would be
a second head); whatever `respond!` returns once a stream started is
ignored, and `Server.streamed` without one is a 500. `examples/sse`
shows each by curl: a stream, one cut short by an error (curl: exit 18,
the transfer closed mid-body), the body after the start, a send after
the end, the marker without a stream, a HEAD, and the next request on
the same connection after a stream. The glue regenerated with
ZigGlue.roc at the nightly's commit (from the unchanged platform first:
byte for byte the committed file).

A bug found on the way, in the existing code too: the host made
fourneau's response headers from Roc's with a by-value loop capture,
`|roc_header, *header|`, then `roc_header.name.asSlice()`. `asSlice`
takes `*const RocStr`, and a small string's bytes live inside the
struct, so the slice pointed into the loop's copy. In `handle` it had
worked by luck of code generation; the stream's head came out as
garbage and was refused. Both loops now capture by pointer.

The tests, tested: three bugs put into `Url` (a hex digit off by one,
an escape appending the `%` instead of decoding, a lone `%` accepted),
each failed two or three of its expects.

## 2026-10-06: SQLite, step 1: vendored, built, floors measured

The owner started M5 (TODO, WIP 4): SQLite designed from scratch, typed
queries generated as rocstache compiles templates, no migrations yet,
measured at every step. Step 1 is SQLite itself.

`vendor/sqlite/`: the 3.53.4 amalgamation (`sqlite3.c`, `sqlite3.h`),
pristine, the zip's SHA3-256 checked against sqlite.org's download page
(README there). `sqlite/options.zig` holds the compile-time options, each
with why (`THREADSAFE=2`, `DQS=0`, no extensions, no mmap, temporary
storage in memory, column metadata for the generator, `HAVE_USLEEP`,
`HAVE_FDATASYNC`, ...); `sqlite/c.zig` the C API roux calls, by hand. The
`zig build test` suite now asserts SQLite reports each option and runs
with SQLite's own assertions (`SQLITE_DEBUG`) and C undefined-behaviour
traps. The test was tested by its first run: SQLite reports
`DEFAULT_FOREIGN_KEYS` and `STRICT_SUBTYPE` without their values, so the
check failed until each option named how SQLite reports it.

`sqlite-floor` (sqlite/floor.zig, `zig build sqlite-floor`, the host's
safe mode): a point query on a 10,000-row STRICT table in WAL mode, on
btrfs on the laptop's NVMe (Samsung 970 EVO Plus), pinned to one CPU,
three interleaved rounds, `perf stat -e instructions:u` (identical every
round), time as the median. Load 0.65 with a browser and an editor open:
the instructions are the numbers to trust.

| per point query | instructions | time |
|---|---:|---:|
| step (prepared once: bind, step, read, reset) | 4,774 | 1.35 us |
| prepare + step + finalize | 22,832 | 3.9 us |
| a new connection + prepare + step (2 tables) | 112,961 | 41 us |
| the same, a schema of 20 tables | 798,929 | 152 us |

So a connection per request costs 24 times a pooled, prepared query with
a toy schema and 167 times with twenty tables (the schema is parsed by
each new connection), and preparing per request 4.8 times: connections
and statements are made at startup and kept (the design, TODO M5).

`sqlite-floor fsync`: a 4 KiB write and fdatasync, 2,000 times, three
runs: p50 3.1 ms, p99 6.2-6.5 ms, max 9.5-35.7 ms. One writer with
`synchronous=FULL` commits at most ~320 times a second on this disk, and
with SQLite's own VFS each commit holds its shard's thread for those
milliseconds: step 5 measures that stall, and group commit (savepoints in
one transaction, one fsync for many requests) moves up the list.

A/B, the same three interleaved rounds:

- Undefined-behaviour traps in SQLite's C (`-fsanitize-c=trap`): 7,944
  instructions against 4,774 (+66%), 1.75 against 1.40 us. On in the
  tests, off in the host and the floor; set explicitly in build.zig.
- `THREADSAFE=2` against 0: 4,774 against 4,320 instructions (+10.5%),
  time within noise. Kept (shards are threads and SQLite's allocator and
  page cache are global); our own mutexes (step 6) may win it back.

A slip: `zig fmt host` reformatted the generated `roc_platform_abi.zig`;
caught by `git status` and restored before anything was built on it.
Format only the files edited, never a directory holding generated code.

## 2026-10-06: SQLite, step 2: roux-db, typed queries generated

`tools/roux-db` (`zig build tools`): `roux-db gen DIR` compiles DIR's
`schema.sql` and `Module.sql` files into `Module.roc` each and
`Database.roc`, as rocstache-gen compiles templates: committed beside
their source, every generated function naming its SQL line, `roc fmt`
stable (checked with the pinned nightly: `Database.roc` and the modules
come out of `roc fmt` unchanged).

How it knows, with SQLite as the only reader of SQL:

- `schema.sql` runs into an in-memory SQLite. Each statement must create
  something (SQLite's authorizer says what a statement does:
  `sqlite/authorizer.zig`), and a table must be STRICT
  (`pragma_table_list`), so a column's declared type is what it holds.
- A query file is split where `sqlite3_prepare_v3` ends a statement. The
  comments before it are scanned by SQLite's own rules for what may
  precede a statement, and two assertions hold the scan to SQLite: the
  stretch skipped prepares to nothing, and the statement's text prepares
  alone to one whole statement.
- Annotations (`-- name: q :one|:many(N)|:exec`, `-- @param`,
  `-- @column`) say only what SQLite cannot: a parameter's type, an
  expression column's. A result column from a table is typed by its
  declaration there; an annotation may narrow it (NOT NULL, Bool) but
  not change its storage class.
- A query may only read and write rows: transactions, PRAGMAs, ATTACH,
  DDL are refused by the authorizer, as roux's (one policy, shared with
  the host). Parameters are `:name` only.
- `sqlite3_stmt_readonly` decides whether a function takes `Sqlite.Read`
  or `Sqlite.Write`.

Learned on the way:

- `pragma_table_xinfo` runs a PRAGMA inside SQLite when stepped, which
  the query policy refused: the authorizer now comes off right after
  each prepare (only the prepare's verdict matters).
- A WITHOUT ROWID table's key adds an index of SQLite's own to the
  CREATE TABLE's actions, so "creates exactly one" became "creates".
- In a STRICT table every key column is reported NOT NULL except the
  rowid's alias (INTEGER PRIMARY KEY), which is never NULL anyway: a key
  column is never nullable, and the lookup of rowid aliases I first
  wrote went (subtract first).
- SQLite's run of spaces begins with tab, newline, form feed, carriage
  return or space and continues through any `isspace` byte, vertical tab
  included. The scan first stopped at a vertical tab after a newline, so
  a statement's text began with a byte the host would refuse; the new
  whole-statement assertion catches any such disagreement.
- A slip: a commit went in with a failing test (`;` instead of `&&`
  after the test run); fixed in the next commit. Chain the commit on the
  tests passing.

Tests (`zig build test`): the golden directory `tools/roux-db/testdata`
(regenerated by roux-db itself, `@embedFile`d and compared), the rules
of nullability, whitespace, and thirty-one refusals by name. Tested by
mutation, each poked into the committed code and reverted: key columns
made nullable, PRAGMA allowed in a query, the nullable helpers dropped,
vertical tab not continuing spaces, STRICT not checked, positional
parameters allowed: all six caught. Generation of the testdata
directory takes ~2.4 ms.

The generated code calls a platform API that does not exist yet
(`Sqlite.Read`, `run_read!`, `Param`, `Cell`, ...): step 4 makes it, and
`roc check` on an example proves the two fit. The database is opened by
an effect in `init!` (`Sqlite.open!(Database.at(path))`), not through
`Server.Config`: a new config field would break every app's config
record, the dragrace site's among them.

## 2026-10-06: SQLite, step 3: our patch, sqlite3_column_nullable

Column metadata gives a result column's origin table and column, and
roux-db typed it by that column's NOT NULL. Wrong in three places, each
found by reading `columnTypeImpl` and the resolver rather than by luck:
the inner side of an outer join (LEFT, RIGHT, FULL), a scalar subquery
(no row is NULL, yet it reports its column as origin), and a compound
select (typed from its left-most arm; another arm may give NULL).

The patch (vendor/sqlite/README.md, the commit on the pristine copy):
`sqlite3_column_nullable(stmt, N)`, 1, 0 or -1 for an expression SQLite
cannot prove never NULL. It follows `columnTypeImpl`'s path through
subqueries and views, reads the resolver's own `EP_CanBeNull` mark,
treats a scalar subquery as nullable and ORs every arm of a compound;
stored as a sixth column-name slot. roux-db now takes a column's
declared type from `sqlite3_column_decltype` and its nullability from
the patch, so its `pragma_table_xinfo` lookup went.

Tested on thirteen shapes (inner, left, right, full and reversed joins;
a view over a left join; a subquery in FROM; a scalar subquery; a CTE;
compounds with a literal, with NULL, and with a left arm alone
nullable), each run on rows built so every outer join meets a row with
no partner: the types are as expected, a column typed never NULL never
is, and each one typed nullable is NULL in some row. By mutation: the
outer-join mark ignored, and a scalar subquery taken as never NULL,
were caught; reading the right-most arm only survived (every compound
shape's right arm decided alone) until the shape with a nullable left
arm was added, then caught.

Cost (sqlite-floor, three interleaved rounds against the pristine
build): stepping a prepared point query unchanged, 4,774 instructions;
preparing one 23,465 against 22,832 (+2.8%), paid at startup only.

## 2026-10-06: SQLite, step 4: the host and `Sqlite`, examples/sqlite

`host/database.zig` keeps the app's one database without knowing Roc
(rows go to a sink passed at compile time), so its tests are Zig alone
(`host/database_test.zig`, seven, in `zig build test`). `Sqlite.open!`
in `init!` opens it: the writer, every option, limit and PRAGMA set and
read back, the schema created on a new file or compared row by row with
what `schema.sql` makes (no migrations yet: a schema changed by one
space does not open), every statement of `Database.roc` prepared on each
connection that runs it and checked against what SQLite says of it,
under the same authorizer policy roux-db used. Each shard opens its own
reader as it starts, and a buffer of rows sized by the largest
`rows_max`: a Roc list of refcounted items records its length when it
is allocated, so rows are collected first, then copied into a list of
exactly their number, and a row cut short by an error is filled with
NULLs before it is released.

`platform/Sqlite.roc`: `open!`, `read`, `write!`, `commit!`, `reading`
(reads inside the transaction), and for generated code `run_read!`,
`run_write!`, `Param`, `Cell` (a cell of another kind than its column's
is a crash: the host checked every cell). `Nullable(a)` is a structural
`[Null, NotNull(a)]`. The writer busy past its wait is `DbErr(WriterBusy)`,
answered 503 by `error_status`.

Decided while building it:

- The database is opened by an effect in `init!`, not a `Server.Config`
  field: a new field breaks every app's config record, the dragrace
  site's among them.
- A transaction still open when `respond!` returns is rolled back. A
  success answer then becomes 500 (what it did was undone); an error
  answer stays, so a constraint the handler turned into a 400 is a 400.
  First built as "always 500", which made every constraint a 500.
- Reading the body or starting a stream while holding the writer is
  refused (`BodyDuringWrite`, a new `Server.BodyErr` tag; `StreamRefused`).
- Request handles were the request's address, which an app can forge
  (`Server.Request` is a plain record); now a slot and a generation in a
  per-shard table (`host/requests.zig`), checked by every effect, the
  body and stream effects included. Tested: handles an app could make,
  a pointer among them, find nothing.

examples/sqlite (dishes and reviews), checked with curl on a fresh
database: a dish added (201), found (200), missing (404), a non-number
id (400); a taken name, a price of 0, a review of a dish that is not
there, five stars out of range: each a 400 naming the constraint
SQLite gave, and rolled back; a rename onto a taken name refused, the
old name kept; `Sqlite.write!` on a GET 500 (`WriteRefused`); a write
never committed rolled back and 500, the dish absent after; the body
read while holding the writer `BodyDuringWrite`; the outer join's
average NULL for a dish with no reviews. The other examples still pass
their routes (hello's echo, sse's stream and `BodyAfterStream`).

Under the checked heap (`-Dhost-heap=checked`) with oha (32
connections, 5 s each, server on CPUs 0-1): point reads (217,416
responses), the 50-row join (24,722), concurrent writes (81,049): no
fault, every answer 2xx, the per-shard leak assertion held. The review
count afterwards was 16 more than oha's 201s: requests in flight when
oha's clock stopped. An exact count needs a fixed number of requests.

A Roc compiler crash on the way: `roc check` segfaulted on the example.
The cause was my code: an error mapper (`? constraint_as_bad_request`)
that took `[DbErr(..)]` where `add!`'s error also has `NotFound`; the
compiler crashes instead of reporting the mismatch. Minimized to twelve
lines in ~/devel/rocbugs/try-mapper-mismatch, not filed (the owner's
call); with it, two more gotchas for the roc skill: `{ id }` is a block,
not a record, and a record pattern names every field or ends in `..`.

## 2026-10-06: experiment 21, what a database request costs across Roc

`roux-db-floor` (host/floor.zig, `zig build db-floor`): examples/sqlite's
three workloads on fourneau and the host's own database.zig, the answers
formatted in Zig, no Roc; the same database file (its schema embedded
from the example's, byte for byte). Against examples/sqlite on the same
file (50 dishes, 500 reviews, btrfs on the NVMe). Server on CPUs 0-1 (2
shards), oha on 2-7, 2 s warmup, 10 s measured, three rounds
interleaved, `perf stat -e instructions:u -p` over the measured run,
user and kernel time from /proc/stat on CPUs 0-1 (the scratchpad's
bench.sh; the method is the benchmarking skill's). The laptop quiet
(load 1.1, no other load; a dragrace session's local race had just
ended).

| per request, median of 3 | roux | floor | roux - floor |
|---|---:|---:|---:|
| point read `GET /dishes/7`, 64 conns: req/s | 131,485 | 163,824 | -20% |
| instructions (user) | 19,023 | 11,399 | +7,624 |
| user / kernel ns | 5,725 / 9,474 | 3,194 / 9,145 | |
| 50-row join `GET /`, 64 conns: req/s | 5,761 | 6,301 | -9% |
| instructions (user) | 1,386,801 | 1,262,352 | +124,449 (2.5k a row) |
| write `POST /reviews`, 16 conns: req/s | 298 | 299 | |
| instructions (user) | 44,871 | 30,830 | +14,041 |

Instructions were identical round to round (within 0.5%); req/s varied
by 10%. The point read is 63% kernel in both: HTTP on loopback. Where
roux's extra 7,600 go (`perf record -e instructions:u`, flat): the
app's own routing and strings (`Str.concat` 7.5%, `split_on` 1.6%,
`I64.from_str` 1.2%), Roc's heap (SmpAllocator alloc and free 6.8%),
copying into Roc (`RocStr.fromSlice` 3.6%, memcpy 3.9%), and 2.3% for a
0xaa fill: the host's 64-slot parameter array is `undefined`, which a
safe build fills on every call (TODO). The top symbol, 7.7%, is
fourneau's head parser (`findScalarPos` under `http1_head.parse`),
shared with the floor.

Writes are the disk's: ~300 a second for both in the first rounds (the
fdatasync floor of 3.1 ms allows ~330), ~150 in the third, as the WAL
grew on btrfs; p99 0.1 to 0.7 s; the floor's second round had 11
writers past their 1 s wait (503). Each commit cost 350-500 us of
kernel CPU on the server's cores: btrfs's fsync is CPU too, not only
waiting. With SQLite's own VFS that wait holds the shard's thread: step
5 measures what it does to the reads beside it.

## 2026-10-06: SQLite, step 5: a commit stalls its shard

One shard (CPU 0), examples/sqlite; reads of one dish at a fixed 1,000
a second for 10 s (oha `-q 1000 -c 4`, CPUs 2-5), alone, then beside
writes at a fixed 100 a second (`-q 100 -c 4`, CPUs 6-7); three rounds,
`synchronous=FULL` (the host's) interleaved with a `NORMAL` build made
from a temporary edit (reverted at once). btrfs on the NVMe, the laptop
quiet (load 0.7). The scratchpad's stall.sh.

| reads | p50 | p99 | p99.9 | max |
|---|---:|---:|---:|---:|
| FULL, alone | 0.12 ms | 0.24-0.31 ms | 0.5-1.8 ms | 2.3-3.2 ms |
| FULL, beside writes | 0.14 ms | 3.6-6.7 ms | 6.5-16 ms | 9-29 ms |
| NORMAL, alone | 0.12 ms | 0.25-0.29 ms | 0.4-1.6 ms | 2.9-4.6 ms |
| NORMAL, beside writes | 0.12 ms | 0.25-0.29 ms | 1.7-4.7 ms | 16-17 ms |

With SQLite's own VFS a commit's fdatasync (~3 ms here) holds the
shard's thread, and every read that arrives meanwhile waits behind it:
at 100 commits a second, 30% of the shard's time, and the reads' p99
grows fifteen times. NORMAL skips the sync per commit, but a checkpoint
still syncs, and the reads beside it wait 16-17 ms. Neither is the
answer: the wait must yield the fiber, not the thread. That is step 6,
a VFS over the shard's `std.Io` (io_uring), measured against these
numbers. `synchronous` stays FULL.

## 2026-10-06: SQLite, step 6: roux's VFS, SQLite's files through `std.Io`

`sqlite/vfs.zig`, registered as SQLite's default by `sqlite.initialize`:
SQLite's files through the calling thread's `std.Io` (`vfs.thread_io`:
the host's startup thread sets the Threaded one, each shard its Evented
one), so on a shard a read, a write, a sync that waits on the disk
yields its fiber. One process owns the database: the five-level file
locks and the WAL index's eight locks are in memory, the index in heap
regions (64 of 32 KiB, zero pages until used, no `-shm` file); the
first open takes an open file description lock on the whole file, which
conflicts with every lock SQLite's own VFS takes, so the `sqlite3` shell
gets "database is locked" while a roux app runs (checked). Randomness
(`getrandom`) and the clock (the vDSO) never yield.

Yielding inside SQLite is safe only when the thread holds no SQLite
mutex, or another fiber on the thread could block it on itself:
`sqlite/mutex.zig` wraps SQLite's own mutexes (initialize, shut down,
read the defaults, install the wrapper, initialize again: sqlite3_config
is refused while initialized) to count them per thread, and every VFS
call that may yield asserts the count is zero. The assertion was tested
by mutation: randomness put on the yielding path fired it at once —
SQLite asks for randomness holding its PRNG mutex, which is why
randomness is a system call. `SQLITE_STMTJRNL_SPILL=-1`: no temporary
files.

What the first measurement found, in order:

1. The stall test aborted at once: "a reader is entered by one fiber at a
   time", the assertion written for SQLite's own VFS, under which one
   reader per shard was enough. A read can now yield mid-statement (a
   page the writer just committed comes from the WAL file), and another
   fiber of the shard needs a reader. So: `ReaderPool`, four readers a
   shard (1 MiB of cache each), leased a statement at a time; none free,
   a bounded wait (`ReadersBusy`, 503).
2. Point reads were then 22% slower than on SQLite's own VFS (139k
   against 109k req/s; kernel time +2.9 us a read). Counting VFS calls
   per statement (`vfs.calls`, printed by sqlite-floor) showed one
   `xFileSize` per read transaction: on Evented a ring round trip and a
   fiber switch. One process owns the files, so only its own writes and
   truncates change their sizes: the VFS keeps them (read once at the
   first open), and a size costs nothing; in tests every size is checked
   against the file's (a mutation that forgot a write's growth was
   caught). sqlite-floor's point query: 1,350 ns (SQLite's VFS), 785 ns
   (ours, sizes from fstat), 565 ns (sizes kept). But the server's
   numbers did not move.
3. The cause was the pool: every release woke a waiter with
   `futexWake`, which Evented submits to the kernel at once, waiter or
   not. Now a release wakes only when a fiber waits (and the writer's
   lock likewise; its count and state are sequentially consistent so no
   release misses a waiter about to sleep).

Measured, examples/sqlite on SQLite's own VFS (a build from before this
step) against roux's, the same file reseeded to 50 dishes and 500
reviews, CPUs 0-1, three interleaved rounds (bench_ab.sh, stall.sh):

| | SQLite's VFS | roux's VFS |
|---|---:|---:|
| point read, req/s (median) | 125,130 | 145,284 (+16%) |
| instructions, user | 19,021 | 18,681 |
| user / kernel ns | 5,898 / 9,947 | 5,181 / 8,650 |
| 50-row join, req/s | 5,724 | 5,509 (-4%; more kernel time, 20 against 14 us) |
| writes, req/s (16 conns) | 293-296 | 297 |
| writes, p99 | 174-343 ms | 69-128 ms |
| reads beside 100 writes/s, p99 (one shard) | 3.8-6.8 ms | 0.26-0.32 ms |
| the same, max | 13-31 ms | ~3 ms |

The stall is gone: a shard keeps serving while its commit waits on the
disk. A write costs ~10k instructions more (55k against 45k): the ring,
the pool, a full fsync where SQLite's VFS did fdatasync (Evented's sync
is fsync; a data-only sync would be a change to fourneau's port, TODO).

Mistakes on the way, and their rules:

- Three servers of mine kept running after their runs (`$!` taken in a
  subshell named the subshell, not the server; and a whole command chain
  sent to the background). One held the benchmark database open, idle,
  through experiment 21 and step 5: the same for both sides of each
  comparison, so the comparisons stand. Rule: start a server with `exec`
  in its subshell, kill it by its own PID, and list what is left
  listening after every run.
- Write runs grew the benchmark's reviews from 500 to ~30,000, so a
  later join measured 45 M instructions where the first measured 1.4 M.
  Rule: reseed the database before a comparison that reads it.
- `zig fmt host/*.zig` reformatted the generated glue again (restored at
  once). Format files by name.
- Deleting cached test binaries left Zig's cache pointing at nothing
  ("checking cache failed"); the local `.zig-cache` was removed and
  rebuilt (10 s; SQLite's object came from the global cache).

## 2026-10-06: SQLite, step 7: SQLite's memory, one heap made at startup

`SQLITE_ENABLE_MEMSYS5`, and `sqlite.initialize_with(.{ .heap })`: the
host allocates SQLite's whole heap before `init!` runs (raw pages,
untouched until used), sized by `database.heap_bytes(shards, limits)`,
an itemised sum: the writer's cache, every reader's cache, 4 MiB per
connection for schema, statements, lookaside and a statement's working
memory (a bound to check by measurement), all doubled for memsys5's
power-of-two blocks. 104 MiB reserved for 2 shards, 344 MiB for 8.
After startup SQLite allocates nothing, and memory running out is an
error (`SQLITE_NOMEM`, a 500), not a growing process. The configuration
window (initialize, shut down, configure, initialize: sqlite3_config is
refused while initialized) now holds the counted mutexes and the heap
together, in sqlite.zig.

Measured, musl's malloc (the build before) against memsys5, the
database reseeded, CPUs 0-1 (2 shards), three interleaved rounds
(bench_heap.sh): point reads 18,686 against 18,694 instructions, 149k
against 145k req/s (median; within the rounds' spread both ways); the
join 1,386,227 against 1,385,116 instructions, 5,760 against 5,684
req/s. Resident memory after both loads: 116 against 123 MB. Not
measured: eight shards contending for memsys5's one mutex (the laptop
cannot load eight shards cleanly with the loader beside them): TODO,
on a race droplet.

## 2026-10-06: SQLite with no OS code of its own (`SQLITE_OS_OTHER`)

SQLite now compiles without its unix VFS or pthread mutexes: roux's VFS
and mutexes are its only way to the system, so nothing can bypass the
shard's `Io` (a temporary file, a stray `fstat`). With `OS_OTHER`
SQLite's default mutexes are no-ops, which SQLite reports
(`MUTEX_NOOP`, checked by the options test), so `sqlite/mutex.zig` is
now the whole implementation, not a wrapper: a futex lock per mutex
(Drepper's), owned by its thread (a thread-local's address), recursive
where SQLite asks, twelve static and a pool of 64 for the few SQLite
allocates; the per-thread count of held mutexes stays, and with it the
VFS's assertion. SQLite calls our exported `sqlite3_os_init` as it
initializes, which registers the VFS; the configuration is now one
pass (mutexes, heap, initialize). `HAVE_USLEEP` and `HAVE_FDATASYNC`
went with the unix VFS.

Checked: SQLite's unix VFS is absent from the binaries (its `unix-excl`
name is in the build before, not in this one; examples/sqlite 143 KB
smaller); every test passes (two new: a recursive mutex refused to
another thread, a waited-for lock handed to the waiter); examples/sqlite
answers every route as before; the stall test keeps reads beside writes
at p99 0.3-0.5 ms. Against the build before (SQLite's pthread mutexes,
wrapped), point reads, three interleaved rounds with the laptop quiet:
18,699 against 18,703 instructions, 147k against 149k req/s (median,
within the spread).

## 2026-10-06: M5's proof: an exact count and integrity_check

examples/sqlite on a fresh database (20 dishes), CPUs 0-1: 3,000 writes
(`oha -n 3000 -c 16`, CPUs 2-3) while 32 connections read the 20-dish
join for 15 s (CPUs 4-7). Every write answered 201, 3,000 reviews in the
table afterwards (the count of answers, exactly); 45,353 reads, every
one 200; no error logged. After the server stopped, the `sqlite3` shell
(SQLite's own VFS, recovering roux's WAL): `PRAGMA integrity_check` ok,
`PRAGMA foreign_key_check` empty. M5 is done.

## 2026-10-06: `synchronous` FULL against NORMAL, on roux's VFS

Asked by the owner (many deployments run NORMAL and accept the
trade). A NORMAL build from a temporary edit (reverted), against FULL
(the host's), the database reseeded, CPUs 0-1, three interleaved rounds
(bench_sync.sh, stall.sh), btrfs on the laptop's NVMe:

| writes, 16 connections | FULL | NORMAL |
|---|---:|---:|
| req/s | 295, 300, 213 | 9,475, 9,285, 7,664 |
| p50 / p99 | 53 / 69-116 ms | 1.3 / 13-25 ms |
| instructions, user | ~55,700 | ~53,600 |
| kernel time | 372-444 us | 75-76 us |

31 times the writes. In WAL mode NORMAL does not sync the WAL at each
commit, only at a checkpoint: a commit is in the kernel's page cache
when it returns. A process crash loses nothing (the kernel has it); a
power loss, kernel panic or host failure can lose the commits since the
last checkpoint's sync (up to `wal_autocheckpoint` pages, ~4 MB here),
never the database's consistency. Reads beside 100 writes a second, one
shard: p99 0.27 ms either way (roux's VFS yields on the sync in both).
`synchronous` stays FULL until the owner decides (TODO).

## 2026-10-06: `synchronous`, the app's choice

The owner decided: the dragrace site's results take FULL, the new
read-write race workload NORMAL (every platform raced alike). So
`Sqlite.open!(Database.at(path), { synchronous: Full })` (or `Normal`):
`Settings`, a record so later settings are named. The host sets it on
every connection, readers too (the last connection to close
checkpoints), and reads it back (2 or 1), or the open fails; the startup
line says which. The setting is a connection's, not the file's: each
start sets it again.

The glue regenerated (ZigGlue.roc at the nightly's commit; from the
committed platform first, byte for byte the committed file): a
`FullOrNormal` enum and the fourth argument, nothing else.

Checked: `zig build test`, with a new test: opened NORMAL, FULL, NORMAL
on one file, the writer and every reader of a pool read back the level
asked. examples/sqlite built and started (`synchronous full`).

## 2026-10-06: `Sqlite.backup!`

The dragrace site keeps its races in roux's SQLite, and the owner wants
backups that need no thought. Nothing outside the app can copy the
database: roux's VFS holds an open file description lock on it, so
`sqlite3 .backup` (or a cron's copy) is kept out by design. So the app
asks: `Sqlite.backup!(db, request, { directory, keep })`.

`host/backup.zig`: SQLite's online backup from a leased reader of the
request's shard, `step(-1)`: one read transaction, a snapshot, the
writer committing meanwhile. Into `backup-<UTC>.partial` with no journal
(a failed copy is deleted, not rolled back), the file synced, renamed to
`backup-20261006T235959Z.db`, the directory synced: a copy under its
dated name is whole. Names sort as their times, so rotation deletes the
first `count - keep` (and any `.partial` a crash left). Bounded: keep 1
to 256, 512 copies, 4096 directory entries; one backup at a time in the
process, one a second (the name exists: refused). Refused to GET, HEAD,
OPTIONS and TRACE, as `write!`. The copy's connection takes 1 MiB of
page cache and a connection's share from SQLite's heap, added to
`heap_bytes`. The clock comes in as a parameter, so the test is exact.

Checked: `zig build test`: names (the epoch, a leap day), and a test on
real files: three dishes copied, a fourth added, copied again (3 and 4
rows, each copy passing `integrity_check`), the same second refused,
keep 0 refused, a third copy deleting the first and the crash's
partial, a file not a copy left alone. Mutation: rotation off fails the
test; the file's sync off does not (no simulated disk yet: the sim_io
TODO). examples/sqlite gained `POST /backup`: two copies, a GET 404, the
same second 500 with the reason logged; the copy read by the sqlite3
shell: `ok`, journal `wal` (the header copied), 3 rows. The glue
regenerated (from the committed platform first: byte for byte), only
additions.

## 2026-10-06: `File.read_utf8!` in `init!`

The dragrace site reads its API tokens once, at start. `File.read_utf8!`
in `init!` answered `FileUnreadable`: the host read files only through a
shard's `Io`, and `init!` runs on the main thread before any shard. Now
`init!` reads through the startup `Io` (the one SQLite's VFS uses there),
set for `init!` only. examples/files reads notes.txt's first line in
`init!` and answers it at `/first-line`: checked live.

## 2026-10-07: a row buffer per connection, not per shard (a bug)

The dragrace's conduit workload (reads and writes on SQLite, open loop,
roux on two shards) crashed roux at once: "roux-db: Conduit.newest: a row
the host should have refused", a row of the wrong width. Each request
alone answered right. The host kept a result's rows in one buffer per
shard; a statement yields mid-step (roux's VFS waits through the fiber),
another request of the shard runs its own statement on another reader
meanwhile, and both wrote rows into the same slots. Under concurrent
reads, a request could have been handed rows of another's: the race's
checks caught it as a crash only because the widths differed.

Now each connection has its own buffer: each reader of a shard's pool,
and the writer. A reader is leased to one statement at a time, the
writer is one request's at a time, so a buffer has one user. Memory: the
largest `rows_max` times 24 bytes, per connection.

Checked: the same race again (roux and Go, two shards for the server):
roux answered the contract's checks and climbed to 2,000 requests a
second without an error. Not checked by a test here: the host is tested
through its examples, and none ran concurrent reads on one shard; the
race does (TODO: a concurrent example test).

## 2026-10-07: templates compiled by Zig, the prototype

The owner's idea: the Roc a template generates is only its contract (the
type and a typed `render!`), and Zig compiles the template at comptime.
Prototyped in a scratch copy of roux (nothing committed), four
prototypes and three experiments, before the branch `templates`
(DESIGN, Templates, says how it works).

The race's Menu page (742 bytes, byte for byte the reference), one
render, `perf stat -e instructions:u,cycles:u` minus the n=0 run:

| renderer | instructions | cycles |
|---|---|---|
| today's generated Roc | 29,700 | 10,900 |
| Roc improved by hand (escape into the output, capacity 2048) | 20,600 | 7,100 |
| Zig comptime, standalone | 3,240 | 1,115 |
| Zig comptime in the host, ReleaseSafe | 5,610 | 1,980 |
| Zig comptime as its own ReleaseFast library | 4,280 | 1,385 |

Over HTTP (server on CPUs 0-1, oha on 2-7, interleaved A/B rounds, CPU
from /proc/stat): Zig 188k requests a second at 2.5 µs user CPU each,
Roc 112k at 8.9 µs (load ~1.2; the server's share of the gap not
attributed).

Learned:
- A hosted function must be effectful, and a type variable may appear
  only inside a `Box`: `template_render! : U64, Box(a) => Str` serves
  every template; the id says which.
- The box's payload is laid out by Roc's rules; `roc glue` on a
  throwaway platform whose hosted functions take each contract
  concretely gives the layout as `extern struct`s (0.5 s). Releasing it:
  `decrefBoxWith` with the struct's own `decref`.
- Reading an environment variable per render was 31% of its cost: read
  development settings once at startup.
- The host rebuilt is ~62 s; the templates as a separate object, ~15 s
  ReleaseFast and 370 ms Debug. Zig's incremental `--watch` on that
  object took 1.2 s and more per markup edit: slower than a fresh build.
- roc's `output: Archive` (crt1.o, the host, the app, builtins and musl
  in one `app.a`) linked with the templates object by `zig ld.lld
  -static`: 40 ms, and it served the same bytes. So roux can own the
  link, and a markup edit needs no roc.
- A development interpreter rendered byte for byte as the compiled
  renderer, but it is a second implementation: dropped (owner: "I
  cannot accept two implementations").

## 2026-10-07: templates compiled by Zig replace rocstache-gen; `roux build`

The branch's first step: the old compiler (`tools/rocstache-gen`, 3,500
lines, templates to Roc code) and the platform's Roc renderer helpers
(`Rocstache.roc`'s escape and formatters, 188 lines) are gone, replaced
by `tools/rocstache` (2,500 lines with tests) and `tools/roux` (190):

- **parse.zig**, one parser for comptime and run time, no allocation:
  values, `{{{ }}}`, `#`, `^`, `?`, partials, `../`, comments, the
  `{{% %}}` block first in the file. Formatter chains are `len`,
  `plural`, `len | plural`, or one of `upper`, `lower`, `url`: each
  writes straight into the page, so no chain builds a string.
- **contract.zig** infers a contract (partials read their includer's
  scope) or **declared.zig** reads `Ctx : { … }` (built-in types spelled
  out; `View.Row` is refused, since glue lays out the contract alone).
  Then every tag is checked against it, so mistakes are roux build's,
  as `Page.rocstache:12:5: `title` …`. `{{#flag}}` on a Bool opens a
  scope, as a list's does, so `../` counts the same in inference,
  checking and rendering.
- **render.zig**, the comptime renderer; **out.zig**, its writers, each
  with an exact measure: a render allocates once, exactly, and asserts
  it filled the buffer. A test sweeps every byte at every position
  through escape and its measure.
- **roc.zig** writes `Page.roc` (fmt-stable, checked with `roc fmt`;
  long contracts one field per line as fmt lays them), the throwaway
  glue platform and the registry; **generate.zig** does an app's
  directory; **object.zig** is the templates object's root.
- `roux build [--dev] APP.roc`: generate, then roc (`--opt=dev` or
  `speed`, to `.roux/APP/app.a`) and `zig build-obj` (Debug or
  ReleaseSafe) at once, then `zig ld.lld -static`. roux runs the Zig it
  was built with and the roc `.roc-version` names (build options).
  ReleaseSafe, not Fast, because the host ships safe; what it costs is
  the next step's measurement.
- The platform: `Host.template_render! : U64, Box(a) => Str`,
  `Rocstache.compiled_render!` over it, the target `output: Archive`.
  The host's glue regenerated: 16 lines added, nothing else.
- roc's `ZigGlue.roc` vendored (`vendor/roc-glue/`, sha256 ff18757f…,
  from roc 130536d, the file the prototype fetched, copied in).
- examples/files built its notes page by hand with `Rocstache.escape`:
  now a template (`Notes.rocstache`), since a Roc escape beside the Zig
  one would be two implementations.
- An app with no templates still gets a templates object (an empty
  registry): glue on a platform with no hosted functions works (0.6 s,
  once).

Checked: `zig build test` (tidy over `tools/` now, the new tests);
`roux build --dev` for all five examples (hello, files, sse, sqlite,
templates), each served; examples/templates' page byte for byte as
main's build of it (278 bytes, cmp); roc exits 1 on a Roc error and
roux stops. `roux build --dev examples/templates/main.roc`: templates
1 ms, roc and the templates object 450 ms at once, link 45-80 ms.
`zig fmt` ran over the new files (it rewrites in place).

Lost for now: the language server (`rocstache-gen lsp`, Zed's), TODO.
On the way, a mistake: a check of the old build ran it on port 8091,
which the dragrace site in `site dev` was serving, and SO_REUSEPORT let
both bind; only the example was stopped. Pick a port nothing listens on
(`ss -ltn`) before starting a server.

## 2026-10-07: the race's menu, main against the branch

The dragrace's roux competitor ported on fourneau-dragrace's own
`templates` branch (its Menu.rocstache declares its contract, the prices
being U32; `Menu.render!(context.menu)`; built by `roux build
--roc={roc}`). Its `/menu` is the workload's reference page byte for
byte (742 bytes, cmp). Then three builds of it, all `--opt=speed`: main
(roux main, the host rebuilt, templates in Roc by rocstache-gen), the
branch (templates ReleaseSafe), and the branch's archive linked with a
ReleaseFast templates object.

Interleaved A/B, five rounds of each: the server on CPUs 0-1 (two
shards), oha on 2-7 at 64 connections, 2 s warmup then 6 s measured;
`perf stat -e instructions:u` on the server for the window, its CPUs'
user time from /proc/stat. Load ~1.1 (a browser, an editor open).
Medians:

| build | req/s | instructions/req | user ns/req | p99 |
|---|---|---|---|---|
| main (Roc templates) | 109,004 | 39,030 | 9,030 | 1.03 ms |
| branch, ReleaseSafe | 164,753 | 14,807 | 3,368 | 0.62 ms |
| branch, ReleaseFast | 169,307 | 13,881 | 3,020 | 0.58 ms |

The whole request, HTTP included: 1.51 times the throughput, 2.6 times
fewer instructions, the tail 40% lower under load. Instructions per
request were steady within 0.1% across rounds; throughput moved ±8%
with the laptop. ReleaseSafe costs 926 instructions a request (6%) and
~3% of throughput, inside the noise: production stays safe, as the host.
(`/tmp/claude-1000/bench/ab.sh`, scratch.)

Also: `roux build --roc=PATH` (the dragrace installs its pinned roc
elsewhere; same pin), and roux writes stderr streaming: a positional
writer wrote at offset 0 of a log file it was redirected to, over what
roc had written.

## 2026-10-07: `roux dev`

`roux dev [--port=N] [--static=DIR] APP.roc` (tools/roux/dev.zig; the
build steps moved to pipeline.zig, shared with `roux build`): one loop,
one pass at a time. A pass hashes the app's sources by kind (`.roc`,
`.rocstache`, `.sql`, the static directory) and runs only what changed:
roux-db for a query, the templates' generation always (1 ms; it rewrites
a `Page.roc` only when its contract changed), roc when Roc sources
differ after that, the templates object when templates do, then the link
and a restart. inotify wakes it; a pass starts once the sources are
quiet 30 ms. The app runs with `ROUX_DEV` set to the build's number:
the host (host/dev.zig) answers `/_dev/events` itself and appends the
reload script to HTML, so no proxy. One line per pass: `roux dev: build
4 ok (templates) in 419 ms`, or `failed; build 3 still serving`, or the
app's own exit with its code.

Measured on a scratch copy of examples/templates (roux dev on port 8096,
an EventSource-like client reconnecting 50 ms after a drop), the time
from the save (sed) to the new page answered by curl:

| edit | new page | reload event | the pass |
|---|---|---|---|
| markup, 13 saves | 461-529 ms | +40-50 ms | 416-483 ms (templates) |
| contract and app (a field) | 1,078 ms | | 1,056 ms (roc and templates) |
| a field the declared contract lacks | refused, `Page.rocstache:10:17: `nope` the contract has no such field here (it has: items, title)`; the old build kept serving | | |

Today's `dragrace site dev` takes 3.0 s for a template edit.

Found on the way:
- Restarts failed every other time: `roux: shard: SystemResources`, the
  new instance's io_uring setup refused memory while the old one's
  rings were not yet freed (eight 4096-entry rings a process; `ulimit
  -l` 8 MiB). Back-to-back restarts, six each: 1, 2 and 4 shards never
  failed, 8 failed 3 times. The host takes `ROUX_SHARDS` now, and roux
  dev runs the app on two. Production restarts may meet the same
  (TODO).
- Stopping roux dev with SIGTERM left the app running (the defer never
  ran). Now a SIGINT or SIGTERM handler stops the app, then roux dev; a
  blocked signal and a signalfd would not do, since a blocked mask
  passes to the app across exec and the app must die by SIGTERM.
- An app without queries got roux-db run on it (the empty digest
  differed from the initial one): roux-db runs only when there are
  `.sql` files.
- A save that brings the sources back to the build that serves rebuilds
  nothing; it now says so, after a failure.
- `roux build` and `roux dev` leaked nothing (the debug allocator found
  a 4 KiB buffer on the first try, fixed).
- Twice in testing, `pgrep -f`/`pkill -f` on a pattern my own shell's
  command contained killed that shell (exit 144). Stop processes by PID
  or by exact command name (`ps -eo pid,comm`), as the benchmarking
  skill says.

## 2026-10-07: the dragrace site on the branch; an object per template

The site (fourneau-dragrace, branch `templates`), 12 templates with
partials, built by `roux build --dev site/main.roc`. What it took:
- Two things roux lacked. `roux build` now runs roux-db when the app
  has `db/schema.sql` (one step, as `roux dev` does). And `Bottom` reads
  nothing: its contract is `{}`, and glue drops a hosted function's
  zero-sized argument (`param_types[0]` of none), so such a template's
  module boxes a `U8` placeholder and glue never sees it.
- The site: `render` is `render!` (and `not_found!` effectful); its view
  records carried what no template reads (a class's tab `label`, chart
  lines' `end_x`/`end_y` for spreading labels): the lines are drafts
  until their labels are placed, then the contract's records, and the
  one class shown is mapped to its contract at the page.
- Its pages differed from main's by a byte or two: the old compiler
  removed a line holding only a section, comment or partial tag
  (Mustache's standalone rule), which the new parser did not. Now it
  does, as before (a test). Then main's site build (`out/dev/dragrace-
  site`) and the branch's, each on a copy of site.db: 17 pages and data
  files byte for byte (`/`, `/history`, the tab fragments, the JSON).

Then `roux dev` on a copy of the site (port 8099, `--static=static`):
markup edits took 1.43-1.50 s, every edit compiling all 12 templates in
one Debug object (1.22 s, 29 MB). Where it went:

| object, Debug | compile |
|---|---|
| no templates, std's panic handler | 327 ms |
| no templates, `no_panic` | 35 ms |
| no templates, `FullPanic` over the host's `roc_crashed` | 43 ms |
| the site's 12, std's handler / ours | 1,218 / 988 ms |
| one template alone, ours: Top, AboutPage, RaceClasses, IndexPage | 111, 159, 272, 392 ms |
| a Zig cache hit of one (same inputs) | ~145 ms |

So: our panic handler (it reports through the host, which prints and
aborts), and an object per template (part.zig; object.zig is the
dispatcher, calling each part's `rocstache_measure_<id>` and
`rocstache_render_<id>` through `@extern`; `Out` is `extern` now). roux
compiles an object only when none exists by the hash of what it is made
from (template, partials reached, registry, glue, renderer; Zig's own
cache hit costs 145 ms), up to 16 at once beside roc, links them all,
and deletes this mode's stale ones. `std.debug.simple_panic` does not
compile on 0.17 ("error set is discarded" in debug/simple_panic.zig).

Save to new page, `roux dev` on the site copy:

| edit | before (one object) | now |
|---|---|---|
| a page's markup (AboutPage) | 1.43-1.50 s | 266-298 ms (1 object, ~220 ms) |
| a partial in nine pages (Top) | | 927-948 ms (9 objects at once) |
| Roc (`main.roc`) | 1.28-1.33 s | (roc, ~1.2 s) |
| a static file | 78-82 ms | |
| `dragrace site dev` today, any template | 3.0 s | |

Every example builds in ~160 ms of compiling (`--dev`), from ~450.
Checked again after: examples/templates byte for byte as main's, the
site's 17 pages too; `zig build test` and tidy.

The optimized build of the site, `roux build` (roc `--opt=speed`, 13
objects ReleaseSafe beside it): 50 s, all of it roc; the dragrace DIARY
measured 83-94 s for `roc build --opt=speed` of the site while its
templates were Roc. Its 15 pages and data files are byte for byte
main's (on a copy of site.db).

## 2026-10-08: called partials, each compiled once

The owner's ask: partials swapped in O(1), not O(n) (an edit to `Top`
recompiled the eight pages that inline it). A partial can now be called
with its own context: `{{> Top frame}}`. Top's contract is its own; the
includer's field `frame` is of that type (inferred, it takes Top's
contract; declared, it must equal it; the module writes `frame :
Top.Ctx` and imports Top). Contracts are computed in order, a called
partial's before its callers', and partials that call each other are
refused by name. The renderer calls the partial's two functions by
their symbols (symbols.zig's `Extern`, the same the dispatcher uses),
passing the includer's field (another glue type of the same layout,
checked at comptime); a part's hash no longer covers the partials it
calls, only those it inlines. `{{> Top}}` still inlines.

Measured on a scratch copy of the dragrace site with its eight pages
changed to `{{> Top frame}}` (and `main.roc` passing `frame:` instead
of three flattened fields): the 12 pages and data files are byte for
byte main's; `roux dev`, save to new page:

| an edit to Top | objects | time |
|---|---|---|
| inlined (`{{> Top}}`) | 9 | 927-948 ms |
| called (`{{> Top frame}}`) | 1 | 427-574 ms |

The dragrace site itself is not changed here: its pages calling Top is
the owner's call (fourneau-dragrace, branch `templates`).

## 2026-10-08: a pure render in Roc: where the instructions go (branch templates-vm)

The owner challenged my guess that a bytecode VM in pure Roc could not
beat generated Roc (20,600 instructions for Menu, I said, was Roc's
floor; a VM 25-30k): "where are all the extra instructions coming
from? be creative on the vm hot path." This branch (from `templates`)
is that experiment. First, measured, not guessed.

The profile of P0, the hand-optimized generated Roc (`perf record -e
instructions:u`, 200,000 renders in `init!`): `roc_builtins_str_concat`
50.7%, the app's code 33%, allocation 6.6%, refcounts 3.2%, memcpy 2.7%.
Inside str_concat the hot loop is a byte at a time (movzbl, mov, dec,
jne: ~5 instructions a byte), every one of the 742 bytes through it,
plus the call's overhead. So the floor was Str.concat, not Roc.

Microbenchmarks (a scratch app on this branch's platform, `n.txt` the
variant and count, instructions per render = (N run - 0 run) / N, the
page's md5 checked):

| variant | instructions/render |
|---|---|
| P0 (Str.concat throughout) | 20,719 |
| a List(U8) builder (List.concat, static byte constants) | 21,133 |
| the same, not converted to Str | 19,443 |
| 62 Str.concat of short strings, nothing else | 10,900 |
| 62 List.append of a small tag union (parts) | 2,531 |

List.concat copies in bulk (memmove) but costs ~90 instructions a call,
and `Str.to_utf8` of a small (inline) string allocates. Appending a part
is ~40, inlined. So: a render that builds **parts**, not text. Then a VM
written by hand as a generator would emit it (one walker per record type
of the contract, the bytecode a List(U32), ops in the low 3 bits; static
text a `Text(ref)` the host resolves, values unescaped):

| VM | parts | instructions/render (Roc, freeing the parts included) |
|---|---|---|
| one part per op | 62 | 3,375 |
| fused: a static run and the value after it, one part | 38 | 2,345 |
| fused and loop-rotated (a row's closing run merged into the next row's opening) | 26 | 1,928 |

What remains: the walker (63%, the appends inlined) and freeing the list
(27%: each part's Str checked). Refcounts are atomic (`lock` prefixes in
both `rc_*` variants), so copying a heap string out of the shared
context costs an atomic increment and decrement on a line every shard
shares: Menu's names are inline (under 24 bytes), the site's are not.

The host then writes the parts (a Zig benchmark of the same 26 parts,
ReleaseSafe, the same page checked three ways):

| serializer | instructions/page |
|---|---|
| a measure pass, one exact allocation (as the comptime renderer does) | 8,508 |
| one pass into a reused buffer (a connection's), 16-byte page-safe loads for short strings | 4,869 |
| the same, static runs and short names overcopied as 32/16-byte blocks, digits straight into place | 3,797 |

So a pure render costs ~1.9k in Roc plus ~3.8k in the host: ~5.7k, near
the comptime renderer in the host (5,610, ReleaseSafe, prototype); and
the host's tricks apply to the comptime renderer as well (its measure
pass and byte-at-a-time tails). My 25-30k was wrong by ~5x: the cost
was never interpretation, it was concatenating strings.

## 2026-10-08: templates as bytecode, built (branch templates-vm)

The comptime renderer replaced, on this branch: `tools/rocstache`'s
render, object, part, symbols and out go; bytecode.zig (the compiler),
elf.zig (the object) and a new roc.zig (the walkers) come; the host's
templates.zig writes the parts. DESIGN.md, Templates, says how it works.
Choices made on the way, each for the hot path or the loop:

- **The mode rides in the run word.** A Str value's formatting (escaped,
  raw, upper, lower, url, and upper/lower unescaped for triple braces)
  is the top byte of the run word the bytecode holds, so the walker
  appends `Value(run, s0.name)` without looking at it, and the part type
  is four tags, not eight.
- **`../` is counted in the contract.** A walker per contract scope takes
  its enclosing scopes as arguments (`s0`, `s1`, ...), so a selector is
  (scopes up, field index by name), contract-only. The template's scopes
  differ when a section opens an ancestor's field: the compiler
  translates, and refuses a read the contract does not enclose.
- **No compiler for markup.** roux writes the object itself, an ELF
  relocatable of one section and one symbol (`rocstache_data`: the
  lengths, the code, the text, 32 bytes of slack for block copies). The
  link (`zig ld.lld`) is all a markup edit costs after the 10 ms of
  generation; the glue for contracts and the per-template objects go.
- **One program for all templates**, with a header of ranges: a
  template's module names only its index, and a partial edit is the
  same as a page edit.

Checked: both examples' pages and the dragrace site's twelve pages and
patches, byte for byte the `templates` branch's (a scratch copy of the
site at /tmp/claude-1000/vmsite, its main.roc ported to `render(code,
ctx)`; the competitor likewise at /tmp/claude-1000/vmcomp). Tests and
tidy pass.

Measured (`/tmp/claude-1000/bench/ab-vm.sh`, scratch: the server on CPUs
0-1, two shards, oha on 2-7, `perf stat -e instructions:u` on the
server, five interleaved rounds):

| competitor | instructions/request |
|---|---|
| comptime (`templates`) | 15,180-15,253 |
| VM (this) | 17,276-17,333 |

Throughput was not measurable: load 2.2 (a browser and an editor), the
comptime build swinging between 26k and 74k requests a second within
the run. The VM's profile (`perf record -e instructions:u`):
`hosted_templates_bytes` 25.5% and `digits` 5.8% (~5.4k: the
microbenchmark's 3.8k plus the parts' release and dispatch), the walker
16.9% (~2.9k, against 1.9k rotated in the microbenchmark: no rotation
here, and ReleaseSafe's checks).

The loop (`roux dev` on the site copy, five edits each, from the write
to the change served; roux dev's own line in brackets):

| edit | VM | `templates` branch |
|---|---|---|
| a page's markup | 110-140 ms (51-92) | 266-298 ms |
| Top, a called partial in eight pages | 110-154 ms | 427-574 ms |
| main.roc | 1,951-2,057 ms | ~1.3 s |

A Roc edit costs more: 15,000 lines of walkers on the site
(`roc check` 1.4 s; a cold `--opt=dev` 3.1 s). The site's release
build: roc 78 s against 50 s. Learned: `roux build` without `--dev` is
`--opt=speed`, so its 78 s is LLVM, not a slow dev backend (I first
read it so, and timed `--no-cache` and the cache before finding it).
Also: `**` is gone in Zig 0.17 (`@splat`, `splatByteAll`), as the zig
skill notes say.

## 2026-10-08: one VM in the host, no walkers

The owner: "This Walker shit all seems like a bad idea ... a single
renderer that compiles once", then "Remove walkers and use a constant VM
in host". Done (`591de12`). A pure renderer written once in Roc cannot
read a record it does not know (Roc has no reflection), so the pure
variant would have been generated code again; there was nothing to race
on that side.

How: `Page.roc` is the contract and `render! = |ctx|
Rocstache.render!(index, Box.box(ctx))`. The hosted function
`template_render! : U64, Box(a) => { bytes : List(U8), context : Box(a)
}` hands the box back, so Roc releases it and the host needs no layout
of what it does not read. The offsets come from the compiler: roux
writes a throwaway platform (one hosted function per contract) and runs
`roc glue` on it with its own spec, `tools/rocstache/Layout.roc`, which
writes `layouts.zon` (kinds, sizes, field offsets). The bytecode's reads
became `(up, byte offset)`; a dotted path is one sum; `../` counts the
template's scopes, since the VM keeps a stack of scope pointers.

Learned: `roc glue`'s cache ran ZigGlue's script when given my spec in
the same directory, and crashed on cut-down specs; `--no-cache` ran each
right, 0.27 s (roc skill, gotchas). The no-shell-edits hook read a loop
variable named `ex` as the editor.

Checked: `zig build test`; both examples, and all 12 pages and patches
of the dragrace site copy (ported: no `code` in the context,
`render!`, `Rocstache.html`/`str` pure), byte for byte the walkers' and
the `templates` branch's (`compare.sh`).

Measured, the race's Menu over HTTP, instructions:u per request (server
on CPUs 0-1, 200,000 requests, three interleaved rounds, within 0.1%):
comptime 15,085, walkers 17,184, the VM 15,870; with `read_int` and
`Sink.number` inline, 15,595. The VM's loop is 37% of the profile, flat
(copies and escaping). On dedicated cores (`dragrace adhoc race -workloads
templates`, three rounds, the under-driven ones rerun by the race):
comptime 135,639 requests a second, the VM 131,374 (-3.1%), the
walkers 127,027 (-6.3%).

The site copy: generated Roc 410 lines (was ~15,000); release build
39 s (78; comptime 50). `roux dev`: cold start 1.3-2.2 s (5.4-5.6),
warm 1.0 s (1.9-2.1); a page's markup 88-111 ms save to page, Top's
91-110 ms (110-154); main.roc 1.16-1.20 s (2.0; comptime 1.3).

## 2026-10-08: the glue cache bug filed; nightly-2026-10-06 on this branch

The glue cache: reduced to two seven-line specs from an empty cache,
the second run writing the first's file; the same on the newest nightly
and on upstream main 5e44ba38 (built here). Every spec that had crashed
ran under `--no-cache` at both opt levels: one bug, not two. Filed
roc-lang/roc#12139 (repro in ~/devel/rocbugs/glue-cache-ignores-spec).

The nightly chore, on this branch only (the owner: tonight's race runs
`main` untouched): `.roc-version` c34079d (installed copy checked
against the release's sha256); ZigGlue.roc and the musl files
unchanged at c34079d; the host's glue regenerated, identical once `zig
fmt` has run (glue quotes identifiers, `.@"Ok"`, and fmt unquotes them;
the ecb657f commit carried the unformatted file, put right after). Found and fixed while at it: roux build
kept the old compiler's `layouts.zon`, since no contract changed; the
roc path (and the spec) now count as glue's inputs, so a bump lays the
contracts out again (once, ~0.25 s). Checked: `zig build test`; both
examples, the race's Menu, and the site copy's 12 pages and patches
byte for byte as before; the site's release build 38 s.

## 2026-10-08: the comptime branch written up; the reread

The owner chose the host VM and asked for the comptime branch to be
documented in full: docs/templates-comptime.md (how it built and
rendered, every measurement, why the VM won, how to bring it back).

Then the reread (owner: "Reread is phenomenal ... Don't stop till this
shit is fucking tight"). A markup edit no longer links or restarts:
roux build writes the program alone too (`templates.bin`); roux dev
starts the app with `ROUX_DEV_TEMPLATES` naming it and, on a markup
edit, rewrites it and sends SIGUSR1. The handler bumps a counter and
wakes the `/_dev/events` streams through the futex (they wait on
io_uring futexes now, not a sleep); the next render swaps the program
in under hazard pointers, so a render on another shard never reads a
freed one. Pages carry the name they were made under, read before they
render, so a page made mid-swap reloads once more, never once too few.

Measured with a client that holds the event stream and fetches the page
on each event, 20-40 edits each (docs/dev-server.md has the table):
save to page 88-111 ms with the link and restart, 34-46 ms with the
reread, 6.1 ms without roux dev's 30 ms quiet window, 4.4 ms without
the safe build's 0xaa fill of whole trees and contracts (hundreds of
KB each: only headers are reset now; a record's fields are kept sorted
as added, so no sort buffer), 2.9 ms with the layouts kept parsed
between passes, 2.2-2.5 ms without hashing sources when inotify named
only templates, outputs' hashes kept in memory. Stamped stages: wake
0.13-0.32 ms, generation 0.42-1.55, signal to event 0.11-0.31; they
scale together with the laptop's clock.

Checked: 300 edits ten milliseconds apart under 175k requests a second
(two shards): 1.4 million responses, all 200, 30,858 pages read back
whole with markers that were written; the app's memory flat over 600
more. A broken template keeps the old program serving. Found while
testing: after a contract change whose roc failed, a later markup edit
would have had the old app reread a program laid out for the new
contract, reading records at wrong offsets. Two guards now: the program
carries its layouts' identity and the host refuses any other (shown by
signalling the app by hand: "the templates' contracts changed: the old
program serves until the restart"), and roux dev hashes every source
after a failed pass. Production: the Menu at 15,649 instructions a
request, from 15,595 at `591de12`; the new nightly and the render's one
comparison are both in the difference, not separated.

## 2026-10-08: incremental generation

The owner: "fix this" (generation redid every template on every edit).
Each template is now parsed, given its contract and compiled alone, and
`roux dev` keeps each (tools/rocstache/cache.zig) while its key holds:
the source for the tree; the source, the inlined partials' sources and
the called partials' contract keys for the contract; the sources it
compiles from, the layouts' identity (which now hashes the templates'
names, so a call's index is covered) and its index for its code. The
program is assembled from the chunks, each run word moved past the text
before it (`bytecode.assemble`; a test). inotify's names go down to
generation, which reads only those files and reuses its listing unless a
template was created or deleted; glue's step is skipped while every
contract key is the same; the object is written only when the layouts
change (the app reads `templates.bin`; the object carries the identity
the host checks rereads against, so it must follow the layouts); an
output known to differ is written without reading the old back. What a
generation replaces is freed once it succeeds; a failed one forgets
every template. Also found: `noun` leaked its buffer (harmless under the
arena, not under the cache's allocator), and the watcher's 64 KB event
buffer was a local `undefined`, filled on every read.

Measured (the browser-like client, 40 edits each): a page's markup 1.39
ms median save to page (2.2-2.5 before), Top, inlined by nine pages, 2.0
ms; a pass 0.1-1.7 ms. Checked: the site's 12 pages byte for byte; 300
edits under load, 1.06 million responses all 200, 27,645 pages whole; a
new template, a deleted one, a broken edit and its fix, a save by
temporary file and rename; no leak reported at exit. A mistake on the
way: a roux dev from an earlier measurement was still running, holding
the database and the port; two measurements and a comparison ran
against it before I saw it (`ps` before every run, as the benchmarking
skill says).

## 2026-10-09: an adversarial pass; Roc's keywords refused

The owner asked for an adversarial pass over the templates' flow (TODO,
Todo, has what it found). Checked, on a scratch copy of
examples/templates: a page with 100 KB of static text each side of a
value, then 150 KB (300 KB pages: runs split past 64 KiB, the growth
past the shard's 256 KiB buffer), byte for byte over three requests and
the same from a `--dev` build as from a release one; cycles of inlined
and of called partials, a missing partial, 20 nested sections, an
unclosed one, `Title` and `my-field` as names: each refused on its line.

What broke: `{{ if }}` passed roux's checks, and roc refused glue's
throwaway `Contracts.roc` (`t0! : { if : Str } => {}`, "malformed"), a
Roc error for a template's mistake. Every one of the 34 keywords in the
pinned compiler's tokenizer (src/parse/tokenize.zig at c34079d) fails
`roc check` as a field, in a type, a literal and an access, so parse.zig
now refuses all 34 in a path, and declared.zig in a declared `Ctx`:
"`if` is a Roc keyword, which cannot name a field", on its line (tests
in both). `when` is no keyword at this nightly, and builds.

## 2026-10-09: the app born ignoring SIGUSR1

From the same pass: roux dev tells the app to reread by SIGUSR1, whose
default action kills; between the spawn and the host's `start_dev` the
app had no handler. roux dev now ignores SIGUSR1 itself, and an ignored
disposition survives exec where a handler does not, so the app starts
ignoring it until the host's handler replaces that. Checked on a scratch
copy of examples/templates: `/proc` shows roux dev with SIGUSR1 in
`SigIgn` (0x200), the app with it in `SigCgt`, and a markup edit reread
(`templates reread, 1`, 0.1 ms) served at once.

## 2026-10-09: one key for the layouts

generate.zig kept two keys for glue's step: `laid_key`, from every
contract's key (made from template sources, so it moved on every markup
edit and skipped nothing then), and the layouts' identity, from what
glue reads (`Contracts.roc`'s text, the spec, the roc, the names), which
the step computes anyway in microseconds, an unchanged file costing a
hash. The identity is now the one key; `laid_key` and `laid_id` are gone
(26 lines). Measured on a scratch copy of the dragrace site (the port
from 2026-10-08, 12 templates, scratchpad `edit_latency.py`, 40 edits of
AboutPage each, alternating): a pass 0.7 ms median before and after,
save to page 1.94 ms before, 1.64 and 1.83 after (noise). A contract
change (Menu's `price : U32` to `U64`) still runs glue: 407 ms, both
files say `U64`, the page the same.

Also seen: a `roux dev` whose roux-db is not beside it fails every pass
with "build 1 failed" and no reason (the spawn's error is not printed).

## 2026-10-09: roc builds while glue lays out

Glue (~0.3 s) needs the contracts, roc needs the modules; neither needs
the other, yet they ran in turn. Measured first by hand on the site
copy: glue 279-329 ms, roc `--opt=dev` 902-919 ms, both at once 985-1006
ms (`--opt=speed`: 35 s either way). So generation has two halves now
(generate.zig): `begin` parses, decides contracts, writes the modules
and glue's inputs, and spawns glue when it must run, its output to
`glue/log` (a file: a long message cannot block it on a pipe); `finish`
waits, parses the layouts, compiles and writes the program; `abandon`
kills glue when the caller fails between. `roux build` and `roux dev`
start roc between the halves (dev.zig's pass grew past 70 lines, so the
generation and roc are its own function).

Measured, old and new binaries alternating: a `roux build --dev` of the
site with glue's output deleted, 1289-1327 ms before, 1026-1041 after
(-21%); `roux dev` on examples/templates, Menu's `price` flipped
U32/U64 six times, 396-446 ms a pass before, 364-408 after (roc there is
only ~100 ms). Checked: every site page (8, 67 KB) byte for byte from a
release build before and after; glue failing (a fake roc whose `glue`
exits 3: "roc glue failed on the contracts: glue says no", no roc left
running); roc failing (a broken main.roc: roc's message, glue finished).

## 2026-10-09: a failure says why; the reread counter never steps back

A tool that cannot start (a roux-db not beside roux, as above) is now
named by roux, as a tool that ran and failed would have said: "roux:
.../roux-db could not run: FileNotFound", and roux dev names any other
failure that no compiler printed ("build 1 failed (…)"). In the host,
`swap_in` skips a request another thread has already met or passed
(counters compared as a wrapping distance): before, a thread waiting
with an older request set `loaded` back and every render read the file
once more. Checked on the site copy: 300 edits ten milliseconds apart
under `oha -c 32` for 12 s, 1,905,863 responses all 200 (158,801 a
second, two shards), 21,462 pages read whole, each marker one written;
301 rereads.

## 2026-10-09: the reload script only where a page is shown

In development every `text/html` answer got the reload script, so an
HTML fragment fetched by Datastar (`fetch()`) would open one more event
stream per patch once the page morphed it in. The browser says what an
answer is for: `Sec-Fetch-Dest` is `document` (or `iframe`) for a
navigation and `empty` for `fetch()`. The script now goes only where it
is `document`, `iframe` or absent (curl and agents send none, and keep
it). Checked against examples/templates under roux dev: the script with
no header and with `document`, none with `empty`; a test in dev.zig.

## 2026-10-09: directories made while roux dev runs are watched

roux dev watched the directories that were there when it started, so a
directory made later (a `db/` for the first queries, a module folder)
and everything in it went unseen. Each watch now knows its directory
(by watch descriptor), and a directory created or moved in under one is
watched with all it holds (`add_tree`, the one walk startup uses too;
`mkdir -p a/b` is caught by the walk), and the next pass lists and
hashes again. Checked on examples/templates: `mkdir newdir`, then
`newdir/X.roc`: build 2 (roc); `mkdir -p deep/er`, then
`deep/er/Y.roc`: build 3. The old binary, the same steps: build 1 only.

## 2026-10-09: the compiler and the VM, tested together

Nothing ran the VM over bytecode the compiler made but the examples'
pages. host/templates_test.zig (its own test root, with the `rocstache`
module, which now exports the parser, the bytecode compiler and the
layouts) makes 3,000 templates from seeds over a contract laid out by
hand from Zig `extern struct`s whose fields are the ABI's own `RocStr`
and `RocList`: Str, U32 and I64 leaves, a list of records holding a
list, a nested record (dotted paths), Bool sections (`#`, `^`, `?`),
`../` up to the root, every formatter (`len`, `plural`, `upper`,
`lower`, `url`), escaped and raw, and a partial both inlined and called
(`Badge`). Each is compiled and assembled as roux build does, run by the
VM's `render_from` over four random records (strings inline and on the
heap, with every special byte), and compared with an oracle written
there: a walk of the parse tree over the Zig values, sharing no code
with the compiler or the VM. 12,000 renders pass. It fails at once on a
bug planted in each: the VM dropping a number's sign (the first seed),
the compiler swapping the plural's nouns (seed 1). On the way, the
generator's own bug (a called partial's field without its `../`) was
found by the compiler's refusal, which names the field.

The seeds come from fourneau's `prng` (tidy refuses the standard
library's), which the `fourneau` module now exports (fourneau, same day).
