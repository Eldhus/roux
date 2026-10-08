# The dev server

Notes toward `roux dev`: an app rebuilt and back on the screen as it is
edited, for people and for agents. Kept as thoughts and integration
points arrive, while the templates move to Zig (TODO, WIP); not a design
yet, and nothing here is built unless it says so. The contract, once
settled, goes in DESIGN.md.

## The goal

From a save to the new page on the screen in the least time the
toolchain allows, with no second implementation of anything: what runs
in development is what runs in production, compiled from the same
source (owner, 2026-10-07: "I cannot accept two implementations"). So
no template interpreter in dev, though the prototype had one.

## What a save costs today

Measured 2026-10-07 on the laptop (nightly-2026-10-04-130536d, Zig 0.17.0):

| step | time | where |
|---|---|---|
| `roc build --opt=speed` (the dragrace site) | 83-94 s, changed or not | fourneau-dragrace DIARY |
| `roc build --opt=dev` (the site) | 1.8-2.9 s, 1.5-1.7 s of it lowering the whole program | same |
| `dragrace site dev`, save to reloaded page | 3.0 s for a template, 10 ms for a static file | same |
| the templates object, Zig Debug (self-hosted backend) | 370-380 ms | prototype, `zig build-obj` |
| the same, ReleaseFast | ~15 s | prototype |
| `zig build -fincremental --watch` on it, a markup edit | 1.2 s and more: slower than a fresh build | prototype |
| linking an app: roc's archive + templates object, `zig ld.lld` | 40 ms | prototype |
| restarting the site | 40-70 ms | fourneau-dragrace DIARY |

## Kinds of edit

Each kind takes a different, shorter path; the watcher decides by
content (hashes), not by mtimes or event kinds, as `dragrace site dev`
does.

| edit | what runs |
|---|---|
| a template's markup | the templates object (Debug), the link, a restart. No Roc. |
| a template's contract (a field added, a type) | rocstache-gen writes the template's `.roc`; glue for the layout; `roc build --opt=dev`; the object; the link; a restart |
| Roc source | `roc build --opt=dev`, the link, a restart |
| a query (`db/*.sql`) | roux-db, then as Roc source |
| a static file | nothing but the browser's reload |

## Integration points

- **The link is roux's.** The platform's target is `output: Archive`
  (roc emits `app.a` with crt1.o, the host, the app, the builtins and
  musl in it); roux links it with the app's templates object. That is
  what lets a markup edit skip roc entirely, and gives each app its own
  templates object without writing into the shared `platform/targets/`.
- **The renderer is one Zig source**, compiled Debug in development and
  ReleaseFast for production. The comptime-generated code is the same.
- **Errors from the generator, not from Zig.** rocstache-gen checks a
  template (parse, fields against the contract) and prints
  `Page.rocstache:12: ...`; a Zig compile error in the templates object
  is a bug in rocstache-gen. The dev server shows the generator's message
  over the page.
- **Reload without a proxy.** roux owns the server, so the host can
  serve `/_dev/events` itself (an `EventSource`), in dev only, sending
  the build's id on connect. A restart drops the stream; the browser
  reconnects by itself, sees a new id, reloads. The script that listens:
  added by the host to `text/html` responses in dev, not by the
  templates (their output stays production's).
- **A failed build** leaves the old binary serving. How it learns the
  error to show: the dev supervisor writes the status where the host
  reads it (a file named in `ROUX_DEV`?), or the supervisor serves the
  error page itself until a build succeeds. Undecided.
- **Dev-only code is off the hot path**: decided once at startup (an
  environment variable read before `init!`), never per request. The
  prototype read an environment variable per render: 31% of its cost.
- **State across restarts**: `init!` runs again (the site reads its
  tokens and opens SQLite: 40-70 ms). Open SSE streams drop and
  reconnect.

## For agents

- One command that builds, serves and prints one machine-readable line
  per build (`build 7 ok 412ms`, `build 8 error Page.rocstache:12: ...`),
  so an agent can wait on a line instead of polling.
- `/_dev/status` as JSON (build id, ok or the error, the time it took),
  so `curl` answers "is my edit live yet?".
- Generated files written only when their content changes, so an
  agent's diff shows only what it changed.

## Faster than a restart, later

A markup edit is ~0.45 s by the numbers above, almost all of it Zig
compiling Debug. The link and restart (~0.1 s) could go: compile the
templates as a self-contained position-independent blob, load it into
the running app (static musl has no `dlopen`: our own loader, mapping
it and applying its `R_X86_64_RELATIVE` relocations, refusing anything
else), and swap a pointer between renders. The same compiled code
still, only loaded differently. Worth it only if the restart shows up in
the measured loop.

Where the 370 ms goes is not measured yet (`--time-report`): the glue
file is ~10k lines and std comes in; a smaller import set may halve it.

## The example app repository

The owner's plan (2026-10-07): a standard roux app as its own
repository, assuming the toolchain is installed and taking the Roc
nightly, hosted on the dragrace site's machine. What it needs from here:
`roux build` and `roux dev` usable from outside roux's tree (the
renderer's Zig source shipped with the tool, not read from a checkout),
and the platform as a bundle roc can fetch.
