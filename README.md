# roux

A Roc platform for hypermedia apps. An app (Roc handlers, typed templates, typed SQL on SQLite)
builds into one static executable that you copy to a server and run, with nothing in front. It runs
on [fourneau](https://github.com/Eldhus/fourneau), each request a Roc handler on a fiber; templates
compile to bytecode, so a markup edit reaches the browser in milliseconds under `roux dev`. Editor
support: [rocstache](https://github.com/Eldhus/rocstache).

A *roux* (said "roo") is the base every sauce starts from.


## Use it

Start from [roux-tutor](https://github.com/Eldhus/roux-tutor): clone it and run `./roux dev
main.roc`; it fetches roux and the Roc compiler it needs. By hand, take `roux` from the
[latest release](https://github.com/Eldhus/roux/releases/latest) (`roux version` names the Roc
nightly it needs); its notes give the line that names the platform in your app's header.

```sh
roux dev main.roc     # served, rebuilt as you save; a request during a restart waits for it
roux build main.roc   # the executable, beside it
```

x86-64 Linux 6.7 or later, on an x86-64-v3 CPU (AVX2).


### The database

An app's database is SQL in `db/`, which `roux-db` checks and compiles as the app builds:

- `schema.sql`: what the database is, its `CREATE` statements.
- `ledger.sql`: what was changed by hand, in order: a rename, a drop, rows moved. Most apps need
  none for a long time.
- every other `.sql`: the queries, each a typed Roc function.

When the app starts, before it serves, it brings its database to `schema.sql`, in one
transaction, each step printed before it runs:

1. The steps of `ledger.sql` the database has not run, in order. The database records each as it
   runs (in its table `roux_ledger`), so a step runs once on every database, however many releases
   that database skipped.
2. What `schema.sql` changed: a new table made; a table whose `CREATE` changed rebuilt with its
   rows (an `AUTOINCREMENT` goes on from where it was), SQLite saying whether they fit; indexes,
   views and triggers made again.
3. The database must then be exactly what `schema.sql` makes, no foreign key broken. A failure
   anywhere rolls it all back: the database is as it was, and the app does not start, saying which
   step and why.

Adding a table, a column, an index or a constraint is an edit to `schema.sql`, and nothing more. A
table or column `schema.sql` no longer has is refused, its rows kept, until a step renames or drops
it; the refusal writes the step. A step is one SQL statement, ended by `;`:

```sql
-- db/ledger.sql: add steps at the end; a step that ran is never changed.
ALTER TABLE dish RENAME COLUMN title TO name;

-- Dishes get a slug (schema.sql makes it NOT NULL UNIQUE).
ALTER TABLE dish ADD COLUMN slug TEXT;
UPDATE dish SET slug = lower(replace(name, ' ', '-'));

DROP TABLE menu;
```

- A step is plain SQL, run as written, on the database as the last deploy left it, before
  `schema.sql`'s changes: a step that fills a column `schema.sql` adds adds the column first, as
  above. SQLite's rules hold: it drops no column a view still reads (drop the view in a step first;
  `schema.sql` makes it again).
- Foreign keys are off while the steps run, so nothing cascades; they are checked once, at the end.
- A new database is made from `schema.sql`, and records every step as run without running one.
- A step that ran is never changed: a database refuses a ledger whose step differs from the one it
  ran, and says both. Comments between steps are not part of them.
- Before steps run, the database is copied into `<path>.before-ledger/` (the last four kept).
  Forward only: the way back is that copy, or one `Sqlite.backup!` made.
- Every view, trigger and `REFERENCES` of the schema is checked as it builds: one that names a
  table or column the schema no longer makes is refused there, not at the request that would run
  it.

To deploy, stop the old executable and start the new one: it migrates, then serves. One process
owns a database, so the new one refuses to start while the old one runs; if the migration is
refused, the database is unchanged and the old executable still opens it. An older executable put
back over a database a newer one migrated opens it as it is, if its ledger is the start of the
database's and its `schema.sql` what the database holds; otherwise it is refused.

Rehearse first: `ROUX_REHEARSE=1 ./app` copies the database beside itself, migrates the copy and
runs `init!` over it, prints what the deploy will, deletes the copy and exits (0 when it all went
through) without serving. The database is only read, but read it must be: the running app holds
it, so rehearse a copy `Sqlite.backup!` made (`ROUX_DATABASE=prod-copy.db`), or rehearse in the
deploy itself, between stopping the old executable and starting the new. Your dev and staging
databases took their own paths to this schema (a dev database took `schema.sql`'s column before
the step that fills it was written); a rehearsal of production's runs the very steps production
will, on its data.

On a team, both files merge as code does. Two branches that each add a column merge into a
`schema.sql` with both. Two that each add steps meet at the end of `ledger.sql`, and git asks
which goes first. A dev database that ran its branch's step before another branch's came in front
of it is refused, as an edited step would be; so is one whose branch's schema lacks a column
another branch added. Give each branch its database:
`ROUX_DATABASE=dev-$(git branch --show-current).db roux dev main.roc`. A dev database that ran a
draft of a step: put back the copy made before it, from `<path>.before-ledger/`, and fix the
step.


## The road ahead

- Multipart uploads, file responses.
- x64v1musl support
- A developer tool under `/_dev`.
- `shutdown!`
- Steps of the ledger in Roc, for what SQL cannot compute.
- Nested results in typed SQL: a column built by SQLite's JSON functions read as a Roc list or
  record, so a query returns a tree in one round trip.
- Tag unions in typed SQL: a table's variants read and written as a Roc tag union.
- Roc hot reload: a Roc edit served without a restart, as a markup edit already is.
- Data-driven routing: routes declared as data, and routers that compose. More structure in routing
  makes a large app easier to understand.
- Pub/sub: a publish needs no request, a gap is told, a slow reader never slows a publisher.
- A simulated disk, so SQLite runs under fourneau's simulator.


## Working on it

roux builds against fourneau checked out beside it:

```sh
git clone https://github.com/Eldhus/fourneau ../fourneau
zig build platform tools   # the host and roux
zig build test             # tidy and every test
```

To build an app against the checkout, the platform also needs musl's `crt1.o` and `libc.a`, from
Roc's source at the commit `toolchain.json` pins, each checked against its SHA-256 there:

```sh
c=$(jq -r .roc_musl.commit toolchain.json)
mkdir -p platform/targets/x64musl
for f in crt1.o libc.a; do
    curl -fsSL -o platform/targets/x64musl/$f \
        https://raw.githubusercontent.com/roc-lang/roc/$c/test/fx/platform/targets/x64musl/$f
done
jq -r '.roc_musl.files | to_entries[] | "\(.value)  platform/targets/x64musl/\(.key | split("/") | last)"' \
    toolchain.json | sha256sum -c
```

Zig and the Roc nightly are pinned in `.zig-version`, `.roc-version` and `toolchain.json`.


## Security

Report a problem by a private security advisory on GitHub, not an issue; see
[SECURITY.md](SECURITY.md).


## License

MIT. `host/roc_platform_abi.zig` and `vendor/roc-glue/` are Roc's (Universal Permissive License);
`vendor/sqlite/` is SQLite's (public domain); a release carries musl (MIT).

Part of [Eldhus](https://github.com/Eldhus).
