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
roux dev main.roc     # served, rebuilt as you save
roux build main.roc   # the executable, beside it
```

x86-64 Linux 6.7 or later, on an x86-64-v3 CPU (AVX2).


### The database

The database's schema is `db/schema.sql`, and nothing else: change it, and the app migrates its
database when it starts, before it serves. There are no migration files and no command to run.

- Each step is printed before it runs, in one transaction. A step that fails rolls them all back:
  the database is as it was, and the app does not start, saying which step and why.
- A table whose `CREATE` changed is rebuilt with its rows (an `AUTOINCREMENT` goes on from where it
  was); whether the rows fit a new constraint is SQLite's to say as they are copied.
- A table or column the schema no longer has is refused, its rows kept, unless the schema drops it
  on purpose, and fills what is new from what was there by an SQL expression over the old row.
  Each line says the release it came in:

  ```sql
  -- @release 9
  -- @drop 8 column dish title
  -- @from 8 column dish name = title          -- a rename: the drop, and the fill
  -- @from 9 column dish slug = lower(name)    -- a new NOT NULL column, filled
  -- @drop 9 table menu
  -- @from 9 table meal = menu                 -- a table renamed
  ```

  A name with a space goes in double quotes. Before a drop the database is copied into
  `<path>.before-drop/`, the last four kept.
- An `@from` expression is SQL. It sees the old row's columns by their old names; a subquery
  naming the table sees the new one, still being filled. It fills a column only when the column is
  new to its table, so it never runs twice; filling a column the table has already is a task in
  `init!`. A `--` comment may follow it.
- Every view, trigger and `REFERENCES` of the schema is checked as it builds: one that names a
  table or column the schema no longer makes is refused there, not at the request that would run
  it.
- Forward only: the way back is a copy, before a drop or by `Sqlite.backup!`.

The database keeps the release it reached (`PRAGMA user_version`), written with the migration. A
line applies to a database at its release or older, never newer, whatever its shape. Once every
database has finished a release, delete its lines and say so: `-- @oldest 8`. A database still
older is refused, rather than migrated without the lines it needed. In `init!`,
`Sqlite.migrated_from(db)` says where a database came from, for a task that fixes older rows.
Columns are matched by name: a name dropped and later added again meets its old values in a
database that skipped the releases between. Splitting a table into two needs a task in `init!`:
an `@from` fills one table from one other.

To deploy, stop the old executable and start the new one: it migrates, then serves. One process
owns a database, so the new one refuses to start while the old one runs; if the migration is
refused, the database is unchanged and the old executable still opens it.

Rehearse first: `ROUX_REHEARSE=1 ./app` copies the database beside itself, migrates the copy and
runs `init!` over it, prints what the deploy will, deletes the copy and exits (0 when it all went
through) without serving. The database is only read, but read it must be: the running app holds
it, so rehearse a copy `Sqlite.backup!` made (`ROUX_DATABASE=prod-copy.db`), or rehearse in the
deploy itself, between stopping the old executable and starting the new. Your dev and staging
databases took their own paths to this schema; a rehearsal of production's runs the very plan
production will, on its data.

On a team, `schema.sql` merges as code does: two branches that each add a column merge into a
schema with both, and every database migrates to it. Under `roux dev`, a branch whose schema lacks
a column another branch added is refused on switching back: give each branch its database,
`ROUX_DATABASE=dev-$(git branch --show-current).db roux dev main.roc`.


## The road ahead

- Multipart uploads, file responses.
- x64v1musl support
- A developer tool under `/_dev`.
- `shutdown!`
- Data migrations, in Roc, beside the schema's.
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
