# The dev server

`roux dev APP.roc` (tools/roux/dev.zig, the host's host/dev.zig and
host/templates.zig): the app built, run, and back on the screen as it is
edited, for people and for agents. What runs in development is what
runs in production, from the same source: the same host, the same
bytecode, the same renderer (owner, 2026-10-07: "I cannot accept two
implementations").

## Kinds of edit

A pass hashes nothing it need not: inotify says which kinds of file
changed (`CLOSE_WRITE`, `MOVED_TO`, `CREATE`, `DELETE`: a file complete,
never half written), and content decides from there, never mtimes.

| edit | what runs | save to page (the dragrace site, 2026-10-08) |
|---|---|---|
| a template's markup, a page's or a partial's | the generation of what the edit touched (0.1-1.7 ms), then SIGUSR1: the running app rereads the program. No link, no restart, no compiler; the app's state kept | 1.39 ms median from a client for a page, 2.0 ms for a partial nine pages inline |
| a template's contract (a field added, a type) | its `Page.roc` and `Templates.roc` rewritten, glue (~0.3 s), `roc build --opt=dev` (roc links), the program attached, a restart | a Roc edit's and glue's (not measured end to end) |
| Roc source | `roc build --opt=dev` (roc links), the program attached, a restart | 1.1-1.2 s; 1.03 s with roc linking (2026-10-09, roc-link) |
| a query (`db/*.sql`) | roux-db, then as Roc source | |
| a static file | a restart (the host reads them at startup) | |

## The reread

roux build writes the templates' program to `templates.bin` and attaches
it after the executable roc linked (production's). In development the
app is started with `ROUX_DEV_TEMPLATES` naming the file,
and reads its program from it, from before `init!`. On a markup edit
roux dev rewrites the file and sends the app SIGUSR1:

1. The signal handler bumps a counter and wakes, through the futex, every
   open `/_dev/events` stream (async-signal-safe: an atomic and a
   `FUTEX_WAKE`; the streams' fibers wait on io_uring futexes).
2. Each stream sends the new name, `<build>.<program>`. The page's
   script knows the name the page was made under (read before it was
   rendered) and reloads.
3. The next render, on any shard, sees the counter moved, reads the file
   and swaps the program in. A render on another shard may still run the
   old one: each thread publishes the program it renders from (a hazard
   pointer), and the swap frees the old one only once no hazard holds it.
   Renders never yield, so that wait is a render's length.

Checked: 300 edits ten milliseconds apart under 175k requests a second
(two shards): 1.4 million responses, all 200; 30,858 pages read back
whole, each marker one that was written; the app's memory flat over 600
more (the old programs freed).

Two guards keep a reread from reading records at wrong offsets:

- The program carries its layouts' identity (a hash of what glue laid
  the contracts out from: the spec, the roc, the contracts). The host
  rereads only a program whose identity is the one it was linked with;
  another is refused ("the templates' contracts changed: the old program
  serves until the restart"), as is a program for another number of
  templates. This holds whatever roux dev does.
- roux dev takes the markup-only path only after a pass that succeeded:
  after a failure (a contract changed and roc failed) it hashes every
  source again, sees the Roc it has not built, and retries roc instead.

In production `ROUX_DEV_TEMPLATES` is unset: renders take the linked
program, and the reread costs one comparison a render.

## What made it fast

Measured with a client that holds `/_dev/events` as the page's script
does and fetches the page on each event (scratch `edit_latency.py`), on
the dragrace site copy, 2026-10-08:

| change | save to page, median |
|---|---|
| link and restart (before the reread) | 88-111 ms |
| the reread | 34-46 ms |
| no 30 ms quiet window after the first event (inotify's events mean complete files; a pass costs a millisecond, so a burst costs one more) | 6.1 ms |
| no 0xaa fill of whole trees and contracts (a safe build fills `undefined`; the bounded arrays are hundreds of KB; only headers are reset now, and a record's fields are kept sorted as added, so no sort buffer) | 4.4 ms |
| the parsed layouts kept between passes while glue's inputs are unchanged (parsing the ZON was a quarter of generation) | 2.9 ms |
| no hashing of sources when inotify named only templates | 2.2-2.5 ms |
| outputs' hashes kept in memory: an unchanged one is neither read back nor written | 2.2-2.5 ms (generation ~0.8 ms) |
| incremental generation (tools/rocstache/cache.zig): each template parsed, given its contract and compiled alone, each kept while its key holds (its source; the partials it inlines; the contracts of those it calls; the layouts); the program assembled from the chunks, their text runs moved; only the files inotify named are read; glue's step skipped while no contract key moved; the object written only when the layouts change (the app reads `templates.bin`) | 1.39 ms a page, 2.0 ms Top (inlined by nine pages: nine contracts and chunks really change); a pass 0.1-1.7 ms |

Where it went before incremental generation (stamps on the monotonic
clock): the save to roux dev awake 0.13-0.32 ms; generation 0.42-1.55 ms
(12 templates parsed, contracts, bytecode, two files); the signal to the
stream's event 0.11-0.31 ms. The three move together with the laptop's
clock speed. A page edit's pass is now 0.1-0.7 ms: reading the one file,
parsing and checking it, compiling it, assembling, writing
`templates.bin`.

Checked again with incremental generation: the site's 12 pages byte for
byte; 300 edits under load (1.06 million responses, all 200, 27,645
pages whole); a new template (roc, link, restart, then its edits
reread), a deleted one (restart), a broken edit and its fix, an editor's
save by temporary file and rename.

## Integration points

- **roc links.** roux attaches the templates' program after roc's
  executable (until 2026-10-09 roc made an archive and roux linked it
  with `zig ld.lld`). In development only a Roc change attaches again.
- **Reload without a proxy.** The host serves `/_dev/events` itself, in
  development only, and appends the reload script to `text/html`
  answers; the templates' output stays production's.
- **A failed build** leaves the last good one serving, and says so on
  roux dev's line. Showing the error in the page: not built.
- **Dev-only code is off the hot path**: decided once at startup.
- **State across restarts**: a Roc edit runs `init!` again and drops SSE
  streams; a markup edit keeps all of it.

## For agents

- One line per pass on stderr: `roux dev: build 1 ok (templates reread,
  12) in 0.8 ms`, `build 2 ok (roc) in 1097 ms`, `build 3 failed; build 2
  still serving`.
- Generated files are written only when their content changes, so an
  agent's diff shows only what it changed.
- Not built: `/_dev/status` as JSON.

## Before (2026-10-07)

When templates were Roc (rocstache-gen), a template edit was `roc build`
and a restart: 3.0 s on the site; the release build 83-94 s. The
comptime branch (docs/templates-comptime.md) took a markup edit to
0.27-0.57 s (a Zig object, the link, a restart).

## The example app repository

The owner's plan (2026-10-07): a standard roux app as its own
repository, assuming the toolchain is installed and taking the Roc
nightly, hosted on the dragrace site's machine. What it needs from here:
`roux build` and `roux dev` usable from outside roux's tree, and the
platform as a bundle roc can fetch.
