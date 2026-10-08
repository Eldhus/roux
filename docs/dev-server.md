# The dev server

`roux dev`: an app rebuilt and back on the screen as it is edited, for
people and for agents. These notes collect what was thought and learned
on the way; what is built is on the branch `templates` (TODO, WIP 3),
described in its DESIGN.md (Templates; Tools) once merged. What is not
built says so.

## The goal

From a save to the new page on the screen in the least time the
toolchain allows, with no second implementation of anything: what runs
in development is what runs in production, compiled from the same
source (owner, 2026-10-07: "I cannot accept two implementations"). So
no template interpreter in dev, though the prototype had one.

## Where it stands (branch `templates`, 2026-10-07)

`roux dev [--port=N] [--static=DIR] APP.roc` is built and measured on a
copy of examples/templates (save with sed, then curl until the new page;
an EventSource-like client for the reload):

| edit | save to new page | reload event | today's `dragrace site dev` |
|---|---|---|---|
| a template's markup | 461-529 ms | +40-50 ms | 3.0 s |
| a contract and the app's record (a field) | 1.08 s | | (every edit 3.0 s) |
| a mistake in a template | refused at once with `Page.rocstache:10:17: ...`; the old build serves | | |

Each step's cost, on the laptop (nightly-2026-10-04-130536d, Zig 0.17.0):

| step | time | where |
|---|---|---|
| the templates generated (contracts, registry) | ~1 ms | roux dev |
| glue, when a contract changed | ~0.6 s | roux dev |
| the templates object, Zig Debug (self-hosted backend) | 370-450 ms | roux dev |
| the same, ReleaseSafe or Fast (production) | 14-17 s | roux build |
| `zig build -fincremental --watch` on it, a markup edit | 1.2 s and more: slower than a fresh build | prototype |
| the link, `zig ld.lld` of roc's archive and the object | 40-80 ms | roux dev |
| `roc build --opt=dev`, the example | ~0.1 s | roux dev |
| `roc build --opt=dev`, the dragrace site | 1.8-2.9 s, 1.5-1.7 s lowering the whole program | fourneau-dragrace DIARY |
| `roc build --opt=speed`, the site | 83-94 s, changed or not | same |
| the app restarted (two shards) | tens of ms | roux dev |

## Kinds of edit

Each takes its own path; content hashes decide (never mtimes or event
kinds), so a save that changes nothing, and the generators' own writes,
cost a hash pass and no more.

| edit | what runs |
|---|---|
| a template's markup | the templates object (Debug), the link, a restart. No roc, no glue. |
| a template's contract | the template's `Page.roc` rewritten, glue, roc and the object at once, the link, a restart |
| Roc source | roc, the link, a restart |
| a query (`*.sql`) | roux-db, then as Roc source |
| a static file (`--static`) | a restart (the host reads them at startup) |

## Integration points, as built

- **The link is roux's.** The platform's target is `output: Archive`;
  roux links roc's archive with the app's templates object. That lets a
  markup edit skip roc, and gives each app its own templates object.
- **One renderer source**, Debug in development, ReleaseSafe in
  production (as the host ships; ReleaseFast measured 6% fewer
  instructions a request, inside the noise in throughput).
- **Errors from the generator, not from Zig**: `Page.rocstache:12:5:
  ...`, file:line:column as compilers print them, so an editor or an
  agent jumps to it. A Zig compile error in the templates object is a bug
  in roux.
- **Reload without a proxy.** `ROUX_DEV` (the build's number) puts the
  host in development mode, decided once at startup: it answers
  `/_dev/events` itself (`retry: 50`, the number, then held open) and
  appends the listening script to `text/html` answers. A restart drops
  the stream; the browser reconnects 50 ms later, hears another number,
  reloads. Production pays one comparison a request.
- **Two shards in development** (`ROUX_SHARDS=2`): eight shards
  restarted right after eight failed half the time, the kernel not yet
  having freed the old process's io_uring memory (8 MiB locked memory on
  the laptop). Production restarts may meet the same (roux TODO).
- **roux dev owns its app**: a SIGINT or SIGTERM handler stops the app,
  then roux dev (a blocked signal would pass to the app across exec, and
  the app must die by SIGTERM). The app exiting on its own is reported
  with its code; the next save starts it again.
- **A restart could overlap** (thought, not built): fourneau's shards
  bind with SO_REUSEPORT, so a new binary could take connections before
  the old one stops. Not with SQLite: roux's VFS holds the database file
  locked, so the old must close it first. And the same property is a
  trap: a stale instance silently shares the port, as one did with the
  dragrace site on 8091 (branch DIARY).
- **State across restarts**: `init!` runs again (the site reads its
  tokens and opens SQLite). Open SSE streams drop and reconnect.

## Next, not built

- **The error over the page.** A failed build leaves the old app
  serving and prints the error in the terminal; the browser shows
  nothing. The old app cannot learn of the failure without a channel:
  roux dev writes the status to a file `ROUX_DEV_STATUS` names and the
  host reads it on each `/_dev/events` connection (and roux dev pokes
  the stream by restarting nothing)? Or roux dev serves `/_dev/events`
  itself on another port and the script listens there. Undecided.
- **Faster markup edits.** 30 ms of quiet before a pass and a 50 ms
  reconnect could be 10 and 20. The object's 370-450 ms is Zig compiling
  Debug: where it goes is not measured (`--time-report`); the glue file is
  ~10k lines and std comes in, and a smaller import set may halve it.
  Then the link and the restart (~0.1 s) could go: a self-contained
  position-independent templates blob loaded into the running app by
  our own loader (static musl has no `dlopen`: map it, apply its
  `R_X86_64_RELATIVE` relocations, refuse anything else), a pointer
  swapped between renders. The same compiled code, loaded differently.
- **Directories made after start** are not watched (the watch set is
  built once). A new `db/` or template directory needs a restart of roux
  dev.
- **Static files** are named with `--static`: the host knows its
  `static_dir` only after `init!`. In development it could say so
  (a line roux dev reads), and roux dev watch it without a flag.
- **The dragrace site** is the real test: 14 templates with partials,
  roc at 1.8-2.9 s for every Roc edit. Its `site dev` (Go, a proxy)
  moves onto `roux dev`.

## For agents

- Built: one line per pass on stderr, `roux dev: build 4 ok (templates)
  in 419 ms`, `roux dev: build 5 failed; build 4 still serving`, `roux
  dev: build 5 exited, code 1`, so an agent waits on a line instead of
  polling. Generated files are written only when their content changes,
  so an agent's diff shows only what it changed.
- Not built: `/_dev/status` as JSON (the build's number, ok or the
  error, its time), so `curl` answers "is my edit live yet?".

## The example app repository

The owner's plan (2026-10-07): a standard roux app as its own
repository, assuming the toolchain is installed and taking the Roc
nightly, hosted on the dragrace site's machine. What it needs from here:
`roux build` and `roux dev` usable from outside roux's tree (the
renderer's Zig source and roc's glue spec are embedded in the tool
already; the tool finds the pinned Zig and roc by path), and the
platform as a bundle roc can fetch, with `libhost.a`, crt1.o and musl's
libc.a inside (roc's archive output then carries them).
