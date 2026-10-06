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
