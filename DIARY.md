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
